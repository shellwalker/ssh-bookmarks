import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore.shared
        AppearanceController.apply(settings.appearance)
        DockIconController.shared.start(mode: settings.dockIconMode)
        HostStoreModel.shared.reload()
    }

    /// 菜单栏应用：关闭最后一个窗口不退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// 打开普通窗口时需要主动激活，否则 accessory 模式下窗口可能在其他应用后面。
@MainActor
enum AppActivation {
    static func bringToFront() {
        NSApp.activate()
    }
}
