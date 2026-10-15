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
- [2026-08-16 11:28] Refactor UI Chat: retorno a vista de chat individual (una por vez) seleccionable con botonera inferior; reubicación de herramientas globales al SidebarColumn.
- [2026-09-15] Especificación técnica completa Fase 6: Bolsa de Cómputo + Token Broker (harness DashAI, ledger partida doble, ciclo Auth→Capture→Release, SCD-2 TokenRate, Event Sourcing audit_log, MCP-Billing-Adapter). Hoja de ruta Fase 1 (SQLite local) → Fase 2 (TigerBeetle cloud). Doc: `docs/2026-09-15-broker-ia-wallet-tokens.md`.
- [2026-09-15] Kanban actualizado con Fase 6 (4 tareas 6.1-6.4). Script de sync Kanban↔Apple Reminders creado: `00-Sistema/scripts/sync_kanbans_to_reminders.py` (32 proyectos, bidireccional, ingesta manual, cabecera on-top). Hooks en `post_session.sh` y `morning_dream.sh`.

## Historial
- [2026-08-03] DeepSeek auditoría: detectó domain_metadata vacío y _specs.md corrupto en volley51app. Se crea tríada OKF para vault-system.
- [2026-10-10] Análisis de función de contenedores y Dagster como orquestador externo. Definición de arquitectura híbrida (Dagster en host vía uv + Dagster Pipes efímero en contenedor individual). Vault-system actúa como broker seguro TCC/DuckDB vía Unix Domain Socket MCP. Doc guardado en docs/2026-10-10-analisis-containers-dagster-broker.md.
