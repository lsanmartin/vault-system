# Plan de Evolución Arquitectónica: Modelo Database-First con Proyección Markdown

> **Fecha:** 2026-10-10  
> **Proyecto:** `vault-system`  
> **Estado:** Propuesta de Diseño / Backlog  
> **Referencia:** Kanban Tarea `BBDD-FIRST-01`

---

## 1. Motivación y Diagnóstico

Actualmente, `vault-system` implementa un patrón **File-First con Caché Indexada**:
- La fuente de verdad reside en los archivos Markdown (`.md`) en disco.
- Un escáner recursivo (`scan_vault`) y un `notify::Watcher` indexan las notas en DuckDB.
- **Dolores detectados:**
  - Cuelgues por contención en iCloud (stubs no descargados) y saturación en arranques con miles de archivos.
  - Micro-commits intensivos de Git al tipear en el editor.
  - El escaneo global al arranque compite con la UI.

---

## 2. Paradigma Propuesto: Database-First (Estilo Apple Notes)

Invertir la fuente de verdad operativa hacia la base de datos interna, manteniendo el sistema de archivos como **proyección local soberana y caché desechable**:

```
[ Usuario / UI / AI ] ──> [ Store Local (DuckDB / SQLite) ]
                                    │
                                    ▼ (Debounce asíncrono)
                         [ Proyector Rust (.md) ]
                                    │
                                    ▼
                         [ Worker Git (.git) ]
```

### Pilares del Diseño:
1. **Escritura y Lectura Instantáneas:** Las mutaciones ocurren en memoria/BBDD en <2 ms sin esperar por I/O de disco ni bloqueos de red/iCloud.
2. **Proyección Asíncrona:** Un worker en Rust toma las notas modificadas (`is_dirty = true`), escribe el `.md` en el workspace local y actualiza los hashes.
3. **Filtro Anti-Eco:** El watcher de archivos conoce los hashes proyectados y descarta eventos de modificación generados por la propia aplicación.
4. **Git Ordenado:** Los commits en el `.git` del vault se disparan tras la consolidación del proyector (eliminando micro-commits por pulsación de tecla).
5. **Capa de Contexto IA Enriquecida:** El proyector puede generar artefactos optimizados:
   - `_index/` (grafos, resúmenes BM25).
   - `_recent/` (notas activas recientes).
   - `manifest.json` (hashes para consultas con consumo mínimo de tokens).

---

## 3. Hoja de Ruta de Implementación

- **Fase 1 (Esquema y Control):** Columnas `content_hash`, `is_dirty`, `version` en la tabla `notes`.
- **Fase 2 (Inversión de Guardado):** `save_note` escribe en BBDD primero y encola en el proyector.
- **Fase 3 (Proyector y Anti-Eco):** Worker de escritura en disco con debounce (500 ms - 1 s).
- **Fase 4 (Pipeline Git):** Enlace del proyector con `enqueue_git_commit`.
