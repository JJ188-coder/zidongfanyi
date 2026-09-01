import AppKit
import Foundation
import LectureCore
import LectureServer
import LectureSpeech

@available(macOS 26.4, *)
final class LectureCoordinator: LectureRuntimeControlling, @unchecked Sendable {
    private let repository: LectureRepository
    private let paths: AppPaths
    private let recorder = MicrophoneRecorder()
    private let keychain = DeepSeekKeychainStore()
    private let deepSeek: DeepSeekClient
    private let translation = AppleTranslationService()
    private let lock = NSLock()
    private var activeLecture: LectureRecord?
    private var activeCourse: Course?
    private var speech: LiveSpeechTranscriber?
    private var durationValue: TimeInterval = 0
    private var audioLevelValue: Double = 0
    private var volatileEnglishValue = ""
    private var volatileChineseValue = ""
    private var statusMessageValue: String?
    private var transition: LectureTransition?
    private var lastStoppedLecture: LectureRecord?
    private var retryingLectureIDs = Set<String>()
    private var audioLevelUpdatedAt: Date?
    private var speechAvailableValue = false
    private var translationAvailableValue = false
    private var deepSeekConfiguredValue = false

    init(repository: LectureRepository, paths: AppPaths, deepSeekConfigured: Bool = false) {
        self.repository = repository; self.paths = paths; deepSeek = DeepSeekClient(keyProvider: keychain)
        deepSeekConfiguredValue = deepSeekConfigured
        Task { [weak self] in
            guard let self else { return }
            let speechAvailable = LiveSpeechTranscriber.isAvailable
            let translationAvailable = await translation.isAvailable()
            self.withState {
                self.speechAvailableValue = speechAvailable
                self.translationAvailableValue = translationAvailable
            }
        }
    }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    func runtimeSnapshot() throws -> RuntimeSnapshot {
        let recording = recorder.hasActiveSession
        let receivingAudio = recorder.isReceivingAudio
        let duration = recorder.hasActiveSession ? recorder.duration : durationValue
        return withState {
            let level: Double
            if recording, receivingAudio, let updatedAt = audioLevelUpdatedAt {
                let age = max(0, Date().timeIntervalSince(updatedAt))
                level = age <= 0.25 ? audioLevelValue : audioLevelValue * exp(-(age - 0.25) * 3)
            } else {
                level = 0
            }
            return RuntimeSnapshot(
                recording: activeLecture != nil && recording,
                activeLectureID: activeLecture?.id,
                duration: duration,
                audioLevel: level,
                volatileEnglish: volatileEnglishValue,
                volatileChinese: volatileChineseValue,
                speechAvailable: speechAvailableValue,
                translationAvailable: translationAvailableValue,
                deepSeekConfigured: deepSeekConfiguredValue,
                statusMessage: statusMessageValue,
                transitioning: transition != nil,
                transitionKind: transition?.rawValue,
                receivingAudio: receivingAudio
            )
        }
    }

    func isDeepSeekConfigured() -> Bool { withState { deepSeekConfiguredValue } }
    var hasActiveLecture: Bool { withState { activeLecture != nil } }
    func storageUsage() throws -> LectureStorageUsage { try paths.storageUsage() }
    func openTranslationSettings() {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(AppleTranslationService.settingsURL)
        }
    }

    func startLecture(courseID: String, title: String?) async throws -> LectureRecord {
        enum StartDecision { case existing(LectureRecord), wait, reserved }
        let deadline = Date().addingTimeInterval(60)
        reserve: while true {
            let decision = withState { () -> StartDecision in
                if transition != nil { return .wait }
                if let activeLecture { return .existing(activeLecture) }
                transition = .starting
                return .reserved
            }
            switch decision {
            case .existing(let lecture): return lecture
            case .reserved: break reserve
            case .wait:
                guard Date() < deadline else { throw CoordinatorError.busy }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        defer { withState { transition = nil } }
        do {
            withState { statusMessageValue = "正在检查麦克风权限…" }
            try await LecturePermissionAuthorizer().authorizeMicrophone()
            guard let course = try repository.course(id: courseID) else { throw CoordinatorError.missingCourse }
            try ensureRecordingCapacity()
            withState { statusMessageValue = "正在准备本地 Whisper 英语识别…" }
            guard LiveSpeechTranscriber.isAvailable else { throw CoordinatorError.missingWhisper }
            let speechLocale = SpeechAssetManager.requestedLocale(
                identifier: course.speechLocaleIdentifier
            )
            withState { speechAvailableValue = true }
            var lecture = LectureRecord(courseID: courseID, title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? defaultTitle(), status: .recording)
            let audioURL = paths.audioURL(lectureID: lecture.id)
            lecture.audioPath = audioURL.path; try repository.upsertLecture(lecture)
            let liveSpeech = LiveSpeechTranscriber(vocabulary: course.vocabulary, locale: speechLocale)
            do {
                try await liveSpeech.start(
                    lectureID: lecture.id,
                    audioFormat: recorder.inputFormat,
                    handler: { [weak self] update in self?.receive(update) },
                    onError: { [weak self] error in
                        guard let self else { return }
                        self.withState {
                            self.statusMessageValue = "录音正常；本地英文识别警告：\(SecretRedactor.redact(String(describing: error)))"
                        }
                    }
                )
                try await recorder.start(
                    url: audioURL,
                    onBuffer: { [weak liveSpeech] buffer in liveSpeech?.append(buffer) },
                    onLevel: { [weak self] level in self?.setAudioLevel(level.normalized) },
                    onCheckpoint: { [weak self] checkpoint in self?.persistCheckpoint(checkpoint) },
                    onError: { [weak self] error in
                        guard let self else { return }
                        self.withState { self.statusMessageValue = "录音写入警告：\(error)" }
                    }
                )
                withState {
                    activeLecture = lecture
                    activeCourse = course
                    speech = liveSpeech
                    durationValue = 0
                    audioLevelValue = 0
                    audioLevelUpdatedAt = nil
                    volatileEnglishValue = ""
                    volatileChineseValue = ""
                    statusMessageValue = "麦克风收音正常；本地英文识别正在运行"
                }
            } catch {
                await liveSpeech.cancel(); try? repository.deleteLecture(id: lecture.id); clearActive(); throw error
            }
            return lecture
        } catch {
            withState { statusMessageValue = SecretRedactor.redact(String(describing: error)) }
            throw error
        }
    }

    func stopLecture() async throws -> LectureRecord {
        enum StopReservation {
            case wait
            case idle
            case stopped(LectureRecord)
            case reserved(LectureRecord, Course?, LiveSpeechTranscriber?)
        }
        let deadline = Date().addingTimeInterval(60)
        var requestedLectureID: String?
        reserve: while true {
            let reservation = withState { () -> StopReservation in
                if let requestedLectureID, lastStoppedLecture?.id == requestedLectureID {
                    return .stopped(lastStoppedLecture!)
                }
                if transition != nil { return .wait }
                guard let activeLecture else {
                    return lastStoppedLecture.map(StopReservation.stopped) ?? .idle
                }
                transition = .stopping
                return .reserved(activeLecture, activeCourse, speech)
            }
            switch reservation {
            case .wait:
                if requestedLectureID == nil {
                    requestedLectureID = withState { transition == .stopping ? activeLecture?.id : nil }
                }
                guard Date() < deadline else { throw CoordinatorError.busy }
                try await Task.sleep(for: .milliseconds(40))
            case .idle: throw CoordinatorError.notRecording
            case .stopped(let lecture): return lecture
            case .reserved(var lecture, let course, let liveSpeech):
                defer { withState { transition = nil } }
                let duration = recorder.stop()
                await liveSpeech?.finish()
                lecture.duration = duration
                lecture.endedAt = Date()
                lecture.status = .reviewingEnglish
                lecture.updatedAt = Date()
                try repository.upsertLecture(lecture)
                withState {
                    durationValue = duration
                    statusMessageValue = "录音已安全保存，正在本地复核英文"
                    lastStoppedLecture = lecture
                }
                clearActive(keepStatus: true)
                Task { [weak self] in await self?.processAfterClass(lecture: lecture, course: course) }
                return lecture
            }
        }
    }

    func addMarker(label: String?) throws -> LectureMarker {
        let lecture = withState { activeLecture }
        guard let lecture else { throw CoordinatorError.notRecording }
        let marker = LectureMarker(lectureID: lecture.id, time: recorder.duration, label: label?.nonEmpty ?? "课堂重点")
        try repository.appendMarker(marker); return marker
    }

    func retryProcessing(lectureID: String) async throws {
        guard let lecture = try repository.lecture(id: lectureID), let course = try repository.course(id: lecture.courseID) else { throw CoordinatorError.missingLecture }
        let canRetry = withState { () -> Bool in
            retryingLectureIDs.insert(lectureID).inserted
        }
        guard canRetry else { throw CoordinatorError.busy }
        defer { _ = withState { retryingLectureIDs.remove(lectureID) } }
        await processAfterClass(lecture: lecture, course: course)
    }

    func answer(question: String, courseID: String, lectureID: String?) async throws -> ChatMessage {
        let lectures = try repository.listLectures(courseID: courseID).filter { lectureID == nil || $0.id == lectureID }
        let evidence = try lectures.flatMap { lecture in
            let live = try repository.transcripts(lectureID: lecture.id, source: .liveEnglish)
            let reviewed = try repository.transcripts(lectureID: lecture.id, source: .reviewedEnglish)
            let source = TranscriptPreference.english(live: live, reviewed: reviewed)
            return GroundingEvidenceFactory.make(lecture: lecture, segments: source)
        }
        let user = ChatMessage(courseID: courseID, lectureID: lectureID, role: .user, text: question); try repository.appendChatMessage(user)
        let answer = try await deepSeek.answer(question: question, evidence: evidence)
        let message = ChatMessage(courseID: courseID, lectureID: lectureID, role: .assistant, text: answer.text, citations: answer.citations); try repository.appendChatMessage(message); return message
    }

    func saveDeepSeekKey(_ key: String) async throws {
        let previous = try keychain.loadAPIKey()
        do {
            try keychain.saveAPIKey(key)
            _ = try await deepSeek.testConnection()
            withState { deepSeekConfiguredValue = true }
        } catch {
            if let previous { try? keychain.saveAPIKey(previous) } else { try? keychain.deleteAPIKey() }
            withState { deepSeekConfiguredValue = previous != nil }
            throw error
        }
    }
    func deleteDeepSeekKey() throws { try keychain.deleteAPIKey(); withState { deepSeekConfiguredValue = false } }
    func testDeepSeek() async throws -> Bool { try await deepSeek.testConnection().isConnected }

    private func receive(_ update: TranscriptionUpdate) {
        if update.kind == .draft { withState { volatileEnglishValue = update.segment.text }; return }
        do { try repository.appendTranscript(update.segment) } catch { withState { statusMessageValue = "字幕保存失败：\(error)" } }
        withState { volatileEnglishValue = "" }
        Task { [weak self] in
            guard let self else { return }
            do {
                let chinese = try await translation.translate(update.segment.text)
                let segment = TranscriptSegment(lectureID: update.segment.lectureID, source: .liveChinese, startTime: update.segment.startTime, endTime: update.segment.endTime, text: chinese, isFinal: true, sourceSegmentID: update.segment.id)
                try repository.appendTranscript(segment); withState { self.volatileChineseValue = chinese }
            } catch {
                let message = AppleTranslationService.userMessage(for: error)
                withState {
                    self.translationAvailableValue = false
                    self.statusMessageValue = "英文录音正常；\(message)"
                }
            }
        }
    }

    private func processAfterClass(lecture original: LectureRecord, course: Course?) async {
        var lecture = original
        do {
            guard let path = lecture.audioPath else { throw CoordinatorError.missingAudio }
            let live = try repository.transcripts(lectureID: lecture.id, source: .liveEnglish)
            let existingReviewed = try repository.transcripts(lectureID: lecture.id, source: .reviewedEnglish)
            let reviewed: [TranscriptSegment]
            if existingReviewed.isEmpty {
                if lecture.status != .reviewingEnglish { lecture.status = .reviewingEnglish; lecture.updatedAt = Date(); try repository.upsertLecture(lecture) }
                reviewed = try WhisperCLI().transcribeAudioFile(
                    audioURL: URL(fileURLWithPath: path),
                    lectureID: lecture.id,
                    source: .reviewedEnglish,
                    vocabulary: course?.vocabulary ?? []
                )
                guard !reviewed.isEmpty else { throw CoordinatorError.emptyTranscript }
                for segment in reviewed { try repository.appendTranscript(segment) }
            } else {
                reviewed = existingReviewed
            }
            lecture.status = .processingDeepSeek; lecture.updatedAt = Date(); try repository.upsertLecture(lecture)
            let base = TranscriptPreference.english(live: live, reviewed: reviewed)
            if (try? keychain.loadAPIKey()) != nil {
                var translationWarning: String?
                do {
                    for segment in try await deepSeek.correctTranslation(englishSegments: base, vocabulary: course?.vocabulary ?? []) {
                        try repository.appendTranscript(segment)
                    }
                } catch {
                    translationWarning = SecretRedactor.redact(String(describing: error))
                }
                let summary = try await deepSeek.generateStudySummary(lectureTitle: lecture.title, transcript: base)
                try repository.appendSummary(.init(lectureID: lecture.id, content: summary))
                if translationWarning != nil {
                    withState { statusMessageValue = "总结已完成；中文校正暂时沿用实时翻译" }
                }
            }
            lecture.status = .completed; lecture.errorMessage = nil
        } catch { lecture.status = .failed; lecture.errorMessage = SecretRedactor.redact(String(describing: error)) }
        lecture.updatedAt = Date(); try? repository.upsertLecture(lecture)
        withState { statusMessageValue = lecture.status == .completed ? "课后复核与总结已完成" : "课后处理可在历史记录中重试" }
    }

    private func setAudioLevel(_ value: Double) {
        withState {
            audioLevelValue = value >= audioLevelValue ? value : max(value, audioLevelValue * 0.90)
            audioLevelUpdatedAt = Date()
        }
    }
    private func persistCheckpoint(_ checkpoint: RecordingCheckpoint) {
        guard var lecture = withState({ activeLecture }) else { return }
        lecture.duration = checkpoint.elapsedTime
        lecture.updatedAt = checkpoint.createdAt
        try? repository.upsertLecture(lecture)
    }
    private func ensureRecordingCapacity() throws {
        let values = try paths.recordings.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < 1_000_000_000 {
            throw CoordinatorError.lowDiskSpace
        }
    }
    private func clearActive(keepStatus: Bool = false) { withState { activeLecture = nil; activeCourse = nil; speech = nil; audioLevelValue = 0; audioLevelUpdatedAt = nil; volatileEnglishValue = ""; volatileChineseValue = ""; if !keepStatus { statusMessageValue = nil } } }
    private func defaultTitle() -> String { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm 课堂"; return formatter.string(from: Date()) }
}

private enum LectureTransition: String {
    case starting
    case stopping
}

private enum CoordinatorError: Error, CustomStringConvertible {
    case alreadyRecording, busy, notRecording, missingCourse, missingLecture, missingAudio, missingWhisper, emptyTranscript, lowDiskSpace
    var description: String {
        switch self { case .alreadyRecording: return "已有课堂正在录音或正在切换状态"; case .busy: return "Lecture 正在切换课堂状态，请稍后再试"; case .notRecording: return "当前没有正在录音的课堂"; case .missingCourse: return "请先选择课程"; case .missingLecture: return "未找到课堂"; case .missingAudio: return "录音文件不存在"; case .missingWhisper: return "本地 Whisper 英语识别引擎或模型不可用，请重新安装 Lecture"; case .emptyTranscript: return "本地复核没有识别到英文，请确认录音中有人声后重试"; case .lowDiskSpace: return "可用磁盘空间不足 1 GB，请先清理空间再开始课堂" }
    }
}

private extension String { var nonEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value } }
