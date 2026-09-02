---
id: rc1-mutex-raiz-latencia
type: important
status: active
supersedes: ""
fecha: 2026-09-02
---

# Latencia del sidebar: medida real (la hipótesis RC-1 quedó refutada)

<summary>
Medición con timers (2026-09-02): query_notes 22-27ms (15.467 notas), query_children 7-22ms, refresh completo 69-97ms, y CERO contención del mutex. La "latencia de 3000ms" del diagnóstico original no existe en navegación idle.
</summary>

## Contenido

- Medido con `eprintln!`/`print` temporales (ya revertidos): `query_notes` full scan = 22-27ms; `query_children` (expandir carpeta) = 7-22ms; `performRefreshNotes` total (Swift + transferencia FFI de 15k `NoteRecord`) = 69-97ms.
- **Cero líneas `get_db_connection waited`** → el mutex global nunca estuvo contendido en carga idle. La hipótesis RC-1 (mutex → sidebar vacío) NO se reproduce en navegación normal.
- El poller de 1s está correctamente gateado por `getLastSyncTs()` (solo refresca cuando cambia, i.e. watcher/save). No hay refrescos espurios.
- El diagnóstico "Antigravity CLI" de ~3000ms era erróneo (o medía otro escenario: scan_vault con MLX eager, o iCloud sin hidratar). No perseguir el pool de conexiones Rust (Fase 3) por esta razón.
- Único costo restante: ~70ms de transferencia FFI de los 15k registros en cada refresh; por debajo del SLA (<50ms por carpeta), no perceptible.

## Relacionado

- [[sidebar-lazy-cache]] · [[_index]]
