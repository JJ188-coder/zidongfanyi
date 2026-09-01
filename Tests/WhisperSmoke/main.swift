import Foundation
import LectureCore
import LectureSpeech

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: LectureWhisperSmoke AUDIO [VOCABULARY...]\n", stderr)
    exit(64)
}

let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
let vocabulary = CommandLine.arguments.count >= 3
    ? Array(CommandLine.arguments.dropFirst(2))
    : []

do {
    let segments = try WhisperCLI().transcribeAudioFile(
        audioURL: audioURL,
        lectureID: "whisper-smoke",
        source: .reviewedEnglish,
        vocabulary: vocabulary
    )
    print("segments=\(segments.count)")
    for segment in segments {
        print(String(format: "[%06.2f-%06.2f] %@", segment.startTime, segment.endTime, segment.text))
    }
    exit(segments.isEmpty ? 2 : 0)
} catch {
    fputs("whisper-smoke-error=\(SecretRedactor.redact(String(describing: error)))\n", stderr)
    exit(1)
}
