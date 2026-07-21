# Vault System — Knowledge OS Nativo

**Fecha:** 2026-07-21
**Versión:** 0.1.0
**Stack:** Rust + SwiftUI (macOS) + DuckDB + MLX + UniFFI

---

## ⚙️ Arquitectura General

```
┌──────────────────────────────────────────────┐
│  SwiftUI App (macOS native)                   │ ← Capa UI (AppKit + SwiftUI)
│  VaultApp.swift → ContentView.swift            │
│  EditorViewModel, WorkspaceManager, etc        │
├──────────────────────────────────────────────┤
│  UniFFI Bridge (FFI Swift ↔ Rust)             │ ← Bindings generados automáticamente
│  vault_core.swift (generado en build)          │
├──────────────────────────────────────────────┤
│  vault_core (Rust)                             │ ← Motor principal
│  core/src/lib.rs + core/src/mcp_server.rs      │
├──────────────────────────────────────────────┤
│  vault_daemon (Rust binary, autónomo)          │ ← Bridge IPC externo
│  daemon/src/main.rs                             │
└──────────────────────────────────────────────┘
```

Workspace Cargo con 2 miembros: `core/` (lib: staticlib + cdylib + rlib) y `daemon/` (binario).

**Build pipeline**: `make release` → `preflight` (RAM check) → `build-aarch64` (cargo) → bindings (uniffi-bindgen) → XCFramework → `xcode-build` (archive) → `deploy` (cp a /Applications).

---

## 🧠 Core Rust — `core/src/lib.rs`

~2900 líneas. Usa DuckDB como base de datos analítica embebida in-process. Exporta ~40 funciones FFI vía UniFFI.

### Constantes y Singletons Globales

- **`DB_CONN`**: `Mutex<Option<Connection>>` — conexión persistente DuckDB (lazy, inicializada en `init_knowledge_base`)
- **`DB_QUERY_MUTEX`**: `Mutex<()>` — exclusión mutua global para queries concurrentes (previene corrupción SIGBUS/EXC_BAD_ACCESS)
- **`EMBEDDING_LAZY`**: `Mutex<bool>` default `true` — modo lazy embeddings (scan sin GPU)
- **`MLX_LOCK`**: `Mutex<()>` — lock para MLX (try_lock, fallback a CPU)
- **`SCANNING_PATHS`**: `Mutex<Vec<String>>` — paths en escaneo actual (watcher consulta antes de procesar)
- **`WATCHER_PENDING_EVENTS`**: `Mutex<Vec<(String, bool)>>` — eventos acumulados durante scan
- **`TELEMETRY_LOGS`**: `Mutex<Vec<String>>` — cola de logs (máx 500)
- **`SCAN_PROGRESS`**: `Mutex<HashMap<String, f32>>` — progreso 0-100%
- **`LAST_SYNC_TS`**: `Mutex<u64>` — timestamp del último sync

`DbConnectionGuard` wrapper que implementa `Deref`/`DerefMut` sobre Connection + `MutexGuard` — la conexión clonada y la guardia viven juntas.

### Motor de Base de Datos — DuckDB

**`init_knowledge_base()`** — Inicializa `~/.vault_system/vault.duckdb` con detección de corrupción y flag `_schema_no_indices`.

#### Esquema: 10 tablas

| Tabla | Columnas | Propósito |
|---|---|---|
| `notes` | id, title, path, content, is_dir, created_at, tags[VARCHAR], embedding FLOAT[384], modified_ts | Catálogo completo de archivos .md y carpetas |
| `links` | source_id, target_id, type, weight, created_at | Grafo de enlaces entre notas |
| `telemetry` | ts, context, event_type, message, metadata JSON | Logs de eventos del sistema |
| `semantic_summaries` | note_id, synthetic_summary, extracted_entities[VARCHAR], cognitive_timestamp, semantic_density | Resúmenes generados por cognitive daemon |
| `entity_graphs` | entity_name, note_id, relation_type, discovered_at | Entidades extraídas por nota |
| `memory_contexts` | dir_path, hitos JSON, contexto, historial JSON, last_updated | Contextos de memoria persistente |
| `domain_metadata` | dir_path, memory_contexto, memory_hitos JSON, memory_historial JSON, specs_arquitectura, specs_reglas JSON, specs_dependencias JSON, lore_proposito, lore_glosario JSON, lore_usuarios JSON, last_updated | Tríada de dominio parseada |
| `_schema_version` | version, applied_at | Versionado de esquema para migraciones |
| `_schema_no_indices` | flag | Flag de migración (evita recreación en cada init) |

**Decisión arquitectónica**: Sin PRIMARY KEY ni FOREIGN KEY ni índices secundarios en VARCHAR — DuckDB tiene un bug interno al serializar índices ART en `TransformToDeprecated` que corrompe la DB al borrar filas. En su lugar: `DELETE WHERE id = ?` + `INSERT`.

**Dedup preventivo** en cada init y post-scan:
```sql
DELETE FROM notes WHERE rowid NOT IN (SELECT MIN(rowid) FROM notes GROUP BY id)
```

### Scan & Indexación — `scan_vault(path, ignore_patterns)`

Pipeline de indexación completa de un vault:

1. **Canonicalizar path** — resuelve symlinks iCloud
2. **Registrar en SCANNING_PATHS** — watcher no compite
3. **Primera pasada** — WalkDir recursivo filtrando ocultos y `ignore_patterns`, recolecta entradas válidas (.md + carpetas)
4. **Cargar mtimes existentes** — HashMap `path → modified_ts` desde DB para detectar cambios y huérfanos
5. **Segunda pasada** — por cada entrada:
   - Si es carpeta nueva → INSERT
   - Si es .md → lee contenido, mtime, filtra stubs (<30 chars), genera embedding, acumula en batch
   - Si ya existe en DB pero mtime no cambió → skip
6. **Batch inserts** de 200 en 200 (BATCH_SIZE), cada batch en transacción
   - `DELETE WHERE id = ?` + `INSERT` (evita INSERT OR REPLACE)
   - Si falla una fila → ROLLBACK todo el batch
7. **Eliminar huérfanos** — registros en DB que ya no existen en disco (cascada: semantic_summaries, links, notes)
8. **Dedup post-scan** — elimina duplicados que pudieran quedar
9. **Asegurar 100%** en SCAN_PROGRESS
10. **Deregistrar de SCANNING_PATHS**
11. **Procesar eventos del watcher** acumulados durante el scan

### Embeddings — 3 modos

| Modo | Función | GPU | Uso |
|---|---|---|---|
| Lazy (default) | `generate_embedding()` | No | Scan: retorna `[0;384]`, ~90% menos GPU |
| Eager MLX | `generate_embedding_mlx()` | Sí (M2 Pro) | Búsqueda semántica bajo demanda |
| Fallback CPU | `generate_embedding_fast()` | No | Cuando MLX lock está ocupado |

**MLX pipeline**:
- Hash djb2 del texto → seed → tensor MLX (1 scalar)
- Broadcast a `[384]` → matmul con `ones([384,384])` → eval() en GPU/NPU
- Extraer slice f32 → normalización L2 (requerida por coseno)

**Fast pipeline** (CPU-only, determinístico):
- Hash 64 bits expandido por índice → `[0;384]`
- Normalización L2

Toggle en runtime: `set_embedding_lazy(bool)` / `is_embedding_lazy()`.

### Queries FFI (exportadas a Swift)

| Función | SQL generado | Notas |
|---|---|---|
| `query_notes(search_term, path_filter, ignore_patterns)` | SELECT con AND ... WHERE | regexp_matches accent-insensitive por palabra (AND) |
| `query_recent_created(path_filter, limit)` | ORDER BY created_at DESC LIMIT N | Content omitido (`'' as content`) |
| `query_recent_modified(path_filter, limit)` | ORDER BY modified_ts DESC LIMIT N | Content omitido (`'' as content`) |

En queries de listado: `SELECT ... '' as content ...` — el contenido se carga desde disco on-demand al abrir la nota (reducción de ~90% transferencia FFI).

Búsqueda semántica: `array_cosine_similarity(n.embedding, ARRAY[...])::FLOAT[384]` — activa solo cuando `EMBEDDING_LAZY` es false y hay search_term.

### File Watcher — `start_watcher(paths, ignore_patterns)`

Hilo con crate `notify` (RecommendedWatcher, 6.1):

- **Debounce 2s**: ventana de coalescing + dedup por path
- **Filtro de eventos**: solo `Modify(Data)`, `Create`, `Remove` (ignora `Modify(Metadata)` de iCloud)
- **Scan-aware**: si `SCANNING_PATHS` no está vacío → encola en `WATCHER_PENDING_EVENTS`
- **Stub detection**: archivos con contenido <30 chars se omiten (iCloud sin hidratar)
- **Hidden skip**: paths que contienen `/.` (carpetas/archivos ocultos)
- **Embedding inline**: calcula embedding en cada evento de modificación

### Cognitive Daemon — `start_cognitive_daemon()`

Hilo background con **backoff adaptativo**:

- Sin notas pendientes → `sleep(60s)`
- Con trabajo → `sleep(10s)`

Proceso:
1. Query: `SELECT id, title, content FROM notes WHERE NOT IN (SELECT note_id FROM semantic_summaries) LIMIT 50`
2. Genera `synthetic_summary` (actualmente mock: primer snippet + título)
3. Extrae entidades del content (split por whitespace, top 10)
4. Inserta en `semantic_summaries`
5. Inserta en `entity_graphs` por cada entidad

### IPC Server — `start_ipc_server()`

TCP listener en `127.0.0.1:49152`, UUID en `/tmp/vault_ipc.token`.

Recibe JSON-RPC, lo parsea, delega en `mcp_handle_request()` con IPC token inyectado, retorna respuesta.

### MCP Server — `mcp_server.rs`

Servidor JSON-RPC por stdin/stdout (Model Context Protocol, protocolVersion 2024-11-05).

**Invocación**: `VaultSystem --mcp --token=<UUID> --workspace=<path>`

**Arquitectura**: `run_mcp_server()` → loop stdin → parse RpcRequest → `handle_method()` → delega en `crate::mcp_handle_request()` para tools.

**Validación de tokens**:
- Lee `~/.config/vault-system/mcp_tokens.json` (fallback `~/.config/vault-app/mcp_tokens.json`)
- Busca token_id en array de `McpTokenRecord`
- Verifica que workspace root esté en `token.workspaces`
- Retorna error si token inválido o sin acceso

**Flujo `initialize`**: carga `mcp_global_agent.md` si existe → inyecta `agent.md` del workspace si `allow_workspace_context` → retorna capabilities + instructions.

**8 herramientas MCP** (delegadas vía `mcp_handle_request`):

| Herramienta | Input Schema | Acción |
|---|---|---|
| `vault_list_workspaces` | {} | Lista workspaces autorizados del token |
| `vault_search` | {query: string, exclude_metadata?: bool, exclude_system?: bool} | `query_notes()` + filtro path_allowed |
| `vault_read` | {path: string} | `fs::read_to_string()` con validación |
| `vault_write` | {path: string, content: string} | `save_note()` + auto-commit git |
| `vault_create_folder` | {path: string} | `create_item(is_dir=true)` |
| `vault_get_domain_context` | {path: string} | Busca ancestro con _memory.md, _specs.md, lore.md |
| `vault_log_friction` | {context, action, friction_detail} | `log_friction_event()` → tabla telemetry |
| `vault_export_domain_metadata` | {limit: int, since_seconds: int} | Exporta domain_metadata como JSON |

**Validaciones de seguridad en tools**:
- `is_path_allowed`: resuelve symlinks + verifica path contra workspaces del token + allow_system para ~/.vault_system
- `is_path_safe_for_write`: canonicaliza path existente o su padre, verifica contra allowed
- `can_write`: flag del token
- Tamano máximo de archivo: 5MB
- Solo archivos regulares (no FIFOs, dispositivos)

### Gestión de Archivos

| Función | Operación | Persistencia DB |
|---|---|---|
| `create_item(path, is_dir=true)` | `mkdir -p` | No (DB se actualiza en scan) |
| `create_item(path, is_dir=false)` | `mkdir -p` parent + touch | No |
| `save_note(path, content)` | `fs::write` + git add + git commit | Sí (INSERT) |
| `rename_item(old, new)` | `fs::rename` | DELETE registros DB viejos |
| `delete_item(path)` | `fs::remove` | No |
| `remove_vault_path(path)` | Valida path existe | DELETE cascada: semantic_summaries, entity_graphs, links, notes |

### Git integrado

- `init_git_repo(path)`: `git init` + `--allow-empty` con `safe.directory=*`
- `save_note()`: `git add` + `git commit` con mensaje "Auto-save"
- `get_file_history(path)`: `git log --format='%H\|%ai\|%s'`
- `get_file_content_at_commit(path, hash)`: `git show hash:path`

---

## 🖥️ UI Swift — `apple/Shared/`

### Estructura de archivos

| Archivo | Rol |
|---|---|
| `VaultApp.swift` | Entry point @main, init MCP, initKnowledgeBase, cognitive daemon |
| `ContentView.swift` | Root SwiftUI view |
| `WorkspaceManager.swift` | Gestión de workspaces, bookmarks TCC, hidratación iCloud, triggerScan |
| `EditorViewModel.swift` | ViewModel central (~930 líneas), lógica de navegación y edición |
| `MainEditorView.swift` | Layout HSplitView 3 columnas + editor WebView + CodeEditor |
| `CodeEditor.swift` | NSTextView personalizado con line numbers, syntax highlighting |
| `WebView.swift` | WKWebView con bridge nativo (checkboxes toggle) |
| `MCPAccessView.swift` | UI de configuración y exportación de tokens MCP |
| `TelemetryView.swift` | Visor de logs de telemetría |
| `CognitiveRadarView.swift` | Visualización de radar cognitivo |
| `HeatmapView.swift` | Heatmap de actividad por hora/día |
| `CloudSync.swift` | Hidratación y sync de iCloud |

### EditorViewModel — ViewModel Central

**Published Properties clave**:

| Property | Tipo | Descripción |
|---|---|---|
| `tabs` | `[TabItem]` | Pestañas abiertas (id, title, content, renderMode, lastSavedAt) |
| `activeTabId` | `String?` | Pestaña activa (didSet actualiza line numbers) |
| `explorationFilter` | `ExplorationFilter` | `.all`, `.recentCreated`, `.recentModified`, `.pinned` |
| `currentPath` | `String` | Ruta actual estilo Finder en el grid |
| `childrenByParent` | `[String: [NoteRecord]]` | HashMap para árbol O(1) sin walk |
| `pinnedPaths` | `Set<String>` | Set persistido en UserDefaults |
| `expandedPaths` | `Set<String>` | Nodos expandidos en sidebar |
| `searchText` / `debouncedSearchText` | `String` | Búsqueda con debounce via Combine |
| `selectedLocationId` | `UUID?` | Workspace activo (persistido) |
| `selectedTheme` | `AppTheme` | system / dark / night |
| `deletedPathsThisSession` | `Set<String>` | Paths eliminados (filtro en refresh) |

**Refresh asíncrono** (`refreshNotes`):
1. Captura estado actual en `DispatchQueue.main`
2. Ejecuta query FFI en `DispatchQueue.global(qos: .userInitiated)`
3. Construye `childrenByParent` con `fastParentPath()` (O(1))
4. Aplica filtro de deletedPaths
5. Actualiza `@Published` en `DispatchQueue.main.async`

**Construcción del árbol**: `fastParentPath()` recorta último segmento en el string sin I/O. `appendChildrenFast()` recursión sobre `childrenByParent` hasta profundidad configurada.

**3 modos de visualización**:
- `.all`: árbol jerárquico de carpetas + notas
- `.recentCreated` / `.recentModified`: lista plana de 30 notas (sin contenido)
- `.pinned`: notas fijadas por el usuario

**TabItem**: id (path absoluto), title, content, renderMode (universal/markdown/latex/html), lastSavedAt, language. Hashable por id.

### WorkspaceManager

- **Bookmarks TCC**: Security-scoped bookmarks persistidos en UserDefaults
- **Symlink resolution**: resuelve symlinks de la ruta iCloud antes de comparar duplicados
- **Hidratación iCloud**: `hydrateAll()` en lotes de 20 archivos con 0.5s de pausa
- **Scan post-hidratación**: `scanAfterHydration()` espera 5s + triggerScan
- **Timer de progreso**: polling `getScanProgress()` cada 0.5s, notifica VaultScanDidFinish

### Layout — HSplitView plano

3 columnas independientes, sin anidación:
1. **Sidebar** (250px min): Workspace list + árbol de carpetas + vistas (recientes, fijadas)
2. **Grid** (250px min): Lista o cuadrícula de notas con context menu
3. **Editor**: WebView (preview) + NSTextView (edición) + RSVP + Git history

Toggle synchronizado de sidebar + grid. Anchura persistida en UserDefaults.

### Funcionalidades UI clave

- **RSVP Reader**: modal 750x480pt con 64pt de texto, Liquid Glass (ultraThinMaterial), blur de fondo (3px), oscurecimiento (opacity 0.45)
- **Checkboxes interactivos**: JavaScript injection en generateSafeHTML, canal `toggleCheckbox` → Swift, actualización silenciosa (sin recarga WebView, scroll preservado)
- **Line Numbers**: `LineNumberRulerView` (NSRulerView), click = seleccionar línea, Shift+click = extender, Cmd+L = línea actual
- **Pin**: icono naranja, persistido en UserDefaults, carpetas/notas fijadas al inicio
- **Git History**: hoja con lista de commits, previsualización de contenido en commit específico
- **Scratchpad**: Soberanía Cognitiva, bottom sheet con drag y snaps, consolida a `current_session.md` vía FFI
- **Finder integration**: "Mostrar en Finder" en cada carpeta/nota, revelar nota en sidebar

### Temas

3 modos: `system` (delega en NSApp.appearance = nil), `dark` (#1E1E1E fondo editor), `night` (rojo sobre negro).
Persistencia en UserDefaults. `NSApp.appearance` sync. `accessibilityReduceTransparency` desactiva Liquid Glass.

---

## 🔧 Daemon — `daemon/src/main.rs`

Bridge externo autónomo (~75 líneas). Pipeline:

1. Requiere `--client-token <UUID>`
2. Lee JSON-RPC de stdin línea por línea
3. Inyecta `ipc_token` (de `/tmp/vault_ipc.token`) + `mcp_client_token`
4. Conecta TCP a `127.0.0.1:49152` y envía request
5. Lee respuesta y escribe a stdout
6. Si Vault App no responde: error `-32000`

Usos: scripts CLI, automatizaciones remotas (SSH), Handoff entre máquinas.

---

## 📡 Pipeline de Comunicación MCP

```
Cliente MCP (Claude Desktop, etc.)
        │
        │ JSON-RPC stdin/stdout
        ▼
VaultSystem --mcp --token=X --workspace=Y
        │
        │ validate_token() → ~/.config/vault-system/mcp_tokens.json
        ▼
mcp_server::handle_method()
        │
        │ Delegación interna a crate::mcp_handle_request()
        ▼
lib::mcp_handle_request() → tools/list | tools/call | initialize
        │
        ├──→ DuckDB queries (read-only)
        ├──→ fs::read/write (con RBAC)
        └──→ Token validation layer
```

---

## 🛡️ Modelo de Seguridad

| Capa | Mecanismo |
|---|---|
| Autenticación | Token UUID en `mcp_tokens.json` |
| Autorización | RBAC por workspace path + allow_system |
| Filesystem | Canonicalización de symlinks, solo archivos regulares, <5MB |
| Escritura | Flag `can_write` en token |
| IPC | Token efímero UUID en `/tmp/vault_ipc.token` |
| TCC macOS | Security-scoped bookmarks persisten acceso entre sesiones |

---

## 🧪 Fricciones históricas resueltas

- **DuckDB ART index crash**: removidos PRIMARY KEY y FOREIGN KEY, reemplazados por DELETE+INSERT
- **DuckDB concurrent crash**: `DB_QUERY_MUTEX` global con try_lock + backoff 100ms
- **Embeddings GPU saturada**: lazy mode + try_lock en MLX + fallback CPU hash
- **iCloud stubs**: detección por <30 chars, omitidos en scan y watcher
- **Watcher tormenta eventos**: debounce 2s + coalescing + filtro Metadata de iCloud
- **Scan vs watcher race**: SCANNING_PATHS flag + WATCHER_PENDING_EVENTS cola
- **Carpetas duplicadas en sidebar**: resetToWorkspaceRoot + observer onChanged de selectedLocationId
- **Filtro pegado**: reinicio explorationFilter a .all al cambiar workspace
