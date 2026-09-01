@preconcurrency import AVFoundation
import Foundation

public final class MicrophoneRecorder: @unchecked Sendable {
    public typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    public typealias LevelHandler = @Sendable (AudioLevel) -> Void
    public typealias CheckpointHandler = @Sendable (RecordingCheckpoint) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.jiyuanyi.Lecture.Recorder")
    private let stateLock = NSLock()
    private var file: AVAudioFile?
    private var startedAt: Date?
    private var bufferHandler: BufferHandler?
    private var levelHandler: LevelHandler?
    private var checkpointHandler: CheckpointHandler?
    private var errorHandler: ErrorHandler?
    private var checkpointScheduler = CheckpointScheduler(interval: 5)
    private var outputURL: URL?
    private var sampleRate = 0.0
    private var recordedFrames: Int64 = 0
    private var tapInstalled = false
    private var lastBufferAt: Date?

    public init() {}
    public var isRecording: Bool {
        stateLock.withLock { startedAt != nil && engine.isRunning }
    }
    public var isReceivingAudio: Bool {
        stateLock.withLock {
            guard startedAt != nil, engine.isRunning, let lastBufferAt else { return false }
            return Date().timeIntervalSince(lastBufferAt) < 2
        }
    }
    public var hasActiveSession: Bool { stateLock.withLock { startedAt != nil } }
    public var duration: TimeInterval {
        stateLock.withLock { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    }
    public var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    public static func protectRecording(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func requestPermission() async -> Bool {
        if #available(macOS 14.0, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { continuation in AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) } }
    }

    public func start(
        url: URL,
        checkpointInterval: TimeInterval = 5,
        onBuffer: @escaping BufferHandler,
        onLevel: @escaping LevelHandler,
        onCheckpoint: CheckpointHandler? = nil,
        onError: ErrorHandler? = nil
    ) async throws {
        guard !engine.isRunning, !tapInstalled else { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        engine.reset()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        let settings = Self.recordingSettings(for: format)
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try Self.protectRecording(at: url)
        bufferHandler = onBuffer; levelHandler = onLevel
        checkpointHandler = onCheckpoint
        errorHandler = onError
        checkpointScheduler = CheckpointScheduler(interval: checkpointInterval)
        outputURL = url
        sampleRate = format.sampleRate
        recordedFrames = 0
        let firstBuffer = FirstAudioBufferSignal()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let copy = Self.copy(buffer)
            self.queue.async {
                do {
                    guard let file = self.file else { throw RecorderError.audioFileClosed }
                    try file.write(from: copy)
                    self.stateLock.withLock { self.lastBufferAt = Date() }
                    firstBuffer.succeed()
                } catch {
                    firstBuffer.fail(error)
                    self.errorHandler?(error)
                    return
                }
                self.levelHandler?(Self.measureLevel(in: copy))
                self.recordedFrames += Int64(copy.frameLength)
                let elapsed = Double(self.recordedFrames) / self.sampleRate
                if self.checkpointScheduler.shouldEmit(elapsedTime: elapsed), let outputURL = self.outputURL {
                    self.checkpointHandler?(RecordingCheckpoint(
                        outputURL: outputURL,
                        elapsedTime: elapsed,
                        recordedFrames: self.recordedFrames
                    ))
                }
                self.bufferHandler?(copy)
            }
        }
        tapInstalled = true
        do {
            stateLock.withLock {
                startedAt = Date()
                lastBufferAt = nil
            }
            engine.prepare()
            try engine.start()
            guard engine.isRunning else { throw RecorderError.engineStopped }
            try await firstBuffer.wait(timeout: .seconds(3))
        } catch {
            _ = stop()
            throw error
        }
    }

    @discardableResult public func stop() -> TimeInterval {
        var value = duration
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if engine.isRunning { engine.stop() }
        queue.sync {
            if let outputURL {
                let recordedDuration = sampleRate > 0
                    ? Double(recordedFrames) / sampleRate
                    : value
                value = recordedDuration
                checkpointHandler?(RecordingCheckpoint(
                    outputURL: outputURL,
                    elapsedTime: recordedDuration,
                    recordedFrames: recordedFrames
                ))
            }
            file = nil
            bufferHandler = nil
            levelHandler = nil
            checkpointHandler = nil
            errorHandler = nil
            outputURL = nil
            sampleRate = 0
            recordedFrames = 0
        }
        engine.reset()
        stateLock.withLock {
            startedAt = nil
            lastBufferAt = nil
        }
        return value
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity)!
        result.frameLength = source.frameLength
        let audioBuffers = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        for index in 0..<min(audioBuffers.count, sourceBuffers.count) {
            if let destination = audioBuffers[index].mData, let origin = sourceBuffers[index].mData { memcpy(destination, origin, Int(sourceBuffers[index].mDataByteSize)); audioBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize }
        }
        return result
    }

    private static func measureLevel(in buffer: AVAudioPCMBuffer) -> AudioLevel {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return AudioLevelMeter.measure(samples: [])
        }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return AudioLevelMeter.measure(samples: []) }
            if buffer.format.isInterleaved {
                return AudioLevelMeter.measure(samples: Array(UnsafeBufferPointer(start: data[0], count: frameCount * channelCount)))
            }
            return AudioLevelMeter.measure(samples: (0..<channelCount).flatMap {
                Array(UnsafeBufferPointer(start: data[$0], count: frameCount))
            })
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return AudioLevelMeter.measure(samples: []) }
            let samplesPerChannel = buffer.format.isInterleaved ? frameCount * channelCount : frameCount
            let channels = buffer.format.isInterleaved ? 1 : channelCount
            return AudioLevelMeter.measure(samples: (0..<channels).flatMap { channel in
                UnsafeBufferPointer(start: data[channel], count: samplesPerChannel).map {
                    Float($0) / Float(Int16.max)
                }
            })
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return AudioLevelMeter.measure(samples: []) }
            let samplesPerChannel = buffer.format.isInterleaved ? frameCount * channelCount : frameCount
            let channels = buffer.format.isInterleaved ? 1 : channelCount
            return AudioLevelMeter.measure(samples: (0..<channels).flatMap { channel in
                UnsafeBufferPointer(start: data[channel], count: samplesPerChannel).map {
                    Float(Double($0) / Double(Int32.max))
                }
            })
        default:
            return AudioLevelMeter.measure(samples: [])
        }
    }

    public static func recordingSettings(for format: AVAudioFormat) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        if format.sampleRate >= 32_000 {
            settings[AVEncoderBitRateKey] = 128_000
        }
        return settings
    }
}

public struct RecordingCheckpoint: Codable, Hashable, Sendable {
    public var outputURL: URL
    public var elapsedTime: TimeInterval
    public var recordedFrames: Int64
    public var createdAt: Date

    public init(
        outputURL: URL,
        elapsedTime: TimeInterval,
        recordedFrames: Int64,
        createdAt: Date = Date()
    ) {
        self.outputURL = outputURL
        self.elapsedTime = elapsedTime
        self.recordedFrames = recordedFrames
        self.createdAt = createdAt
    }
}

public enum RecorderError: Error, CustomStringConvertible {
    case alreadyRecording, noMicrophone, engineStopped, noAudioBuffers, audioFileClosed
    public var description: String {
        switch self {
        case .alreadyRecording: "已有课堂正在录音"
        case .noMicrophone: "没有检测到可用麦克风"
        case .engineStopped: "麦克风启动后立即停止，请重新连接或切换输入设备后重试"
        case .noAudioBuffers: "麦克风已启动，但没有收到任何声音数据，请检查系统输入设备后重试"
        case .audioFileClosed: "录音文件已意外关闭"
        }
    }
}

private final class FirstAudioBufferSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let existing = lock.withLock { () -> Result<Void, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let existing { continuation.resume(with: existing) }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.fail(RecorderError.noAudioBuffers)
            }
        }
    }

    func succeed() { resolve(.success(())) }
    func fail(_ error: Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
