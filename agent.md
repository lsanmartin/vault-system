# Contexto del Agente

Última actualización: [2026-08-10]

**📋 Agenda de trabajo:** `KANBAN.md` — fuente de verdad para fases y tareas. Leer al iniciar sesión.

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas independientes (`HSplitView` plano), y navegación jerárquica.
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento híbrido de MD, HTML y LaTeX con ayuda de sintaxis in-app.
- **Capa 3: Core (Rust) & Seguridad MCP**: Búsqueda semántica, File Watcher con persistencia Git (Auto-Save), y RBAC de MCP.

## Resumen Técnico
- **Objetivo**: Implementación nativa de Soberanía Cognitiva (Tríada de metadatos, Scratchpad SwiftUI y telemetría de fricción).
- **Cambios Realizados**:
  - **[2026-08-16] Fix Glitch Chat Local y Expansión Agentic Loop**:
    - **Fix Glitch de Scroll/Flickering**: Se resolvió un bug en `LocalChatView.swift` donde el motor Swift recargaba completamente el `WKWebView` (`loadHTMLString`) de forma prematura durante la generación del stream porque JavaScript no encontraba el nodo DOM del mensaje. Esto causaba un salto violento al tope de la página ("vuelve y regresa del primer mensaje"). **Solución**: Se interceptó la recarga en modo streaming (`isUpdateOnly`) y se modificó `appendOrUpdateMessage` en JS para auto-insertar el mensaje en el DOM si no existe, garantizando fluidez sin recargas.
    - **Expansión Autonomía IA (Agentic Loop)**: Se habilitaron herramientas para que el Cerebro Local explore archivos y carpetas (`[CMD: list_directory]`, `[CMD: read_file]`). Se implementó un bucle recursivo (`sendLocal`) en el código Swift para detectar, ejecutar nativamente estas herramientas vía `FileManager`, e inyectar el resultado al contexto de la IA en milisegundos de forma invisible para el usuario.
    - **Mecanismo de Auto-Corrección Heurístico**: Se ajustó el prompt del `LocalBrain.swift` para clarificar la diferencia entre abrir notas y listar directorios. Adicionalmente, se programó un sistema "ruedas de entrenamiento" en `LocalChatView.swift` que intercepta comandos inválidos (ej. usar `open_note` en el directorio `_vault`); si detecta que la ruta solicitada es un directorio o un workspace, el código Swift lo auto-corrige silenciosamente a `list_directory` y le entrega los archivos al agente, salvando la incapacidad de modelos pequeños (4B) para recuperarse de errores de ruteo.
  - **[2026-08-16] Refactor de UI Chat y Fix GPU OOM**:
    - **Reversión a vista individual**: Eliminado el layout apilado verticalmente de múltiples chats (con `ChatSectionDivider`) para simplificar y aprovechar la altura total de la ventana.
    - **Selector inferior estilo Mac**: Añadida una botonera inferior en `LocalChatView` para alternar entre el agente local y los externos, utilizando un diseño consistente con `SidebarColumn` y asignando iconos personalizados por provider (`cpu`, `water.waves`, `brain`, `sparkles`). El agente activo ahora se destaca de forma minimalista con un pequeño punto indicador debajo del ícono (estilo Mac Dock).
    - **Alineación con AI-Launch**: Asegurado que la tarea de compilación y despliegue corra bajo el namespace correcto en background, utilizando el formato exacto `nohup bash -c "exec -a ai-deploy-3m bash -c 'make core && make deploy'" &` para observabilidad universal como proceso temporal (⏳).
    - **Fix Metal OOM en MLX (`Abort trap: 6`)**: Se aplicó truncamiento a 6,000 caracteres del `finalContext` inyectado en `LocalBrain.chatStream` para prevenir el desbordamiento de memoria GPU (context window limit excedida) que causaba cierres forzados al acumular notas extensas o RAG muy amplio.
    - **Fix Glitches de UI en Chat**:
      - **Fluidez de escritura IA**: Implementado sistema de debounce/throttling (50ms) en la actualización y un **Smart DOM Update** vía Javascript para inyectar el texto directamente en el nodo sin recargar el `WKWebView`. Esto elimina el parpadeo de pantalla (flashing) que dejaba ver el fondo intermitentemente durante el stream.
      - **Indicador fantasma de descarga**: Eliminada la falsa activación de `isDownloading` durante la fase de carga a memoria en el `LocalBrain`.
      - **Solapamiento visual de chats**: Eliminado el uso destructivo de `.id()` en `AgentChatSection` al cambiar de agente, adoptando un reciclaje mediante `.onChange()` para purgar historial y cargar limpio, evitando colisiones del webview.
  - **[2026-08-15] Fix % de descarga de modelos congelado en 0/1% (root cause definitivo)**:
    - **Bug reportado**: al descargar el modelo `gemma-4-e2b-it-4bit` desde la app, el % no avanzaba (se quedaba en 1% o 0%) aunque la red iba a 7 MB/s vía curl.
    - **Root cause (reproducido con tests aislados en `swiftc`)**: `URLSession.downloadTask` (y `bytes(for:)`) se **cuelgan contra el CDN xet-bridge de HF** (`us.aws.cdn.hf.co`) para archivos ≳25 MB — la tarea espera con 0 bytes indefinidamente. `dataTask` con delegate funciona a cualquier tamaño (50 MB OK; el archivo completo de 3.55 GB streamed a ~4.5 MB/s). Umbral entre 20 MB (OK) y 29 MB (HANG). NO era el HEAD preflight (`fetchFileMetadata` + `SameHostRedirectDelegate`, devuelve 302 + Location xet-bridge en 2.2s), ni la UI (ProgressView correcta), ni locks/disco.
    - **Fix** (`apple/Shared/Storage/ModelManager.swift`): reescrito `downloadModel` para **no usar swift-huggingface** (`import HuggingFace` removido, `publicHubClient` eliminado). Ahora: `listRemoteFiles` (GET `api/models/<id>/tree/main?recursive=true`) → `resolveDownloadURL` (`<id>/resolve/main/<path>`) → `streamFile` con `URLSessionDataDelegate` que escribe a `FileHandle` y reporta bytes → `reportDownloadProgress` con **throttle 0.4%** (`lastReportedPct[id]` reseteado a 0 al iniciar descarga — evita que un 1.0 previo congele el %). Movida a `DownloadCounter` (NSLock, @unchecked Sendable) para el progreso global del snapshot.
    - **Resultado**: el fix quedó implementado y listo; build (`make app`) estaba bloqueado por **ENOSPC** (disco lleno: la descarga del e2b de 3.3 GB + intermediates). Disco liberado (33 Gi libres) y build relanzado.
    - **Modelo e2b descargado por curl como bypass**: `model.safetensors` = 3,550,670,554 bytes (byte-exacto) en `~/.vault_system/models/mlx-community/gemma-4-e2b-it-4bit/` (ruta canónica + `config.json`) → `modelIsDownloaded` da true → carga offline inmediata.
  - **[2026-08-10] Fix re-descarga del modelo local Gemma 4 (12B-4bit)**:
    - **Bug**: cada vez que la app usaba la IA local, decía que "descargaba de nuevo el modelo" (~7 GB) aunque ya estaba descargado.
    - **Causa raíz**: el modelo completo (**6.3 GB**, `model-00001/2-of-2.safetensors`, Jul 30) está en `~/Library/Containers/cl.nicelio.vault.VaultSystem/Data/Documents/huggingface/models/mlx-community/gemma-4-12B-it-4bit/` (ruta **legacy** de versiones anteriores de la app). Pero `LocalBrain.getOrLoadContainer` usaba `ModelConfiguration(id:)` **sin `directory`** → el macro `#huggingFaceLoadModelContainer` busca en el cache de HF estándar `Library/Caches/huggingface/hub/` → solo había 31 MB parciales → fallaba → `Hub.snapshot` re-descargaba los 6-7 GB.
    - **Fix** (`apple/Shared/Storage/LocalBrain.swift`): antes de cargar, se detecta si existe `config.json` en `Documents/huggingface/models/<modelId>` y, si existe, se pasa `ModelConfiguration(id:modelId, directory: dir)` → carga offline inmediata. Si no existe, cae a la carga por cache/descarga normal.
    - **Modelo**: `mlx-community/gemma-4-12B-it-4bit` (12B cuantizado 4-bit, GPU Metal vía mlx-swift).
  - **[2026-08-10] Fix Cmd+Q colgado + build nativo Apple Silicon (arm64)**:
    - **Bug Cmd+Q**: el shutdown corría síncrono en `willTerminateNotification` (main thread) haciendo `git add -A` + `git commit` por cada workspace. El vault Obsidian tiene **~93K archivos untracked** sobre iCloud → el `add` intentaba indexarlos todos → la app se colgaba al cerrar. **Fix en 2 capas**:
      - Swift (`apple/Shared/VaultApp.swift`): nuevo `AppDelegate` con `applicationShouldTerminate` → responde `.terminateLater`, lanza los shutdowns en `DispatchQueue.global`, y `reply(toApplicationShouldTerminate:)` exactamente una vez (lock) cuando termina, **con timeout de seguridad de 10s** que fuerza el cierre. El observer síncrono de `willTerminate` se eliminó.
      - Rust (`core/src/lib.rs` → `shutdown_vault_session`): el `git add` ahora usa **`-u` (solo rastreados)** en workspaces de contenido (el `add -A` queda solo para `.vault_system`). Ya no indexa los untracked del usuario.
    - **Build nativo arm64**: el core fallaba porque el único `cmake` era Intel (`/usr/local`, x86_64) → bajo Rosetta detectaba host x86_64 → MLX abortaba (`Building for x86_64 on macOS is not supported`). **Fix**: `brew install cmake` en Homebrew arm64 (`/opt/homebrew/bin/cmake` v4.4.2). Como `/usr/local` está antes en PATH, se fuerza con `CMAKE=/opt/homebrew/bin/cmake make core`. `make core` exit 0, `libvault_core.dylib` arm64, MLX nativo (Metal/Accelerate). El Makefile ya era arm64-first (`build-universal` = solo `aarch64-apple-darwin`; `xcode-build` usa `-arch arm64`). El target `build-x86_64` es legacy/no usado — la versión Intel será un proyecto separado más simple.
  - **[2026-08-10] Fix persistencia de chat + rediseño tipo WhatsApp (chat infinito)**:
    - **Bug raíz (persistencia)**: `chat_messages.id INTEGER PRIMARY KEY` NO es autoincrement en DuckDB (eso es SQLite) → todo INSERT fallaba con `NOT NULL constraint failed` → el chat se reseteaba al abrir la app (los threads existían pero `chat_messages` quedaba vacío). **Fix**: id explícito vía secuencia — `CREATE SEQUENCE IF NOT EXISTS chat_messages_id_seq START 1` + `chat_save_message` calcula `nextval('chat_messages_id_seq')` e inserta con id. **IMPORTANTE**: DuckDB v1.5 NO soporta columnas IDENTITY (`GENERATED ALWAYS AS IDENTITY` → "Constraint not implemented!") ni `lastval()`/`ALTER SEQUENCE ... RESTART`; verificado por CLI. Migración v2 en `init_knowledge_base`: rename/create/copy/drop de `chat_messages` + `INSERT INTO _schema_version (2)`. La tabla vieja está vacía (el bug impedía todo insert) → no hay pérdida de datos.
    - **Idempotencia de guardado**: `saveMessage(_:)` no re-guarda mensajes con `persistedId != nil` (evita duplicados; el guardado incremental de `updateMessage` —cada ~200 chars— se eliminó porque con persistencia funcionando habría creado filas parciales). `saveCurrentThreadMessages` solo guarda lo no persistido. `ChatThreadManager.saveMessage` devuelve el id.
    - **Paginación (lazy loading)**: `chat_get_messages(thread_id, limit, before_id)` — subquery `ORDER BY id DESC LIMIT ?` re-ascendente, incluye `id` en el JSON. Corrige el bug latente del `ORDER BY id ASC LIMIT ?` (devolvía los MÁS ANTIGUOS en vez de los recientes). Carga inicial 60. Scroll a arriba en el WKWebView → JS `chatRequestOlder` → `loadOlderMessages` antepone y ancla vía `data-mid` + `scrollIntoView` (sin salto visual); `preserveAnchorId` se consume tras el render.
    - **Marcas de sesión tipo WhatsApp**: separador `── <fecha> ──` (reusa CSS `.anchor-marker`) cuando el gap entre mensajes consecutivos supera 2h (`msg.effectiveDate` = `persistedDate ?? Date()`).
    - **Buscador**: `chat_search_messages(thread_id, query, limit)` con `content ILIKE '%q%'` (descendente). Lupa en el header + TextField + overlay de resultados (`ChatSearchResultsList`). Tap → `jumpToMessage(id)`: carga ventana `beforeId=id, limit=80`, centra y resalta el `data-mid` (CSS `.highlight` fade 2.2s).
    - **Fix latente de decodificación**: la FFI devuelve `agent_code`/`created_at` (snake_case); los decoders de `ChatThreadManager` ahora usan `.convertFromSnakeCase` (antes `agentCode` quedaba nil y `ChatThread.agentCode` no-Optional rompía `loadThreads` → lista de threads vacía).
    - **Compilación**: `make core` (Rust + bindings `vault_core.swift` regenerados) + `make deploy` → `ARCHIVE SUCCEEDED`.
  - **[2026-08-10] Visualización de Formatos en Listado + Inserción de Imágenes**:
    - **Imágenes en el listado**: Desbloqueadas de `binaryExtBlacklist` (solo formatos de imagen) en `EditorViewModel.swift` — con el toggle "Mostrar todos los archivos" ahora aparecen png/jpg/webp/heic/etc. Seguridad intacta (`.env*`, credenciales, binarios no-imagen siguen ocultos).
    - **Thumbnails**: Nuevo `ThumbnailCache.swift` (ImageIO downsampled + NSCache ~64MB, carga async con `.task(id:)`). `NoteCard` (grid) muestra la imagen como cover; `FileRowView` (lista) miniatura 28pt. Iconos SF Symbol por extensión vía `FileTypeHelper.swift` (PDF, código, JSON, zip, audio, video).
    - **QuickLook nativo**: Nuevo `QuickLookManager.swift` (QLPreviewPanel; QuickLookUI.framework linkeado en `project.yml`). Al hacer clic en una imagen/binario no-.md → panel QuickLook en vez de abrir pestaña (guard en `openNote`). "Vista rápida" en menús contextuales.
    - **Inserción de imágenes en notas (modo edición)**: Nuevo `ImageImportService.swift` (copia a `_attachments/` + enlace Markdown con ruta relativa). Tres vías: (a) drag & drop del listado al editor (`CodeEditor` registra `.fileURL`; `performDragOperation` inserta `![](rel)` en el punto de soltado), (b) botón "Insertar Imagen" (NSOpenPanel multi-selección), (c) pegar Cmd+V guardando el portapapeles en `_attachments/image-<ts>.png`.
    - **Compilación**: `make xcode-build` → `ARCHIVE SUCCEEDED`. Desplegado en `/Applications/VaultSystem.app`.
  - **[2026-08-10] Opciones IA para notas desde el chat**:
    - **Motivación**: Operar el apoyo de IA sobre la nota activa desde el panel de chat (fila rápida + panel colapsable) en vez del popover "Redactor IA" de cada nota (que concatena ciego al final y solo usa Gemma local).
    - **`NoteAIPanel.swift` (NUEVO)**: `NoteAIMode` (.insertAtEnd/.replaceAll/.replaceSelection), `NoteAIAction.all` (Resumir, Glosario, Redacción — "Extraer OAs" eliminada de aquí y de `InlineAICommandView` por ser demasiado específica), `NoteAIApplyInfo`, `NoteAIQuickActionsRow` (botones compactos bajo los chips) y `NoteAIOptionsPanel` (DisclosureGroup bajo `PermissionsBar` con nota activa, override de título, acciones, instrucción personalizada, toggle auto-aplicar y Picker de modo).
    - **Flujo**: `runNoteAIAction` → genera con el agente seleccionado. Local: `chatStream(prompt:context:)` con la nota como contexto (salta RAG). Externo: `runExternalPlan` (single-shot con tool loop). El resultado se marca aplicable en `LocalChatMessage.applyContent`.
    - **Aplicación**: Botón "Aplicar a la nota" (JS bridge WKScriptMessageHandler `noteAIApply` → `handleApplyRequest`) o toggle auto-aplicar (`@AppStorage "vault_noteai_autoApply"`). `applyToActiveNote` escribe `tabs[idx].content` + `saveActiveTab` (dispara recarga de preview). Modo persistido en `"vault_noteai_mode"`.
    - **Comando por texto**: `/nota <instrucción>` en el input → mismo flujo.
    - **Externo**: si el workspace del agente contiene la nota y tiene `writeContent`, puede además usar MCP tools (seguridad de escritura ya validada por el core Rust). Si escribe con `vault_write`, se confirma sin botón Aplicar.
    - **Selección**: `EditorViewModel.editorSelection` (NSRange) alimentado por `CodeEditor.textViewDidChangeSelection`; usado por modo Reemplazar selección.
    - **Edge cases**: nota > 12k chars se trunca con aviso; resultado vacío no muestra botón; resultado con fenced blocks se desempaqueta (`parseNoteAIResult`).
    - **[Refinamiento 2026-08-10] Creación de nota nueva**: `NoteAIApplyInfo.noteId` ahora es opcional (`createNew`). Dos triggers: (a) sin nota activa → la acción crea una nota nueva en el folder activo con el resultado; (b) instrucción con keywords "crea una nota / crear nota / nueva nota…" (`wantsCreateNew`) → fuerza nota nueva aunque haya pestaña abierta. `applyToActiveNote` con `noteID == nil` llama `createNewNote(locations:content:skipRename:)` (nuevos params `content` y `skipRename` en `EditorViewModel`; el H1 usa `noteAITitleOverride` si está) y sincroniza la preview de la pestaña recién abierta. El botón del mensaje cambia a "Crear nota nueva" cuando `applyNoteId == nil`. Panel y fila rápida ahora se habilitan sin nota activa (label "creará una nota nueva").
    - **[Refinamiento 2026-08-10] Título en el prompt**: la IA conoce el tema de la nota — `noteAIUserPrompt` y el prompt local incluyen "Nota activa: <título>". En modo crear-nota, el prompt pide "una nota nueva" sin inyectar texto original.
    - **Compilación**: `make deploy` → `ARCHIVE SUCCEEDED`. Desplegado en `/Applications/VaultSystem.app`.
  - **[2026-08-10] Bootstrapping del agente IA (system_workspace)**:
    - **Contexto**: Auditoría de una IA externa reveló que su "conciencia" se basaba en un inventario parcialmente alucinado (listaba `capacidades-agente.md`, `instrucciones_chatbot.md`, `lore.md`, "LTM 2.0" — ninguno existía). El `system_workspace` real solo tenía Contexto.md, arquitectura.md, cerebro-local.md y un scratchpad con residuo `asdasdasd`. Diagnóstico: el bootstrap no era un documento, era una ausencia de documentos.
    - **Docs creados en `~/.vault_system/system_workspace/`** (repo git propio, commit propio): `capacidades-agente.md` (inventario REAL de las 19 tools MCP extraídas de `lib.rs:2174-2362`, categorizadas + heurística de uso), `instrucciones_chatbot.md` (comandos `/plan /goal /design /nota /reset /clear /compact`, tono, reglas de memoria), `directrices-core.md` (framework operativo: taxonomía 3 capas, protocolos no negociables — es el archivo que `buildSystemPrompt` ya inyectaba pero no existía), `bootstrapping-agente.md` (ritual de conexión en 4 pasos: dónde estoy → herramientas → memoria → operar; índice corto, profundización bajo demanda). Limpieza de `current_session.md` (residuo eliminado, estructura base).
    - **Inyección automática de memoria (bloque 4)**: `buildSystemPrompt` en `LocalChatView.swift` ahora inyecta `current_session.md` como "## Sesión Anterior (scratchpad)" (igual patrón que directrices-core.md/conciencia.md), para que el agente despierte con el contexto de la sesión anterior sin gastar una llamada de tool. Límite de sysPrompt subido de 3000 → 6000 chars en `sendExternal` y `runExternalPlan` para acomodar la inyección.
    - **Gatillos de consolidación (bloque 3) — verificado, sin cambios**: `consolidate_session` (lib.rs:3354) ya consolida al cerrar vía OnStop→`shutdown_vault_session`: `[HITO]`→`_memory.md`, `[ACUERDO]`→`_specs.md` del Nodo Ancla, reinicia scratchpad. El eslabón de memoria ya estaba implementado en Rust.
    - **Compilación**: `make deploy` → `ARCHIVE SUCCEEDED`. Desplegado en `/Applications/VaultSystem.app`.
  - **[2026-08-01] Fix Descarga del Cerebro Local (gemma-4-12B-it-4bit)**:
    - **Diagnóstico**: La app "re-descargaba" el modelo en cada arranque porque los pesos NUNCA se completaron en `~/.cache/huggingface/hub`. Quedaban blobs `.incomplete` del 2026-06-27 (descarga interrumpida) para otros IDs (`gemma-4-12B-it-OptiQ-4bit`, `gemma-4-e4b-it-4bit`), y el ID del código (`mlx-community/gemma-4-12B-it-4bit`) no tenía nada en caché. `Hub.snapshot` vuelve a descargar desde cero si el snapshot está incompleto.
    - **Solución**: Pre-poblado del caché HF con la estructura exacta que la librería Hub de Swift espera (verificado contra `swift-huggingface/HubCache.swift` y `HubClient+Files.swift`): `refs/main` → commit `73bcf09092aa277861d5a191b989b666f7f32e8f`; `snapshots/<commit>/` → 11 archivos completos (pesos byte-exactos: 5,351,756,584 + 1,389,282,927 bytes); `.metadata/<commit>.json` → metadata de snapshot para el fast-path `cachedSnapshotPath`.
    - **Método**: `curl -L -C -` (resumible) directo al CDN xet-bridge de HF. Verificado byte-exacto contra `content-range`.
    - **Nota**: `loadModelContainer` usa `useLatest=false` → resuelve vía `refs/main` → carga desde disco en segundos, sin re-descargar.
  - **[2026-08-01] Toggle de Activación/Desactivación del Cerebro Local (Liberación de Memoria GPU)**:
    - **LocalBrain.swift**: Añadida propiedad `isEnabled` (@Published, persistida en UserDefaults `vault_brain_enabled`). Nuevo método `setEnabled(_:)` que al desactivar cancela generaciones/digestión en curso (`activeChatTask`, `digestionTask`, `downloadTask`), libera el modelo de la memoria GPU (`activeContainer = nil` + `MLX.GPU.clearCache()`) y resetea `modelStatus = .notLoaded`. Guards de `isEnabled` en `getOrLoadContainer()`, `preloadModel()`, `startDigestion()` y `chatStream()` para impedir cargas con el cerebro apagado (incluye check post-carga por si se desactiva a mitad). Tracking de tareas activas para cancelación.
    - **LocalChatView.swift**: Botón power (⏻) en el header del sidebar derecho. Encendido → `power.circle.fill` verde; apagado → `power` gris. Al desactivar, el input de chat se deshabilita y el estado muestra "Desactivado - Memoria GPU liberada". Al reactivar, el modelo se recarga bajo demanda en la próxima generación (los pesos ya están en caché de disco, sin re-descarga).
    - **Compilación**: `make xcode-build` → `ARCHIVE SUCCEEDED`. App desplegada en `/Applications/VaultSystem.app`.
  - **[2026-07-29 20:23] Integración de Inferencia de Cerebro Local en Swift/MLX**:
    - **Rust Core**: Desactivado el mock de resúmenes del daemon cognitivo interno en `core/src/lib.rs`.
    - **FFI**: Expuestas funciones FFI `get_pending_summary_notes` y `save_note_summary` vía UniFFI para que Swift controle la inserción de resúmenes reales en DuckDB.
    - **Swift UI App**: Implementada la clase `LocalBrain.swift` para orquestar la generación de resúmenes semánticos y extracción de entidades.
    - **VaultApp.swift**: Integrado el arranque asíncrono y la actualización del conteo del cerebro local.
    - **XcodeGen**: Corregido bug de parsing `path` en `apple/project.yml` al añadir `path: Info.plist`.
    - **Compilación**: `make install` OK. `ARCHIVE SUCCEEDED` y app instalada en `/Applications/VaultSystem.app`.
  - **[2026-07-27 18:44] Fix Definitivo Ghost Notes — iCloud Race Condition (v2)**:
    - **Root cause**: `process_batch` ejecutaba `DELETE FROM notes` cuando `path_obj.exists()` era `false` durante sync transitorio de iCloud. Borraba el registro que `upsert_note_item` acababa de insertar. Swift polling detectaba `update_sync_ts()` → `refreshNotes` leía DB ya sin la nota → ghost note.
    - **Fix #1 — process_batch iCloud guard** (`core/src/lib.rs`): Reintento 3×500ms → 5×600ms (3s). Si path ausente en disco, es iCloud, Y existe en DuckDB → **SKIP DELETE**. Loguea `SKIP DELETE — sync en progreso`.
    - **Fix #2 — Second-chance refresh** (`EditorViewModel.swift`): `createNewNote` y `createNewFolder` disparan un segundo `syncAll` a los 2.5s post-creación. Captura el estado real de DB después de que el watcher de Rust confirma el INSERT.
    - **Compilación**: `make build-aarch64` OK. `make xcode-build` → `ARCHIVE SUCCEEDED`.
  - **[2026-07-23 11:15] Protección contra Race Conditions de iCloud y Ghost Notes** *(mitigación previa, superada por fix 2026-07-27)*:

    - **Diagnóstico**: Las notas recién creadas desde la UI desaparecían ("ghost notes") debido a una carrera entre Swift, iCloud y los procesos asíncronos de Rust (`sync_vault` y `process_batch`). iCloud sustituye brevemente los nuevos archivos `.md` por placeholders de carga (`.sb-*`), lo que provocaba que las comprobaciones de existencia en Rust fallaran, disparando borrados de la nota en DuckDB justo después de ser creada. Además, la lógica antigua borraba intencionalmente archivos con menos de 30 caracteres asumiéndolos "stubs" de iCloud.
    - **Mitigación de Stubs**: Se eliminó la regla que borraba e ignoraba archivos de menos de 30 caracteres en `sync_vault`, permitiendo la existencia de notas vacías.
    - **Mitigación Swift**: Inyectado de contenido inicial (`# Titulo\n\n`) en `EditorViewModel.swift` al invocar `createNewNote`, previniendo que el archivo nazca vacío.
    - **Mitigación Rust**: Añadido bucle de reintento (espera de hasta 1.5s) en `lib.rs`, aplicado en la cola de eventos `process_batch` y en el Limpiador de Huérfanos de `sync_vault`. Esto otorga a Rust tolerancia para esperar a que iCloud devuelva el archivo real `.md` en lugar de ejecutar el `DELETE` en la base de datos de manera precipitada.
    - **Estado actual**: Desplegado en local, pero pendiente de revisión y debug adicional ya que el error reportó persistir según el usuario.
  - **[2026-07-22 12:45] Consistencia de Rutas y Solución a Notas Ocultas**:
    - **Rutas Canonicalizadas**: Corregido bug recurrente de desaparición inmediata de notas y carpetas al crearse/renombrarse/eliminarse. Las funciones `upsert_note_item`, `rename_item` y `delete_item` de Rust en `core/src/lib.rs` insertaban o eliminaban usando rutas tal como venían de Swift (que podían contener symlinks como `/Users/lsanmartin/obsidian`). Dado que `scan_vault` y `query_notes` canonicalizan todas las rutas internamente mediante `canonicalize_path` (ej. apuntando a la ruta física de iCloud), esto creaba discrepancias que hacían que las notas recién creadas quedaran invisibles en la UI hasta un escaneo completo posterior. Se introdujo `canonicalize_path` en estas funciones en el Core Rust para asegurar la consistencia.
    - **Compilación y Despliegue**: Compilado el núcleo de Rust (`make core`) y reconstruido/desplegado el paquete Swift nativo (`make deploy`) a `/Applications/VaultSystem.app`.
  - **[2026-07-20 ~22:00] Mitigación de Crash y Consumo de Recursos**:
    - **Diagnóstico multifactorial**: Crashes y saturación de RAM/CPU/GPU durante build e indexación en MacBook M2 Pro. Causas: (1) embeddings MLX/GPU por cada nota en scan, (2) tormenta de eventos de iCloud Drive sin debounce, (3) hidratación masiva sin throttle, (4) cognitive daemon con polling fijo cada 10s, (5) build pipeline secuencial sin control de recursos.
    - **Lazy Embeddings**: Flag `EMBEDDING_LAZY` (default true). `scan_vault()` ya no llama a MLX/GPU — almacena vector `[0;384]`. Embedding real solo bajo demanda en `query_notes()`. Reduce ~90% de GPU/CPU durante scan.
    - **generate_embedding_mlx con try_lock**: Si GPU ocupada, fallback a `generate_embedding_fast()` (CPU hash determinístico).
    - **SCANNING_PATHS + WATCHER_PENDING_EVENTS**: Watcher consulta flag de scan activo. Si hay scan, acumula eventos en cola; scan los procesa al terminar.
    - **Batch inserts**: Reducido de 500→200. Dedup de rowid post-scan (no al inicio).
    - **Stub detection**: Archivos .md con contenido <30 chars se omiten (stub de iCloud sin hidratar).
    - **Watcher debounce 2s**: Coalescing por path + filtra eventos `Modify(Metadata)` de iCloud.
    - **Cognitive daemon backoff**: 60s sin trabajo, 10s con trabajo. Usa `get_db_connection()` (no lockea `DB_CONN` directo).
    - **get_db_connection timeout**: `try_lock` + retry 100ms. Watcher retorna `None` si no puede adquirir.
    - **Makefile**: `make preflight` (RAM<8GB advierte), `make core` (solo Rust), `make app` (solo Swift). `release` depende de `preflight`.
    - **Cargo jobs=4**: `core/.cargo/config.toml` limita compilación Rust.
    - **WorkspaceManager**: `hydrateAll()` throttled (20 lote, 0.5s pausa). `scanAfterHydration()` nuevo. `addLocation()` resuelve symlinks.
    - **Archivos**: `core/src/lib.rs`, `Makefile`, `core/.cargo/config.toml`, `apple/Shared/Storage/WorkspaceManager.swift`
  - **[2026-07-14 10:55] Checkboxes Interactivos Persistentes en Modo Vista**:
    - **Habilitación de Inputs en WebView**: Inyectado script de JavaScript en `generateSafeHTML` (`MainEditorView.swift`) para remover el atributo `disabled` de los checkboxes HTML generados por Marked, y adjuntar un event listener nativo al cambio de estado (`change`) que invoca a `window.webkit.messageHandlers.toggleCheckbox.postMessage({index: index})`.
    - **Registro de Canal Swift**: Registrada la interfaz de script `toggleCheckbox` en `WebView.swift` (`makeNSView`) e implementado el callback `onCheckboxToggled` en el `Coordinator` / `WebViewModel`.
    - **Prevención de Recarga/Flicker (Update Silencioso)**: Agregado el flag `isCheckboxToggleUpdate` en el coordinator de WebView. Al dispararse el callback, se activa el flag para que la llamada reactiva subsiguiente a `updateNSView` sincronice el estado HTML actualizado en memoria (`lastLoadedHTML`) pero omita invocar a `loadHTMLString()`. Esto previene la recarga del documento, eliminando el parpadeo de pantalla y salvando la posición de scroll exacta.
    - **Edición en EditorViewModel**: Diseñada la función `toggleMarkdownCheckbox(index:tabId:)` en `EditorViewModel.swift` que parsea el contenido Markdown activo de forma de componentes separados por línea, localiza el checkbox `N` mediante expresiones regulares (`\[([ xX])\]`), alterna su estado (`[ ]` <-> `[x]`), actualiza el modelo `TabItem` y persiste los cambios síncronamente en el disco mediante la función `saveNote`.
    - **Compilación y Despliegue**: Compilado y desplegado de forma segura tanto en modo Debug (`xcodebuild`) como Release (`make deploy`), quedando instalado de forma funcional en `/Applications/VaultSystem.app`.
  - **[2026-06-27 20:26] Remoción Completa de Índices Secundarios**:
    - **Evitar Invalidación de DuckDB**: Removidos todos los `CREATE INDEX` secundarios en columnas `VARCHAR` en `core/src/lib.rs`. Esto resuelve de forma definitiva el error interno de DuckDB al eliminar filas sobre índices de texto (`Failed to delete all rows from index. Only deleted 0 out of X rows`), manteniendo la base de datos estable. La velocidad se conserva óptima vía escaneo secuencial.
    - **Recreación Automática**: Introducido el flag `_schema_no_indices` en `init_knowledge_base` para forzar la eliminación de la base de datos previa y asegurar una migración limpia libre de índices corruptos.
  - **[2026-06-27 20:21] Normalización y Resolución de Enlaces Simbólicos**:
    - **Compatibilidad con iCloud**: Implementada la resolución de enlaces simbólicos (`resolvingSymlinksInPath()` en Swift y `canonicalize()` en Rust) tanto en `EditorViewModel.swift` (`currentPath`) como en las funciones del core de Rust (`scan_vault`, `query_notes`, `query_recent_...`, `remove_vault_path`). Esto soluciona la discrepancia de rutas físicas y lógicas (ej: `/Users/lsanmartin/obsidian` vs `/Users/lsanmartin/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian`), previniendo grillas vacías.
  - **[2026-06-27 20:13] Deduplicación Preventiva de Indices en DuckDB**:
    - **Limpieza de rowid**: Integrada una consulta de limpieza automatizada (`DELETE WHERE rowid NOT IN (SELECT MIN(rowid)...)`) que se ejecuta preventivamente tanto al iniciar la base de datos como al lanzar cualquier re-indexado (`scan_vault`). Esto elimina de forma definitiva e instantánea los registros duplicados remanentes en las tablas `notes`, `semantic_summaries` y `domain_metadata`, sin requerir borrado de base de datos.
  - **[2026-06-27 20:08] Corrección de Duplicación y Reinicio de Workspace**:
    - **Observer de Selección en Sidebar**: Vinculado `resetToWorkspaceRoot` al observador de cambio `.onChange(of: viewModel.selectedLocationId)` en `MainEditorView.swift`. Esto soluciona un bug de SwiftUI en macOS donde la selección del Listado no ejecutaba el TapGesture del NavigationLink de forma confiable, previniendo que `currentPath` se quedara apuntando al workspace anterior y causara carpetas duplicadas.
  - **[2026-06-27 20:03] Reinicio de Filtro al Cambiar Workspace**:
    - **Reinicio del Filtro de Exploración**: Modificado `resetToWorkspaceRoot` en `EditorViewModel.swift` para restablecer automáticamente `explorationFilter = .all` al cambiar de workspace en la barra lateral. Esto asegura que la vista siempre cargue la jerarquía completa de notas en lugar de quedarse atascada en filtros transitorios (como notas recientes o marcadas).
  - **[2026-06-27 19:57] Estilizado del Fondo RSVP**:
    - **Fondo Sólido Oscuro**: Cambiado el color de fondo y el `.presentationBackground` de la hoja RSVP a un gris oscuro sólido `#1E1E1E` (`Color(red: 30/255, green: 30/255, blue: 30/255)`), ofreciendo una paleta contrastada y uniforme.
  - **[2026-06-27 19:49] Suavizado de Brillo en Lector RSVP**:
    - **Atenuación de Opacidad**: Ajustada la opacidad del texto naranja del RSVP Reader a `0.85` en `MainEditorView.swift` para suavizar el contraste visual y mejorar la legibilidad prolongada.
  - **[2026-06-27 19:31] Eliminación del Crash Interno de Indexación DuckDB (ART Checkpoint Error)**:
    - **Remoción de Unique Constraints**: Eliminadas las restricciones `PRIMARY KEY` y `FOREIGN KEY` de todas las tablas de la base de datos DuckDB, previniendo el bug interno de DuckDB al serializar índices ART (`TransformToDeprecated` invalidation error). Se crearon índices estándares en `id` y `path` para mantener consultas ultra rápidas.
    - **Controlador de Borrado Preventivo**: Modificados los bloques de inserción en `scan_vault`, `start_watcher` e `import_domain_specs` para ejecutar una eliminación explícita (`DELETE WHERE id = ?`) previa a la inserción, emulando de forma segura el comportamiento de `INSERT OR REPLACE` / `INSERT OR IGNORE`.
    - **Auto-recreación Dinámica**: Implementado validador en `init_knowledge_base` que detecta si el esquema local requiere migración o si la base de datos fue invalidada por DuckDB, eliminando preventivamente el archivo físico `vault.duckdb` y reconstruyendo el esquema correcto en frío.
  - **[2026-06-27 14:41] Resolución de Bloqueo de Acceso Concurrente DuckDB**:
    - **DbConnectionGuard con Deref**: Implementada la estructura `DbConnectionGuard` en Rust que encapsula la conexión a DuckDB y una guardia de exclusión mutua global (`MutexGuard<'static, ()>`). Utiliza las características `Deref` y `DerefMut` para permitir el uso directo y transparente del objeto connection original.
    - **Exclusión Mutua Global (DB_QUERY_MUTEX)**: Introducido el mutex global `DB_QUERY_MUTEX` que se bloquea al obtener la conexión en `get_db_connection()` y se libera automáticamente cuando la guardia retornada sale del ámbito de ejecución de cada hilo (Thread 2 y Thread 4). Esto previene que se lancen lecturas (SELECT) e inserciones transaccionales concurrentes sobre la misma tabla `notes`, evitando corrupción de memoria y crashes SIGBUS/EXC_BAD_ACCESS.
  - **[2026-06-27 14:35] Corrección al Revelar Carpeta Contenedora**:
    - **Reinicio del Filtro de Exploración**: Modificado `revealInSidebar` en `EditorViewModel.swift` para forzar `explorationFilter = .all` al hacer clic en el botón revelar carpeta. Esto asegura que la aplicación cambie de la lista plana de "Recientes" o "Marcadas" a la estructura de árbol del directorio original, posicionando y seleccionando correctamente la nota en su ubicación correspondiente.
  - **[2026-06-27 14:17] Lector RSVP y Mejoras de Enfoque Visual**:
    - **Renombrado a RSVP**: Actualizados botones, títulos y referencias del speed reader al estándar universal RSVP.
    - **Liquid Glass & Color Tint**: Aplicado `.presentationBackground(.ultraThinMaterial)` en combinación con el color de fondo dinámico de la nota actualizada (`noteBackgroundColor` con opacidad del 85%) sobre el modal.
    - **Dimensionamiento de Enfoque**: Incrementadas las dimensiones del modal a 750x480pt y la tipografía a 64pt para mejorar la experiencia de lectura.
    - **Foco del Fondo (Dimming/Blur)**: Integrado desenfoque (`.blur(radius: 3)`) y oscurecimiento (`.opacity(0.45)` y máscara de opacidad negra del 30%) sobre el editor subyacente al activar el lector RSVP.
  - **[2026-06-27 13:46] Previsualización de Versiones de Cambios**:
    - **Panel de Previsualización**: Implementada la hoja emergente (.sheet) estilizada bajo Liquid Glass (`.ultraThinMaterial`) para visualizar el contenido exacto de una nota en un commit específico sin alterar el estado actual.
    - **Row Interaction**: Añadido `.onTapGesture` sobre las filas del listado de historial de cambios en `GitHistorySidebar` para cargar dinámicamente y abrir la previsualización del commit clicado.
    - **Extensión de Tipo**: Implementada la conformidad a `Identifiable` para `GitCommit` extendiendo el tipo en Swift para facilitar la presentación con sheets nativas.
  - **[2026-06-27 13:32] Soporte de Normas Gráficas Liquid Glass (macOS Tahoe)**:
    - **Materiales Translúcidos**: Integrado `.ultraThinMaterial` en barras de herramientas, cabeceras y barra lateral de navegación para habilitar el motor de refracción y profundidad dinámico nativo de macOS Tahoe.
    - **Compatibilidad y Accesibilidad**: Agregada la variable de entorno `@Environment(\.accessibilityReduceTransparency)` para desactivar automáticamente la refracción translúcida y degradar a colores sólidos estáticos (`macSidebar` y `macBackground`) cuando el usuario solicita reducción de transparencia en macOS.
  - **[2026-06-27 13:26] Auto-inicialización de Repositorios Git**:
    - **Inicilización Automática**: Implementada la función `init_git_repo` en el Core de Rust que verifica la existencia de la carpeta `.git` en el espacio de trabajo, inicializando un nuevo repositorio Git y realizando un commit inicial vacío (`--allow-empty`) para habilitar los comandos de historial de forma inmediata.
    - **Integración con Swift**: Invocado `initGitRepo` desde `WorkspaceManager.swift` al inicializar el espacio de sistema (`.vault_system/system_workspace`), restaurar las ubicaciones registradas en el arranque, o al añadir nuevos directorios.
    - **Preservación de TCC y Symlinks**: Ajustado el comando git para ejecutarse con la bandera `-C` utilizando la ruta original seleccionada por el usuario (sin resolver canonicalize) para mantener la cadena de permisos TCC intacta en macOS.
  - **[2026-06-27 09:10] Botón Guardar, Indicador y Comando+S**:
    - **Indicador Temporal**: Mostrado el string `lastSavedText` en la barra superior en formato monoespaciado (`HH:mm:ss`). Se inicializa con la fecha de modificación real en disco.
    - **Botón Guardar Físico**: Agregado botón en la barra superior sólo visible en modo de edición para guardar cambios de inmediato.
    - **Atajo Cmd + S**: Vinculado atajo `.keyboardShortcut("s", modifiers: .command)` nativo sobre el botón Guardar.
    - **Alineación de Números e Intervalos**: Ajustado el offset Y a `-1.5pt` y acotados los límites Y con `max(0, ...)` resolviendo desfase visual al aplicar un `lineSpacing` de `4.0pt` en el editor.
  - **[2026-06-27 08:40] Números de Línea y Selección Avanzada en Editor**:
    - **Regla de Números**: Implementada la subclase `LineNumberRulerView` de `NSRulerView` para dibujar números de línea minimalistas y discretos con ancho de 45pt.
    - **Gestos de Selección en Regla**: Soportado click primario para seleccionar toda la línea y `Shift + Click` para extender la selección actual hasta la línea clicada.
    - **Cmd + L**: Subclase `EditorTextView` que intercepta `Cmd + L` para seleccionar toda la línea o conjunto de líneas activas de la selección.
    - **Persistencia y Toggle**: Creado botón discreto en cabecera con icono `list.number` para alternar la visibilidad, persistiendo el estado en `UserDefaults` (`"vault_show_line_numbers"`).
  - **[2026-06-27 08:15] Menú Contextual en Background de Segunda Columna**:
    - **Nueva Nota y Nueva Carpeta**: Se añadió un `.contextMenu` al fondo (background) del ScrollView en `MainContentColumn` (tanto para modo de vista `.list` como para cuadrícula).
    - **Acciones Directas**: Permite crear una nueva nota (`createNewNote`) o una nueva carpeta (`createNewFolder`) mediante click secundario en el espacio vacío de la columna de listado de notas.
  - **[2026-06-26 16:15] Filtros de Exploración y Estética del Editor en Modo Oscuro**:
    - **Filtros de Exploración (Vistas)**: Creado el enum `ExplorationFilter` e implementadas funciones FFI en Rust (`query_recent_created` y `query_recent_modified`) ordenando por `created_at` y `modified_ts` en DuckDB. Diseñada sección de "Vistas" (Favoritos, Recientes, Pins) en el Sidebar.
    - **Persistencia de Workspace**: Corregida la inicialización asíncrona del path del workspace para que se restaure de manera instantánea el último workspace activo guardado al abrir la aplicación.
    - **Fondo Modo Oscuro #1E1E1E**: Modificado el fondo de `NSTextView` en `CodeEditor.swift` y de las vistas SwiftUI del visor de nota para pintar un color gris oscuro sólido `#1E1E1E` (tipo VS Code) en lugar del fondo translúcido y clear por defecto en modo oscuro.
    - **Indicador de Modo Edición**: Diseñado un badge flotante "Modo Edición" y un borde naranja sutil (overlay border) alrededor del editor de texto para indicar de manera inequívoca cuándo se está en modo edición.
  - **[2026-06-26 16:00] Resolución de Compilación del Core y Despliegue de XCFramework**:
    - **Limpieza Preventiva de Almacenamiento**: Se detectó almacenamiento crítico en disco (1.5 GiB libres) y se realizó una purga segura de cachés de Xcode DerivedData y Homebrew para recuperar **4.2 GB** de espacio libre, permitiendo compilar sin fallos por `no space left on device`.
    - **Generación de XCFramework**: Se recompiló el Core Rust para Apple Silicon y se generaron los enlaces FFI usando UniFFI Bindgen, empaquetándolos exitosamente en `target/apple_core.xcframework`.
    - **Build y Despliegue**: Se resolvió la dependencia faltante de Xcode, logrando un build exitoso (`ARCHIVE SUCCEEDED`) y desplegando la aplicación en `/Applications/VaultSystem.app`.
  - **[2026-06-22 14:47] Revelar Nota en Sidebar y Solución de Historial Git**:
    - **Revelar Nota**: Creado método `revealInSidebar` en `EditorViewModel` e integrado en `EditorAreaView` (icono `folder.circle` a la izquierda de Historial) para expandir ancestros, seleccionar la nota activa en el Sidebar y navegar a su directorio contenedor (focalizando el Grid de la segunda columna).
    - **Historial Git**: Añadida la bandera `-c safe.directory=*` en todas las ejecuciones de `git` en `core/src/lib.rs` (add, commit, log, show) para eludir restricciones de directorio seguro de Git dentro del contexto de ejecución de la app nativa en macOS.
  - **[2026-06-22 00:18] Ajuste Fino de Padding en Notas**:
    - **Visualización (Ver)**: Reducido padding del cuerpo HTML a `5.125rem` (82px, -10px sobre el aumento anterior).
    - **Edición (Editar)**: Reducido `textContainerInset` de `CodeEditor` a `NSSize(70, 70)` (-10px sobre el aumento anterior).
  - **[2026-06-21 20:10] Padding Adicional de Notas**:
    - **Visualización (Ver)**: Incrementado el padding del cuerpo HTML a `4.5rem` (72px, +20px adicionales).
    - **Edición (Editar)**: Incrementado el `textContainerInset` de `CodeEditor` a `NSSize(60, 60)` (+20px adicionales).
  - **[2026-06-21 20:05] Padding de Notas y Foco de Cursor**:
    - **Visualización (Ver)**: Incrementado el padding del cuerpo HTML a `3.25rem` (52px, +20px sobre el original).
    - **Edición (Editar)**: Incrementado el `textContainerInset` de `CodeEditor` a `NSSize(40, 40)` (+20px sobre el original).
    - **Cursor**: Añadida asignación asíncrona de primer respondedor (`makeFirstResponder`) en `CodeEditor` para posicionar automáticamente el cursor de escritura al alternar a modo de edición.
  - **[2026-06-21 19:54] Integración NSApp.appearance para Sincronización del Sistema**:
    - **AppKit NSApp.appearance**: Añadida la llamada a `NSApp.appearance = nil` para delegar al sistema el aspecto de las ventanas cuando está seleccionado "Sistema", y forzar `.darkAqua` o `.aqua` según corresponda, solucionando el bug de preferredColorScheme.
    - **Persistencia del Tema**: Guardado y restauración del tema seleccionado en `UserDefaults` usando la clave `vault_selected_theme`.
  - **[2026-06-21 19:45] Corrección del Tema del Sistema (preferredColorScheme)**:
    - **SwiftUI preferredColorScheme**: Eliminado el acoplamiento forzado en la columna de la barra lateral que forzaba el modo oscuro al seleccionar el tema del sistema.
    - **Propiedad Dinámica**: Trasladado el mapeo de colorScheme al enum `AppTheme`.
    - **CodeEditor**: Modificado el coloreado de sintaxis y color de inserción para reaccionar dinámicamente al aspecto actual (`effectiveAppearance`) cuando está en modo sistema.
    - **Vista Web (HTML)**: Corregidas las variables CSS en la vista web para el tema del sistema, agregando soporte dinámico para light y dark modes.
  - **[2026-06-21 19:40] Funcionalidad de Fijado (Pin)**:
    - **Persistencia**: Almacenamiento local de rutas fijadas (`pinnedPaths`) mediante `UserDefaults`.
    - **Ordenamiento**: Modificada la lógica de ordenación para colocar elementos fijados al inicio de la lista/árbol (carpetas primero, luego notas).
    - **Visualización**: Icono de pin naranja (`pin.fill`) en `VaultTreeRow`, `FileRowView` y `NoteCard`.
    - **Menú Contextual**: Acción "Fijar"/"Desfijar" en `VaultContextMenu` y `NoteCard` context menu.
  - **[2026-06-21 19:30] Alineación de Chevrons y Acceso a Finder**:
    - **Alineación**: Ajustado el padding horizontal de los chevrons en el árbol para alinearse con su nivel de profundidad respectivo en lugar de pegarse al borde izquierdo.
    - **Menú Contextual**: Botón "Mostrar en Finder" en VaultContextMenu (abre carpetas o revela notas).
    - **Encabezado**: Botón junto al nombre de la carpeta actual para abrir en Finder.
  - **[2026-06-21 18:25] Soberanía Cognitiva (Fase 1-4)**:
    - **DuckDB & Core FFI**: Creada tabla `domain_metadata` y refactorizado el escáner a `scan_domain_metadata` para parsear la tríada completa (`_memory.md`, `_specs.md`, `lore.md`).
    - **UI Scratchpad**: Componente `BottomSheetScratchpadView` en SwiftUI con drag vertical y snaps, persistido en `current_session.md`, con botón de Consolidar (`consolidate_session` en Rust).
    - **Telemetría Nativa**: `TelemetryManager` singleton en Swift que reporta remociones de workspace, guardándolos en `telemetria.log` e insertando logs de fricción a la tabla `telemetry` en DuckDB via FFI (`log_friction_event`).
    - **API de RAG**: Añadida la herramienta MCP `vault_export_domain_metadata` para exportar en JSON optimizado todos los metadatos de dominio.
    - **MCP Tools**: Expuestas `vault_get_domain_context`, `vault_log_friction` y `vault_export_domain_metadata`.
  - **[2026-06-17 10:20] Diagnóstico Historial Git**:
    - **Telemetría en Core**: Añadidos logs detallados en `get_file_history` (Rust) para rastrear errores de comandos Git y verificar el conteo de commits detectados.
    - **Revisión de Persistencia**: Verificado que `save_note` realiza correctamente el ciclo `git add` + `git commit`.
  - **[2026-06-17 10:10] Ayuda de Sintaxis y Redondeo**:
    - **Panel de Ayuda**: Añadido icono 'i' con Popover explicando soporte Markdown/HTML/LaTeX.
    - **Estética Editor**: Aplicado `cornerRadius(15)` al `CodeEditor` y centrado a 850px para consistencia visual con Preview.
  - **[2026-06-17 09:45] Refactor de Independencia UI**:
    - **Aplanamiento de HSplitView**: Eliminada la anidación para independizar los tiradores de Sidebar y Cards.
    - **Lógica de Ocultación**: Sincronizada la visibilidad de Sidebar y Cards bajo un mismo toggle.
    - **Dimensiones**: Ajustado `minWidth` a 250pts para mayor flexibilidad.
  - **[2026-06-16] Motor Unicode & Sandbox Fix**:
    - Soporte universal de acentos y normalización NFD/NFC.
    - Migración de tokens MCP a `UserDefaults` para evitar pérdida en recompilaciones.

## Pendientes Próxima Sesión
- **Debug Ghost Notes**: Continuar investigando por qué la nota recién creada desaparece de la UI a pesar del exitoso `INSERT EXITOSO` en `process_batch` y de las mitigaciones implementadas (stub-removal, retry loop, content injection). Identificar dónde y cómo se elimina o filtra el registro en DuckDB.
- **Build release a /Applications**: `cd ~/dev/vault-system && make release`
- **Refinamiento de RAG Local**: Integrar la generación de embeddings nativos en Apple Silicon (MLX/Metal) directamente en la tabla `domain_metadata` para RAG local offline.
- **Validación de Rendimiento**: Comprobar tiempo de respuesta del scanner en vaults de gran escala (>1000 carpetas).
- **Consistencia UI**: Sincronizar el estado visual del botón del Scratchpad tras la consolidación exitosa.
- **[AI Engine — Fase 1]**: Crear scaffolding `core/src/ai_engine/` + feature flag `local-ai` en `Cargo.toml`. Ver `docs/2026-07-02-plan-local-ai-engine.md` y `docs/ADR-001-local-inference-engine.md`.

## Análisis Estratégico (2026-07-20)
### Portabilidad a Intel Mac
- **Viable con ~30 min de trabajo**: MLX es el único blocker — no existe para x86_64.
- **Solución**: Hacer `mlx-rs` opcional vía feature flag (`mlx-accel`) en `core/Cargo.toml`. Intel compila con `--no-default-features`, cae a `generate_embedding_fast()`.
- **Makefile**: Agregar target `build-x86_64` con `--no-default-features`. Xcode cambiar `-arch arm64` → `-arch x86_64`.
- **DuckDB y UI Swift** corren nativos en Intel sin cambios.

### Portabilidad a iOS/iPadOS/Android
- **Vault-system (SwiftUI nativo) → NO**: UI usa componentes exclusivos de AppKit (HSplitView, NSRulerView, NSTextView, NSApp). No hay atajo — requiere rewrite completo de UI.
- **Alternativa real**: vault-app (Tauri + React, en ~/dev/vault-app/) ya compila para iOS/Android con el mismo core Rust. De hecho ya tiene código `#[cfg(target_os = "ios")]` y corre en iPad Simulator.
- **Opción estratégica**: Extraer `vault-core` como crate independiente compartido entre vault-system (macOS) y vault-app (cross-platform). vault-app ganaría scan, indexación, búsqueda semántica y workspaces sin reescribir nada.
- **Nota**: vault-app y vault-system son proyectos distintos. vault-app cambiará de nombre próximamente.

### Relación vault-system ↔ vault-app
- Son proyectos independientes con orígenes y stacks diferentes: vault-system (SwiftUI nativo macOS) vs vault-app (Tauri + React cross-platform).
- Comparten concepto (gestión de vault/knowledge) pero no código base.
- El core Rust (DuckDB, embeddings, scan) es conceptualmente similar pero implementado por separado en cada uno.
- Decisión pendiente: unificar core, mantener separados, o converger bajo un proyecto. Ver `_lore.md` cuando se cree.

## Decisiones Arquitectónicas
- **[ADR-001 — 2026-07-02]**: Motor de inferencia local `llama-cpp-2` (MIT) como engine in-process.
  - Opt-in via feature flag `local-ai`. Sin impacto en binario base.
  - Engine detrás de `trait InferenceEngine` (swappable cuando mlx-rs madure para LLM).
  - Fine-tuning: contrato declarado, implementación es stub hasta Fase 5+.
  - Modelos GGUF Apache 2.0/MIT únicamente. Catálogo en `docs/models/catalog.json`.
  - Hook de inserción: `lib.rs` L1177 (comentario "// Aquí en un futuro se llamará al modelo local").
  - Implementa Fase 2 del PLAN_ESTRATEGICO_DEV2 ("El Digestor").

## ⚠️ DuckDB SQL Compatibility — Reglas críticas

> **2026-08-05**: El sidebar dejó de funcionar porque `AUTOINCREMENT` no es válido en DuckDB.
> Al agregar `INTEGER PRIMARY KEY AUTOINCREMENT` en `chat_messages`, `execute_batch`
> falló completo y **ninguna** tabla se creó (ni `notes`, ni `telemetry`, ni nada).
> La DB quedaba en 12KB sin tablas. Tardamos 2h en encontrar la causa.

### Reglas para modificar el schema (lib.rs init_knowledge_base)

1. **NUNCA usar `AUTOINCREMENT`**. DuckDB auto-incrementa `INTEGER PRIMARY KEY` por defecto.
2. **Sintaxis válida**: `id INTEGER PRIMARY KEY` (sin AUTOINCREMENT, sin SERIAL, sin GENERATED)
3. **TIMESTAMP**: usar `TIMESTAMP DEFAULT now()` (válido)
4. **BOOLEAN**: usar `BOOLEAN DEFAULT true/false` (válido)
5. **Verificar después de cada cambio**: `SELECT * FROM notes LIMIT 1` debe funcionar.
6. **Una sola llamada a `init_knowledge_base()`**: ahora protegida con `DB_INITIALIZED` AtomicBool.
7. **`execute_batch` falla completo si hay error de sintaxis**: todas las tablas o ninguna.

### Lecciones aprendidas

- `execute_batch` es atómico en DuckDB: un error de sintaxis en una tabla rompe todo el batch.
- `init_knowledge_base` devolvía `"Error de Esquema"` pero nadie leía el retorno (`_ = init_knowledge_base()`).
- Agregar `add_telemetry_log` en init ayuda a diagnosticar.
- La DB en sandbox está en `~/Library/Containers/cl.nicelio.vault.VaultSystem/Data/.vault_system/`.

## ⚠️ LIMIT en queries de navegación — no usar

> **2026-08-05**: Agregamos `LIMIT 5000` a `query_notes` para evitar congelamiento con 277K notas.
> Esto rompió la navegación: carpetas como `06-Desarrollo` desaparecían porque quedaban
> fuera del top 5000 (ordenadas por created_at DESC).

### Regla
- **NUNCA usar LIMIT en queries de navegación** (las que alimentan el sidebar/grid).
- Para navegación por carpetas, usar `query_children(parent_path)` que devuelve solo
  los hijos directos de una carpeta — naturalmente acotado, sin límite artificial.
- `query_notes` sin límite se usa solo para búsqueda full-text.

### Lección
- Si una carpeta existe en disco pero no en el sidebar, revisar si hay LIMIT cortando resultados.

## [2026-08-16 14:50] Orquestación Determinista y Quick Actions
- **Core Loop**: Se modificó `sendLocal` en `LocalChatView.swift` para soportar un `TaskPlan` que rastrea items pendientes de una herramienta recursiva.
- **Stop-Hook**: Swift ahora intercepta el fin del turno y reinicia el prompt hacia el modelo si el plan no está completado, ahorrando tokens de planificación.
- **Macro-Tools**: Se creó `audit_memory_consistency` para delegar chequeos profundos de archivos directamente en Swift. Las respuestas se vuelcan a Markdown en `_harness/` y el modelo lee con `read_file`, protegiendo la GPU de OOM.
- **Fallbacks**: Se añadieron intercepciones a nivel de parseo `[CMD: ...]` para autocorregir alucinaciones (como `vault_get_domain_context` o sintaxis con paréntesis).
- **UI Quick Actions**: Se implementó un Dropdown Menu y soporte para Slash Commands (`/audit`, `/list`) para emitir llamadas a herramientas directamente, previniendo totalmente las alucinaciones en operaciones frecuentes. Adicionalmente se inyectaron directivas de Anti-Alucinación (Semantic Framing) en la expansión de los comandos para asegurar que el LLM no devuelva disculpas ni confabulaciones al recibir los reportes desde Swift.
- **UI Metadatos Visuales**: Se agregó el despliegue de fecha y hora de última modificación del archivo (`dd/MM/yy HH:mm`) directamente en el listado de notas (`NoteCard`) y en la cabecera del modo vista/edición (`EditorAreaView`).
