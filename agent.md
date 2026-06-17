# Contexto del Agente

Última actualización: [2026-06-15 22:15]

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas (`DragGesture`), y navegación jerárquica (`VaultTreeView`).
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento unificado de MD, HTML y LaTeX con detección automática.
- **Capa 3: Core (Rust) & Seguridad MCP**: Búsqueda semántica (DuckDB + MLX), File Watcher, Puente IPC y RBAC de MCP.

## Resumen Técnico
- **Objetivo**: Implementación de seguridad estricta para MCP (RBAC de 3 capas), panel de telemetría y buscador de texto nativo en la UI.
- **Cambios Realizados**:
  - **[2026-06-16 19:00] Motor de Búsqueda Unicode & Zero-Delay Navigation**:
    - **Soporte Universal de Acentos y 'ñ' (NFD/NFC)**: Se reemplazó el filtro genérico de carácteres por el uso de propiedades Unicode (`\p{M}*`) y normalización en memoria dentro de Rust, resolviendo el bug silencioso de macOS con carácteres especiales descompuestos en Finder.
    - **Búsqueda por Intersección Estricta (AND)**: La lógica de consulta de base de datos ahora divide la frase en N tokens y exige que cada término exista individualmente en el archivo (vía `regexp_matches`), emulando comportamientos avanzados de motores de búsqueda.
    - **Navegación en UI (Zero-Delay)**: Se modificó la vista `EditorViewModel` para que las selecciones de carpetas dentro del mismo workspace procesen el redibujado de la grilla 100% en memoria en Swift (`updateGridForCurrentPath()`), deteniendo los escaneos innecesarios a través del FFI de DuckDB. Se estabilizó a 60FPS constantes.
    - **Recuperación Fallback MCP**: Se reintegró el pipeline de tokens (`McpTokenRecord`) de la CLI que había colapsado durante el refactor del core.
  - **[2026-06-16 23:30] Depuración de Búsqueda UI y Sandbox**:
    - **Fix UI Buscador**: Corregido bug crítico en la renderización de Swift (`updateGridForCurrentPath`) que causaba la mezcla de notas previas con los resultados de búsqueda de DuckDB. La grilla ahora muestra limpia y exclusivamente los archivos que hicieron `match`.
    - **Persistencia MCP (Fix Sandbox)**: Migrada exitosamente la persistencia de `mcp_tokens` desde archivos en el Sandbox (efímeros ante compilaciones en Xcode) hacia `UserDefaults` nativo en macOS. El core de Rust ahora maneja los tokens en memoria (vía `LazyLock<Mutex>`) y se sincroniza dinámicamente con Swift usando `load_mcp_tokens_from_json` y `export_mcp_tokens_to_json` a través de FFI, garantizando que no se pierdan al recompilar.
    - **Highlights en Vista**: Se inyectó `mark.js` usando escapado de interpolaciones dinámicas para resaltar el texto buscado directamente dentro del WebKit WebView.
  - **RBAC en Daemon (Rust)**: Implementadas banderas modulares (`--read-only`, `--allow-metadata`, `--allow-system`) en el proxy CLI para validar el acceso al filesystem antes de enviar JSON-RPC a la App.
  - **Filtros DuckDB (Core)**: La app principal intercepta parámetros inyectados por el Daemon (`exclude_metadata`, `exclude_system`) para añadir cláusulas dinámicas (`NOT LIKE '%/_%'`) y evitar fuga de información en `vault_search`.
  - **Panel de Telemetría**: Añadida vista `TelemetryView` en SwiftUI con estilo terminal hacker, que hace polling a un buffer seguro (`Mutex<Vec<String>>`) mantenido por Rust.
  - **Buscador Nativo (Cmd+F)**: Se implementó una interfaz de búsqueda directa mediante `.keyboardShortcut("f")` en SwiftUI que despacha dinámicamente un menú oculto a través de `NSApp.sendAction` para disparar el `performFindPanelAction` del `NSTextView`. El WebView (Preview Mode) fue excluido de esta acción por carecer de la API `isFindInteractionEnabled` nativa en macOS AppKit.
  - **Mantenimiento**: Arreglada la advertencia `.onChange(of: noteId)` en `CognitiveRadarView` usando la sintaxis de cero parámetros (macOS 14+).

## Pendientes Próxima Sesión
- **Generación de Archivos y Metadatos**: Terminar la integración de metadatos (`_memory.md` y `_lore.md`) dentro de los flujos automáticos.
- **Búsqueda Avanzada WebView**: Desarrollar componente de UI customizado para buscar dentro de la vista `Ver` utilizando la API de inyección `webView.findString()`.
- **Dashboard de Historial**: Lista interactiva (clickable) para reanudar contextos de trabajo rápidamente.
- **Vault App Store**: Sistema de gestión para harnesses, workflows, skills y MCPs oficiales.
- **Artefactos Seguros**: Compartición de notas/artefactos con opciones de seguridad.
