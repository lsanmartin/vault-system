import sys

def patch_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    start_str = "    let total_entries = entries.len();\n    let mut count = 0;"
    end_str = "    // Asegurar 100% al finalizar"

    start_idx = content.find(start_str)
    end_idx = content.find(end_str)

    if start_idx == -1 or end_idx == -1:
        print("Could not find start or end markers")
        return

    new_code = """    let total_entries = entries.len();
    let mut count = 0;
    let mut skips = 0;

    // Obtener lista actual para detectar huérfanos
    let mut db_contents = std::collections::HashMap::new();
    {
        let mut conn_guard = DB_CONN.lock().unwrap();
        if let Some(conn) = conn_guard.as_mut() {
            if let Ok(mut stmt) = conn.prepare("SELECT path, content FROM notes") {
                if let Ok(rows) = stmt.query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                }) {
                    for row in rows.flatten() {
                        db_contents.insert(row.0, row.1);
                    }
                }
            }
        }
    }

    let mut batch_inserts = Vec::new();
    let batch_size = 500; // Lote de 500 para evitar agotar FixedSizeAllocator

    // Segunda pasada: procesar e insertar actualizando el progreso
    for (idx, entry) in entries.into_iter().enumerate() {
        let file_path = entry.path();
        let full_path_str = file_path.to_str().unwrap_or("").to_string();
        
        let existing_content = db_contents.remove(&full_path_str);
        
        // Procesar directorios y archivos
        if file_path.is_dir() {
            if existing_content.is_none() {
                let title = file_path.file_name().and_then(|s| s.to_str()).unwrap_or("Carpeta").to_string();
                batch_inserts.push((full_path_str.clone(), title, "".to_string(), vec![], true));
            }
        } else if file_path.is_file() && file_path.extension().and_then(|s| s.to_str()) == Some("md") {
            let content = std::fs::read_to_string(file_path).unwrap_or_else(|_| "".to_string());
            let content_changed = match existing_content {
                Some(ref db_content) => *db_content != content,
                None => true,
            };
            
            if content_changed {
                let title = file_path.file_stem().and_then(|s| s.to_str()).unwrap_or("Sin título").to_string();
                let emb = generate_embedding(&content);
                batch_inserts.push((full_path_str.clone(), title, content, emb, false));
            } else {
                skips += 1;
            }
        }

        // Ejecutar el lote si alcanza tamaño
        if batch_inserts.len() >= batch_size {
            let mut conn_guard = DB_CONN.lock().unwrap();
            if let Some(conn) = conn_guard.as_mut() {
                let _ = conn.execute("BEGIN TRANSACTION", []);
                let mut tx_failed = false;
                
                for (p, t, c, emb, is_dir) in batch_inserts.drain(..) {
                    if tx_failed { continue; }
                    
                    let res = if is_dir {
                        conn.execute(
                            "INSERT OR IGNORE INTO notes (id, title, path, content, is_dir, created_at) VALUES (?, ?, ?, ?, true, now())",
                            duckdb::params![p, t, p, c]
                        )
                    } else {
                        let sql = format!(
                            "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at, embedding) VALUES (?, ?, ?, ?, false, now(), {})",
                            vector_to_sql_array(&emb)
                        );
                        conn.execute(&sql, duckdb::params![p, t, p, c])
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
            if let Some(&p) = progress.get(&path) {
                if p < 0.0 {
                    return "Escaneado cancelado.".to_string();
                }
            }
            if total_entries > 0 {
                let pct = ((idx + 1) as f32 / total_entries as f32) * 100.0;
                progress.insert(path.clone(), pct);
            }
        }
    }
    
    // Procesar último lote
    if !batch_inserts.is_empty() {
        let mut conn_guard = DB_CONN.lock().unwrap();
        if let Some(conn) = conn_guard.as_mut() {
            let _ = conn.execute("BEGIN TRANSACTION", []);
            let mut tx_failed = false;
            
            for (p, t, c, emb, is_dir) in batch_inserts.drain(..) {
                if tx_failed { continue; }
                
                let res = if is_dir {
                    conn.execute(
                        "INSERT OR IGNORE INTO notes (id, title, path, content, is_dir, created_at) VALUES (?, ?, ?, ?, true, now())",
                        duckdb::params![p, t, p, c]
                    )
                } else {
                    let sql = format!(
                        "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at, embedding) VALUES (?, ?, ?, ?, false, now(), {})",
                        vector_to_sql_array(&emb)
                    );
                    conn.execute(&sql, duckdb::params![p, t, p, c])
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
    let orphans_count = db_contents.len();
    if orphans_count > 0 {
        let mut conn_guard = DB_CONN.lock().unwrap();
        if let Some(conn) = conn_guard.as_mut() {
            for orphan in db_contents.keys() {
                let _ = conn.execute("DELETE FROM notes WHERE path = ?", duckdb::params![orphan]);
            }
        }
    }

"""

    with open(filepath, 'w') as f:
        f.write(content[:start_idx] + new_code + content[end_idx:])

patch_file("/Users/lsanmartin/dev/vault-system/core/src/lib.rs")
