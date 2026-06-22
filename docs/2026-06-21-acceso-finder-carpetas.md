# 2026-06-21 - Acceso a Finder, Alineación de Chevrons, Pines, Sincronización del Tema y Ajustes de Padding y Foco de Notas

## Análisis y Estrategia
- **Problema 1**: El usuario requiere abrir directamente cualquier carpeta desde la aplicación en Finder para facilitar la gestión de archivos nativos en macOS.
- **Problema 2**: Los chevrons del árbol del Sidebar se mostraban alineados al borde izquierdo sin importar su profundidad, causando confusión visual.
- **Problema 3**: El usuario necesita la capacidad de fijar (pin) carpetas y notas clave para mantenerlas siempre en la parte superior de la lista y del árbol jerárquico.
- **Problema 4**: Al seleccionar el tema "Sistema", la aplicación no restauraba correctamente el aspecto del sistema macOS si se había seleccionado Claro u Oscuro previamente debido a un bug de preferredColorScheme de SwiftUI en macOS.
- **Problema 5**: El padding de visualización y edición en notas se sentía muy ajustado. Asimismo, al alternar al modo de edición, el usuario debía hacer clic en la nota para empezar a escribir, lo que interrumpía el flujo.
- **Estrategia**: 
  - Añadir una opción en el menú contextual (`VaultContextMenu` y `NoteCard`) y un botón directo en el encabezado principal de la lista de notas.
  - Mover el modificador `.padding(.leading)` del contenedor interno de la fila al contenedor externo en `VaultTreeRow`.
  - Crear una colección `pinnedPaths` en `EditorViewModel` persistida mediante `UserDefaults` y ordenar todos los listados priorizando los elementos fijados.
  - Sincronizar dinámicamente el tema usando la API nativa de AppKit `NSApp.appearance`, asignando `nil` para modo Sistema y forzando `.darkAqua` o `.aqua` cuando es necesario. Persistir el tema en `UserDefaults` usando la clave `vault_selected_theme`.
  - Incrementar el padding de la vista HTML (`body padding`) a `4.5rem` (72px) y del editor a `60px` (modificando `textContainerInset`). Asignar el foco (`makeFirstResponder`) al `NSTextView` de forma asíncrona al instanciar `CodeEditor`.

## Decisiones Técnicas
- **Caminos tomados**:
  - Uso de `NSWorkspace.shared.open(URL)` para carpetas.
  - Uso de `NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")` para notas individuales (revela en Finder y resalta el archivo).
  - Añadido botón con icono de carpeta en el header junto al título de la ruta actual para abrir la ubicación en Finder.
  - Corregida la indentación de los chevrons moviendo `.padding(.leading, CGFloat(depth * 16))` del `HStack` interno al `HStack` externo en `VaultTreeRow`.
  - Implementación de `togglePin` que persiste un arreglo de rutas fijadas usando `UserDefaults` con la clave `vault_pinned_paths`.
  - Modificación de la función de ordenamiento en `updateGridForCurrentPath`, `rootItems` y `children` para priorizar los elementos contenidos in `pinnedPaths`.
  - Renderizado de un icono `pin.fill` de color naranja junto al título de cada elemento fijado en todas las vistas de listados (`VaultTreeRow`, `FileRowView` y `NoteCard`).
  - Implementación de `updateAppAppearance()` en `EditorViewModel` que cambia la apariencia global mediante `NSApp.appearance = NSAppearance(named: ...)` para anular y restaurar dinámicamente el modo de sistema macOS.
  - Incremento del padding general de lectura a `4.5rem` (+40px sobre el original) e incremento de `textContainerInset` en `CodeEditor.swift` a `NSSize(width: 60, height: 60)`.
  - Inyección de una llamada a `window?.makeFirstResponder(textView)` dentro de `DispatchQueue.main.async` al construir el `NSView` en `CodeEditor.swift` para que el cursor de texto aparezca enfocado inmediatamente al abrir el editor.
- **Alternativas descartadas**:
  - *Guardar pins en base de datos*: Descartado por requerir migraciones complejas de esquema en DuckDB e incremento de acoplamiento FFI de Rust innecesariamente.

## Próximos Pasos
- Validar comportamiento al tener workspaces remotos o en ubicaciones sin permisos (iCloud Drive sandbox).
- Ajustar si el usuario requiere soporte para arrastrar y soltar carpetas a otras aplicaciones directamente.
