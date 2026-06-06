# Contexto del Agente

Última actualización: [2026-06-06 14:35]

## Lineamientos de Dominio: Taxonomía de Tres Capas
... (Mantenido igual) ...

## Resumen Técnico
- **Objetivo**: Integración de DuckDB, Persistencia iCloud y Editor Multi-Pestaña.
- **Estado Actual**
  - **Editor Multi-Pestaña**: ¡Implementado!
    - Interfaz SwiftUI con barra de pestañas horizontal.
    - Soporte para edición (Markdown) y previsualización (Render MD/HTML).
    - Atajos de teclado funcionales: `Cmd+S` (Guardar), `Cmd+R` (Alternar Preview).
  - **Sincronización Reactiva (Motor)**:
    - Rust ahora permite consultar notas por término de búsqueda (`query_notes`).
    - Implementada función de guardado persistente en disco (`save_note`) conectada a la UI.
    - Crate `notify` integrada en el core para la próxima fase de watching automático.
  - **Build**: XCFramework funcional para ARM64.

## Pendientes Próxima Sesión
- **File Watcher Activo**: Implementar el bucle de eventos en Rust para que la UI se refresque automáticamente cuando la IA escriba archivos en disco.
- **Renderizado HTML Real**: Integrar una WebView en `PreviewView` para interpretar correctamente el switch a HTML solicitado por el usuario.
- **Búsqueda Semántica**: Integrar embeddings sobre el contenido almacenado en DuckDB.
