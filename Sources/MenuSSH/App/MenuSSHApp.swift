import MenuSSHCore
import SwiftUI

enum WindowID {
    static let hosts = "hosts"
    static let settings = "settings"
}

@MainActor
struct MenuSSHApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// `openWindow` is delivered to the App, not to views built inside `.commands`.
    @Environment(\.openWindow) private var openWindow
    @StateObject private var hostStore: HostStoreModel
    @StateObject private var settings: SettingsStore

    init() {
        // The same singletons AppDelegate uses. Initializing the wrapper here keeps
        // the lookup on the main actor; a default-value expression is nonisolated.
        _hostStore = StateObject(wrappedValue: HostStoreModel.shared)
        _settings = StateObject(wrappedValue: SettingsStore.shared)
    }

    var body: some Scene {
        // 第一个 Scene 是菜单栏常驻面板（window 风格，可放搜索框和列表）。
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(hostStore)
                .environmentObject(settings)
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)

        // 站点管理主窗口（Termius 风格：左侧分组，右侧站点列表）。
        Window("MenuSSH", id: WindowID.hosts) {
            HostManagerView()
                .environmentObject(hostStore)
                .environmentObject(settings)
        }
        .defaultSize(width: 920, height: 580)

        // 设置窗口（参考 magpie：左侧导航 + 右侧一行一项）。
        // 不用 SwiftUI `Settings` scene：在 LSUIElement 应用里从菜单栏打开它不可靠。
        Window("Settings", id: WindowID.settings) {
            SettingsWindowView()
                .environmentObject(hostStore)
                .environmentObject(settings)
        }
        .defaultSize(width: 860, height: 560)
        .commands {
            // openWindow 挂在 App 上：嵌在 commands 里的子 View 拿不到这个 environment。
            CommandGroup(replacing: .appInfo) {
                Button("About MenuSSH") {
                    settings.pendingSettingsPane = .about
                    openWindow(id: WindowID.settings)
                    AppActivation.bringToFront()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    settings.pendingSettingsPane = nil
                    openWindow(id: WindowID.settings)
                    AppActivation.bringToFront()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit MenuSSH") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
