import AppKit
import Combine
import MenuSSHCore
import SwiftUI

/// 按 id 渲染一行设置。分类页与搜索结果共用，保证同一设置项只有一份实现。
@MainActor
struct SettingsItemRow: View {
    let id: SettingsItemID
    var showsDivider = true

    var body: some View {
        switch id {
        case .appearance: AppearanceRow(showsDivider: showsDivider)
        case .language: LanguageRow(showsDivider: showsDivider)
        case .launchAtLogin: LaunchAtLoginRow(showsDivider: showsDivider)
        case .dockIcon: DockIconRow(showsDivider: showsDivider)
        case .closePanelAfterConnect: ClosePanelRow(showsDivider: showsDivider)
        case .sessionTerminal: SessionTerminalRow(showsDivider: showsDivider)
        case .openMode: OpenModeRow(showsDivider: showsDivider)
        case .sshPath: SSHPathRow(showsDivider: showsDivider)
        case .automationPermission: AutomationPermissionRow(showsDivider: showsDivider)
        case .importSSHConfig: ImportSSHConfigRow(showsDivider: showsDivider)
        case .dataFile: DataFileRow(showsDivider: showsDivider)
        case .version: VersionRow(showsDivider: showsDivider)
        case .sourceCode: SourceCodeRow(showsDivider: showsDivider)
        }
    }
}

/// 标题 / 默认说明取自 SettingsItemID，避免和搜索用的文案不一致。
@MainActor
private func row<Accessory: View>(
    _ id: SettingsItemID,
    subtitle: Text? = nil,
    showsDivider: Bool,
    @ViewBuilder accessory: () -> Accessory
) -> SettingsRow<Accessory> {
    SettingsRow(
        title: Text(LocalizedStringKey(id.titleKey)),
        subtitleText: subtitle ?? id.subtitleKey.map { Text(LocalizedStringKey($0)) },
        showsDivider: showsDivider,
        accessory: accessory
    )
}

enum OnOff: String, CaseIterable, Identifiable {
    case off
    case on
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .on ? "On" : "Off" }

    init(_ value: Bool) { self = value ? .on : .off }
    var isOn: Bool { self == .on }
}

// MARK: - General

@MainActor
private struct AppearanceRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(.appearance, showsDivider: showsDivider) {
            SegmentedSetting(selection: $settings.appearance, options: AppearanceMode.allCases) { $0.title }
        }
    }
}

@MainActor
private struct LanguageRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(
            .language,
            subtitle: settings.languageChangePending ? Text("Restart MenuSSH to apply") : nil,
            showsDivider: showsDivider
        ) {
            HStack(spacing: 8) {
                if settings.languageChangePending {
                    Button("Restart Now") { settings.relaunch() }
                }
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

@MainActor
private struct LaunchAtLoginRow: View {
    @ObservedObject private var loginItem = LoginItemController.shared
    let showsDivider: Bool

    var body: some View {
        row(.launchAtLogin, subtitle: subtitle, showsDivider: showsDivider) {
            HStack(spacing: 8) {
                if loginItem.requiresApproval {
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                }
                SegmentedSetting(
                    selection: Binding(get: { OnOff(loginItem.isEnabled) }, set: { loginItem.setEnabled($0.isOn) }),
                    options: OnOff.allCases
                ) { $0.title }
                .disabled(loginItem.isUnavailable)
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var subtitle: Text? {
        if let error = loginItem.lastError { return Text(verbatim: error).foregroundColor(.red) }
        if loginItem.requiresApproval { return Text("Approve MenuSSH in System Settings › General › Login Items") }
        if loginItem.isUnavailable { return Text("Move MenuSSH to the Applications folder to enable this") }
        return nil
    }
}

@MainActor
private struct DockIconRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(.dockIcon, showsDivider: showsDivider) {
            SegmentedSetting(selection: $settings.dockIconMode, options: DockIconMode.allCases) { $0.title }
        }
    }
}

@MainActor
private struct ClosePanelRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(.closePanelAfterConnect, showsDivider: showsDivider) {
            SegmentedSetting(
                selection: Binding(get: { OnOff(settings.closePanelAfterConnect) }, set: { settings.closePanelAfterConnect = $0.isOn }),
                options: OnOff.allCases
            ) { $0.title }
        }
    }
}

// MARK: - Terminal

/// 终端的安装状态（读取 Info.plist，打开设置页时刷新一次）。
struct TerminalInstallInfo: Equatable {
    var installed: Bool
    var version: String?

    @MainActor
    static func current(_ app: TerminalApp) -> TerminalInstallInfo {
        TerminalInstallInfo(installed: TerminalLauncher.isInstalled(app), version: TerminalLauncher.installedVersion(of: app))
    }
}

@MainActor
private struct SessionTerminalRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var info: [TerminalApp: TerminalInstallInfo] = [:]
    let showsDivider: Bool

    var body: some View {
        row(.sessionTerminal, subtitle: subtitle, showsDivider: showsDivider) {
            Picker("", selection: $settings.terminal) {
                ForEach(TerminalApp.allCases) { app in
                    pickerLabel(app).tag(app)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        var result: [TerminalApp: TerminalInstallInfo] = [:]
        for app in TerminalApp.allCases { result[app] = .current(app) }
        info = result
    }

    private func pickerLabel(_ app: TerminalApp) -> Text {
        let state = info[app] ?? TerminalInstallInfo(installed: true, version: nil)
        if !state.installed {
            return Text("\(app.localizedName) (not installed)")
        }
        if let version = state.version, app != .terminal {
            return Text(verbatim: "\(app.localizedName) \(version)")
        }
        return Text(verbatim: app.localizedName)
    }

    private var subtitle: Text? {
        let selected = settings.terminal
        guard let state = info[selected] else { return nil }
        if !state.installed {
            return Text("\(selected.localizedName) is not installed; sessions will fail to open.").foregroundColor(.orange)
        }
        if selected == .ghostty, let version = state.version,
            version.compare(TerminalLaunchPlanner.ghosttyAppleScriptMinimumVersion, options: .numeric) == .orderedAscending
        {
            return Text(
                "Ghostty \(version) has no AppleScript support; each session opens in a new window. Update to 1.3 or later for tabs.")
        }
        return nil
    }
}

@MainActor
private struct OpenModeRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(
            .openMode,
            subtitle: settings.terminal.supportsNewTab ? nil : Text("This terminal only supports new windows"),
            showsDivider: showsDivider
        ) {
            SegmentedSetting(selection: $settings.openMode, options: TerminalOpenMode.allCases) { $0.title }
                .disabled(!settings.terminal.supportsNewTab)
        }
    }
}

@MainActor
private struct SSHPathRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    private var isValid: Bool {
        settings.sshPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: settings.sshPath)
    }

    var body: some View {
        row(
            .sshPath,
            subtitle: isValid ? nil : Text("Not an executable file; using it will fail").foregroundColor(.red),
            showsDivider: showsDivider
        ) {
            HStack(spacing: 6) {
                TextField("", text: $settings.sshPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                if settings.sshPath != "/usr/bin/ssh" {
                    Button("Reset") { settings.sshPath = "/usr/bin/ssh" }
                }
            }
        }
    }
}

@MainActor
private struct AutomationPermissionRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var status: AutomationPermission.Status?
    @State private var checking = false
    let showsDivider: Bool

    var body: some View {
        row(.automationPermission, subtitle: statusText, showsDivider: showsDivider) {
            HStack(spacing: 8) {
                Button("Check") { check(ask: true) }
                    .disabled(checking || settings.terminal == .ghostty && !ghosttySupportsAppleScript)
                Button("Open Privacy Settings") { AutomationPermission.openPrivacySettings() }
            }
        }
        .onAppear { check(ask: false) }
        .onChange(of: settings.terminal) { _, _ in check(ask: false) }
    }

    private var ghosttySupportsAppleScript: Bool {
        guard let version = TerminalLauncher.installedVersion(of: .ghostty) else { return false }
        return version.compare(TerminalLaunchPlanner.ghosttyAppleScriptMinimumVersion, options: .numeric) != .orderedAscending
    }

    private func check(ask: Bool) {
        let terminal = settings.terminal
        checking = true
        Task {
            let result = await AutomationPermission.check(terminal, ask: ask)
            status = result
            checking = false
        }
    }

    private var statusText: Text? {
        let name = settings.terminal.localizedName
        switch status {
        case .none:
            return nil
        case .granted?:
            return Text("Allowed to control \(name).").foregroundColor(.green)
        case .denied?:
            return Text("Not allowed to control \(name). Enable MenuSSH under Privacy & Security › Automation.").foregroundColor(.red)
        case .notDetermined?:
            return Text("macOS will ask for permission the first time a session opens in \(name).")
        case .targetNotRunning?:
            return Text("Open \(name) and click Check to see the permission state.")
        case .unknown(let code)?:
            return Text("Permission state unknown (\(Int(code))).")
        }
    }
}

// MARK: - Hosts

@MainActor
private struct ImportSSHConfigRow: View {
    @EnvironmentObject private var hosts: HostStoreModel
    @State private var message: Text?
    let showsDivider: Bool

    var body: some View {
        row(.importSSHConfig, subtitle: message, showsDivider: showsDivider) {
            Button("Import") {
                let count = hosts.importSSHConfig()
                message = Text("Imported \(count) hosts")
            }
        }
    }
}

@MainActor
private struct DataFileRow: View {
    @EnvironmentObject private var hosts: HostStoreModel
    let showsDivider: Bool

    var body: some View {
        row(.dataFile, showsDivider: showsDivider) {
            Button("Show in Finder") { hosts.revealDataFileInFinder() }
        }
    }
}

// MARK: - About

@MainActor
private struct VersionRow: View {
    let showsDivider: Bool

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        row(.version, showsDivider: showsDivider) {
            Text(verbatim: version).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

@MainActor
private struct SourceCodeRow: View {
    let showsDivider: Bool

    var body: some View {
        row(.sourceCode, showsDivider: showsDivider) {
            if let url = URL(string: "https://github.com/shellwalker/ssh-menu") {
                Link(destination: url) { Text(verbatim: "github.com/shellwalker/ssh-menu") }
            }
        }
    }
}
