use duckdb::{params, Connection, Result};
use std::sync::Mutex;
use once_cell::sync::Lazy;
use walkdir::WalkDir;
use std::path::Path;
use std::fs;
use notify::{Watcher, RecursiveMode, Config, RecommendedWatcher};
use std::sync::mpsc::channel;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

uniffi::setup_scaffolding!();

#[derive(uniffi::Record)]
pub struct NoteRecord {
    pub id: String,
    pub title: String,
    pub path: String,
    pub content: String,
    pub is_dir: bool,
}

static DB_CONN: Lazy<Mutex<Option<Connection>>> = Lazy::new(|| Mutex::new(None));
static LAST_SYNC_TS: Lazy<Mutex<u64>> = Lazy::new(|| Mutex::new(0));

#[uniffi::export]
pub fn get_last_sync_ts() -> u64 {
    *LAST_SYNC_TS.lock().unwrap()
}

fn update_sync_ts() {
    let mut ts = LAST_SYNC_TS.lock().unwrap();
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    *ts = now;
}

#[uniffi::export]
pub fn hello_vault() -> String {
    "Hello from Vault Core IA (DuckDB Engine)!".to_string()
}

fn generate_embedding(text: &str) -> Vec<f32> {
    let mut vec = vec![0.0f32; 384];
    if text.is_empty() {
        return vec;
    }
    let words: Vec<&str> = text.split_whitespace().collect();
    for word in &words {
        let mut h = 5381u64;
        for c in word.chars() {
            h = (h << 5).wrapping_add(h).wrapping_add(c as u64);
        }
        for step in 0..12 {
            let dim = ((h ^ (step * 0x9e3779b9u64)) % 384) as usize;
            let val = if (h & (1 << step)) != 0 { 1.0f32 } else { -1.0f32 };
            vec[dim] += val;
        }
    }
    let sum_sq: f32 = vec.iter().map(|x| x * x).sum();
    let norm = sum_sq.sqrt();
    if norm > 0.0001f32 {
        for val in vec.iter_mut() {
            *val /= norm;
        }
    }
    vec
}

fn vector_to_sql_array(vec: &[f32]) -> String {
    let mut s = "ARRAY[".to_string();
    for (i, val) in vec.iter().enumerate() {
        if i > 0 {
            s.push_str(", ");
        }
        s.push_str(&val.to_string());
    }
    s.push(']');
    s
}

#[uniffi::export]
pub fn init_knowledge_base() -> String {
    let mut conn_guard = DB_CONN.lock().unwrap();
    
    // Abrir conexión en memoria
    let conn = match Connection::open_in_memory() {
        Ok(c) => c,
        Err(e) => return format!("Error abriendo DuckDB: {}", e),
    };

    // Crear tablas de esquema básico
    let schema_res = conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS notes (
            id VARCHAR PRIMARY KEY,
            title VARCHAR,
            path VARCHAR,
            content TEXT,
            is_dir BOOLEAN DEFAULT false,
            created_at TIMESTAMP,
            tags VARCHAR[],
            embedding FLOAT[]
        );
        CREATE TABLE IF NOT EXISTS links (
            source_id VARCHAR,
            target_id VARCHAR,
            type VARCHAR,
            FOREIGN KEY (source_id) REFERENCES notes(id)
        );
        CREATE TABLE IF NOT EXISTS telemetry (
            ts TIMESTAMP DEFAULT now(),
            context VARCHAR,
            event_type VARCHAR,
            message TEXT,
            metadata JSON
        );"
    );

    match schema_res {
        Ok(_) => {
            *conn_guard = Some(conn);
            "Knowledge Base inicializada (DuckDB in-memory)".to_string()
        },
        Err(e) => format!("Error de Esquema: {}", e),
    }
}

#[uniffi::export]
pub fn scan_vault(path: String, ignore_patterns: Vec<String>) -> String {
    let mut conn_guard = DB_CONN.lock().unwrap();
    
    let conn = match conn_guard.as_mut() {
        Some(c) => c,
        None => return "Error: La base de datos no ha sido inicializada.".to_string(),
    };

    // Limpiar registros antiguos para evitar huérfanos antes de re-escanear
    // Usamos un patrón que incluya el directorio raíz y todos sus hijos
    let clean_path = if path.ends_with('/') { path.clone() } else { format!("{}/", path) };
    let _ = conn.execute(
        "DELETE FROM notes WHERE path = ? OR path LIKE ?",
        params![path, format!("{}%", clean_path)],
    );

    let mut count = 0;
    let vault_path = Path::new(&path);

    // Iterar recursivamente sobre el directorio
    for entry in WalkDir::new(vault_path)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let file_path = entry.path();
        let full_path_str = file_path.to_str().unwrap_or("");

        // Aplicar filtrado híbrido: ignorar si la ruta contiene algún patrón de la lista blanca negativa
        if ignore_patterns.iter().any(|p| full_path_str.contains(p)) {
            continue;
        }
        
        // Procesar directorios y archivos
        if file_path.is_dir() {
            let title = file_path.file_name().and_then(|s| s.to_str()).unwrap_or("Carpeta");
            let sql = "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at) VALUES (?, ?, ?, ?, true, now())";
            let _ = conn.execute(sql, params![full_path_str, title, full_path_str, ""]);
        } else if file_path.is_file() && file_path.extension().and_then(|s| s.to_str()) == Some("md") {
            let title = file_path.file_stem().and_then(|s| s.to_str()).unwrap_or("Sin título");

            // Leer contenido del archivo
            let content = fs::read_to_string(file_path).unwrap_or_else(|_| "".to_string());

            // Generar embedding
            let emb = generate_embedding(&content);
            let sql = format!(
                "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at, embedding) VALUES (?, ?, ?, ?, false, now(), {})",
                vector_to_sql_array(&emb)
            );

            // Insertar en la tabla de notas incluyendo el contenido y embedding
            let insert_res = conn.execute(
                &sql,
                params![full_path_str, title, full_path_str, content],
            );

            if insert_res.is_ok() {
                count += 1;
            }
        }
    }

    format!("Escaneado completado: {} notas procesadas con contenido y embeddings.", count)
}

#[uniffi::export]
pub fn create_item(path: String, is_dir: bool) -> bool {
    let target = Path::new(&path);
    if is_dir {
        fs::create_dir_all(target).is_ok()
    } else {
        if let Some(parent) = target.parent() {
            let _ = fs::create_dir_all(parent);
        }
        fs::write(target, "").is_ok()
    }
}

#[uniffi::export]
pub fn rename_item(old_path: String, new_path: String) -> bool {
    // Borrar registros viejos de la DB (el sync posterior creará los nuevos)
    {
        let mut conn_guard = DB_CONN.lock().unwrap();
        if let Some(conn) = conn_guard.as_mut() {
            let _ = conn.execute(
                "DELETE FROM notes WHERE path = ? OR path LIKE ?",
                params![old_path, format!("{}/%", old_path)],
            );
        }
    }
    fs::rename(old_path, new_path).is_ok()
}

#[uniffi::export]
pub fn delete_item(path: String) -> bool {
    // 1. Borrar de la base de datos
    {
        let mut conn_guard = DB_CONN.lock().unwrap();
        if let Some(conn) = conn_guard.as_mut() {
            let _ = conn.execute(
                "DELETE FROM notes WHERE path = ? OR path LIKE ?",
                params![path, format!("{}/%", path)],
            );
        }
    }

    // 2. Borrar del disco
    let target = Path::new(&path);
    if target.is_dir() {
        fs::remove_dir_all(target).is_ok()
    } else {
        fs::remove_file(target).is_ok()
    }
}

#[uniffi::export]
pub fn query_notes(search_term: Option<String>, path_filter: Option<String>, ignore_patterns: Vec<String>) -> Vec<NoteRecord> {
    let conn_guard = DB_CONN.lock().unwrap();
    let conn = match conn_guard.as_ref() {
        Some(c) => c,
        None => return Vec::new(),
    };

    let mut search_emb_sql = String::new();
    let mut is_semantic = false;

    if let Some(ref term) = search_term {
        if !term.is_empty() {
            let emb = generate_embedding(term);
            search_emb_sql = vector_to_sql_array(&emb);
            is_semantic = true;
        }
    }

    let mut sql = if is_semantic {
        format!(
            "SELECT id, title, path, content, is_dir, array_cosine_similarity(embedding, {}) as similarity FROM notes WHERE 1=1",
            search_emb_sql
        )
    } else {
        "SELECT id, title, path, content, is_dir FROM notes WHERE 1=1".to_string()
    };
    
    // Filtro por Workspace (Path)
    if let Some(path) = path_filter {
        if !path.is_empty() {
            sql.push_str(&format!(" AND path LIKE '{}%'", path));
        }
    }

    // Aplicar filtros de ignorado
    for pattern in ignore_patterns {
        sql.push_str(&format!(" AND path NOT LIKE '%{}%'", pattern));
    }

    if is_semantic {
        sql.push_str(" ORDER BY similarity DESC");
    } else {
        sql.push_str(" ORDER BY created_at DESC");
    }

    let mut stmt = conn.prepare(&sql).unwrap();
    let note_iter = stmt.query_map([], |row| {
        Ok(NoteRecord {
            id: row.get(0)?,
            title: row.get(1)?,
            path: row.get(2)?,
            content: row.get(3)?,
            is_dir: row.get(4)?,
        })
    }).unwrap();

    note_iter.map(|n| n.unwrap()).collect()
}

#[uniffi::export]
pub fn save_note(path: String, content: String) -> String {
    let res = fs::write(&path, content);
    match res {
        Ok(_) => {
            update_sync_ts();
            "Nota guardada en disco.".to_string()
        },
        Err(e) => format!("Error al guardar: {}", e),
    }
}

#[uniffi::export]
pub fn add_telemetry_event(context: String, event_type: String, message: String) {
    let mut conn_guard = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_guard.as_mut() {
        let _ = conn.execute(
            "INSERT INTO telemetry (context, event_type, message) VALUES (?, ?, ?)",
            params![context, event_type, message],
        );
    }
}

#[uniffi::export]
pub fn get_telemetry_summary() -> String {
    let conn_guard = DB_CONN.lock().unwrap();
    let conn = match conn_guard.as_ref() {
        Some(c) => c,
        None => return "DB no inicializada".to_string(),
    };

    let count: i64 = conn.query_row("SELECT count(*) FROM telemetry", [], |row| row.get(0)).unwrap_or(0);
    format!("Total de eventos de telemetría registrados: {}", count)
}

#[uniffi::export]
pub fn start_watcher(paths: Vec<String>, ignore_patterns: Vec<String>) -> String {
    thread::spawn(move || {
        let (tx, rx) = channel();
        let mut watcher = RecommendedWatcher::new(tx, Config::default()).unwrap();

        for path in &paths {
            let _ = watcher.watch(Path::new(path), RecursiveMode::Recursive);
        }

        for res in rx {
            if let Ok(event) = res {
                if event.kind.is_modify() || event.kind.is_create() {
                    for path in event.paths {
                        let path_str = path.to_str().unwrap_or("");
                        let is_dir = path.is_dir();
                        
                        if is_dir || (path_str.ends_with(".md") && !ignore_patterns.iter().any(|p| path_str.contains(p))) {
                            let mut conn_guard = DB_CONN.lock().unwrap();
                            if let Some(conn) = conn_guard.as_mut() {
                                let title = path.file_name().and_then(|s| s.to_str()).unwrap_or("Sin título");
                                
                                if is_dir {
                                    let _ = conn.execute(
                                        "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at) VALUES (?, ?, ?, ?, true, now())",
                                        params![path_str, title, path_str, ""],
                                    );
                                } else {
                                    let content = fs::read_to_string(&path).unwrap_or_else(|_| "".to_string());
                                    let emb = generate_embedding(&content);
                                    let sql = format!(
                                        "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at, embedding) VALUES (?, ?, ?, ?, false, now(), {})",
                                        vector_to_sql_array(&emb)
                                    );
                                    let _ = conn.execute(
                                        &sql,
                                        params![path_str, title, path_str, content],
                                    );
                                }
                                update_sync_ts();
                            }
                        }
                    }
                } else if event.kind.is_remove() {
                    for path in event.paths {
                        let path_str = path.to_str().unwrap_or("");
                        let mut conn_guard = DB_CONN.lock().unwrap();
                        if let Some(conn) = conn_guard.as_mut() {
                            let _ = conn.execute(
                                "DELETE FROM notes WHERE path = ? OR path LIKE ?",
                                params![path_str, format!("{}/%", path_str)],
                            );
                            update_sync_ts();
                        }
                    }
                }
            }
        }
    });
    "File Watcher iniciado.".to_string()
}
