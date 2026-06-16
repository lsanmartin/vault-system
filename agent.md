# Contexto del Agente

Última actualización: [2026-06-15 22:15]

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas (`DragGesture`), y navegación jerárquica (`VaultTreeView`).
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento unificado de MD, HTML y LaTeX con detección automática.
- **Capa 3: Core (Rust) & Seguridad MCP**: Búsqueda semántica (DuckDB + MLX), File Watcher, Puente IPC y RBAC de MCP.

## Resumen Técnico
- **Objetivo**: Implementación de seguridad estricta para MCP (RBAC de 3 capas), panel de telemetría y buscador de texto nativo en la UI.
- **Cambios Realizados**:
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
