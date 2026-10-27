@preconcurrency import AppKit
import SSHBookmarksCore
import SwiftUI

/// 菜单栏面板的键盘处理。
///
/// 不用 `onKeyPress`：焦点在搜索框时，↑/↓/Return 会先被 NSTextField 的 field editor 吃掉，
/// SwiftUI 的 `onKeyPress` 收不到。这里用只作用于面板窗口的本地事件监视器，在 field editor 之前拦截。
@MainActor
final class PanelKeyMonitor: ObservableObject {
    /// 返回 true 表示已处理（事件不再传递）。
    var onKey: ((PanelKey) -> Bool)?
    /// 面板每次弹出（窗口成为 key window）时调用。
    var onOpen: (() -> Void)?

    private(set) weak var window: NSWindow?
    private var monitor: Any?
    private var becomeKeyObserver: NSObjectProtocol?

    func attach(to window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window

        if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onOpen?()
            }
        }

        if monitor == nil {
            // 本地监视器在安装它的线程（主线程）上回调。assumeIsolated 把回调标回 MainActor，
            // 这样可以在 field editor 之前处理方向键，同时满足 Swift 6 工具链的隔离检查。
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // 只把“是否吃掉”传出隔离域。NSEvent 的 Sendable 一致性在 SDK 里被标成不可用。
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    return self.process(event)
                }
                return handled ? nil : event
            }
        }
        // 第一次弹出时窗口在挂上之前就已是 key window，不会收到通知；那一次由视图的 onAppear 负责初始化。
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
        becomeKeyObserver = nil
        window = nil
    }

    /// 关闭面板。先用 SwiftUI 的 dismiss，若窗口仍在（MenuBarExtra 在部分系统上不响应 dismiss）再直接关窗。
    func close(using dismiss: DismissAction) {
        dismiss()
        // MenuBarExtra 在部分系统上不响应 SwiftUI dismiss，下一轮 runloop 再直接隐藏面板。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.window, window.isVisible else { return }
                window.orderOut(nil)
            }
        }
    }

    private func process(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        // 输入法正在组词（拼音候选等）时，方向键 / 回车 / Esc 留给输入法。
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) { return false }
        guard let key = PanelKey(keyCode: event.keyCode, control: flags.contains(.control)) else { return false }
        return onKey?(key) ?? false
    }
}

/// 取得 SwiftUI 视图所在的 NSWindow。
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // NSView 在新 SDK 里是 MainActor；旧 SDK 里这个方法不是。两种情况下都在主线程调用。
            MainActor.assumeIsolated {
                self.onWindow?(self.window)
            }
        }
    }
}
