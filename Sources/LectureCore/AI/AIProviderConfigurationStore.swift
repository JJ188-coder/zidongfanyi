import Foundation

public protocol AIProviderConfigurationProviding: Sendable {
    func loadConfiguration() throws -> AIProviderConfiguration
}

public final class AIProviderConfigurationStore: AIProviderConfigurationProviding, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(
        url: URL = AppPaths.live.aiConfiguration,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
    }

    public func loadConfiguration() throws -> AIProviderConfiguration {
        try lock.withLock {
            guard fileManager.fileExists(atPath: url.path) else { return .deepSeekV4Flash }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try JSONDecoder().decode(AIProviderConfiguration.self, from: data).validated()
        }
    }

    public func saveConfiguration(_ configuration: AIProviderConfiguration) throws {
        let value = try configuration.validated()
        try lock.withLock {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
