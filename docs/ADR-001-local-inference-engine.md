# ADR-001: Motor de Inferencia Local (Local AI Engine)

**Estado:** Aprobado — v1.1 (revisión técnica 2026-07-02)
**Fecha original:** 2026-07-02
**Revisado:** 2026-07-02 (correcciones de licencia, prompt template y decisiones de concurrencia)
**Autores:** LSM + Antigravity
**Supersede:** ninguno
**Relacionado con:** `PLAN_ESTRATEGICO_DEV2.md` (Fase 2), `revision_estrategica_vault-system.md` (Brecha 1 y §5.1)

---

## Contexto

El plan estratégico DEV2 (Fase 2, "El Digestor") define la integración de un LLM local cuantizado para
procesar notas en segundo plano y generar resúmenes sintéticos, entidades y densidad cognitiva. Actualmente,
`generate_summary()` en `core/src/lib.rs` (L1177) contiene un mock cognitivo (snippet de 150 chars +
extracción heurística de palabras). El hook de inserción está explícitamente marcado para ser reemplazado.

Adicionalmente, `generate_embedding()` usa `mlx-rs` para operaciones tensoriales, pero sobre una semilla
hash — no sobre un modelo de embeddings real. Esta función también debe evolucionar.

## Decisión

Se adopta `llama-cpp-2` (Rust crate, MIT License) como motor de inferencia in-process para la Fase 2.

### Principios que guían la decisión

1. **In-process real**: `llama-cpp-2` compila llama.cpp (C++) dentro del binario Rust via FFI. No hay
   proceso externo, no hay IPC, no hay latencia de red. Idéntico al patrón ya usado con `duckdb`.
2. **Opt-in para el usuario**: El motor no se activa en la instalación base. El usuario lo habilita
   explícitamente desde la UI.
3. **Swappable via trait**: El engine vive detrás de `trait InferenceEngine`. Cuando `mlx-rs` madure
   para inferencia LLM (estimado: 12–24 meses), se agrega `MlxEngine` como implementación alternativa
   sin cambiar la API FFI ni el contrato Swift.
4. **Sin fine-tuning en esta fase**: La arquitectura deja preparado el contrato (`finetune` en el trait),
   pero la implementación es un stub vacío. Fine-tuning se planifica para Fase 5.
5. **Modelos Apache 2.0 / MIT únicamente**: El catálogo usa solo modelos verificados como comercialmente
   libres. Ver sección "Decisión sobre modelos" más abajo.
6. **Hardware-aware**: El sistema detecta RAM disponible y recomienda el modelo óptimo. A medida que
   el hardware mejore, el catálogo se actualiza via manifest remoto sin recompilar.
7. **Grammar-constrained decoding para JSON**: El sampler de llama.cpp fuerza una gramática GBNF que
   define el schema exacto del output esperado. No se confía solo en el prompt para adherencia JSON.
8. **Chat template por modelo desde GGUF**: llama.cpp lee el template Jinja embebido en los metadatos
   del archivo GGUF. No se hardcodea ningún formato de prompt en el código de la aplicación.

### Alternativas descartadas

| Alternativa | Razón del descarte |
|---|---|
| `mlx-lm` (Python sidecar) | Proceso externo, IPC, dependencia Python en runtime |
| `mlx-rs` directo | Solo ops tensoriales hoy, sin tokenizador ni inference pipeline LLM |
| `candle` (HF Rust) | Soporte cuantización limitado, sin Metal comparable a llama.cpp |
| `ort` (ONNX) | Requiere conversión de modelo, menor ecosistema GGUF |
| CoreML (Swift) | Óptimo para Apple Silicon pero sin pipeline LLM maduro aún; considerado para futuro |
| Gemma 3 (modelos) | **Licencia Gemma Terms of Use** (custom Google), no Apache 2.0. Reemplazado por Gemma 4. |

---

## Decisión sobre modelos — corrección de licencia

> **Corrección v1.1 (2026-07-02):** La versión inicial del ADR indicaba "todos Apache 2.0 / MIT",
> incluyendo Gemma 3. Esto es incorrecto. **Gemma 3** se distribuye bajo los **Gemma Terms of Use**
> (licencia custom de Google, Sección 3.2), que impone restricciones de uso y obligación de aviso
> de redistribución. **No es Apache 2.0.**

**Resolución adoptada (opción A):** Se reemplaza todo el catálogo Gemma 3 por **Gemma 4**, cuyo
lanzamiento en abril 2026 incluyó el cambio de licencia a **Apache 2.0 real**. Los modelos edge
de Gemma 4 (E2B, E4B) son además mejores candidatos para on-device: diseñados específicamente para
inferencia eficiente, tamaños similares o menores que Gemma 3 1B/4B, y con mejor rendimiento.

Catálogo final (detalle en `docs/models/catalog.json`):

| ID | Base | Params efectivos | Tamaño GGUF Q4 | Licencia | Default |
|---|---|---|---|---|---|
| `gemma-4-e2b-q4` | Gemma 4 E2B | ~2B edge | ~1.2 GB | Apache 2.0 ✅ | ✅ |
| `phi-4-mini-q4` | Phi-4 Mini | ~3.8B | ~2.3 GB | MIT ✅ | — |
| `gemma-4-e4b-q4` | Gemma 4 E4B | ~4B edge | ~2.5 GB | Apache 2.0 ✅ | — |

---

## Decisiones de concurrencia y runtime (explicitadas)

### D1 — `ai_query` es exclusivo del Digestor en background

`ai_query` (y por ende el hook de L1177) es **síncrono y puede tardar hasta ~5s en M2 Pro**.
Se declara explícitamente que esta función es para el **Digestor en background** únicamente,
no para llamadas user-facing directas. Si en el futuro se requiere un "chat" interactivo en la UI,
se implementará via el patrón de polling ya establecido en el proyecto (`ai_get_download_progress`
como referencia), o via exports async de UniFFI cuando estén disponibles.

**Corolario:** Swift **nunca** llama `ai_query` desde el hilo principal.

### D2 — Runtime Tokio: singleton global, no por llamada

`reqwest` + `tokio-stream` (usados en el model manager para descargas) requieren un runtime Tokio.
`vault_core` es una librería FFI llamada síncronamente desde Swift. Se define:

- El runtime Tokio se crea **una sola vez** como `Lazy<Runtime>` global en `ai_engine/mod.rs`.
- Ninguna función FFI crea su propio runtime — todas invocan `TOKIO_RT.block_on(...)`.
- Si `vault_core` incorpora Tokio en otro módulo en el futuro, consolidar ambos bajo el mismo singleton.

### D3 — Feature flag y ramas `cfg` explícitas

El XCFramework de distribución **siempre** se compila con `--features local-ai`. Sin embargo,
todas las funciones FFI del módulo `ai_engine` deben tener ambas ramas definidas:

```rust
#[uniffi::export]
pub fn ai_is_available() -> bool {
    #[cfg(feature = "local-ai")]
    { crate::ai_engine::AI_MANAGER.is_available() }
    #[cfg(not(feature = "local-ai"))]
    { false }
}
```

Esto garantiza que un build sin `local-ai` (ej. desarrollo o CI liviano) compile sin errores
y que el contrato Swift sea siempre idéntico independientemente del feature.

---

## Consecuencias

**Positivas:**
- Reemplaza el mock de L1177 con síntesis real generada por LLM
- In-process → sin IPC, mismo proceso, sin dependencias de runtime externas
- Licencia MIT del motor + Apache 2.0/MIT de los modelos: sin restricciones comerciales
- Chat template por modelo desde GGUF: código desacoplado del formato de cada modelo
- Grammar GBNF: output JSON confiable incluso en modelos 1B–4B cuantizados

**Riesgos y mitigaciones:**

| Riesgo | Mitigación |
|---|---|
| Tamaño binario real con llama.cpp+Metal (estimado previo "2–5MB" era optimista) | Medir empíricamente al cerrar Fase 3 antes de fijar cualquier número |
| `llama-cpp-2` en 0.x → breaking changes posibles | Fijar versión exacta en Cargo.lock, no bumpar sin pruebas |
| `hf-hub` puede ser peso muerto si ya se tiene URL+SHA256 en catálogo | Evaluar en Fase 2: si `reqwest` cubre las necesidades, eliminar `hf-hub` |
| Modelo GGUF ocupa 1.2–2.5 GB en disco del usuario | Opt-in explícito con información de tamaño antes de descargar |
| llama.cpp no explota ANE al máximo | CoreML considerado para implementación futura via `CoreMlEngine` |

---

## Nota sobre Fase 5 — Fine-tuning Vector B y consentimiento explícito

El Vector B de fine-tuning (asistido via MCP: enviar notas del vault a un agente externo para
generar pares Q&A) es el **único punto del plan que rompe el modelo "100% local"** de Fases 1–4.
Cuando se implemente, debe tener un gate de consentimiento explícito y separado del resto de la
activación de AI:

> *"Para generar el dataset de entrenamiento, [N] notas de tu vault serán enviadas a [proveedor].
> ¿Confirmas que deseas continuar?"*

Este gate es independiente del toggle "Activar IA Local". Los Vectores A y C del fine-tuning
(llama.cpp LoRA local y mlx-rs nativo) no requieren este gate porque son 100% offline.

---

## Notas sobre mlx-rs y el futuro

`mlx-rs` es el binding Rust de MLX (Apple ML Research). Su roadmap incluye soporte de inferencia LLM,
pero hoy solo expone operaciones tensoriales de bajo nivel. Cuando tenga:
- Tokenizador integrado
- Soporte de modelos en safetensors/GGUF
- Sampling (temperature, top-p, etc.)

...se implementará `MlxEngine` como alternativa preferente, ya que MLX usa directamente Metal/ANE
sin capa de traducción, obteniendo la máxima eficiencia en Apple Silicon.

El diseño del trait garantiza que este swap sea transparente para Swift.
