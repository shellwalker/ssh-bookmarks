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
            // 宽窗口保持接近生产尺寸（站点窗口 920×580），不再铺满屏幕。
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

    /// 宽窗口靠左铺满高度，面板靠右。两者重叠时，XCTest 的点击会落到前面的窗口上。
    private static func placeWideWindowForUITest(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let wide = window.frame.width > 600
        let width = wide ? min(window.frame.width, 960) : window.frame.width
        let height = wide ? min(window.frame.height, min(580, visible.height - 16)) : window.frame.height
        guard width > 200, height > 200 else { return }
        let frame = NSRect(
            x: wide ? visible.minX + 8 : visible.maxX - width - 8,
            y: visible.maxY - height - 8,
            width: width,
            height: height
        )
        let same =
            abs(window.frame.minX - frame.minX) < 2 && abs(window.frame.minY - frame.minY) < 2
            && abs(window.frame.width - frame.width) < 2 && abs(window.frame.height - frame.height) < 2
        if same { return }
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
