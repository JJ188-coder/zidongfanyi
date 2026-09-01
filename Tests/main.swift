import Foundation
import LectureCore
import LectureServer

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    guard try condition() else { throw TestFailure(description: message) }
    return true
}

func testDomainModels() throws {
    let course = Course(id: "course-1", name: "Microeconomic Theory", code: "ECON-UA 11", professor: "David Miller", semester: "Fall 2026", vocabulary: ["indifference curve"])
    let lecture = LectureRecord(id: "lecture-1", courseID: course.id, title: "Consumer Choice", status: .completed)
    let segment = TranscriptSegment(id: "segment-1", lectureID: lecture.id, source: .reviewedEnglish, startTime: 12.5, endTime: 18, text: "Marginal rate of substitution", confidence: 0.82, isFinal: true)
    try expect(!(try JSONEncoder().encode(course)).isEmpty, "course should encode")
    let legacyCourse = try JSONDecoder().decode(Course.self, from: Data(#"{"id":"legacy","name":"Legacy","professor":"Professor","vocabulary":[],"createdAt":0,"updatedAt":0}"#.utf8))
    try expect(legacyCourse.speechLocaleIdentifier == "en-US", "legacy courses should default to US English")
    try expect(!(try JSONEncoder().encode(lecture)).isEmpty, "lecture should encode")
    try expect(!(try JSONEncoder().encode(segment)).isEmpty, "segment should encode")
    try expect(!segment.isLowConfidence, "0.82 should not be low confidence")
    let low = TranscriptSegment(id: "s", lectureID: "l", source: .liveEnglish, startTime: 0, endTime: 1, text: "uncertain", confidence: 0.54, isFinal: true)
    try expect(low.isLowConfidence, "0.54 should be low confidence")
    let quality = TranscriptQuality(segments: [segment, low])
    try expect(quality.segmentCount == 2 && quality.scoredSegmentCount == 2, "quality should count final scored segments")
    try expect(quality.lowConfidenceCount == 1 && quality.lowConfidenceRate == 0.5, "quality should expose low-confidence rate")
    try expect(LectureStatus.recording.canTransition(to: .reviewingEnglish), "recording should transition to review")
    try expect(!LectureStatus.completed.canTransition(to: .recording), "completed must not restart")
    try expect(LectureStatus.completed.canTransition(to: .processingDeepSeek), "completed local transcripts should allow later DeepSeek enrichment")
    let redacted = SecretRedactor.redact("Authorization: Bearer sk-example-secret and api_key=sk-second-secret")
    try expect(!redacted.contains("sk-example-secret") && redacted.contains("[REDACTED]"), "secret redaction")
    let strict = SecretRedactor.redact(#"{\"api_key\":\"not-prefixed-secret-value\"} DEEPSEEK_API_KEY=plain-secret Authorization: Bearer opaque-token"#)
    try expect(!strict.contains("not-prefixed-secret-value"), "JSON API key should be redacted")
    try expect(!strict.contains("plain-secret"), "environment API key should be redacted")
    try expect(!strict.contains("opaque-token"), "bearer token should be redacted")
}

func testTranscriptPreference() throws {
    let live = (0..<10).map { index in
        TranscriptSegment(id: "live-\(index)", lectureID: "lecture", source: .liveEnglish, startTime: Double(index * 6), endTime: Double(index * 6 + 6), text: String(repeating: "reliable classroom words ", count: 5), isFinal: true)
    }
    let sparseReview = (0..<4).map { index in
        TranscriptSegment(id: "review-\(index)", lectureID: "lecture", source: .reviewedEnglish, startTime: Double(index * 15), endTime: Double(index * 15 + 1), text: "Yes.", isFinal: true)
    }
    try expect(TranscriptPreference.english(live: live, reviewed: sparseReview) == live, "a sparse review must not replace a richer live transcript")
    let completeReview = live.map { segment in
        TranscriptSegment(id: "reviewed-" + segment.id, lectureID: segment.lectureID, source: .reviewedEnglish, startTime: segment.startTime, endTime: segment.endTime, text: segment.text + " reviewed", isFinal: true)
    }
    try expect(TranscriptPreference.english(live: live, reviewed: completeReview) == completeReview, "a complete review should remain preferred")
    let liveChinese = live.map { segment in
        TranscriptSegment(id: "zh-" + segment.id, lectureID: segment.lectureID, source: .liveChinese, startTime: segment.startTime, endTime: segment.endTime, text: "实时翻译", isFinal: true, sourceSegmentID: segment.id)
    }
    let partialCorrected = [TranscriptSegment(id: "corrected-one", lectureID: "lecture", source: .correctedChinese, startTime: 0, endTime: 6, text: "局部校正", isFinal: true, sourceSegmentID: live[0].id)]
    try expect(TranscriptPreference.chinese(live: liveChinese, corrected: partialCorrected, preferredEnglish: live) == liveChinese, "partial AI translation must not replace a complete live translation")
}

func testAppPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = AppPaths(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.createDirectories()
    for directory in [paths.root, paths.recordings, paths.exports, paths.working, paths.speechModels, paths.whisper, paths.whisperWorking] {
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o700, "private app directory should use owner-only permissions")
    }
    try Data([1]).write(to: paths.database)
    try Data([2]).write(to: paths.database.appendingPathExtension("wal"))
    try Data([3]).write(to: paths.database.appendingPathExtension("shm"))
    let legacyRecording = paths.recordings.appendingPathComponent("legacy-recording.m4a")
    try Data("legacy".utf8).write(to: legacyRecording)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacyRecording.path)
    try Data([4]).write(to: paths.whisperVADModel)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.whisperVADModel.path)
    try Data([5]).write(to: paths.whisperQualityModel)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.whisperQualityModel.path)
    try paths.createDirectories()
    for file in [paths.database, paths.database.appendingPathExtension("wal"), paths.database.appendingPathExtension("shm")] {
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "database files should use owner-only permissions")
    }
    let recordingPermissions = try FileManager.default.attributesOfItem(atPath: legacyRecording.path)[.posixPermissions] as? NSNumber
    try expect(recordingPermissions?.intValue == 0o600, "existing recordings should be migrated to owner-only permissions")
    let vadPermissions = try FileManager.default.attributesOfItem(atPath: paths.whisperVADModel.path)[.posixPermissions] as? NSNumber
    try expect(vadPermissions?.intValue == 0o600, "the local VAD model should use owner-only permissions")
    let qualityModelPermissions = try FileManager.default.attributesOfItem(atPath: paths.whisperQualityModel.path)[.posixPermissions] as? NSNumber
    try expect(qualityModelPermissions?.intValue == 0o600, "the higher-quality Whisper model should use owner-only permissions")
    try expect(paths.audioURL(lectureID: "unsafe/id").lastPathComponent == "unsafe-id.m4a", "recording paths should sanitize identifiers")

    try Data([1, 2, 3, 4]).write(to: paths.exports.appendingPathComponent("notes.md"))
    let outsideRecording = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
    defer { try? FileManager.default.removeItem(at: outsideRecording) }
    try Data(repeating: 9, count: 40_000).write(to: outsideRecording)
    try FileManager.default.createSymbolicLink(
        at: paths.recordings.appendingPathComponent("linked-recording.m4a"),
        withDestinationURL: outsideRecording
    )
    let usage = try paths.storageUsage()
    try expect(usage.totalBytes >= 10, "storage diagnostics should count local database, recording, and export bytes")
    try expect(usage.recordingCount == 1, "storage diagnostics should count only regular recording files")
    try expect(usage.recordingBytes < 40_000, "storage diagnostics must skip linked recordings outside the app directory")
    try expect(usage.databaseBytes > 0 && usage.exportBytes > 0, "storage diagnostics should classify database and export bytes")
}

func testLectureMarkdownExport() throws {
    let course = Course(id: "export-course", name: "Microeconomics", code: "ECON-1", professor: "Professor Example")
    let lecture = LectureRecord(id: "export-lecture", courseID: course.id, title: "Consumer Choice", status: .completed, duration: 95)
    let transcripts = [
        TranscriptSegment(id: "en", lectureID: lecture.id, source: .reviewedEnglish, startTime: 12, endTime: 18, text: "The budget constraint matters.", isFinal: true),
        TranscriptSegment(id: "zh", lectureID: lecture.id, source: .correctedChinese, startTime: 12, endTime: 18, text: "预算约束很重要。", isFinal: true, sourceSegmentID: "en"),
    ]
    let olderSummary = SummaryVersion(
        lectureID: lecture.id,
        createdAt: Date(timeIntervalSince1970: 1),
        content: StudySummary(overview: "旧版本摘要")
    )
    let summary = SummaryVersion(
        lectureID: lecture.id,
        createdAt: Date(timeIntervalSince1970: 2),
        content: StudySummary(
            overview: "消费者在约束下选择。",
            coreConcepts: ["Budget constraint"],
            definitions: ["预算约束描述可负担的选择。"],
            professorExamples: ["咖啡与茶的选择。"],
            professorEmphasis: ["斜率代表相对价格。"],
            possibleExamTopics: ["画出预算线。"],
            unresolvedQuestions: ["收入效应如何变化？"],
            glossary: [GlossaryTerm(english: "budget constraint", chinese: "预算约束", explanation: "可负担集合的边界")]
        )
    )
    let markdown = LectureMarkdownExporter.render(
        course: course,
        lecture: lecture,
        transcripts: transcripts,
        markers: [LectureMarker(lectureID: lecture.id, time: 14, label: "考试重点")],
        summaries: [olderSummary, summary]
    )
    try expect(markdown.contains("# Consumer Choice") && markdown.contains("Professor Example"), "export should identify the lecture and course")
    try expect(markdown.contains("[00:12]") && markdown.contains("The budget constraint matters.") && markdown.contains("预算约束很重要。"), "export should preserve bilingual timestamp evidence")
    try expect(markdown.contains("考试重点") && markdown.contains("消费者在约束下选择。") && markdown.contains("预算约束"), "export should include markers and the latest study summary")
    try expect(!markdown.contains("旧版本摘要") && markdown.contains("咖啡与茶的选择。") && markdown.contains("收入效应如何变化？"), "export should include every latest-summary section and exclude older versions")
    try expect(!markdown.lowercased().contains("api key") && !markdown.contains("sk-"), "export must never contain credentials")

    let secretLecture = LectureRecord(id: "secret-export", courseID: course.id, title: "Token sk-test-export-secret-123456789", status: .completed)
    let redacted = LectureMarkdownExporter.render(course: course, lecture: secretLecture, transcripts: [], markers: [], summaries: [])
    try expect(redacted.contains("[REDACTED]") && !redacted.contains("sk-test-export-secret"), "the final Markdown artifact should redact credentials from all stored fields")

    let draftPreferredSources = [
        TranscriptSegment(id: "live-final", lectureID: lecture.id, source: .liveEnglish, startTime: 1, endTime: 2, text: "Final live fallback.", isFinal: true),
        TranscriptSegment(id: "review-draft", lectureID: lecture.id, source: .reviewedEnglish, startTime: 1, endTime: 2, text: "Draft review.", isFinal: false),
        TranscriptSegment(id: "live-zh-final", lectureID: lecture.id, source: .liveChinese, startTime: 1, endTime: 2, text: "最终实时中文。", isFinal: true),
        TranscriptSegment(id: "corrected-draft", lectureID: lecture.id, source: .correctedChinese, startTime: 1, endTime: 2, text: "校正草稿。", isFinal: false),
    ]
    let fallback = LectureMarkdownExporter.render(course: course, lecture: lecture, transcripts: draftPreferredSources, markers: [], summaries: [])
    try expect(fallback.contains("Final live fallback.") && fallback.contains("最终实时中文。"), "draft preferred sources must not suppress finalized live transcript fallbacks")
    try expect(fallback.contains("### 核心概念") && fallback.contains("### 双语术语表"), "exports should keep every summary field visible even when there is no summary")
}

func testKeychainStore() throws {
    let service = "com.jiyuanyi.Lecture.Tests." + UUID().uuidString
    let store = DeepSeekKeychainStore(service: service)
    defer { try? store.deleteAPIKey() }

    try expect(try store.loadAPIKey() == nil, "isolated Keychain service should start empty")
    try expect(!store.hasAPIKeyReference(), "missing key should have no item reference")
    try store.saveAPIKey("  sk-test-first-value-123456  ")
    try expect(try store.loadAPIKey() == "sk-test-first-value-123456", "Keychain should trim and load the saved key")
    try expect(store.hasAPIKeyReference(), "saved key should have an item reference")
    try store.saveAPIKey("sk-test-replacement-value-654321")
    try expect(try store.loadAPIKey() == "sk-test-replacement-value-654321", "Keychain save should replace the existing key")
    try store.deleteAPIKey()
    try expect(try store.loadAPIKey() == nil, "Keychain delete should remove the key")
    try expect(!store.hasAPIKeyReference(), "deleted key should remove its item reference")
}

func testTranscriptChunking() throws {
    let segments = [
        TranscriptSegment(id: "s1", lectureID: "lecture-1", source: .reviewedEnglish, startTime: 0, endTime: 20, text: "First sentence. Second sentence.", isFinal: true),
        TranscriptSegment(id: "s2", lectureID: "lecture-1", source: .reviewedEnglish, startTime: 25, endTime: 30, text: "Third sentence.", isFinal: true),
    ]
    let chunks = DeepSeekTranscriptChunker.chunks(
        from: segments,
        policy: DeepSeekChunkPolicy(maxCharacters: 22, maxDuration: 12)
    )
    let units = chunks.flatMap(\.units)
    try expect(units.map(\.text) == ["First sentence.", "Second sentence.", "Third sentence."], "chunking must preserve complete sentences")
    try expect(units.map(\.sourceSegmentID) == ["s1", "s1", "s2"], "chunking must retain source segment identifiers")
    try expect(units[0].startTime == 0 && units[1].endTime == 20, "split sentences should retain the source time range")
    try expect(chunks.count == 3, "character and time limits should create safe boundaries")
}

func testGroundingEvidenceKeepsTheWholeLecture() throws {
    let lecture = LectureRecord(
        id: "lecture-long",
        courseID: "course-long",
        title: "A long lecture",
        status: .completed
    )
    var segments: [TranscriptSegment] = []
    for index in 0..<240 {
        let segment = TranscriptSegment(
            id: "segment-\(index)",
            lectureID: lecture.id,
            source: .reviewedEnglish,
            startTime: Double(index * 5),
            endTime: Double(index * 5 + 4),
            text: index == 239 ? "The final theorem appears here." : "Lecture evidence \(index).",
            isFinal: true
        )
        segments.append(segment)
    }

    let evidence = GroundingEvidenceFactory.make(lecture: lecture, segments: segments)
    try expect(evidence.count == 240, "grounded Q&A must not discard the end of a long lecture")
    try expect(evidence.last?.segmentID == "segment-239", "the final lecture segment must remain retrievable")
}

func testStructuredResponseParsing() throws {
    let summaryJSON = """
    ```json
    {
      "overview": "Consumer choice under scarcity.",
      "coreConcepts": ["Budget constraint"],
      "definitions": ["MRS is the slope of an indifference curve."],
      "professorExamples": ["Coffee and tea"],
      "professorEmphasis": ["Diminishing MRS"],
      "possibleExamTopics": ["Derive the tangency condition"],
      "unresolvedQuestions": ["Corner solutions"],
      "glossary": [{"english":"Marginal rate of substitution","chinese":"边际替代率","explanation":"Trade-off along an indifference curve"}]
    }
    ```
    """
    let summary = try DeepSeekResponseParser.studySummary(from: summaryJSON)
    try expect(summary.overview == "Consumer choice under scarcity.", "summary overview should parse")
    try expect(summary.glossary.first?.chinese == "边际替代率", "summary glossary should parse")

    let flexibleSummary = try DeepSeekResponseParser.studySummary(from: #"{"overview":"Demand comparison","coreConcepts":{"Hicksian demand":"compensated demand","Marshallian demand":"ordinary demand"},"definitions":{"Slutsky equation":"separates substitution and income effects"},"professorExamples":"Coffee and tea","professorEmphasis":[],"possibleExamTopics":[],"unresolvedQuestions":null,"glossary":{"Hicksian demand":"希克斯需求"}}"#)
    try expect(
        flexibleSummary.coreConcepts == ["Hicksian demand：compensated demand", "Marshallian demand：ordinary demand"],
        "summary dictionaries should normalize into stable study bullets"
    )
    try expect(
        flexibleSummary.definitions == ["Slutsky equation：separates substitution and income effects"],
        "definition dictionaries should not fail the entire lecture workflow"
    )
    try expect(flexibleSummary.professorExamples == ["Coffee and tea"], "single summary strings should normalize into one bullet")
    try expect(flexibleSummary.unresolvedQuestions.isEmpty, "null summary sections should normalize to empty lists")
    try expect(flexibleSummary.glossary == [GlossaryTerm(english: "Hicksian demand", chinese: "希克斯需求")], "glossary dictionaries should normalize into terms")
    let nestedSummary = try DeepSeekResponseParser.studySummary(from: #"{"overview":"Nested response","coreConcepts":[{"Market power":"ability to raise price"}],"definitions":{"elasticity":1.5},"professorExamples":[],"professorEmphasis":[],"possibleExamTopics":[],"unresolvedQuestions":[],"glossary":[{"term":"markup","translation":"加成","definition":"price over marginal cost"}]}"#)
    try expect(nestedSummary.coreConcepts == ["Market power：ability to raise price"], "object list fields should normalize instead of failing a completed lecture")
    try expect(nestedSummary.definitions == ["elasticity：1.5"], "numeric dictionary values should normalize instead of failing a completed lecture")
    try expect(nestedSummary.glossary.first?.english == "markup" && nestedSummary.glossary.first?.chinese == "加成", "alternate glossary field names should normalize")

    let evidence = [
        GroundingEvidence(id: "ev-1", lectureID: "lecture-1", lectureTitle: "Consumer Choice", segmentID: "s1", startTime: 96, endTime: 104, text: "The MRS diminishes along a convex indifference curve."),
        GroundingEvidence(id: "ev-2", lectureID: "lecture-2", lectureTitle: "Demand", segmentID: "s9", startTime: 210, endTime: 220, text: "Demand follows from utility maximization."),
    ]
    let answer = try DeepSeekResponseParser.groundedAnswer(
        from: #"{"answer":"教授将其解释为无差异曲线斜率。","foundEvidence":true,"citedEvidenceIDs":["ev-1"]}"#,
        evidence: evidence
    )
    try expect(answer.citations == [Citation(lectureID: "lecture-1", lectureTitle: "Consumer Choice", startTime: 96, segmentID: "s1")], "grounded answer should map citations from local evidence")

    do {
        _ = try DeepSeekResponseParser.groundedAnswer(
            from: #"{"answer":"Unsupported","foundEvidence":true,"citedEvidenceIDs":["invented"]}"#,
            evidence: evidence
        )
        throw TestFailure(description: "invented citations must be rejected")
    } catch is DeepSeekError {
        // Expected: model citations may only point to locally supplied evidence.
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var observedRequests: [URLRequest] = []

    static func reset() {
        lock.lock()
        stubs = []
        observedRequests = []
        lock.unlock()
    }

    static func enqueue(statusCode: Int = 200, body: String) {
        lock.lock()
        stubs.append(Stub(statusCode: statusCode, body: Data(body.utf8)))
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return observedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub?
        Self.lock.lock()
        Self.observedRequests.append(request)
        stub = Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        Self.lock.unlock()

        guard let stub, let url = request.url, let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: TestFailure(description: "missing URL protocol stub"))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct StaticAPIKeyProvider: DeepSeekAPIKeyProviding {
    let value: String?
    func loadAPIKey() throws -> String? { value }
}

struct StaticAIConfigurationProvider: AIProviderConfigurationProviding {
    let value: AIProviderConfiguration
    func loadConfiguration() throws -> AIProviderConfiguration { value }
}

func makeStubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

func completionEnvelope(content: String, finishReason: String = "stop") throws -> String {
    let object: [String: Any] = [
        "id": "chatcmpl-test",
        "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": finishReason]],
    ]
    return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

func testDeepSeekRequestShapeAndRedaction() async throws {
    StubURLProtocol.reset()
    let key = "sk-test-request-shape-1234567890"
    StubURLProtocol.enqueue(body: try completionEnvelope(content: "OK"))
    let client = DeepSeekClient(
        keyProvider: StaticAPIKeyProvider(value: key),
        configurationProvider: StaticAIConfigurationProvider(value: .deepSeekV4Flash),
        session: makeStubbedSession()
    )
    let status = try await client.testConnection()
    try expect(status.isConnected, "connectivity response should report success")

    guard let request = StubURLProtocol.requests().first else { throw TestFailure(description: "DeepSeek request was not emitted") }
    try expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions", "client must use the official chat completion endpoint")
    try expect(request.httpMethod == "POST", "DeepSeek request should use POST")
    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key, "DeepSeek request should use bearer authentication")
    let body = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    guard let body, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        throw TestFailure(description: "DeepSeek request body should be JSON")
    }
    try expect(json["model"] as? String == "deepseek-v4-flash", "client should default to DeepSeek V4 Flash")
    try expect(json["stream"] as? Bool == false, "core workflows should request a non-stream response")
    try expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled", "structured workflows should disable thinking output")

    StubURLProtocol.enqueue(
        statusCode: 401,
        body: #"{"error":{"message":"Authorization: Bearer sk-test-request-shape-1234567890 api_key=sk-test-request-shape-1234567890","type":"authentication_error"}}"#
    )
    do {
        _ = try await client.testConnection()
        throw TestFailure(description: "HTTP authentication failure should throw")
    } catch {
        let description = String(describing: error)
        try expect(!description.contains(key), "DeepSeek errors must redact API keys")
        try expect(description.contains("[REDACTED]"), "redacted DeepSeek errors should preserve a safe diagnostic marker")
    }
}

func testDeepSeekWorkflows() async throws {
    StubURLProtocol.reset()
    let summary = #"{"overview":"Utility maximization","coreConcepts":["MRS"],"definitions":[],"professorExamples":[],"professorEmphasis":[],"possibleExamTopics":[],"unresolvedQuestions":[],"glossary":[] }"#
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"translations":[{"index":0,"chinese":"边际替代率递减。"}]}"#))
    StubURLProtocol.enqueue(body: try completionEnvelope(content: summary))
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"answer":"教授说边际替代率沿凸无差异曲线递减。","foundEvidence":true,"citedEvidenceIDs":["ev-1"]}"#))

    let client = DeepSeekClient(
        keyProvider: StaticAPIKeyProvider(value: "sk-test-workflow-1234567890"),
        configurationProvider: StaticAIConfigurationProvider(value: .deepSeekV4Flash),
        session: makeStubbedSession()
    )
    let segment = TranscriptSegment(id: "seg-1", lectureID: "lecture-1", source: .reviewedEnglish, startTime: 10, endTime: 16, text: "The marginal rate of substitution diminishes.", isFinal: true)
    let corrected = try await client.correctTranslation(englishSegments: [segment], vocabulary: ["marginal rate of substitution"])
    try expect(corrected.count == 1 && corrected[0].text == "边际替代率递减。", "translation correction should retain parsed Chinese text")
    try expect(corrected[0].sourceSegmentID == "seg-1" && corrected[0].startTime == 10, "translation correction should retain local source identity and time")

    let studySummary = try await client.generateStudySummary(lectureTitle: "Consumer Choice", transcript: [segment])
    try expect(studySummary.overview == "Utility maximization", "structured study summary should parse through the client")

    let evidence = [GroundingEvidence(id: "ev-1", lectureID: "lecture-1", lectureTitle: "Consumer Choice", segmentID: "seg-1", startTime: 10, endTime: 16, text: segment.text)]
    let answer = try await client.answer(question: "教授如何解释 MRS？", evidence: evidence)
    try expect(answer.citations.first?.startTime == 10, "Q&A should return a playable local timestamp citation")
    try expect(StubURLProtocol.requests().count == 3, "each workflow should make one focused request for a short transcript")
}

func testOpenAICompatibleRequestShape() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.enqueue(body: try completionEnvelope(content: "OK"))
    let configuration = AIProviderConfiguration(
        name: "Local test",
        baseURL: "http://127.0.0.1:11434/v1",
        model: "qwen-test",
        providerKind: .local,
        requiresAPIKey: false,
        supportsJSONResponseFormat: false
    )
    let client = DeepSeekClient(
        keyProvider: StaticAPIKeyProvider(value: nil),
        configurationProvider: StaticAIConfigurationProvider(value: configuration),
        session: makeStubbedSession()
    )
    _ = try await client.testConnection()
    guard let request = StubURLProtocol.requests().first else {
        throw TestFailure(description: "custom AI request missing")
    }
    let body = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    guard let body, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        throw TestFailure(description: "custom AI request body missing")
    }
    try expect(request.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions", "local OpenAI-compatible endpoint should append chat/completions")
    try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "keyless local service should omit authorization")
    try expect(json["model"] as? String == "qwen-test", "custom model should be used verbatim")
    try expect(json["thinking"] == nil && json["response_format"] == nil, "provider-specific fields should be omitted when disabled")

    do {
        _ = try AIProviderConfiguration(
            name: "Unsafe",
            baseURL: "http://example.com/v1",
            model: "model"
        ).validated()
        throw TestFailure(description: "remote HTTP AI URL must be rejected")
    } catch is AIProviderConfigurationError {
        // Expected.
    }
}

func testAIProviderConfigurationPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("ai-provider.json")
    let store = AIProviderConfigurationStore(url: url)
    try expect(try store.loadConfiguration() == .deepSeekV4Flash, "new installations should default to DeepSeek V4 Flash")
    let custom = AIProviderConfiguration(
        name: "Custom provider",
        baseURL: "https://example.test/v1",
        model: "custom-model",
        providerKind: .openAICompatible
    )
    try store.saveConfiguration(custom)
    try expect(try store.loadConfiguration() == custom, "custom compatible provider settings should survive reload")
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    try expect(permissions?.intValue == 0o600, "AI provider settings should remain private")
    let text = try String(contentsOf: url, encoding: .utf8).lowercased()
    try expect(!text.contains("api key") && !text.contains("authorization"), "provider settings must not contain credentials")
}

func testDeepSeekTranslationRetrySafety() async throws {
    StubURLProtocol.reset()
    let response = try completionEnvelope(
        content: #"{"translations":[{"index":0,"chinese":"重试后仍是同一段。"}]}"#
    )
    StubURLProtocol.enqueue(body: response)
    StubURLProtocol.enqueue(body: response)
    let client = DeepSeekClient(
        keyProvider: StaticAPIKeyProvider(value: "sk-test-retry-safety-1234567890"),
        configurationProvider: StaticAIConfigurationProvider(value: .deepSeekV4Flash),
        session: makeStubbedSession()
    )
    let segment = TranscriptSegment(
        id: "seg-retry",
        lectureID: "lecture-retry",
        source: .reviewedEnglish,
        startTime: 1,
        endTime: 4,
        text: "Retrying must not duplicate corrected translations.",
        isFinal: true
    )

    let first = try await client.correctTranslation(englishSegments: [segment], vocabulary: [])
    let second = try await client.correctTranslation(englishSegments: [segment], vocabulary: [])
    try expect(first.map(\.id) == second.map(\.id), "translation retries must reuse stable transcript identifiers")

    StubURLProtocol.reset()
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"translations":[]}"#))
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"translations":[{"index":99,"chinese":"错误序号"}]}"#))
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"translations":[{"index":0,"chinese":"恢复后的翻译。"}]}"#))
    let recovered = try await client.correctTranslation(englishSegments: [segment], vocabulary: [])
    try expect(recovered.first?.text == "恢复后的翻译。", "translation should retry malformed DeepSeek indices")
    try expect(StubURLProtocol.requests().count == 3, "a malformed translation chunk should retry at most three times")

    StubURLProtocol.reset()
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"translations":[]}"#))
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"translations":[]}"#))
    StubURLProtocol.enqueue(body: try completionEnvelope(content: #"{"translations":[]}"#))
    do {
        _ = try await client.correctTranslation(englishSegments: [segment], vocabulary: [])
        throw TestFailure(description: "missing translation units must fail the corrected transcript")
    } catch is DeepSeekError {
        // Expected: partial AI output must not hide otherwise usable live Chinese.
    }
}

func testDeepSeekRejectsEmptySummaryInput() async throws {
    StubURLProtocol.reset()
    let client = DeepSeekClient(
        keyProvider: StaticAPIKeyProvider(value: "sk-test-empty-summary-1234567890"),
        configurationProvider: StaticAIConfigurationProvider(value: .deepSeekV4Flash),
        session: makeStubbedSession()
    )
    do {
        _ = try await client.generateStudySummary(lectureTitle: "Silent class", transcript: [])
        throw TestFailure(description: "empty transcripts must not produce an AI summary")
    } catch is DeepSeekError {
        // Expected: no transcript means there is no evidence to summarize.
    }
    try expect(StubURLProtocol.requests().isEmpty, "empty transcripts must be rejected before any network request")
}

func testStorage() throws {
    func step(_ name: String, _ work: () throws -> Void) throws {
        do { try work() } catch { throw TestFailure(description: "storage step \(name): \(error)") }
    }
    let repository: SQLiteLectureRepository
    do { repository = try SQLiteLectureRepository(databaseURL: URL(fileURLWithPath: ":memory:")) }
    catch { throw TestFailure(description: "storage init: " + String(describing: error)) }
    let course = Course(id: "c1", name: "Statistics II", code: "STAT-UA 202", professor: "Hannah Wilson")
    try step("upsert course") { try repository.upsertCourse(course) }
    var lecture = LectureRecord(id: "l1", courseID: course.id, title: "Regression", status: .recording)
    try step("upsert lecture") { try repository.upsertLecture(lecture) }
    try step("append transcript") { try repository.appendTranscript(TranscriptSegment(id: "s1", lectureID: lecture.id, source: .liveEnglish, startTime: 0, endTime: 3, text: "Consumer preferences", confidence: 0.91, isFinal: true)) }
    try step("append marker") { try repository.appendMarker(LectureMarker(id: "m1", lectureID: lecture.id, time: 1.5, label: "Professor emphasis")) }
    try step("append summary") { try repository.appendSummary(SummaryVersion(id: "sum1", lectureID: lecture.id, createdAt: Date(timeIntervalSince1970: 100), content: StudySummary(overview: "Preferences and utility"))) }
    try step("append course chat") { try repository.appendChatMessage(ChatMessage(id: "chat-course", courseID: course.id, role: .user, text: "whole course")) }
    try step("append lecture chat") { try repository.appendChatMessage(ChatMessage(id: "chat-lecture", courseID: course.id, lectureID: lecture.id, role: .assistant, text: "single lecture")) }
    try expect(try repository.chatMessages(courseID: course.id, lectureID: nil).map(\.id) == ["chat-course", "chat-lecture"], "whole-course chat should include course and lecture-scoped history")
    try expect(try repository.chatMessages(courseID: course.id, lectureID: lecture.id).map(\.id) == ["chat-lecture"], "lecture chat should stay scoped")
    try expect(try repository.incompleteLectures().map(\.id) == ["l1"], "recover incomplete lecture")
    let searchIDs = try repository.searchCourses(query: "Wilson").map(\.id)
    try expect(searchIDs == ["c1"], "search professor got " + String(describing: searchIDs))
    lecture.status = .reviewingEnglish
    try repository.upsertLecture(lecture)
    lecture.status = .completed
    try repository.upsertLecture(lecture)
    try expect(try repository.transcripts(lectureID: "l1", source: .liveEnglish).count == 1, "transcript persisted")
    try expect(try repository.markers(lectureID: "l1").count == 1, "marker persisted")
    try expect(try repository.summaries(lectureID: "l1").count == 1, "summary persisted")
    try repository.deleteCourse(id: "c1")
    try expect(try repository.listLectures(courseID: "c1").isEmpty, "course delete cascades")
}

func testFileBackedStoragePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(root: root)
    try paths.createDirectories()
    let repository = try SQLiteLectureRepository(databaseURL: paths.database)
    try repository.upsertCourse(Course(id: "permissions", name: "Permissions", professor: "Professor"))
    for file in [paths.database, paths.database.appendingPathExtension("wal"), paths.database.appendingPathExtension("shm")]
    where FileManager.default.fileExists(atPath: file.path) {
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "SQLite should create owner-only database and journal files")
    }
}

final class FakeRuntime: LectureRuntimeControlling, @unchecked Sendable {
    var snapshot = RuntimeSnapshot(deepSeekConfigured: true)
    func runtimeSnapshot() throws -> RuntimeSnapshot { snapshot }
    func startLecture(courseID: String, title: String?) async throws -> LectureRecord { LectureRecord(courseID: courseID, title: title ?? "Class", status: .recording) }
    func stopLecture() async throws -> LectureRecord { LectureRecord(courseID: "c", title: "Class", status: .reviewingEnglish) }
    func addMarker(label: String?) throws -> LectureMarker { LectureMarker(lectureID: "l", time: 1) }
    func retryProcessing(lectureID: String) async throws {}
    func answer(question: String, courseID: String, lectureID: String?) async throws -> ChatMessage { ChatMessage(courseID: courseID, lectureID: lectureID, role: .assistant, text: "answer") }
    func saveDeepSeekKey(_ key: String) async throws {}
    func deleteDeepSeekKey() throws {}
    func testDeepSeek() async throws -> Bool { true }
    func isDeepSeekConfigured() -> Bool { snapshot.deepSeekConfigured }
}

final class SecretFailingRuntime: LectureRuntimeControlling, @unchecked Sendable {
    func runtimeSnapshot() throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func startLecture(courseID: String, title: String?) async throws -> LectureRecord {
        throw TestFailure(description: "failed URL http://127.0.0.1/?token=opaque-session-secret Authorization: Bearer opaque-api-secret")
    }
    func stopLecture() async throws -> LectureRecord { throw TestFailure(description: "unused") }
    func addMarker(label: String?) throws -> LectureMarker { throw TestFailure(description: "unused") }
    func retryProcessing(lectureID: String) async throws {}
    func answer(question: String, courseID: String, lectureID: String?) async throws -> ChatMessage { throw TestFailure(description: "unused") }
    func saveDeepSeekKey(_ key: String) async throws {}
    func deleteDeepSeekKey() throws {}
    func testDeepSeek() async throws -> Bool { false }
    func isDeepSeekConfigured() -> Bool { false }
}

func testServerRouter() async throws {
    let repository = try SQLiteLectureRepository(databaseURL: URL(fileURLWithPath: ":memory:"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: root.appendingPathComponent("index.html"))
    let router = LectureAPIRouter(repository: repository, runtime: FakeRuntime(), token: "secret-token", resourcesRoot: root)
    let unauthorized = await router.handle(HTTPRequest(method: "GET", path: "/api/health"))
    try expect(unauthorized.status == 401, "server must require session token")
    let health = await router.handle(HTTPRequest(method: "GET", path: "/api/health", headers: ["x-lecture-token": "secret-token"]))
    try expect(health.status == 200, "authorized health request")
    let aiConfig = await router.handle(HTTPRequest(method: "GET", path: "/api/ai/config", headers: ["x-lecture-token": "secret-token"]))
    try expect(aiConfig.status == 200, "AI configuration should be readable without exposing a key")
    let savedAIConfig = await router.handle(HTTPRequest(
        method: "PUT",
        path: "/api/ai/config",
        headers: ["x-lecture-token": "secret-token"],
        body: try LectureJSON.encoder.encode(AIProviderConfiguration.local)
    ))
    try expect(savedAIConfig.status == 200, "OpenAI-compatible AI configuration should be writable")
    let storage = await router.handle(HTTPRequest(method: "GET", path: "/api/storage", headers: ["x-lecture-token": "secret-token"]))
    try expect(storage.status == 200 && storage.headers["Content-Type"] == "application/json; charset=utf-8", "storage diagnostics should be available to the local page")
    let page = await router.handle(HTTPRequest(method: "GET", path: "/", query: ["token": "secret-token"]))
    try expect(page.status == 200 && String(data: page.body, encoding: .utf8) == "hello", "authorized static page")
    try expect(page.headers["Content-Security-Policy"]?.contains("connect-src 'self'") == true, "local page should have a restrictive CSP")
    try expect(page.headers["Content-Security-Policy"]?.contains("style-src 'self'") == true, "styles should remain external under CSP")
    try expect(page.headers["Content-Security-Policy"]?.contains("unsafe-inline") == false, "CSP must not be weakened for the audio level meter")

    let secretRouter = LectureAPIRouter(repository: repository, runtime: SecretFailingRuntime(), token: "secret-token", resourcesRoot: root)
    let secretFailure = await secretRouter.handle(HTTPRequest(
        method: "POST",
        path: "/api/lectures/start",
        headers: ["x-lecture-token": "secret-token"],
        body: Data(#"{"courseID":"anything","title":null}"#.utf8)
    ))
    let secretFailureText = String(data: secretFailure.body, encoding: .utf8) ?? ""
    try expect(secretFailure.status == 500 && secretFailureText.contains("[REDACTED]"), "internal failures should retain a safe diagnostic marker")
    try expect(!secretFailureText.contains("opaque-session-secret") && !secretFailureText.contains("opaque-api-secret"), "API errors must redact local tokens and bearer secrets")

    let course = Course(id: "audio-course", name: "Audio", professor: "Professor")
    try repository.upsertCourse(course)
    let m4a = root.appendingPathComponent("lecture.m4a")
    try Data([0, 1, 2, 3]).write(to: m4a)
    try repository.upsertLecture(LectureRecord(id: "audio-lecture", courseID: course.id, title: "Audio", status: .completed, audioPath: m4a.path))
    let audio = await router.handle(HTTPRequest(method: "GET", path: "/api/lectures/audio-lecture/audio", headers: ["x-lecture-token": "secret-token"]))
    try expect(audio.status == 200 && audio.headers["Content-Type"] == "audio/mp4", "m4a recording should use a browser-playable MIME type")
    try expect(audio.headers["Accept-Ranges"] == "bytes", "full recording responses should advertise byte seeking")
    let audioRange = await router.handle(HTTPRequest(
        method: "GET",
        path: "/api/lectures/audio-lecture/audio",
        headers: ["x-lecture-token": "secret-token", "range": "bytes=1-2"]
    ))
    try expect(audioRange.status == 206 && audioRange.body == Data([1, 2]), "audio byte ranges should return only the requested media bytes")
    try expect(audioRange.headers["Content-Range"] == "bytes 1-2/4", "partial audio should report its exact content range")
    let invalidAudioRange = await router.handle(HTTPRequest(
        method: "GET",
        path: "/api/lectures/audio-lecture/audio",
        headers: ["x-lecture-token": "secret-token", "range": "bytes=9-10"]
    ))
    try expect(invalidAudioRange.status == 416 && invalidAudioRange.headers["Content-Range"] == "bytes */4", "unsatisfiable audio ranges should be explicit")

    try repository.appendTranscript(TranscriptSegment(id: "audio-en", lectureID: "audio-lecture", source: .reviewedEnglish, startTime: 2, endTime: 4, text: "Exported evidence.", isFinal: true))
    let exported = await router.handle(HTTPRequest(method: "GET", path: "/api/lectures/audio-lecture/export", headers: ["x-lecture-token": "secret-token"]))
    let exportedText = String(data: exported.body, encoding: .utf8) ?? ""
    try expect(exported.status == 200 && exported.headers["Content-Type"] == "text/markdown; charset=utf-8", "lecture export should be a UTF-8 Markdown download")
    try expect(exported.headers["Content-Disposition"]?.contains("attachment") == true && exportedText.contains("Exported evidence."), "lecture export should download the stored evidence")
    try expect(exported.headers["Cache-Control"] == "no-store", "lecture exports should never be cached by the browser")

    let runtime = FakeRuntime()
    runtime.snapshot.activeLectureID = "audio-lecture"
    let protectedRouter = LectureAPIRouter(repository: repository, runtime: runtime, token: "secret-token", resourcesRoot: root)
    let protectedDelete = await protectedRouter.handle(HTTPRequest(method: "DELETE", path: "/api/courses/audio-course", headers: ["x-lecture-token": "secret-token"]))
    try expect(protectedDelete.status == 409, "active recording course must not be deleted")
    try expect(try repository.course(id: course.id) != nil && FileManager.default.fileExists(atPath: m4a.path), "blocked delete must preserve data")
    runtime.snapshot.activeLectureID = nil
    let deleted = await protectedRouter.handle(HTTPRequest(method: "DELETE", path: "/api/courses/audio-course", headers: ["x-lecture-token": "secret-token"]))
    try expect(deleted.status == 200 && !FileManager.default.fileExists(atPath: m4a.path), "course delete should remove original recordings")
}

func testWebSecurityContract() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appJavaScript = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/LectureApp/Resources/Web/app.js"),
        encoding: .utf8
    )
    try expect(!appJavaScript.contains("style=\""), "web UI must not use inline styles blocked by its CSP")
    try expect(appJavaScript.contains("<progress"), "microphone level should use a CSP-safe native progress value")
    try expect(appJavaScript.contains("正在准备…"), "long-running start should show visible progress")
    try expect(appJavaScript.contains("control.disabled = true"), "long-running controls should prevent duplicate requests")
    try expect(
        appJavaScript.contains("function transcriptWindow(values)")
            && appJavaScript.contains("sort((a, b) => Number(a.startTime) - Number(b.startTime))")
            && appJavaScript.contains("captureStreamPositions()")
            && appJavaScript.contains("anchor.offsetTop - previous.anchorOffset")
            && appJavaScript.contains("previous.wasNearBottom")
            && appJavaScript.contains("restoreStreamPositions(preservedStreams)"),
        "live transcripts should run top-to-bottom, follow the bottom, and preserve an older reading anchor"
    )
    try expect(
        appJavaScript.contains("state.runtime.receivingAudio === false")
            && appJavaScript.contains("未收到声音，请检查输入设备"),
        "the live UI should distinguish an active lecture from a stalled microphone stream"
    )
    try expect(
        appJavaScript.contains("pendingAudioTime") && appJavaScript.contains("applyPendingAudioJump()"),
        "Q&A citations should carry their timestamp into the lecture audio player"
    )
    try expect(
        appJavaScript.contains("requiresLectureChange") && appJavaScript.contains(#"state.route !== "detail""#),
        "citation clicks outside lecture detail should open the referenced lecture before seeking"
    )
    try expect(
        appJavaScript.contains("const targetHash = `#${route}`") && appJavaScript.contains("if (location.hash !== targetHash)"),
        "route changes should render once through hashchange instead of racing duplicate detail renders"
    )
    try expect(
        appJavaScript.contains("routeRenderGeneration")
            && appJavaScript.contains("renderIsCurrent(generation, route)")
            && appJavaScript.contains("state.detailRequest += 1"),
        "stale course, lecture, summary, detail, and Q&A responses must not overwrite a newer selection"
    )
    try expect(
        appJavaScript.contains("updateStreamElements(stream, segments, draft, language)")
            && appJavaScript.contains("stream.insertBefore")
            && appJavaScript.contains("node.querySelector(\"p\").textContent = draft"),
        "live draft refreshes should update the existing stream instead of rebuilding the scroll container"
    )
    try expect(
        appJavaScript.contains("state.pendingAudioTime = null; audio.play()"),
        "pending citation time should clear only after the audio element is ready to seek"
    )
    try expect(
        appJavaScript.contains("/api/storage") && appJavaScript.contains("/export?token=") && appJavaScript.contains("导出 Markdown 学习档案"),
        "the web UI should display real storage diagnostics and expose lecture Markdown downloads"
    )
    try expect(
        appJavaScript.contains("async function refreshStorage()")
            && appJavaScript.contains(#"try { state.storage = await api("/api/storage"); } catch {}"#)
            && !appJavaScript.contains(#"state.runtime = await api("/api/state"); state.storage = await api("/api/storage")"#),
        "storage diagnostics should remain best-effort and never make the core classroom UI appear disconnected"
    )

    let buildScript = try String(
        contentsOf: projectRoot.appendingPathComponent("scripts/build-app.sh"),
        encoding: .utf8
    )
    try expect(
        buildScript.contains(#"designated => identifier "com.jiyuanyi.Lecture""#)
            && buildScript.contains(#"--identifier com.jiyuanyi.Lecture.whisper-cli"#),
        "packaged builds must keep a stable designated requirement so macOS permissions survive updates"
    )

    let coordinatorSource = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/LectureApp/LectureCoordinator.swift"),
        encoding: .utf8
    )
    try expect(
        coordinatorSource.contains("catch {\n            withState { statusMessageValue = SecretRedactor.redact(String(describing: error)) }\n            throw error\n        }"),
        "failed classroom startup should replace transient progress text with the safe actionable error"
    )
    try expect(
        coordinatorSource.contains("let recording = recorder.hasActiveSession")
            && coordinatorSource.contains("let receivingAudio = recorder.isReceivingAudio")
            && coordinatorSource.contains("lastStoppedLecture?.id == requestedLectureID"),
        "recording state must survive a quiet input stream and duplicate stop calls must return the same lecture"
    )
    try expect(
        coordinatorSource.contains("guard !live.isEmpty else { throw error }")
            && coordinatorSource.contains("let base = TranscriptPreference.english(live: live, reviewed: reviewed)")
            && coordinatorSource.contains("processingLectureIDs"),
        "post-class review must preserve a usable live transcript and avoid duplicate background work"
    )

    let whisperSource = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/LectureSpeech/WhisperCLI.swift"),
        encoding: .utf8
    )
    try expect(
        whisperSource.contains("--vad-model")
            && whisperSource.contains("--vad-min-silence-duration-ms")
            && whisperSource.contains("0.35"),
        "Whisper should use the local Silero VAD model with a classroom-friendly threshold when installed"
    )

    let appSource = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/LectureApp/main.swift"),
        encoding: .utf8
    )
    try expect(
        appSource.contains(#"mainBundle.resourceURL"#)
            && appSource.contains(#"Lecture_LectureApp.bundle"#)
            && appSource.contains(#"packaged.appendingPathComponent("index.html")"#),
        "installed builds must load their packaged web UI instead of falling back to an absolute Swift build directory"
    )
}

let tests: [(String, () async throws -> Void)] = [
    ("domain", { try testDomainModels() }),
    ("transcript preference", { try testTranscriptPreference() }),
    ("app paths", { try testAppPaths() }),
    ("lecture Markdown export", { try testLectureMarkdownExport() }),
    ("storage", { try testStorage() }),
    ("storage permissions", { try testFileBackedStoragePermissions() }),
    ("keychain", { try testKeychainStore() }),
    ("chunking", { try testTranscriptChunking() }),
    ("whole-lecture grounding evidence", { try testGroundingEvidenceKeepsTheWholeLecture() }),
    ("structured parsing", { try testStructuredResponseParsing() }),
    ("DeepSeek request and redaction", testDeepSeekRequestShapeAndRedaction),
    ("DeepSeek workflows", testDeepSeekWorkflows),
    ("OpenAI-compatible request", testOpenAICompatibleRequestShape),
    ("AI provider persistence", { try testAIProviderConfigurationPersistence() }),
    ("DeepSeek translation retry safety", testDeepSeekTranslationRetrySafety),
    ("DeepSeek empty summary safety", testDeepSeekRejectsEmptySummaryInput),
    ("server router", testServerRouter),
    ("web security contract", { try testWebSecurityContract() }),
    ("native speech helpers", { try testLectureSpeech() }),
    ("native permission timeout", testLecturePermissions),
    ("recording permissions", { try testRecordingFilePermissions() }),
]

Task {
    var failures = 0
    for (name, test) in tests {
        do { try await test(); print("✓ \(name)") }
        catch { failures += 1; print("✗ \(name): \(error)") }
    }
    if failures > 0 { exit(1) }
    print("All \(tests.count) test groups passed")
    exit(0)
}
dispatchMain()
