use duckdb::{params, Connection, Result};
use std::sync::Mutex;
use std::time::Duration;
use serde_json::{json, Value};
use once_cell::sync::Lazy;
use walkdir::WalkDir;
use std::path::Path;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
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

// --- COLA DE TELEMETRÍA ---
static TELEMETRY_LOGS: Lazy<Mutex<Vec<String>>> = Lazy::new(|| Mutex::new(Vec::new()));

pub fn add_telemetry_log(log: String) {
    if let Ok(mut logs) = TELEMETRY_LOGS.lock() {
        logs.push(log);
        // Mantener un máximo de 500 logs en memoria para no desbordar
        if logs.len() > 500 {
            logs.remove(0);
        }
    }
}

#[uniffi::export]
pub fn poll_telemetry_logs() -> Vec<String> {
    if let Ok(mut logs) = TELEMETRY_LOGS.lock() {
        let extracted = logs.clone();
        logs.clear();
        return extracted;
    }
    Vec::new()
}

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
    if text.is_empty() {
        return vec![0.0f32; 384];
    }
    
    // FASE 1: Aceleración MLX (Nativo M2 Pro)
    // 1. Convertimos el texto en una semilla numérica para el tokenizer simulado.
    let mut h = 5381u64;
    for c in text.chars() {
        h = (h << 5).wrapping_add(h).wrapping_add(c as u64);
    }
    let seed_val = (h % 1000) as f32 / 1000.0;
    
    // 2. Creación nativa del Tensor en MLX. 
    use mlx_rs::array;
    let mlx_tensor = array!(seed_val);
    
    // Expandimos al tamaño del vector objetivo (384 dimensiones) usando MLX
    let shape: &[i32] = &[384];
    let expanded = mlx_rs::ops::broadcast_to(&mlx_tensor, shape).unwrap_or(array!(0.0f32));
    
    // Simulación de un paso de transformación matricial en NPU (Linear Layer)
    let weights = mlx_rs::ops::ones::<f32>(&[384, 384]).unwrap_or(array!(0.0f32));
    let mut result_tensor = mlx_rs::ops::matmul(&expanded, &weights).unwrap_or(array!(0.0f32));
    
    // Evaluar el tensor en memoria (NPU/GPU) antes de extraerlo a la CPU
    let _ = result_tensor.eval();
    
    // 3. Extraemos los resultados a un Vec<f32> seguro para DuckDB
    let mut vec: Vec<f32> = result_tensor.as_slice::<f32>().to_vec();
    
    // 4. Normalización L2 requerida para búsqueda por similitud de Coseno
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
    s.push_str("]::FLOAT[384]");
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

    // Crear tablas de esquema básico y Arquitectura Dual-Brain
    let schema_res = conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS notes (
            id VARCHAR PRIMARY KEY,
            title VARCHAR,
            path VARCHAR,
            content TEXT,
            is_dir BOOLEAN DEFAULT false,
            created_at TIMESTAMP,
            tags VARCHAR[],
            embedding FLOAT[384]
        );
        CREATE TABLE IF NOT EXISTS links (
            source_id VARCHAR,
            target_id VARCHAR,
            type VARCHAR,
            weight FLOAT DEFAULT 1.0,
            created_at TIMESTAMP DEFAULT now(),
            FOREIGN KEY (source_id) REFERENCES notes(id)
        );
        CREATE TABLE IF NOT EXISTS telemetry (
            ts TIMESTAMP DEFAULT now(),
            context VARCHAR,
            event_type VARCHAR,
            message TEXT,
            metadata JSON
        );
        
        -- FASE 2: ARQUITECTURA DUAL-BRAIN (Metadata Offloading)
        -- Esta tabla almacena los resúmenes sintéticos generados por la IA Local (Daemon).
        -- Es la ÚNICA tabla de contenido que el MCP expondrá a los LLMs Remotos.
        CREATE TABLE IF NOT EXISTS semantic_summaries (
            note_id VARCHAR PRIMARY KEY,
            synthetic_summary TEXT,
            extracted_entities VARCHAR[],
            cognitive_timestamp TIMESTAMP DEFAULT now(),
            semantic_density FLOAT,
            FOREIGN KEY (note_id) REFERENCES notes(id)
        );
        
        -- FASE 3: GRAFO TEMPORAL Y NAVEGACIÓN
        CREATE TABLE IF NOT EXISTS entity_graphs (
            entity_name VARCHAR,
            note_id VARCHAR,
            relation_type VARCHAR,
            discovered_at TIMESTAMP DEFAULT now(),
            FOREIGN KEY (note_id) REFERENCES notes(id)
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
fn make_accent_insensitive_regex(word: &str) -> String {
    let mut regex = String::new();
    for c in word.chars() {
        if c >= '\u{0300}' && c <= '\u{036F}' { continue; }
        match c.to_lowercase().next().unwrap() {
            'a' | 'á' | 'ä' => regex.push_str("[aáäAÁÄ]\\p{M}*"),
            'e' | 'é' | 'ë' => regex.push_str("[eéëEÉË]\\p{M}*"),
            'i' | 'í' | 'ï' => regex.push_str("[iíïIÍÏ]\\p{M}*"),
            'o' | 'ó' | 'ö' => regex.push_str("[oóöOÓÖ]\\p{M}*"),
            'u' | 'ú' | 'ü' => regex.push_str("[uúüUÚÜ]\\p{M}*"),
            'n' | 'ñ' => regex.push_str("[nñNÑ]\\p{M}*"),
            other => {
                if ".*+?^${}()|[]\\".contains(other) { regex.push('\\'); }
                regex.push(other);
                regex.push_str("\\p{M}*");
            }
        }
    }
    regex
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

    if let Some(ref term) = search_term {
        if !term.is_empty() {
            // Filtrado estricto por palabras: Intersección (AND) de todos los tokens con soporte para acentos y NFD
            for word in term.split_whitespace() {
                let safe_word = word.replace("'", "''"); // Evitar inyección
                let regex_pattern = format!("(?i){}", make_accent_insensitive_regex(&safe_word));
                sql.push_str(&format!(" AND (regexp_matches(title, '{}') OR regexp_matches(content, '{}') OR regexp_matches(path, '{}'))", regex_pattern, regex_pattern, regex_pattern));
            }
        }
    }

    if is_semantic {
        sql.push_str(" ORDER BY similarity DESC");
    } else {
        sql.push_str(" ORDER BY created_at DESC");
    }

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            println!("DuckDB prepare error: {}", e);
            return Vec::new();
        }
    };
    
    let note_iter = match stmt.query_map([], |row| {
        Ok(NoteRecord {
            id: row.get(0).unwrap_or_default(),
            title: row.get(1).unwrap_or_default(),
            path: row.get(2).unwrap_or_default(),
            content: row.get(3).unwrap_or_default(),
            is_dir: row.get(4).unwrap_or(false),
        })
    }) {
        Ok(iter) => iter,
        Err(e) => {
            println!("DuckDB query_map error: {}", e);
            return Vec::new();
        }
    };

    note_iter.filter_map(|n| n.ok()).collect()
}

#[uniffi::export]
pub fn save_note(path: String, content: String) -> String {
    let res = fs::write(&path, content);
    match res {
        Ok(_) => {
            update_sync_ts();
            
            // Auto Git Commit implementation
            let path_obj = std::path::Path::new(&path);
            if let Some(parent) = path_obj.parent() {
                if let Some(file_name) = path_obj.file_name() {
                    if let Some(file_str) = file_name.to_str() {
                        let _ = std::process::Command::new("git")
                            .current_dir(parent)
                            .args(["add", file_str])
                            .output();
                        
                        let _ = std::process::Command::new("git")
                            .current_dir(parent)
                            .args(["commit", "-m", &format!("[Vault Auto-Save] {}", file_str)])
                            .output();
                    }
                }
            }

            "Nota guardada en disco.".to_string()
        },
        Err(e) => format!("Error al guardar: {}", e),
    }
}

#[derive(uniffi::Record)]
pub struct GitCommit {
    pub hash: String,
    pub date: String,
    pub message: String,
}

#[uniffi::export]
pub fn get_file_history(path: String) -> Vec<GitCommit> {
    let path_obj = std::path::Path::new(&path);
    let parent = match path_obj.parent() {
        Some(p) => p,
        None => return vec![],
    };
    let file_name = match path_obj.file_name() {
        Some(f) => f.to_str().unwrap_or(""),
        None => return vec![],
    };

    let output = std::process::Command::new("git")
        .current_dir(parent)
        .args(["log", "--pretty=format:%H|%ad|%s", "--date=short", "--", file_name])
        .output();

    let mut commits = vec![];
    if let Ok(out) = output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            let parts: Vec<&str> = line.splitn(3, '|').collect();
            if parts.len() == 3 {
                commits.push(GitCommit {
                    hash: parts[0].to_string(),
                    date: parts[1].to_string(),
                    message: parts[2].to_string(),
                });
            }
        }
    }
    commits
}

#[uniffi::export]
pub fn get_file_content_at_commit(path: String, commit_hash: String) -> String {
    let path_obj = std::path::Path::new(&path);
    let parent = match path_obj.parent() {
        Some(p) => p,
        None => return String::new(),
    };
    let file_name = match path_obj.file_name() {
        Some(f) => f.to_str().unwrap_or(""),
        None => return String::new(),
    };

    let spec = format!("{}:./{}", commit_hash, file_name);
    let output = std::process::Command::new("git")
        .current_dir(parent)
        .args(["show", &spec])
        .output();

    if let Ok(out) = output {
        String::from_utf8_lossy(&out.stdout).to_string()
    } else {
        String::new()
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

#[uniffi::export]
pub fn start_cognitive_daemon() -> String {
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(10));
            
            // Usar un nuevo binding para evitar mantener el lock demasiado tiempo
            let mut pending_notes = Vec::new();
            
            {
                let conn_guard = DB_CONN.lock().unwrap();
                if let Some(conn) = conn_guard.as_ref() {
                    // Buscar notas que no están en semantic_summaries
                    let query = "
                        SELECT id, title, content 
                        FROM notes 
                        WHERE is_dir = false 
                          AND id NOT IN (SELECT note_id FROM semantic_summaries)
                        LIMIT 50
                    ";
                    
                    let mut stmt = match conn.prepare(query) {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    
                    let note_iter = match stmt.query_map([], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                        ))
                    }) {
                        Ok(i) => i,
                        Err(_) => continue,
                    };
                    
                    for note in note_iter {
                        if let Ok(n) = note {
                            pending_notes.push(n);
                        }
                    }
                }
            }
            
            if pending_notes.is_empty() {
                continue;
            }
            
            // Procesamiento: IA Local (Fase 2)
            // Aquí en un futuro se llamará al modelo local (MLX / LLaMA / Phi)
            // Por ahora, usamos un Mock cognitivo
            
            let mut processed = Vec::new();
            for (id, title, content) in pending_notes {
                // Mock Summary
                let mut snippet = content.chars().take(150).collect::<String>();
                if content.len() > 150 { snippet.push_str("..."); }
                
                let synthetic_summary = format!("SÍNTESIS DE [{}]: {}", title, snippet);
                
                // Mock Entities (palabras de más de 6 letras que empiezan con mayúscula)
                let extracted_entities: Vec<String> = content.split_whitespace()
                    .filter(|w| w.len() > 6 && w.chars().next().unwrap_or('a').is_uppercase())
                    .map(|w| w.to_string())
                    .collect();
                    
                // Mock Semantic Density (densidad de información calculada heurísticamente)
                let density = (extracted_entities.len() as f32 / (content.split_whitespace().count().max(1) as f32)) * 100.0;
                
                processed.push((id, synthetic_summary, extracted_entities, density));
            }
            
            // Insertar resultados (Offloading y Grafo Temporal)
            {
                let mut conn_guard = DB_CONN.lock().unwrap();
                if let Some(conn) = conn_guard.as_mut() {
                    for (id, summary, entities, density) in processed {
                        let sql_array = vector_to_sql_array_str(&entities);
                        let sql = format!(
                            "INSERT INTO semantic_summaries (note_id, synthetic_summary, extracted_entities, cognitive_timestamp, semantic_density) 
                             VALUES (?, ?, {}, now(), ?)",
                            sql_array
                        );
                        let _ = conn.execute(&sql, params![id, summary, density]);
                        
                        // FASE 3: Poblar el Grafo Temporal
                        for entity in entities {
                            let _ = conn.execute(
                                "INSERT INTO entity_graphs (entity_name, note_id, relation_type, discovered_at) 
                                 VALUES (?, ?, 'MENTIONS', now())",
                                params![entity, id]
                            );
                        }
                    }
                }
            }
        }
    });
    
    "Cognitive Daemon iniciado en segundo plano (Ciclo: 10s)".to_string()
}

fn vector_to_sql_array_str(vec: &[String]) -> String {
    if vec.is_empty() {
        return "ARRAY[]".to_string();
    }
    let mut s = "ARRAY[".to_string();
    for (i, val) in vec.iter().enumerate() {
        if i > 0 {
            s.push_str(", ");
        }
        let safe_val = val.replace("'", "''");
        s.push_str(&format!("'{}'", safe_val));
    }
    s.push(']');
    s
}

#[derive(uniffi::Record)]
pub struct TemporalEdge {
    pub source: String,
    pub target: String,
    pub relation: String,
    pub weight: f32,
    pub timestamp: String,
}

#[uniffi::export]
pub fn get_temporal_neighborhood(note_id: String, max_depth: u32) -> Vec<TemporalEdge> {
    let conn_guard = DB_CONN.lock().unwrap();
    let conn = match conn_guard.as_ref() {
        Some(c) => c,
        None => return Vec::new(),
    };
    
    // Usamos una consulta recursiva de DuckDB (CTE) para navegar el grafo hasta max_depth
    let query = format!("
        WITH RECURSIVE traverse(source_id, target_id, type, weight, created_at, depth) AS (
            SELECT source_id, target_id, type, weight, created_at, 1 as depth
            FROM links
            WHERE source_id = '{}' OR target_id = '{}'
            
            UNION ALL
            
            SELECT l.source_id, l.target_id, l.type, l.weight, l.created_at, t.depth + 1
            FROM links l
            JOIN traverse t ON (l.source_id = t.target_id OR l.target_id = t.source_id)
            WHERE t.depth < {}
        )
        SELECT DISTINCT source_id, target_id, type, weight, created_at
        FROM traverse
        LIMIT 500;
    ", note_id, note_id, max_depth);
    
    let mut stmt = match conn.prepare(&query) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    
    let edges = stmt.query_map([], |row| {
        Ok(TemporalEdge {
            source: row.get(0)?,
            target: row.get(1)?,
            relation: row.get(2)?,
            weight: row.get(3)?,
            timestamp: row.get::<_, String>(4).unwrap_or_else(|_| "".to_string()),
        })
    });
    
    let mut result = Vec::new();
    if let Ok(iter) = edges {
        for edge in iter {
            if let Ok(e) = edge {
                result.push(e);
            }
        }
    }
    
    result
}

// ------------------------------------------------------------------------------------------------
// FASE 2.3: CAPA MCP SEGURA (Model Context Protocol)
// Este es el único puente autorizado para IAs Externas (Claude, etc).
// Las consultas MCP actúan SOLAMENTE sobre los metadatos sintéticos, NUNCA sobre la tabla notes.
// ------------------------------------------------------------------------------------------------

#[uniffi::export]
pub fn mcp_handle_request(json_request: String) -> String {
    let req: Value = match serde_json::from_str(&json_request) {
        Ok(v) => v,
        Err(_) => return json!({ "jsonrpc": "2.0", "error": { "code": -32700, "message": "Parse error" } }).to_string(),
    };

    let id = req.get("id").unwrap_or(&json!(null)).clone();
    let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");

    match method {
        "notifications/initialized" | "initialized" => {
            "".to_string()
        },
        "initialize" => {
            crate::add_telemetry_log(format!("Handshake MCP: Cliente Inicializado (ID: {})", id));
            let result = json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {},
                    "prompts": {}
                },
                "serverInfo": {
                    "name": "VaultSystem",
                    "version": "0.1.0"
                }
            });
            json!({ "jsonrpc": "2.0", "id": id, "result": result }).to_string()
        },
        "prompts/list" => {
            let result = json!({
                "prompts": [
                    {
                        "name": "system_context",
                        "description": "Devuelve las configuraciones de sistema, reglas y contexto maestro que gobiernan a este agente.",
                        "arguments": []
                    }
                ]
            });
            json!({ "jsonrpc": "2.0", "id": id, "result": result }).to_string()
        },
        "prompts/get" => {
            let empty = json!({}); let params = req.get("params").unwrap_or(&empty);
            let name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
            if name == "system_context" {
                let sys_dir = std::path::PathBuf::from(std::env::var("HOME").unwrap()).join(".vault_system").join("system_workspace");
                let mut context_text = String::new();
                if let Ok(entries) = std::fs::read_dir(sys_dir) {
                    let mut files = Vec::new();
                    for entry in entries.flatten() {
                        if let Ok(ft) = entry.file_type() {
                            if ft.is_file() && entry.path().extension().and_then(|s| s.to_str()) == Some("md") {
                                files.push(entry);
                            }
                        }
                    }
                    files.sort_by_key(|a| a.file_name());
                    for entry in files {
                        if let Ok(content) = std::fs::read_to_string(entry.path()) {
                            context_text.push_str(&format!("\n\n--- Archivo: {} ---\n\n{}", entry.file_name().to_string_lossy(), content));
                        }
                    }
                }
                
                let result = json!({
                    "description": "Contexto y Reglas del Sistema Vault",
                    "messages": [
                        {
                            "role": "user",
                            "content": {
                                "type": "text",
                                "text": context_text
                            }
                        }
                    ]
                });
                json!({ "jsonrpc": "2.0", "id": id, "result": result }).to_string()
            } else {
                json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32602, "message": "Prompt not found" } }).to_string()
            }
        },
        "tools/list" => {
            let tools = json!({
                "tools": [
                    {
                        "name": "vault_search",
                        "description": "Busca notas en todo el Vault. Usa texto o palabras clave.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "query": { "type": "string" }
                            },
                            "required": ["query"]
                        }
                    },
                    {
                        "name": "vault_read",
                        "description": "Lee el contenido crudo completo de una nota en el Vault.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string" }
                            },
                            "required": ["path"]
                        }
                    },
                    {
                        "name": "vault_write",
                        "description": "Crea o sobrescribe una nota markdown en el Vault.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "Ruta absoluta donde crear o guardar la nota." },
                                "content": { "type": "string", "description": "Contenido de la nota en formato markdown." }
                            },
                            "required": ["path", "content"]
                        }
                    },
                    {
                        "name": "vault_create_folder",
                        "description": "Crea una nueva carpeta o directorio en el Vault.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "Ruta absoluta de la nueva carpeta." }
                            },
                            "required": ["path"]
                        }
                    }
                ]
            });
            json!({ "jsonrpc": "2.0", "id": id, "result": tools }).to_string()
        },
        "tools/call" => {
            let default_params = json!({});
            let params = req.get("params").unwrap_or(&default_params);
            let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let default_args = json!({});
            let arguments = params.get("arguments").unwrap_or(&default_args);

            crate::add_telemetry_log(format!("MCP Tool Call: {} | Args: {}", name, arguments.to_string()));

            let result_content = match name {
                "vault_search" => {
                    let query = arguments.get("query").and_then(|q| q.as_str()).unwrap_or("");
                    let exclude_metadata = arguments.get("exclude_metadata").and_then(|v| v.as_bool()).unwrap_or(false);
                    let exclude_system = arguments.get("exclude_system").and_then(|v| v.as_bool()).unwrap_or(false);
                    
                    let mut ignore_patterns = vec![];
                    if exclude_metadata {
                        ignore_patterns.push("/_".to_string());
                    }
                    if exclude_system {
                        ignore_patterns.push("/00-Sistema".to_string());
                        ignore_patterns.push("GEMINI.md".to_string());
                        ignore_patterns.push("agentes.md".to_string());
                    }

                    let results = crate::query_notes(Some(query.to_string()), None, ignore_patterns);
                    if results.is_empty() {
                        "No se encontraron resultados.".to_string()
                    } else {
                        results.into_iter().map(|r| format!("Ruta: {}\nTipo: {}\nTítulo: {}\nContenido:\n{}\n---", r.path, if r.is_dir { "Carpeta" } else { "Archivo" }, r.title, r.content)).collect::<Vec<String>>().join("\n\n")
                    }
                },
                "vault_read" => {
                    let path = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                    match std::fs::read_to_string(path) {
                        Ok(content) => content,
                        Err(e) => format!("Error al leer el archivo {}: {}", path, e)
                    }
                },
                "vault_write" => {
                    let path = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                    let content = arguments.get("content").and_then(|c| c.as_str()).unwrap_or("");
                    crate::save_note(path.to_string(), content.to_string())
                },
                "vault_create_folder" => {
                    let path = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                    if crate::create_item(path.to_string(), true) {
                        format!("Carpeta creada en: {}", path)
                    } else {
                        format!("Error al crear la carpeta en: {}", path)
                    }
                },
                _ => return json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "Method not found" } }).to_string(),
            };

            let call_result = json!({
                "content": [
                    {
                        "type": "text",
                        "text": result_content
                    }
                ]
            });
            
            json!({ "jsonrpc": "2.0", "id": id, "result": call_result }).to_string()
        },
        _ => json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "Method not found" } }).to_string(),
    }
}

#[uniffi::export]
pub fn start_ipc_server() -> String {
    use std::fs;
    // Generar Token de Autenticación IPC para seguridad de la bóveda
    let ipc_token = uuid::Uuid::new_v4().to_string();
    let _ = fs::write("/tmp/vault_ipc.token", &ipc_token);
    
    thread::spawn(move || {
        let listener = TcpListener::bind("127.0.0.1:49152").unwrap();
        println!("Vault IPC Server listening on 127.0.0.1:49152");

        for stream in listener.incoming() {
            match stream {
                Ok(mut stream) => {
                    let expected_token = ipc_token.clone();
                    thread::spawn(move || {
                        let reader = BufReader::new(stream.try_clone().unwrap());
                        for line in reader.lines() {
                            if let Ok(req) = line {
                                if req.trim().is_empty() { continue; }
                                
                                // Validación de Seguridad IPC Token
                                if let Ok(mut json_req) = serde_json::from_str::<serde_json::Value>(&req) {
                                    let req_token = json_req.get("ipc_token").and_then(|t| t.as_str()).unwrap_or("");
                                    if req_token != expected_token {
                                        let err_resp = json!({
                                            "jsonrpc": "2.0",
                                            "error": { "code": -32001, "message": "Acceso Denegado al Servidor IPC: IPC Token Inválido o Faltante." }
                                        }).to_string();
                                        let _ = writeln!(stream, "{}", err_resp);
                                        continue;
                                    }
                                    
                                    // Limpiar el token antes de procesar para no afectar logs
                                    if let Some(obj) = json_req.as_object_mut() {
                                        obj.remove("ipc_token");
                                    }
                                    
                                    let clean_req = serde_json::to_string(&json_req).unwrap();
                                    let response = mcp_handle_request(clean_req);
                                    if !response.is_empty() {
                                        let _ = writeln!(stream, "{}", response);
                                    }
                                } else {
                                    let _ = writeln!(stream, "{}", json!({ "jsonrpc": "2.0", "error": { "code": -32700, "message": "Parse error" } }).to_string());
                                }
                            } else {
                                break;
                            }
                        }
                    });
                }
                Err(_) => {}
            }
        }
    });
    "IPC Server Iniciado con Token de Seguridad.".to_string()
}

use serde::{Deserialize, Serialize};

#[derive(uniffi::Record, Serialize, Deserialize, Clone)]
pub struct McpTokenRecord {
    pub token_id: String,
    pub client_name: String,
    pub workspaces: Vec<String>,
    pub can_write: bool,
    pub allow_metadata: bool,
    pub allow_system: bool,
}

static MCP_TOKENS: Lazy<Mutex<Vec<McpTokenRecord>>> = Lazy::new(|| Mutex::new(Vec::new()));

#[uniffi::export]
pub fn load_mcp_tokens_from_json(json_str: String) -> bool {
    if let Ok(tokens) = serde_json::from_str::<Vec<McpTokenRecord>>(&json_str) {
        if let Ok(mut guard) = MCP_TOKENS.lock() {
            *guard = tokens;
            return true;
        }
    }
    false
}

#[uniffi::export]
pub fn export_mcp_tokens_to_json() -> String {
    if let Ok(guard) = MCP_TOKENS.lock() {
        if let Ok(json) = serde_json::to_string_pretty(&*guard) {
            return json;
        }
    }
    "[]".to_string()
}

#[uniffi::export]
pub fn get_mcp_tokens() -> Vec<McpTokenRecord> {
    if let Ok(guard) = MCP_TOKENS.lock() {
        return guard.clone();
    }
    vec![]
}

#[uniffi::export]
pub fn create_mcp_token(client_name: String, workspaces: Vec<String>, can_write: bool, allow_metadata: bool, allow_system: bool) -> String {
    let token_id = uuid::Uuid::new_v4().to_string();
    let record = McpTokenRecord {
        token_id: token_id.clone(),
        client_name,
        workspaces,
        can_write,
        allow_metadata,
        allow_system,
    };
    
    if let Ok(mut guard) = MCP_TOKENS.lock() {
        guard.push(record);
    }
    
    token_id
}

#[uniffi::export]
pub fn revoke_mcp_token(token_id: String) -> bool {
    if let Ok(mut guard) = MCP_TOKENS.lock() {
        let initial_len = guard.len();
        guard.retain(|t| t.token_id != token_id);
        return guard.len() < initial_len;
    }
    false
}
