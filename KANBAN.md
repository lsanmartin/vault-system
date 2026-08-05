---
project: vault-system
description: Harness Agéntico — stack Rust + SwiftUI + DuckDB + MLX + MCP
updated: 2026-08-04
---

# KANBAN — vault-system

## 🔄 En Progreso



## 👀 Revisión



## ⬜ Backlog — Fase 3: Motor de Tareas Programadas

## ⬜ Backlog — Fase 3: Motor de Tareas Programadas

- [ ] **3.1** Scheduler en Rust — `core/src/scheduler.rs` | est:3h | dep:—
  - Tabla `scheduled_tasks` en DuckDB, event loop cada 30s en daemon, crons
  - refs: `core/src/lib.rs`, `daemon/src/main.rs`

- [ ] **3.2** `SchedulerView.swift` — UI de tareas programadas | est:3h | dep:3.1
  - Lista con toggle enable/disable, ejecutar ahora, última ejecución + estado
  - refs: `TelemetryView.swift`

- [ ] **3.3** Tareas built-in | est:2h | dep:3.1
  - reindex-parquet, consolidate-journals, embedding-batch, git-gc

## ⬜ Backlog — Fase 4: Tablero Kanban Visual (CPM)

- [ ] **4.1** `CPMTaskBoardView.swift` | est:6h | dep:—
  - Matriz Eisenhower + ruta crítica + drag & drop. Lee/escribe KANBAN.md
  - refs: `KANBAN.md`, `ContentView.swift`

- [ ] **4.2** Herramientas MCP `kanban_*` | est:2h | dep:4.1
  - `kanban_move_task`, `kanban_add_task`, `kanban_get_status`

- [ ] **4.3** Vista unificada multi-proyecto | est:3h | dep:4.1

## ⬜ Backlog — Fase 5: Pulido

- [ ] **5.1** LATS agent loop en Rust | est:4h | dep:—
- [ ] **5.2** `make export-telemetry` → Parquet | est:1h | dep:—
- [ ] **5.3** Actualizar ADR-001 (MLX/Gemma 4 real) | est:1h | dep:—

## ✅ Completado

### Fase 0 — Agentes Externos (completa 2026-08-03/04)
- [x] **0.1** `ExternalAgentManager.swift` — CRUD agentes, API keys en Keychain, tokens MCP
- [x] **0.2** `AgentSettingsView.swift` — UI formulario + workspace selector + permisos granular
- [x] **0.3** RBAC en handlers MCP — `read_metadata`, `read_content`, `can_write` en todas las tools
- [x] **0.4** Chat con @menciones (`@local`, `@ds`, `@cl`, `@op`) + streaming SSE + tool calling MCP real

### Fase 1 — Hooks y Validación OKF (completa 2026-08-04)
- [x] **1.1** OnStop: consolidar scratchpad → bitácora + git snapshot local + flush telemetría + cerrar DuckDB
- [x] **1.2** `okf_validator.rs`: validación frontmatter YAML + detección ciclos dependencias (4 tests, 2 MCP tools)
- [x] **1.3** PreCommit en `save_note()`: archivos OKF validados antes de escribir a disco

### Fase 2 — Comandos de Modo Agente (completa 2026-08-05)
- [x] **2.1** `/plan`: agente genera plan detallado sin tocar archivos, output markdown en chat
- [x] **2.2** `/goal`: bucle autónomo con tool calling MCP + verificación OKF + reintentos
- [x] **2.3** `/design`: diagrama Mermaid generado por agente, renderizado en WebView del chat

### Fase 1.5 — Chat Persistente (completa 2026-08-04)
- [x] Threads por agente en DuckDB (`chat_threads`, `chat_messages`)
- [x] Persistencia entre reinicios + onDisappear save
- [x] `/reset` crea ancla .md en `_inbox/`
- [x] Nombres completos (Local, DeepSeek Planner) + PermissionsBar

### Mejoras adicionales
- [x] Refactor `McpTokenRecord`: 10 permisos lectura/escritura + `allowed_paths` (subcarpetas)
- [x] ChatMessagesView WebView con `marked.js` (markdown en burbujas)
- [x] Colapsables para tool calls + indicador "● Pensando…"
- [x] Streaming SSE para agentes externos (texto en tiempo real)
- [x] Chat MCP tools: `chat_reset`, `chat_clear`, `chat_compact` accesibles por agentes externos
- [x] Enter = enviar, ⌘Enter = nueva línea (NSTextView nativo)
- [x] ⏹ Cancelar generación (local + externo)
- [x] 🗑 Ícono eliminar agente en panel de configuración
- [x] System workspace como workspace seleccionable en agentes externos
- [x] OKF triad vault-system (`_memory.md`, `_specs.md`, `_lore.md`)
- [x] Botones unificados abajo-izquierda (chat, telemetría, agentes, MCP)
- [x] TextEditor altura ×2 (72-240px)
- [x] Gestión de tokens (truncado + poda de conversación)

---

## 📋 Arquitectura Actual

| Componente | Ubicación |
|---|---|
| MCP Server Rust stdio nativo | `core/src/mcp_server.rs` |
| RBAC granular (10 permisos por token) | `core/src/lib.rs` (McpTokenRecord) |
| DuckDB 10 tablas OKF L1-L4 | `core/src/lib.rs` |
| Gemma 4 12B vía MLX Swift | `LocalBrain.swift` |
| FileWatcher + Cognitive Daemon | `core/src/lib.rs` |
| SwiftUI Liquid Glass + RSVP | `MainEditorView.swift` |
| Telemetría DuckDB + Swift | `core/src/lib.rs` + `TelemetryView.swift` |
| Git local sin remote | `core/src/lib.rs` |

## 🔗 Referencias

- Plan detallado: `docs/2026-08-03-plan-harness-agentico.md`
- Arquitectura: `docs/2026-07-21-arquitectura-detallada-vault-system.md`
- Plan estratégico: `docs/PLAN_ESTRATEGICO_DEV2.md`
- ADR-001: `docs/ADR-001-local-inference-engine.md`
- Bitácora: `agent.md`
