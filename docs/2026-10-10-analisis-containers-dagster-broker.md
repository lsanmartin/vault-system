# Análisis de Arquitectura: Función de Containers y Orquestación con Dagster

- **Fecha:** 2026-10-10
- **Proyecto:** vault-system (`cddev`)
- **Estado:** Propuesta Técnica / Planificación

---

## 1. Visión y Rol de `vault-system` como Broker de Aislamiento

El objetivo es incorporar capacidades de ejecución aislada en micro-contenedores/VMs efímeros en macOS, operables tanto manualmente por el usuario desde la UI nativa (SwiftUI) como por agentes de IA a través del Model Context Protocol (MCP).

### Principio de Soberanía y Contención TCC
1. **Host Protegido:** El proceso host de `vault-system` retiene los permisos TCC (Mail, Calendar, Finder) y el acceso a DuckDB / iCloud.
2. **Contenedor Desprovisto de Permisos:** El contenedor no hereda permisos del host, no tiene acceso a `$HOME` ni monta la raíz del vault.
3. **Comunicación Exclusiva vía Broker:** Todo acceso a datos o servicios externos debe ser solicitado al broker mediante IPC (Unix Domain Socket) sobre el protocolo MCP.

---

## 2. Diagnóstico del Entorno Local

- **Hardware:** Apple M2 Pro (`arm64`), optimizado para ejecución nativa eficiente.
- **Runtimes disponibles:** `uv` gestionado en `/Users/lsanmartin/.vault-app/runtimes/uv/uv` (Python 3.12 y 3.13 aarch64).
- **Virtualización:** Docker instalado (`/usr/local/bin/docker`). El comando `container` nativo de Apple (Containerization Framework) se encuentra en fase temprana de adopción sin soporte nativo para topologías complejas multi-proceso.

---

## 3. Estrategia de Integración: Dagster Híbrido + Pipes Efímeros

En lugar de desplegar toda la infraestructura de Dagster (Dagit, Daemon, PostgreSQL, gRPC) en una máquina virtual pesada (`docker-compose` con consumo de 2–4 GB de RAM), se adopta una arquitectura híbrida ultraligera:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        macOS Host (Ligero)                             │
│                                                                        │
│  [vault-system (Rust / Swift)] ◄─── Broker, Seguridad TCC, DuckDB      │
│          ▲                                                             │
│          │ API / MCP via Unix Domain Socket                            │
│  [Dagster Daemon + Webserver]                                          │
│  • Ejecución nativa Python 3.12 vía `uv`                               │
│  • Almacenamiento local SQLite (SqliteEventLogStorage)                 │
│  • Consumo total host: < 200 MB RAM                                    │
│                                                                        │
│          │                                                             │
│          ▼ Dispara ejecución aislada                                   │
└──────────┬─────────────────────────────────────────────────────────────┘
           │
           │ Micro-VM / Contenedor Efímero (1 tarea = 1 instancia)
           ▼
┌────────────────────────────────────────────────────────────────────────┐
│              Contenedor Efímero (Dagster Pipes)                        │
│                                                                        │
│  • Ejecuta la computación / script no confiable                        │
│  • Streaming de logs y métricas hacia el host                          │
│  • Destrucción inmediata al completar tarea (< 2s)                     │
│  • Sin persistencia local ni permisos de sistema                       │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Componentes Faltantes para Implementación en `vault-system`

### 1. Módulo de Ciclo de Vida de Contenedores (`core/src/container.rs`)
- Abstracción de backend (`docker` / `container` / `orb`).
- Métodos atómicos: `container_create`, `container_start`, `container_stop`, `container_exec`.
- Aislamiento estricto de volúmenes: únicamente directorios de trabajo temporales.

### 2. Transporte MCP sobre Unix Domain Socket
- Adaptar `core/src/mcp_server.rs` para escuchar peticiones JSON-RPC en `/tmp/vault-system-{workspace_id}.sock` además de `stdin`/`stdout`.
- Montar el socket dentro del contenedor en `/var/run/vault-system.sock`.

### 3. Exposición de Herramientas MCP
- Incorporar en `core/src/lib.rs` las funciones:
  - `container_spawn`
  - `container_run_command`
  - `container_terminate`
- Restringir uso bajo token con flag `allow_containers: true`.

### 4. Interfaz de Control (SwiftUI)
- Controles en `apple/Shared/Views/MCPAccessView` y `WorkspaceManager`:
  - Visualización y gestión manual del ciclo de vida de los contenedores por workspace.
  - Modales de aprobación para llamadas de ejecución solicitadas por agentes vía MCP.
