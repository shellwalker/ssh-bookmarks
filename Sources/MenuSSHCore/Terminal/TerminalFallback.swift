import Foundation

/// 配置的终端没装时，改用哪一个、以及要不要告诉用户。
public struct TerminalFallbackNotice: Equatable, Sendable {
    public var missing: TerminalApp
    public var used: TerminalApp

    public init(missing: TerminalApp, used: TerminalApp) {
        self.missing = missing
        self.used = used
    }
}

/// 选择本次会话实际使用的终端。不改用户保存的设置。
public enum TerminalFallback {
    /// 首选缺失时的查找顺序。Terminal.app 永远垫底，即使没有出现在 `installed` 里也使用它。
    public static let order: [TerminalApp] = [.iTerm2, .ghostty, .terminal]

    public static func resolve(preferred: TerminalApp, installed: Set<TerminalApp>) -> (
        terminal: TerminalApp, notice: TerminalFallbackNotice?
    ) {
        if preferred == .terminal || installed.contains(preferred) {
            return (preferred, nil)
        }
        for candidate in order where candidate != preferred {
            if candidate == .terminal || installed.contains(candidate) {
                return (candidate, TerminalFallbackNotice(missing: preferred, used: candidate))
            }
        }
        return (.terminal, TerminalFallbackNotice(missing: preferred, used: .terminal))
    }
}
