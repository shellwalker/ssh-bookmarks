import AppKit
import MenuSSHCore

/// 控制 Dock 图标。Info.plist 中 LSUIElement = YES，启动时默认无 Dock 图标；
/// 运行时通过 NSApp.setActivationPolicy(.regular / .accessory) 切换。
@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private var mode: DockIconMode = .hidden
    private var observers: [NSObjectProtocol] = []

    func start(mode: DockIconMode) {
        self.mode = mode
        if observers.isEmpty {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
            ]
            for name in names {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // willClose 时窗口仍是可见的，下一轮 runloop 再判断。
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.update() }
                    }
                }
                observers.append(token)
            }
        }
        update()
    }

    func setMode(_ newMode: DockIconMode) {
        mode = newMode
        update()
    }

    func update() {
        let show = mode.showsDockIcon(hasVisibleWindow: hasVisibleAppWindow)
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy != policy else { return }
        // 先记下当前可见窗口：切换 activation policy 时系统可能把应用移到后台，
        // 设置窗口会“消失”在其他应用后面，下一轮 runloop 再把它们带回前台（无需重启）。
        let visibleWindows = appWindows.filter(\.isVisible)
        guard NSApp.setActivationPolicy(policy) else { return }
        guard !visibleWindows.isEmpty || show else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppActivation.bringToFront()
                for window in visibleWindows where !window.isMiniaturized {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    /// 真正的应用窗口（排除菜单栏面板这类 NSPanel 和无标题栏窗口）。
    private var appWindows: [NSWindow] {
        NSApp.windows.filter { window in
            !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
        }
    }

    private var hasVisibleAppWindow: Bool {
        appWindows.contains(where: \.isVisible)
    }
}
