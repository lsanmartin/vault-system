# Análisis de Seguridad: Entorno Nativo y Core Rust (vault-system)

He realizado una revisión focalizada de los vectores de seguridad para la aplicación nativa `vault-system`, considerando su arquitectura dual (macOS SwiftUI + Rust Core FFI) y su acceso al sistema de archivos local.

## 🟠 ALTA

### 1. Inyección de Código en el Renderizador Universal (XSS / Escapes)
* **Ubicación:** Capa de Renderizado en SwiftUI (`MainEditorView.swift` / Procesador LaTeX y HTML)
* **Descripción:** La aplicación detecta dinámicamente HTML y procesa LaTeX + Markdown. El uso de raw strings (`##""" ... """##`) protege el código fuente Swift, pero si la nota del usuario contiene inyecciones de JavaScript (ej. etiquetas `<script>` dentro del bloque HTML) y estas son renderizadas en un `WKWebView` o componente web embebido sin restricciones.
* **Vector de Ataque:** Si el usuario importa un `.md` de origen externo, el visor podría ejecutar código arbitrario en el contexto del Sandbox de la App.
* **Recomendación:** Forzar que la configuración del WebKit o motor de renderizado deshabilite la ejecución de JavaScript (`javaScriptEnabled = false`) para las vistas estáticas, o aplicar una estricta Content Security Policy (CSP) local.

### 2. File System Traversal / Path Limits
* **Ubicación:** `core/src/lib.rs` (Función `scan_vault`)
* **Descripción:** El sistema utiliza `WalkDir::new(vault_path)` para indexar recursivamente los directorios.
* **Vector de Ataque:** No hay mecanismos explícitos en el código Rust analizado para mitigar enlaces simbólicos maliciosos (Symlink loops) que puedan causar un *Denial of Service* (Memory/Stack Exhaustion) durante el escaneo. Un atacante (o un error del usuario al crear symlinks infinitos en su disco) colgaría el proceso de Rust, arrastrando a la aplicación macOS entera dado el lazo sincrónico FFI.
* **Recomendación:** Configurar `WalkDir` explícitamente para no seguir symlinks, o imponer una profundidad máxima de recursión (ej. `max_depth(15)`).

---

## 🟡 MEDIA

### 3. Exposición de Datos en Memoria Volátil
* **Ubicación:** `core/src/lib.rs` (`Connection::open_in_memory()`)
* **Descripción:** La base de datos DuckDB es instanciada en memoria. Las notas, que pueden contener información altamente sensible, y sus incrustaciones semánticas viven en el heap de la aplicación.
* **Evaluación:** Dado que macOS gestiona la swap al disco (Virtual Memory) en texto plano, partes de este contenido podrían filtrarse temporalmente al disco físico del Mac en estado de suspensión o baja memoria.
* **Recomendación:** Para un producto calificado como "Knowledge OS", evaluar en el futuro el cifrado de datos at-rest (Data-at-Rest Encryption) si la base de datos DuckDB migra de RAM a almacenamiento persistente.

---

## 🔵 INFORMATIVA

### 4. Robustez FFI (Foreign Function Interface)
* El uso de **UniFFI** es una excelente decisión de ingeniería de seguridad. A diferencia del uso crudo de punteros C (C-ABI) o serialización JSON lenta, UniFFI garantiza que el contrato de tipos de datos entre Swift y Rust sea verificado en tiempo de compilación. Elimina casi por completo las vulnerabilidades de desbordamiento de búfer (*Buffer Overflow*) y corrupciones de memoria en la barrera entre la UI y el Core.
