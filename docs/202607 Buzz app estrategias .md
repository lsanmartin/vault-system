
## Buzz app estrategias 

Según la información del texto proporcionado, las funciones y estrategias de **Buzz** son las siguientes:

### Funciones Principales

* **Chat de equipo unificado:** Similar a Slack, incluye canales, hilos (*threads*), mensajes directos (DMs), intercambio de archivos multimedia y búsqueda.
* **Protocolo descentralizado (Nostr):** Toda la actividad (mensajes, reacciones, cambios de código, aprobaciones) se registra como eventos firmados en un registro de auditoría compartido y ejecutable.
* **Identidad criptográfica dual:** Cada humano y cada agente de IA tiene un par de claves criptográficas independientes. Las acciones del agente incluyen una segunda firma vinculada a su dueño humano, creando un rastreo o "pasaporte verificable" para la IA.
* **Control de versiones e integración de Git:** Aloja Git de forma nativa. Cada rama de características (*feature branch*) puede convertirse en un canal propio, unificando en el mismo lugar la conversación, los *patches*, resultados de CI y comentarios de revisión.
* **Agente e Infraestructura Agnósticos:** Es compatible con múltiples arneses y modelos (como *Claude Code*, *Codex* de OpenAI o *Goose* de Block) a través del estándar *Agent Client Protocol* (ACP).
* **Propiedad de la infraestructura (Código abierto):** Licencia Apache 2.0. El usuario puede alojar su propio *relay* de Nostr o usar la versión alojada de Block.
* **Memoria y aprendizaje persistente de agentes:** Los agentes recuerdan sus conversaciones dentro de la comunidad y pueden consultar documentación interna para aprender a ejecutar comandos en futuras ocasiones.

### Estrategias y Objetivos

* **Reducir la dependencia de Slack y GitHub:** Combinar en una sola plataforma la comunicación de equipo, la gestión de proyectos, el alojamiento de código y los flujos de trabajo.
* **Colaboración directa Humano + IA:** Crear espacios donde agentes de IA especializados trabajen a la par de los desarrolladores como miembros reales del equipo.
* **Soberanía y propiedad de datos:** Eliminar cuentas tradicionales; la identidad pertenece a la clave criptográfica del usuario y no a la plataforma.
* **Control de consumo de tokens:** Implementar límites estrictos en los agentes para evitar bucles de mensajes continuos que agoten los tokens rápidamente.