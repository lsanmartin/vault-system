# Reporte Arquitectura Vault-System

## Arquitectura (7 Capas)

### L1: Implementar binario Rust nativo
- Ejecutar código compilado localmente.
- Maximizar rendimiento uso CPU.
- Evitar dependencias nube externa.

### L1: Controlar acceso archivos UMA
- Implementar User-Managed Access estricto.
- Validar permisos cada lectura.
- Restringir acceso carpetas no-autorizadas.

### L2: Operar motor base DuckDB
- Transformar archivos planos analíticamente.
- Ejecutar consultas SQL complejas.
- Indexar contenido Markdown rápidamente.

### L3/L4: Abstraer modelos mediante MCP
- Integrar Model Context Protocol.
- Estandarizar comunicación IA local.
- Soportar múltiples proveedores intercambiables.

### L5: Sistematizar memoria conversacional estructurada
- Mantener archivo _memory.md actualizado.
- Persistir contexto entre sesiones.
- Dotar agentes memoria temporal.

### L6: Orquestar herramientas subagentes locales
- Coordinar múltiples agentes simultáneamente.
- Ejecutar scripts locales automáticamente.
- Construir grafo orquestación tareas.

### L7: Renderizar interfaz nativa SwiftUI
- Proveer UI fluida macOS.
- Integrar App Intents sistema.
- Minimizar consumo recursos visuales.

## Protocolos

### Operar Model Context Protocol (MCP)
- Estandarizar conexión LLM herramientas.
- Usar formato JSON-RPC seguro.
- Exponer capacidades sistema ordenadamente.

### Aplicar control acceso roles (RBAC)
- Asignar permisos específicos demonio.
- Restringir operaciones según nivel.
- Bloquear accesos escalados ilegítimos.

### Comunicar procesos IPC puente FFI
- Conectar frontend Swift backend.
- Pasar datos memoria eficientemente.
- Eliminar latencia red interna.

### Normalizar texto Unicode memoria Rust
- Soportar carácteres especiales NFD/NFC.
- Resolver bugs Finder macOS.
- Asegurar consistencia búsquedas acentos.

## Funciones Seguridad (Core)

### Aislar workspaces mediante tokens
- Generar tokens cliente únicos.
- Validar rutas contra workspaces.
- Prevenir lecturas globales sistema.

### Bloquear vulnerabilidad path-traversal
- Limpiar rutas absolutas dinámicamente.
- Impedir uso carácteres escapado.
- Restringir navegación fuera directorio.

### Neutralizar enlaces simbólicos dinámicamente
- Resolver rutas canonicalize Rust.
- Evaluar destino final archivo.
- Impedir escapes workspace silenciosos.

### Mitigar ataques DoS
- Bloquear lectura FIFOs pipes.
- Prevenir cuelgues lectura infinitos.
- Mantener estabilidad sistema host.

### Limitar carga máxima JSON-RPC
- Establecer límite estricto 5MB.
- Prevenir consumo memoria excesivo.
- Evitar colapsos Out-Of-Memory OOM.

### Filtrar metadatos privados dinámicamente
- Ocultar archivos sistema metadata.
- Aplicar cláusulas exclusión SQL.
- Proteger Lore agentes internos.

## Funciones Operativas (UI/App)

### Ejecutar búsquedas semánticas DuckDB
- Buscar texto alta velocidad.
- Filtrar resultados formato tabular.
- Apoyar consultas complejas IA.

### Intersectar términos búsqueda estructurada
- Dividir frases múltiples tokens.
- Exigir presencia término individual.
- Emular motores búsqueda avanzados.

### Renderizar formato universal Markdown/HTML
- Procesar lenguajes marcado automáticamente.
- Soportar expresiones matemáticas LaTeX.
- Mostrar contenido UI nativa.

### Visualizar telemetría panel nativo
- Mostrar logs tiempo real.
- Auditar acciones agentes IA.
- Facilitar depuración errores sistema.

### Buscar texto directo WebView
- Buscar cadenas vista actual.
- Usar inyección JavaScript custom.
- Navegar resultados UI local.

### Persistir contexto archivos _memory.md
- Guardar hitos sesión actual.
- Recuperar historial tareas previas.
- Mantener continuidad flujo trabajo.
