@preconcurrency import AVFoundation
import Foundation
import LectureCore
import LectureSpeech

final class SmokeState: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [TranscriptSegment] = []
    private var errors: [String] = []

    func append(_ segment: TranscriptSegment) {
        lock.withLock { segments.append(segment) }
    }

    func append(_ error: Error) {
        lock.withLock { errors.append(SecretRedactor.redact(String(describing: error))) }
    }

    func snapshot() -> ([TranscriptSegment], [String]) {
        lock.withLock { (segments, errors) }
    }
}

@main
struct LiveWhisperSmoke {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: LectureLiveWhisperSmoke AUDIO [VOCABULARY...]\n", stderr)
            exit(64)
        }
        do {
            let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let vocabulary = CommandLine.arguments.count >= 3
                ? Array(CommandLine.arguments.dropFirst(2))
                : []
            let file = try AVAudioFile(forReading: audioURL)
            let transcriber = LiveSpeechTranscriber(vocabulary: vocabulary)
            let state = SmokeState()
            try await transcriber.start(
                lectureID: "live-whisper-smoke",
                audioFormat: file.processingFormat,
                handler: { state.append($0.segment) },
                onError: { state.append($0) }
            )
            let frameCount: AVAudioFrameCount = 2_048
            while file.framePosition < file.length {
                let requested = min(
                    frameCount,
                    AVAudioFrameCount(file.length - file.framePosition)
                )
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: requested
                ) else { break }
                try file.read(into: buffer, frameCount: requested)
                transcriber.append(buffer)
            }
            await transcriber.finish()
            let result = state.snapshot()
            print("segments=\(result.0.count) errors=\(result.1.count)")
            for segment in result.0 {
                print(String(
                    format: "[%06.2f-%06.2f] %@",
                    segment.startTime,
                    segment.endTime,
                    segment.text
                ))
            }
            if let error = result.1.first {
                fputs("live-whisper-smoke-error=\(error)\n", stderr)
                exit(1)
            }
            exit(result.0.isEmpty ? 2 : 0)
        } catch {
            fputs("live-whisper-smoke-error=\(SecretRedactor.redact(String(describing: error)))\n", stderr)
            exit(1)
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
