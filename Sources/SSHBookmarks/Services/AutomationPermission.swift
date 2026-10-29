import AppKit
import SSHBookmarksCore

/// “自动化”权限（Apple Events）检查：SSH Bookmarks 通过 AppleScript 控制终端，需要用户在
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
        // 询问用户时会阻塞，不能放在主线程。闭包本身是同步的，挂起点在 task.value。
        let task = Task.detached(priority: .userInitiated) { () -> Int32 in
            // `typeWildCard` 是 DescType。Swift 接口不接受把它传给 AEEventClass / AEEventID，
            // 虽然它们都是 FourCharCode。'****' 就是这个通配符。
            let anyEventClass = AEEventClass(0x2A2A_2A2A)
            let anyEventID = AEEventID(0x2A2A_2A2A)
            var target = AEAddressDesc()
            defer { AEDisposeDesc(&target) }
            let bytes = Array(bundleID.utf8)
            // AECreateDesc 在这个 SDK 里返回 OSErr（Int16），权限 API 返回 OSStatus（Int32）。
            let created: OSStatus = bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return OSStatus(-600) }
                return OSStatus(AECreateDesc(typeApplicationBundleID, base, raw.count, &target))
            }
            guard created == 0 else { return created }
            return AEDeterminePermissionToAutomateTarget(&target, anyEventClass, anyEventID, ask)
        }
        let status = await task.value
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
