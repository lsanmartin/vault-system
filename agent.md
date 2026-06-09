# Contexto del Agente

Última actualización: [2026-06-08 20:45]

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas (`DragGesture`), y navegación jerárquica (`VaultTreeView`).
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento unificado de MD, HTML y LaTeX con detección automática.
- **Capa 3: Core (Rust)**: Búsqueda semántica, File Watcher y persistencia en DuckDB.

## Resumen Técnico
- **Objetivo**: Estandarización del Renderizador Universal y simplificación de la interfaz.
- **Cambios Realizados**:
  - **Navegación Jerárquica**: Árbol de carpetas desplegable con toggle de expansión y chevrons.
  - **Redimensión Táctica**: Tirador de columnas funcional y persistente.
  - **Gestión de Archivos**: Renombrado integrado en menús contextuales.
  - **Renderizador Universal Standard**:
    - Se ha establecido el modo **Universal** como el estándar único del sistema.
    - Se ha **ocultado el toggle manual** de modos en la UI (comentado en `MainEditorView.swift`) para simplificar la experiencia de usuario.
    - **Detección Automática**: El motor identifica y procesa dinámicamente bloques Markdown, documentos HTML y estructuras complejas de LaTeX (incluyendo matrices `pmatrix`, `align`, etc.).
    - **Protección de Bloques**: Las ecuaciones y entornos LaTeX se blindan antes del parseo de Markdown para preservar secuencias de escape como `\\`.
  - **Blindaje Estructural**: Implementado el uso de Raw Strings de triple comilla y doble hash (`##""" ... """##`) en Swift para una inyección segura de código JS/LaTeX.

## Especificaciones de Renderizado (Para la IA)
1. **Detección de Formato**:
   - `Universal Mode`: Analiza el texto. Prioriza HTML si detecta `<html>`, limpia preámbulo si detecta `\documentclass`, y procesa Markdown en todo lo demás.
2. **Motor Matemático**: Se utiliza `KaTeX 0.16.9` con soporte extendido para entornos matriciales y de sistemas.
3. **Interfaz**: El selector de modo está comentado en el código por si se requiere restaurar, pero el sistema opera de forma autónoma.

## Pendientes Próxima Sesión
- **Sintonización de Búsqueda**: Ajustar pesos de búsqueda híbrida (Semántica + Keyword).
- **Mejoras de Exportación**: Evaluar la generación de PDFs basados en el renderizado universal.
