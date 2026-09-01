import Foundation

public struct WhisperConfiguration: Hashable, Sendable {
    public var executableURL: URL
    public var modelURL: URL
    public var vadModelURL: URL?
    public var workingDirectory: URL
    public var chunkDuration: TimeInterval
    public var draftDuration: TimeInterval
    public var minimumFinalChunkDuration: TimeInterval
    public var threadCount: Int

    public init(
        executableURL: URL,
        modelURL: URL,
        vadModelURL: URL? = nil,
        workingDirectory: URL,
        chunkDuration: TimeInterval = 5,
        draftDuration: TimeInterval = 2.5,
        minimumFinalChunkDuration: TimeInterval = 0.35,
        threadCount: Int = 8
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.vadModelURL = vadModelURL
        self.workingDirectory = workingDirectory
        self.chunkDuration = max(1, chunkDuration)
        self.draftDuration = max(1, min(draftDuration, self.chunkDuration))
        self.minimumFinalChunkDuration = max(0, minimumFinalChunkDuration)
        self.threadCount = max(1, threadCount)
    }

    public static var live: WhisperConfiguration {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let root = support.appendingPathComponent("Lecture", isDirectory: true)
        let bundledExecutable = Bundle.main.url(
            forAuxiliaryExecutable: "whisper-cli"
        ) ?? URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
        let whisperRoot = root.appendingPathComponent("Whisper", isDirectory: true)
        let qualityModel = whisperRoot.appendingPathComponent("ggml-small.en.bin")
        let balancedModel = whisperRoot.appendingPathComponent("ggml-base.en.bin")
        return WhisperConfiguration(
            executableURL: bundledExecutable,
            modelURL: FileManager.default.fileExists(atPath: qualityModel.path)
                ? qualityModel : balancedModel,
            vadModelURL: whisperRoot.appendingPathComponent("ggml-silero-v6.2.0.bin"),
            workingDirectory: root
                .appendingPathComponent("Working", isDirectory: true)
                .appendingPathComponent("Whisper", isDirectory: true),
            threadCount: min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        )
    }
}
