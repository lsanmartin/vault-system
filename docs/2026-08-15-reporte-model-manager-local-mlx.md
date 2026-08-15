---
tipo: reporte
proyecto: vault-system
fecha: 2026-08-15
tema: Model Manager — modelo IA local (MLX) + propuesta de cambio/borrado/agregado
estado: borrador
---

# Reporte: Cerebro Local (MLX) y Model Manager propuesto

## 1. Modelo IA local actual

| Campo | Valor |
|---|---|
| Modelo | `mlx-community/gemma-4-12B-it-4bit` |
| Familia | Gemma 4, 12B, cuantizado 4-bit (affine, group_size 64) |
| Formato | MLX (`.safetensors`), no GGUF |
| Motor | `mlx-swift-lm` v3.31.4 + Metal/GPU (Apple M2 Pro) |
| Peso en disco | 6.3 GB (2 shards: 5.35G + 1.39G) |
| Licencia | Apache 2.0 (Gemma 4 reemplazó a Gemma 3, que usaba términos custom) |
| Token HF | Presente en `~/.cache/huggingface/token` → inyectado como `HF_TOKEN` |

### Cómo funciona (LocalBrain.swift)

Orquestador singleton (`apple/Shared/Storage/LocalBrain.swift`) con contenedor **caliente en GPU** (`activeContainer`):

1. **Carga (`getOrLoadContainer`)**:
   - Si `config.json` existe en `Documents/huggingface/models/<modelId>` → `ModelConfiguration(directory:)` → **carga offline instantánea**.
   - Si no → `ModelConfiguration(id:)` (cache HF estándar).
   - Si falla → `Hub.snapshot()` re-descarga 6-7 GB con progreso.
2. **Tres usos**:
   - **Digestión cognitiva**: hasta 10 notas pendientes → síntesis 1 oración + 5 entidades (JSON, temp 0.2) → DuckDB vía `saveNoteSummary`.
   - **Chat local** (`chatStream`): streaming temp 0.3, RAG (docs autoconsciencia + notas por búsqueda), comandos `[CMD: open_note/create_note/set_mode]`.
   - **Opciones IA de nota**: Resumir/Glosario/Redacción con la nota activa como contexto.
3. **Concurrencia**: `GPUInferenceActor` serializa GPU; chat cancela digestión (`pauseDigestionForChat`) y la reanuda a los 2s.
4. **Memoria**: cache Metal 64MB + `GPU.clearCache()`; toggle ⏻ libera el modelo de la GPU.

### Modelo alternativo candidato (prueba)

`mlx-community/gemma-4-e2b-it-4bit` — Gemma 4 E2B (2.3B params efectivos), ~2.4 GB, mismo formato MLX/`gemma4_unified`, carga con el mismo `#huggingFaceLoadModelContainer`. 69K+ descargas/mes. Variantes: `gemma-4-E2B-it-qat-4bit` (QAT), `gemma-4-e2b-it-OptiQ-4bit` (mixed-precision, mejor calidad).

> **Decisión GGUF vs MLX (2026-08-15):** el usuario evaluó `unsloth/gemma-4-E2B-it-qat-GGUF` (UD-Q4_K_XL, 2.62 GB). **NO es compatible** con el motor MLX actual: GGUF es formato llama.cpp (Ollama/LM Studio/llama-server); MLX carga `.safetensors`. El **mismo modelo base** (Gemma 4 E2B QAT de Google, Apache 2.0, multimodal) existe en formato MLX nativo como `mlx-community/gemma-4-E2B-it-qat-4bit` (~2.4 GB), cargable con el código actual sin cambios de motor. Se descarta el motor llama.cpp: duplicaría el pipeline y contradice la eficiencia MLX.

## 2. Hallazgos de la auditoría

1. **`modelId` hardcodeado** — `LocalBrain.swift:156` es la única fuente de verdad. No hay UserDefaults/plist/catálogo que lo controle.
2. **Discrepancia de ruta (bug latente)**: el sandbox está **desactivado** (`apple/Shared/VaultSystem.entitlements:5-6` = `false`). Con sandbox off, `documentDirectory` resuelve a `~/Documents` real, pero los 6.3 GB viven en el **contenedor legacy** `~/Library/Containers/cl.nicelio.vault.VaultSystem/Data/Documents/huggingface/models/`. El "fix carga offline" del 10-ago funcionaba con sandbox activo; ahora probablemente cae al flujo de cache/redescarga.
3. **`catalog.json` huérfano y GGUF** — `docs/models/catalog.json` define modelos GGUF de `bartowski` (diseño llama.cpp de ADR-001 original). Ningún código lo consume. Hay que reemplazarlo por catálogo MLX.
4. **No existe borrado de modelos** — cero código que limpie `huggingface/` o `~/.cache/huggingface/hub/`. Solo `MLX.GPU.clearCache()` (memoria, no disco).
5. **Caches HF huérfanos** en `~/.cache/huggingface/hub/`: `gemma-4-12B-it-OptiQ-4bit` (31M), `gemma-4-e4b-it-4bit` (209M), `google/gemma-4-e4b-it` (4K) — residuos de descargas fallidas de junio.
6. **Rust core no participa** — el "MLX" del core son embeddings simulados por hash (no modelo LLM). Toda la inferencia real vive en Swift.

## 3. Propuesta: Model Manager

Funcionalidad (funciones **distintas**, ambas con confirmación):
- **Cambiar modelo**: descargar (si no está) + activar otro modelo MLX; libera GPU y recarga.
- **Borrar modelo**: eliminar pesos del disco (ubicación canónica + cache HF) para liberar espacio; con confirmación.
- **Agregar modelo**: desde catálogo embebido o repo id custom de `mlx-community/*`.

### 3.1 Ubicación canónica (recomendada)
`~/.vault_system/models/<modelId>/` — carpeta propia de la app (junto a `vault.duckdb` y `system_workspace`), accesible sin sandbox. El manager **migra** el 12B desde el contenedor legacy sin re-descargar (detección de `config.json`), y `LocalBrain` busca: canónica → contenedor legacy → cache HF.

### 3.2 Catálogo (recomendado)
Embebido en Swift (3-4 modelos MLX iniciales) + input para repo custom. Sin red. Reemplazar el `catalog.json` GGUF.

Modelos iniciales:
| id | nombre | tamaño aprox. |
|---|---|---|
| `mlx-community/gemma-4-12B-it-4bit` | Gemma 4 12B (actual) | 6.3 GB |
| `mlx-community/gemma-4-e2b-it-4bit` | Gemma 4 E2B 4bit | ~2.4 GB |
| `mlx-community/gemma-4-E2B-it-qat-4bit` | Gemma 4 E2B QAT | ~2.4 GB |
| `mlx-community/gemma-4-e2b-it-OptiQ-4bit` | Gemma 4 E2B OptiQ | ~4.9 GB |

### 3.3 Persistencia
- `UserDefaults "vault_brain_model_id"` → modelo activo (reemplaza el hardcode en `LocalBrain.swift:156`).
- Estado por modelo (descargado / tamaño en disco / activo) calculado escaneando `~/.vault_system/models/`.

### 3.4 UI (recomendada)
Evolucionar `LocalBrainConfigView` (`MCPAccessView.swift:320-420`, pestaña "Cerebro Local") a CRUD completo:
- Lista de modelos del catálogo: badge **Activo**, tamaño, botón **Usar** / **Descargar**, botón **Borrar** (con `.alert(item:)` `.destructive`, patrón `MainEditorView.swift:453-466`).
- Barra de progreso por descarga (reutiliza `brain.downloadProgress`).
- Campo "Agregar modelo" (repo id `mlx-community/*`).

### 3.5 Cambios necesarios
- `apple/Shared/Storage/LocalBrain.swift`: quitar hardcode L156, leer `vault_brain_model_id`, soportar ruta canónica + migración legacy, método `switchModel(id:)`.
- `apple/Shared/Storage/ModelManager.swift` (NUEVO): catálogo, escaneo de disco, descarga, borrado (`FileManager.removeItem` + limpieza cache HF), confirmaciones.
- `apple/Shared/Views/MCPAccessView.swift`: reemplazar `LocalBrainConfigView` por `ModelManagerView`.
- `docs/models/catalog.json`: reemplazar por catálogo MLX (o eliminar si se embebe en Swift).
- Nuevos archivos en `apple/Shared/` se auto-incluyen vía xcodegen (`project.yml` → `- path: Shared`).

## 4. Decisiones pendientes (usuario)

1. Ubicación canónica de modelos (`~/.vault_system/models` vs `~/Documents/huggingface/models` vs contenedor).
2. Catálogo (embebido en Swift vs JSON en repo vs remoto).
3. UI (pestaña Cerebro Local vs sheet desde chat vs ambos).

## 5. Referencias
- `apple/Shared/Storage/LocalBrain.swift` (carga/descarga/digestión/chat)
- `apple/Shared/Views/MCPAccessView.swift` (LocalBrainConfigView, 320-420)
- `apple/Shared/Views/ContentView.swift` (botones flotantes, overlay MCP)
- `docs/ADR-001-local-inference-engine.md` (decisión original llama.cpp → MLX real)
- `docs/models/catalog.json` (catálogo GGUF obsoleto)
