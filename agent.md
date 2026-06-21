# Contexto del Agente

Última actualización: [2026-06-21 18:25]

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas independientes (`HSplitView` plano), y navegación jerárquica.
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento híbrido de MD, HTML y LaTeX con ayuda de sintaxis in-app.
- **Capa 3: Core (Rust) & Seguridad MCP**: Búsqueda semántica, File Watcher con persistencia Git (Auto-Save), y RBAC de MCP.

## Resumen Técnico
- **Objetivo**: Implementación nativa de Soberanía Cognitiva (Tríada de metadatos, Scratchpad SwiftUI y telemetría de fricción).
- **Cambios Realizados**:
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
