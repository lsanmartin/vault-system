---
id: unique-index-notes-upsert
type: decision
status: active
supersedes: ""
fecha: 2026-09-10
confidence: high
source: smoke test DuckDB 1.5.3 (CLI) + validación de migración v4
---

# Índice UNIQUE sobre notes.id + UPSERT (reemplaza el DELETE+INSERT O(n²))

<summary>
Se agrega `CREATE UNIQUE INDEX ux_notes_id ON notes(id)` + índices `modified_ts`/`created_at` (migración v4) y se reemplaza el patrón `DELETE WHERE id=?`+`INSERT` por `INSERT ... ON CONFLICT (id) DO UPDATE` en los 6 sitios de escritura. Escritura O(n) en vez de O(n²) (el DELETE por fila hacía full-scan sin índice).
</summary>

## Contenido

- El principio #33-34 ("sin PK ni índices VARCHAR", adoptado para esquivar un bug ART de DuckDB al borrar filas) queda **superado** para DuckDB 1.5.x: smoke test con 15k filas + churn DELETE/INSERT sobre `UNIQUE INDEX` no reproduce `TransformToDeprecated` ni `Failed to delete all rows from index`.
- `ON CONFLICT (id) DO UPDATE` exige constraint/índice UNIQUE sobre `id`. Se usa `CREATE UNIQUE INDEX` (no PK) para **no reconstruir la tabla ni perder el índice FTS BM25** (un `DROP TABLE`/rename habría forzado recrear FTS).
- Migración v4 deduplica con `MAX(rowid)` (conserva la fila más reciente) antes de crear el índice único, y corrige el bug previo de dedup que usaba `MIN(rowid)` (conservaba contenido obsoleto).
- Índices `modified_ts`/`created_at`: son BIGINT/TIMESTAMP, **no VARCHAR**, así que nunca estuvieron alcanzados por el principio #33. Aceleran `query_recent_modified`/`query_recent_created` (1e).
- **1c descartada**: `duckdb-rs 1.10503.1` no soporta bindear `List`/`Array`/`Struct` (`"binding List parameters is not yet supported"`, `value_ref.rs:357`). La columna `embedding FLOAT[384]` se sigue interpolando vía `ARRAY[...]::FLOAT[384]`.

## Relacionado

- [[_index]] · [[sidebar-lazy-cache]] · [[rc1-mutex-raiz-latencia]]
