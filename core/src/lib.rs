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
            created_at TIMESTAMP,
            tags VARCHAR[]
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
        
        // Filtrar solo archivos .md
        if file_path.is_file() && file_path.extension().and_then(|s| s.to_str()) == Some("md") {
            let title = file_path.file_stem().and_then(|s| s.to_str()).unwrap_or("Sin título");

            // Leer contenido del archivo
            let content = fs::read_to_string(file_path).unwrap_or_else(|_| "".to_string());

            // Insertar en la tabla de notas incluyendo el contenido
            let insert_res = conn.execute(
                "INSERT OR REPLACE INTO notes (id, title, path, content, created_at) VALUES (?, ?, ?, ?, now())",
                params![full_path_str, title, full_path_str, content],
            );

            if insert_res.is_ok() {
                count += 1;
            }
        }
    }

    format!("Escaneado completado: {} notas procesadas con contenido.", count)
}

#[uniffi::export]
pub fn query_notes(search_term: Option<String>, path_filter: Option<String>, ignore_patterns: Vec<String>) -> Vec<NoteRecord> {
    let conn_guard = DB_CONN.lock().unwrap();
    let conn = match conn_guard.as_ref() {
        Some(c) => c,
        None => return Vec::new(),
    };

    let mut sql = "SELECT id, title, path, content FROM notes WHERE 1=1".to_string();
    
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

    if let Some(term) = search_term {
        if !term.is_empty() {
            sql.push_str(&format!(" AND (title ILIKE '%{}%' OR content ILIKE '%{}%')", term, term));
        }
    }
    sql.push_str(" ORDER BY created_at DESC");

    let mut stmt = conn.prepare(&sql).unwrap();
    let note_iter = stmt.query_map([], |row| {
        Ok(NoteRecord {
            id: row.get(0)?,
            title: row.get(1)?,
            path: row.get(2)?,
            content: row.get(3)?,
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
                        if path_str.ends_with(".md") && !ignore_patterns.iter().any(|p| path_str.contains(p)) {
                            let mut conn_guard = DB_CONN.lock().unwrap();
                            if let Some(conn) = conn_guard.as_mut() {
                                let title = path.file_stem().and_then(|s| s.to_str()).unwrap_or("Sin título");
                                let content = fs::read_to_string(&path).unwrap_or_else(|_| "".to_string());
                                let _ = conn.execute(
                                    "INSERT OR REPLACE INTO notes (id, title, path, content, created_at) VALUES (?, ?, ?, ?, now())",
                                    params![path_str, title, path_str, content],
                                );
                                update_sync_ts();
                            }
                        }
                    }
                }
            }
        }
    });
    "File Watcher iniciado.".to_string()
}
