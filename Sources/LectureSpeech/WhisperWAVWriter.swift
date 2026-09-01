import Foundation

public enum WhisperWAVWriter {
    public enum WAVError: Error, CustomStringConvertible {
        case tooManySamples

        public var description: String { "本地识别音频片段过长" }
    }

    public static func data(
        samples: [Int16],
        sampleRate: Int = Int(WhisperAudioConverter.sampleRate)
    ) throws -> Data {
        let payloadBytes = samples.count.multipliedReportingOverflow(by: 2)
        guard !payloadBytes.overflow, payloadBytes.partialValue <= Int(UInt32.max) - 36 else {
            throw WAVError.tooManySamples
        }

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payloadBytes.partialValue), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payloadBytes.partialValue), to: &data)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
