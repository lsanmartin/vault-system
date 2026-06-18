# Plan de Mejora Arquitectura Vault-System

## 1. Formalización L5: Schema _memory.md (Prioridad Alta)
- Objetivo: Estructurar contexto persistente.
- Acción: Definir formato YAML Frontmatter estandarizado.
- Acción: Separar secciones: Hitos, Contexto, Historial.
- Acción: Crear parser DuckDB extrayendo columnas.
- Resultado: Habilitar consultas SQL estado temporal.

## 2. Refactorización L6: Coordinación Subagentes (Prioridad Alta)
- Objetivo: Establecer protocolo comunicación interna.
- Acción: Implementar Message Bus local `tokio::mpsc`.
- Acción: Definir tipado mensajes unificado.
- Acción: Aislar contextos memoria subagente.
- Resultado: Eliminar colisiones ejecuciones paralelas.

## 3. Implementación Routing Híbrido (Prioridad Media)
- Objetivo: Decidir motor IA dinámicamente.
- Acción: Programar capa routing evaluando reglas.
- Acción: Forzar ejecución local datos privados.
- Acción: Derivar consultas masivas API externa.
- Resultado: Optimizar consumo recursos latencia.

## 4. Definición Matriz RBAC (Prioridad Media)
- Objetivo: Consolidar roles acceso sistema.
- Acción: Codificar roles: reader, writer, executor, admin.
- Acción: Limitar scopes subagentes dinámicamente.
- Acción: Vincular roles validación UMA L1.
- Resultado: Evitar escalamiento privilegios subagentes.
