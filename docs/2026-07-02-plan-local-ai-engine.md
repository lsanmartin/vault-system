# Plan de Implementación: Motor de Inferencia Local
## vault-system — Módulo `ai_engine`

**Versión:** 1.1 (revisión técnica 2026-07-02)
**Fecha original:** 2026-07-02
**ADR de referencia:** `ADR-001-local-inference-engine.md` (v1.1)
**Rama sugerida:** `feature/local-ai-engine`
**Impacto sobre código existente:** NINGUNO en Fase 1 — aditivo puro

---

## Resumen

Se agrega el módulo `core/src/ai_engine/` al crate `vault_core`. Este módulo es
**completamente opt-in** via Cargo feature flag `local-ai`. El código existente en `lib.rs`
(incluyendo `generate_embedding()`, `generate_summary()` y todas las funciones FFI actuales)
**no se modifica**. El hook en L1177 se activa solo si el feature está presente y el usuario
ha activado explícitamente el motor.

Implementa la **Fase 2 del PLAN_ESTRATEGICO_DEV2** ("El Digestor").

---

## Fase 1 — Estructura base y feature flag
**Objetivo:** Scaffolding del módulo sin introducir dependencias binarias pesadas.
**Estimado:** 1 sesión de trabajo (~3h)
**Riesgo:** Mínimo — solo Cargo.toml y archivos nuevos.

### 1.1 Cargo.toml — `core/Cargo.toml`

Agregar al final del archivo, **sin modificar dependencias existentes**:

```toml
[features]
default = []
local-ai = ["dep:llama-cpp-2", "dep:reqwest", "dep:sha2", "dep:tokio-stream"]
# Nota: hf-hub evaluado en Fase 2 — puede ser redundante si reqwest cubre las necesidades

[dependencies]
# ... dependencias existentes intactas ...
llama-cpp-2   = { version = "0.1.150", optional = true }  # pin de minor para 0.x
reqwest       = { version = "0.12", optional = true, features = ["stream", "json"] }
sha2          = { version = "0.10", optional = true }
tokio-stream  = { version = "0.1", optional = true }
# hf-hub — agregar solo si Fase 2 lo justifica (resume de descargas, caché HF)
```

> **Nota sobre versión:** `llama-cpp-2` está activamente en 0.x. Se fija la minor (`0.1.150`)
> porque saltos de minor en 0.x pueden traer breaking changes. Actualizar solo después de
> pruebas explícitas, no con `cargo update` automático.

### 1.2 Estructura de archivos a crear

```
core/src/ai_engine/
├── mod.rs              ← trait InferenceEngine + AiManager global + TOKIO_RT singleton
├── model_catalog.rs    ← ModelInfo, CatalogEntry, deserialización desde JSON remoto
├── model_manager.rs    ← descarga con reqwest, verificación SHA256, caché ~/.vault_system/models/
├── llm_local.rs        ← impl LlamaCppEngine (feature-gated)
├── finetune.rs         ← trait FineTuneEngine + struct FineTuneConfig + stub vacío
└── hardware.rs         ← detección RAM disponible, recomendación hardware-aware
```

### 1.3 Traits centrales — `ai_engine/mod.rs`

```rust
#[cfg(feature = "local-ai")]
pub trait InferenceEngine: Send + Sync {
    fn load(&self, model_path: &str) -> Result<(), String>;
    fn infer(&self, prompt: &str, max_tokens: u32, temperature: f32) -> Result<String, String>;
    fn unload(&self);
    fn backend_name(&self) -> &'static str;
    fn supports_quantization(&self) -> bool;
    fn model_loaded(&self) -> bool;
}

// Stub de fine-tuning — compilado siempre para que Swift vea el tipo vía FFI
pub struct FineTuneConfig {
    pub base_model_id: String,
    pub adapter_output_path: String,
    pub epochs: u32,
    pub lora_rank: u32,
}

// Implementaciones actuales y futuras (detrás del trait, transparente para Swift):
// LlamaCppEngine  ← hoy
// MlxEngine       ← futuro (~2027)
// CoreMlEngine    ← futuro (ANE nativo)
```

### 1.4 Runtime Tokio singleton

```rust
// ai_engine/mod.rs — creado UNA SOLA VEZ, nunca por-llamada
static TOKIO_RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime for ai_engine")
});

// Uso en model_manager (descarga):
// TOKIO_RT.block_on(async { reqwest::get(url).await })
```

> **Regla:** Si `vault_core` incorpora Tokio en otro módulo en el futuro, consolidar ambos
> bajo este mismo singleton. Nunca crear un segundo runtime.

### 1.5 Ramas `cfg` explícitas en todas las FFI

Cada función FFI del módulo `ai_engine` define **ambas ramas**:

```rust
#[uniffi::export]
pub fn ai_is_available() -> bool {
    #[cfg(feature = "local-ai")]
    { crate::ai_engine::AI_MANAGER.is_available() }
    #[cfg(not(feature = "local-ai"))]
    { false }
}
```

Esto garantiza que un build sin `--features local-ai` (CI liviano, desarrollo base) compile
sin errores y que el contrato Swift sea idéntico en cualquier configuración.

### 1.6 Compilación

```bash
# Sin AI (instalación base — sin cambios en binario ni en lib.rs)
cargo build --release

# Con AI (distribución con motor)
cargo build --release --features local-ai

# El XCFramework de distribución siempre usa --features local-ai
# El modelo no carga en memoria hasta que el usuario lo activa en UI
```

### 1.7 Commit objetivo

```
feat: add local-ai feature flag scaffold [no behavioral change to existing code]
```

---

## Fase 2 — Model Manager y Catálogo
**Objetivo:** Sistema de descarga, verificación y gestión de modelos GGUF.
**Estimado:** 1–2 sesiones (~5h)
**Riesgo:** Bajo — módulo aislado sin tocar lib.rs.

### 2.1 Evaluación de hf-hub

Antes de agregar `hf-hub` como dependencia, evaluar si `reqwest` cubre las necesidades:
- Si el catálogo provee URL directa + SHA256: `reqwest` + streaming es suficiente.
- Si se necesita resume de descargas, caché de HuggingFace Hub, o autenticación: agregar `hf-hub`.
- **Decisión por defecto:** empezar solo con `reqwest`. Agregar `hf-hub` solo si surge necesidad concreta.

### 2.2 Estructura de datos — `model_catalog.rs`

```rust
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub description: String,
    pub size_gb: f32,
    pub format: String,
    pub quantization: String,
    pub context_length: u32,
    pub chat_template_id: String,  // "gemma" | "phi-4" | etc. — referencia al template del GGUF
    pub url: String,
    pub sha256: String,
    pub min_ram_gb: f32,
    pub quality_score: u8,
    pub license: String,
    pub capabilities: Vec<String>,
    pub recommended_for: String,
    pub is_default: bool,
}
```

### 2.3 Catálogo inicial — modelos Apache 2.0 / MIT verificados

Ver `docs/models/catalog.json` para el detalle completo.

| ID | Base | Params | Tamaño Q4 | Licencia | Default |
|---|---|---|---|---|---|
| `gemma-4-e2b-q4` | Gemma 4 E2B | ~2B edge | ~1.2 GB | Apache 2.0 ✅ | ✅ |
| `phi-4-mini-q4` | Phi-4 Mini | ~3.8B | ~2.3 GB | MIT ✅ | — |
| `gemma-4-e4b-q4` | Gemma 4 E4B | ~4B edge | ~2.5 GB | Apache 2.0 ✅ | — |

> **Nota de licencias (corrección v1.1):** Gemma 3 fue eliminado del catálogo. Gemma 3 usa
> **Gemma Terms of Use** (licencia custom Google, no Apache 2.0). Gemma 4 (abril 2026) cambió
> a Apache 2.0 real. Usar únicamente modelos Gemma 4+.

### 2.4 Almacenamiento local

```
~/.vault_system/
├── vault.duckdb         ← existente, sin tocar
├── models/
│   ├── catalog.json     ← copia local del manifest (TTL: 24h)
│   ├── gemma-4-e2b-q4.gguf
│   └── phi-4-mini-q4.gguf
└── ai_config.json       ← { "enabled": bool, "active_model": "id" | null, "active_adapter": null }
```

### 2.5 FFI expuestas a Swift — añadir a `lib.rs`

```rust
ai_is_available() → bool
ai_get_catalog() → String          // JSON de ModelInfo[]
ai_get_available_ram_gb() → f32
ai_download_model(model_id) → String
ai_get_download_progress(model_id) → f32   // 0.0–1.0 (patrón ya establecido en el proyecto)
ai_activate_model(model_id) → String
ai_deactivate() → String
ai_get_active_model() → String
ai_query(prompt, context, max_tokens) → String   // SOLO para Digestor en background
ai_prepare_finetune_dataset(output_path) → String  // stub — retorna mensaje informativo
```

### 2.6 Commit objetivo

```
feat: model catalog, manager, download with SHA256 and FFI stubs
```

---

## Fase 3 — Motor llama-cpp-2
**Objetivo:** Implementación real de `InferenceEngine` + activación del hook L1177.
**Estimado:** 2 sesiones (~8h, incluyendo pruebas)
**Riesgo:** Medio — llama.cpp linkea con Metal. Requiere build environment configurado.

### 3.1 `llm_local.rs` — estructura

```rust
#[cfg(feature = "local-ai")]
pub struct LlamaCppEngine {
    model: Mutex<Option<LlamaModel>>,
    ctx_params: LlamaContextParams,
}

#[cfg(feature = "local-ai")]
impl InferenceEngine for LlamaCppEngine {
    fn load(&self, model_path: &str) -> Result<(), String> { ... }
    fn infer(&self, prompt: &str, max_tokens: u32, temperature: f32) -> Result<String, String> { ... }
    fn unload(&self) { ... }
    fn backend_name(&self) -> &'static str { "llama-cpp-2/Metal" }
    fn supports_quantization(&self) -> bool { true }
    fn model_loaded(&self) -> bool { ... }
}
```

### 3.2 Chat template por modelo — NO hardcodear `[INST]`

llama.cpp puede leer el **chat template Jinja embebido en los metadatos del GGUF** y aplicarlo
automáticamente. Usar este mecanismo en lugar de construir strings de prompt manualmente:

```rust
// llama-cpp-2 expone el chat template del modelo cargado
// Se construye la conversación como lista de mensajes y llama.cpp formatea según el modelo

let messages = vec![
    ChatMessage { role: "user", content: &full_prompt }
];
// llama.cpp aplica el template correcto según el GGUF cargado:
// Gemma 4:   <start_of_turn>user ... <end_of_turn><start_of_turn>model
// Phi-4:     <|user|> ... <|end|><|assistant|>
// Sin hardcodear nada en el código de la app
let formatted = model.apply_chat_template(&messages)?;
```

> **Por qué importa:** El formato `[INST]...[/INST]` es Mistral/Llama-2 y degrada la calidad
> en Gemma y Phi porque el modelo nunca vio esos tokens durante su fine-tuning de instrucción.
> Esto afecta directamente la adherencia al formato JSON del output.

### 3.3 Grammar-constrained decoding (GBNF)

Para el output de síntesis de notas, **no confiar solo en el prompt** para producir JSON válido.
llama.cpp soporta gramáticas GBNF que fuerzan el output a un schema definido:

```rust
// Gramática GBNF para el output del Digestor
const SYNTHESIS_GRAMMAR: &str = r#"
root   ::= object
object ::= "{" ws "\"summary\"" ws ":" ws string ws "," ws
               "\"entities\"" ws ":" ws array ws "," ws
               "\"density\"" ws ":" ws number ws "}"
array  ::= "[" ws (string ("," ws string)*)? ws "]"
string ::= "\"" ([^"\\] | "\\" .)* "\""
number ::= [0-9] "." [0-9]+
ws     ::= [ \t\n]*
"#;

// Se pasa al sampler, no al prompt
ctx.set_grammar(SYNTHESIS_GRAMMAR)?;
```

> **Por qué importa:** Modelos 1B–4B cuantizados en Q4 fallan esporádicamente en producir
> JSON válido bajo presión de formato, incluso con instrucciones claras en el prompt.
> La gramática GBNF fuerza el schema en el sampler, eliminando la necesidad de parseos
> con reintentos en el Digestor de background.

### 3.4 Hook L1177 — modificación mínima, ambas ramas explícitas

```rust
// L1177 — solo se agrega un bloque cfg sobre el mock existente
// El mock cognitivo permanece INTACTO como fallback de compilación base

#[cfg(feature = "local-ai")]
{
    if crate::ai_engine::AI_MANAGER.is_available() {
        match crate::ai_engine::AI_MANAGER.infer_synthesis(&title, &content) {
            Ok(json) => {
                // parsear json → synthetic_summary, entities, density
                // insertar en DuckDB (mismo flujo que el mock)
            }
            Err(_) => {
                // fallback al mock si la inferencia falla
                // Mock cognitivo actual aquí
            }
        }
    } else {
        // Mock cognitivo actual — usuario no activó AI
    }
}
#[cfg(not(feature = "local-ai"))]
{
    // Mock cognitivo actual — build sin local-ai, sin cambios
    let mut snippet = content.chars().take(150).collect::<String>();
    // ...
}
```

### 3.5 Declaración de `ai_query` como exclusivo del Digestor

`ai_query` es **síncrono** y tarda hasta ~5s en M2 Pro (criterio de éxito de esta fase).
**Swift nunca lo llama desde el hilo principal.** Si en el futuro se requiere una interfaz
interactiva tipo "chat", se implementará via el patrón de polling establecido
(`ai_get_download_progress` como referencia) o via exports async de UniFFI.

### 3.6 Medición del tamaño binario

El estimado "2–5 MB" de la versión anterior era especulativo. Al cerrar esta fase:
- Medir delta de tamaño del `.xcframework` con y sin `--features local-ai`
- Registrar la medición real en el ADR como dato empírico
- No publicar número en el ADR hasta tener la medición real

### 3.7 Commit objetivo

```
feat: llama-cpp-2 inference engine + GBNF grammar + chat template from GGUF + activate L1177
```

---

## Fase 4 — UI Swift (onboarding)
**Objetivo:** Panel de activación y gestión de modelos en SwiftUI.
**Estimado:** 1–2 sesiones (~6h)
**Riesgo:** Bajo — componente nuevo, no modifica vistas existentes.

### 4.1 Flujo de usuario

```
Primera apertura (post-instalación)
└─► Estado: ai_is_available() == false
        └─► Badge discreto en Sidebar: "IA Local · Inactiva"
                └─► Click → Sheet "Motor de Inferencia Local"
                        ├── Descripción del feature
                        ├── Lista de modelos del catálogo
                        │     ├── Badge RAM requerida
                        │     ├── Badge "Recomendado" (hardware-aware, via ai_get_available_ram_gb)
                        │     ├── Tamaño de descarga explícito ANTES de confirmar
                        │     └── Botón "Descargar" → Progress circular (ai_get_download_progress)
                        ├── Toggle "Activar IA Local"
                        └── Link "Más información" → doc URL
```

### 4.2 Indicador de estado en Sidebar

- 🔴 "IA · Desactivada"
- 🟡 "IA · Descargando... (X%)"
- 🟢 "IA · Activa · Gemma 4 E2B"

**Archivo nuevo:** `AiEngineSettingsView.swift`
**Sin modificar:** `MainEditorView`, `EditorViewModel`, ni ninguna vista existente.

### 4.3 Commit objetivo

```
feat(swift): AI onboarding and settings view
```

---

## Fase 5 — Fine-tuning (Arco futuro — stub hoy)
**Estado:** No implementado. Contrato preparado. Implementación planificada post-Fase 4.

### 5.1 Qué se deja preparado hoy

- `trait FineTuneEngine` con los métodos del contrato
- FFI `ai_prepare_finetune_dataset` retorna mensaje informativo
- Campo `active_adapter: null` en `ai_config.json`
- Carpeta `~/.vault_system/finetune/` documentada pero no creada

### 5.2 Vectores de implementación futura

**Vector A — Fine-tuning local via llama.cpp LoRA (100% offline):**
Rust exporta notas de DuckDB como JSONL → lanza CLI de fine-tuning de llama.cpp → carga LoRA adapter.
Sin datos saliendo del dispositivo.

**Vector B — Fine-tuning asistido via MCP (requiere consentimiento explícito):**
Tool MCP `prepare_finetune_dataset` → agente externo (Claude/Gemini) recibe notas del vault
y genera pares Q&A → JSONL → fine-tuning local.

> **⚠️ Gate de consentimiento mandatorio para Vector B:**
> Este es el ÚNICO punto del plan donde datos del vault salen del dispositivo.
> Antes de ejecutar, el usuario debe ver y aceptar:
> *"Para generar el dataset, [N] notas de tu vault serán enviadas a [proveedor externo].
> ¿Confirmas que deseas continuar?"*
> Este gate es INDEPENDIENTE del toggle "Activar IA Local". Los Vectores A y C son
> 100% offline y no requieren este gate.

**Vector C — mlx-rs cuando madure (100% offline):**
`MlxEngine` implementa fine-tuning nativo. Swap transparente via el trait.

---

## Tabla de compatibilidad

| Componente | Impacto |
|---|---|
| `generate_embedding()` en lib.rs | ✅ Sin cambios |
| Todas las FFI UniFFI existentes | ✅ Sin cambios |
| Esquema DuckDB | ✅ Sin cambios |
| `MLX_LOCK`, `DB_CONN`, telemetría | ✅ Sin cambios |
| Vistas Swift existentes | ✅ Sin cambios |
| `daemon/` | ✅ Sin cambios |
| Makefile | Solo se agrega `build-apple-ai` target |

---

## Criterios de éxito por fase

| Fase | Criterio | Método |
|---|---|---|
| 1 | `cargo build` pasa sin `local-ai`; con feature pasa; ambas ramas `cfg` compilan | CI |
| 2 | Descarga con SHA256 correcto; catálogo JSON parseable; TOKIO_RT es singleton | Test unitario |
| 3 | Síntesis de nota < 5s en M2 Pro; JSON siempre válido (GBNF); chat template correcto por modelo | Benchmark + test |
| 4 | Swift muestra catálogo y descarga modelo sin crash; badge de estado correcto | TestFlight |
| 5 | Trait compila; FFI stub retorna string informativo; Vector B documentado con gate | Test unitario |

---

## Orden de commits sugerido

```
feat: add local-ai feature flag scaffold [no behavioral change]
feat: model catalog, manager, download with SHA256 and FFI stubs
feat: llama-cpp-2 inference engine + GBNF grammar + chat template + L1177 hook
feat(swift): AI onboarding and settings view
issue: feat: finetune pipeline [future - Vector A/B/C]
```

---

## Relación con PLAN_ESTRATEGICO_DEV2.md

Este plan implementa la **Fase 2 del PLAN_ESTRATEGICO_DEV2** ("El Digestor"):

> "Acoplar un LLM cuantizado al Daemon. Programar un hilo en segundo plano que despierte
> en idle y procese las notas nuevas para extraer resúmenes densos, entidades y timestamps
> cognitivos, guardando esto en las nuevas tablas de DuckDB."

El hook en L1177 de `lib.rs` es exactamente ese punto de inserción del Digestor.
La arquitectura de este plan no contradice ni modifica ninguna decisión del Plan DEV2.
