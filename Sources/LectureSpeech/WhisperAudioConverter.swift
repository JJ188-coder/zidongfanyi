@preconcurrency import AVFoundation
import Foundation

public final class WhisperAudioConverter: @unchecked Sendable {
    public enum ConversionError: Error, CustomStringConvertible {
        case unsupportedFormat
        case unableToAllocateBuffer
        case failed(AVAudioConverterOutputStatus)

        public var description: String {
            switch self {
            case .unsupportedFormat: "无法把麦克风音频转换为本地识别格式"
            case .unableToAllocateBuffer: "无法分配本地识别音频缓冲区"
            case .failed: "麦克风音频转换失败"
            }
        }
    }

    public static let sampleRate = 16_000.0
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()

    public init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat = targetFormat) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ConversionError.unsupportedFormat
        }
        self.converter = converter
        self.targetFormat = targetFormat
    }

    public func convert(_ source: AVAudioPCMBuffer) throws -> [Int16] {
        try lock.withLock {
            converter.reset()
            let ratio = targetFormat.sampleRate / source.format.sampleRate
            let capacity = max(
                1,
                AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 64
            )
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else {
                throw ConversionError.unableToAllocateBuffer
            }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            if let conversionError { throw conversionError }
            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                guard output.frameLength > 0, let channel = output.int16ChannelData?[0] else {
                    return []
                }
                return Array(
                    UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
                )
            case .error:
                throw ConversionError.failed(status)
            @unknown default:
                throw ConversionError.failed(status)
            }
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
