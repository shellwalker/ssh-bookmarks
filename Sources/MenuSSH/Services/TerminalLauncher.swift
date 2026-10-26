import AppKit
import MenuSSHCore

enum TerminalLaunchError: LocalizedError {
    case invalidHost(SSHCommandError)
    case terminalNotInstalled(TerminalApp)
    case automationDenied(TerminalApp)
    case appleScript(String)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost(let e):
            return String(localized: "Invalid host settings: \(String(describing: e))")
        case .terminalNotInstalled(let t):
            return String(localized: "\(t.displayName) is not installed.")
        case .automationDenied(let t):
            return String(
                localized:
                    "MenuSSH is not allowed to control \(t.displayName). Enable it in System Settings › Privacy & Security › Automation.")
        case .appleScript(let message):
            return message
        case .process(let message):
            return message
        }
    }
}

/// 把 TerminalLaunchPlanner 的计划在 macOS 上执行。
@MainActor
struct TerminalLauncher {
    var sshPath: String
    var terminal: TerminalApp
    var openMode: TerminalOpenMode

    static func isInstalled(_ terminal: TerminalApp) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) != nil
    }

    static func installedVersion(of terminal: TerminalApp) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier),
            let bundle = Bundle(url: url)
        else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func launch(_ host: SSHHost) throws {
        let builder = SSHCommandBuilder(sshPath: sshPath, homeDirectory: NSHomeDirectory())
        let argv: [String]
        do {
            argv = try builder.argv(for: host)
        } catch let error as SSHCommandError {
            throw TerminalLaunchError.invalidHost(error)
        }

        guard Self.isInstalled(terminal) else { throw TerminalLaunchError.terminalNotInstalled(terminal) }

        let plan = TerminalLaunchPlanner.plan(
            terminal: terminal,
            argv: argv,
            mode: openMode,
            ghosttyVersion: terminal == .ghostty ? Self.installedVersion(of: .ghostty) : nil
        )
        try execute(plan)
    }

    private func execute(_ plan: TerminalLaunchPlan) throws {
        switch plan {
        case .appleScript(let source):
            // TODO(M1)：NSAppleScript 是同步调用，首次授权弹窗期间会阻塞主线程；
            // 后续可改为后台串行队列 + NSAppleScript（需保证同一线程）或 NSUserAppleScriptTask。
            guard let script = NSAppleScript(source: source) else {
                throw TerminalLaunchError.appleScript("Failed to compile AppleScript")
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                // -1743 errAEEventNotPermitted：用户在“自动化”里拒绝了授权。
                if code == -1743 { throw TerminalLaunchError.automationDenied(terminal) }
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
                throw TerminalLaunchError.appleScript(message)
            }
        case .process(let executable, let arguments):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            do {
                try process.run()
            } catch {
                throw TerminalLaunchError.process(error.localizedDescription)
            }
        }
    }
}
