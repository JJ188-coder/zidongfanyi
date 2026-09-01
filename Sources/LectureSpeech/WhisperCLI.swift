@preconcurrency import AVFoundation
import Foundation
import LectureCore

public final class WhisperCLI: @unchecked Sendable {
    public enum WhisperError: Error, CustomStringConvertible {
        case executableMissing
        case modelMissing
        case invalidFileType
        case launchFailed(String)
        case processFailed(Int32, String)
        case resultMissing

        public var description: String {
            switch self {
            case .executableMissing:
                "Lecture 缺少本地英文识别引擎，请重新安装应用"
            case .modelMissing:
                "Lecture 缺少本地英语模型，请重新安装应用"
            case .invalidFileType:
                "本地识别仅接受 WAV、MP3、FLAC 或 OGG 音频"
            case .launchFailed(let message):
                "本地英文识别无法启动：\(message)"
            case .processFailed(_, let message):
                message.isEmpty ? "本地英文识别失败" : "本地英文识别失败：\(message)"
            case .resultMissing:
                "本地英文识别没有生成结果"
            }
        }
    }

    private let configuration: WhisperConfiguration
    private let fileManager: FileManager
    private let processLock = NSLock()
    private var activeProcess: Process?

    public init(
        configuration: WhisperConfiguration = .live,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public var isAvailable: Bool {
        fileManager.isExecutableFile(atPath: configuration.executableURL.path)
            && fileManager.fileExists(atPath: configuration.modelURL.path)
    }

    public func prepareWorkingDirectory() throws {
        try fileManager.createDirectory(
            at: configuration.workingDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configuration.workingDirectory.path
        )
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in try fileManager.contentsOfDirectory(
            at: configuration.workingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.contentModificationDate ?? .distantFuture) < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    public func transcribe(
        audioURL: URL,
        lectureID: String,
        source: TranscriptSource,
        vocabulary: [String],
        timeOffset: TimeInterval = 0,
        maximumDuration: TimeInterval? = nil
    ) throws -> [TranscriptSegment] {
        guard fileManager.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw WhisperError.executableMissing
        }
        guard fileManager.fileExists(atPath: configuration.modelURL.path) else {
            throw WhisperError.modelMissing
        }
        guard ["wav", "mp3", "flac", "ogg"].contains(audioURL.pathExtension.lowercased()) else {
            throw WhisperError.invalidFileType
        }
        try prepareWorkingDirectory()

        let outputBase = configuration.workingDirectory
            .appendingPathComponent("result-\(UUID().uuidString)")
        let resultURL = outputBase.appendingPathExtension("json")
        defer { try? fileManager.removeItem(at: resultURL) }
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = arguments(
            audioURL: audioURL,
            outputBase: outputBase,
            vocabulary: vocabulary
        )
        process.currentDirectoryURL = configuration.workingDirectory
        let diagnostics = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics
        var diagnosticData = Data()
        let diagnosticQueue = DispatchQueue(label: "com.jiyuanyi.Lecture.WhisperDiagnostics")
        let diagnosticGroup = DispatchGroup()
        diagnosticGroup.enter()
        diagnosticQueue.async {
            diagnosticData = diagnostics.fileHandleForReading.readDataToEndOfFile()
            diagnosticGroup.leave()
        }

        var environment = ProcessInfo.processInfo.environment
        if let resources = Bundle.main.resourceURL {
            let runtime = resources.appendingPathComponent("WhisperRuntime", isDirectory: true)
            let libraries = runtime.appendingPathComponent("lib", isDirectory: true)
            let backends = runtime.appendingPathComponent("libexec", isDirectory: true)
            if fileManager.fileExists(atPath: libraries.path) {
                environment["DYLD_LIBRARY_PATH"] = libraries.path
            }
            if fileManager.fileExists(atPath: backends.path) {
                let candidates = (try? fileManager.contentsOfDirectory(
                    at: backends,
                    includingPropertiesForKeys: nil
                )) ?? []
                let backendNames = candidates
                    .filter { ["so", "dylib"].contains($0.pathExtension.lowercased()) }
                    .map { $0.lastPathComponent }
                    .joined(separator: ",")
                environment["GGML_BACKEND_PATH"] = backends
                    .appendingPathComponent(backendNames).path
            }
        }
        process.environment = environment

        do { try process.run() }
        catch {
            diagnostics.fileHandleForWriting.closeFile()
            diagnosticGroup.wait()
            throw WhisperError.launchFailed(safeMessage(error))
        }
        processLock.lock()
        activeProcess = process
        processLock.unlock()
        process.waitUntilExit()
        processLock.lock()
        if activeProcess === process { activeProcess = nil }
        processLock.unlock()
        diagnosticGroup.wait()
        if process.terminationStatus != 0 {
            throw WhisperError.processFailed(
                process.terminationStatus,
                safeDiagnostics(diagnosticData)
            )
        }

        guard let data = try? Data(contentsOf: resultURL) else {
            throw WhisperError.resultMissing
        }
        let items = try WhisperTranscriptParser.parse(data)
        return WhisperTranscriptParser.segments(
            from: items,
            lectureID: lectureID,
            source: source,
            timeOffset: timeOffset,
            maximumDuration: maximumDuration
        )
    }

    public var usesVoiceActivityDetection: Bool {
        guard let vadModelURL = configuration.vadModelURL else { return false }
        return fileManager.fileExists(atPath: vadModelURL.path)
    }

    public func cancel() {
        processLock.lock()
        let process = activeProcess
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    public func transcribeAudioFile(
        audioURL: URL,
        lectureID: String,
        source: TranscriptSource,
        vocabulary: [String]
    ) throws -> [TranscriptSegment] {
        if ["wav", "mp3", "flac", "ogg"].contains(audioURL.pathExtension.lowercased()) {
            return try transcribe(
                audioURL: audioURL,
                lectureID: lectureID,
                source: source,
                vocabulary: vocabulary
            )
        }

        try prepareWorkingDirectory()
        let wavURL = configuration.workingDirectory
            .appendingPathComponent("review-\(UUID().uuidString).wav")
        defer { try? fileManager.removeItem(at: wavURL) }
        try convertAudioFileToWAV(inputURL: audioURL, outputURL: wavURL)
        return try transcribe(
            audioURL: wavURL,
            lectureID: lectureID,
            source: source,
            vocabulary: vocabulary
        )
    }

    private func arguments(
        audioURL: URL,
        outputBase: URL,
        vocabulary: [String]
    ) -> [String] {
        var values = [
            "-m", configuration.modelURL.path,
            "-l", "en",
            "-t", String(configuration.threadCount),
            "-bo", "1",
            "-bs", "1",
            "-np",
            "-oj",
            "-of", outputBase.path,
        ]
        let prompt = prompt(from: vocabulary)
        if !prompt.isEmpty { values.append(contentsOf: ["--prompt", prompt]) }
        if let vadModelURL = configuration.vadModelURL,
           fileManager.fileExists(atPath: vadModelURL.path) {
            values.append(contentsOf: [
                "--vad",
                "--vad-model", vadModelURL.path,
                "--vad-threshold", "0.35",
                "--vad-min-speech-duration-ms", "180",
                "--vad-min-silence-duration-ms", "700",
                "--vad-max-speech-duration-s", "18",
                "--vad-speech-pad-ms", "220",
                "--vad-samples-overlap", "0.25",
            ])
        }
        values.append(audioURL.path)
        return values
    }

    private func prompt(from vocabulary: [String]) -> String {
        String(
            VocabularyNormalizer.normalized(vocabulary, maximumCount: 100)
                .joined(separator: ", ")
                .prefix(1_500)
        )
    }

    private func safeDiagnostics(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        let useful = text
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.contains("whisper_") && !$0.contains("ggml_") }
            .suffix(2)
            .joined(separator: " ")
        return SecretRedactor.redact(String(useful.prefix(400)))
    }

    private func safeMessage(_ error: Error) -> String {
        SecretRedactor.redact(String(String(describing: error).prefix(300)))
    }

    private func convertAudioFileToWAV(inputURL: URL, outputURL: URL) throws {
        let inputFile: AVAudioFile
        do { inputFile = try AVAudioFile(forReading: inputURL) }
        catch { throw WhisperError.launchFailed("无法读取课堂录音") }
        let converter = try WhisperAudioConverter(sourceFormat: inputFile.processingFormat)
        let outputHandle = try WhisperWAVWriter.createEmptyFile(at: outputURL)
        var sampleCount: Int64 = 0
        var finalized = false
        defer {
            if !finalized { try? outputHandle.close() }
        }
        let frameCount: AVAudioFrameCount = 16_384
        while inputFile.framePosition < inputFile.length {
            let remaining = inputFile.length - inputFile.framePosition
            let requested = min(frameCount, AVAudioFrameCount(remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFile.processingFormat,
                frameCapacity: requested
            ) else { break }
            do { try inputFile.read(into: buffer, frameCount: requested) }
            catch { throw WhisperError.launchFailed("无法读取完整课堂录音") }
            guard buffer.frameLength > 0 else { break }
            let samples = try converter.convert(buffer)
            guard !samples.isEmpty else { continue }
            try WhisperWAVWriter.append(samples: samples, to: outputHandle)
            sampleCount += Int64(samples.count)
        }
        try WhisperWAVWriter.finalize(outputHandle, sampleCount: sampleCount)
        finalized = true
    }
}
