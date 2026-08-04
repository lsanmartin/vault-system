import Foundation

/// Un hilo de chat persistente (como un chat de WhatsApp)
struct ChatThread: Identifiable, Codable {
    let id: String
    let agentCode: String
    var name: String
    let createdAt: String
    let updatedAt: String
}

/// Mensaje persistente en DuckDB
struct PersistentMessage: Codable {
    let role: String
    let agentCode: String?
    let content: String
    let timestamp: String
}

/// Gestiona la persistencia de hilos de chat en DuckDB.
/// Cada agente (@local, @ds, @cl, @op) tiene su propio thread independiente.
class ChatThreadManager: ObservableObject {
    static let shared = ChatThreadManager()

    @Published var threads: [ChatThread] = []
    @Published var activeThreadId: String? = nil

    init() {
        loadThreads()
    }

    // MARK: - Threads

    func loadThreads() {
        let json = chatListThreads()
        if let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([ChatThread].self, from: data) {
            threads = list
        }
    }

    func getOrCreateThread(for agentCode: String) -> String {
        // Buscar thread existente para este agente
        if let existing = threads.first(where: { $0.agentCode == agentCode }) {
            activeThreadId = existing.id
            return existing.id
        }
        // Crear nuevo
        let json = chatGetOrCreateThread(agentCode: agentCode)
        if let data = json.data(using: .utf8),
           let obj = try? JSONDecoder().decode([String: String].self, from: data),
           let tid = obj["thread_id"] {
            loadThreads()
            activeThreadId = tid
            return tid
        }
        return ""
    }

    func deleteThread(_ threadId: String) {
        _ = chatDeleteThread(threadId: threadId)
        loadThreads()
        if activeThreadId == threadId { activeThreadId = nil }
    }

    // MARK: - Messages

    func saveMessage(threadId: String, role: String, agentCode: String?, content: String) {
        _ = chatSaveMessage(threadId: threadId, role: role, agentCode: agentCode ?? "", content: content)
    }

    func loadMessages(threadId: String, limit: Int32 = 200) -> [PersistentMessage] {
        let json = chatGetMessages(threadId: threadId, limit: limit)
        if let data = json.data(using: .utf8),
           let msgs = try? JSONDecoder().decode([PersistentMessage].self, from: data) {
            return msgs
        }
        return []
    }

    // MARK: - Convert to LocalChatMessage

    func toLocalMessages(threadId: String, limit: Int32 = 200) -> [LocalChatMessage] {
        loadMessages(threadId: threadId, limit: limit).map { msg in
            LocalChatMessage(
                text: msg.content,
                isUser: msg.role == "user",
                agentCode: msg.agentCode
            )
        }
    }

    // MARK: - Naming

}
