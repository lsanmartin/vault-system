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
    let id: Int64?
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
        guard let data = json.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase   // FFI devuelve agent_code, created_at…
        if let list = try? decoder.decode([ChatThread].self, from: data) {
            threads = list
        }
    }

    func getOrCreateThread(for agentCode: String) -> String {
        // Siempre consultar DB primero (threads en memoria puede estar stale)
        if threads.isEmpty { loadThreads() }
        if let existing = threads.first(where: { $0.agentCode == agentCode }) {
            activeThreadId = existing.id
            return existing.id
        }
        // Usar FFI que busca en DB antes de crear
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

    @discardableResult
    func saveMessage(threadId: String, role: String, agentCode: String?, content: String) -> Int64 {
        chatSaveMessage(threadId: threadId, role: role, agentCode: agentCode ?? "", content: content)
    }

    /// Carga mensajes del thread: las últimas `limit` (beforeId = nil) o las anteriores a `beforeId`.
    func loadMessages(threadId: String, limit: Int32 = 200, beforeId: Int64? = nil) -> [PersistentMessage] {
        let json = chatGetMessages(threadId: threadId, limit: limit, beforeId: beforeId)
        return decodeMessages(json)
    }

    /// Busca mensajes por substring dentro del thread, más recientes primero.
    func searchMessages(threadId: String, query: String, limit: Int32 = 100) -> [PersistentMessage] {
        let json = chatSearchMessages(threadId: threadId, query: query, limit: limit)
        return decodeMessages(json)
    }

    private func decodeMessages(_ json: String) -> [PersistentMessage] {
        guard let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase   // FFI devuelve agent_code → agentCode
        return (try? decoder.decode([PersistentMessage].self, from: data)) ?? []
    }

    // MARK: - Convert to LocalChatMessage

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func toLocalMessages(threadId: String, limit: Int32 = 200, beforeId: Int64? = nil) -> [LocalChatMessage] {
        loadMessages(threadId: threadId, limit: limit, beforeId: beforeId).map { msg in
            var local = LocalChatMessage(
                text: msg.content,
                isUser: msg.role == "user",
                agentCode: msg.agentCode
            )
            local.persistedId = msg.id
            // DuckDB devuelve timestamps como "2026-08-10 12:34:56" (puede traer fracción o offset)
            let ts = msg.timestamp
            local.persistedDate = Self.dateParser.date(from: ts)
                ?? ISO8601DateFormatter().date(from: ts)
                ?? Self.flexibleDateParser(ts)
            return local
        }
    }

    private static func flexibleDateParser(_ s: String) -> Date? {
        // "2026-08-10 12:34:56.123456" o similar (formato %F %T%.f de chrono):
        // recortar la fracción de microsegundos del componente de hora.
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let datePart = parts[0]
        let timePart = parts[1].split(separator: ".").first ?? parts[1]
        return dateParser.date(from: "\(datePart) \(timePart)")
    }

    // MARK: - Naming

}
