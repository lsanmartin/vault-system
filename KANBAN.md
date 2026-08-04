---
project: vault-system
description: Harness Agéntico — 6 fases sobre stack Rust + SwiftUI + DuckDB + MLX + MCP
updated: 2026-08-03
---

# KANBAN — vault-system

## 🔄 En Progreso

- [x] **Fase 0 completa** — Agentes externos con RBAC MCP + @menciones en chat | fin:2026-08-03
- [x] **Fase 1 parcial** — OnStop ✓, okf_validator ⬜, PreCommit ⬜



## 👀 Revisión



## ⬜ Backlog — Fase 1: Hooks y Validación OKF

- [ ] **1.2** `core/src/okf_validator.rs` — validador OKF determinista en Rust | est:3h | dep:—
  - Validar frontmatter YAML de `_memory.md` y `_specs.md`, detección de ciclos en dependencias
  - refs: `core/src/lib.rs` (scan_domain_metadata, tabla domain_metadata), `docs/2026-07-21-arquitectura-detallada-vault-system.md`

- [ ] **1.3** Integrar PreCommit en `save_note()` | est:1h | dep:1.2
  - Linter Markdown + YAML antes de escribir a disco. Rechazar errores fatales
  - refs: `core/src/lib.rs` (save_note), `core/src/okf_validator.rs`

## ⬜ Backlog — Fase 2: Comandos de Modo Agente

> Usan Gemma 4 local para tareas simples, delegan a agente externo (Fase 0) para razonamiento complejo.

- [ ] **2.1** Comando `/plan` — dry-run de cambios en chat local | est:3h | dep:0.4
  - El modelo genera plan detallado sin tocar archivos. Output Markdown en el chat
  - refs: `apple/Shared/Views/Editor/InlineAICommandView.swift`, `apple/Shared/Views/Editor/LocalChatView.swift`

- [ ] **2.2** Comando `/goal` — bucle autónomo con guardrails | est:5h | dep:0.4, 2.1
  - Descompone en sub-tareas, ejecuta tools MCP, verifica con OKF, reintenta (máx 3x). Se detiene: éxito total, 3 fallos, o cancelación manual
  - refs: `apple/Shared/Storage/LocalBrain.swift`, `core/src/okf_validator.rs`, `core/src/mcp_server.rs`

- [ ] **2.3** Comando `/design` — diagrama Mermaid previo | est:3h | dep:0.4, 2.1
  - Genera diagrama del cambio, renderiza en WebView, usuario aprueba/rechaza antes de ejecutar
  - refs: `apple/Shared/Views/Editor/WebView.swift`, `apple/Shared/Views/Editor/LocalChatView.swift`

## ⬜ Backlog — Fase 3: Motor de Tareas Programadas

- [ ] **3.1** Scheduler en Rust — `core/src/scheduler.rs` | est:3h | dep:—
  - Tabla `scheduled_tasks` en DuckDB, event loop cada 30s en daemon, crons. FFI: schedule_task, unschedule_task, list, run_now
  - refs: `core/src/lib.rs`, `daemon/src/main.rs`, `docs/2026-07-21-arquitectura-detallada-vault-system.md`

- [ ] **3.2** `SchedulerView.swift` — UI de tareas programadas | est:3h | dep:3.1
  - Lista con toggle enable/disable, ejecutar ahora, última ejecución + estado
  - refs: `apple/Shared/Views/TelemetryView.swift` (patrón de panel similar)

- [ ] **3.3** Tareas built-in | est:2h | dep:3.1
  - reindex-parquet, consolidate-journals, embedding-batch, git-gc
  - refs: `core/src/lib.rs` (scan_vault, consolidate_session)

## ⬜ Backlog — Fase 4: Tablero Kanban Visual (CPM)

> Toma el KANBAN.md de cada proyecto y lo vuelve una vista visual interactiva en la app.

- [ ] **4.1** `CPMTaskBoardView.swift` | est:6h | dep:—
  - Matriz Eisenhower + ruta crítica (CPM) + drag & drop entre columnas. Lee/escribe KANBAN.md
  - refs: `KANBAN.md` (formato actual), `apple/Shared/Views/ContentView.swift`

- [ ] **4.2** Herramientas MCP `kanban_*` | est:2h | dep:4.1
  - `kanban_move_task`, `kanban_add_task`, `kanban_get_status`. Agentes leen/escriben KANBAN.md del proyecto
  - refs: `core/src/mcp_server.rs`, `KANBAN.md`

- [ ] **4.3** Vista unificada de múltiples proyectos | est:3h | dep:4.1
  - Agregar KANBAN.md de todos los proyectos `~/dev/` en una vista de portafolio
  - refs: `~/dev/` (lista de proyectos), `apple/Shared/Storage/WorkspaceManager.swift`

## ⬜ Backlog — Fase 5: Pulido y Consolidación

- [ ] **5.1** LATS agent loop en Rust — `core/src/lats_agent.rs` | est:4h | dep:—
  - Migrar lats_agent.py a Rust, integrar con MCP tools, exponer vía FFI
  - refs: `lats_agent.py` (script externo actual), `core/src/mcp_server.rs`

- [ ] **5.2** `make export-telemetry` → Parquet | est:1h | dep:—
  - Exportar telemetría desde DuckDB a `00-Sistema/telemetria.parquet`
  - refs: `core/src/lib.rs` (tabla telemetry, TELEMETRY_LOGS)

- [ ] **5.3** Actualizar ADR-001 | est:1h | dep:—
  - Reflejar MLX/Gemma 4 como motor real (ya no llama-cpp-2). Documentar Dual-Brain: LocalBrain + ExternalAgent
  - refs: `docs/ADR-001-local-inference-engine.md`, `apple/Shared/Storage/LocalBrain.swift`

## ✅ Completado

- [x] Auditoría de consistencia: plan 10-capas vs código actual | fin:2026-08-03
  - refs: `agent.md`, `docs/2026-07-21-arquitectura-detallada-vault-system.md`, `docs/PLAN_ESTRATEGICO_DEV2.md`

- [x] `KANBAN.md` creado como fuente de verdad humano-agente | fin:2026-08-03
  - refs: `KANBAN.md` (este archivo)

- [x] **1.1** Hook `OnStop` — consolidar scratchpad + git snapshot local + flush telemetría + cerrar DuckDB | fin:2026-08-03
  - refs: `apple/Shared/VaultApp.swift` (observer NSApplication.willTerminate), `core/src/lib.rs` (shutdown_vault_session)

- [x] **0.1** `ExternalAgentManager.swift` — gestor de agentes externos con Keychain | fin:2026-08-03
  - refs: `apple/Shared/Storage/ExternalAgentManager.swift`

- [x] **0.2** `AgentSettingsView.swift` — UI CRUD de agentes externos | fin:2026-08-03
  - refs: `apple/Shared/Views/AgentSettingsView.swift`

- [x] **0.3** RBAC en handlers MCP — `allow_metadata`, `allow_raw`, `can_write` | fin:2026-08-03
  - refs: `core/src/lib.rs` (vault_get_domain_context, vault_export_domain_metadata, vault_ui_create_note)

---

## 📋 Resumen de Arquitectura Actual (lo que NO se toca)

| Componente | Ubicación | 
|---|---|
| MCP Server Rust stdio nativo | `core/src/mcp_server.rs` |
| RBAC granular (6 permisos por token) | `mcp_server.rs` |
| DuckDB 10 tablas OKF L1-L4 | `core/src/lib.rs` |
| Gemma 4 12B vía MLX Swift | `LocalBrain.swift` |
| FileWatcher + Cognitive Daemon | `core/src/lib.rs` |
| SwiftUI Liquid Glass + RSVP | `MainEditorView.swift` |
| Telemetría DuckDB + Swift | `core/src/lib.rs` + `TelemetryView.swift` |
| Git local sin remote | `core/src/lib.rs` (save_note, git add, git commit) |

## 🔗 Referencias

- Plan detallado: `docs/2026-08-03-plan-harness-agentico.md`
- Arquitectura: `docs/2026-07-21-arquitectura-detallada-vault-system.md`
- Plan estratégico: `docs/PLAN_ESTRATEGICO_DEV2.md`
- ADR-001 (motor inferencia): `docs/ADR-001-local-inference-engine.md`
- Bitácora de sesiones: `agent.md`
