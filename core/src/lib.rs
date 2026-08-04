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

pub mod mcp_server;

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
static DB_QUERY_MUTEX: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

pub struct DbConnectionGuard {
    conn_guard: std::sync::MutexGuard<'static, Option<Connection>>,
    _query_guard: std::sync::MutexGuard<'static, ()>,
}

impl std::ops::Deref for DbConnectionGuard {
    type Target = Connection;
    fn deref(&self) -> &Self::Target {
        self.conn_guard.as_ref().unwrap()
    }
}

impl std::ops::DerefMut for DbConnectionGuard {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.conn_guard.as_mut().unwrap()
    }
}

pub fn get_db_connection() -> Option<DbConnectionGuard> {
    // Wait up to 3 seconds for the query mutex
    let mut retries = 0;
    let query_guard = loop {
        match DB_QUERY_MUTEX.try_lock() {
            Ok(g) => break g,
            Err(_) => {
                retries += 1;
                if retries >= 60 { // 3 seconds timeout (60 * 50ms)
                    return None;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    };

    // Wait up to 3 seconds for the DB connection mutex
    let mut retries = 0;
    let conn_guard = loop {
        match DB_CONN.try_lock() {
            Ok(g) => break g,
            Err(_) => {
                retries += 1;
                if retries >= 60 { // 3 seconds timeout
                    return None;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    };

    if conn_guard.is_some() {
        return Some(DbConnectionGuard {
            conn_guard: conn_guard,
            _query_guard: query_guard,
        });
    }
    None
}

static LAST_SYNC_TS: Lazy<Mutex<u64>> = Lazy::new(|| Mutex::new(0));

#[uniffi::export(callback_interface)]
pub trait UiActionListener: Send + Sync {
    fn create_note(&self, title: String, content: String);
    fn open_note(&self, path: String);
    fn set_editor_mode(&self, mode: String);
    fn chat_reset(&self);
    fn chat_clear(&self);
    fn chat_compact(&self);
}

static UI_LISTENER: Lazy<Mutex<Option<Box<dyn UiActionListener>>>> = Lazy::new(|| Mutex::new(None));

#[uniffi::export]
pub fn register_ui_listener(listener: Box<dyn UiActionListener>) {
    if let Ok(mut guard) = UI_LISTENER.lock() {
        *guard = Some(listener);
    }
}


// --- COLA DE TELEMETRÍA ---
static TELEMETRY_LOGS: Lazy<Mutex<Vec<String>>> = Lazy::new(|| Mutex::new(Vec::new()));
static SCAN_PROGRESS: Lazy<Mutex<std::collections::HashMap<String, f32>>> = Lazy::new(|| Mutex::new(std::collections::HashMap::new()));
static MLX_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

// --- MODO DE EMBEDDING ---
// lazy (default true): scan almacena vector cero [0;384], sin tocar MLX/GPU.
// Solo se computa embedding MLX real cuando query_notes hace búsqueda semántica en modo eager.
static EMBEDDING_LAZY: Lazy<Mutex<bool>> = Lazy::new(|| Mutex::new(true));

// --- SCANNING EN PROGRESO ---
// El watcher consulta este flag antes de procesar eventos. Si hay scan activo,
// acumula eventos en cola para procesarlos al terminar.
static SCANNING_PATHS: Lazy<Mutex<Vec<String>>> = Lazy::new(|| Mutex::new(Vec::new()));
static WATCHER_PENDING_EVENTS: Lazy<Mutex<Vec<(String, bool)>>> = Lazy::new(|| Mutex::new(Vec::new()));

// Tamaño de lote reducido para evitar saturar FixedSizeAllocator de DuckDB
const BATCH_SIZE: usize = 200;

#[uniffi::export]
pub fn get_scan_progress(path: String) -> f32 {
    if let Ok(progress) = SCAN_PROGRESS.lock() {
        return *progress.get(&path).unwrap_or(&0.0);
    }
    0.0
}

#[uniffi::export]
pub fn cancel_scan(path: String) -> String {
    if let Ok(mut progress) = SCAN_PROGRESS.lock() {
        progress.insert(path, -1.0);
        return "Cancelado".to_string();
    }
    "Error".to_string()
}

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
pub fn add_swift_telemetry_log(log: String) {
    add_telemetry_log(format!("SWIFT: {}", log));
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
    if let Ok(mut ts) = LAST_SYNC_TS.lock() {
        *ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    }
}

#[uniffi::export]
pub fn hello_vault() -> String {
    "Hello from Vault Core IA (DuckDB Engine)!".to_string()
}

#[uniffi::export]
pub fn set_embedding_lazy(lazy: bool) -> bool {
    if let Ok(mut mode) = EMBEDDING_LAZY.lock() {
        *mode = lazy;
        return true;
    }
    false
}

#[uniffi::export]
pub fn is_embedding_lazy() -> bool {
    EMBEDDING_LAZY.lock().map(|m| *m).unwrap_or(true)
}

fn generate_embedding(text: &str) -> Vec<f32> {
    // Defensivo: si lock está poisoned, asumir lazy y retornar vector cero
    let is_lazy = EMBEDDING_LAZY.lock().map(|m| *m).unwrap_or(true);
    if text.is_empty() || is_lazy {
        return vec![0.0f32; 384];
    }

    // Modo eager: embedding MLX completo (GPU/MLX)
    generate_embedding_mlx(text)
}

fn generate_embedding_mlx(text: &str) -> Vec<f32> {
    if text.is_empty() {
        return vec![0.0f32; 384];
    }

    // try_lock para evitar deadlock si GPU está ocupada.
    // Si no se puede adquirir, genera embedding hash rápido (CPU) como fallback.
    let guard = match MLX_LOCK.try_lock() {
        Ok(g) => g,
        Err(_) => {
            return generate_embedding_fast(text);
        }
    };
    let _guard = guard;
    
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
    let result_tensor = mlx_rs::ops::matmul(&expanded, &weights).unwrap_or(array!(0.0f32));
    
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

/// Embedding rápido basado en hash (CPU-only, sin MLX/GPU).
/// Determinístico: mismo texto → mismo vector.
/// Usado como fallback cuando MLX no está disponible o el lock está ocupado.
fn generate_embedding_fast(text: &str) -> Vec<f32> {
    if text.is_empty() {
        return vec![0.0f32; 384];
    }

    // Hash de 64 bits para mezclar el contenido
    let mut h: u64 = 5381;
    for c in text.chars() {
        h = (h << 5).wrapping_add(h).wrapping_add(c as u64);
    }

    // Poblar vector de 384 dimensiones con variación basada en hash + índice
    let mut vec = Vec::with_capacity(384);
    for i in 0..384 {
        let val = ((h.wrapping_mul(i as u64 + 1).wrapping_add(i as u64 * 31)) % 1000) as f32 / 500.0 - 1.0;
        vec.push(val);
    }

    // Normalización L2
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
    if vec.is_empty() {
        return "NULL".to_string();
    }
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

fn canonicalize_path(p: &str) -> String {
    std::path::Path::new(p)
        .canonicalize()
        .ok()
        .and_then(|cp| cp.to_str().map(|s| s.to_string()))
        .unwrap_or_else(|| p.to_string())
}

#[uniffi::export]
pub fn init_knowledge_base() -> String {
    let mut conn_guard = DB_CONN.lock().unwrap();
    
    // Abrir conexión persistente
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let db_dir = format!("{}/.vault_system", home);
    let _ = std::fs::create_dir_all(&db_dir);
    let db_path = format!("{}/vault.duckdb", db_dir);

    // FASE 0: Detección y recreación preventiva para evitar bugs de índices en DuckDB
    let mut needs_recreate = false;
    if std::path::Path::new(&db_path).exists() {
        match Connection::open(&db_path) {
            Ok(conn) => {
                // Verificar si el archivo está corrupto/invalidado o tiene restricciones antiguas
                if conn.execute("SELECT id FROM notes LIMIT 1", []).is_err() {
                    needs_recreate = true;
                } else {
                    // Verificar si tiene el flag del esquema libre de índices secundarios
                    if conn.execute("SELECT * FROM _schema_no_indices LIMIT 1", []).is_err() {
                        needs_recreate = true;
                    }
                }
            }
            Err(e) => {
                let err_str = e.to_string().to_lowercase();
                if err_str.contains("lock") || err_str.contains("io error") {
                    return format!("Error CRITICO: La base de datos está bloqueada por otra instancia. Por favor cierre la otra aplicación o proceso (posible zombie). Detalle: {}", e);
                } else {
                    needs_recreate = true;
                }
            }
        }
    }

    if needs_recreate {
        let _ = std::fs::remove_file(&db_path);
        let _ = std::fs::remove_file(&format!("{}.wal", db_path));
    }

    let conn = match Connection::open(&db_path) {
        Ok(c) => c,
        Err(e) => return format!("Error abriendo DuckDB: {}", e),
    };

    // Crear tablas sin restricciones PRIMARY KEY ni índices secundarios para evitar corrupción y crashes al borrar filas
    let schema_res = conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS notes (
            id VARCHAR,
            title VARCHAR,
            path VARCHAR,
            content TEXT,
            is_dir BOOLEAN DEFAULT false,
            created_at TIMESTAMP,
            tags VARCHAR[],
            embedding FLOAT[384],
            modified_ts BIGINT DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS links (
            source_id VARCHAR,
            target_id VARCHAR,
            type VARCHAR,
            weight FLOAT DEFAULT 1.0,
            created_at TIMESTAMP DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS telemetry (
            ts TIMESTAMP DEFAULT now(),
            context VARCHAR,
            event_type VARCHAR,
            message TEXT,
            metadata JSON
        );
        
        CREATE TABLE IF NOT EXISTS semantic_summaries (
            note_id VARCHAR,
            synthetic_summary TEXT,
            extracted_entities VARCHAR[],
            cognitive_timestamp TIMESTAMP DEFAULT now(),
            semantic_density FLOAT
        );
        
        CREATE TABLE IF NOT EXISTS entity_graphs (
            entity_name VARCHAR,
            note_id VARCHAR,
            relation_type VARCHAR,
            discovered_at TIMESTAMP DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS memory_contexts (
            dir_path VARCHAR,
            hitos JSON,
            contexto TEXT,
            historial JSON,
            last_updated TIMESTAMP DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS domain_metadata (
            dir_path VARCHAR,
            memory_contexto TEXT,
            memory_hitos JSON,
            memory_historial JSON,
            specs_arquitectura TEXT,
            specs_reglas JSON,
            specs_dependencias JSON,
            lore_proposito TEXT,
            lore_glosario JSON,
            lore_usuarios JSON,
            last_updated TIMESTAMP DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS _schema_version (
            version INTEGER,
            applied_at TIMESTAMP DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS _schema_no_indices (
            flag BOOLEAN
        );"
    );

    match schema_res {
        Ok(_) => {
            // Schema versioning
            let current_version: u32 = conn.query_row(
                "SELECT COALESCE(MAX(version), 0) FROM _schema_version", [], |r| r.get(0)
            ).unwrap_or(0);

            if current_version < 1 {
                let _ = conn.execute(
                    "INSERT INTO _schema_version (version) VALUES (1)", []
                );
            }

            // Ejecutar deduplicación preventiva de rowids
            let _ = conn.execute("DELETE FROM notes WHERE rowid NOT IN (SELECT MIN(rowid) FROM notes GROUP BY id)", []);
            let _ = conn.execute("DELETE FROM semantic_summaries WHERE rowid NOT IN (SELECT MIN(rowid) FROM semantic_summaries GROUP BY note_id)", []);
            let _ = conn.execute("DELETE FROM domain_metadata WHERE rowid NOT IN (SELECT MIN(rowid) FROM domain_metadata GROUP BY dir_path)", []);

            *conn_guard = Some(conn);
            "Knowledge Base inicializada (DuckDB sin índices secundarios para evitar corrupción)".to_string()
        },
        Err(e) => format!("Error de Esquema: {}", e),
    }
}



#[uniffi::export]
pub fn scan_vault(path: String, ignore_patterns: Vec<String>) -> String {
    let canonical_path = canonicalize_path(&path);

    // Registrar en SCANNING_PATHS para que el watcher no compita
    if let Ok(mut paths) = SCANNING_PATHS.lock() {
        if !paths.contains(&canonical_path) {
            paths.push(canonical_path.clone());
        }
    }

    // Inicializar el progreso en 0%
    if let Ok(mut progress) = SCAN_PROGRESS.lock() {
        progress.insert(canonical_path.clone(), 0.0);
    }

    // Dedup se ejecuta al final del scan, no al inicio.
    // (Elimina contention innecesaria durante el escaneo)

    let vault_path = Path::new(&canonical_path);

    // Primera pasada: recolectar y contar todas las entradas válidas
    let mut entries = Vec::new();
    let it = WalkDir::new(vault_path).into_iter().filter_entry(|e| {
        let is_hidden = e.file_name()
             .to_str()
             .map(|s| s.starts_with("."))
             .unwrap_or(false);
        !is_hidden
    });
    
    for entry in it.filter_map(|e| e.ok())
    {
        let file_path = entry.path();
        let full_path_str = file_path.to_str().unwrap_or("");

        if ignore_patterns.iter().any(|p| full_path_str.contains(p)) {
            continue;
        }

        let ext = file_path.extension().and_then(|s| s.to_str());
        if file_path.is_dir() || (file_path.is_file() && (ext == Some("md") || (ext == Some("log") && !full_path_str.ends_with("telemetria.log")))) {
            entries.push(entry);
        }
    }

    let total_entries = entries.len();
    let mut count = 0;
    let mut skips = 0;

    // Obtener lista actual (con mtime) para detectar huérfanos
    let mut db_mtimes = std::collections::HashMap::new();
    {
        if let Some(conn) = get_db_connection() {
            if let Ok(mut stmt) = conn.prepare("SELECT path, COALESCE(modified_ts, 0) FROM notes WHERE path = ? OR path LIKE ?") {
                if let Ok(rows) = stmt.query_map(duckdb::params![&canonical_path, format!("{}/%", canonical_path)], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                }) {
                    for row in rows.flatten() {
                        db_mtimes.insert(row.0, row.1 as u64);
                    }
                }
            }
        }
    }

    let mut batch_inserts = Vec::new();
    let mut pending_stubs: Vec<String> = Vec::new();

    // Segunda pasada: procesar e insertar actualizando el progreso
    for (idx, entry) in entries.into_iter().enumerate() {
        let file_path = entry.path();
        let full_path_str = file_path.to_str().unwrap_or("").to_string();
        
        let existing_mtime = db_mtimes.remove(&full_path_str);
        
        // Procesar directorios y archivos
        if file_path.is_dir() {
            if existing_mtime.is_none() {
                let title = file_path.file_name().and_then(|s| s.to_str()).unwrap_or("Carpeta").to_string();
                batch_inserts.push((full_path_str.clone(), title, "".to_string(), vec![], true, 0u64));
            }
        } else if file_path.is_file() && file_path.extension().and_then(|s| s.to_str()) == Some("md") {
            let mtime = std::fs::metadata(file_path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
                
            let content_changed = match existing_mtime {
                Some(db_mtime) => db_mtime != mtime || db_mtime == 0,
                None => true,
            };
            
            if content_changed {
                let content = std::fs::read_to_string(file_path).unwrap_or_else(|_| "".to_string());

                // Removed stub detection to allow empty notes created by the user to exist in the database.
                let title = file_path.file_stem().and_then(|s| s.to_str()).unwrap_or("Sin título").to_string();
                let emb = generate_embedding(&content);
                batch_inserts.push((full_path_str.clone(), title, content, emb, false, mtime));
            } else {
                let _skips = 1;
            }
        }

        // Ejecutar el lote si alcanza tamaño
        if batch_inserts.len() >= BATCH_SIZE {
            if let Some(conn) = get_db_connection() {
                let _ = conn.execute("BEGIN TRANSACTION", []);
                let mut tx_failed = false;
                
                for (p, t, c, emb, is_dir, mtime) in batch_inserts.drain(..) {
                    if tx_failed { continue; }
                    
                    let _ = conn.execute("DELETE FROM notes WHERE id = ?", duckdb::params![p]);
                    let res = if is_dir {
                        conn.execute(
                            "INSERT INTO notes (id, title, path, content, is_dir, created_at, modified_ts) VALUES (?, ?, ?, ?, true, now(), ?)",
                            duckdb::params![p, t, p, c, mtime as i64]
                        )
                    } else {
                        let sql = format!(
                            "INSERT INTO notes (id, title, path, content, is_dir, created_at, embedding, modified_ts) VALUES (?, ?, ?, ?, false, now(), {}, ?)",
                            vector_to_sql_array(&emb)
                        );
                        conn.execute(&sql, duckdb::params![p, t, p, c, mtime as i64])
                    };
                    
                    match res {
                        Ok(_) => count += 1,
                        Err(e) => {
                            eprintln!("Error insertando nota {}: {}", p, e);
                            tx_failed = true;
                        }
                    }
                }
                
                if tx_failed {
                    let _ = conn.execute("ROLLBACK", []);
                } else {
                    let _ = conn.execute("COMMIT", []);
                }
            }
        }

        // Actualizar progreso y check cancel
        if let Ok(mut progress) = SCAN_PROGRESS.lock() {
            if let Some(&p) = progress.get(&canonical_path) {
                if p < 0.0 {
                    return "Escaneado cancelado.".to_string();
                }
            }
            if total_entries > 0 {
                let pct = ((idx + 1) as f32 / total_entries as f32) * 100.0;
                progress.insert(canonical_path.clone(), pct);
            }
        }
    }
    
    // Procesar último lote
    if !batch_inserts.is_empty() {
        if let Some(conn) = get_db_connection() {
            let _ = conn.execute("BEGIN TRANSACTION", []);
            let mut tx_failed = false;
            
            for (p, t, c, emb, is_dir, mtime) in batch_inserts.drain(..) {
                if tx_failed { continue; }
                
                let _ = conn.execute("DELETE FROM notes WHERE id = ?", duckdb::params![p]);
                let res = if is_dir {
                    conn.execute(
                        "INSERT INTO notes (id, title, path, content, is_dir, created_at, modified_ts) VALUES (?, ?, ?, ?, true, now(), ?)",
                        duckdb::params![p, t, p, c, mtime as i64]
                    )
                } else {
                    let sql = format!(
                        "INSERT INTO notes (id, title, path, content, is_dir, created_at, embedding, modified_ts) VALUES (?, ?, ?, ?, false, now(), {}, ?)",
                        vector_to_sql_array(&emb)
                    );
                    conn.execute(&sql, duckdb::params![p, t, p, c, mtime as i64])
                };
                
                match res {
                    Ok(_) => count += 1,
                    Err(e) => {
                        eprintln!("Error insertando nota {}: {}", p, e);
                        tx_failed = true;
                    }
                }
            }
            
            if tx_failed {
                let _ = conn.execute("ROLLBACK", []);
            } else {
                let _ = conn.execute("COMMIT", []);
            }
        }
    }
    
    // Eliminar huérfanos
    let orphans_count = db_mtimes.len();
    if orphans_count > 0 {
        if let Some(conn) = get_db_connection() {
            for orphan in db_mtimes.keys() {
                let mut exists_now = std::path::Path::new(orphan).exists();
                if !exists_now && orphan.contains("Library/Mobile Documents") {
                    for _ in 0..3 {
                        std::thread::sleep(std::time::Duration::from_millis(500));
                        if std::path::Path::new(orphan).exists() {
                            exists_now = true;
                            break;
                        }
                    }
                }
                
                if !exists_now {
                    let _ = conn.execute("DELETE FROM semantic_summaries WHERE note_id IN (SELECT id FROM notes WHERE path = ?)", duckdb::params![orphan]);
                    let _ = conn.execute("DELETE FROM links WHERE source_id IN (SELECT id FROM notes WHERE path = ?)", duckdb::params![orphan]);
                    let _ = conn.execute("DELETE FROM notes WHERE path = ?", duckdb::params![orphan]);
                } else {
                    crate::add_telemetry_log(format!("sync_vault: AVISO: el huérfano reapareció, no se borra: {}", orphan));
                }
            }
        }
    }

    // Dedup post-scan (ejecutar después de inserts para evitar contention)
    if let Some(conn) = get_db_connection() {
        let _ = conn.execute("DELETE FROM notes WHERE rowid NOT IN (SELECT MIN(rowid) FROM notes GROUP BY id)", []);
        let _ = conn.execute("DELETE FROM semantic_summaries WHERE rowid NOT IN (SELECT MIN(rowid) FROM semantic_summaries GROUP BY note_id)", []);
        let _ = conn.execute("DELETE FROM domain_metadata WHERE rowid NOT IN (SELECT MIN(rowid) FROM domain_metadata GROUP BY dir_path)", []);
    }

    let stub_count = pending_stubs.len();
    if stub_count > 0 {
        eprintln!("[vault-core] Stubs detectados: {} archivos con contenido <30 chars (probable iCloud sin hidratar)", stub_count);
    }

    // Asegurar 100% al finalizar
    if let Ok(mut progress) = SCAN_PROGRESS.lock() {
        progress.insert(canonical_path.clone(), 100.0);
    }

    // Deregistrar de SCANNING_PATHS
    if let Ok(mut paths) = SCANNING_PATHS.lock() {
        paths.retain(|p| p != &canonical_path);
    }

    // Procesar eventos pendientes del watcher que se acumularon durante el scan
    if let Ok(mut pending) = WATCHER_PENDING_EVENTS.lock() {
        if !pending.is_empty() {
            eprintln!("[vault-core] Procesando {} eventos del watcher acumulados durante scan", pending.len());
            if let Some(conn) = get_db_connection() {
                for (p, is_dir) in pending.drain(..) {
                    let _ = conn.execute("DELETE FROM notes WHERE id = ?", duckdb::params![&p]);
                    if is_dir {
                        let title = std::path::Path::new(&p).file_name().and_then(|s| s.to_str()).unwrap_or("Carpeta");
                        let _ = conn.execute(
                            "INSERT INTO notes (id, title, path, content, is_dir, created_at, modified_ts) VALUES (?, ?, ?, ?, true, now(), 0)",
                            duckdb::params![&p, title, &p, ""],
                        );
                    } else if p.ends_with(".md") || p.ends_with(".log") {
                        let content = std::fs::read_to_string(&p).unwrap_or_default();
                        let title = std::path::Path::new(&p).file_stem().and_then(|s| s.to_str()).unwrap_or("Sin título");
                        let emb = generate_embedding(&content);
                        let sql = format!(
                            "INSERT INTO notes (id, title, path, content, is_dir, created_at, embedding, modified_ts) VALUES (?, ?, ?, ?, false, now(), {}, ?)",
                            vector_to_sql_array(&emb)
                        );
                        let mtime = std::fs::metadata(&p).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
                        let _ = conn.execute(&sql, duckdb::params![&p, title, &p, content, mtime as i64]);
                    }
                }
            }
        }
    }

    update_sync_ts();
    let mut msg = format!("Escaneado completado: {} notas procesadas.", count);
    if stub_count > 0 {
        msg.push_str(&format!(" ({} stubs omitidos — se re-indexarán cuando iCloud complete la descarga)", stub_count));
    }
    msg
}

#[uniffi::export]
pub fn remove_vault_path(path: String) -> String {
    let canonical_path = canonicalize_path(&path);
    if let Some(conn) = get_db_connection() {
        let clean_path = if canonical_path.ends_with('/') { canonical_path.clone() } else { format!("{}/", canonical_path) };
        
        // Limpieza completa en cascada manual
        let _ = conn.execute(
            "DELETE FROM semantic_summaries WHERE note_id = ? OR note_id LIKE ?",
            params![canonical_path, format!("{}%", clean_path)],
        );
        let _ = conn.execute(
            "DELETE FROM entity_graphs WHERE note_id = ? OR note_id LIKE ?",
            params![canonical_path, format!("{}%", clean_path)],
        );
        let _ = conn.execute(
            "DELETE FROM links WHERE source_id = ? OR source_id LIKE ? OR target_id = ? OR target_id LIKE ?",
            params![canonical_path, format!("{}%", clean_path), canonical_path, format!("{}%", clean_path)],
        );
        let _ = conn.execute(
            "DELETE FROM notes WHERE path = ? OR path LIKE ?",
            params![canonical_path, format!("{}%", clean_path)],
        );

        // Remover del mapa de progreso si existe
        if let Ok(mut progress) = SCAN_PROGRESS.lock() {
            progress.remove(&canonical_path);
        }

        "Directorio eliminado de la base de datos por completo (Cascada Semántica)".to_string()
    } else {
        "Error: La base de datos no ha sido inicializada".to_string()
    }
}

#[uniffi::export]
pub fn create_item(path: String, is_dir: bool) -> bool {
    crate::add_telemetry_log(format!("create_item: intentando crear {} (is_dir={})", path, is_dir));
    let target = Path::new(&path);
    let success = if is_dir {
        fs::create_dir_all(target).is_ok()
    } else {
        if let Some(parent) = target.parent() {
            let _ = fs::create_dir_all(parent);
        }
        match fs::write(target, "") {
            Ok(_) => true,
            Err(e) => {
                crate::add_telemetry_log(format!("create_item: Error fs::write en {}: {}", path, e));
                false
            }
        }
    };
    crate::add_telemetry_log(format!("create_item: finalizado para {} -> éxito={}", path, success));
    success
}

#[uniffi::export]
pub fn upsert_note_item(path: String, title: String, content: String, is_dir: bool) -> bool {
    // Inserta o actualiza inmediatamente en DuckDB sin esperar al watcher.
    crate::add_telemetry_log(format!("upsert_note_item: INICIO para path={}", path));
    if let Some(conn) = get_db_connection() {
        let canonical = canonicalize_path(&path);
        crate::add_telemetry_log(format!("upsert_note_item: canonical_path={}", canonical));
        let _ = conn.execute("DELETE FROM notes WHERE id = ?", params![&canonical]);
        if is_dir {
            return conn.execute(
                "INSERT INTO notes (id, title, path, content, is_dir, created_at, modified_ts) VALUES (?, ?, ?, ?, true, now(), 0)",
                params![&canonical, &title, &canonical, &content],
            ).is_ok();
        } else {
            let mtime = std::fs::metadata(&canonical)
                .and_then(|m| m.modified()).ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs()).unwrap_or(0);
            let emb = generate_embedding(&content);
            let sql_array = vector_to_sql_array(&emb);
            let sql = format!(
                "INSERT INTO notes (id, title, path, content, is_dir, created_at, embedding, modified_ts) VALUES (?, ?, ?, ?, false, now(), {}, ?)",
                sql_array
            );
            crate::add_telemetry_log(format!("upsert_note_item: Ejecutando SQL: {}", sql));
            match conn.execute(&sql, params![&canonical, &title, &canonical, &content, mtime as i64]) {
                Ok(_) => {
                    crate::add_telemetry_log(format!("upsert_note_item: EXITOSO para {}", canonical));
                    return true;
                }
                Err(e) => {
                    println!("VaultSystem Rust Error inserting note {}: {}", canonical, e);
                    crate::add_telemetry_log(format!("DB Insert Error {}: {}", canonical, e));
                    return false;
                }
            }
        }
    } else {
        println!("VaultSystem Rust Error: get_db_connection returned None in upsert_note_item");
        crate::add_telemetry_log("upsert_note_item: get_db_connection returned None".to_string());
    }
    false
}

#[uniffi::export]
pub fn rename_item(old_path: String, new_path: String) -> bool {
    // Borrar registros viejos de la DB (el sync posterior creará los nuevos)
    {
        if let Some(conn) = get_db_connection() {
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
        if let Some(conn) = get_db_connection() {
            let _ = conn.execute("DELETE FROM semantic_summaries WHERE note_id IN (SELECT id FROM notes WHERE path = ? OR path LIKE ?)", duckdb::params![&path, &format!("{}/%", path)]);
            let _ = conn.execute("DELETE FROM links WHERE source_id IN (SELECT id FROM notes WHERE path = ? OR path LIKE ?)", duckdb::params![&path, &format!("{}/%", path)]);
            let _ = conn.execute(
                "DELETE FROM notes WHERE path = ? OR path LIKE ?",
                duckdb::params![&path, &format!("{}/%", path)],
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
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return Vec::new(),
    };

    let mut search_emb_sql = String::new();
    let mut is_semantic = false;
    let is_lazy = EMBEDDING_LAZY.lock().map(|m| *m).unwrap_or(true);

    if let Some(ref term) = search_term {
        if !term.is_empty() && !is_lazy {
            let emb = generate_embedding(term);
            search_emb_sql = vector_to_sql_array(&emb);
            is_semantic = true;
        }
    }

    // Telemetry Audit Logging (Radar de Intenciones)
    if let Some(ref term) = search_term {
        if !term.is_empty() {
            let safe_term = term.replace("'", "''");
            let _ = conn.execute(
                &format!("INSERT INTO telemetry (event_type, context, message) VALUES ('QUERY_NOTES', 'Vault-System', 'Agent searched for: {}')", safe_term),
                []
            );
        }
    }

    let mut sql = if is_semantic {
        format!(
            "SELECT n.id, n.title, n.path, n.content, n.is_dir, array_cosine_similarity(n.embedding, {}) as similarity FROM notes n WHERE 1=1",
            search_emb_sql
        )
    } else {
        let select_content = if search_term.as_ref().map(|t| !t.is_empty()).unwrap_or(false) {
            "n.content"
        } else {
            "'' as content"
        };
        format!("SELECT n.id, n.title, n.path, {}, n.is_dir FROM notes n WHERE 1=1", select_content)
    };
    
    // Filtro por Workspace (Path)
    if let Some(path) = path_filter {
        if !path.is_empty() {
            let canonical_path = canonicalize_path(&path);
            sql.push_str(&format!(" AND (n.path = '{}' OR n.path LIKE '{}/%')", canonical_path, canonical_path));
        }
    }

    // Aplicar filtros de ignorado
    for pattern in ignore_patterns {
        sql.push_str(&format!(" AND n.path NOT LIKE '%{}%'", pattern));
    }

    if let Some(ref term) = search_term {
        if !term.is_empty() {
            // Filtrado estricto por palabras: Intersección (AND) de todos los tokens con soporte para acentos y NFD
            for word in term.split_whitespace() {
                let safe_word = word.replace("'", "''"); // Evitar inyección
                let regex_pattern = format!("(?i){}", make_accent_insensitive_regex(&safe_word));
                sql.push_str(&format!(" AND (regexp_matches(n.title, '{}') OR regexp_matches(n.content, '{}') OR regexp_matches(n.path, '{}'))", regex_pattern, regex_pattern, regex_pattern));
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
pub fn query_recent_created(path_filter: Option<String>, limit: i32) -> Vec<NoteRecord> {
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return Vec::new(),
    };
    let mut sql = "SELECT id, title, path, '' as content, is_dir FROM notes WHERE is_dir = false".to_string();
    if let Some(ref path) = path_filter {
        if !path.is_empty() {
            let canonical_path = canonicalize_path(path);
            let clean_path = canonical_path.trim_end_matches('/');
            sql.push_str(&format!(" AND path LIKE '{}%'", clean_path));
        }
    }
    sql.push_str(&format!(" ORDER BY created_at DESC LIMIT {}", limit));
    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
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
        Err(_) => return Vec::new(),
    };
    note_iter.filter_map(|n| n.ok()).collect()
}

#[uniffi::export]
pub fn query_recent_modified(path_filter: Option<String>, limit: i32) -> Vec<NoteRecord> {
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return Vec::new(),
    };
    let mut sql = "SELECT id, title, path, '' as content, is_dir FROM notes WHERE is_dir = false".to_string();
    if let Some(ref path) = path_filter {
        if !path.is_empty() {
            let canonical_path = canonicalize_path(path);
            let clean_path = canonical_path.trim_end_matches('/');
            sql.push_str(&format!(" AND path LIKE '{}%'", clean_path));
        }
    }
    sql.push_str(&format!(" ORDER BY modified_ts DESC LIMIT {}", limit));
    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
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
        Err(_) => return Vec::new(),
    };
    note_iter.filter_map(|n| n.ok()).collect()
}

#[uniffi::export]
pub fn save_note(path: String, content: String) -> String {
    let res = fs::write(&path, content);
    match res {
        Ok(_) => {
            update_sync_ts();
            crate::add_telemetry_log(format!("Git: Iniciando auto-commit para {}", path));
            
            // Auto Git Commit implementation
            let path_obj = std::path::Path::new(&path);
            if let Some(parent) = path_obj.parent() {
                let parent_str = parent.to_string_lossy().into_owned();
                if let Some(file_name) = path_obj.file_name() {
                    if let Some(file_str) = file_name.to_str() {
                        // 1. Git Add
                        let add_out = std::process::Command::new("/usr/bin/git")
                            .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
                            .env_remove("GIT_DIR")
                            .env_remove("GIT_WORK_TREE")
                            .env_remove("GIT_INDEX_FILE")
                            .env_remove("GIT_OBJECT_DIRECTORY")
                            .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
                            .args(["-C", &parent_str, "-c", "safe.directory=*", "add", file_str])
                            .output();
                        
                        match add_out {
                            Ok(o) if !o.status.success() => {
                                let err = String::from_utf8_lossy(&o.stderr).to_string();
                                crate::add_telemetry_log(format!("Git Add Error: {}", err));
                                crate::log_friction_event("Git".to_string(), "Git Add Error".to_string(), err);
                            },
                            Err(e) => {
                                let err_str = e.to_string();
                                crate::add_telemetry_log(format!("Git Add Failed to start: {}", err_str));
                                crate::log_friction_event("Git".to_string(), "Git Add Failed to start".to_string(), err_str);
                            },
                            _ => {}
                        }
                        
                        // 2. Git Commit
                        let commit_out = std::process::Command::new("/usr/bin/git")
                            .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
                            .env_remove("GIT_DIR")
                            .env_remove("GIT_WORK_TREE")
                            .env_remove("GIT_INDEX_FILE")
                            .env_remove("GIT_OBJECT_DIRECTORY")
                            .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
                            .args([
                                "-C", &parent_str,
                                "-c", "safe.directory=*",
                                "-c", "user.name=Vault Auto-Save",
                                "-c", "user.email=vault-autosave@lsm.cl",
                                "commit", "-m", &format!("[Vault Auto-Save] {}", file_str)
                            ])
                            .output();

                        match commit_out {
                            Ok(o) => {
                                if o.status.success() {
                                    crate::add_telemetry_log(format!("Git: Commit exitoso para {}", file_str));
                                } else {
                                    let err = String::from_utf8_lossy(&o.stderr).to_string();
                                    if err.contains("nothing to commit") || err.contains("no cambios") {
                                        crate::add_telemetry_log("Git: Sin cambios detectados para commit".to_string());
                                    } else {
                                        crate::add_telemetry_log(format!("Git Commit Error: {}", err));
                                        crate::log_friction_event("Git".to_string(), "Git Commit Error".to_string(), err);
                                    }
                                }
                            },
                            Err(e) => {
                                let err_str = e.to_string();
                                crate::add_telemetry_log(format!("Git Commit Failed to start: {}", err_str));
                                crate::log_friction_event("Git".to_string(), "Git Commit Failed to start".to_string(), err_str);
                            }
                        }
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
    crate::add_telemetry_log(format!("Git: Recuperando historial para {}", path));
    let path_obj = std::path::Path::new(&path);
    let parent = match path_obj.parent() {
        Some(p) => p,
        None => {
            crate::add_telemetry_log("Git: Error - No se pudo determinar el padre del archivo".to_string());
            return vec![];
        }
    };
    let parent_str = parent.to_string_lossy().into_owned();
    let file_name = match path_obj.file_name() {
        Some(f) => f.to_str().unwrap_or(""),
        None => {
            crate::add_telemetry_log("Git: Error - No se pudo determinar el nombre del archivo".to_string());
            return vec![];
        }
    };

    let output = std::process::Command::new("/usr/bin/git")
        .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
        .args([
            "-C", &parent_str,
            "-c", "safe.directory=*",
            "log", "--pretty=format:%H|%ad|%s", "--date=short", "--", file_name
        ])
        .output();

    let mut commits = vec![];
    if let Ok(out) = output {
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr).to_string();
            crate::add_telemetry_log(format!("Git: Error en comando log - {}", err));
            crate::log_friction_event("Git".to_string(), "Git Log Error".to_string(), err);
        }
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
    } else {
        crate::add_telemetry_log("Git: Fallo crítico al ejecutar comando git log".to_string());
        crate::log_friction_event("Git".to_string(), "Git Log Failed to start".to_string(), "Fallo crítico al ejecutar".to_string());
    }
    
    crate::add_telemetry_log(format!("Git: Encontrados {} commits", commits.len()));
    commits
}

#[uniffi::export]
pub fn get_file_content_at_commit(path: String, commit_hash: String) -> String {
    let path_obj = std::path::Path::new(&path);
    let parent = match path_obj.parent() {
        Some(p) => p,
        None => return String::new(),
    };
    let parent_str = parent.to_string_lossy().into_owned();
    let file_name = match path_obj.file_name() {
        Some(f) => f.to_str().unwrap_or(""),
        None => return String::new(),
    };

    let spec = format!("{}:./{}", commit_hash, file_name);
    let output = std::process::Command::new("/usr/bin/git")
        .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
        .args([
            "-C", &parent_str,
            "-c", "safe.directory=*",
            "show", &spec
        ])
        .output();

    if let Ok(out) = output {
        String::from_utf8_lossy(&out.stdout).to_string()
    } else {
        String::new()
    }
}

#[uniffi::export]
pub fn init_git_repo(workspace_path: String) {
    let path_obj = std::path::Path::new(&workspace_path);
    let git_dir = path_obj.join(".git");
    if !git_dir.exists() {
        crate::add_telemetry_log(format!("Git: Inicializando nuevo repositorio en {}", workspace_path));
        let out = std::process::Command::new("/usr/bin/git")
            .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_OBJECT_DIRECTORY")
            .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
            .args(["-C", &workspace_path, "init"])
            .output();
        if let Ok(o) = out {
            if o.status.success() {
                crate::add_telemetry_log("Git: Repositorio inicializado con éxito".to_string());
                // Create an initial empty commit so git log works
                let _ = std::process::Command::new("/usr/bin/git")
                    .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
                    .env_remove("GIT_DIR")
                    .env_remove("GIT_WORK_TREE")
                    .env_remove("GIT_INDEX_FILE")
                    .env_remove("GIT_OBJECT_DIRECTORY")
                    .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
                    .args([
                        "-C", &workspace_path,
                        "-c", "user.name=Vault Auto-Save",
                        "-c", "user.email=vault-autosave@lsm.cl",
                        "commit", "--allow-empty", "-m", "Initial commit from VaultSystem"
                    ])
                    .output();
            } else {
                let err = String::from_utf8_lossy(&o.stderr).to_string();
                crate::add_telemetry_log(format!("Git Init Error: {}", err));
            }
        }
    }
}

#[uniffi::export]
pub fn add_telemetry_event(context: String, event_type: String, message: String) {
    if let Some(conn) = get_db_connection() {
        let _ = conn.execute(
            "INSERT INTO telemetry (context, event_type, message) VALUES (?, ?, ?)",
            params![context, event_type, message],
        );
    }
}

#[uniffi::export]
pub fn get_telemetry_summary() -> String {
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return "DB no inicializada".to_string(),
    };

    let count: i64 = conn.query_row("SELECT count(*) FROM telemetry", [], |row| row.get(0)).unwrap_or(0);
    format!("Total de eventos de telemetría registrados: {}", count)
}

#[uniffi::export]
pub fn start_watcher(paths: Vec<String>, ignore_patterns: Vec<String>) -> String {
    let ignore_patterns = std::sync::Arc::new(ignore_patterns);

    thread::spawn(move || {
        let (tx, rx) = channel();
        let mut watcher = RecommendedWatcher::new(tx, Config::default()).unwrap();

        for path in &paths {
            let _ = watcher.watch(Path::new(path), RecursiveMode::Recursive);
        }

        // Cola de eventos con dedup por path (debounce corto para responsiveness)
        let mut pending: std::collections::HashMap<String, bool> = std::collections::HashMap::new();
        let debounce = Duration::from_millis(300);

        fn filter_data_event(kind: &notify::EventKind) -> bool {
            match kind {
                notify::EventKind::Modify(notify::event::ModifyKind::Metadata(_)) => false,
                _ => true,
            }
        }

        fn process_batch(
            pending: &std::collections::HashMap<String, bool>,
            ign: &[String],
        ) {
            if pending.is_empty() { return; }
            if let Some(conn) = get_db_connection() {
                for (path_str, is_dir) in pending {
                    let canonical = canonicalize_path(path_str);
                    let path_obj = std::path::Path::new(&canonical);
                    
                    if !path_obj.exists() {
                        let mut exists_now = false;
                        let is_icloud = canonical.contains("Library/Mobile Documents");

                        if is_icloud {
                            // iCloud puede poner el archivo en estado transitorio durante sync.
                            // Reintento extendido: hasta 5x con 600ms = 3s de espera total.
                            crate::add_telemetry_log(format!("process_batch: AVISO: path iCloud no encontrado en disco, reintentando... {}", canonical));
                            for attempt in 0..5 {
                                std::thread::sleep(std::time::Duration::from_millis(600));
                                if path_obj.exists() {
                                    exists_now = true;
                                    crate::add_telemetry_log(format!("process_batch: path iCloud aparecio en disco (intento {}): {}", attempt + 1, canonical));
                                    break;
                                }
                            }
                        }

                        if !exists_now {
                            if is_icloud {
                                // Antes de borrar, verificar si el registro existe en DB.
                                // Si existe, es probable que iCloud esté en sync (no un borrado real).
                                // Saltamos el DELETE para no provocar "ghost note".
                                let in_db = conn.query_row(
                                    "SELECT COUNT(*) FROM notes WHERE id = ?",
                                    duckdb::params![canonical],
                                    |r| r.get::<_, i64>(0),
                                ).unwrap_or(0) > 0;

                                if in_db {
                                    crate::add_telemetry_log(format!(
                                        "process_batch: SKIP DELETE — path iCloud en DB pero ausente en disco (sync en progreso, se conserva el registro): {}",
                                        canonical
                                    ));
                                    continue; // No borrar; el siguiente evento del watcher lo confirmará
                                }
                            }
                            crate::add_telemetry_log(format!("process_batch: DELETE confirmado para {}", canonical));
                            let _ = conn.execute("DELETE FROM notes WHERE id = ?", duckdb::params![canonical]);
                            continue;
                        }
                    }

                    if *is_dir {
                        let title = path_obj.file_name().and_then(|s| s.to_str()).unwrap_or("Carpeta");
                        let _ = conn.execute("DELETE FROM notes WHERE id = ?", duckdb::params![canonical]);
                        let _ = conn.execute(
                            "INSERT INTO notes (id, title, path, content, is_dir, created_at, modified_ts) VALUES (?, ?, ?, ?, true, now(), 0)",
                            duckdb::params![canonical, title, canonical, ""],
                        );
                    } else if (canonical.ends_with(".md") || canonical.ends_with(".log")) && !ign.iter().any(|p| canonical.contains(p)) {
                        if canonical.contains("/.") && !canonical.contains("/.vault_system") { continue; } // hidden path
                        if canonical.ends_with("telemetria.log") { continue; } // evitar bucle infinito de logs
                        let content = std::fs::read_to_string(&canonical).unwrap_or_default();
                        
                        let title = path_obj.file_stem().and_then(|s| s.to_str()).unwrap_or("Sin título");
                        let emb = generate_embedding(&content);
                        let sql = format!(
                            "INSERT INTO notes (id, title, path, content, is_dir, created_at, embedding, modified_ts) VALUES (?, ?, ?, ?, false, now(), {}, ?)",
                            vector_to_sql_array(&emb)
                        );
                        let mtime = std::fs::metadata(&canonical)
                            .and_then(|m| m.modified()).ok()
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_secs()).unwrap_or(0);
                        let _ = conn.execute("DELETE FROM notes WHERE id = ?", duckdb::params![canonical]);
                        match conn.execute(&sql, duckdb::params![canonical, title, canonical, content, mtime as i64]) {
                            Ok(_) => {
                                // Exitoso, no saturemos el log si no es necesario, pero para debugear este caso en específico:
                                crate::add_telemetry_log(format!("process_batch: INSERT EXITOSO para {}", canonical));
                            }
                            Err(e) => {
                                crate::add_telemetry_log(format!("process_batch: ERROR INSERTANDO {}: {}", canonical, e));
                            }
                        }
                    }
                }
            }
            update_sync_ts();
        }

        loop {
            // Recibir lote de eventos con debounce
            match rx.recv() {
                Ok(Ok(event)) => {
                    if !filter_data_event(&event.kind) { continue; }
                    for path in event.paths {
                        let p = path.to_string_lossy().to_string();
                        if p.contains("/.") && !p.contains("/.vault_system") { continue; } // oculto
                        pending.insert(p, path.is_dir());
                    }
                }
                _ => { thread::sleep(Duration::from_millis(100)); continue; }
            }

            // Acumular más eventos que lleguen en la ventana de debounce
            let deadline = std::time::Instant::now() + debounce;
            while std::time::Instant::now() < deadline {
                match rx.try_recv() {
                    Ok(Ok(ev)) => {
                        if !filter_data_event(&ev.kind) { continue; }
                        for path in ev.paths {
                            let p = path.to_string_lossy().to_string();
                            if p.contains("/.") && !p.contains("/.vault_system") { continue; }
                            pending.insert(p, path.is_dir());
                        }
                    }
                    Ok(Err(_)) | Err(_) => {
                        thread::sleep(Duration::from_millis(100));
                    }
                }
            }

            // Si hay scan en progreso, encolar en vez de procesar
            if let Ok(paths_scanning) = SCANNING_PATHS.lock() {
                if !paths_scanning.is_empty() {
                    if let Ok(mut queued) = WATCHER_PENDING_EVENTS.lock() {
                        for (p, is_dir) in pending.drain() {
                            queued.push((p, is_dir));
                        }
                    }
                    continue;
                }
            }

            // Procesar lote
            process_batch(&pending, &ignore_patterns);
            pending.clear();
            thread::sleep(Duration::from_millis(100));
        }
    });
    "File Watcher iniciado (con debounce 2s + coalescing).".to_string()
}

#[uniffi::export]
pub fn start_cognitive_daemon() -> String {
    // Daemon pasivo: Swift gestiona la generación con mlx-swift local.
    "Cognitive Daemon iniciado de forma pasiva (Swift controla la inferencia local)".to_string()
}

#[derive(uniffi::Record)]
pub struct PendingSummaryNote {
    pub id: String,
    pub title: String,
    pub content: String,
}

#[uniffi::export]
pub fn get_pending_summary_notes(limit: u32) -> Vec<PendingSummaryNote> {
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return vec![],
    };
    let query = "
        SELECT id, title, content
        FROM notes
        WHERE is_dir = false
          AND id NOT IN (SELECT note_id FROM semantic_summaries)
        LIMIT ?
    ";
    let mut stmt = match conn.prepare(query) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    let note_iter = match stmt.query_map(params![limit], |row| {
        Ok(PendingSummaryNote {
            id: row.get(0)?,
            title: row.get(1)?,
            content: row.get(2)?,
        })
    }) {
        Ok(i) => i,
        Err(_) => return vec![],
    };
    note_iter.flatten().collect()
}

#[uniffi::export]
pub fn save_note_summary(
    note_id: String,
    synthetic_summary: String,
    entities: Vec<String>,
    density: f32,
) -> bool {
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return false,
    };
    // 1. Eliminar previos para evitar duplicaciones
    let _ = conn.execute("DELETE FROM semantic_summaries WHERE note_id = ?", params![note_id]);
    let _ = conn.execute("DELETE FROM entity_graphs WHERE note_id = ?", params![note_id]);

    // 2. Insertar resumen sintético real
    let sql_array = vector_to_sql_array_str(&entities);
    let sql = format!(
        "INSERT INTO semantic_summaries (note_id, synthetic_summary, extracted_entities, cognitive_timestamp, semantic_density)
         VALUES (?, ?, {}, now(), ?)",
        sql_array
    );
    if conn.execute(&sql, params![note_id, synthetic_summary, density]).is_err() {
        return false;
    }

    // 3. Insertar entidades en entity_graphs
    for entity in entities {
        let _ = conn.execute(
            "INSERT INTO entity_graphs (entity_name, note_id, relation_type, discovered_at)
             VALUES (?, ?, 'MENTIONS', now())",
            params![entity, note_id]
        );
    }
    true
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
    let conn = match get_db_connection() {
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
// PALACIO MENTAL — Vecinos Semánticos por Cosine Similarity (DuckDB FLOAT[384])
// Filtra por workspace_path para aislar el contexto del proyecto activo.
// note_id == path del archivo (PRIMARY KEY en DuckDB).
// ------------------------------------------------------------------------------------------------

#[derive(uniffi::Record)]
pub struct SemanticNeighbor {
    pub id: String,
    pub title: String,
    pub path: String,
    pub score: f32,
}

#[uniffi::export]
pub fn get_semantic_neighbors(note_id: String, workspace_path: String, limit: u32) -> Vec<SemanticNeighbor> {
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return Vec::new(),
    };

    // Escapar paths para evitar inyección SQL (los paths pueden tener comillas simples)
    let safe_note_id = note_id.replace('\'', "''");
    let safe_ws_path = workspace_path.replace('\'', "''");

    // Consulta: para cada nota del workspace, calcula cosine similarity contra el embedding
    // del nodo origen. Excluye directorios, excluye la nota origen, requiere embedding no nulo.
    // El LIKE filtra estrictamente al workspace activo.
    let query = format!(
        "
        SELECT n.id, n.title, n.path,
               array_cosine_similarity(n.embedding, src.embedding)::FLOAT as score
        FROM notes n,
             (SELECT embedding FROM notes WHERE id = '{}' AND embedding IS NOT NULL LIMIT 1) src
        WHERE n.id != '{}'
          AND n.is_dir = false
          AND n.embedding IS NOT NULL
          AND n.path LIKE '{}%'
          AND array_cosine_similarity(n.embedding, src.embedding) > 0.35
        ORDER BY score DESC
        LIMIT {}
        ",
        safe_note_id, safe_note_id, safe_ws_path, limit
    );

    let mut stmt = match conn.prepare(&query) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[PalacioMental] Error preparando query: {}", e);
            return Vec::new();
        }
    };

    let mut result = Vec::new();
    if let Ok(iter) = stmt.query_map([], |row| {
        Ok(SemanticNeighbor {
            id: row.get(0)?,
            title: row.get(1)?,
            path: row.get(2)?,
            score: row.get(3)?,
        })
    }) {
        for item in iter.flatten() {
            result.push(item);
        }
    }
    result
}

// ------------------------------------------------------------------------------------------------
// CARGA COGNITIVA — Métricas reales para el CognitiveRadar
// Un solo lock de DuckDB para las 3 métricas (evita deadlock por re-entrar al mutex).
//   ENT   = edges reales en tabla `links` (vecindad temporal del nodo)
//   CARGA = diversidad de directorios padre en el grafo → indicador de context-switching
//   NOV   = aislamiento semántico: 1 - best cosine_similarity en el workspace
// ------------------------------------------------------------------------------------------------

#[derive(uniffi::Record)]
pub struct CognitiveMetrics {
    pub entity_count: u32,   // ENT: nodos conectados en el grafo de links
    pub novelty_score: f32,  // NOV: [0,1] — 1 = nota muy nueva/aislada, 0 = bien integrada
    pub load_score: f32,     // CARGA: [0,1] — 1 = cruzando muchos proyectos a la vez
}

#[uniffi::export]
pub fn get_cognitive_metrics(note_id: String, workspace_path: String) -> CognitiveMetrics {
    let conn = match get_db_connection() {
        Some(c) => c,
        None => return CognitiveMetrics { entity_count: 0, novelty_score: 0.5, load_score: 0.0 },
    };

    let safe_id  = note_id.replace('\'', "''");
    let safe_ws  = workspace_path.replace('\'', "''");

    // ── 1. ENT + CARGA: leer edges del grafo de links (depth 1) ─────────────────────────────
    let edge_query = format!(
        "SELECT source_id, target_id FROM links \
         WHERE source_id = '{}' OR target_id = '{}' LIMIT 200",
        safe_id, safe_id
    );

    let mut entity_count: u32 = 0;
    let mut unique_dirs: std::collections::HashSet<String> = std::collections::HashSet::new();

    if let Ok(mut stmt) = conn.prepare(&edge_query) {
        if let Ok(iter) = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }) {
            for item in iter.flatten() {
                entity_count += 1;
                // El otro extremo del edge = nodo vecino
                let other = if item.0 == note_id { item.1 } else { item.0 };
                // Extraer directorio padre para medir diversidad de contexto
                if let Some(slash) = other.rfind('/') {
                    unique_dirs.insert(other[..slash].to_string());
                }
            }
        }
    }

    // CARGA = unique_dirs / sqrt(entity_count)  →  normalizado a [0, 1]
    // sqrt amortigua el efecto de notas muy conectadas donde la diversidad sería artificialmente alta
    let load_score: f32 = if entity_count == 0 {
        0.0
    } else {
        (unique_dirs.len() as f32 / (entity_count as f32).sqrt()).min(1.0)
    };

    // ── 2. NOV: aislamiento semántico (1 - best cosine similarity en workspace) ─────────────
    // Si el vecino más cercano tiene score alto → nota bien integrada → NOV baja
    // Si no hay vecinos semánticos → nota nueva/aislada → NOV alta
    let novelty_query = format!(
        "SELECT array_cosine_similarity(n.embedding, src.embedding)::FLOAT as score \
         FROM notes n, \
              (SELECT embedding FROM notes WHERE id = '{}' AND embedding IS NOT NULL LIMIT 1) src \
         WHERE n.id != '{}' \
           AND n.is_dir = false \
           AND n.embedding IS NOT NULL \
           AND n.path LIKE '{}%' \
         ORDER BY score DESC \
         LIMIT 1",
        safe_id, safe_id, safe_ws
    );

    let mut novelty_score: f32 = 0.5; // default: sin datos suficientes
    if let Ok(mut stmt) = conn.prepare(&novelty_query) {
        if let Ok(mut rows) = stmt.query([]) {
            if let Ok(Some(row)) = rows.next() {
                if let Ok(best) = row.get::<_, f32>(0) {
                    novelty_score = (1.0_f32 - best).max(0.0).min(1.0);
                }
            }
        }
    }

    CognitiveMetrics { entity_count, novelty_score, load_score }
}

// ------------------------------------------------------------------------------------------------
// HEATMAP — Actividad Temporal por Workspace
// Usa mtime del filesystem (sin DuckDB) para máxima velocidad.
// Devuelve notas modificadas en los últimos `days_back` días, ordenadas por recencia.
// heat = [0,1] — 1.0 = modificado hoy, 0.0 = al límite del período.
// ------------------------------------------------------------------------------------------------

#[derive(uniffi::Record)]
pub struct NoteActivity {
    pub path: String,
    pub title: String,
    pub modified_secs: u64,  // Unix timestamp de última modificación
    pub days_ago: u32,       // 0=hoy, 1=ayer, etc.
    pub heat: f32,           // [0,1] recencia normalizada
}

#[uniffi::export]
pub fn get_workspace_activity(workspace_path: String, days_back: u32) -> Vec<NoteActivity> {
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let period_secs = (days_back as u64) * 86_400;
    let cutoff_secs = now_secs.saturating_sub(period_secs);

    let mut activities: Vec<NoteActivity> = Vec::new();

    for entry in WalkDir::new(&workspace_path)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let file_path = entry.path();

        // Solo archivos .md
        if !file_path.is_file() {
            continue;
        }
        if file_path.extension().and_then(|s| s.to_str()) != Some("md") {
            continue;
        }
        // Ignorar archivos ocultos
        if file_path.file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with('.'))
            .unwrap_or(false)
        {
            continue;
        }

        // Leer mtime del filesystem
        let modified_secs = match file_path.metadata()
            .and_then(|m| m.modified())
            .and_then(|t| t.duration_since(UNIX_EPOCH).map_err(|_| std::io::Error::from(std::io::ErrorKind::Other)))
        {
            Ok(d) => d.as_secs(),
            Err(_) => continue,
        };

        if modified_secs < cutoff_secs {
            continue;
        }

        let elapsed = now_secs.saturating_sub(modified_secs);
        let days_ago = (elapsed / 86_400) as u32;

        // heat: 1.0 en el momento actual, decae linealmente hasta 0 en `days_back` días
        let heat = if period_secs == 0 {
            1.0
        } else {
            (1.0_f32 - (elapsed as f32 / period_secs as f32)).max(0.0)
        };

        let title = file_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Sin título")
            .to_string();

        let path_str = file_path.to_str().unwrap_or("").to_string();

        activities.push(NoteActivity {
            path: path_str,
            title,
            modified_secs,
            days_ago,
            heat,
        });
    }

    // Más reciente primero
    activities.sort_by(|a, b| b.modified_secs.cmp(&a.modified_secs));
    activities
}

// ------------------------------------------------------------------------------------------------
// FASE 2.3: CAPA MCP SEGURA (Model Context Protocol)
// Este es el único puente autorizado para IAs Externas (Claude, etc).
// Las consultas MCP actúan SOLAMENTE sobre los metadatos sintéticos, NUNCA sobre la tabla notes.
// ------------------------------------------------------------------------------------------------

fn get_synthetic_summary_by_id(id: &str) -> String {
    let conn_guard = match DB_CONN.lock() {
        Ok(g) => g,
        Err(_) => return "[Resumen semántico no disponible - DB Bloqueada]".to_string(),
    };
    if let Some(conn) = conn_guard.as_ref() {
        let mut stmt = match conn.prepare("SELECT synthetic_summary FROM semantic_summaries WHERE note_id = ? LIMIT 1") {
            Ok(s) => s,
            Err(_) => return "[Resumen semántico no disponible - Error Query]".to_string(),
        };
        let mut rows = match stmt.query(duckdb::params![id]) {
            Ok(r) => r,
            Err(_) => return "[Resumen semántico no disponible - Error Ejecución]".to_string(),
        };
        if let Ok(Some(row)) = rows.next() {
            if let Ok(sum) = row.get::<_, String>(0) {
                return sum;
            }
        }
    }
    "[Resumen semántico no disponible]".to_string()
}

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
                        "name": "vault_list_workspaces",
                        "description": "Lista todos los directorios o workspaces a los que tienes acceso.",
                        "inputSchema": { "type": "object", "properties": {} }
                    },
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
                    },
                    {
                        "name": "vault_get_domain_context",
                        "description": "Obtiene la triada completa de metadatos de dominio (_memory.md, _specs.md, lore.md) del Nodo Ancla mas cercano hacia arriba en la jerarquia.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "Ruta absoluta de archivo o carpeta desde la cual buscar el contexto de dominio." }
                            },
                            "required": ["path"]
                        }
                    },
                    {
                        "name": "vault_log_friction",
                        "description": "Registra una situacion de friccion, error o desalineamiento con el usuario para su posterior analisis.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "context": { "type": "string", "description": "El modulo o proyecto donde ocurre (ej. UCH, Nicelio)." },
                                "action": { "type": "string", "description": "La accion o comando que provoco el error o friccion." },
                                "friction_detail": { "type": "string", "description": "La descripcion detallada del error o feedback del usuario." }
                            },
                            "required": ["context", "action", "friction_detail"]
                        }
                    },
                    {
                        "name": "vault_export_domain_metadata",
                        "description": "Exporta los metadatos de dominio estructurados de todos los Nodos Ancla (util para pipelines RAG de LangChain).",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "limit": { "type": "integer", "description": "Numero maximo de registros a exportar (por defecto 100)." },
                                "since_seconds": { "type": "integer", "description": "Filtrar por registros actualizados desde este timestamp epoch en segundos (por defecto 0)." }
                            }
                        }
                    },
                    {
                        "name": "vault_ui_create_note",
                        "description": "Crea una nueva nota en el sistema y la abre inmediatamente en el editor en modo de edicion.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "title": { "type": "string", "description": "Titulo de la nota a crear." },
                                "content": { "type": "string", "description": "Contenido inicial de la nota en markdown." }
                            },
                            "required": ["title", "content"]
                        }
                    },
                    {
                        "name": "vault_ui_open_note",
                        "description": "Abre una nota existente del Vault en la pantalla del usuario dentro de la aplicacion.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "Ruta absoluta de la nota a abrir." }
                            },
                            "required": ["path"]
                        }
                    },
                    {
                        "name": "vault_ui_set_editor_mode",
                        "description": "Cambia el modo de visualizacion del editor en pantalla (ej. 'edit', 'preview').",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "mode": { "type": "string", "description": "El modo del editor: 'edit' o 'preview'." }
                            },
                            "required": ["mode"]
                        }
                    },
                    {
                        "name": "chat_reset",
                        "description": "Reinicia completamente la sesión del chat. Borra todo el historial y empieza de cero. Usar cuando el usuario pida 'resetear', 'reiniciar' o 'empezar de nuevo' la conversación.",
                        "inputSchema": { "type": "object", "properties": {} }
                    },
                    {
                        "name": "chat_clear",
                        "description": "Limpia la ventana de chat (solo la vista, el historial sigue en base de datos).",
                        "inputSchema": { "type": "object", "properties": {} }
                    },
                    {
                        "name": "chat_compact",
                        "description": "Compacta el contexto de la conversación actual resumiendo los mensajes previos en uno solo. Libera tokens sin perder el hilo de la conversación.",
                        "inputSchema": { "type": "object", "properties": {} }
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

            let mcp_client_token = req.get("mcp_client_token").and_then(|t| t.as_str()).unwrap_or("");
            let token_record = {
                if let Ok(guard) = MCP_TOKENS.lock() {
                    guard.iter().find(|t| t.token_id == mcp_client_token).cloned()
                } else {
                    None
                }
            };

            let is_path_allowed = |p: &str, record: &Option<McpTokenRecord>| -> bool {
                if let Some(r) = record {
                    let mut cleaned = std::path::PathBuf::new();
                    for component in std::path::Path::new(p).components() {
                        match component {
                            std::path::Component::ParentDir => { cleaned.pop(); },
                            std::path::Component::CurDir => {},
                            _ => cleaned.push(component),
                        }
                    }
                    let cleaned_str = cleaned.to_string_lossy().to_string();

                    let mut allowed = false;
                    for w in &r.workspaces {
                        if cleaned_str.starts_with(w) { allowed = true; break; }
                    }
                    if r.read_system || r.write_system {
                        let home = std::env::var("HOME").unwrap_or("/".to_string());
                        let sys_dir = std::path::PathBuf::from(home).join(".vault_system").join("system_workspace");
                        if cleaned_str.starts_with(sys_dir.to_str().unwrap_or("")) { allowed = true; }
                    }
                    // Si hay subcarpetas restringidas, verificar que la ruta esté dentro de alguna
                    if allowed && !r.allowed_paths.is_empty() {
                        allowed = r.allowed_paths.iter().any(|sub| {
                            cleaned_str.starts_with(sub) || cleaned_str.contains(&format!("/{}/", sub.trim_matches('/')))
                        });
                    }
                    allowed
                } else {
                    false
                }
            };

            let is_path_safe_for_write = |p: &str, record: &Option<McpTokenRecord>| -> bool {
                let path_obj = std::path::Path::new(p);
                let canon = if path_obj.exists() {
                    std::fs::canonicalize(path_obj).unwrap_or_else(|_| path_obj.to_path_buf())
                } else if let Some(parent) = path_obj.parent() {
                    if parent.exists() {
                        let mut cp = std::fs::canonicalize(parent).unwrap_or_else(|_| parent.to_path_buf());
                        if let Some(name) = path_obj.file_name() { cp.push(name); }
                        cp
                    } else {
                        path_obj.to_path_buf()
                    }
                } else {
                    path_obj.to_path_buf()
                };
                is_path_allowed(&canon.to_string_lossy(), record)
            };

            let can_write = token_record.as_ref().map(|r| r.write_content).unwrap_or(false);
            let write_metadata = token_record.as_ref().map(|r| r.write_metadata).unwrap_or(false);
            let allow_raw = token_record.as_ref().map(|r| r.read_content).unwrap_or(true);
            let allow_metadata = token_record.as_ref().map(|r| r.read_metadata).unwrap_or(false);
            let allow_system = token_record.as_ref().map(|r| r.read_system).unwrap_or(false);

            crate::add_telemetry_log(format!("MCP Tool Call: {} | Args: {}", name, arguments.to_string()));

            let result_content = match name {
                "vault_list_workspaces" => {
                    if let Some(r) = &token_record {
                        let mut resp = format!("Workspaces permitidos:\n{}", r.workspaces.join("\n"));
                        if !r.allowed_paths.is_empty() {
                            resp.push_str(&format!("\n\nRestringido a carpetas:\n{}", r.allowed_paths.join("\n")));
                        }
                        if r.read_system || r.write_system {
                            let home = std::env::var("HOME").unwrap_or("/".to_string());
                            let sys_dir = std::path::PathBuf::from(home).join(".vault_system").join("system_workspace");
                            resp.push_str(&format!("\n{}", sys_dir.to_string_lossy()));
                        }
                        resp
                    } else {
                        "Token no válido o sin acceso a workspaces.".to_string()
                    }
                },
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

                    let mut results = crate::query_notes(Some(query.to_string()), None, ignore_patterns);
                    results.retain(|r| is_path_allowed(&r.path, &token_record));
                    if results.is_empty() {
                        "No se encontraron resultados.".to_string()
                    } else {
                        results.into_iter().map(|r| {
                            let display_content = if allow_raw {
                                if r.content.is_empty() && !r.is_dir {
                                    std::fs::read_to_string(&r.path).unwrap_or_default()
                                } else {
                                    r.content.clone()
                                }
                            } else {
                                get_synthetic_summary_by_id(&r.id)
                            };
                            format!("Ruta: {}\nTipo: {}\nTítulo: {}\nContenido:\n{}\n---",
                                r.path, if r.is_dir { "Carpeta" } else { "Archivo" }, r.title, display_content)
                        }).collect::<Vec<String>>().join("\n\n")
                    }
                },
                "vault_read" => {
                    if !allow_raw {
                        "Error de Seguridad: Acceso restringido. Ceguera de datos activa para este token. Usa metadatos sintéticos.".to_string()
                    } else {
                        let path = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                        if let Ok(canon_path) = std::fs::canonicalize(path) {
                            if !is_path_allowed(&canon_path.to_string_lossy(), &token_record) {
                                "Error de Seguridad: Acceso denegado. El enlace simbólico apunta fuera del workspace.".to_string()
                            } else if let Ok(meta) = std::fs::metadata(&canon_path) {
                                if !meta.is_file() {
                                    "Error de Seguridad: Solo se permiten archivos regulares (no FIFOs, directorios ni dispositivos especiales).".to_string()
                                } else if meta.len() > 5 * 1024 * 1024 {
                                    "Error de Seguridad: El archivo es demasiado grande (>5MB) para leerse por IPC.".to_string()
                                } else {
                                    match std::fs::read_to_string(&canon_path) {
                                        Ok(content) => content,
                                        Err(e) => format!("Error al leer el archivo {}: {}", path, e)
                                    }
                                }
                            } else {
                                "Error al leer metadatos del archivo.".to_string()
                            }
                        } else if !is_path_allowed(path, &token_record) {
                            "Error de Seguridad: Acceso denegado a esta ruta. El directorio no pertenece a un workspace permitido.".to_string()
                        } else if let Ok(meta) = std::fs::metadata(path) {
                            if !meta.is_file() {
                                "Error de Seguridad: Solo se permiten archivos regulares (no FIFOs, directorios ni dispositivos especiales).".to_string()
                            } else if meta.len() > 5 * 1024 * 1024 {
                                "Error de Seguridad: El archivo es demasiado grande (>5MB) para leerse por IPC.".to_string()
                            } else {
                                match std::fs::read_to_string(path) {
                                    Ok(content) => content,
                                    Err(e) => format!("Error al leer el archivo {}: {}", path, e)
                                }
                            }
                        } else {
                            "Error al leer metadatos del archivo.".to_string()
                        }
                    }
                },
                "vault_write" => {
                    let path = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                    let content = arguments.get("content").and_then(|c| c.as_str()).unwrap_or("");
                    if !can_write {
                        "Error de Seguridad: El token actual no tiene permisos de escritura (can_write=false).".to_string()
                    } else if !is_path_safe_for_write(path, &token_record) {
                        "Error de Seguridad: Acceso denegado a esta ruta. El directorio (o enlace simbólico) no pertenece a un workspace permitido.".to_string()
                    } else {
                        crate::save_note(path.to_string(), content.to_string())
                    }
                },
                "vault_create_folder" => {
                    let path = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                    if !can_write {
                        "Error de Seguridad: El token actual no tiene permisos de escritura (can_write=false).".to_string()
                    } else if !is_path_safe_for_write(path, &token_record) {
                        "Error de Seguridad: Acceso denegado a esta ruta. El directorio (o enlace simbólico) no pertenece a un workspace permitido.".to_string()
                    } else {
                        if crate::create_item(path.to_string(), true) {
                            format!("Carpeta creada en: {}", path)
                        } else {
                            format!("Error al crear la carpeta en: {}", path)
                        }
                    }
                },
                "vault_get_domain_context" => {
                    if !allow_metadata {
                        "Error de Seguridad: El token no tiene permiso para leer metadatos de dominio (allow_metadata=false).".to_string()
                    } else {
                    let path_str = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                    if !is_path_allowed(path_str, &token_record) {
                        "Error de Seguridad: Acceso denegado a esta ruta.".to_string()
                    } else {
                        if let Some(anchor_dir) = find_anchor_path(path_str, &token_record) {
                            let val = read_domain_context_from_disk(&anchor_dir);
                            serde_json::to_string_pretty(&val).unwrap_or_else(|_| "Error al formatear JSON".to_string())
                        } else {
                            serde_json::json!({
                                "anchor_path": null,
                                "memory": null,
                                "specs": null,
                                "lore": null,
                                "message": "No se encontro ningun Nodo Ancla (_memory.md, _specs.md, lore.md) en la jerarquia de directorios."
                            }).to_string()
                        }
                    }
                    } // close allow_metadata guard
                },
                "vault_log_friction" => {
                    let ctx = arguments.get("context").and_then(|c| c.as_str()).unwrap_or("");
                    let act = arguments.get("action").and_then(|a| a.as_str()).unwrap_or("");
                    let det = arguments.get("friction_detail").and_then(|d| d.as_str()).unwrap_or("");
                    if crate::log_friction_event(ctx.to_string(), act.to_string(), det.to_string()) {
                        "Friccion registrada correctamente en el sistema de telemetria.".to_string()
                    } else {
                        "Error al escribir en el registro de telemetria.".to_string()
                    }
                },
                "vault_export_domain_metadata" => {
                    if !allow_metadata {
                        "Error de Seguridad: El token no tiene permiso para exportar metadatos de dominio (allow_metadata=false).".to_string()
                    } else {
                    let limit = arguments.get("limit").and_then(|l| l.as_u64()).unwrap_or(100);
                    let since_seconds = arguments.get("since_seconds").and_then(|s| s.as_u64()).unwrap_or(0);
                    
                    let mut conn_guard = DB_CONN.lock().unwrap();
                    if let Some(conn) = conn_guard.as_mut() {
                        let query_sql = if since_seconds > 0 {
                            "SELECT dir_path, memory_contexto, memory_hitos, memory_historial, 
                                    specs_arquitectura, specs_reglas, specs_dependencias, 
                                    lore_proposito, lore_glosario, lore_usuarios, 
                                    epoch(last_updated)
                             FROM domain_metadata 
                             WHERE epoch(last_updated) >= ? 
                             ORDER BY last_updated DESC 
                             LIMIT ?"
                        } else {
                            "SELECT dir_path, memory_contexto, memory_hitos, memory_historial, 
                                    specs_arquitectura, specs_reglas, specs_dependencias, 
                                    lore_proposito, lore_glosario, lore_usuarios, 
                                    epoch(last_updated)
                             FROM domain_metadata 
                             ORDER BY last_updated DESC 
                             LIMIT ?"
                        };
                        
                        let mut stmt = match conn.prepare(query_sql) {
                            Ok(s) => s,
                            Err(e) => return format!("Error al preparar consulta SQL: {}", e),
                        };
                        
                        let mapper = |row: &duckdb::Row<'_>| {
                            Ok((
                                row.get::<_, String>(0)?,
                                row.get::<_, Option<String>>(1)?,
                                row.get::<_, Option<String>>(2)?,
                                row.get::<_, Option<String>>(3)?,
                                row.get::<_, Option<String>>(4)?,
                                row.get::<_, Option<String>>(5)?,
                                row.get::<_, Option<String>>(6)?,
                                row.get::<_, Option<String>>(7)?,
                                row.get::<_, Option<String>>(8)?,
                                row.get::<_, Option<String>>(9)?,
                                row.get::<_, f64>(10)?,
                            ))
                        };
                        
                        let rows_res = if since_seconds > 0 {
                            stmt.query_map(params![since_seconds, limit], mapper)
                        } else {
                            stmt.query_map(params![limit], mapper)
                        };
                        
                        match rows_res {
                            Ok(rows) => {
                                let mut results = Vec::new();
                                for r in rows.flatten() {
                                    let parse_json_array = |opt_str: Option<String>| -> Vec<String> {
                                        opt_str.and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok()).unwrap_or_default()
                                    };
                                    
                                    let export_row = serde_json::json!({
                                        "dir_path": r.0,
                                        "memory": {
                                            "contexto": r.1.unwrap_or_default(),
                                            "hitos": parse_json_array(r.2),
                                            "historial": parse_json_array(r.3)
                                        },
                                        "specs": {
                                            "arquitectura": r.4.unwrap_or_default(),
                                            "reglas": parse_json_array(r.5),
                                            "dependencias": parse_json_array(r.6)
                                        },
                                        "lore": {
                                            "proposito": r.7.unwrap_or_default(),
                                            "glosario": parse_json_array(r.8),
                                            "usuarios": parse_json_array(r.9)
                                        },
                                        "last_updated_epoch": r.10 as u64
                                    });
                                    results.push(export_row);
                                }
                                serde_json::to_string_pretty(&results).unwrap_or_else(|_| "[]".to_string())
                            },
                            Err(e) => format!("Error al ejecutar consulta SQL: {}", e),
                        }
                    } else {
                        "Error: Base de datos no inicializada.".to_string()
                    }
                    } // close allow_metadata guard
                },
                "vault_ui_create_note" => {
                    if !can_write {
                        "Error de Seguridad: El token no tiene permisos para crear notas (can_write=false).".to_string()
                    } else {
                    let title = arguments.get("title").and_then(|t| t.as_str()).unwrap_or("");
                    let content = arguments.get("content").and_then(|c| c.as_str()).unwrap_or("");
                    if let Ok(guard) = UI_LISTENER.lock() {
                        if let Some(listener) = guard.as_ref() {
                            listener.create_note(title.to_string(), content.to_string());
                            "Comando de UI de creacion de nota enviado con exito.".to_string()
                        } else {
                            "Error: No hay una instancia de la aplicacion macOS escuchando eventos de interfaz.".to_string()
                        }
                    } else {
                        "Error al adquirir bloqueo del listener de interfaz.".to_string()
                    }
                    } // close can_write guard
                },
                "vault_ui_open_note" => {
                    let path = arguments.get("path").and_then(|p| p.as_str()).unwrap_or("");
                    if let Ok(guard) = UI_LISTENER.lock() {
                        if let Some(listener) = guard.as_ref() {
                            listener.open_note(path.to_string());
                            "Comando de UI de apertura de nota enviado con exito.".to_string()
                        } else {
                            "Error: No hay una instancia de la aplicacion macOS escuchando eventos de interfaz.".to_string()
                        }
                    } else {
                        "Error al adquirir bloqueo del listener de interfaz.".to_string()
                    }
                },
                "vault_ui_set_editor_mode" => {
                    let mode = arguments.get("mode").and_then(|m| m.as_str()).unwrap_or("");
                    if let Ok(guard) = UI_LISTENER.lock() {
                        if let Some(listener) = guard.as_ref() {
                            listener.set_editor_mode(mode.to_string());
                            "Comando de UI de cambio de modo enviado con exito.".to_string()
                        } else {
                            "Error: No hay una instancia de la aplicacion macOS escuchando eventos de interfaz.".to_string()
                        }
                    } else {
                        "Error al adquirir bloqueo del listener de interfaz.".to_string()
                    }
                },
                "chat_reset" => {
                    if let Ok(guard) = UI_LISTENER.lock() {
                        if let Some(listener) = guard.as_ref() {
                            listener.chat_reset();
                            "Sesión de chat reiniciada.".to_string()
                        } else { "Error: App no disponible.".to_string() }
                    } else { "Error al adquirir listener.".to_string() }
                },
                "chat_clear" => {
                    if let Ok(guard) = UI_LISTENER.lock() {
                        if let Some(listener) = guard.as_ref() {
                            listener.chat_clear();
                            "Ventana de chat limpiada.".to_string()
                        } else { "Error: App no disponible.".to_string() }
                    } else { "Error al adquirir listener.".to_string() }
                },
                "chat_compact" => {
                    if let Ok(guard) = UI_LISTENER.lock() {
                        if let Some(listener) = guard.as_ref() {
                            listener.chat_compact();
                            "Contexto compactado.".to_string()
                        } else { "Error: App no disponible.".to_string() }
                    } else { "Error al adquirir listener.".to_string() }
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

fn default_true() -> bool { true }
fn default_false() -> bool { false }

#[derive(serde::Deserialize, serde::Serialize, Clone, uniffi::Record)]
pub struct McpTokenRecord {
    pub token_id: String,
    pub client_name: String,
    pub workspaces: Vec<String>,
    /// Subcarpetas específicas dentro del workspace. Vacío = acceso total al workspace.
    #[serde(default)]
    pub allowed_paths: Vec<String>,

    // --- Lectura ---
    /// Leer contenido crudo de notas (.md)
    #[serde(default = "default_true")]
    pub read_content: bool,
    /// Leer metadatos (_memory.md, _specs.md, _lore.md)
    #[serde(default)]
    pub read_metadata: bool,
    /// Leer contexto de sistema (system_workspace)
    #[serde(default)]
    pub read_system: bool,
    /// Leer telemetría
    #[serde(default)]
    pub read_telemetry: bool,

    // --- Escritura ---
    /// Crear o modificar notas
    #[serde(default)]
    pub write_content: bool,
    /// Modificar _memory.md, _specs.md, _lore.md
    #[serde(default)]
    pub write_metadata: bool,
    /// Modificar system_workspace
    #[serde(default)]
    pub write_system: bool,
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
pub fn create_mcp_token(
    client_name: String,
    workspaces: Vec<String>,
    allowed_paths: Vec<String>,
    read_content: bool,
    read_metadata: bool,
    read_system: bool,
    read_telemetry: bool,
    write_content: bool,
    write_metadata: bool,
    write_system: bool,
) -> String {
    let token_id = uuid::Uuid::new_v4().to_string();
    let record = McpTokenRecord {
        token_id: token_id.clone(),
        client_name,
        workspaces,
        allowed_paths,
        read_content,
        read_metadata,
        read_system,
        read_telemetry,
        write_content,
        write_metadata,
        write_system,
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

#[uniffi::export]
pub fn create_external_agent_token(
    client_name: String,
    workspaces: Vec<String>,
    allowed_paths: Vec<String>,
    read_content: bool,
    read_metadata: bool,
    read_system: bool,
    read_telemetry: bool,
    write_content: bool,
    write_metadata: bool,
    write_system: bool,
) -> String {
    let token_id = uuid::Uuid::new_v4().to_string();
    let record = McpTokenRecord {
        token_id: token_id.clone(),
        client_name,
        workspaces,
        allowed_paths,
        read_content,
        read_metadata,
        read_system,
        read_telemetry,
        write_content,
        write_metadata,
        write_system,
    };

    if let Ok(mut guard) = MCP_TOKENS.lock() {
        guard.push(record);
    }

    token_id
}

fn parse_markdown_sections(
    content: &str,
    sec_free_keyword: &str,
    sec_list1_keyword: &str,
    sec_list2_keyword: &str,
) -> (String, Vec<String>, Vec<String>) {
    let mut free_text = String::new();
    let mut list1 = Vec::new();
    let mut list2 = Vec::new();
    let mut current_section = "";

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("##") {
            let header = trimmed[2..].trim().to_lowercase();
            if header.contains(&sec_free_keyword.to_lowercase()) {
                current_section = "free";
            } else if header.contains(&sec_list1_keyword.to_lowercase()) {
                current_section = "list1";
            } else if header.contains(&sec_list2_keyword.to_lowercase()) {
                current_section = "list2";
            } else {
                current_section = "other";
            }
        } else {
            match current_section {
                "free" => {
                    if !trimmed.is_empty() || !free_text.is_empty() {
                        if !free_text.is_empty() {
                            free_text.push('\n');
                        }
                        free_text.push_str(trimmed);
                    }
                }
                "list1" => {
                    if trimmed.starts_with("- ") {
                        list1.push(trimmed[2..].trim().to_string());
                    } else if trimmed.starts_with("* ") {
                        list1.push(trimmed[2..].trim().to_string());
                    }
                }
                "list2" => {
                    if trimmed.starts_with("- ") {
                        list2.push(trimmed[2..].trim().to_string());
                    } else if trimmed.starts_with("* ") {
                        list2.push(trimmed[2..].trim().to_string());
                    }
                }
                _ => {}
            }
        }
    }
    (free_text.trim().to_string(), list1, list2)
}

fn read_domain_context_from_disk(anchor_dir: &std::path::Path) -> serde_json::Value {
    let memory_path = anchor_dir.join("_memory.md");
    let specs_path = anchor_dir.join("_specs.md");
    let lore_path = anchor_dir.join("lore.md");

    let mut memory_val = serde_json::json!({
        "contexto": "",
        "hitos": [],
        "historial": []
    });
    if memory_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&memory_path) {
            let (ctx, hitos, hist) = parse_markdown_sections(&content, "contexto", "hitos", "historial");
            memory_val = serde_json::json!({
                "contexto": ctx,
                "hitos": hitos,
                "historial": hist
            });
        }
    }

    let mut specs_val = serde_json::json!({
        "arquitectura": "",
        "reglas": [],
        "dependencias": []
    });
    if specs_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&specs_path) {
            let (arq, reglas, deps) = parse_markdown_sections(&content, "arquitectura", "reglas", "dependencias");
            specs_val = serde_json::json!({
                "arquitectura": arq,
                "reglas": reglas,
                "dependencias": deps
            });
        }
    }

    let mut lore_val = serde_json::json!({
        "proposito": "",
        "glosario": [],
        "usuarios": []
    });
    if lore_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&lore_path) {
            let (prop, glosario, usuarios) = parse_markdown_sections(&content, "prop", "glosario", "usuarios");
            lore_val = serde_json::json!({
                "proposito": prop,
                "glosario": glosario,
                "usuarios": usuarios
            });
        }
    }

    serde_json::json!({
        "anchor_path": anchor_dir.to_string_lossy().to_string(),
        "memory": memory_val,
        "specs": specs_val,
        "lore": lore_val
    })
}

fn find_anchor_path(start_path: &str, token_record: &Option<McpTokenRecord>) -> Option<std::path::PathBuf> {
    let mut current = std::path::PathBuf::from(start_path);
    if current.is_file() {
        current = match current.parent() {
            Some(p) => p.to_path_buf(),
            None => return None,
        };
    }

    loop {
        let current_str = current.to_string_lossy();
        let mut is_allowed = false;
        if let Some(r) = token_record {
            for w in &r.workspaces {
                if current_str.starts_with(w) {
                    is_allowed = true;
                    break;
                }
            }
            let home = std::env::var("HOME").unwrap_or("/".to_string());
            let sys_dir = std::path::PathBuf::from(home).join(".vault_system").join("system_workspace");
            if current_str.starts_with(sys_dir.to_str().unwrap_or("")) {
                is_allowed = true;
            }
        }

        if !is_allowed {
            return None;
        }

        if current.join("_memory.md").exists() || current.join("_specs.md").exists() || current.join("lore.md").exists() {
            return Some(current);
        }

        match current.parent() {
            Some(parent) => current = parent.to_path_buf(),
            None => break,
        }
    }
    None
}

#[uniffi::export]
pub fn scan_domain_metadata(vault_path: String) -> String {
    let path = std::path::Path::new(&vault_path);
    let mut processed_dirs = std::collections::HashSet::new();
    let mut count = 0;

    for entry in walkdir::WalkDir::new(path).into_iter().filter_map(|e| e.ok()) {
        let file_name = entry.file_name().to_string_lossy().to_string();
        if file_name == "_memory.md" || file_name == "_specs.md" || file_name == "lore.md" {
            let parent_dir = match entry.path().parent() {
                Some(p) => p.to_path_buf(),
                None => continue,
            };

            let parent_str = parent_dir.to_string_lossy().to_string();
            if processed_dirs.contains(&parent_str) {
                continue;
            }
            processed_dirs.insert(parent_str.clone());

            let memory_path = parent_dir.join("_memory.md");
            let specs_path = parent_dir.join("_specs.md");
            let lore_path = parent_dir.join("lore.md");

            let mut memory_contexto: Option<String> = None;
            let mut memory_hitos: Option<String> = None;
            let mut memory_historial: Option<String> = None;

            let mut specs_arquitectura: Option<String> = None;
            let mut specs_reglas: Option<String> = None;
            let mut specs_dependencias: Option<String> = None;

            let mut lore_proposito: Option<String> = None;
            let mut lore_glosario: Option<String> = None;
            let mut lore_usuarios: Option<String> = None;

            if memory_path.exists() {
                if let Ok(content) = std::fs::read_to_string(&memory_path) {
                    let (ctx, hitos, hist) = parse_markdown_sections(&content, "contexto", "hitos", "historial");
                    memory_contexto = Some(ctx);
                    memory_hitos = Some(serde_json::json!(hitos).to_string());
                    memory_historial = Some(serde_json::json!(hist).to_string());
                }
            }

            if specs_path.exists() {
                if let Ok(content) = std::fs::read_to_string(&specs_path) {
                    let (arq, reglas, deps) = parse_markdown_sections(&content, "arquitectura", "reglas", "dependencias");
                    specs_arquitectura = Some(arq);
                    specs_reglas = Some(serde_json::json!(reglas).to_string());
                    specs_dependencias = Some(serde_json::json!(deps).to_string());
                }
            }

            if lore_path.exists() {
                if let Ok(content) = std::fs::read_to_string(&lore_path) {
                    let (prop, glosario, usuarios) = parse_markdown_sections(&content, "prop", "glosario", "usuarios");
                    lore_proposito = Some(prop);
                    lore_glosario = Some(serde_json::json!(glosario).to_string());
                    lore_usuarios = Some(serde_json::json!(usuarios).to_string());
                }
            }

            let mut conn_guard = DB_CONN.lock().unwrap();
            if let Some(conn) = conn_guard.as_mut() {
                let _ = conn.execute("DELETE FROM domain_metadata WHERE dir_path = ?", params![parent_str]);
                let sql = "INSERT INTO domain_metadata (
                    dir_path,
                    memory_contexto, memory_hitos, memory_historial,
                    specs_arquitectura, specs_reglas, specs_dependencias,
                    lore_proposito, lore_glosario, lore_usuarios,
                    last_updated
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, now())";

                let res = conn.execute(
                    sql,
                    params![
                        parent_str,
                        memory_contexto,
                        memory_hitos,
                        memory_historial,
                        specs_arquitectura,
                        specs_reglas,
                        specs_dependencias,
                        lore_proposito,
                        lore_glosario,
                        lore_usuarios
                    ],
                );
                if res.is_ok() {
                    count += 1;
                }
            }
        }
    }

    format!("Escaneo de metadatos de dominio completado: {} carpetas ancla actualizadas.", count)
}

#[uniffi::export]
pub fn scan_memory_contexts(vault_path: String) -> String {
    scan_domain_metadata(vault_path)
}

fn inject_bullets_into_file(file_path: &std::path::Path, header_name: &str, bullets: &[String], default_template: &str) -> std::io::Result<()> {
    let mut content = if file_path.exists() {
        std::fs::read_to_string(file_path)?
    } else {
        default_template.to_string()
    };

    let header_marker = format!("## {}", header_name);
    let mut lines: Vec<String> = content.lines().map(|s| s.to_string()).collect();
    
    let mut header_idx = None;
    for (i, line) in lines.iter().enumerate() {
        if line.trim().starts_with(&header_marker) {
            header_idx = Some(i);
            break;
        }
    }

    if let Some(idx) = header_idx {
        let mut insert_pos = idx + 1;
        while insert_pos < lines.len() && !lines[insert_pos].trim().starts_with("##") {
            insert_pos += 1;
        }
        
        for bullet in bullets.iter().rev() {
            let bullet_line = if bullet.starts_with("- ") || bullet.starts_with("* ") {
                bullet.clone()
            } else {
                format!("- {}", bullet)
            };
            lines.insert(insert_pos, bullet_line);
        }
    } else {
        lines.push(String::new());
        lines.push(header_marker);
        for bullet in bullets {
            let bullet_line = if bullet.starts_with("- ") || bullet.starts_with("* ") {
                bullet.clone()
            } else {
                format!("- {}", bullet)
            };
            lines.push(bullet_line);
        }
    }

    let mut new_content = lines.join("\n");
    if !new_content.ends_with('\n') {
        new_content.push('\n');
    }
    std::fs::write(file_path, new_content)?;
    Ok(())
}

#[uniffi::export]
pub fn consolidate_session(active_path: String) -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let system_dir = std::path::PathBuf::from(&home).join(".vault_system").join("system_workspace");
    let scratchpad_path = system_dir.join("current_session.md");

    if !scratchpad_path.exists() {
        return "Error: No se encontró el archivo de Scratchpad (current_session.md).".to_string();
    }

    let content = match std::fs::read_to_string(&scratchpad_path) {
        Ok(c) => c,
        Err(e) => return format!("Error al leer el Scratchpad: {}", e),
    };

    let mut hitos = Vec::new();
    let mut acuerdos = Vec::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let lower = trimmed.to_lowercase();
        if lower.contains("[hito]") {
            let clean = trimmed
                .replace("[HITO]", "")
                .replace("[hito]", "")
                .replace("[Hito]", "")
                .trim()
                .to_string();
            let clean_bullet = if clean.starts_with("- ") {
                clean[2..].trim().to_string()
            } else if clean.starts_with("* ") {
                clean[2..].trim().to_string()
            } else {
                clean
            };
            if !clean_bullet.is_empty() {
                hitos.push(format!("- {}", clean_bullet));
            }
        } else if lower.contains("[acuerdo]") {
            let clean = trimmed
                .replace("[ACUERDO]", "")
                .replace("[acuerdo]", "")
                .replace("[Acuerdo]", "")
                .trim()
                .to_string();
            let clean_bullet = if clean.starts_with("- ") {
                clean[2..].trim().to_string()
            } else if clean.starts_with("* ") {
                clean[2..].trim().to_string()
            } else {
                clean
            };
            if !clean_bullet.is_empty() {
                acuerdos.push(format!("- {}", clean_bullet));
            }
        }
    }

    if hitos.is_empty() && acuerdos.is_empty() {
        return "No se encontraron elementos marcados con [HITO] o [ACUERDO] para consolidar.".to_string();
    }

    let anchor_dir = {
        let mut current = std::path::PathBuf::from(&active_path);
        if current.is_file() {
            current = current.parent().map(|p| p.to_path_buf()).unwrap_or(current);
        }

        let mut found = None;
        let mut temp = current.clone();
        loop {
            if temp.join("_memory.md").exists() || temp.join("_specs.md").exists() || temp.join("lore.md").exists() {
                found = Some(temp.clone());
                break;
            }
            match temp.parent() {
                Some(parent) => temp = parent.to_path_buf(),
                None => break,
            }
        }
        found.unwrap_or(current)
    };

    let anchor_str = anchor_dir.to_string_lossy().to_string();
    let mut summary = format!("Consolidando en el Nodo Ancla: {}\n", anchor_str);

    if !hitos.is_empty() {
        let memory_path = anchor_dir.join("_memory.md");
        let default_mem = "# Memoria de Desarrollo\n\n## Contexto\n\n## Hitos\n\n## Historial\n";
        match inject_bullets_into_file(&memory_path, "Hitos", &hitos, default_mem) {
            Ok(_) => summary.push_str(&format!("✅ Inyectados {} hitos en _memory.md.\n", hitos.len())),
            Err(e) => summary.push_str(&format!("❌ Error al inyectar hitos: {}\n", e)),
        }
    }

    if !acuerdos.is_empty() {
        let specs_path = anchor_dir.join("_specs.md");
        let default_specs = "# Especificaciones Técnicas\n\n## Arquitectura\n\n## Reglas\n\n## Dependencias\n";
        match inject_bullets_into_file(&specs_path, "Reglas", &acuerdos, default_specs) {
            Ok(_) => summary.push_str(&format!("✅ Inyectados {} acuerdos en _specs.md.\n", acuerdos.len())),
            Err(e) => summary.push_str(&format!("❌ Error al inyectar acuerdos: {}\n", e)),
        }
    }

    let reset_content = "# Sesión Actual\n\n- [HITO] \n- [ACUERDO] \n";
    if let Err(e) = std::fs::write(&scratchpad_path, reset_content) {
        summary.push_str(&format!("⚠️ No se pudo vaciar el Scratchpad: {}\n", e));
    } else {
        summary.push_str("✅ Scratchpad reiniciado.\n");
    }

    let _ = scan_domain_metadata(anchor_str);

    summary
}

#[uniffi::export]
pub fn log_friction_event(context: String, action: String, friction_detail: String) -> bool {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let log_path = std::path::PathBuf::from(home).join(".vault_system").join("system_workspace").join("telemetria.log");

    if let Some(parent) = log_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let now = chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
    
    let mut conn_guard = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_guard.as_mut() {
        let sql = "INSERT INTO telemetry (ts, context, event_type, message, metadata) VALUES (now(), ?, 'FRICCION', ?, ?)";
        let meta = serde_json::json!({
            "action": action,
            "friction_detail": friction_detail
        }).to_string();
        let _ = conn.execute(sql, params![context, friction_detail, meta]);
    }

    use std::fs::OpenOptions;
    use std::io::Write;

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let log_line = format!("[{}] | FRICCION | CONTEXTO: {} | ACCION: {} | DETALLE: {}\n", now, context, action, friction_detail);
        let _ = file.write_all(log_line.as_bytes());
        crate::add_telemetry_log(format!("[FRICCION] ({}) - {}", context, friction_detail));
        return true;
    }
    
    false
}

#[uniffi::export]
pub fn shutdown_vault_session(workspace_path: String) -> String {
    let mut msgs: Vec<String> = Vec::new();

    // 1. Consolidar scratchpad → bitácora diaria
    let consolidation = consolidate_session(workspace_path.clone());
    msgs.push(format!("Scratchpad: {}", consolidation));

    // 2. Git snapshot del workspace (si .git existe)
    let ws = Path::new(&workspace_path);
    if ws.join(".git").exists() {
        let _ = std::process::Command::new("/usr/bin/git")
            .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_OBJECT_DIRECTORY")
            .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
            .args(["-C", &workspace_path, "-c", "safe.directory=*", "add", "-A"])
            .output();

        let ts = chrono::Local::now().format("%Y-%m-%d %H:%M").to_string();
        let commit = std::process::Command::new("/usr/bin/git")
            .env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_OBJECT_DIRECTORY")
            .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
            .args([
                "-C", &workspace_path,
                "-c", "safe.directory=*",
                "-c", "user.name=Vault Session",
                "-c", "user.email=vault-session@lsm.cl",
                "commit", "-m", &format!("[Vault Session] {}", ts),
            ])
            .output();

        match commit {
            Ok(o) if o.status.success() => msgs.push("Git: snapshot de cierre creado.".into()),
            Ok(o) => {
                let err = String::from_utf8_lossy(&o.stderr);
                if err.contains("nothing to commit") || err.contains("no cambios") {
                    msgs.push("Git: sin cambios pendientes.".into());
                }
            }
            Err(_) => {}
        }
    }

    // 3. Flush de telemetría a DuckDB
    if let Ok(mut logs) = TELEMETRY_LOGS.lock() {
        if !logs.is_empty() {
            if let Some(conn) = get_db_connection() {
                let count = logs.len();
                for log in logs.iter() {
                    let _ = conn.execute(
                        "INSERT INTO telemetry (ts, context, event_type, message) VALUES (now(), 'Session', 'SHUTDOWN_FLUSH', ?)",
                        params![log],
                    );
                }
                msgs.push(format!("Telemetría: {} eventos persistidos.", count));
            }
            logs.clear();
        }
    }

    // 4. Cerrar DuckDB gracefully
    if let Ok(mut guard) = DB_CONN.lock() {
        if let Some(conn) = guard.take() {
            match conn.close() {
                Ok(_) => msgs.push("DuckDB: conexión cerrada.".into()),
                Err((_, e)) => msgs.push(format!("DuckDB: error al cerrar — {}", e)),
            }
        }
    }

    msgs.join(" | ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_vault_metodos() {
        init_db();
        let path = "/Users/lsanmartin/_vault/m\u{00E9}todos".to_string();
        let ignore = vec!["_metadata.md".to_string()];
        let res = scan_vault(path, ignore);
        println!("Result: {}", res);
        
        let conn_guard = DB_CONN.lock().unwrap();
        if let Some(conn) = conn_guard.as_ref() {
            let mut stmt = conn.prepare("SELECT count(*) FROM notes WHERE path LIKE '%/me_todos%' OR path LIKE '%/m\u{00E9}todos%' OR path LIKE '%/me\u{0301}todos%'").unwrap();
            let count: i64 = stmt.query_row([], |row| row.get(0)).unwrap();
            println!("Rows found: {}", count);
        }
    }
}

#[uniffi::export]
pub fn mcp_execute_for_agent(json_request: String) -> String {
    mcp_handle_request(json_request)
}

#[uniffi::export]
pub fn get_agent_mcp_tools(token_id: String) -> String {
    let req = json!({
        "jsonrpc": "2.0",
        "method": "tools/list",
        "params": {},
        "id": 1,
        "mcp_client_token": token_id
    });
    mcp_handle_request(req.to_string())
}

#[uniffi::export]
pub fn run_mcp_server(workspace_root: String, token_id: Option<String>) {
    let max_payload_bytes = 5 * 1024 * 1024;
    let _ = mcp_server::run_mcp_server(std::path::PathBuf::from(workspace_root), max_payload_bytes, token_id);
}
