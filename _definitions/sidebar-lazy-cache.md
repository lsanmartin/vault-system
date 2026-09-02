---
id: sidebar-lazy-cache
type: decision
status: active
supersedes: ""
fecha: 2026-09-02
---

# Sidebar lazy: childrenByParent como caché on-demand (no árbol completo)

<summary>
El sidebar NO materializa el árbol completo desde DuckDB en cada refresh; `childrenByParent` solo puebla raíz + carpetas expandidas, y expandir carga hijos on-demand desde `allFolders`/`allNotes` (que se mantienen completos).
</summary>

## Contenido

- `childrenByParent` = caché lazy: en `performRefreshNotes` solo se construyen las entradas para la raíz del workspace + los paths en `expandedPaths` (más `newExpandedPaths` en modo búsqueda). No se reconstruye el mapa O(n) completo.
- `allFolders` / `allNotes` se mantienen **completos** (los consume `handleNavigation` link-lookup, árbol semántico por workspace y `HeatmapView`). No hacer lazy sobre ellos.
- `toggleExpansion(path:)` puebla `childrenByParent[path]` on-demand filtrando `allFolders + allNotes` por `fastParentPath == path` si la entrada es nil.
- `refreshNotes` tiene debounce de ~150ms (`refreshDebounceWork`) para coalescer ráfagas (poller 1s + mutaciones + VaultScanDidFinish).
- Cambio de workspace: un solo refresh (se quitó el `refreshNotes` del `didSet selectedLocationId`; lo dispara `MainEditorView.onChange → resetToWorkspaceRoot`).
- Modos `.recentCreated` / `.recentModified` / `.pinned` y búsqueda conservan su camino existente (no usan el mapa completo).

## Relacionado

- [[rc1-mutex-raiz-latencia]] · [[_index]]
