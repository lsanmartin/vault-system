import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var triggerSearch: Bool
    let language: String
    let theme: AppTheme
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        
        // Habilitar barra de búsqueda (Command+F)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        
        // Agregar espacio interno (Padding)
        textView.textContainerInset = NSSize(width: 70, height: 70)
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
