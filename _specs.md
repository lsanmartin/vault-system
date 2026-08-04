# Especificaciones Técnicas — vault-system

## Arquitectura
Workspace Cargo con 2 miembros: `core/` (librería Rust: staticlib + cdylib + rlib) y `daemon/` (binario). UI en SwiftUI/AppKit con bridge UniFFI.

- **Core (Rust)**: DuckDB (10+ tablas), MCP server stdio nativo, FileWatcher (notify crate), Cognitive Daemon, embeddings MLX
- **Daemon (Rust)**: bridge IPC vía TCP loopback (127.0.0.1:49152)
- **UI (Swift)**: SwiftUI + AppKit, Liquid Glass (macOS Tahoe), WebView para Markdown, ChatInputView (NSTextView wrapper), LocalBrain (MLX Gemma 4)

## Reglas
- MCP tokens con 10 permisos: read/write × (content, metadata, system) + read_telemetry + allowed_paths
- Agentes externos: API keys en Keychain, tokens en UserDefaults/MCP_TOKENS
- Telemetría: solo lectura, nunca modificable por agentes
- Git local sin remote: versionado de notas, no push
- Build: `make build-universal` → `make xcode-build` → `make deploy`
- Workspace del sistema: `~/.vault_system/system_workspace`
- Base de datos: `~/.vault_system/vault.duckdb`

## Dependencias
- Rust: duckdb, mlx-rs, uniffi, tokio, notify, walkdir, serde_json, uuid, chrono
- Swift: mlx-swift-lm, swift-huggingface, swift-transformers
- Externas: marked.js (CDN), DeepSeek/Anthropic/OpenAI APIs
