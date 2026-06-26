# Contexto del Agente

Última actualización: [2026-06-26 16:15]

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas independientes (`HSplitView` plano), y navegación jerárquica.
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento híbrido de MD, HTML y LaTeX con ayuda de sintaxis in-app.
- **Capa 3: Core (Rust) & Seguridad MCP**: Búsqueda semántica, File Watcher con persistencia Git (Auto-Save), y RBAC de MCP.

## Resumen Técnico
- **Objetivo**: Implementación nativa de Soberanía Cognitiva (Tríada de metadatos, Scratchpad SwiftUI y telemetría de fricción).
- **Cambios Realizados**:
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
- **Refinamiento de RAG Local**: Integrar la generación de embeddings nativos en Apple Silicon (MLX/Metal) directamente en la tabla `domain_metadata` para RAG local offline.
- **Validación de Rendimiento**: Comprobar tiempo de respuesta del scanner en vaults de gran escala (>1000 carpetas).
- **Consistencia UI**: Sincronizar el estado visual del botón del Scratchpad tras la consolidación exitosa.
