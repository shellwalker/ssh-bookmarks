import AppKit
import MenuSSHCore

/// “自动化”权限（Apple Events）检查：MenuSSH 通过 AppleScript 控制终端，需要用户在
/// 系统设置 › 隐私与安全性 › 自动化 中允许。
enum AutomationPermission {
    enum Status: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
        /// 目标应用没在运行，系统无法判断（不代表没有权限）。
        case targetNotRunning
        case unknown(Int32)
    }

    /// 检查（可选：弹出系统授权对话框）是否允许向终端发送 Apple Events。
    /// `AEDeterminePermissionToAutomateTarget` 在 ask = true 时会阻塞等待用户选择，所以放到后台线程执行。
    static func check(_ terminal: TerminalApp, ask: Bool) async -> Status {
        let bundleID = terminal.bundleIdentifier
        let status: Int32 = await Task.detached(priority: .userInitiated) { () -> Int32 in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            guard let desc = target.aeDesc else { return -600 }
            return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        }.value
        switch status {
        case 0: return .granted  // noErr
        case -1743: return .denied  // errAEEventNotPermitted
        case -1744: return .notDetermined  // errAEEventWouldRequireUserConsent
        case -600: return .targetNotRunning  // procNotFound
        default: return .unknown(status)
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
