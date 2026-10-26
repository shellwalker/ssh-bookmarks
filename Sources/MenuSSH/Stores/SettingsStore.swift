import Foundation
import MenuSSHCore

/// 应用设置，持久化到 UserDefaults。密码等敏感信息不在这里。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let appearance = "appearance"
        static let language = "language"
        static let dockIconMode = "dockIconMode"
        static let terminal = "terminal"
        static let openMode = "terminalOpenMode"
        static let sshPath = "sshPath"
        static let closePanelAfterConnect = "closePanelAfterConnect"
    }

    private let defaults: UserDefaults

    @Published var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            AppearanceController.apply(appearance)
        }
    }

    /// 修改后写入 AppleLanguages，重启生效。
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            if let override = language.appleLanguagesOverride {
                defaults.set(override, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
            languageChangePending = true
        }
    }

    @Published private(set) var languageChangePending = false

    @Published var dockIconMode: DockIconMode {
        didSet {
            defaults.set(dockIconMode.rawValue, forKey: Keys.dockIconMode)
            DockIconController.shared.setMode(dockIconMode)
        }
    }

    @Published var terminal: TerminalApp {
        didSet { defaults.set(terminal.rawValue, forKey: Keys.terminal) }
    }

    @Published var openMode: TerminalOpenMode {
        didSet { defaults.set(openMode.rawValue, forKey: Keys.openMode) }
    }

    @Published var sshPath: String {
        didSet { defaults.set(sshPath, forKey: Keys.sshPath) }
    }

    @Published var closePanelAfterConnect: Bool {
        didSet { defaults.set(closePanelAfterConnect, forKey: Keys.closePanelAfterConnect) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        dockIconMode = DockIconMode(rawValue: defaults.string(forKey: Keys.dockIconMode) ?? "") ?? .followWindow
        terminal = TerminalApp(rawValue: defaults.string(forKey: Keys.terminal) ?? "") ?? .terminal
        openMode = TerminalOpenMode(rawValue: defaults.string(forKey: Keys.openMode) ?? "") ?? .newWindow
        sshPath = defaults.string(forKey: Keys.sshPath) ?? "/usr/bin/ssh"
        closePanelAfterConnect = defaults.object(forKey: Keys.closePanelAfterConnect) as? Bool ?? true
    }
}
