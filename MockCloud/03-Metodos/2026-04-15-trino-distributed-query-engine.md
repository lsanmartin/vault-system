# Trino: Motor de Consultas SQL Distribuido (MPP)

Trino (anteriormente PrestoSQL) es un motor de ejecución de consultas SQL distribuido diseñado para analizar grandes volúmenes de datos donde residen (S3, HDFS, SQL, NoSQL), sin necesidad de moverlos (Data Federation).

## Conceptos Clave
- **Arquitectura MPP:** Un solo Coordinador (planifica/orquesta) y múltiples Workers (procesan datos).
- **Pipelined Execution:** Los datos fluyen en memoria entre etapas (stages) sin escribir a disco, permitiendo baja latencia interactiva.
- **Conectores (SPI):** Abstraen la fuente de datos. Separan Metadatos (esquema) de Datos (lectura de filas/splits).
- **Cost-Based Optimizer (CBO):** Utiliza estadísticas (NDV, histogramas) para optimizar el orden de joins y estrategias de distribución (Broadcast vs Partitioned).

## Optimizaciones de Rendimiento
- **Dynamic Filtering:** Filtros generados en tiempo de ejecución de una tabla pequeña se "empujan" al escaneo de la tabla grande (pruning de archivos/particiones).
- **Data Lakehouse:** Soporte profundo para formatos abiertos como **Apache Iceberg**, **Delta Lake** y **Hudi**, permitiendo transacciones ACID y evolución de esquemas.

## Resiliencia: Proyecto Tardigrade
- Permite la ejecución de tareas batch (ETL) con **tolerancia a fallos**.
- **Task Retries:** Reintenta tareas individuales si un worker falla.
- **Exchange Manager:** Spoollea datos intermedios a almacenamiento externo (S3) para manejar consultas que superan la memoria del clúster.

## Casos de Uso
1. **Analítica Interactiva:** Consultas rápidas para dashboards y exploración de datos ad-hoc.
2. **Federación de Consultas:** Unir datos de S3 con PostgreSQL y Kafka en una sola consulta.
3. **ETL de Alta Velocidad:** Procesamiento de transformaciones masivas usando SQL estándar.

## Comparativa Rápida
- **Trino vs PrestoDB:** Trino es el fork impulsado por la comunidad original, enfocado en innovación rápida. PrestoDB es mantenido por Meta (Facebook).
- **Trino vs Spark:** Trino es mejor para SQL interactivo (< 30s); Spark es mejor para procesamiento general (ML, Batch complejo) con alta tolerancia a fallos nativa.
- **Trino vs Snowflake:** Trino consulta datos en formatos abiertos ("Open Lakehouse"); Snowflake requiere ingesta en almacenamiento propietario.

---
*Referencia técnica completa en: 05-IA-Drafts/gemini/2026-04-15-DEEP-REPORT-Trino-Architecture.md*
