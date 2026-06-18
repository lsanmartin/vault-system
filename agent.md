# Contexto del Agente

Última actualización: [2026-06-17 10:30]

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas independientes (`HSplitView` plano), y navegación jerárquica.
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento híbrido de MD, HTML y LaTeX con ayuda de sintaxis in-app.
- **Capa 3: Core (Rust) & Seguridad MCP**: Búsqueda semántica, File Watcher con persistencia Git (Auto-Save), y RBAC de MCP.

## Resumen Técnico
- **Objetivo**: Refinamiento de la interfaz de usuario, independización de columnas y diagnóstico del historial de cambios Git.
- **Cambios Realizados**:
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
- **Optimización de Historial**: Si la telemetría confirma que Rust obtiene commits pero SwiftUI no los muestra, revisar el flujo de datos en `GitHistorySidebar`.
- **Arquitectura MCP Broker (MacOS Nativo)**: Abordar la implementación del broker local basado en `vault://register` y XPC para centralizar la gestión de permisos MCP (ver `docs/2026-06-17-mcp-broker-macos.md`).
- **Búsqueda en WebView**: Componente nativo para buscar dentro del modo Preview.
- **Persistencia de Layout**: Guardar el ancho de las columnas entre sesiones.
