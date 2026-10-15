# Informe Técnico: Arquitectura Eutrópica, Blindaje PII y Transición Database-First de Workspaces

> 🗓️ **Fecha:** 2026-10-15  
> 🏷️ **Contexto:** Modelo de gobernanza en dos planos (Vault-app local vs. Gobernanza central), Blindaje PII en MCP, Rediseño de Workspaces en Vault-System e Integración de PostgreSQL en Catálogo  
> 📌 **Estado:** Consolidado y Actualizado  

---

## 1. Resumen Ejecutivo

Este informe consolida el marco arquitectónico definitivo del ecosistema analítico y de conocimiento (`vault-app`, `vault-system`, `dashai`, `obsidian`), articulando cuatro ejes críticos:
1. **Separación de planos de cómputo y almacenamiento:** Cálculo determinista local en `vault-app` y catalogación central inmutable en Apache Parquet particionado anualmente.
2. **Blindaje PII y soberanía frente a IA:** Inviolabilidad del archivo Parquet. Los modelos de lenguaje nunca acceden a microdatos crudos; operan estrictamente sobre perfiles estadísticos agregados, esquemas de variables no privadas y ontologías semánticas (Lore) expuestas mediante herramientas MCP controladas.
3. **Evolución de Workspaces (Database-First):** Superación del cuello de botella de Markdown (`.md`) como sustrato operacional en `vault-system`. Se formaliza el paso hacia bases de datos transaccionales (SQLite en modo WAL) para el trabajo diario con textos y metadatos, relegando el formato Markdown a una vista derivada y opcional para consumo humano o respaldo.
4. **Catálogo de Metadatos Dual (SQLite Local vs. PostgreSQL Central):** Incorporación de PostgreSQL como alternativa superior para el catálogo maestro institucional multi-analista frente a SQLite en el borde.

---

## 2. Blindaje de Privacidad (PII) e Inviolabilidad de Parquet

### 2.1 Oclusión en Tiempo de Compilación (`vault-app` / Rust Core)
La protección de datos personales opera en el origen mediante código nativo en `vault-core`:
*   **Filtrado Case-Insensitive en Profiling:** Durante la ejecución de cualquier nodo, el backend en Rust analiza las columnas contra la lista de variables sensibles (`sensitive_columns` / `sensitive_set`) y de control interno (`is_internal_column`).
*   **Oclusión de `.meta.json`:** Si una columna se cataloga como PII, el proceso de perfilado omite por completo su análisis estadístico (`continue`). El archivo `.meta.json` generado en disco almacena únicamente el nombre y el tipo de dato (`{"name": "rut", "type": "VARCHAR"}`), eliminando valores mínimos, máximos, cardinalidad, valores nulos y muestras (`sample_values`).
*   **Nodos `privacidad_pii` y Cumplimiento Normativo:** Mapeo de campos a categorías legales (identificatorios, financieros, salud) y consolidación en el Registro de Actividades de Tratamiento (`rat_reporte`) bajo GDPR Art. 30 y Ley 21.719 de Chile.
*   **Nodos de Credenciales Ocultos (`credencial`):** Los secretos residen en el Keychain del sistema operativo. Estos nodos son de configuración exclusiva en UI y están bloqueados frente al servidor MCP por defensa en profundidad.

Referencia técnica: [reporte_verificacion_pii_mcp.md](../../.gemini/antigravity-cli/brain/36408b6f-e6fa-425c-a216-4a98bdddf264/reporte_verificacion_pii_mcp.md) y [2026-10-11-analisis-nodos-bpmn-gobernanza-rat.md](../../02-Proyectos/vault-app/2026-10-11-analisis-nodos-bpmn-gobernanza-rat.md)

### 2.2 Restricción Estricta del Protocolo MCP
*   **Prohibición de Herramientas Crudas:** El servidor MCP de `vault-app` expone exclusivamente herramientas de inspección de esquemas (`mcp_get_schema`) y consulta de metadatos saneados (`mcp_query_metadata`). No contiene herramientas de lectura directa de tablas (`read_parquet` o ejecución de `query` libre sobre microdatos).
*   **Inviolabilidad del Parquet:** Los archivos `.parquet` permanecen aislados en el disco local o en S3. La IA jamás abre un Parquet con registros individuales de estudiantes o docentes; solo consume los metadatos y perfiles filtrados en `.meta.json`.

### 2.3 Cortafuegos Semántico y Aprobaciones en DashAI
*   **`PromptFirewall`:** Intercepta las solicitudes del usuario y del agente para abortar cualquier intento de volcar microdatos sin agregación previa.
*   **`privacy_profiler`:** Aplica supresión complementaria y verifica el umbral de tamaño mínimo de celda ($N \ge 5$) para impedir ataques de reidentificación por inferencia.
*   **Permisos Granulares de Proveedor:** En `~/.DashAI/mcp_config.json`, cada agente dispone de permisos delimitados (`read_meta`, `write_meta`, `read_data`, `write_data`).
*   **Panel de Aprobaciones (`APPROVAL_TOOLS`):** Operaciones de entrenamiento, predicción o exportación masiva pausan la ejecución hasta recibir autorización humana en la UI.

Referencia técnica: [dashai-tokens-chat-ia.md](../../03-Metodos/ia/mcp/2026-09-24-dashai-tokens-chat-ia.md)

---

## 3. Rediseño de Workspaces en `vault-system`: De Markdown-First a Database-First

### 3.1 Diagnóstico de Ineficiencia de Markdown (`.md`) como Almacén Operativo
En `vault-system`, persistir el árbol de trabajo, textos y notas directamente en archivos `.md` sobre APFS/iCloud generó fricciones estructurales severas:
*   **Colapso OLTP sobre Motor OLAP (DuckDB):** Tratar a DuckDB como gestor de navegación de archivos requirió un mutex global (`DB_QUERY_MUTEX`), elevando la latencia de respuesta de la UI a picos de 3.000 ms por bloqueos de hilo.
*   **I/O Innecesario y Escaneos Masivos:** El escaneo continuo de decenas de miles de archivos Markdown para extraer metadatos y embeddings bloquea el CPU y satura el hilo principal de renderizado en SwiftUI.
*   **Fricción con Sincronización iCloud:** La hidratación asíncrona de archivos `.md` en disco dispara bloqueos de lectura, errores de permisos TCC y cuellos de botella en watchers de sistema de archivos.

Referencia técnica: [diagnostico-vault-system-performance.md](../../.gemini/antigravity-cli/brain/add0ba06-84ba-4d1b-89c0-efe17d9e7952/diagnostico-vault-system-performance.md)

### 3.2 El Paradigma Database-First (BBDD Transaccional en SQLite WAL)
Para textos, borradores, definiciones, metadatos y jerarquías de trabajo, el sustrato primario de ejecución debe ser una base de datos relacional transaccional, no el sistema de archivos:
*   **Operación 100% en BBDD (SQLite modo WAL):** 
    *   CRUD sub-milisegundo sin bloqueos de lectura/escritura concurrentes.
    *   Búsqueda determinista de texto completo mediante FTS5 integrada nativamente.
    *   Estructura relacional para workspaces, carpetas virtuales, etiquetas y entidades.
*   **Markdown como Vista Materializada Derivada (Opcional):**
    *   Los archivos `.md` ya no son la fuente de la verdad; se convierten en proyecciones exportadas bajo demanda.
    *   Solo se serializa a Markdown cuando el usuario solicita explícitamente editar en un editor externo (como One Markdown / Obsidian), sincronizar con un repositorio Git público o generar un entregable formal.
*   **Desacople de la IA:** La IA no necesita leer archivos `.md` dispersos en disco. El servidor MCP consulta directamente las tablas SQLite del workspace con filtros de privacidad y devuelve el contexto estructurado en milisegundos, reduciendo el consumo de tokens de prefill.

---

## 4. Modelo Operativo de Doble Procedimiento (Cálculo vs. Ingesta)

```
┌─────────────────────────────────────────────────────────────┐
│                 ENTORNO LOCAL (VAULT-APP)                   │
├─────────────────────────────────────────────────────────────┤
│ • Procedimiento 1: Cálculo en Borde                         │
│   - Workspace en BBDD local (SQLite / DuckDB CTEs)          │
│   - Transformaciones sobre periodo activo 2026              │
│   - Generación atómica de matricula_2026.parquet            │
│   - Extracción de .meta.json (perfiles PII ocluidos)        │
│   - Manifiesto semántico + Checksum SHA-256                 │
└──────────────────────────────┬──────────────────────────────┘
                               │ Envío de activo anual
┌──────────────────────────────▼──────────────────────────────┐
│             SERVICIO CENTRAL (WORKER SERIALIZADO)           │
├─────────────────────────────────────────────────────────────┤
│ • Procedimiento 2: Ingesta, Catálogo y Purga                │
│   - Test de apertura en DuckDB efímero (:memory:)           │
│   - Reemplazo atómico exclusivo de partición 2026 en S3     │
│   - Asiento transaccional en catálogo PostgreSQL / SQLite   │
│   - Emisión de recibo firmado criptográficamente (Ed25519)  │
│   - Disparo de purga obligatoria en Vault local del analista│
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│           ALMACENAMIENTO INMUTABLE Y CAPA SEMÁNTICA         │
├─────────────────────────────────────────────────────────────┤
│ • S3: Serie 2002-2025 congelada + Partición 2026 activa     │
│ • Catálogo Central (PostgreSQL): Linaje, esquemas y estados │
│ • Servidor MCP: Consultas agregadas sin acceso a Parquet    │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. Opciones de Diseño y Decisiones Técnicas Consolidadas

### Opción A: Particionamiento de la Serie Histórica (Anual vs. Monolítico)
*   *Alternativa 1 (Archivo Monolítico Único 2002-2026):* Descartada. Obliga a reescribir toda la serie en cada actualización, destruye cierres contables y anula la inmutabilidad de periodos previos.
*   *Alternativa 2 (Particionamiento Anual `matricula_YYYY.parquet` - Seleccionada):* Aprobada. Aísla modificaciones al periodo 2026, mantiene intactos los hashes de 2002-2025 y permite consultas globales en DuckDB mediante globbing: `SELECT * FROM read_parquet('matricula_*.parquet')`.

### Opción B: Catálogo de Metadatos (SQLite WAL vs. DuckDB vs. PostgreSQL)

>> Tal vez podemos probar en este logica, pero mas adelante incorporar el motor de sqlite directamente en vault-app y que alimente un espejo central que use postgre

*   *Alternativa 1 (DuckDB Central):* Descartada por colapsos ante accesos concurrentes (`SIGBUS`) y falta de transaccionalidad OLTP. DuckDB no soporta múltiples escritores simultáneos sobre un mismo archivo.
*   *Alternativa 2 (SQLite modo WAL - Seleccionada para el Borde Local):* Aprobada en estaciones de trabajo y `vault-app`. Archivo único embebido, cero mantenimiento de servidores y transaccionalidad robusta multi-lectura/escritor único para el analista individual.
*   *Alternativa 3 (PostgreSQL - Seleccionada para la Capa Central Institucional):* Aprobada como catálogo de metadatos centralizado.
    *   **Evaluación de Concurrencia:** Control de concurrencia multiversión (MVCC) con bloqueos a nivel de fila. Elimina el cuello de botella de escritor único y permite que múltiples analistas o procesos automáticos registren manifiestos simultáneamente sin riesgo de contención.
    *   **Esquemas Flexibles con JSONB:** Permite almacenar manifiestos de esquemas, perfiles de variables y configuraciones semiestructuradas (`manifest.jsonb`) con indexación GIN de alto rendimiento.
    *   **Seguridad y Gobernanza:** Seguridad a nivel de fila (Row-Level Security / RLS) y control de acceso basado en roles (RBAC) nativos para restringir qué metadatos o linajes puede consultar cada usuario o agente.
    *   **Indexación Semántica y Lore:** Soporte de búsqueda de texto completo avanzada y compatibilidad con extensiones como `pgvector` para catalogar y consultar el histórico de reglas del Lore institucional.
    *   **Veredicto Arquitectónico Dual:** SQLite (WAL) confinado al borde local (`vault-app`); PostgreSQL en el servidor central como la base de datos maestra de metadatos, linaje y cierres contables. DuckDB se utiliza como motor efímero en memoria (`:memory:`) para resolver consultas analíticas sobre los archivos Parquet en S3.

### Opción C: Sustrato Operativo de Workspaces (Database-First vs. Markdown-First)
*   *Alternativa 1 (Archivos Markdown en Disco):* Descartada como motor primario de trabajo por latencia, bloqueos de I/O y saturación en sincronización de archivos.
*   *Alternativa 2 (BBDD Transaccional SQLite con Markdown Derivado - Seleccionada):* Aprobada. Operación, textos y jerarquías viven en SQLite (FTS5); Markdown se genera únicamente como vista de exportación o contexto acotado.

### Opción D: Ingesta y Despacho (Worker Serializado vs. Subida Directa)
*   *Alternativa 1 (Subida Directa a S3):* Descartada por riesgo de colisiones y ruptura del protocolo de purga.
*   *Alternativa 2 (Worker Despachador Serializado - Seleccionada):* Aprobada. Valida integridad con DuckDB en memoria, persiste en S3, actualiza el catálogo central (PostgreSQL/SQLite) y emite el acuse Ed25519 que habilita la purga local.

### Opción E: Frontera de IA (MCP con Blindaje PII vs. Acceso a Datos Crudos)
*   *Alternativa 1 (Acceso de IA a Archivos Parquet o Volcado en Contexto):* Descartada por violación de normativas de privacidad, riesgo de reidentificación y alucinaciones de cálculo.
*   *Alternativa 2 (MCP con Oclusión PII y `PromptFirewall` - Seleccionada):* Aprobada. La IA jamás toca Parquet; solo consume metadatos de variables no sensibles, perfiles estadísticos filtrados y ontologías semánticas (Lore).

---

## 6. Plan Operativo de Implementación (Fases 1 a 5)

| Fase | Denominación | Foco Operativo | Entregables Clave |
| :--- | :--- | :--- | :--- |
| **Fase 1** | Catastro Físico y Selección de Caso Testigo | Inventario de artefactos y flujos heredados (Python, KNIME, R). | Selección de **Avance Académico** como pipeline piloto. |
| **Fase 2** | Desarme y BBDD Local (`vault-app`) | Prototipado mediante CTEs y sustrato Database-First (SQLite WAL). | Activos A, B, C; `matricula_2026.parquet` + `.meta.json` ocluido + SHA-256. |
| **Fase 3** | Ingesta, Catálogo Central y Purga Local | Worker despachador, validación efímera y acuse Ed25519. | Almacenamiento S3; catálogo central PostgreSQL; purga obligatoria en el cliente. |
| **Fase 4** | Orquestación, Cómputo Efímero y MCP | Control en Dagster y exposición segura de consultas agregadas. | *Asset checks* (bandas eutrópicas); endpoints MCP con `PromptFirewall`. |
| **Fase 5** | Cuentas de Entrega, Lore y Cierre Formal | Formalización de la verdad metodológica y registro normativo. | Cierre inmutable de corte; actualización de Lore (PostgreSQL/YAML); actualización RAT/SODC. |

---

## 7. Matriz de Riesgos y Mitigaciones Operativas

| Riesgo Técnico / Operativo | Impacto | Mitigación Implementada |
| :--- | :--- | :--- |
| **Fuga de microdatos personales hacia la IA** | Violación legal (GDPR / Ley 21.719). | Oclusión de variables sensibles en `.meta.json` (Rust); prohibición de herramientas `read_parquet` en MCP; activación de `PromptFirewall`. |
| **Sobreescritura de series históricas** | Destrucción de cierres contables previos. | Particionamiento anual estricto; el servicio central solo admite escrituras sobre la partición del año activo. |
| **Bloqueos de interfaz por I/O de Markdown** | Congelamiento de UI (~3.000 ms). | Migración a modelo Database-First (SQLite WAL); Markdown relegado a vista materializada derivada. |
| **Cuello de botella de concurrencia en catálogo** | Bloqueo en cierre masivo de periodos. | Catálogo central en PostgreSQL con MVCC y bloqueo a nivel de fila; SQLite confinado al borde local. |
| **Purgas prematuras en clientes locales** | Pérdida definitiva de cálculos. | El script local exige un comprobante firmado Ed25519 emitido por el worker central antes de purgar archivos. |

---

## 8. Conclusión

La arquitectura eutrópica consolida un equilibrio de alto rendimiento y gobernanza estricta:
1. **En el borde (`vault-app`):** Máxima agilidad bajo el modelo **Database-First** (SQLite WAL), desacoplando el cómputo analítico de la persistencia central y eliminando la sobrecarga del formato Markdown.
2. **En la capa central:** Máxima robustez institucional mediante **PostgreSQL** para el catálogo transaccional multi-usuario y **Apache Parquet particionado por año** en S3 para el almacenamiento inmutable.
3. **Frente a la Inteligencia Artificial:** Blindaje integral mediante **MCP**, garantizando que el modelo analítico opere con pleno contexto metodológico (Lore) y ontológico sin tocar jamás los microdatos protegidos.
