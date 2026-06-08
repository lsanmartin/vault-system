# Contexto del Agente

Última actualización: [2026-06-07 11:39]

## Lineamientos de Dominio: Taxonomía de Tres Capas
... (Mantenido igual) ...

## Resumen Técnico
- **Objetivo**: Consolidación de un Entorno de Trabajo Reactivo y Táctico.
- **Estado Actual**
  - **Editor Inteligente**: ¡Implementado!
    - Motor nativo `NSTextView` con resaltado de sintaxis dinámico (Títulos, Enlaces, Tags).
    - Sistema de autocompletado nativo (tecla Esc) para MD y HTML.
  - **Motor de Renderizado Híbrido (V2)**: ¡Implementado!
    - Arquitectura de Puente Seguro: Envío de contenido vía Base64 (UTF-8 safe) para evitar corrupción de caracteres especiales y barras invertidas (`\`).
    - Renderizado Industrial: Integración de `Marked.js` para Markdown completo y `KaTeX` para ecuaciones matemáticas.
    - Persistencia Atómica: El `RenderMode` (MD, HTML, LaTeX) se guarda automáticamente por archivo (ID único) en `UserDefaults`.
  - **Telemetría y Debug**: Sistema de logs persistentes en `~/Documents/vault_telemetry.log` y captura de errores JS en tiempo real hacia Swift.
  - **Modo Noche (IR)**: Inmersión total (negro/rojo) en sidebar, listas y editor, con soporte heredado en fórmulas matemáticas.
  - **Sincronización**: Reactividad en el foco y File Watcher funcional en Rust.
  - **Repositorio**: Sincronizado y limpio en `lsanmartin/vault-system`.
  - **Búsqueda Semántica**: ¡Implementada! Embeddings locales de 384 dimensiones integrados en DuckDB usando `array_cosine_similarity`.

## Pendientes Próxima Sesión
- **Ajuste de Búsqueda Híbrida**: Sintonización de búsqueda híbrida.
- **Optimización de Reactividad**: Mejorar reactividad del sistema.
