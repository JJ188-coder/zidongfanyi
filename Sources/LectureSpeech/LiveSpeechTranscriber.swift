@preconcurrency import AVFoundation
import Foundation
import LectureCore

public final class LiveSpeechTranscriber: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable (TranscriptionUpdate) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    public enum LiveSpeechError: Error, CustomStringConvertible {
        case alreadyRunning
        case unavailable

        public var description: String {
            switch self {
            case .alreadyRunning: "英文识别已在运行"
            case .unavailable: "本地英文识别引擎或英语模型不可用，请重新安装 Lecture"
            }
        }
    }

    private let vocabulary: [String]
    private let configuration: WhisperConfiguration
    private let whisper: WhisperCLI
    private let stateLock = NSLock()
    private let workerQueue = DispatchQueue(label: "com.jiyuanyi.Lecture.WhisperLive")
    private var converter: WhisperAudioConverter?
    private var lectureID: String?
    private var handler: UpdateHandler?
    private var errorHandler: ErrorHandler?
    private var pendingSamples: [Int16] = []
    private var pendingStartSample: Int64 = 0
    private var processing = false
    private var running = false
    private var finishing = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeProcessCount = 0

    public init(
        vocabulary: [String],
        locale: Locale = Locale(identifier: "en-US"),
        configuration: WhisperConfiguration = .live
    ) {
        _ = locale
        self.vocabulary = VocabularyNormalizer.normalized(vocabulary)
        self.configuration = configuration
        whisper = WhisperCLI(configuration: configuration)
    }

    public static var isAvailable: Bool { WhisperCLI().isAvailable }

    public func start(
        lectureID: String,
        audioFormat: AVAudioFormat,
        handler: @escaping UpdateHandler,
        onError: ErrorHandler? = nil
    ) async throws {
        guard whisper.isAvailable else { throw LiveSpeechError.unavailable }
        try whisper.prepareWorkingDirectory()
        let converter = try WhisperAudioConverter(sourceFormat: audioFormat)
        let reserved = stateLock.withLock { () -> Bool in
            guard !running, !finishing, activeProcessCount == 0 else { return false }
            self.converter = converter
            self.lectureID = lectureID
            self.handler = handler
            errorHandler = onError
            pendingSamples.removeAll(keepingCapacity: true)
            pendingStartSample = 0
            processing = false
            running = true
            finishing = false
            return true
        }
        guard reserved else { throw LiveSpeechError.alreadyRunning }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        let state = stateLock.withLock { (running, converter, errorHandler) }
        guard state.0, let converter = state.1 else { return }
        do {
            let samples = try converter.convert(buffer)
            guard !samples.isEmpty else { return }
            var shouldSchedule = false
            stateLock.withLock {
                guard running else { return }
                pendingSamples.append(contentsOf: samples)
                if !processing, pendingSamples.count >= chunkSampleCount {
                    processing = true
                    shouldSchedule = true
                }
            }
            if shouldSchedule { scheduleNextChunk() }
        } catch {
            state.2?(error)
        }
    }

    public func finish() async {
        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        let shouldWait = stateLock.withLock { () -> Bool in
            guard running || processing || activeProcessCount > 0 else { return false }
            running = false
            finishing = true
            if !processing, !pendingSamples.isEmpty {
                processing = true
                workerQueue.async { [weak self] in self?.processNextChunk() }
            } else if !processing {
                waitersToResume = takeFinishWaitersIfReadyLocked()
            }
            return processing || activeProcessCount > 0 || !pendingSamples.isEmpty
        }
        waitersToResume.forEach { $0.resume() }
        guard shouldWait else { clearState(); return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = stateLock.withLock { () -> Bool in
                if !processing, activeProcessCount == 0, pendingSamples.isEmpty { return true }
                finishWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
        clearState()
    }

    public func cancel() async {
        whisper.cancel()
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            running = false
            finishing = false
            pendingSamples.removeAll(keepingCapacity: false)
            let values = finishWaiters
            finishWaiters.removeAll()
            return values
        }
        waiters.forEach { $0.resume() }
        while stateLock.withLock({ activeProcessCount > 0 }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        clearState()
    }

    private var chunkSampleCount: Int {
        max(1, Int(configuration.chunkDuration * WhisperAudioConverter.sampleRate))
    }

    private var minimumFinalSampleCount: Int {
        max(1, Int(configuration.minimumFinalChunkDuration * WhisperAudioConverter.sampleRate))
    }

    private func scheduleNextChunk() {
        workerQueue.async { [weak self] in self?.processNextChunk() }
    }

    private func processNextChunk() {
        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        let work = stateLock.withLock { () -> (samples: [Int16], startSample: Int64, lectureID: String, handler: UpdateHandler?, errorHandler: ErrorHandler?)? in
            guard processing, let lectureID else { return nil }
            let count: Int
            if pendingSamples.count >= chunkSampleCount {
                count = chunkSampleCount
            } else if finishing, pendingSamples.count >= minimumFinalSampleCount {
                count = pendingSamples.count
            } else {
                if finishing, !pendingSamples.isEmpty {
                    pendingStartSample += Int64(pendingSamples.count)
                    pendingSamples.removeAll(keepingCapacity: false)
                }
                processing = false
                waitersToResume = takeFinishWaitersIfReadyLocked()
                return nil
            }
            let samples = Array(pendingSamples.prefix(count))
            pendingSamples.removeFirst(count)
            let start = pendingStartSample
            pendingStartSample += Int64(count)
            activeProcessCount += 1
            return (samples, start, lectureID, handler, errorHandler)
        }
        waitersToResume.forEach { $0.resume() }
        guard let work else { return }

        let wavURL = configuration.workingDirectory
            .appendingPathComponent("live-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            finishProcessedChunk()
        }
        do {
            try WhisperWAVWriter.data(samples: work.samples).write(to: wavURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: wavURL.path
            )
            let offset = Double(work.startSample) / WhisperAudioConverter.sampleRate
            let segments = try whisper.transcribe(
                audioURL: wavURL,
                lectureID: work.lectureID,
                source: .liveEnglish,
                vocabulary: vocabulary,
                timeOffset: offset,
                maximumDuration: Double(work.samples.count) / WhisperAudioConverter.sampleRate
            )
            for segment in segments {
                work.handler?(TranscriptionUpdate(
                    segment: segment,
                    alternatives: [],
                    confidenceClassification: .unavailable,
                    kind: .final
                ))
            }
        } catch {
            work.errorHandler?(error)
        }
    }

    private func finishProcessedChunk() {
        var shouldContinue = false
        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        stateLock.withLock {
            activeProcessCount = max(0, activeProcessCount - 1)
            if pendingSamples.count >= chunkSampleCount
                || (finishing && pendingSamples.count >= minimumFinalSampleCount) {
                shouldContinue = true
            } else {
                if finishing, !pendingSamples.isEmpty {
                    pendingStartSample += Int64(pendingSamples.count)
                    pendingSamples.removeAll(keepingCapacity: false)
                }
                processing = false
                waitersToResume = takeFinishWaitersIfReadyLocked()
            }
        }
        waitersToResume.forEach { $0.resume() }
        if shouldContinue { scheduleNextChunk() }
    }

    private func takeFinishWaitersIfReadyLocked() -> [CheckedContinuation<Void, Never>] {
        guard finishing, !processing, activeProcessCount == 0, pendingSamples.isEmpty else { return [] }
        let waiters = finishWaiters
        finishWaiters.removeAll()
        finishing = false
        return waiters
    }

    private func clearState() {
        stateLock.withLock {
            converter = nil
            lectureID = nil
            handler = nil
            errorHandler = nil
            pendingSamples.removeAll(keepingCapacity: false)
            pendingStartSample = 0
            processing = false
            running = false
            finishing = false
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
