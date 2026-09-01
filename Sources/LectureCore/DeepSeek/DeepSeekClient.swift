import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class DeepSeekClient: @unchecked Sendable {
    public static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    public static let model = "deepseek-v4-pro"
    private let keyProvider: DeepSeekAPIKeyProviding
    private let session: URLSession

    public init(keyProvider: DeepSeekAPIKeyProviding = DeepSeekKeychainStore(), session: URLSession = .shared) {
        self.keyProvider = keyProvider; self.session = session
    }

    public func testConnection() async throws -> DeepSeekConnectionStatus {
        _ = try await complete(system: "Reply with only OK.", user: "Connection test", jsonMode: false)
        return .init(isConnected: true, message: "DeepSeek 连接正常")
    }

    public func correctTranslation(englishSegments: [TranscriptSegment], vocabulary: [String]) async throws -> [TranscriptSegment] {
        struct Translation: Decodable { let index: Int; let chinese: String }
        struct Result: Decodable { let translations: [Translation] }
        guard englishSegments.contains(where: \.isFinal) else { throw DeepSeekError.missingTranscript }
        var output: [TranscriptSegment] = []
        for chunk in DeepSeekTranscriptChunker.chunks(from: englishSegments) {
            struct TranslationInput: Encodable { let index: Int; let text: String }
            let inputUnits = chunk.units.enumerated().map { TranslationInput(index: $0.offset, text: $0.element.text) }
            let input = try jsonString(inputUnits)
            var translatedByIndex: [Int: String]?
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    let raw = try await complete(
                        system: "Translate university lecture English into accurate Simplified Chinese. Return every supplied integer index exactly once, unchanged and in order. Return only JSON: {\"translations\":[{\"index\":0,\"chinese\":\"...\"}]}. Course vocabulary: \(vocabulary.joined(separator: ", "))",
                        user: input
                    )
                    let parsed: Result = try DeepSeekResponseParser.decodeJSON(Result.self, from: raw)
                    var candidate: [Int: String] = [:]
                    for value in parsed.translations {
                        guard chunk.units.indices.contains(value.index), candidate[value.index] == nil else {
                            throw DeepSeekError.invalidResponse("翻译序号无效或重复")
                        }
                        let chinese = value.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !chinese.isEmpty else { throw DeepSeekError.invalidResponse("翻译内容为空") }
                        candidate[value.index] = chinese
                    }
                    guard candidate.count == chunk.units.count else {
                        throw DeepSeekError.invalidResponse("翻译结果缺少部分逐字稿单元")
                    }
                    translatedByIndex = candidate
                    break
                } catch {
                    lastError = error
                    if attempt < 2 { try? await Task.sleep(for: .milliseconds(Int64(400 * (attempt + 1)))) }
                }
            }
            guard let translatedByIndex else { throw lastError ?? DeepSeekError.invalidResponse("翻译失败") }
            for (index, unit) in chunk.units.enumerated() {
                guard let chinese = translatedByIndex[index] else {
                    throw DeepSeekError.invalidResponse("翻译结果缺少逐字稿单元")
                }
                output.append(.init(
                    id: "deepseek-zh-\(unit.id)",
                    lectureID: englishSegments.first?.lectureID ?? "",
                    source: .correctedChinese,
                    startTime: unit.startTime,
                    endTime: unit.endTime,
                    text: chinese,
                    isFinal: true,
                    sourceSegmentID: unit.sourceSegmentID
                ))
            }
        }
        return output
    }

    public func generateStudySummary(lectureTitle: String, transcript: [TranscriptSegment]) async throws -> StudySummary {
        guard transcript.contains(where: \.isFinal) else { throw DeepSeekError.missingTranscript }
        let chunks = DeepSeekTranscriptChunker.chunks(from: transcript)
        if chunks.count <= 1 {
            let text = transcript.map { "[\(format($0.startTime))] \($0.text)" }.joined(separator: "\n")
            return try DeepSeekResponseParser.studySummary(from: await complete(system: summaryPrompt, user: "Lecture: \(lectureTitle)\n\n\(text)"))
        }
        var partials: [StudySummary] = []
        for chunk in chunks {
            let text = chunk.units.map { "[\(format($0.startTime))] \($0.text)" }.joined(separator: "\n")
            partials.append(try DeepSeekResponseParser.studySummary(from: await complete(system: summaryPrompt, user: "Lecture: \(lectureTitle), partial transcript\n\n\(text)")))
        }
        return try DeepSeekResponseParser.studySummary(from: await complete(system: summaryPrompt + " Merge the partial summaries without repetition.", user: try jsonString(partials)))
    }

    public func answer(question: String, evidence: [GroundingEvidence]) async throws -> GroundedAnswer {
        guard !evidence.isEmpty else { return .init(text: "本地课堂记录中没有找到足够证据。", citations: [], foundEvidence: false) }
        let prompt = "Answer only from the supplied evidence. The question may be Chinese while evidence is English. If insufficient, say so. Cite only evidence IDs. Return JSON: {\"answer\":\"...\",\"foundEvidence\":true,\"citedEvidenceIDs\":[\"ev-id\"]}."
        let chunks = evidence.chunked(maximum: 120)
        if chunks.count == 1 {
            let raw = try await complete(system: prompt, user: "Question: \(question)\nEvidence:\n" + (try jsonString(evidence)))
            return try DeepSeekResponseParser.groundedAnswer(from: raw, evidence: evidence)
        }
        var candidates: [GroundingEvidence] = []
        for chunk in chunks {
            let raw = try await complete(system: prompt, user: "Question: \(question)\nEvidence chunk:\n" + (try jsonString(chunk)))
            let partial = try DeepSeekResponseParser.groundedAnswer(from: raw, evidence: chunk)
            let ids = Set(partial.citations.compactMap(\.segmentID))
            candidates.append(contentsOf: chunk.filter { ids.contains($0.segmentID) })
        }
        let unique = Array(Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) }).values)
        guard !unique.isEmpty else { return .init(text: "本地课堂记录中没有找到足够证据。", citations: [], foundEvidence: false) }
        let raw = try await complete(system: prompt, user: "Question: \(question)\nCandidate evidence:\n" + (try jsonString(unique)))
        return try DeepSeekResponseParser.groundedAnswer(from: raw, evidence: unique)
    }

    private func complete(system: String, user: String, jsonMode: Bool = true) async throws -> String {
        guard let key = try keyProvider.loadAPIKey(), !key.isEmpty else { throw DeepSeekError.missingAPIKey }
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable { let model: String; let messages: [Message]; let stream: Bool; let thinking: Thinking; let responseFormat: ResponseFormat?; enum CodingKeys: String, CodingKey { case model, messages, stream, thinking; case responseFormat = "response_format" }; struct Thinking: Encodable { let type: String }; struct ResponseFormat: Encodable { let type: String } }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(Request(model: Self.model, messages: [.init(role: "system", content: system), .init(role: "user", content: user)], stream: false, thinking: .init(type: "disabled"), responseFormat: jsonMode ? .init(type: "json_object") : nil))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse("没有 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else { throw DeepSeekError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "未知错误") }
        struct Envelope: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message; let finishReason: String?; enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" } }; let choices: [Choice] }
        do {
            let value = try JSONDecoder().decode(Envelope.self, from: data)
            guard let choice = value.choices.first else { throw DeepSeekError.invalidResponse("没有内容") }
            guard choice.finishReason != "length" else { throw DeepSeekError.invalidResponse("输出被截断，请重试") }
            let content = choice.message.content
            return content
        } catch let error as DeepSeekError { throw error }
        catch { throw DeepSeekError.invalidResponse(String(describing: error)) }
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String { String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "[]" }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    private var summaryPrompt: String {
        "Create a faithful Chinese study summary from the transcript. Do not invent facts. Return only JSON with keys overview, coreConcepts, definitions, professorExamples, professorEmphasis, possibleExamTopics, unresolvedQuestions, glossary. glossary items use english, chinese, explanation. Possible exam topics are suggestions, not claims."
    }
}

private extension Array {
    func chunked(maximum: Int) -> [[Element]] {
        guard maximum > 0 else { return [self] }
        return stride(from: 0, to: count, by: maximum).map { start in
            Array(self[start..<Swift.min(start + maximum, count)])
        }
    }
}
