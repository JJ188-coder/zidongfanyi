import Foundation
import Speech

@available(macOS 26.0, *)
public enum SpeechAssetManager {
    public enum AssetError: Error, CustomStringConvertible {
        case unsupportedLocale(String)
        case installationUnavailable

        public var description: String {
            switch self {
            case .unsupportedLocale(let identifier):
                return "这台 Mac 不支持英语识别资源（\(identifier)）"
            case .installationUnavailable:
                return "无法准备本地英语识别资源，请连接网络后重试"
            }
        }
    }

    public static func requestedLocale(identifier: String?) -> Locale {
        let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.lowercased().hasPrefix("en-") || value.lowercased() == "en" else {
            return Locale(identifier: "en-US")
        }
        return Locale(identifier: value)
    }

    public static func resolvedLocale(
        identifier: String? = nil
    ) async throws -> Locale {
        let requested = requestedLocale(identifier: identifier)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AssetError.unsupportedLocale(requested.identifier)
        }
        return locale
    }

    @discardableResult
    public static func ensureInstalled(
        identifier: String? = nil
    ) async throws -> Locale {
        let locale = try await resolvedLocale(identifier: identifier)
        let modules: [any SpeechModule] = [
            OfflineDictationTranscriber.makeDictationTranscriber(locale: locale),
        ]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return locale
        case .unsupported:
            throw AssetError.unsupportedLocale(locale.identifier)
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                if await AssetInventory.status(forModules: modules) == .installed { return locale }
                throw AssetError.installationUnavailable
            }
            try await request.downloadAndInstall()
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw AssetError.installationUnavailable
            }
            _ = try? await AssetInventory.reserve(locale: locale)
            return locale
        @unknown default:
            throw AssetError.installationUnavailable
        }
    }
}
