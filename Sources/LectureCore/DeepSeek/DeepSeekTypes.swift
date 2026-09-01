import Foundation

public struct DeepSeekConnectionStatus: Codable, Sendable {
    public let isConnected: Bool
    public let message: String
    public init(isConnected: Bool, message: String) { self.isConnected = isConnected; self.message = message }
}

public struct DeepSeekChunkPolicy: Sendable {
    public var maxCharacters: Int
    public var maxDuration: TimeInterval
    public init(maxCharacters: Int = 10_000, maxDuration: TimeInterval = 900) { self.maxCharacters = maxCharacters; self.maxDuration = maxDuration }
}

public struct DeepSeekTranscriptUnit: Codable, Hashable, Sendable {
    public var id: String
    public var sourceSegmentID: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
}

public struct DeepSeekTranscriptChunk: Codable, Hashable, Sendable {
    public var units: [DeepSeekTranscriptUnit]
}

public enum DeepSeekTranscriptChunker {
    public static func chunks(from segments: [TranscriptSegment], policy: DeepSeekChunkPolicy = .init()) -> [DeepSeekTranscriptChunk] {
        var units: [DeepSeekTranscriptUnit] = []
        for segment in segments where segment.isFinal {
            let sentences = splitSentences(segment.text)
            for (offset, sentence) in sentences.enumerated() {
                units.append(.init(id: "\(segment.id)-\(offset)", sourceSegmentID: segment.id, startTime: segment.startTime, endTime: segment.endTime, text: sentence))
            }
        }
        var result: [DeepSeekTranscriptChunk] = []
        var current: [DeepSeekTranscriptUnit] = []
        for unit in units {
            let characters = current.reduce(0) { $0 + $1.text.count } + unit.text.count
            let duration = max(current.first?.startTime ?? unit.startTime, unit.endTime) - min(current.first?.startTime ?? unit.startTime, unit.startTime)
            if !current.isEmpty && (characters > policy.maxCharacters || duration > policy.maxDuration) { result.append(.init(units: current)); current = [] }
            current.append(unit)
        }
        if !current.isEmpty { result.append(.init(units: current)) }
        return result
    }

    private static func splitSentences(_ value: String) -> [String] {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let regex = try! NSRegularExpression(pattern: #"[^.!?。！？]+[.!?。！？]?"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
    }
}

public struct GroundingEvidence: Codable, Hashable, Sendable {
    public var id: String
    public var lectureID: String
    public var lectureTitle: String
    public var segmentID: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public init(id: String, lectureID: String, lectureTitle: String, segmentID: String, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id; self.lectureID = lectureID; self.lectureTitle = lectureTitle; self.segmentID = segmentID; self.startTime = startTime; self.endTime = endTime; self.text = text
    }
}

public enum GroundingEvidenceFactory {
    public static func make(
        lecture: LectureRecord,
        segments: [TranscriptSegment]
    ) -> [GroundingEvidence] {
        segments.filter(\.isFinal).map { segment in
            GroundingEvidence(
                id: segment.id,
                lectureID: lecture.id,
                lectureTitle: lecture.title,
                segmentID: segment.id,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text
            )
        }
    }
}

public struct GroundedAnswer: Codable, Sendable {
    public var text: String
    public var citations: [Citation]
    public var foundEvidence: Bool
}

public enum DeepSeekError: Error, CustomStringConvertible {
    case missingAPIKey
    case missingTranscript
    case invalidResponse(String)
    case http(Int, String)
    case unsupportedCitation(String)
    public var description: String {
        switch self {
        case .missingAPIKey: return "请先在设置中保存当前 AI 服务的 API Key"
        case .missingTranscript: return "没有可用于课后处理的英文逐字稿"
        case .invalidResponse(let message): return "AI 服务返回格式异常：" + SecretRedactor.redact(message)
        case .http(let code, let message): return "AI 服务请求失败（\(code)）：" + SecretRedactor.redact(message)
        case .unsupportedCitation(let id): return "AI 服务返回了不存在的引用：" + id
        }
    }
}

public enum DeepSeekResponseParser {
    public static func studySummary(from raw: String) throws -> StudySummary {
        struct FlexibleSummary: Decodable {
            let overview: String
            let coreConcepts: FlexibleStringList
            let definitions: FlexibleStringList
            let professorExamples: FlexibleStringList
            let professorEmphasis: FlexibleStringList
            let possibleExamTopics: FlexibleStringList
            let unresolvedQuestions: FlexibleStringList
            let glossary: FlexibleGlossary
        }
        let value = try decodeJSON(FlexibleSummary.self, from: raw)
        return StudySummary(
            overview: value.overview,
            coreConcepts: value.coreConcepts.values,
            definitions: value.definitions.values,
            professorExamples: value.professorExamples.values,
            professorEmphasis: value.professorEmphasis.values,
            possibleExamTopics: value.possibleExamTopics.values,
            unresolvedQuestions: value.unresolvedQuestions.values,
            glossary: value.glossary.values
        )
    }

    public static func groundedAnswer(from raw: String, evidence: [GroundingEvidence]) throws -> GroundedAnswer {
        struct Payload: Decodable { let answer: String; let foundEvidence: Bool; let citedEvidenceIDs: [String] }
        let payload = try decodeJSON(Payload.self, from: raw)
        let map = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        let citations = try payload.citedEvidenceIDs.map { id -> Citation in
            guard let item = map[id] else { throw DeepSeekError.unsupportedCitation(id) }
            return Citation(lectureID: item.lectureID, lectureTitle: item.lectureTitle, startTime: item.startTime, segmentID: item.segmentID)
        }
        guard payload.foundEvidence == !citations.isEmpty else { throw DeepSeekError.invalidResponse("证据状态与引用不一致") }
        return GroundedAnswer(text: payload.answer, citations: citations, foundEvidence: payload.foundEvidence)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = cleaned.data(using: .utf8) else { throw DeepSeekError.invalidResponse("不是 UTF-8 文本") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DeepSeekError.invalidResponse(String(describing: error)) }
    }
}

private struct FlexibleStringList: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { values = []; return }
        if let array = try? container.decode([String].self) {
            values = array
            return
        }
        if let dictionary = try? container.decode([String: String].self) {
            values = dictionary.keys.sorted().map { key in
                let value = dictionary[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? key : "\(key)：\(value)"
            }
            return
        }
        if let dictionaries = try? container.decode([[String: String]].self) {
            values = dictionaries.flatMap { dictionary in
                dictionary.keys.sorted().compactMap { key in
                    let value = dictionary[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !key.isEmpty || !value.isEmpty else { return nil }
                    return value.isEmpty ? key : "\(key)：\(value)"
                }
            }
            return
        }
        if let numbers = try? container.decode([Double].self) {
            values = numbers.map { String($0) }
            return
        }
        if let dictionary = try? container.decode([String: FlexibleScalar].self) {
            values = dictionary.keys.sorted().compactMap { key in
                let value = dictionary[key]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !key.isEmpty || !value.isEmpty else { return nil }
                return value.isEmpty ? key : "\(key)：\(value)"
            }
            return
        }
        if let string = try? container.decode(String.self) {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            values = value.isEmpty ? [] : [value]
            return
        }
        throw DecodingError.typeMismatch(
            [String].self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected an array, dictionary, string, or null")
        )
    }
}

private struct FlexibleScalar: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { text = ""; return }
        if let string = try? container.decode(String.self) { text = string; return }
        if let number = try? container.decode(Double.self) { text = String(number); return }
        if let boolean = try? container.decode(Bool.self) { text = String(boolean); return }
        throw DecodingError.typeMismatch(
            String.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected a scalar value")
        )
    }
}

private struct FlexibleGlossary: Decodable {
    let values: [GlossaryTerm]

    private struct FlexibleTerm: Decodable {
        let english: String
        let chinese: String
        let explanation: String

        private enum CodingKeys: String, CodingKey {
            case english, term, word, chinese, translation, meaning, explanation, definition
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            english = try container.decodeIfPresent(String.self, forKey: .english)
                ?? (try container.decodeIfPresent(String.self, forKey: .term))
                ?? (try container.decodeIfPresent(String.self, forKey: .word))
                ?? ""
            chinese = try container.decodeIfPresent(String.self, forKey: .chinese)
                ?? (try container.decodeIfPresent(String.self, forKey: .translation))
                ?? (try container.decodeIfPresent(String.self, forKey: .meaning))
                ?? ""
            explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
                ?? (try container.decodeIfPresent(String.self, forKey: .definition))
                ?? ""
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { values = []; return }
        if let array = try? container.decode([GlossaryTerm].self) {
            values = array
            return
        }
        if let dictionary = try? container.decode([String: String].self) {
            values = dictionary.keys.sorted().map {
                GlossaryTerm(english: $0, chinese: dictionary[$0] ?? "")
            }
            return
        }
        if let terms = try? container.decode([FlexibleTerm].self) {
            values = terms.compactMap { term in
                guard !term.english.isEmpty || !term.chinese.isEmpty else { return nil }
                return GlossaryTerm(
                    english: term.english,
                    chinese: term.chinese,
                    explanation: term.explanation
                )
            }
            return
        }
        throw DecodingError.typeMismatch(
            [GlossaryTerm].self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected a glossary array, dictionary, or null")
        )
    }
}
