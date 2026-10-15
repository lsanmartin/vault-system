---
nid: vs-prefill-20261003
fecha: 2026-10-03
status: draft
confidence: high
source: conversacion:2026-10-03
tags: [vault-system, swiftui, mlx, local-llm, prefill, apple-silicon, kv-cache]
---

# Plan de Optimización de Pre-fill y Caché — vault-system

**Proyecto:** `~/dev/vault-system`  
**Fecha:** 2026-10-03  
**Estado:** Plan Inicial (Listo para ejecución)  
**Referencias:** [2026-10-03-plan-optimizacion-prefill-ia.md](../../../obsidian/03-Metodos/2026-10-03-plan-optimizacion-prefill-ia.md) · [telemetria.log](../../../obsidian/00-Sistema/telemetria.log)

---

## 1. Contexto y Diagnóstico
`vault-system` es una aplicación de escritorio nativa (SwiftUI + MLX) que ejecuta modelos locales en Apple Silicon para tareas de orquestación, RAG y asistencia dentro del sistema de archivos.

- **Cuello de Botella en Apple Silicon:** Modelos locales (ej. Gemma 4B, Qwen) procesan prefill a velocidades acotadas por ancho de banda de memoria unificada (~400–500 tok/s). Prompts largos de notas de vault causan demoras de varios minutos antes de emitir el primer token.
- **Fricciones Registradas en Telemetría:** Línea 51 reporta alucinaciones de sintaxis y llamadas a herramientas inexistentes (`vault_get_domain_context`) provocadas por sobrecarga de contexto en modelos compactos.

---

## 2. Líneas de Acción Específicas

### A. Habilitación de Caché KV Cuantizada (FP8 / INT4)
- Configurar el runtime de inferencia en MLX para almacenar los tensores Key/Value en precisión reducida (FP8 o cuantización K-quants).
- Reduce la huella en memoria de la caché KV en 50%–75% y acelera la tasa de transferencia de datos hacia los núcleos de cómputo en la GPU integrada.

### B. Segmentación de Chunks RAG (Anti-Inyección Masiva)
- En el subsistema de consulta de notas (`query_notes`), prohibir la inyección de notas Markdown completas con frontmatter extenso y secciones secundarias.
- Inyectar exclusivamente fragmentos de texto procesados (chunks de máx. 250 palabras) filtrados por coincidencia semántica y nivel de autoridad OKF (N1/N2).

### C. Desacoplamiento de Capas de Prefill (Patrón YOCO / Sparse)
- En futuras migraciones de modelos de base en MLX, priorizar checkpoints con atención cruzada ligera (donde el contexto prefill no computa atención densa en todas las capas del transformador), reduciendo las operaciones de prefill hasta 4x.

---

## 3. Criterios de Aceptación
1. Latencia TTFT (Time To First Token) en inferencia local inferior a 10 segundos en consultas con 8k tokens de contexto.
2. Cero caídas por saturación de memoria RAM unificada en hardware de 16 GB y 32 GB.
