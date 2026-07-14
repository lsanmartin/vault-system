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
        context.coordinator.parent = self
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
    private var _customSelectedRanges: [NSValue]? = nil
    private var _isApplyingCustomSelection = false
    
    override var selectedRanges: [NSValue] {
        get {
            return _customSelectedRanges ?? super.selectedRanges
        }
        set {
            let hasMultipleEmpty = newValue.filter { $0.rangeValue.length == 0 }.count > 1
            if hasMultipleEmpty {
                _customSelectedRanges = newValue
                _isApplyingCustomSelection = true
                super.selectedRanges = [newValue.first!]
                _isApplyingCustomSelection = false
            } else {
                _customSelectedRanges = nil
                super.selectedRanges = newValue
            }
            self.setNeedsDisplay(self.bounds)
        }
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers ?? ""
        let keyCode = event.keyCode
        
        // Cmd+Z: Undo
        if modifiers == .command && chars.lowercased() == "z" {
            if let undoManager = self.undoManager, undoManager.canUndo {
                undoManager.undo()
                return true
            }
        }
        
        // Cmd+Shift+Z: Redo
        if modifiers == [.command, .shift] && chars.lowercased() == "z" {
            if let undoManager = self.undoManager, undoManager.canRedo {
                undoManager.redo()
                return true
            }
        }
        
        // Cmd + Shift + L: Seleccionar todas las coincidencias
        if modifiers == [.command, .shift] && chars.lowercased() == "l" {
            selectAllOccurrences()
            return true
        }
        
        // Cmd + L: Seleccionar línea actual
        if modifiers == .command && chars == "l" {
            selectCurrentLineOrLines()
            return true
        }
        
        // Cmd+Shift+K: Borrar línea
        if modifiers == [.command, .shift] && chars.lowercased() == "k" {
            deleteCurrentLineOrLines()
            return true
        }
        
        // Option + Up: Mover línea arriba
        if modifiers == .option && keyCode == 126 {
            moveLines(up: true)
            return true
        }
        
        // Option + Down: Mover línea abajo
        if modifiers == .option && keyCode == 125 {
            moveLines(up: false)
            return true
        }
        
        // Shift + Option + Up: Duplicar línea arriba
        if modifiers == [.shift, .option] && keyCode == 126 {
            duplicateLines(up: true)
            return true
        }
        
        // Shift + Option + Down: Duplicar línea abajo
        if modifiers == [.shift, .option] && keyCode == 125 {
            duplicateLines(up: false)
            return true
        }
        
        // Cmd + U: Uppercase
        if modifiers == .command && chars == "u" {
            transformSelection(toUpper: true)
            return true
        }
        
        // Cmd + Shift + U: Lowercase
        if modifiers == [.command, .shift] && chars.lowercased() == "u" {
            transformSelection(toUpper: false)
            return true
        }
        
        // Cmd + /: Comentar / Descomentar
        let exactChars = event.characters ?? ""
        if modifiers.contains(.command) && (chars == "/" || exactChars == "/") {
            toggleComment()
            return true
        }
        
        // Cmd + D: Seleccionar siguiente coincidencia
        if modifiers.contains(.command) && chars.lowercased() == "d" {
            selectNextOccurrence()
            return true
        }
        
        return super.performKeyEquivalent(with: event)
    }
    
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        
        // Dibujar múltiples cursores porque NSTextView solo dibuja el principal
        if self.selectedRanges.count > 1 {
            guard let layoutManager = self.layoutManager, let textContainer = self.textContainer else { return }
            NSColor.labelColor.setFill()
            for (index, value) in self.selectedRanges.enumerated() {
                if index == 0 { continue } // El principal lo dibuja el sistema
                let range = value.rangeValue
                if range.length == 0 {
                    let loc = max(0, min(range.location, (self.string as NSString).length - 1))
                    if loc >= 0 && (self.string as NSString).length > 0 {
                        let glyphIndex = layoutManager.glyphIndexForCharacter(at: loc)
                        var caretRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
                        caretRect.origin.x += self.textContainerOrigin.x
                        caretRect.origin.y += self.textContainerOrigin.y
                        caretRect.size.width = 1.5
                        
                        if range.location > loc {
                            caretRect.origin.x += 8.0 // Approx char width advance if at very end
                        }
                        
                        caretRect.fill()
                    }
                }
            }
        }
    }
    

    
    private func applyTextChange(in range: NSRange, with newText: String) -> Bool {
        _isApplyingCustomSelection = true
        super.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: false)
        _isApplyingCustomSelection = false
        
        if shouldChangeText(in: range, replacementString: newText) {
            replaceCharacters(in: range, with: newText)
            didChangeText()
            return true
        }
        return false
    }
    
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let insertStr = string as? String else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        
        let contentString = self.string as NSString
        let pairs: [String: String] = ["{": "}", "[": "]", "(": ")", "\"": "\"", "'": "'", "<": ">"]
        
        if self.selectedRanges.count > 1 {
            let ranges = self.selectedRanges.map { $0.rangeValue }.sorted(by: { $0.location > $1.location })
            
            var newRanges = [NSValue]()
            
            for range in ranges {
                if let closing = pairs[insertStr] {
                    if range.length > 0 {
                        let selectedText = contentString.substring(with: range)
                        let newText = insertStr + selectedText + closing
                        if applyTextChange(in: range, with: newText) {
                            newRanges.append(NSValue(range: NSRange(location: range.location + 1, length: range.length)))
                        } else {
                            newRanges.append(NSValue(range: range))
                        }
                    } else {
                        if applyTextChange(in: range, with: insertStr + closing) {
                            newRanges.append(NSValue(range: NSRange(location: range.location + 1, length: 0)))
                        } else {
                            newRanges.append(NSValue(range: range))
                        }
                    }
                } else {
                    if applyTextChange(in: range, with: insertStr) {
                        newRanges.append(NSValue(range: NSRange(location: range.location + insertStr.utf16.count, length: 0)))
                    } else {
                        newRanges.append(NSValue(range: range))
                    }
                }
            }
            self.selectedRanges = newRanges.reversed()
            return
        }
        
        let selectedRange = self.selectedRange()
        
        // --- 1. Auto-closing & Wrapping (Single Cursor) ---
        if let closing = pairs[insertStr] {
            if selectedRange.length > 0 {
                let selectedText = contentString.substring(with: selectedRange)
                let newText = insertStr + selectedText + closing
                
                if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
                if shouldChangeText(in: selectedRange, replacementString: newText) {
                    replaceCharacters(in: selectedRange, with: newText)
                    didChangeText()
                    self.setSelectedRange(NSRange(location: selectedRange.location + 1, length: selectedRange.length))
                }
                if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
                return
            } else {
                super.insertText(insertStr + closing, replacementRange: replacementRange)
                let newLocation = self.selectedRange().location - 1
                self.setSelectedRange(NSRange(location: newLocation, length: 0))
                return
            }
        }
        
        // --- 2. Smart Enter (Continuación de Listas) ---
        if insertStr == "\n" {
            let lineRange = contentString.lineRange(for: NSRange(location: max(0, selectedRange.location - 1), length: 0))
            let currentLine = contentString.substring(with: lineRange)
            
            let pattern = "^(\\s*)([-*]|\\d+\\.)\\s"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                
                let prefixRange = match.range
                let prefix = (currentLine as NSString).substring(with: prefixRange)
                let contentAfterPrefix = (currentLine as NSString).substring(from: prefixRange.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
                
                if contentAfterPrefix.isEmpty {
                    // Double enter: remove prefix
                    let replacementRange = NSRange(location: lineRange.location, length: lineRange.length)
                    if shouldChangeText(in: replacementRange, replacementString: "\n") {
                        replaceCharacters(in: replacementRange, with: "\n")
                        didChangeText()
                    }
                } else {
                    // Continue list
                    var nextPrefix = prefix
                    if let numberMatch = try? NSRegularExpression(pattern: "\\d+").firstMatch(in: prefix, range: NSRange(location: 0, length: prefix.utf16.count)) {
                        let numberStr = (prefix as NSString).substring(with: numberMatch.range)
                        if let number = Int(numberStr) {
                            nextPrefix = prefix.replacingOccurrences(of: numberStr + ".", with: "\(number + 1).")
                        }
                    }
                    super.insertText("\n" + nextPrefix, replacementRange: replacementRange)
                }
                
                if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
                return
            }
        }
        
        super.insertText(string, replacementRange: replacementRange)
    }
    
    private func toggleComment() {
        let contentString = self.string as NSString
        guard contentString.length > 0 else { return }
        
        let selectedRange = self.selectedRange()
        let lineRange = contentString.lineRange(for: selectedRange)
        var text = contentString.substring(with: lineRange)
        
        let isCommented = (text.hasPrefix("<!--") && text.hasSuffix("-->\n")) || (text.hasPrefix("<!--") && text.hasSuffix("-->"))
        
        if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
        
        if isCommented {
            text = text.replacingOccurrences(of: "<!--", with: "", options: [], range: text.startIndex..<text.index(text.startIndex, offsetBy: 4))
            
            if text.hasSuffix("-->\n") {
                text = text.replacingOccurrences(of: "-->\n", with: "\n", options: [.backwards], range: text.index(text.endIndex, offsetBy: -4)..<text.endIndex)
            } else if text.hasSuffix("-->") {
                text = text.replacingOccurrences(of: "-->", with: "", options: [.backwards], range: text.index(text.endIndex, offsetBy: -3)..<text.endIndex)
            }
            
            if shouldChangeText(in: lineRange, replacementString: text) {
                replaceCharacters(in: lineRange, with: text)
                didChangeText()
            }
        } else {
            let hasNewline = text.hasSuffix("\n")
            if hasNewline {
                text.removeLast()
                text = "<!--" + text + "-->\n"
            } else {
                text = "<!--" + text + "-->"
            }
            if shouldChangeText(in: lineRange, replacementString: text) {
                replaceCharacters(in: lineRange, with: text)
                didChangeText()
            }
        }
        
        if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
    }
    
    override func insertTab(_ sender: Any?) {
        let selectedRange = self.selectedRange()
        let contentString = self.string as NSString
        let lineRange = contentString.lineRange(for: selectedRange)
        
        if selectedRange.length > 0 && lineRange.length > 0 && contentString.substring(with: lineRange).contains("\n") {
            indentSelection(outdent: false)
        } else {
            super.insertTab(sender)
        }
    }
    
    override func insertBacktab(_ sender: Any?) {
        indentSelection(outdent: true)
    }

    private func indentSelection(outdent: Bool) {
        let selectedRange = self.selectedRange()
        let contentString = self.string as NSString
        let lineRange = contentString.lineRange(for: selectedRange)
        
        let lines = contentString.substring(with: lineRange).components(separatedBy: .newlines)
        var newText = ""
        
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 && line.isEmpty {
                if contentString.substring(with: lineRange).hasSuffix("\n") {
                    break
                }
            }
            
            if outdent {
                if line.hasPrefix("    ") {
                    newText += line.dropFirst(4) + "\n"
                } else if line.hasPrefix("\t") {
                    newText += line.dropFirst(1) + "\n"
                } else {
                    newText += line + "\n"
                }
            } else {
                newText += "    " + line + "\n"
            }
        }
        
        if newText.hasSuffix("\n") && !contentString.substring(with: lineRange).hasSuffix("\n") {
            newText.removeLast()
        }
        
        if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
        if shouldChangeText(in: lineRange, replacementString: newText) {
            replaceCharacters(in: lineRange, with: newText)
            didChangeText()
            self.setSelectedRange(NSRange(location: lineRange.location, length: (newText as NSString).length))
        }
        if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
    }
    
    private func transformSelection(toUpper: Bool) {
        let selectedRange = self.selectedRange()
        guard selectedRange.length > 0 else { return }
        let contentString = self.string as NSString
        let currentText = contentString.substring(with: selectedRange)
        let newText = toUpper ? currentText.uppercased() : currentText.lowercased()
        
        if shouldChangeText(in: selectedRange, replacementString: newText) {
            replaceCharacters(in: selectedRange, with: newText)
            didChangeText()
            self.setSelectedRange(selectedRange)
        }
    }
    
    private func deleteCurrentLineOrLines() {
        let contentString = self.string as NSString
        guard contentString.length > 0 else { return }
        let selectedRange = self.selectedRange()
        let lineRange = contentString.lineRange(for: selectedRange)
        
        if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
        if shouldChangeText(in: lineRange, replacementString: "") {
            replaceCharacters(in: lineRange, with: "")
            didChangeText()
        }
        if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
    }
    
    private func duplicateLines(up: Bool) {
        let contentString = self.string as NSString
        guard contentString.length > 0 else { return }
        
        let selectedRange = self.selectedRange()
        let lineRange = contentString.lineRange(for: selectedRange)
        
        var textToDuplicate = contentString.substring(with: lineRange)
        let needsNewline = !textToDuplicate.hasSuffix("\n")
        if needsNewline {
            textToDuplicate += "\n"
        }
        
        let insertLocation = up ? lineRange.location : NSMaxRange(lineRange)
        var replacement = textToDuplicate
        if up && needsNewline {
            replacement = "\n" + contentString.substring(with: lineRange)
        }
        
        if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
        
        let insertRange = NSRange(location: insertLocation, length: 0)
        
        if shouldChangeText(in: insertRange, replacementString: replacement) {
            replaceCharacters(in: insertRange, with: replacement)
            didChangeText()
            
            if up {
                self.setSelectedRange(NSRange(location: lineRange.location, length: selectedRange.length))
            } else {
                self.setSelectedRange(NSRange(location: lineRange.location + (replacement as NSString).length, length: selectedRange.length))
            }
        }
        
        if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
    }
    
    private func moveLines(up: Bool) {
        let contentString = self.string as NSString
        guard contentString.length > 0 else { return }
        
        let selectedRange = self.selectedRange()
        let lineRange = contentString.lineRange(for: selectedRange)
        
        if up {
            if lineRange.location == 0 { return }
            let prevLineRange = contentString.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            
            let totalRange = NSRange(location: prevLineRange.location, length: NSMaxRange(lineRange) - prevLineRange.location)
            var text1 = contentString.substring(with: prevLineRange)
            var text2 = contentString.substring(with: lineRange)
            
            if !text2.hasSuffix("\n") {
                text2 += "\n"
                if text1.hasSuffix("\n") { text1.removeLast() }
            }
            
            let newText = text2 + text1
            
            if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
            if shouldChangeText(in: totalRange, replacementString: newText) {
                replaceCharacters(in: totalRange, with: newText)
                didChangeText()
                self.setSelectedRange(NSRange(location: prevLineRange.location, length: selectedRange.length))
            }
            if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
            
        } else {
            if NSMaxRange(lineRange) >= contentString.length { return }
            let nextLineRange = contentString.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0))
            
            let totalRange = NSRange(location: lineRange.location, length: NSMaxRange(nextLineRange) - lineRange.location)
            var text1 = contentString.substring(with: lineRange)
            var text2 = contentString.substring(with: nextLineRange)
            
            if !text1.hasSuffix("\n") {
                text1 += "\n"
                if text2.hasSuffix("\n") { text2.removeLast() }
            }
            
            let newText = text2 + text1
            
            if undoManager?.groupingLevel == 0 { undoManager?.beginUndoGrouping() }
            if shouldChangeText(in: totalRange, replacementString: newText) {
                replaceCharacters(in: totalRange, with: newText)
                didChangeText()
                self.setSelectedRange(NSRange(location: lineRange.location + (text2 as NSString).length, length: selectedRange.length))
            }
            if undoManager?.groupingLevel == 1 { undoManager?.endUndoGrouping() }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if _isApplyingCustomSelection {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            return
        }
        
        let hasMultipleEmpty = ranges.filter { $0.rangeValue.length == 0 }.count > 1
        if hasMultipleEmpty {
            _customSelectedRanges = ranges
            _isApplyingCustomSelection = true
            super.setSelectedRanges([ranges.first!], affinity: affinity, stillSelecting: stillSelecting)
            _isApplyingCustomSelection = false
        } else {
            _customSelectedRanges = nil
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        self.setNeedsDisplay(self.bounds)
    }
    
    override func mouseDown(with event: NSEvent) {
        let hasCmd = event.modifierFlags.contains(.command)
        
        if hasCmd {
            self.window?.makeFirstResponder(self)
            
            let location = self.convert(event.locationInWindow, from: nil)
            let index = self.characterIndexForInsertion(at: location)
            
            if index != NSNotFound {
                var ranges = self.selectedRanges
                let newRange = NSRange(location: index, length: 0)
                
                if let existingIndex = ranges.firstIndex(where: { $0.rangeValue == newRange }) {
                    ranges.remove(at: existingIndex)
                } else {
                    ranges.append(NSValue(range: newRange))
                }
                
                if ranges.isEmpty {
                    ranges.append(NSValue(range: newRange))
                }
                
                self.selectedRanges = ranges
                return
            }
        }
        super.mouseDown(with: event)
    }
    
    private func selectAllOccurrences() {
        let contentString = self.string as NSString
        guard contentString.length > 0 else { return }
        
        let selectedRange = self.selectedRange()
        var searchString = ""
        
        if selectedRange.length == 0 {
            let wordRange = self.selectionRange(forProposedRange: selectedRange, granularity: .selectByWord)
            if wordRange.length > 0 {
                searchString = contentString.substring(with: wordRange)
            }
        } else {
            searchString = contentString.substring(with: selectedRange)
        }
        
        guard !searchString.isEmpty else { return }
        
        var ranges = [NSValue]()
        var searchRange = NSRange(location: 0, length: contentString.length)
        
        while searchRange.location < contentString.length {
            let foundRange = contentString.range(of: searchString, options: [], range: searchRange)
            if foundRange.location != NSNotFound {
                ranges.append(NSValue(range: foundRange))
                searchRange = NSRange(location: NSMaxRange(foundRange), length: contentString.length - NSMaxRange(foundRange))
            } else {
                break
            }
        }
        
        if !ranges.isEmpty {
            self.selectedRanges = ranges
            self.scrollRangeToVisible(ranges.first!.rangeValue)
        }
    }
    
    override func deleteBackward(_ sender: Any?) {
        if self.selectedRanges.count > 1 {
            let ranges = self.selectedRanges.map { $0.rangeValue }.sorted(by: { $0.location > $1.location })
            
            var newRanges = [NSValue]()
            
            for range in ranges {
                var deleteRange = range
                if range.length == 0 && range.location > 0 {
                    deleteRange = NSRange(location: range.location - 1, length: 1)
                }
                
                if deleteRange.length > 0 {
                    if applyTextChange(in: deleteRange, with: "") {
                        newRanges.append(NSValue(range: NSRange(location: deleteRange.location, length: 0)))
                    } else {
                        newRanges.append(NSValue(range: range))
                    }
                } else {
                    newRanges.append(NSValue(range: range))
                }
            }
            self.selectedRanges = newRanges.reversed()
        } else {
            super.deleteBackward(sender)
        }
    }
    
    override func deleteForward(_ sender: Any?) {
        if self.selectedRanges.count > 1 {
            let ranges = self.selectedRanges.map { $0.rangeValue }.sorted(by: { $0.location > $1.location })
            let contentString = self.string as NSString
            
            var newRanges = [NSValue]()
            
            for range in ranges {
                var deleteRange = range
                if range.length == 0 && range.location < contentString.length {
                    deleteRange = NSRange(location: range.location, length: 1)
                }
                
                if deleteRange.length > 0 {
                    if applyTextChange(in: deleteRange, with: "") {
                        newRanges.append(NSValue(range: NSRange(location: deleteRange.location, length: 0)))
                    } else {
                        newRanges.append(NSValue(range: range))
                    }
                } else {
                    newRanges.append(NSValue(range: range))
                }
            }
            self.selectedRanges = newRanges.reversed()
        } else {
            super.deleteForward(sender)
        }
    }
    
    private func selectNextOccurrence() {
        let contentString = self.string as NSString
        guard contentString.length > 0 else { return }
        
        var ranges = self.selectedRanges.map { $0.rangeValue }
        guard let lastRange = ranges.last else { return }
        
        var searchString = ""
        
        if lastRange.length == 0 {
            let wordRange = self.selectionRange(forProposedRange: lastRange, granularity: .selectByWord)
            if wordRange.length > 0 {
                self.setSelectedRange(wordRange)
                return
            }
        } else {
            searchString = contentString.substring(with: lastRange)
        }
        
        if searchString.isEmpty { return }
        
        let searchRange = NSRange(location: NSMaxRange(lastRange), length: contentString.length - NSMaxRange(lastRange))
        let foundRange = contentString.range(of: searchString, options: [], range: searchRange)
        
        if foundRange.location != NSNotFound {
            ranges.append(foundRange)
            self.selectedRanges = ranges.map { NSValue(range: $0) }
            self.scrollRangeToVisible(foundRange)
        } else {
            let wrapRange = NSRange(location: 0, length: lastRange.location)
            let foundWrapRange = contentString.range(of: searchString, options: [], range: wrapRange)
            if foundWrapRange.location != NSNotFound {
                ranges.append(foundWrapRange)
                self.selectedRanges = ranges.map { NSValue(range: $0) }
                self.scrollRangeToVisible(foundWrapRange)
            }
        }
    }
    
    private func selectCurrentLineOrLines() {
        let contentString = self.string as NSString
        if contentString.length == 0 { return }
        
        let selectedRange = self.selectedRange()
        let lineStart = contentString.lineRange(for: NSRange(location: selectedRange.location, length: 0)).location
        
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
