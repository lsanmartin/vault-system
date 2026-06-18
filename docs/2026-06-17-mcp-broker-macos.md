# ADR: Broker MCP Local y Knowledge Kernel (macOS)

**Estado**: Finalizado (Exploración y Roadmap)  
**Fecha**: 2026-06-17  
**Contexto**: Evolución de `vault-system` de un servidor MCP pasivo a un árbitro central de conocimiento.

---

## 1. Análisis de Arquitectura: La Inversión del Control

La trayectoria evolutiva del ecosistema Vault exige pasar de un modelo de "búsqueda de clientes" a un modelo de "anuncio de clientes" (**Broker Pattern**). Este cambio alinea la aplicación con los principios de seguridad nativos de macOS y refuerza la separación entre lógica y data.

### Categorización de Funciones en el Broker
El Broker no es solo un conector, es el orquestador del estándar MCP (Model Context Protocol):
- **Virtualización de Resources**: El contenido no se expone como archivos crudos, sino como "URIs de conocimiento" (`vault://`) servidas por DuckDB.
- **Gatekeeping de Tools**: RBAC (Role-Based Access Control) por cliente. Gemini CLI tiene acceso a shell; Claude Desktop solo a lectura de notas.
- **Memoria Centralizada**: Un Knowledge Graph único alimentado concurrentemente por múltiples clientes sin colisiones de estado.

---

## 2. Definición Técnica: Primitivas macOS

Para transformar `vault-system` en un servicio de sistema, se utilizarán las siguientes herramientas del sistema operativo:
1.  **URL Scheme (`vault://register`)**: El handshake inicial. macOS lanza el daemon automáticamente al recibir la petición de registro de un cliente.
2.  **XPC Service**: Comunicación IPC segura y de baja latencia (sub-milisegundo) para clientes nativos.
3.  **NSDistributedNotificationCenter**: Anuncios ligeros para scripts y CLIs que no requieren integración profunda.
4.  **Keychain & SQLite Sidecar**: Gestión de tokens y journaling de sesiones independiente del motor DuckDB (*stateless core*).

---

## 3. Crítica de Rigor Técnico (Auditoría de Riesgos)

### A. Riesgo de Abstracción Vacía
*Problema*: Añadir capas de red/IPC sin un beneficio semántico real.  
*Estrategia Elegida*: **Computed Views (Lentes de Datos)**. El Broker genera vistas DuckDB dinámicas basadas en el `project_context`, ocultando la complejidad de los archivos Parquet/YAML originales.

### B. Tensión Fricción vs. Automatización
*Problema*: El modelo de permisos de macOS destruye la proactividad del agente IA.  
*Estrategia Elegida*: **TOFU (Trust-on-First-Use) con Expiración**. La primera aprobación manual genera un token con TTL dinámico. Operaciones críticas escalan a biometría silenciosa (TouchID).

### C. Inconsistencia de Estado
*Problema*: El motor Rust es stateless, pero la sesión MCP requiere persistencia.  
*Estrategia Elegida*: **Sidecar Persistence**. El Broker gestiona una DB SQLite para la genealogía de acciones y auditoría, garantizando la integridad ante crashes del motor de datos.

---

## 4. Plan Evolutivo (Roadmap)

### Fase 1: El Núcleo Duro (MVP v1.0)
Foco en estabilidad y seguridad básica. **Sin este núcleo, el sistema es arquitectura en papel.**
- Handshake vía `vault://register`.
- Filtrado de `list_tools` por ID de cliente (RBAC).
- Implementación de TOFU con TTL.
- Herramientas base estables: `read_note`, `search_notes`, `save_note`.
- Política de concurrencia básica (Resource Locking).

### Fase 2: El Knowledge Kernel (v2.0+)
Expansión hacia la integración total con el OS.
- **Spotlight Integration**: `MDImporter` nativo para búsqueda sistémica.
- **Shortcuts Provider**: Herramientas MCP disponibles como acciones de Siri/Atajos.
- **Unified Intent Broker**: El Broker decide qué cliente (Claude/Gemini/Script) resuelve una intención específica.
- **Semantic Resolver**: Traducción de esquemas técnicos a lenguaje natural dinámico.

---

**Veredicto Final**: El Broker debe nacer como un **Gestor de Intenciones y Sesiones**. La v1.0 evitará la burocracia técnica centrándose en el contrato mínimo de confianza. Una vez consolidado, Vault trascenderá la categoría de app para convertirse en el núcleo de conocimiento del sistema operativo.
