import duckdb
import time

con = duckdb.connect("/Users/lsanmartin/.vault_system/vault.duckdb")
start = time.time()
res = con.execute("SELECT path, is_dir FROM notes WHERE path LIKE '/Users/lsanmartin/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian%' ORDER BY created_at DESC").fetchall()
end = time.time()
print(f"Time to query 35k records: {end - start:.4f} seconds")
print(f"Records retrieved: {len(res)}")
