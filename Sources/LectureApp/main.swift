import AppKit
import Foundation
import LectureCore
import LectureServer

@available(macOS 26.4, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var server: LoopbackHTTPServer?
    private var coordinator: LectureCoordinator?
    private var terminationTask: Task<Void, Never>?
    private var terminationReplyPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        Task { await launchService() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator?.hasActiveLecture == true else { return .terminateNow }
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        terminationTask = Task { [weak self, weak sender] in
            guard let self else { return }
            _ = try? await coordinator?.stopLecture()
            server?.stop()
            await MainActor.run {
                self.terminationReplyPending = false
                sender?.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "L."
        statusItem.button?.toolTip = "Lecture 本地课堂助手"
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 Lecture 网页", action: #selector(openBrowser), keyEquivalent: "o")
        menu.addItem(withTitle: "停止当前课堂", action: #selector(stopLecture), keyEquivalent: ".")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Lecture", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @MainActor private func launchService() async {
        do {
            KeyFileImporter.importIfPresent(url: AppPaths.live.root.appendingPathComponent(".pending-deepseek-key"))
            let paths = AppPaths.live
            try paths.createDirectories()
            let repository = try SQLiteLectureRepository(databaseURL: paths.database)
            try paths.createDirectories()
            recoverInterruptedLectures(repository)
            let coordinator = LectureCoordinator(
                repository: repository,
                paths: paths,
                deepSeekConfigured: DeepSeekKeychainStore().hasAPIKeyReference()
            )
            let resourceRoot = Bundle.module.resourceURL ?? Bundle.module.bundleURL
            let server = LoopbackHTTPServer { token in
                LectureAPIRouter(repository: repository, runtime: coordinator, token: token, resourcesRoot: resourceRoot)
            }
            _ = try await server.start()
            self.coordinator = coordinator
            self.server = server
            openBrowser()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Lecture 无法启动"
            alert.informativeText = SecretRedactor.redact(String(describing: error))
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    private func recoverInterruptedLectures(_ repository: LectureRepository) {
        guard let items = try? repository.incompleteLectures() else { return }
        for var lecture in items {
            switch lecture.status {
            case .recording:
                lecture.status = .interrupted
                lecture.endedAt = Date()
                lecture.errorMessage = "Lecture 上次退出时仍在录音；原始音频已保留，可以继续课后复核。"
            case .reviewingEnglish, .translatingChinese, .processingDeepSeek:
                lecture.status = .failed
                lecture.errorMessage = "上次课后处理被中断，可以安全重试。"
            default:
                continue
            }
            lecture.updatedAt = Date()
            try? repository.upsertLecture(lecture)
        }
    }

    @MainActor @objc private func openBrowser() {
        guard let url = server?.browserURL() else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor @objc private func stopLecture() { Task { _ = try? await coordinator?.stopLecture() } }
    @MainActor @objc private func quit() { NSApplication.shared.terminate(nil) }
}

if #available(macOS 26.4, *) {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
} else {
    fputs("Lecture 需要 macOS 26.4 或更高版本。\n", stderr)
}
