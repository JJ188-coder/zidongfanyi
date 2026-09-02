import Foundation
import LectureCore
import LectureServer

private actor CallCounter {
    var startCount = 0
    var stopCount = 0
    func markStart() { startCount += 1 }
    func markStop() { stopCount += 1 }
}

private final class IdempotentRuntime: LectureRuntimeControlling, @unchecked Sendable {
    private enum Transition { case starting, stopping }
    private let lock = NSLock()
    private let counter: CallCounter
    private var active: LectureRecord?
    private var stopped: LectureRecord?
    private var transition: Transition?

    init(counter: CallCounter) { self.counter = counter }
    func runtimeSnapshot() throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func addMarker(label: String?) throws -> LectureMarker { throw SmokeError.unused }
    func retryProcessing(lectureID: String) async throws {}
    func answer(question: String, courseID: String, lectureID: String?) async throws -> ChatMessage { throw SmokeError.unused }
    func saveDeepSeekKey(_ key: String) async throws {}
    func deleteDeepSeekKey() throws {}
    func testDeepSeek() async throws -> Bool { true }
    func isDeepSeekConfigured() -> Bool { false }

    func startLecture(courseID: String, title: String?) async throws -> LectureRecord {
        while true {
            let decision = lock.withLock { () -> Int in
                if transition != nil { return 0 }
                if let active { return active.courseID == courseID ? 1 : 3 }
                transition = .starting
                return 2
            }
            if decision == 1 { return lock.withLock { active! } }
            if decision == 2 { break }
            if decision == 3 { throw SmokeError.alreadyRecording }
            try await Task.sleep(for: .milliseconds(5))
        }
        await counter.markStart()
        try await Task.sleep(for: .milliseconds(100))
        let lecture = LectureRecord(id: courseID, courseID: courseID, title: title ?? "Class", status: .recording)
        lock.withLock { active = lecture; transition = nil }
        return lecture
    }

    func stopLecture() async throws -> LectureRecord {
        while true {
            let decision = lock.withLock { () -> Int in
                if transition != nil { return 0 }
                if active == nil { return stopped == nil ? 3 : 1 }
                transition = .stopping
                return 2
            }
            if decision == 1 { return lock.withLock { stopped! } }
            if decision == 2 { break }
            if decision == 3 { throw SmokeError.unused }
            try await Task.sleep(for: .milliseconds(5))
        }
        await counter.markStop()
        try await Task.sleep(for: .milliseconds(100))
        let lecture = lock.withLock { active! }
        lock.withLock { active = nil; stopped = lecture; transition = nil }
        return lecture
    }
}

private enum SmokeError: Error { case alreadyRecording, unused }
private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock(); defer { unlock() }; return try body()
    }
}

@main struct CoordinatorConcurrencySmoke {
    static func main() async throws {
        let counter = CallCounter()
        let runtime = IdempotentRuntime(counter: counter)
        async let startA = runtime.startLecture(courseID: "course", title: nil)
        async let startB = runtime.startLecture(courseID: "course", title: nil)
        let starts = try await [startA, startB]
        guard Set(starts.map(\.id)).count == 1 else { exit(1) }
        do {
            _ = try await runtime.startLecture(courseID: "other-course", title: nil)
            exit(1)
        } catch SmokeError.alreadyRecording {}
        async let stopA = runtime.stopLecture()
        async let stopB = runtime.stopLecture()
        let stops = try await [stopA, stopB]
        guard Set(stops.map(\.id)).count == 1 else { exit(1) }
        let nextStart = try await runtime.startLecture(courseID: "next-course", title: nil)
        let nextStop = try await runtime.stopLecture()
        guard nextStop.id == nextStart.id, nextStop.id != stops[0].id else { exit(1) }
        let counts = await (counter.startCount, counter.stopCount)
        guard counts == (2, 2) else { exit(1) }
        print("start_same_id=true")
        print("different_course_rejected=true")
        print("stop_same_id=true")
        print("new_cycle_stop_id=true")
        print("single_start_transition=true")
        print("single_stop_transition=true")
    }
}
