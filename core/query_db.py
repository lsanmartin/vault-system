import duckdb
con = duckdb.connect("/Users/lsanmartin/.vault_system/vault.duckdb")
res = con.execute("SELECT path, is_dir FROM notes WHERE path LIKE '%_vaulta%' LIMIT 10").fetchall()
print("Vaulta files:", res)
res2 = con.execute("SELECT path, is_dir FROM notes LIMIT 10").fetchall()
print("Any files:", len(res2))
