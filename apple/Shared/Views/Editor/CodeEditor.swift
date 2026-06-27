import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var triggerSearch: Bool
    @Binding var showLineNumbers: Bool
    let language: String
    let theme: AppTheme
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        
        let contentSize = scrollView.contentSize
        
        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        
        scrollView.documentView = textView
        
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4.0
        textView.defaultParagraphStyle = paragraphStyle
        
        // Habilitar barra de búsqueda (Command+F)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        
        // Agregar espacio interno (Padding)
        textView.textContainerInset = NSSize(width: 24, height: 36)
        textView.textContainer?.lineFragmentPadding = 5
        
        // Auto-foco del cursor al entrar a edición
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        
        // Evitar bucles de actualización y pérdida de cursor
        if textView.string != text {
            textView.string = text
        }
        
        if triggerSearch {
            DispatchQueue.main.async {
                triggerSearch = false
                nsView.window?.makeFirstResponder(textView)
                let item = NSMenuItem(title: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
                item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                textView.performFindPanelAction(item)
            }
        }
        
        // Mostrar / Ocultar Números de Línea dinámicamente
        if showLineNumbers {
            nsView.hasVerticalRuler = true
            nsView.rulersVisible = true
            if !(nsView.verticalRulerView is LineNumberRulerView) {
                let ruler = LineNumberRulerView(textView: textView)
                nsView.verticalRulerView = ruler
            }
            nsView.verticalRulerView?.needsDisplay = true
        } else {
            nsView.rulersVisible = false
            nsView.hasVerticalRuler = false
        }
        
        // Aplicar colores de fondo y base según el tema
        updateColors(textView)
        
        // Disparar resaltado
        context.coordinator.highlight(textView)
    }
    
    private func updateColors(_ textView: NSTextView) {
        let isDark = theme == .dark || (theme == .system && NSApp.effectiveAppearance.name == .darkAqua)
        switch theme {
        case .night:
            textView.backgroundColor = .black
            textView.insertionPointColor = .red
            if let scrollView = textView.enclosingScrollView {
                scrollView.drawsBackground = true
            }
        case .dark, .light, .system:
            if isDark {
                textView.backgroundColor = NSColor(red: 30/255.0, green: 30/255.0, blue: 30/255.0, alpha: 1.0)
                textView.insertionPointColor = .white
                if let scrollView = textView.enclosingScrollView {
                    scrollView.drawsBackground = true
                }
            } else {
                textView.backgroundColor = .clear
                textView.insertionPointColor = .black
                if let scrollView = textView.enclosingScrollView {
                    scrollView.drawsBackground = false
                }
            }
        }
    }
    
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let textView = nsView.documentView as? NSTextView {
            textView.delegate = nil
            textView.undoManager?.removeAllActions(withTarget: textView)
            if let textStorage = textView.layoutManager?.textStorage {
                textView.undoManager?.removeAllActions(withTarget: textStorage)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        
        init(_ parent: CodeEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            if parent.text != newText {
                parent.text = newText
            }
            highlight(textView)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        
        func highlight(_ textView: NSTextView) {
            guard let textStorage = textView.layoutManager?.textStorage else { return }
            let content = textStorage.string
            let fullRange = NSRange(location: 0, length: content.utf16.count)
            
            // 1. Resetear estilo base
            let baseColor: NSColor = {
                switch parent.theme {
                case .night: return NSColor(red: 0.8, green: 0, blue: 0, alpha: 1)
                case .dark: return NSColor(white: 0.9, alpha: 1)
                default: return .textColor
                }
            }()
            
            textStorage.beginEditing()
            textStorage.addAttribute(.foregroundColor, value: baseColor, range: fullRange)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4.0
            textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
            
            // 2. Procesar por patrones (Evitando propagación global)
            let theme = parent.theme
            let isDarkTheme = (theme == .dark || (theme == .system && NSApp.effectiveAppearance.name == .darkAqua))
            let tagColor = theme == .night ? NSColor.orange : (isDarkTheme ? NSColor.systemOrange : NSColor.systemBlue)
            let headerColor = theme == .night ? NSColor.red : (isDarkTheme ? NSColor.systemBlue : NSColor.systemIndigo)
            
            if parent.language == "html" {
                // HTML: Resaltar etiquetas <...>
                applyRegex(to: textStorage, pattern: "<[^>]+>", color: tagColor)
            } else {
                // MARKDOWN: Procesamiento Robusto
                
                // Títulos: Solo si empiezan con # al inicio de línea
                // Usamos [^\\n] para asegurar que no se pase de la línea
                applyRegex(to: textStorage, pattern: "^#+[^\\n]*", color: headerColor)
                
                // Enlaces: [[...]] o [...]()
                applyRegex(to: textStorage, pattern: "\\[\\[.*?\\]\\]", color: tagColor)
                applyRegex(to: textStorage, pattern: "\\[.*?\\]\\(.*?\\)", color: tagColor)
                
                // Negritas/Cursivas (Simple)
                let emphColor = theme == .night ? NSColor.magenta : (isDarkTheme ? NSColor.systemPink : NSColor.systemGray)
                applyRegex(to: textStorage, pattern: "\\*\\*.*?\\*\\*|__.*?__", color: emphColor)
                
                // Listas
                let listColor = theme == .night ? NSColor.yellow : (isDarkTheme ? NSColor.systemYellow : NSColor.systemGreen)
                applyRegex(to: textStorage, pattern: "^[\\t ]*(?:[-*+]|\\d+\\.)[\\t ]", color: listColor)
                
                // Tareas
                let taskColor = theme == .night ? NSColor.green : (isDarkTheme ? NSColor.systemGreen : NSColor.systemTeal)
                applyRegex(to: textStorage, pattern: "^[\\t ]*[-*+][\\t ]+\\[[ xX]\\]", color: taskColor)
                
                // Citas / Blockquotes
                let quoteColor = theme == .night ? NSColor.brown : (theme == .dark ? NSColor.systemGray : NSColor.gray)
                applyRegex(to: textStorage, pattern: "^[\\t ]*>[^\\n]*", color: quoteColor)
                
                // Código en línea
                let inlineCodeColor = theme == .night ? NSColor.cyan : (theme == .dark ? NSColor.systemCyan : NSColor.systemPurple)
                applyRegex(to: textStorage, pattern: "`[^`\\n]+`", color: inlineCodeColor)
                
                // Bloques de código (multilínea)
                let codeBlockColor = theme == .night ? NSColor.cyan : (theme == .dark ? NSColor.systemCyan : NSColor.systemPurple)
                applyRegex(to: textStorage, pattern: "(?s)```.*?```", color: codeBlockColor)
            }
            
            textStorage.endEditing()
        }
        
        private func applyRegex(to textStorage: NSTextStorage, pattern: String, color: NSColor) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let matches = regex.matches(in: textStorage.string, options: [], range: NSRange(location: 0, length: textStorage.string.utf16.count))
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange).lowercased()
            if parent.language == "html" {
                let tags = ["video", "audio", "div", "span", "img", "a href", "script", "style", "table", "h1", "h2"]
                return tags.filter { $0.hasPrefix(partial) }
            } else {
                let md = ["[[", "[ ]", "[x]", "link", "bold", "code"]
                return md.filter { $0.hasPrefix(partial) }
            }
        }
    }
}

// MARK: - EditorTextView Subclass for Keyboard Interception

class EditorTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "l" {
            selectCurrentLineOrLines()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    
    private func selectCurrentLineOrLines() {
        let contentString = self.string as NSString
        if contentString.length == 0 { return }
        
        let selectedRange = self.selectedRange()
        
        // Encontrar el inicio de la línea del comienzo de la selección
        let lineStart = contentString.lineRange(for: NSRange(location: selectedRange.location, length: 0)).location
        
        // Encontrar el final de la línea del final de la selección
        let endLoc = max(0, NSMaxRange(selectedRange) - (selectedRange.length > 0 ? 1 : 0))
        let lineEnd = contentString.lineRange(for: NSRange(location: endLoc, length: 0)).upperBound
        
        self.setSelectedRange(NSRange(location: lineStart, length: lineEnd - lineStart))
    }
}

// MARK: - LineNumberRulerView Subclass for Drawing Line Numbers

class LineNumberRulerView: NSRulerView {
    private var textView: NSTextView? {
        return clientView as? NSTextView
    }
    
    override var isFlipped: Bool {
        return true
    }
    
    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 45
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        
        let contentString = textView.string as NSString
        let textContainerOrigin = textView.textContainerOrigin
        
        let isDark = NSApp.effectiveAppearance.name == .darkAqua
        let numberColor = isDark ? NSColor.lightGray.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.5)
        let rulerBackgroundColor = textView.backgroundColor
        
        rulerBackgroundColor.setFill()
        bounds.fill()
        
        let separatorColor = isDark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.08)
        separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.width - 0.5, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.maxY))
        path.lineWidth = 1.0
        path.stroke()
        
        let visibleRect = scrollView?.contentView.documentVisibleRect ?? .zero
        
        // Ajustar el visibleRect al espacio de coordenadas del container
        var containerVisibleRect = visibleRect
        containerVisibleRect.origin.x = max(0, visibleRect.origin.x - textContainerOrigin.x)
        containerVisibleRect.origin.y = max(0, visibleRect.origin.y - textContainerOrigin.y)
        
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerVisibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        
        var lineNumber = 1
        var charIndex = 0
        
        while charIndex < visibleCharRange.location {
            charIndex = contentString.lineRange(for: NSRange(location: charIndex, length: 0)).upperBound
            lineNumber += 1
        }
        
        charIndex = visibleCharRange.location
        
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = contentString.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            
            // Sumar el origen del contenedor antes de convertir las coordenadas a la regla
            var actualPoint = rect.origin
            actualPoint.x += textContainerOrigin.x
            actualPoint.y += textContainerOrigin.y
            
            let viewPoint = textView.convert(actualPoint, to: self)
            
            let label = "\(lineNumber)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: numberColor
            ]
            
            let labelSize = label.size(withAttributes: attributes)
            let labelX = bounds.width - labelSize.width - 8
            let labelY = viewPoint.y + (rect.height - labelSize.height) / 2 - 1.5
            
            label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attributes)
            
            charIndex = lineRange.upperBound
            lineNumber += 1
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        
        let location = convert(event.locationInWindow, from: nil)
        let visibleRect = scrollView?.contentView.documentVisibleRect ?? .zero
        let contentString = textView.string as NSString
        let textContainerOrigin = textView.textContainerOrigin
        
        var containerVisibleRect = visibleRect
        containerVisibleRect.origin.x = max(0, visibleRect.origin.x - textContainerOrigin.x)
        containerVisibleRect.origin.y = max(0, visibleRect.origin.y - textContainerOrigin.y)
        
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerVisibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        
        var charIndex = visibleCharRange.location
        var matchedRange: NSRange? = nil
        
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = contentString.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            
            var actualPoint = rect.origin
            actualPoint.x += textContainerOrigin.x
            actualPoint.y += textContainerOrigin.y
            
            let viewPoint = textView.convert(actualPoint, to: self)
            
            if location.y >= viewPoint.y && location.y <= viewPoint.y + rect.height {
                matchedRange = lineRange
                break
            }
            charIndex = lineRange.upperBound
        }
        
        if let targetRange = matchedRange {
            let extendSelection = event.modifierFlags.contains(.shift)
            
            if extendSelection {
                let currentSelectedRange = textView.selectedRange()
                let start = min(currentSelectedRange.location, targetRange.location)
                let end = max(NSMaxRange(currentSelectedRange), NSMaxRange(targetRange))
                textView.setSelectedRange(NSRange(location: start, length: end - start))
            } else {
                textView.setSelectedRange(targetRange)
            }
        }
    }
}
