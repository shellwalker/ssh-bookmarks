import Foundation
import SSHBookmarksCore
import SwiftUI

/// UI 测试专用开关。未设置环境变量时，正式启动路径完全不变。
enum UITestLaunch {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var isEnabled: Bool {
        if EnvironmentAlias.flag(primary: ProductEnvironment.uiTest, legacy: ProductEnvironment.uiTestLegacy, environment: environment) {
            return true
        }
        return ProcessInfo.processInfo.arguments.contains("--ui-test")
    }

    /// 独立的 hosts.json 目录。只在测试模式生效，避免误伤用户数据。
    static var dataDirectory: URL? {
        guard isEnabled,
            let path = EnvironmentAlias.string(
                primary: ProductEnvironment.dataDirectory,
                legacy: ProductEnvironment.dataDirectoryLegacy,
                environment: environment
            )
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 测试可以指向一份假的 `~/.ssh`，用来列出密钥和导入 config。正式启动始终是用户主目录。
    static var sshDirectory: URL {
        if isEnabled,
            let path = EnvironmentAlias.string(
                primary: ProductEnvironment.sshDirectory,
                legacy: ProductEnvironment.sshDirectoryLegacy,
                environment: environment
            )
        {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
    }

    /// 把本该发给终端的 argv 追加写成一行 JSON，而不是执行 AppleScript。
    static var fakeTerminalLogURL: URL? {
        guard isEnabled,
            let path = EnvironmentAlias.string(
                primary: ProductEnvironment.fakeTerminalLog,
                legacy: ProductEnvironment.fakeTerminalLogLegacy,
                environment: environment
            )
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var forcedAppearance: AppearanceMode? {
        switch EnvironmentAlias.string(
            primary: ProductEnvironment.appearance,
            legacy: ProductEnvironment.appearanceLegacy,
            environment: environment
        ) {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// 每次测试进程使用独立的 UserDefaults，并在启动时清空。
    static func userDefaults() -> UserDefaults {
        guard isEnabled else { return .standard }
        let name = "com.shellwalker.SSHBookmarks.uitest"
        guard let defaults = UserDefaults(suiteName: name) else { return .standard }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func appendFakeTerminalLog(url: URL, argv: [String], startup: String?) throws {
        struct Event: Encodable {
            var argv: [String]
            var startup: String?
        }
        let trimmed = startup?.isEmpty == false ? startup : nil
        var line = try JSONEncoder().encode(Event(argv: argv, startup: trimmed))
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let directory = url.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

/// 测试模式把一块界面收成可查询的容器，子元素仍然暴露。正式启动不加这个修饰，VoiceOver 行为不变。
struct UITestContainer: ViewModifier {
    var identifier: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if UITestLaunch.isEnabled {
            content.accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// 稳定的 accessibilityIdentifier。UI 测试目标不能链接 App，字面量需与这里保持一致。
enum UITestID {
    static let panel = "screen.panel"
    static let hosts = "screen.hosts"
    static let settings = "screen.settings"
    static let panelSearch = "panel.search"
    static let panelManage = "panel.manageHosts"
    static let panelSettings = "panel.settings"
    static let panelImport = "panel.import"
    static let panelNewHost = "panel.newHost"
    static let hostsNew = "hosts.new"
    static let hostsImport = "hosts.import"
    static let hostsNotice = "hosts.notice"
    static let hostsUndo = "hosts.undo"
    static let hostsSettings = "hosts.settings"
    static let hostsNewGroup = "hosts.newGroup"
    static let groupName = "group.name"
    static let groupCreate = "group.create"
    static let hostEdit = "host.edit"
    static let hostDelete = "host.delete"
    static let editorLabel = "editor.label"
    static let editorHost = "editor.host"
    static let editorPort = "editor.port"
    static let editorUser = "editor.user"
    static let editorJump = "editor.jump"
    static let editorStartup = "editor.startup"
    static let editorForwardAgent = "editor.forwardAgent"
    static let editorUseJump = "editor.useJump"
    static let editorAddForward = "editor.addForward"
    static let editorAddOption = "editor.addOption"
    static let editorOptionKey = "editor.optionKey"
    static let editorOptionValue = "editor.optionValue"
    static let editorKeyPicker = "editor.keyPicker"
    static let editorIdentity = "editor.identity"
    static let editorSave = "editor.save"
    static let editorCancel = "editor.cancel"
    static let editorDiscard = "editor.discard"
    static let forwardKind = "forward.kind"
    static let forwardListen = "forward.listen"
    static let forwardDestinationHost = "forward.destinationHost"
    static let forwardDestinationPort = "forward.destinationPort"
    static let forwardSave = "forward.save"
    static let forwardCancel = "forward.cancel"

    static func host(_ label: String) -> String { "host.\(label)" }
    static func group(_ name: String) -> String { "group.\(name)" }
    static func settingsPane(_ id: String) -> String { "settings.pane.\(id)" }
    static func jumpPick(_ label: String) -> String { "jump.pick.\(label)" }
    static func groupNest(_ name: String) -> String { "group.nest.\(name)" }
}
