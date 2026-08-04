import Foundation
import Security

// MARK: - Provider

enum ExternalAgentProvider: String, Codable, CaseIterable, Hashable {
    case deepseek = "DeepSeek"
    case anthropic = "Anthropic"
    case openai = "OpenAI"

    var baseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-v4-flash"
        case .anthropic: return "claude-sonnet-5-20250901"
        case .openai: return "gpt-4o"
        }
    }
}

// MARK: - Agent Config

struct ExternalAgentConfig: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var provider: ExternalAgentProvider
    var tokenId: String
    var model: String
    var createdAt: Date = Date()

    // Permisos reflejados del token MCP asociado
    var workspaces: [String] = []
    var readContent: Bool = false
    var readMetadata: Bool = true
    var readSystem: Bool = false
    var readTelemetry: Bool = true
    var writeContent: Bool = false
    var writeMetadata: Bool = false
    var writeSystem: Bool = false
}

// MARK: - Manager

class ExternalAgentManager: ObservableObject {
    static let shared = ExternalAgentManager()

    @Published var agents: [ExternalAgentConfig] = []

    private let agentsKey = "cl.nicelio.vault.externalAgents"
    private let keychainService = "cl.nicelio.vault.agent"

    init() {
        loadAgents()
    }

    // MARK: - Persistencia de config (sin API keys)

    func loadAgents() {
        if let data = UserDefaults.standard.data(forKey: agentsKey),
           let decoded = try? JSONDecoder().decode([ExternalAgentConfig].self, from: data) {
            agents = decoded
        }
    }

    private func saveAgents() {
        if let data = try? JSONEncoder().encode(agents) {
            UserDefaults.standard.set(data, forKey: agentsKey)
        }
    }

    // MARK: - Keychain

    private func keychainAccount(for agentId: String) -> String {
        return "agent_\(agentId)"
    }

    func saveAPIKey(_ key: String, for agentId: String) {
        let account = keychainAccount(for: agentId)
        guard let data = key.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[ExternalAgentManager] Error guardando API key en Keychain: \(status)")
        }
    }

    func getAPIKey(for agentId: String) -> String? {
        let account = keychainAccount(for: agentId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    func deleteAPIKey(for agentId: String) {
        let account = keychainAccount(for: agentId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - CRUD

    func addAgent(name: String, provider: ExternalAgentProvider, apiKey: String,
                  workspaces: [String],
                  readContent: Bool, readMetadata: Bool, readSystem: Bool, readTelemetry: Bool,
                  writeContent: Bool, writeMetadata: Bool, writeSystem: Bool) {
        // 1. Crear token MCP en Rust
        let tokenId = createExternalAgentToken(
            clientName: name,
            workspaces: workspaces,
            allowedPaths: [],
            readContent: readContent,
            readMetadata: readMetadata,
            readSystem: readSystem,
            readTelemetry: readTelemetry,
            writeContent: writeContent,
            writeMetadata: writeMetadata,
            writeSystem: writeSystem
        )

        // 2. Guardar API key en Keychain
        saveAPIKey(apiKey, for: tokenId)

        // 3. Guardar config local
        let config = ExternalAgentConfig(
            id: tokenId,
            name: name,
            provider: provider,
            tokenId: tokenId,
            model: provider.defaultModel,
            workspaces: workspaces,
            readContent: readContent,
            readMetadata: readMetadata,
            readSystem: readSystem,
            readTelemetry: readTelemetry,
            writeContent: writeContent,
            writeMetadata: writeMetadata,
            writeSystem: writeSystem
        )
        agents.append(config)
        saveAgents()

        // 4. Sincronizar tokens a UserDefaults
        syncTokensToUserDefaults()
    }

    func removeAgent(_ agent: ExternalAgentConfig) {
        deleteAPIKey(for: agent.id)
        _ = revokeMcpToken(tokenId: agent.tokenId)
        agents.removeAll(where: { $0.id == agent.id })
        saveAgents()
        syncTokensToUserDefaults()
    }

    func agentFor(tokenId: String) -> ExternalAgentConfig? {
        agents.first(where: { $0.tokenId == tokenId })
    }
}
