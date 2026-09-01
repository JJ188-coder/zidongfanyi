import Foundation

public enum LectureMarkdownExporter {
    public static func render(
        course: Course,
        lecture: LectureRecord,
        transcripts: [TranscriptSegment],
        markers: [LectureMarker],
        summaries: [SummaryVersion]
    ) -> String {
        var lines: [String] = [
            "# \(safe(lecture.title))",
            "",
            "- 课程：\(safe(course.name))",
            "- 课程代码：\(safe(course.code ?? "未填写"))",
            "- 教授：\(safe(course.professor.isEmpty ? "未填写" : course.professor))",
            "- 课堂时间：\(ISO8601DateFormatter().string(from: lecture.startedAt))",
            "- 时长：\(timestamp(lecture.duration))",
        ]

        lines += ["", "## 学习总结", ""]
        if let summary = summaries.max(by: { $0.createdAt < $1.createdAt })?.content {
            lines.append(summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无" : safe(summary.overview))
            appendList(title: "核心概念", values: summary.coreConcepts, to: &lines)
            appendList(title: "定义", values: summary.definitions, to: &lines)
            appendList(title: "教授举例", values: summary.professorExamples, to: &lines)
            appendList(title: "教授强调", values: summary.professorEmphasis, to: &lines)
            appendList(title: "可能的复习方向", values: summary.possibleExamTopics, to: &lines)
            appendList(title: "仍待解决的问题", values: summary.unresolvedQuestions, to: &lines)
            appendGlossary(summary.glossary, to: &lines)
        } else {
            lines.append("暂无")
            for title in ["核心概念", "定义", "教授举例", "教授强调", "可能的复习方向", "仍待解决的问题"] {
                appendList(title: title, values: [], to: &lines)
            }
            appendGlossary([], to: &lines)
        }

        lines += ["", "## 课堂重点", ""]
        if markers.isEmpty { lines.append("- 无") }
        else {
            for marker in markers.sorted(by: { $0.time < $1.time }) {
                lines.append("- [\(timestamp(marker.time))] \(safe(marker.label))")
            }
        }

        appendTranscript(
            title: "英文逐字稿",
            segments: preferredEnglish(from: transcripts),
            to: &lines
        )
        appendTranscript(
            title: "中文翻译",
            segments: preferredChinese(from: transcripts),
            to: &lines
        )
        lines += ["", "---", "由 Lecture 在本机导出；原始录音未嵌入此文件。", ""]
        return SecretRedactor.redact(lines.joined(separator: "\n"))
    }

    private static func preferredEnglish(from transcripts: [TranscriptSegment]) -> [TranscriptSegment] {
        let live = transcripts.filter { $0.source == .liveEnglish }
        let reviewed = transcripts.filter { $0.source == .reviewedEnglish && $0.isFinal }
        return TranscriptPreference.english(live: live, reviewed: reviewed)
    }

    private static func preferredChinese(from transcripts: [TranscriptSegment]) -> [TranscriptSegment] {
        let preferredEnglish = preferredEnglish(from: transcripts)
        let live = transcripts.filter { $0.source == .liveChinese }
        let corrected = transcripts.filter { $0.source == .correctedChinese && $0.isFinal }
        return TranscriptPreference.chinese(live: live, corrected: corrected, preferredEnglish: preferredEnglish)
    }

    private static func appendTranscript(
        title: String,
        segments: [TranscriptSegment],
        to lines: inout [String]
    ) {
        lines += ["", "## \(title)", ""]
        if segments.isEmpty { lines.append("暂无"); return }
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            lines.append("[\(timestamp(segment.startTime))] \(safe(segment.text))")
            lines.append("")
        }
    }

    private static func appendList(title: String, values: [String], to lines: inout [String]) {
        lines += ["", "### \(title)", ""]
        lines += values.isEmpty ? ["暂无"] : values.map { "- \(safe($0))" }
    }

    private static func appendGlossary(_ glossary: [GlossaryTerm], to lines: inout [String]) {
        lines += ["", "### 双语术语表", ""]
        if glossary.isEmpty {
            lines.append("暂无")
            return
        }
        for term in glossary {
            let explanation = term.explanation.isEmpty ? "" : " — \(safe(term.explanation))"
            lines.append("- **\(safe(term.english))**：\(safe(term.chinese))\(explanation)")
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private static func safe(_ value: String) -> String {
        SecretRedactor.redact(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
