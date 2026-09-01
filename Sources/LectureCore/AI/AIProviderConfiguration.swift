import Foundation

public enum AIProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case deepSeek
    case openAICompatible
    case local
}

public struct AIProviderConfiguration: Codable, Hashable, Sendable {
    public var name: String
    public var baseURL: String
    public var model: String
    public var providerKind: AIProviderKind
    public var requiresAPIKey: Bool
    public var sendThinkingDisabled: Bool
    public var supportsJSONResponseFormat: Bool

    public init(
        name: String,
        baseURL: String,
        model: String,
        providerKind: AIProviderKind = .openAICompatible,
        requiresAPIKey: Bool = true,
        sendThinkingDisabled: Bool = false,
        supportsJSONResponseFormat: Bool = true
    ) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.providerKind = providerKind
        self.requiresAPIKey = requiresAPIKey
        self.sendThinkingDisabled = sendThinkingDisabled
        self.supportsJSONResponseFormat = supportsJSONResponseFormat
    }

    public static let deepSeekV4Flash = AIProviderConfiguration(
        name: "DeepSeek V4 Flash",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-flash",
        providerKind: .deepSeek,
        sendThinkingDisabled: true
    )

    public static let deepSeekV4Pro = AIProviderConfiguration(
        name: "DeepSeek V4 Pro",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-pro",
        providerKind: .deepSeek,
        sendThinkingDisabled: true
    )

    public static let openAI = AIProviderConfiguration(
        name: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-5-mini"
    )

    public static let openRouter = AIProviderConfiguration(
        name: "OpenRouter",
        baseURL: "https://openrouter.ai/api/v1",
        model: "openai/gpt-5-mini"
    )

    public static let local = AIProviderConfiguration(
        name: "本地 OpenAI 兼容服务",
        baseURL: "http://127.0.0.1:11434/v1",
        model: "qwen3",
        providerKind: .local,
        requiresAPIKey: false,
        supportsJSONResponseFormat: false
    )

    public static let presets: [AIProviderConfiguration] = [
        .deepSeekV4Flash, .deepSeekV4Pro, .openAI, .openRouter, .local,
    ]

    public func validated() throws -> AIProviderConfiguration {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw AIProviderConfigurationError.missingName }
        guard !value.model.isEmpty else { throw AIProviderConfigurationError.missingModel }
        guard value.name.count <= 100, value.model.count <= 300, value.baseURL.count <= 2_000 else {
            throw AIProviderConfigurationError.valueTooLong
        }
        _ = try value.chatCompletionsURL()
        return value
    }

    public func chatCompletionsURL() throws -> URL {
        guard var components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        let localHosts = ["localhost", "127.0.0.1", "::1"]
        if scheme == "http" {
            guard localHosts.contains(host) else { throw AIProviderConfigurationError.insecureRemoteURL }
        } else if scheme != "https" {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path.isEmpty ? "/chat/completions" : path
        guard let url = components.url else { throw AIProviderConfigurationError.invalidBaseURL }
        return url
    }
}

public struct AIProviderConfigurationStatus: Codable, Hashable, Sendable {
    public var configuration: AIProviderConfiguration
    public var keyConfigured: Bool
    public var presets: [AIProviderConfiguration]

    public init(
        configuration: AIProviderConfiguration,
        keyConfigured: Bool,
        presets: [AIProviderConfiguration] = AIProviderConfiguration.presets
    ) {
        self.configuration = configuration
        self.keyConfigured = keyConfigured
        self.presets = presets
    }
}

public enum AIProviderConfigurationError: Error, CustomStringConvertible, Sendable {
    case missingName
    case missingModel
    case invalidBaseURL
    case insecureRemoteURL
    case valueTooLong

    public var description: String {
        switch self {
        case .missingName: return "请填写 AI 服务名称"
        case .missingModel: return "请填写模型名称"
        case .invalidBaseURL: return "AI 服务地址无效"
        case .insecureRemoteURL: return "远程 AI 服务必须使用 HTTPS；HTTP 只允许 localhost 或 127.0.0.1"
        case .valueTooLong: return "AI 服务配置内容过长"
        }
    }
}
