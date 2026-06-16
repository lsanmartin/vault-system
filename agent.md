# Contexto del Agente

Última actualización: [2026-06-15 20:25]

## Lineamientos de Dominio: Taxonomía de Tres Capas
- **Capa 1: UI Nativa (SwiftUI)**: Gestión de ventanas, redimensión de columnas (`DragGesture`), y navegación jerárquica (`VaultTreeView`).
- **Capa 2: Motor de Renderizado (Universal)**: Procesamiento unificado de MD, HTML y LaTeX con detección automática.
- **Capa 3: Core (Rust)**: Búsqueda semántica (DuckDB + MLX), File Watcher y Puente IPC.

## Resumen Técnico
- **Objetivo**: Estabilización del build en Apple Silicon, reparación del motor de base de datos in-memory y planificación de MCP.
- **Cambios Realizados**:
  - **Refactor del Build (Apple Silicon)**: Se eliminó la compilación universal (`lipo`) del Makefile, forzando `aarch64-apple-darwin` y enlazando contra `libclang` local y Homebrew DuckDB. Se empaquetó como `dylib` dentro de un `.xcframework` para resolver símbolos de MLX.
  - **Corrección de DuckDB Schema**: Se modificó el tipo de datos de `embedding` a `FLOAT[384]` (tamaño estático) para permitir la evaluación de `array_cosine_similarity`.
  - **Auto-poblado in-memory**: La App en Swift ahora dispara `scanVault` automáticamente al inicio para cargar la base de datos temporal con el estado actual del filesystem.
  - **Buscador Robusto (Híbrido)**: Añadido soporte ILIKE en Rust para buscar coincidencias estrictas de texto en títulos, contenidos y rutas de archivos (y carpetas).
  - **Reparación de Rutas Finder**: Implementado un normalizador de rutas en Swift que remueve las trailing slashes al comparar directorios padres, evitando la invisibilidad accidental de los nodos del árbol.
  - **Interfaz de Búsqueda**: Botón de "X" incrustado en el TextField para resetear rápidamente.

## Especificaciones de Renderizado (Para la IA)
1. **Detección de Formato**:
   - `Universal Mode`: Analiza el texto. Prioriza HTML si detecta `<html>`, limpia preámbulo si detecta `\documentclass`, y procesa Markdown en todo lo demás.
2. **Motor Matemático**: Se utiliza `KaTeX 0.16.9` con soporte extendido para entornos matriciales y de sistemas.
3. **Interfaz**: El selector de modo está comentado en el código por si se requiere restaurar, pero el sistema opera de forma autónoma.

## Pendientes Próxima Sesión (dev3)
- **Puente IPC (Localhost)**: Exponer un socket/HTTP en `vault_core` (ej. 127.0.0.1:49152) para la comunicación Inter-Process.
- **MCP Daemon**: Transformar `daemon/src/main.rs` en un cliente proxy (Mensajero) que escuche comandos MCP vía Stdio y los rutee al servidor IPC interno de la App (Orquestador).

## Visión Estratégica (Nuevos Requerimientos)
- **Búsqueda & Referencia Local**: Capacidad de buscar y vincular documentos/carpetas de todo el Mac (Spotlight Integration/Indexación).
- **Continuidad Inteligente**: Iniciar sesión con los items de trabajo recientes disponibles de inmediato.
- **Dashboard de Historial**: Lista interactiva (clickable) para reanudar contextos de trabajo rápidamente.
- **Vault App Store**: Sistema de gestión para harnesses, workflows, skills y MCPs oficiales.
- **Artefactos Seguros**: Compartición de notas/artefactos (MD, HTML, LaTeX) con opciones de seguridad (password opcional).
