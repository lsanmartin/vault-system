# Análisis Arquitectónico e Integración MCP (vault-system)

## 1. Diseño Arquitectónico General

La estructura del proyecto demuestra madurez y claridad de responsabilidades. La separación en capas (*Taxonomía de Tres Capas*) entre la interfaz de usuario en Swift, el motor universal de renderizado, y el motor de procesamiento semántico en Rust es la configuración ideal para una aplicación "Knowledge OS" de escritorio.

### Fortalezas Estructurales
* **Rendimiento Nativo:** El uso de UniFFI puentea macOS nativo (SwiftUI) con un binario precompilado y altamente eficiente (Rust). Esto significa que las cargas computacionales masivas (ej. recorrer miles de carpetas o generar incrustaciones vectoriales) no congelan la UI ni el `Main Thread` del sistema operativo.
* **Semantic Search Integrado:** El núcleo de Rust incluye su propia capacidad de generar embeddings al vuelo (implementado de forma algorítmica en `lib.rs` sin dependencias externas monstruosas) y almacenarlos en matrices nativas de DuckDB. Esto proporciona una excelente base determinista y rápida sin requerir dependencias de red o de GPU dedicada masiva.
* **DuckDB In-Memory:** El uso de la base de datos DuckDB de forma efímera para construir el índice semántico es un diseño de alto rendimiento (*OLAP* nativo de alta eficiencia en memoria).

## 2. Preparación para Integración MCP (Agentes IA)

### Estado Actual del MCP
El archivo `agent.md` visiona una *"Vault App Store: Sistema de gestión para harnesses, workflows, skills y MCPs oficiales"*. Sin embargo, a nivel de código fuente (`Cargo.toml` de `core`), **el framework de Model Context Protocol (MCP) aún no ha sido integrado físicamente**. El sistema está posicionado arquitectónicamente para hacerlo de forma perfecta.

### Ventajas de Integrar MCP en la Capa Rust (Recomendado)
Para materializar el hub central de Inteligencia Artificial que se proyecta, la implementación del Servidor MCP debe residir estrictamente en la capa Rust (`core/`) y NO en la capa Swift.

1. **Abstracción Total de los Agentes:** Al levantar un servidor MCP en Rust, herramientas como "Búsqueda Semántica" y "Acceso al Historial de Vault" pueden ser expuestas a IAs locales o conectadas (e.g. Gemini, Claude Desktop).
2. **Protocolo Estándar:** Usando un crate Rust como `mcp-rs`, el sistema se vuelve universal. Cualquier agente conectado puede entender automáticamente cómo interactuar con `vault-system`.

### Estrategia Definitiva de "Data Blindness": Arquitectura Dual-Brain

El problema de exponer el "Conocimiento Disciplinar" puro (documentos privados, papers, notas) a un LLM remoto a través del MCP es el mayor riesgo de privacidad del sistema. La solución óptima es crear una **Arquitectura de Metadatos Desacoplada (Dual-Brain)** impulsada por el Daemon en Rust.

1. **El Cerebro Interno (IA Local en Rust/MLX):**
   * El Daemon de Vault, ejecutándose en segundo plano, utiliza un modelo local pequeño y rápido (ej. Llama-3-8B cuantizado o Apple Foundation Models on-device) para **leer sistemáticamente el conocimiento disciplinar en crudo**.
   * Su única tarea es *digerir* la información y extraer una **capa de metadatos semánticos estructurados**: resúmenes conceptuales densos, grafos de entidades, timestamps de evolución cognitiva y categorizaciones.
   * Estos metadatos, junto con los embeddings vectoriales, se almacenan en la instancia de DuckDB. El texto crudo original *nunca* abandona esta capa.

2. **El Cerebro Externo (LLM Remoto vía MCP):**
   * Cuando te conectas a VAULT usando una IA avanzada en la nube (como Claude o Gemini) vía MCP, este agente externo **sólo tiene permiso para consultar la capa de metadatos semánticos en DuckDB**, jamás el conocimiento disciplinar crudo.
   * *Ejemplo de interacción:* El MCP expone una herramienta `query_vault_concepts(topic)`. Claude la invoca y Vault le devuelve: *"El usuario tiene 14 nodos sobre X, evolucionaron desde la perspectiva Y a la Z en los últimos 3 meses"*. Claude usa esa *metadata sintética* para razonar contigo, sin haber leído jamás tus documentos confidenciales.

3. **El desafío del Daemon y el Handoff:**
   * El `README.md` menciona un módulo `Daemon`. El servicio MCP y la IA Local de extracción deben correr adscritos a este Daemon para que la base de datos de metadatos se enriquezca pasivamente (incluso si la UI principal Swift está cerrada) y esté siempre lista para responder a las IAs remotas con latencia cero y total privacidad.
