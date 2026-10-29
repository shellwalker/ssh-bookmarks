import AppKit
import Combine
import SSHBookmarksCore

/// 应用设置，持久化到 UserDefaults。密码等敏感信息不在这里。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore(defaults: UITestLaunch.userDefaults())

    private enum Keys {
        static let appearance = "appearance"
        static let language = "language"
        static let dockIconMode = "dockIconMode"
        static let terminal = "terminal"
        static let openMode = "terminalOpenMode"
        static let sshPath = "sshPath"
        static let closePanelAfterConnect = "closePanelAfterConnect"
        static let showTunnelCount = "showTunnelCount"
        static let diagnosticLog = "diagnosticLogEnabled"
        static let diagnosticRedactNames = "diagnosticRedactNames"
        static let syncEnabled = "syncEnabled"
        static let syncFolder = "syncFolderPath"
        static let deviceId = "syncDeviceId"
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
            languageChangePending = language != launchLanguage
        }
    }

    /// 本次启动时生效的语言；改回去就不再提示重启。
    private let launchLanguage: AppLanguage
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

    /// 菜单栏图标在隧道数量大于 0 时显示数字。默认开。
    @Published var showTunnelCount: Bool {
        didSet { defaults.set(showTunnelCount, forKey: Keys.showTunnelCount) }
    }

    /// 诊断文件默认关。os.Logger 不受这个开关影响。
    @Published var diagnosticLogEnabled: Bool {
        didSet { defaults.set(diagnosticLogEnabled, forKey: Keys.diagnosticLog) }
    }

    /// 主机名和用户名默认打码。密码、令牌和私钥始终打码，没有相反的开关。
    @Published var diagnosticRedactNames: Bool {
        didSet { defaults.set(diagnosticRedactNames, forKey: Keys.diagnosticRedactNames) }
    }

    /// 默认关闭。打开前要明确告诉用户：同步文件里的主机名和用户名是明文。
    @Published var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Keys.syncEnabled) }
    }

    /// nil 表示用 iCloud Drive/MenuSSH。用户可以改成任意文件夹。
    @Published var syncFolderPath: String? {
        didSet {
            if let syncFolderPath, !syncFolderPath.isEmpty {
                defaults.set(syncFolderPath, forKey: Keys.syncFolder)
            } else {
                defaults.removeObject(forKey: Keys.syncFolder)
            }
        }
    }

    var resolvedSyncDirectory: URL {
        if let syncFolderPath, !syncFolderPath.isEmpty {
            return URL(fileURLWithPath: syncFolderPath, isDirectory: true)
        }
        return SyncPaths.iCloudDirectory(home: NSHomeDirectory())
    }

    /// 这台 Mac 的稳定 id。时间戳相同时，字典序更大的一边胜出。
    var deviceId: String {
        if let existing = defaults.string(forKey: Keys.deviceId), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: Keys.deviceId)
        return created
    }

    /// 下次设置窗口出现时切到这一页（关于 / 从菜单打开）。用完即清。
    @Published var pendingSettingsPane: SettingsPaneID?

    init(defaults: UserDefaults = .standard) {
        LegacyDataMigration.copyDefaultsIfNeeded(into: defaults)
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        let storedLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        language = storedLanguage
        launchLanguage = storedLanguage
        dockIconMode = DockIconMode(rawValue: defaults.string(forKey: Keys.dockIconMode) ?? "") ?? .followWindow
        terminal = TerminalApp(rawValue: defaults.string(forKey: Keys.terminal) ?? "") ?? .terminal
        openMode = TerminalOpenMode(rawValue: defaults.string(forKey: Keys.openMode) ?? "") ?? .newWindow
        sshPath = defaults.string(forKey: Keys.sshPath) ?? "/usr/bin/ssh"
        closePanelAfterConnect = defaults.object(forKey: Keys.closePanelAfterConnect) as? Bool ?? true
        showTunnelCount = defaults.object(forKey: Keys.showTunnelCount) as? Bool ?? true
        diagnosticLogEnabled = defaults.object(forKey: Keys.diagnosticLog) as? Bool ?? false
        diagnosticRedactNames = defaults.object(forKey: Keys.diagnosticRedactNames) as? Bool ?? true
        syncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? false
        let storedFolder = defaults.string(forKey: Keys.syncFolder)
        syncFolderPath = (storedFolder?.isEmpty == false) ? storedFolder : nil
        if UITestLaunch.isEnabled {
            syncEnabled = false
            closePanelAfterConnect = false
            dockIconMode = .visible
            if let forced = UITestLaunch.forcedAppearance {
                appearance = forced
            }
        }
    }

    /// 修改语言后“立即重启”：1 秒后由 /bin/sh 重新打开本应用，然后退出。
    /// 应用路径作为 $0 传入，不拼接进脚本，避免路径中的特殊字符被 shell 解释。
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("SSH Bookmarks relaunch failed: \(error.localizedDescription)")
        }
    }
}
