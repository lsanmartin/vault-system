import sys

def patch_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    search = """                let res = if is_dir {
                    conn.execute(
                        "INSERT OR IGNORE INTO notes (id, title, path, content, is_dir, created_at) VALUES (?, ?, ?, ?, true, now())",
                        params![p, t, p, c]
                    )
                } else {
                    let sql = format!(
                        "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at, embedding) VALUES (?, ?, ?, ?, false, now(), {})",
                        vector_to_sql_array(&emb)
                    );
                    conn.execute(&sql, params![p, t, p, c])
                };"""
                
    replace = """                let res = if is_dir {
                    conn.execute(
                        "INSERT OR IGNORE INTO notes (id, title, path, content, is_dir, created_at, modified_ts) VALUES (?, ?, ?, ?, true, now(), ?)",
                        duckdb::params![p, t, p, c, mtime as i64]
                    )
                } else {
                    let sql = format!(
                        "INSERT OR REPLACE INTO notes (id, title, path, content, is_dir, created_at, embedding, modified_ts) VALUES (?, ?, ?, ?, false, now(), {}, ?)",
                        vector_to_sql_array(&emb)
                    );
                    conn.execute(&sql, duckdb::params![p, t, p, c, mtime as i64])
                };"""

    content = content.replace(search, replace)
    
    with open(filepath, 'w') as f:
        f.write(content)

patch_file("/Users/lsanmartin/dev/vault-system/core/src/lib.rs")
