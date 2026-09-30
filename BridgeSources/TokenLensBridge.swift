import AppKit
import Foundation

@MainActor
final class ChatGPTLifecycleBridge: NSObject {
    private let workspace = NSWorkspace.shared
    private let assistantBundleIdentifiers: Set<String> = [
        "com.openai.codex", "com.deepseek.dsh", "com.workbuddy.workbuddy-ai",
        "com.anthropic.claudefordesktop", "com.tencent.codebuddycn", "com.tencent.codebuddy"
    ]
    private let tokenLensBundleIdentifier = "cn.liuli.tokenlens"
    private var synchronizationTimer: Timer?

    func start() {
        let center = workspace.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationStateChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationStateChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(periodicSynchronization(_:)),
            userInfo: nil,
            repeats: true
        )
        synchronizationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        synchronize()
    }

    @objc private func applicationStateChanged(_ notification: Notification) {
        synchronize()
    }

    @objc private func periodicSynchronization(_ timer: Timer) {
        synchronize()
    }

    private func synchronize() {
        let anAssistantIsRunning = workspace.runningApplications.contains {
            $0.bundleIdentifier.map { assistantBundleIdentifiers.contains($0) } ?? false
        }
        let tokenLensApplications = workspace.runningApplications.filter {
            $0.bundleIdentifier == tokenLensBundleIdentifier
        }

        if anAssistantIsRunning {
            if tokenLensApplications.isEmpty {
                launchTokenLens()
            }
        } else {
            tokenLensApplications.forEach { $0.terminate() }
        }
    }

    private func launchTokenLens() {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let appURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        workspace.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }
}

@main
struct TokenLensBridgeMain {
    @MainActor
    static func main() {
        let bridge = ChatGPTLifecycleBridge()
        bridge.start()
        RunLoop.main.run()
    }
}
