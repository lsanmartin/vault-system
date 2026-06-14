# Plan Estratégico de Implementación: VAULT-System (Rama: dev2)

Este documento detalla el roadmap técnico estructurado en 5 fases secuenciales para transformar `vault-system` desde un repositorio pasivo hacia el **Sustrato Cognitivo (Exocórtex Privado)**, integrando los hallazgos de la auditoría estratégica de 2026 y la arquitectura Dual-Brain.

---

## FASE 1: Aceleración de Hardware (El Cimiento de MLX)
**Objetivo:** Abandonar la generación *naive* de embeddings en CPU genérica y explotar el Neural Engine del Apple Silicon (Zero-Copy Transfer).

1. **Dependencias:** Añadir `mlx-rs` (o bindings C++ de MLX) al `Cargo.toml` en el módulo `core`.
2. **Refactorización de Embeddings:** Reemplazar la función algorítmica iterativa actual (`generate_embedding` en `lib.rs`) por una llamada directa al tensor en memoria unificada usando Metal 4.
3. **Métricas de Éxito:** Validar que el throughput de indexación se incremente entre 5x-15x reduciendo drásticamente la latencia de escaneo.

---

## FASE 2: Data Blindness & Arquitectura Dual-Brain (El Daemon Cognitivo)
**Objetivo:** Proteger el conocimiento disciplinar y generar la capa de metadatos sintéticos que será consumida por las IAs externas.

1. **Actualización de Esquema DuckDB:** Modificar la inicialización en `lib.rs` para soportar tablas de metadatos sintéticos separadas del texto crudo (ej. `semantic_summaries`, `entity_graphs`).
2. **Integración de IA Local (El Digestor):** 
   - Acoplar un LLM cuantizado (ej. vía `llama.cpp` Rust bindings o Foundation Models locales) al Daemon.
   - Programar un hilo en segundo plano que despierte en "idle" (ej. 3 AM) y procese las notas nuevas para extraer resúmenes densos, entidades y timestamps cognitivos, guardando esto en las nuevas tablas de DuckDB.
3. **Capa MCP Segura:** Desarrollar el servidor MCP en Rust que exponga **exclusivamente** las tablas de metadatos sintéticos (TopK restrictivo), bloqueando por defecto el acceso al contenido crudo de las notas.

---

## FASE 3: El Grafo de Conocimiento Temporal
**Objetivo:** Dotar al sistema de la capacidad de entender cómo evoluciona el conocimiento del usuario a través del tiempo.

1. **Modelo Relacional Temporal:** Añadir vectores temporales a cada nodo en DuckDB.
2. **Backlinks Dinámicos:** Utilizar funciones analíticas (Window Functions) y *AS OF joins* de DuckDB para establecer saltos temporales ("cómo cambió mi entendimiento de este tema desde Enero a Junio").
3. **Consolidación de Memoria:** Implementar un loop que genere "nodos de síntesis" periódicos, agrupando ideas dispares y detectando contradicciones en el corpus histórico.

---

## FASE 4: Sinergia con Apple Ecosystem (WWDC 2026)
**Objetivo:** Transformar VAULT en un proveedor nativo para el ecosistema macOS.

1. **LanguageModel Protocol:** A través del puente UniFFI, actualizar la capa de SwiftUI para que la app se registre nativamente como un proveedor `LanguageModel` usando el nuevo Foundation Models framework.
2. **Spotlight & Siri AI:** Exponer la base de datos de DuckDB (los metadatos) a Siri AI. Ahora el SO puede consultar a VAULT en nombre del usuario.
3. **Routing con Dynamic Profiles:** Preparar la UI para despachar tareas analíticas complejas (que excedan la capacidad del modelo local) hacia Private Cloud Compute (PCC) o Anthropic/Google preservando el cifrado del contexto.

---

## FASE 5: UI Cognitiva (El Panel de Control del Exocórtex)
**Objetivo:** Elevar la interfaz gráfica de un contenedor pasivo a un HUD (Head-Up Display) de inteligencia aumentada.

1. **Cognitive Radar (Widget):** Implementar un panel inferior en SwiftUI que mida en tiempo real: Novedad, Cobertura, Carga Cognitiva y Alertas de Contradicción sobre el documento que se está escribiendo.
2. **Semantic Heat Map Overlay:** Añadir un renderizado especial al modo Universal que resalte visualmente los "Gaps" (Dark Matter) y los conceptos que están altamente respaldados por el corpus previo.
3. **Memory Palace / Árbol Mejorado:** Evolucionar el `VaultTreeView` para reflejar clústeres de proximidad semántica, no solo estructuras de carpetas del Finder.

---

## Próximos Pasos (Inmediatos en dev2)
1. Comenzar aislando la capa FFI para la inyección del MLX backend (Fase 1).
2. Crear los esquemas de bases de datos adicionales en DuckDB para la capa "Dual-Brain" (Fase 2).
