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

## El Rol Estratégico de Vault-System (The 7-Layer Enterprise AI Stack)

Basado en los estándares de IA empresarial (JPMorgan Chase, 2026), vault-system actúa como el acelerador de infraestructura moviendo la inteligencia desde el "cloud-scripting" hacia el "native-edge".

- **L1 (Gobernanza) - Seguridad Local**: Implementación de un binario nativo en Rust con control de acceso UMA (User-Managed Access) sobre el sistema de archivos local.
- **L2 (Datos) - El Motor DuckDB**: Vault-system transforma el vault de una colección de archivos planos en una base de datos analítica de alto rendimiento, permitiendo consultas SQL sobre Markdown.
- **L3/L4 (Modelos y Gateway)**: Abstracción multi-modelo a través de MCP (Model Context Protocol), aislando a la app de la dependencia a un solo proveedor.
- **L5 (Memoria) - Persistencia Estructurada**: Sistematiza la memoria a largo plazo mediante los archivos `_memory.md` y `_metadata.md`, dotando a los agentes de estado conversacional y retención de contexto temporal.
- **L6 (Orquestación)**: Subagentes y herramientas CLI actúan como un grafo de orquestación local sobre un ecosistema de datos unificado.
- **L7 (Aplicación) - Integración Nativa**: Mediante App Intents y SwiftUI, la plataforma se expone de forma ubicua e integrada al ecosistema de Apple.

Vault-system es el cimiento técnico que permite la transición hacia una IA Agente puramente local, persistente y soberana.
