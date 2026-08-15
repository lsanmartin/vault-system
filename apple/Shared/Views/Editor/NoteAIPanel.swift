import SwiftUI

/// Modo de edición al aplicar un resultado de IA a la nota activa.
enum NoteAIMode: String, CaseIterable, Identifiable {
    case insertAtEnd = "Insertar al final"
    case replaceAll = "Reemplazar todo"
    case replaceSelection = "Reemplazar selección"
    var id: String { self.rawValue }
}

/// Acción predefinida de IA aplicable a la nota activa.
struct NoteAIAction: Identifiable, Hashable {
    let id: String
    let title: String
    let instruction: String
    let icon: String

    static let all: [NoteAIAction] = [
        NoteAIAction(id: "summarize", title: "Resumir", instruction: "Genera un resumen analítico denso de tres puntos clave.", icon: "text.alignleft"),
        NoteAIAction(id: "glossary", title: "Glosario", instruction: "Extrae los términos técnicos y genera definiciones concisas.", icon: "character.book.closed"),
        NoteAIAction(id: "writing", title: "Redacción", instruction: "Corrige la gramática y el estilo del texto de forma profesional.", icon: "pencil.line")
    ]
}

/// Información de una acción de IA para notas, inyectada a la generación para marcar el resultado como aplicable.
struct NoteAIApplyInfo {
    let instruction: String   // label visible ("Resumir Nota")
    let noteId: String?       // nil → crear nota nueva con el resultado
    let noteTitle: String
    let originalContent: String
    var createNew: Bool = false
}

/// Fila de acciones rápidas de IA para la nota activa (arriba del input del chat).
struct NoteAIQuickActionsRow: View {
    let actions: [NoteAIAction]
    let isEnabled: Bool
    let onAction: (NoteAIAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(actions) { action in
                    Button(action: { onAction(action) }) {
                        HStack(spacing: 3) {
                            Image(systemName: action.icon)
                                .font(.system(size: 9))
                            Text(action.title)
                                .font(.caption2).bold()
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(isEnabled ? 0.12 : 0.05))
                        .foregroundColor(isEnabled ? .accentColor : .secondary.opacity(0.5))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .help(action.instruction)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 22)
    }
}

/// Panel colapsable de opciones IA para la nota activa (bajo los permisos).
struct NoteAIOptionsPanel: View {
    @ObservedObject var viewModel: EditorViewModel
    let isEnabled: Bool
    @Binding var autoApply: Bool
    @Binding var modeRaw: String
    @Binding var titleOverride: String
    let onRun: (String, String) -> Void

    @State private var customInstruction: String = ""

    private var activeTab: TabItem? {
        guard let id = viewModel.activeTabId else { return nil }
        return viewModel.tabs.first(where: { $0.id == id })
    }

    private var effectiveTitle: String {
        if !titleOverride.isEmpty { return titleOverride }
        if let t = activeTab?.title { return t }
        return "Nueva nota IA"
    }

    var body: some View {
        // El panel ya no tiene cabecera propia: se renderiza completo cuando el
        // header de la sección lo despliega (toggle sparkles ▾), o nada si está cerrado.
        VStack(alignment: .leading, spacing: 8) {
                // Nota activa
                HStack(spacing: 4) {
                    Image(systemName: activeTab == nil ? "doc.text" : "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundColor(activeTab == nil ? .secondary : .accentColor)
                    Text(effectiveTitle)
                        .font(.caption).bold()
                        .lineLimit(1)
                    Spacer()
                    if activeTab != nil {
                        Button {
                            titleOverride = ""
                            customInstruction = ""
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Restablecer")
                    }
                }

                // Título a usar en la cabecera de la inserción
                TextField("Título (opcional)", text: $titleOverride)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)

                // Acciones rápidas
                HStack(spacing: 6) {
                    ForEach(NoteAIAction.all) { action in
                        Button(action: { run(action) }) {
                            VStack(spacing: 3) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 13))
                                Text(action.title)
                                    .font(.caption2).bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(isEnabled ? 0.10 : 0.04))
                            .foregroundColor(isEnabled ? .accentColor : .secondary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEnabled)
                        .help(action.instruction)
                    }
                }

                // Instrucción personalizada
                HStack(spacing: 6) {
                    TextField("Instrucción personalizada...", text: $customInstruction)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                        .disabled(!isEnabled)
                        .onSubmit {
                            let t = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            onRun(t, effectiveTitle)
                            customInstruction = ""
                        }
                    Button(action: {
                        let t = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        onRun(t, effectiveTitle)
                        customInstruction = ""
                    }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11))
                            .foregroundColor(isEnabled ? .accentColor : .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                }

                Divider()

                // Preferencias
                Toggle(isOn: $autoApply) {
                    Text("Aplicar automáticamente")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Picker("Aplicar como", selection: $modeRaw) {
                    ForEach(NoteAIMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
            }
            .padding(.top, 4)
            .disabled(!isEnabled)
    }

    private func run(_ action: NoteAIAction) {
        onRun(action.instruction, effectiveTitle)
    }
}
