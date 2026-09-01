import Foundation

public struct WhisperConfiguration: Hashable, Sendable {
    public var executableURL: URL
    public var modelURL: URL
    public var workingDirectory: URL
    public var chunkDuration: TimeInterval
    public var minimumFinalChunkDuration: TimeInterval
    public var threadCount: Int

    public init(
        executableURL: URL,
        modelURL: URL,
        workingDirectory: URL,
        chunkDuration: TimeInterval = 6,
        minimumFinalChunkDuration: TimeInterval = 0.35,
        threadCount: Int = 8
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.workingDirectory = workingDirectory
        self.chunkDuration = max(1, chunkDuration)
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
        return WhisperConfiguration(
            executableURL: bundledExecutable,
            modelURL: root
                .appendingPathComponent("Whisper", isDirectory: true)
                .appendingPathComponent("ggml-base.en.bin"),
            workingDirectory: root
                .appendingPathComponent("Working", isDirectory: true)
                .appendingPathComponent("Whisper", isDirectory: true),
            threadCount: min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        )
    }
}
