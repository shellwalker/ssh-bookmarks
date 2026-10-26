import Combine
import ServiceManagement

/// 开机自启：macOS 13+ 的 SMAppService.mainApp。状态以系统为准，不另存一份。
@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published var lastError: String?

    var isEnabled: Bool { status == .enabled }

    /// 用户需要在“系统设置 › 通用 › 登录项”中批准。
    var requiresApproval: Bool { status == .requiresApproval }

    /// 系统找不到可注册的应用（通常是没放进“应用程序”文件夹，或签名无效）。
    var isUnavailable: Bool { status == .notFound }

    /// 用户可能在系统设置里改了登录项，设置页出现 / 应用重新激活时刷新。
    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if requiresApproval {
            openSystemSettings()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
