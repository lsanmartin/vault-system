import duckdb
import os
con = duckdb.connect("/Users/lsanmartin/.vault_system/vault.duckdb")
res = con.execute("SELECT path FROM notes WHERE is_dir = true").fetchall()
roots = set()
for (p,) in res:
    if p.count('/') <= 4:  # heuristic for roots
        roots.add(p)
print("Roots:", list(roots)[:20])
