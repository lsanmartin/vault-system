# 2026-06-27 - Números de Línea y Selección Avanzada en Editor

## Análisis y Estrategia
Se implementaron números de línea minimalistas y atajos avanzados de selección en el editor de código de `vault-system`. Esta mejora incrementa la ergonomía de edición permitiendo referenciar y seleccionar líneas de forma fluida.

## Decisiones Técnicas
- **Regla de Números de Línea en AppKit**: Se desarrolló la subclase `LineNumberRulerView` de `NSRulerView` para dibujar dinámicamente los números de línea correspondientes a las líneas visibles del `NSTextView`. El ancho de la regla se fijó en 45pt, ofreciendo un soporte holgado para notas de miles de líneas.
- **Ajustes Visuales Premium**:
  - **Fondo Transparente en Canal**: Se modificó `LineNumberRulerView.drawHashMarksAndLabels` para rellenar la regla utilizando exactamente el color de fondo del editor (`textView.backgroundColor`), eliminando cualquier color de fondo alternativo o divisorio brusco para un look completamente integrado y limpio.
  - **Padding Superior**: Se modificó el `textContainerInset` a `NSSize(width: 24, height: 36)`, agregando una holgura superior de 36pt que evita que el texto y los números queden pegados al borde de la ventana.
- **Preferencia por Nota**:
  - El estado de visualización se almacena de forma independiente para cada nota en `UserDefaults` utilizando la clave `vault_show_line_numbers_\(tabId)`.
  - Por defecto, los números de línea están desactivados al abrir una nota nueva o no configurada previamente.
- **Intercepción de Click Secundario y Shift + Click en Regla**:
  - Click normal en el canal (gutter): Selecciona toda la línea clicada.
  - `Shift + Click` en el canal: Extiende la selección del cursor actual para abarcar todas las líneas intermedias hasta la línea clicada.
- **Subclase EditorTextView**: Se implementó una subclase personalizada de `NSTextView` para interceptar comandos de teclado.
  - `Cmd + L`: Expande la selección para cubrir las líneas completas seleccionadas en ese momento.
- **Toggle en Cabecera**: Se añadió un botón con icono `list.number` en `MainEditorView` para activar/desactivar los números de línea, guardando el estado en `UserDefaults` para recordar la preferencia del usuario entre sesiones y notas.

## Próximos Pasos
- Validar el comportamiento de los números de línea al alternar entre diferentes fuentes del sistema y tamaños de letra dinámicos.
