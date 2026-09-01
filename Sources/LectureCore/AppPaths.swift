import Foundation

public struct LectureStorageUsage: Codable, Hashable, Sendable {
    public var totalBytes: Int64
    public var recordingBytes: Int64
    public var databaseBytes: Int64
    public var exportBytes: Int64
    public var recordingCount: Int

    public init(
        totalBytes: Int64 = 0,
        recordingBytes: Int64 = 0,
        databaseBytes: Int64 = 0,
        exportBytes: Int64 = 0,
        recordingCount: Int = 0
    ) {
        self.totalBytes = totalBytes
        self.recordingBytes = recordingBytes
        self.databaseBytes = databaseBytes
        self.exportBytes = exportBytes
        self.recordingCount = recordingCount
    }
}

public struct AppPaths: Sendable {
    public let root: URL
    public let database: URL
    public let recordings: URL
    public let exports: URL
    public let working: URL
    public let speechModels: URL
    public let whisper: URL
    public let whisperModel: URL
    public let whisperQualityModel: URL
    public let whisperVADModel: URL
    public let aiConfiguration: URL
    public let whisperWorking: URL

    public init(root: URL) {
        self.root = root
        self.database = root.appendingPathComponent("lecture.sqlite3")
        self.recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        self.exports = root.appendingPathComponent("Exports", isDirectory: true)
        self.working = root.appendingPathComponent("Working", isDirectory: true)
        self.speechModels = root.appendingPathComponent("SpeechModels", isDirectory: true)
        self.whisper = root.appendingPathComponent("Whisper", isDirectory: true)
        self.whisperModel = whisper.appendingPathComponent("ggml-base.en.bin")
        self.whisperQualityModel = whisper.appendingPathComponent("ggml-small.en.bin")
        self.whisperVADModel = whisper.appendingPathComponent("ggml-silero-v6.2.0.bin")
        self.aiConfiguration = root.appendingPathComponent("ai-provider.json")
        self.whisperWorking = working.appendingPathComponent("Whisper", isDirectory: true)
    }

    public static var live: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return AppPaths(root: support.appendingPathComponent("Lecture", isDirectory: true))
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: working, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: speechModels, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: whisper, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: whisperWorking, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordings.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exports.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: working.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: speechModels.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: whisper.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: whisperWorking.path)
        if fileManager.fileExists(atPath: whisperModel.path) {
            let values = try whisperModel.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AppPathError.unsafeWhisperModel
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: whisperModel.path)
        }
        if fileManager.fileExists(atPath: whisperVADModel.path) {
            let values = try whisperVADModel.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AppPathError.unsafeWhisperModel
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: whisperVADModel.path)
        }
        if fileManager.fileExists(atPath: whisperQualityModel.path) {
            let values = try whisperQualityModel.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AppPathError.unsafeWhisperModel
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: whisperQualityModel.path)
        }
        for url in try fileManager.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        for url in [database, database.appendingPathExtension("wal"), database.appendingPathExtension("shm")]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if fileManager.fileExists(atPath: aiConfiguration.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aiConfiguration.path)
        }
    }

    public func audioURL(lectureID: String, fileExtension: String = "m4a") -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = lectureID.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : Character("-") }
        let ext = fileExtension.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return recordings.appendingPathComponent("\(String(safe)).\(ext.isEmpty ? "m4a" : ext)")
    }

    public func storageUsage(fileManager: FileManager = .default) throws -> LectureStorageUsage {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ]
        ) else { return LectureStorageUsage() }

        var usage = LectureStorageUsage()
        let recordingsPrefix = recordings.standardizedFileURL.path + "/"
        let exportsPrefix = exports.standardizedFileURL.path + "/"
        let databasePath = database.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            let path = url.standardizedFileURL.path
            usage.totalBytes += bytes
            if path.hasPrefix(recordingsPrefix) {
                usage.recordingBytes += bytes
                usage.recordingCount += 1
            } else if path.hasPrefix(exportsPrefix) {
                usage.exportBytes += bytes
            } else if path == databasePath || path.hasPrefix(databasePath + "-") {
                usage.databaseBytes += bytes
            }
        }
        return usage
    }
}

public enum AppPathError: Error, CustomStringConvertible {
    case unsafeWhisperModel

    public var description: String {
        "本地 Whisper 模型路径不安全，请重新安装 Lecture"
    }
}
