# Lore — vault-system

## Propósito
Knowledge OS nativo macOS. Hub de inteligencia que combina un cerebro local (Gemma 4 vía MLX) con agentes externos (DeepSeek, Claude, OpenAI) bajo un mismo sistema de permisos MCP. El usuario (Luis) controla qué ve y qué hace cada agente. La app es soberana: todo el procesamiento ocurre localmente excepto las llamadas API explícitas a IAs externas.

## Glosario
- **Harness Agéntico**: arquitectura de 10 capas que gobierna agentes IA
- **OKF (Open Knowledge Format)**: tríada `_memory.md` + `_specs.md` + `_lore.md` por proyecto
- **MCP (Model Context Protocol)**: protocolo JSON-RPC para tools; servidor nativo Rust stdio
- **RBAC**: control de acceso basado en tokens con 10 flags
- **Nodo Ancla**: directorio que contiene la tríada OKF
- **Cognitive Daemon**: proceso pasivo en background para digestión de notas
- **LocalBrain**: clase Swift que orquesta Gemma 4 vía MLX
- **Scratchpad**: `current_session.md` para notas temporales de sesión

## Usuarios
- **Luis (lsanmartin)**: desarrollador principal, Santiago, Chile
- **Agentes IA**: DeepSeek V4 Flash (planner), Claude (reviewer), Gemma 4 (local executor)
- **Proyectos relacionados**: volley51 (web), volley51app (Tauri), nicelio (mapa-bancos)
