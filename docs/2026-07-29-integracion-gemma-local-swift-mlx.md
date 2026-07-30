# Integración de Inferencia de Cerebro Local (Gemma/mlx-swift)

## Análisis y Estrategia
- **Objetivo**: Integrar inferencia local de Gemma en macOS/Apple Silicon usando `mlx-swift` en el cliente Swift nativo, reemplazando el mock cognitivo del Core Rust de forma segura.
- **Estrategia**:
  - Desactivar generación automática de mocks en el thread `start_cognitive_daemon` en Rust.
  - Exponer FFI para traer notas sin resumir (`get_pending_summary_notes`) y guardar resúmenes reales en DuckDB (`save_note_summary`).
  - Desarrollar `LocalBrain.swift` para realizar inferencia local estructurada vía Metal y actualizar la base de datos de forma asíncrona.

## Decisiones Técnicas
- **Caminos tomados**:
  - Se prefirió ejecutar la inferencia en el hilo de Swift con `mlx-swift` en lugar de `llama.cpp` en Rust para maximizar el uso nativo de Metal sin añadir dependencias complejas de FFI de C++ al compilador de Rust.
  - Se expuso la cola de resúmenes pendientes mediante UniFFI, permitiendo un pipeline modular y limpio.
  - Se corrigió `apple/project.yml` añadiendo `path: Info.plist` para resolver errores de parsing en la versión actual de XcodeGen.

## Próximos Pasos
- Conectar los resúmenes sintéticos generados en DuckDB al Servidor MCP en `mcp_server.rs` para implementar el filtro de privacidad ("Data Blindness").
- Realizar pruebas de rendimiento de inferencia on-device con Gemma 4 12B cuantizado.
