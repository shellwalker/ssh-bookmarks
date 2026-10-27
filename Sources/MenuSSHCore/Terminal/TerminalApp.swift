import Foundation

/// 支持的终端。
public enum TerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    /// macOS 自带 Terminal.app（“系统默认”）。
    case terminal
    case iTerm2
    case ghostty

    public var id: String { rawValue }

    public var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm2: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }

    /// 是否支持在已有窗口中开新标签页（Terminal.app 需要辅助功能权限模拟 ⌘T，因此不支持）。
    public var supportsNewTab: Bool {
        self != .terminal
    }
}

/// 执行方式：一段 AppleScript，或直接启动进程（不经过 shell）。
public enum TerminalLaunchPlan: Equatable, Sendable {
    case appleScript(String)
    case process(executable: String, arguments: [String])
}

/// 某个终端实际用哪条启动路径。只有 Ghostty 按版本分叉。
public enum TerminalLaunchMechanism: Equatable, Sendable {
    /// Terminal、iTerm2（各公开版本同一套字典），以及 Ghostty ≥ 1.3。
    case appleScript
    /// Ghostty < 1.3，或版本未知：`open -na Ghostty --args -e`，不经过 AppleScript。
    case legacyGhosttyProcess
}

/// 纯函数：根据终端类型生成启动计划，便于单元测试（不依赖 AppKit）。
public enum TerminalLaunchPlanner {
    /// Ghostty 从 1.3.0 开始提供 AppleScript 字典。
    public static let ghosttyAppleScriptMinimumVersion = "1.3.0"

    /// Terminal 与 iTerm2 不按版本分叉：iTerm2 的 `create window/tab with default profile` 覆盖目前的公开版本。
    /// 只有 Ghostty 在 1.3.0 前后换过启动方式。`version` 对 Terminal / iTerm2 会被忽略。
    public static func mechanism(for terminal: TerminalApp, version: String?) -> TerminalLaunchMechanism {
        switch terminal {
        case .terminal, .iTerm2:
            return .appleScript
        case .ghostty:
            if let version, compareVersions(version, ghosttyAppleScriptMinimumVersion) != .orderedAscending {
                return .appleScript
            }
            return .legacyGhosttyProcess
        }
    }

    /// - Parameters:
    ///   - argv: SSHCommandBuilder 生成的 argv（已校验）。
    ///   - ghosttyVersion: 已安装 Ghostty 的 CFBundleShortVersionString；nil 视为未知（走兼容路径）。
    public static func plan(
        terminal: TerminalApp,
        argv: [String],
        mode: TerminalOpenMode,
        ghosttyVersion: String? = nil
    ) -> TerminalLaunchPlan {
        let commandLine = ShellQuoting.join(argv)
        let literal = AppleScriptQuoting.stringLiteral(commandLine)

        switch terminal {
        case .terminal:
            // Terminal 未运行时，`tell` 会先启动它并自动打开一个空窗口；此时复用 window 1，避免出现两个窗口。
            return .appleScript(
                """
                set wasRunning to application id "com.apple.Terminal" is running
                tell application id "com.apple.Terminal"
                    if wasRunning then
                        do script \(literal)
                    else
                        activate
                        delay 0.3
                        if (count of windows) > 0 then
                            do script \(literal) in window 1
                        else
                            do script \(literal)
                        end if
                    end if
                    activate
                end tell
                """)

        case .iTerm2:
            let create: String
            switch mode {
            case .newTab:
                create = """
                        if (count of windows) = 0 then
                            set w to (create window with default profile)
                        else
                            tell current window to create tab with default profile
                            set w to current window
                        end if
                    """
            case .newWindow:
                create = """
                        set w to (create window with default profile)
                    """
            }
            return .appleScript(
                """
                tell application id "com.googlecode.iterm2"
                    activate
                \(create)
                    tell current session of w
                        write text \(literal)
                    end tell
                end tell
                """)

        case .ghostty:
            if mechanism(for: .ghostty, version: ghosttyVersion) == .appleScript {
                let create: String
                switch mode {
                case .newTab:
                    create = """
                            if (count of windows) = 0 then
                                new window with configuration cfg
                            else
                                new tab in front window with configuration cfg
                            end if
                        """
                case .newWindow:
                    create = """
                            new window with configuration cfg
                        """
                }
                // 用 initial input 把命令“输入”到登录 shell：断开后仍停留在本地 shell，与 Terminal/iTerm2 行为一致。
                return .appleScript(
                    """
                    tell application id "com.mitchellh.ghostty"
                        activate
                        set cfg to new surface configuration
                        set initial input of cfg to \(literal) & linefeed
                    \(create)
                    end tell
                    """)
            }
            // 兼容旧版 Ghostty：开一个新实例，-e 之后是要执行的命令（argv 直接传递，不经 shell）。
            return .process(
                executable: "/usr/bin/open",
                arguments: ["-na", "Ghostty", "--args", "--quit-after-last-window-closed=true", "-e"] + argv
            )
        }
    }

    /// 简单的语义化版本比较（"1.3.0" vs "1.2.10"）。
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}
