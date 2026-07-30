import SwiftUI
import Combine

/// Mensaje de Chat
struct LocalChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let timestamp = Date()
}

/// Vista del Chat RAG de IA Local (Gemma 4 en GPU)
struct LocalChatView: View {
    @ObservedObject var viewModel: EditorViewModel
    @StateObject private var brain = LocalBrain.shared
    
    @State private var messages: [LocalChatMessage] = [
        LocalChatMessage(text: "¡Hola! Soy tu asistente cognitivo local. ¿De qué te gustaría conversar sobre tus notas hoy?", isUser: false)
    ]
    @State private var inputPrompt: String = ""
    @State private var isGenerating: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(brain.isDownloading ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemma 4 (Local)")
                        .font(.headline)
                    Text(brain.isDownloading ? "Descargando weights... \(Int(brain.downloadProgress * 100))%" : "GPU Metal Caliente")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                Button(action: {
                    messages = [LocalChatMessage(text: "Conversación reiniciada. ¿En qué puedo ayudarte?", isUser: false)]
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Lista de Mensajes
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { msg in
                            ChatBubble(message: msg)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Entrada de texto
            HStack(spacing: 8) {
                TextField("Pregúntale a tu Vault...", text: $inputPrompt)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isGenerating)
                    .onSubmit {
                        sendMessage()
                    }
                
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 260, maxWidth: 350)
    }
    
    private func sendMessage() {
        let cleanText = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        inputPrompt = ""
        let userMsg = LocalChatMessage(text: cleanText, isUser: true)
        messages.append(userMsg)
        
        isGenerating = true
        
        // Obtener contexto de la nota activa si está abierta
        var activeContext = ""
        if let activeId = viewModel.activeTabId,
           let tab = viewModel.tabs.first(where: { $0.id == activeId }) {
            activeContext = tab.content
        }
        
        Task {
            do {
                // Iniciar stream del chat
                let stream = try await brain.chatStream(prompt: cleanText, context: activeContext)
                
                // Añadir burbuja vacía para la respuesta
                let assistantMsg = LocalChatMessage(text: "", isUser: false)
                DispatchQueue.main.async {
                    messages.append(assistantMsg)
                }
                
                var accumulatedText = ""
                for await chunk in stream {
                    accumulatedText += chunk
                    DispatchQueue.main.async {
                        if let lastIdx = messages.indices.last {
                            messages[lastIdx] = LocalChatMessage(text: accumulatedText, isUser: false)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    messages.append(LocalChatMessage(text: "❌ Error: \(error.localizedDescription)", isUser: false))
                }
            }
            DispatchQueue.main.async {
                isGenerating = false
            }
        }
    }
}

/// Burbuja de Mensaje Premium
struct ChatBubble: View {
    let message: LocalChatMessage
    
    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            
            Text(message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.isUser ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                .foregroundColor(message.isUser ? .white : .primary)
                .cornerRadius(12)
                .textSelection(.enabled)
                .frame(maxWidth: 260, alignment: message.isUser ? .trailing : .leading)
            
            if !message.isUser { Spacer() }
        }
    }
}
