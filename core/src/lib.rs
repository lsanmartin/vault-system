use duckdb::{params, Connection, Result};
use std::sync::Mutex;
use std::time::Duration;
use serde_json::{json, Value};
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
            embedding FLOAT[]
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
        "tools/list" => {
            let tools = json!({
                "tools": [
                    {
                        "name": "get_semantic_summary",
                        "description": "Obtiene el resumen cognitivo generado por IA de una nota por su ID.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "note_id": { "type": "string" }
                            },
                            "required": ["note_id"]
                        }
                    },
                    {
                        "name": "search_semantic_summaries",
                        "description": "Busca conceptos clave en la memoria sintética del Vault.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "query": { "type": "string" }
                            },
                            "required": ["query"]
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

            let result_content = match name {
                "get_semantic_summary" => {
                    let note_id = arguments.get("note_id").and_then(|n| n.as_str()).unwrap_or("");
                    let mut summary = String::from("No encontrado");
                    
                    let conn_guard = DB_CONN.lock().unwrap();
                    if let Some(conn) = conn_guard.as_ref() {
                        let mut stmt = match conn.prepare("SELECT synthetic_summary FROM semantic_summaries WHERE note_id = ?") {
                            Ok(s) => s,
                            Err(_) => return json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32000, "message": "DB Error" } }).to_string(),
                        };
                        let mut rows = match stmt.query(params![note_id]) {
                            Ok(r) => r,
                            Err(_) => return json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32000, "message": "Query Error" } }).to_string(),
                        };
                        if let Ok(Some(row)) = rows.next() {
                            if let Ok(sum) = row.get::<_, String>(0) {
                                summary = sum;
                            }
                        }
                    }
                    
                    summary
                },
                "search_semantic_summaries" => {
                    let query = arguments.get("query").and_then(|q| q.as_str()).unwrap_or("");
                    let search_pattern = format!("%{}%", query);
                    let mut results = Vec::new();
                    
                    let conn_guard = DB_CONN.lock().unwrap();
                    if let Some(conn) = conn_guard.as_ref() {
                        let mut stmt = match conn.prepare("SELECT note_id, synthetic_summary FROM semantic_summaries WHERE synthetic_summary LIKE ? LIMIT 5") {
                            Ok(s) => s,
                            Err(_) => return json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32000, "message": "DB Error" } }).to_string(),
                        };
                        let mut rows = match stmt.query(params![search_pattern]) {
                            Ok(r) => r,
                            Err(_) => return json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32000, "message": "Query Error" } }).to_string(),
                        };
                        while let Ok(Some(row)) = rows.next() {
                            if let (Ok(n_id), Ok(sum)) = (row.get::<_, String>(0), row.get::<_, String>(1)) {
                                results.push(format!("ID: {} - {}", n_id, sum));
                            }
                        }
                    }
                    
                    if results.is_empty() {
                        "No se encontraron coincidencias en la memoria sintética.".to_string()
                    } else {
                        results.join("\n\n")
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
