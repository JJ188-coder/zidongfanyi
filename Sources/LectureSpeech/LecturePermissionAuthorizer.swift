@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

public enum LecturePermissionKind: Equatable, Sendable {
    case microphone
    case speechRecognition
}

public enum LecturePermissionStatus: Equatable, Sendable {
    case undetermined
    case denied
    case restricted
    case granted
}

public enum LecturePermissionError: Error, Equatable, CustomStringConvertible, Sendable {
    case denied(LecturePermissionKind)
    case restricted(LecturePermissionKind)
    case timedOut(LecturePermissionKind)

    public var description: String {
        switch self {
        case .denied(.microphone), .restricted(.microphone):
            return "请在系统设置 → 隐私与安全性 → 麦克风中允许 Lecture 使用麦克风"
        case .denied(.speechRecognition), .restricted(.speechRecognition):
            return "请在系统设置 → 隐私与安全性 → 语音识别中允许 Lecture 使用语音识别"
        case .timedOut(.microphone):
            return "等待麦克风权限超时。请在系统权限窗口选择允许，或到系统设置 → 隐私与安全性 → 麦克风中开启 Lecture，然后重试"
        case .timedOut(.speechRecognition):
            return "等待语音识别权限超时。请在系统权限窗口选择允许，或到系统设置 → 隐私与安全性 → 语音识别中开启 Lecture，然后重试"
        }
    }
}

@available(macOS 26.0, *)
public struct LecturePermissionAuthorizer: Sendable {
    public typealias StatusProvider = @Sendable () -> LecturePermissionStatus
    public typealias Requester = @Sendable (@escaping @Sendable (LecturePermissionStatus) -> Void) -> Void

    private let timeout: Duration
    private let microphoneStatus: StatusProvider
    private let requestMicrophone: Requester
    private let speechRecognitionStatus: StatusProvider
    private let requestSpeechRecognition: Requester

    public init(timeout: TimeInterval = 40) {
        self.init(
            timeout: timeout,
            microphoneStatus: { Self.systemMicrophoneStatus() },
            requestMicrophone: { completion in Self.requestSystemMicrophone(completion) },
            speechRecognitionStatus: { Self.systemSpeechRecognitionStatus() },
            requestSpeechRecognition: { completion in Self.requestSystemSpeechRecognition(completion) }
        )
    }

    public init(
        timeout: TimeInterval,
        microphoneStatus: @escaping StatusProvider,
        requestMicrophone: @escaping Requester,
        speechRecognitionStatus: @escaping StatusProvider,
        requestSpeechRecognition: @escaping Requester
    ) {
        self.timeout = .milliseconds(max(0, Int64(timeout * 1_000)))
        self.microphoneStatus = microphoneStatus
        self.requestMicrophone = requestMicrophone
        self.speechRecognitionStatus = speechRecognitionStatus
        self.requestSpeechRecognition = requestSpeechRecognition
    }

    public func authorize() async throws {
        try await authorizeMicrophone()
        try await authorizeSpeechRecognition()
    }

    public func authorizeMicrophone() async throws {
        try await authorize(
            .microphone,
            currentStatus: microphoneStatus,
            requester: requestMicrophone
        )
    }

    public func authorizeSpeechRecognition() async throws {
        try await authorize(
            .speechRecognition,
            currentStatus: speechRecognitionStatus,
            requester: requestSpeechRecognition
        )
    }

    private func authorize(
        _ kind: LecturePermissionKind,
        currentStatus: StatusProvider,
        requester: @escaping Requester
    ) async throws {
        let status: LecturePermissionStatus
        switch currentStatus() {
        case .granted:
            return
        case .denied:
            throw LecturePermissionError.denied(kind)
        case .restricted:
            throw LecturePermissionError.restricted(kind)
        case .undetermined:
            status = try await request(kind, requester: requester)
        }

        switch status {
        case .granted:
            return
        case .denied, .undetermined:
            throw LecturePermissionError.denied(kind)
        case .restricted:
            throw LecturePermissionError.restricted(kind)
        }
    }

    private func request(
        _ kind: LecturePermissionKind,
        requester: @escaping Requester
    ) async throws -> LecturePermissionStatus {
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            let completion = PermissionCompletion(continuation: continuation)
            requester { status in completion.resume(returning: status) }
            Task {
                try? await Task.sleep(for: timeout)
                completion.resume(throwing: LecturePermissionError.timedOut(kind))
            }
        }
    }

    private static func systemMicrophoneStatus() -> LecturePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .undetermined
        case .denied: return .denied
        case .granted: return .granted
        @unknown default: return .restricted
        }
    }

    private static func requestSystemMicrophone(
        _ completion: @escaping @Sendable (LecturePermissionStatus) -> Void
    ) {
        AVAudioApplication.requestRecordPermission { granted in
            completion(granted ? .granted : .denied)
        }
    }

    private static func systemSpeechRecognitionStatus() -> LecturePermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .undetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .granted
        @unknown default: return .restricted
        }
    }

    private static func requestSystemSpeechRecognition(
        _ completion: @escaping @Sendable (LecturePermissionStatus) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .notDetermined: completion(.undetermined)
            case .denied: completion(.denied)
            case .restricted: completion(.restricted)
            case .authorized: completion(.granted)
            @unknown default: completion(.restricted)
            }
        }
    }
}

private final class PermissionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LecturePermissionStatus, Error>?

    init(continuation: CheckedContinuation<LecturePermissionStatus, Error>) {
        self.continuation = continuation
    }

    func resume(returning status: LecturePermissionStatus) {
        take()?.resume(returning: status)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<LecturePermissionStatus, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
