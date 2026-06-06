# Vault System

Knowledge OS que actúa como un hub central de Inteligencia Artificial para el ecosistema de macOS. Combina un motor robusto en Rust (Kuzu Graph DB, MCP, DuckDB) con una interfaz nativa acelerada por SwiftUI y Metal.

## Arquitectura

- **Core (Rust)**: Procesamiento, IA, Memoria Semántica y Sandboxing.
- **Daemon (Rust)**: Proceso en segundo plano para manejar automatizaciones remotas y Handoff.
- **UI (Swift)**: Frontend nativo para macOS con capacidades inter-app (Mail, Calendar, Notes).

## Requisitos Previos

- Rust (`rustup target add aarch64-apple-darwin aarch64-apple-ios`)
- UniFFI (`cargo install uniffi_bindgen`)
- Xcode y Command Line Tools

## Compilación

```bash
make build-apple
```
