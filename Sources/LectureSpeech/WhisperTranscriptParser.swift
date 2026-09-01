import Foundation
import LectureCore

public struct WhisperTranscriptItem: Decodable, Hashable, Sendable {
    public struct Offsets: Decodable, Hashable, Sendable {
        public let from: Int
        public let to: Int
    }

    public let offsets: Offsets
    public let text: String
}

public enum WhisperTranscriptParser {
    private struct Envelope: Decodable {
        let transcription: [WhisperTranscriptItem]
    }

    public static func parse(_ data: Data) throws -> [WhisperTranscriptItem] {
        try JSONDecoder().decode(Envelope.self, from: data).transcription
    }

    public static func segments(
        from items: [WhisperTranscriptItem],
        lectureID: String,
        source: TranscriptSource,
        timeOffset: TimeInterval = 0,
        maximumDuration: TimeInterval? = nil
    ) -> [TranscriptSegment] {
        items.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNonSpeech(text), !isKnownHallucination(text) else { return nil }
            let localStart = max(0, Double(item.offsets.from) / 1_000)
            let reportedEnd = max(localStart, Double(item.offsets.to) / 1_000)
            let localEnd = maximumDuration.map { min(reportedEnd, max(localStart, $0)) }
                ?? reportedEnd
            return TranscriptSegment(
                lectureID: lectureID,
                source: source,
                startTime: timeOffset + localStart,
                endTime: timeOffset + localEnd,
                text: text,
                isFinal: true
            )
        }
    }

    private static func isNonSpeech(_ text: String) -> Bool {
        let value = text.uppercased().replacingOccurrences(of: " ", with: "_")
        return ["[BLANK_AUDIO]", "[SILENCE]", "(SILENCE)", "[MUSIC]"].contains(value)
    }

    private static func isKnownHallucination(_ text: String) -> Bool {
        let value = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let exact = [
            "thank you for watching",
            "thanks for watching",
            "please subscribe",
            "subtitles by amara org",
        ]
        if exact.contains(value) { return true }
        let words = value.split(whereSeparator: \.isWhitespace)
        if words.count == 1, let word = words.first, word.count <= 3 { return true }
        if words.count <= 3, Set(words).count == 1 { return true }
        return false
    }
}
