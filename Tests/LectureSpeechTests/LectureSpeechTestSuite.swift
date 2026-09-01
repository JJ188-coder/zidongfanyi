import CoreMedia
import AVFoundation
import Foundation
import LectureCore
import LectureSpeech
import Speech

struct LectureSpeechTestFailure: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
private func speechExpect(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String
) throws -> Bool {
    guard try condition() else {
        throw LectureSpeechTestFailure(description: message)
    }
    return true
}

private func speechExpectClose(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double = 0.001,
    _ message: String
) throws {
    try speechExpect(abs(actual - expected) <= accuracy, "\(message): expected \(expected), got \(actual)")
}

private func speechUnwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else {
        throw LectureSpeechTestFailure(description: message)
    }
    return value
}

public func testLectureSpeech() throws {
    try testSegmentMapping()
    try testFallbackMappingAndFinality()
    try testConfidenceClassification()
    try testVocabularyNormalization()
    try testCustomVocabularyFingerprint()
    try testSpeechConfigurations()
    try testWhisperAudioConversion()
    try testRecorderEncodingSettings()
    try testWhisperWAVAndTranscriptParsing()
    try testWhisperFileSmoke()
    try testLectureEnglishLocaleResolution()
    try testAudioLevels()
    try testStreamingWAVWriter()
    try testCheckpointCadence()
}

@available(macOS 26.0, *)
public func testLecturePermissions() async throws {
    let granted = LecturePermissionAuthorizer(
        timeout: 0.05,
        microphoneStatus: { .granted },
        requestMicrophone: { _ in
            preconditionFailure("granted microphone permission must not prompt again")
        },
        speechRecognitionStatus: { .granted },
        requestSpeechRecognition: { _ in
            preconditionFailure("granted speech permission must not prompt again")
        }
    )
    try await granted.authorize()

    let timeout = LecturePermissionAuthorizer(
        timeout: 0.02,
        microphoneStatus: { .undetermined },
        requestMicrophone: { _ in },
        speechRecognitionStatus: { .granted },
        requestSpeechRecognition: { _ in }
    )
    let startedAt = ContinuousClock.now
    do {
        try await timeout.authorize()
        throw LectureSpeechTestFailure(description: "unanswered microphone prompt should time out")
    } catch let error as LecturePermissionError {
        try speechExpect(error == .timedOut(.microphone), "microphone timeout should identify the blocked permission")
        try speechExpect(ContinuousClock.now - startedAt < .seconds(1), "permission timeout should release the caller promptly")
    }

    let speechDenied = LecturePermissionAuthorizer(
        timeout: 0.05,
        microphoneStatus: { .granted },
        requestMicrophone: { _ in },
        speechRecognitionStatus: { .denied },
        requestSpeechRecognition: { _ in }
    )
    do {
        try await speechDenied.authorize()
        throw LectureSpeechTestFailure(description: "denied speech permission should fail")
    } catch let error as LecturePermissionError {
        try speechExpect(error == .denied(.speechRecognition), "speech denial should name speech recognition")
        try speechExpect(error.description.contains("语音识别"), "speech denial should provide a useful Chinese instruction")
    }
}

public func testRecordingFilePermissions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let audioURL = root.appendingPathComponent("private-recording.m4a")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0, 1, 2, 3]).write(to: audioURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audioURL.path)

    try MicrophoneRecorder.protectRecording(at: audioURL)

    let permissions = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.posixPermissions] as? NSNumber
    try speechExpect(permissions?.intValue == 0o600, "recordings should be readable only by the current user")
}

private func testRecorderEncodingSettings() throws {
    let lowRate = try speechUnwrap(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        "low-rate input format"
    )
    let lowSettings = MicrophoneRecorder.recordingSettings(for: lowRate)
    try speechExpect(
        lowSettings[AVEncoderBitRateKey] == nil,
        "low-rate inputs must not force an unsupported AAC bit rate"
    )

    let standardRate = try speechUnwrap(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ),
        "standard-rate input format"
    )
    let standardSettings = MicrophoneRecorder.recordingSettings(for: standardRate)
    try speechExpect(
        standardSettings[AVEncoderBitRateKey] as? Int == 128_000,
        "standard microphone formats should retain the configured AAC bit rate"
    )
}

@available(macOS 26.0, *)
private func testCustomVocabularyFingerprint() throws {
    let first = CustomVocabularyModel.fingerprint(
        locale: Locale(identifier: "en-US"),
        vocabulary: [" Nash   equilibrium ", "Pareto efficiency"]
    )
    let equivalent = CustomVocabularyModel.fingerprint(
        locale: Locale(identifier: "en-US"),
        vocabulary: ["nash equilibrium", "pareto efficiency"]
    )
    let otherLocale = CustomVocabularyModel.fingerprint(
        locale: Locale(identifier: "en-GB"),
        vocabulary: ["Nash equilibrium", "Pareto efficiency"]
    )
    try speechExpect(first == equivalent, "fingerprint should use normalized case-insensitive terms")
    try speechExpect(first != otherLocale, "fingerprint should separate locale-specific models")
}

@available(macOS 26.0, *)
private func testLectureEnglishLocaleResolution() throws {
    try speechExpect(
        SpeechAssetManager.requestedLocale(identifier: "en-US").identifier == "en-US",
        "US English locale"
    )
    try speechExpect(
        SpeechAssetManager.requestedLocale(identifier: "en-GB").identifier == "en-GB",
        "British English locale"
    )
    try speechExpect(
        SpeechAssetManager.requestedLocale(identifier: "zh-CN").identifier == "en-US",
        "non-English locale should safely fall back to US English"
    )
}

@available(macOS 26.0, *)
private func testSpeechConfigurations() throws {
    let context = SpeechAnalysisContextFactory.make(
        vocabulary: ["  Bayes   rule", "bayes rule", "Nash equilibrium"]
    )
    try speechExpect(
        context.contextualStrings[.general] == ["Bayes rule", "Nash equilibrium"],
        "analysis context vocabulary"
    )

    let review = OfflineDictationTranscriber.makeDictationPreset()
    try speechExpect(review.contentHints.contains(.farField), "review far-field hint")
    try speechExpect(review.attributeOptions.contains(.audioTimeRange), "review audio time")
    try speechExpect(review.attributeOptions.contains(.transcriptionConfidence), "review confidence")
    try speechExpect(!review.reportingOptions.contains(.volatileResults), "review emits final results")
}

private func testWhisperAudioConversion() throws {
    let sourceFormat = try speechUnwrap(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ),
        "Whisper source format"
    )
    let source = try speechUnwrap(
        AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4_800),
        "Whisper source buffer"
    )
    source.frameLength = 4_800
    if let samples = source.floatChannelData?[0] {
        for index in 0..<Int(source.frameLength) {
            samples[index] = sin(Float(index) * 0.09) * 0.25
        }
    }
    let converted = try WhisperAudioConverter(sourceFormat: sourceFormat).convert(source)
    try speechExpect(
        converted.count >= 1_300 && converted.count <= 1_700,
        "Whisper conversion should preserve the expected duration"
    )
    try speechExpect(converted.contains(where: { $0 != 0 }), "Whisper conversion should preserve sound")
}

private func testWhisperWAVAndTranscriptParsing() throws {
    let wav = try WhisperWAVWriter.data(samples: [1, -2, 3, -4], sampleRate: 16_000)
    try speechExpect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF", "WAV RIFF header")
    try speechExpect(String(data: wav[8..<12], encoding: .utf8) == "WAVE", "WAV format header")
    try speechExpect(wav.count == 52, "WAV should contain a 44-byte header and PCM payload")

    let json = #"{"transcription":[{"offsets":{"from":1200,"to":2450},"text":"  Hicksian demand. "},{"offsets":{"from":2450,"to":3000},"text":"   "}]}"#
    let items = try WhisperTranscriptParser.parse(Data(json.utf8))
    let segments = WhisperTranscriptParser.segments(
        from: items,
        lectureID: "whisper-lecture",
        source: .reviewedEnglish,
        timeOffset: 10,
        maximumDuration: 2
    )
    try speechExpect(segments.count == 1, "blank Whisper segments should be discarded")
    try speechExpect(segments[0].text == "Hicksian demand.", "Whisper text should be trimmed")
    try speechExpectClose(segments[0].startTime, 11.2, "Whisper start timestamp")
    try speechExpectClose(segments[0].endTime, 12, "Whisper end timestamp should be clamped to audio")
    try speechExpect(segments[0].source == .reviewedEnglish, "Whisper source should be retained")
}

private func testWhisperFileSmoke() throws {
    let executable = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
    let model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lecture/Whisper/ggml-base.en.bin")
    guard FileManager.default.isExecutableFile(atPath: executable.path),
          FileManager.default.fileExists(atPath: model.path) else { return }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LectureWhisperTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = WhisperConfiguration(
        executableURL: executable,
        modelURL: model,
        workingDirectory: root,
        threadCount: 2
    )
    let wavURL = root.appendingPathComponent("silent.wav")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try WhisperWAVWriter.data(samples: [Int16](repeating: 0, count: 16_000))
        .write(to: wavURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wavURL.path)
    let result = try WhisperCLI(configuration: configuration).transcribe(
        audioURL: wavURL,
        lectureID: "silent",
        source: .liveEnglish,
        vocabulary: []
    )
    try speechExpect(result.isEmpty, "silent Whisper input should not invent a transcript")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
    try speechExpect(leftovers == ["silent.wav"], "Whisper result JSON should be removed after parsing")
}

private func testSegmentMapping() throws {
    var text = AttributedString("marginal rate")
    let marginalRange = try speechUnwrap(text.range(of: "marginal"), "missing marginal range")
    text[marginalRange].transcriptionConfidence = 0.9
    text[marginalRange].audioTimeRange = speechTimeRange(start: 1.0, duration: 1.25)
    let rateRange = try speechUnwrap(text.range(of: "rate"), "missing rate range")
    text[rateRange].transcriptionConfidence = 0.5
    text[rateRange].audioTimeRange = speechTimeRange(start: 2.5, duration: 1.0)

    let update = try speechUnwrap(
        TranscriptionSegmentMapper.map(
            id: "segment-1",
            lectureID: "lecture-1",
            source: .liveEnglish,
            text: text,
            alternatives: [AttributedString(" marginal ratio "), AttributedString("marginal ratio")],
            fallbackRange: speechTimeRange(start: 20, duration: 5),
            isFinal: false,
            confidenceClassifier: ConfidenceClassifier(lowConfidenceThreshold: 0.75)
        ),
        "non-empty result should map"
    )

    try speechExpect(update.segment.id == "segment-1", "segment id")
    try speechExpect(update.segment.lectureID == "lecture-1", "lecture id")
    try speechExpect(update.segment.source == .liveEnglish, "live source")
    try speechExpect(update.segment.text == "marginal rate", "trimmed text")
    try speechExpect(update.alternatives == ["marginal ratio"], "normalized alternatives")
    try speechExpectClose(update.segment.startTime, 1.0, "mapped start time")
    try speechExpectClose(update.segment.endTime, 3.5, "mapped end time")
    try speechExpectClose(try speechUnwrap(update.segment.confidence, "missing confidence"), 0.7, "mean confidence")
    try speechExpect(update.confidenceClassification == .low, "low confidence classification")
    try speechExpect(update.kind == .draft, "volatile result should be a draft")
    try speechExpect(update.durableSegment == nil, "draft must not be durable")
}

private func testFallbackMappingAndFinality() throws {
    let update = try speechUnwrap(
        TranscriptionSegmentMapper.map(
            id: "segment-2",
            lectureID: "lecture-1",
            source: .reviewedEnglish,
            text: AttributedString("The theorem follows."),
            fallbackRange: speechTimeRange(start: 4.25, duration: 2.5),
            isFinal: true
        ),
        "final result should map"
    )

    try speechExpectClose(update.segment.startTime, 4.25, "fallback start")
    try speechExpectClose(update.segment.endTime, 6.75, "fallback end")
    try speechExpect(update.segment.confidence == nil, "missing confidence stays nil")
    try speechExpect(update.confidenceClassification == .unavailable, "missing confidence classification")
    try speechExpect(update.kind == .final, "final result kind")
    try speechExpect(update.durableSegment == update.segment, "final result is durable")

    let blank = TranscriptionSegmentMapper.map(
        id: "blank",
        lectureID: "lecture-1",
        source: .liveEnglish,
        text: AttributedString("  \n  "),
        fallbackRange: speechTimeRange(start: 0, duration: 1),
        isFinal: true
    )
    try speechExpect(blank == nil, "blank results should be discarded")
}

private func testConfidenceClassification() throws {
    let classifier = ConfidenceClassifier(lowConfidenceThreshold: 0.72)
    try speechExpect(classifier.classify(0.719) == .low, "below threshold")
    try speechExpect(classifier.classify(0.72) == .acceptable, "threshold is acceptable")
    try speechExpect(classifier.classify(0.98) == .acceptable, "high confidence")
    try speechExpect(classifier.classify(nil) == .unavailable, "missing confidence")
    try speechExpect(classifier.classify(-0.01) == .unavailable, "negative confidence")
    try speechExpect(classifier.classify(1.01) == .unavailable, "confidence above one")
    try speechExpect(classifier.classify(.nan) == .unavailable, "NaN confidence")
}

private func testVocabularyNormalization() throws {
    let decomposedCafe = "Cafe\u{301}"
    let result = VocabularyNormalizer.normalized([
        "  Marginal   Rate of\nSubstitution  ",
        "marginal rate of substitution",
        decomposedCafe,
        "Café",
        "  MRS  ",
        "",
    ])

    try speechExpect(
        result == ["Marginal Rate of Substitution", "Café", "MRS"],
        "vocabulary normalization: \(result)"
    )
    try speechExpect(
        VocabularyNormalizer.normalized(["one", "ONE", "two", "three"], maximumCount: 2) == ["one", "two"],
        "maximum count after deduplication"
    )
    try speechExpect(VocabularyNormalizer.normalized(["one"], maximumCount: 0).isEmpty, "zero maximum")
}

private func testAudioLevels() throws {
    let signal = AudioLevelMeter.measure(samples: [0.5, -0.5, 0.5, -0.5])
    try speechExpectClose(signal.rmsDecibels, -6.0206, "signal RMS")
    try speechExpectClose(signal.peakDecibels, -6.0206, "signal peak")
    try speechExpect(signal.normalized > 0.8 && signal.normalized <= 1.0, "normalized signal")

    let silence = AudioLevelMeter.measure(samples: [0, 0, 0])
    try speechExpectClose(silence.rmsDecibels, -96, "silence RMS")
    try speechExpectClose(silence.peakDecibels, -96, "silence peak")
    try speechExpectClose(silence.normalized, 0, "silence normalized")

    let quietSpeech = AudioLevelMeter.measure(samples: Array(repeating: 0.01, count: 256))
    let normalSpeech = AudioLevelMeter.measure(samples: Array(repeating: 0.08, count: 256))
    try speechExpect(quietSpeech.normalized > 0, "quiet classroom speech should be visible")
    try speechExpect(
        normalSpeech.normalized - quietSpeech.normalized > 0.25,
        "the classroom meter should visibly distinguish quiet and normal speech"
    )
}

private func testStreamingWAVWriter() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("stream.wav")
    let handle = try WhisperWAVWriter.createEmptyFile(at: url)
    try WhisperWAVWriter.append(samples: [1, -1], to: handle)
    try WhisperWAVWriter.append(samples: [2, -2], to: handle)
    try WhisperWAVWriter.finalize(handle, sampleCount: 4)
    let data = try Data(contentsOf: url)
    try speechExpect(data.count == 44 + 8, "streaming WAV size")
    try speechExpect(Array(data[4..<8]) == [44, 0, 0, 0], "streaming RIFF size")
    try speechExpect(Array(data[40..<44]) == [8, 0, 0, 0], "streaming payload size")
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    try speechExpect(mode?.intValue == 0o600, "streaming WAV permissions")
}

private func testCheckpointCadence() throws {
    var scheduler = CheckpointScheduler(interval: 5)
    try speechExpect(!scheduler.shouldEmit(elapsedTime: 4.99), "before first checkpoint")
    try speechExpect(scheduler.shouldEmit(elapsedTime: 5.0), "first checkpoint")
    try speechExpect(!scheduler.shouldEmit(elapsedTime: 9.99), "before second checkpoint")
    try speechExpect(scheduler.shouldEmit(elapsedTime: 16.0), "catch up after long buffer")
    try speechExpect(!scheduler.shouldEmit(elapsedTime: 19.99), "caught-up boundary")
    try speechExpect(scheduler.shouldEmit(elapsedTime: 20.0), "next checkpoint")

    var disabled = CheckpointScheduler(interval: 0)
    try speechExpect(!disabled.shouldEmit(elapsedTime: 1_000), "non-positive interval disables checkpoints")
}

private func speechTimeRange(start: Double, duration: Double) -> CMTimeRange {
    CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
}
