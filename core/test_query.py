import duckdb
con = duckdb.connect("/Users/lsanmartin/.vault_system/vault.duckdb")
# test path filter
obsidian_path = "/Users/lsanmartin/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian"
res = con.execute("SELECT count(*) FROM notes WHERE path LIKE ?", [obsidian_path + '%']).fetchall()
print("Count obsidian:", res)
