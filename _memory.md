# Memoria de Desarrollo — vault-system

## Contexto
Vault System es un Knowledge OS nativo macOS que actúa como hub de IA local + externa. Stack: Rust (core) + SwiftUI (UI) + DuckDB (persistencia) + MLX (inferencia local Gemma 4). Arquitectura agéntica con MCP server nativo, RBAC granular, y delegación a IAs externas vía API keys.

## Hitos
- [2026-06-04] Validación XCFramework y primer build
- [2026-06-14] Definición hoja de ruta estratégica (DEV2)
- [2026-06-27] Estabilización DuckDB (índices, concurrencia, ghost notes)
- [2026-07-02] ADR-001: motor de inferencia local
- [2026-07-14] Checkboxes interactivos en modo vista
- [2026-07-20] Mitigación de crash y consumo de recursos (lazy embeddings, debounce watcher)
- [2026-07-22] Consistencia de rutas y canonicalización
- [2026-07-27] Fix definitivo ghost notes (iCloud race condition)
- [2026-07-29] Integración Gemma 4 local vía MLX Swift
- [2026-08-01] Toggle cerebro local con liberación GPU
- [2026-08-03] Fase 0 completa: agentes externos con RBAC MCP + @menciones en chat
- [2026-08-03] OnStop: cierre determinista (consolidar sesión, git snapshot, flush telemetría)
- [2026-08-03] Chat unificado con tool calling MCP real para IAs externas
- [2026-08-03] Refactor McpTokenRecord: 10 permisos granulares + allowed_paths
- [2026-08-03] Chat con WebView + marked.js (markdown en burbujas)
- [2026-08-03] Colapsables para tool calls y gestión de tokens

## Historial
- [2026-08-03] DeepSeek auditoría: detectó domain_metadata vacío y _specs.md corrupto en volley51app. Se crea tríada OKF para vault-system.
