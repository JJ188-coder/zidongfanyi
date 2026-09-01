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

    public static func createEmptyFile(
        at url: URL,
        sampleRate: Int = Int(WhisperAudioConverter.sampleRate),
        fileManager: FileManager = .default
    ) throws -> FileHandle {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: header(payloadBytes: 0, sampleRate: sampleRate))
        return handle
    }

    public static func append(samples: [Int16], to handle: FileHandle) throws {
        try samples.withUnsafeBytes { bytes in
            try handle.write(contentsOf: Data(bytes))
        }
    }

    public static func finalize(
        _ handle: FileHandle,
        sampleCount: Int64,
        sampleRate: Int = Int(WhisperAudioConverter.sampleRate)
    ) throws {
        let payload = sampleCount.multipliedReportingOverflow(by: 2)
        guard !payload.overflow, payload.partialValue >= 0, payload.partialValue <= Int64(UInt32.max) - 36 else {
            throw WAVError.tooManySamples
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(payloadBytes: Int(payload.partialValue), sampleRate: sampleRate))
        try handle.synchronize()
        try handle.close()
    }

    private static func header(payloadBytes: Int, sampleRate: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payloadBytes), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payloadBytes), to: &data)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
