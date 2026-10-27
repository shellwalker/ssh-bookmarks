import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore.shared
        AppearanceController.apply(settings.appearance)
        DockIconController.shared.start(mode: settings.dockIconMode)
        HostStoreModel.shared.reload()
        if UITestLaunch.isEnabled {
            // LSUIElement 应用不会自动把 WindowGroup 摆到前面。测试模式下一轮再激活。
            // 宽窗口钉在屏幕可见区域顶部，编辑表单才不会伸出窗口，XCUITest 才能点到下面的字段。
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow else { return }
                    Self.placeWideWindowForUITest(window)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppActivation.bringToFront()
                    for window in NSApp.windows {
                        window.makeKeyAndOrderFront(nil)
                        Self.placeWideWindowForUITest(window)
                    }
                }
            }
        }
    }

    /// 只动站点窗口和设置窗口。面板和编辑 sheet 更窄，保持原样。
    private static func placeWideWindowForUITest(_ window: NSWindow) {
        guard window.frame.width > 600, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = visible.height - 8
        let width = min(max(window.frame.width, 920), visible.width - 16)
        let frame = NSRect(x: visible.minX + 8, y: visible.maxY - height - 8, width: width, height: height)
        let sameOrigin = abs(window.frame.minY - frame.minY) < 2 && abs(window.frame.height - frame.height) < 2
        if sameOrigin { return }
        window.isRestorable = false
        window.setFrame(frame, display: true)
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
