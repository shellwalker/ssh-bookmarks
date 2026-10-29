import AppKit
import Combine
import SSHBookmarksCore
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
        case .showTunnelCount: TunnelCountRow(showsDivider: showsDivider)
        case .sessionTerminal: SessionTerminalRow(showsDivider: showsDivider)
        case .openMode: OpenModeRow(showsDivider: showsDivider)
        case .sshPath: SSHPathRow(showsDivider: showsDivider)
        case .automationPermission: AutomationPermissionRow(showsDivider: showsDivider)
        case .importSSHConfig: ImportSSHConfigRow(showsDivider: showsDivider)
        case .dataFile: DataFileRow(showsDivider: showsDivider)
        case .sync: SyncRow(showsDivider: showsDivider)
        case .syncFolder: SyncFolderRow(showsDivider: showsDivider)
        case .diagnosticFile: DiagnosticFileRow(showsDivider: showsDivider)
        case .diagnosticRedactNames: DiagnosticRedactRow(showsDivider: showsDivider)
        case .diagnosticExport: DiagnosticExportRow(showsDivider: showsDivider)
        case .diagnosticCopy: DiagnosticCopyRow(showsDivider: showsDivider)
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
            subtitle: settings.languageChangePending ? Text("Restart SSH Bookmarks to apply") : nil,
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
        if loginItem.requiresApproval { return Text("Approve SSH Bookmarks in System Settings › General › Login Items") }
        if loginItem.isUnavailable { return Text("Move SSH Bookmarks to the Applications folder to enable this") }
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
            return Text(verbatim: L10n.format("%@ (not installed)", app.localizedName))
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
            return Text(verbatim: L10n.format("%@ is not installed; sessions will fail to open.", selected.localizedName))
                .foregroundColor(.orange)
        }
        if selected == .ghostty, let version = state.version,
            version.compare(TerminalLaunchPlanner.ghosttyAppleScriptMinimumVersion, options: .numeric) == .orderedAscending
        {
            return Text(
                verbatim: L10n.format(
                    "Ghostty %@ has no AppleScript support; each session opens in a new window. Update to 1.3 or later for tabs.",
                    version))
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
            return Text(verbatim: L10n.format("Allowed to control %@.", name)).foregroundColor(.green)
        case .denied?:
            return Text(
                verbatim: L10n.format(
                    "Not allowed to control %@. Enable SSH Bookmarks under Privacy & Security › Automation.",
                    name
                )
            )
            .foregroundColor(.red)
        case .notDetermined?:
            return Text(verbatim: L10n.format("macOS will ask for permission the first time a session opens in %@.", name))
        case .targetNotRunning?:
            return Text(verbatim: L10n.format("Open %@ and click Check to see the permission state.", name))
        case .unknown(let code)?:
            return Text(verbatim: L10n.format("Permission state unknown (%lld).", Int64(code)))
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
                guard let plan = hosts.importSSHConfig() else { return }
                message = Text(verbatim: hosts.importNotice(plan))
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

// MARK: - Sync

private let syncPlaintextWarning = LocalizedStringKey(
    """
    The sync file stores hostnames and usernames in plaintext. \
    Passwords and key passphrases stay in the Keychain on this Mac and are never written to the file.
    """
)

@MainActor
private struct SyncRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hosts: HostStoreModel
    @State private var showingWarning = false
    let showsDivider: Bool

    var body: some View {
        row(.sync, subtitle: subtitle, showsDivider: showsDivider) {
            SegmentedSetting(
                selection: Binding(
                    get: { OnOff(settings.syncEnabled) },
                    set: { newValue in
                        if newValue.isOn {
                            if !settings.syncEnabled { showingWarning = true }
                        } else {
                            settings.syncEnabled = false
                        }
                    }
                ),
                options: OnOff.allCases
            ) { $0.title }
        }
        .alert("Enable Sync?", isPresented: $showingWarning) {
            Button("Enable") {
                settings.syncEnabled = true
                hosts.syncNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(syncPlaintextWarning)
        }
    }

    private var subtitle: Text {
        if settings.syncEnabled {
            return Text(syncPlaintextWarning)
        }
        return Text("Sync is off. Hosts stay on this Mac.")
    }
}

private let syncFolderChangeWarning = """
    Local hosts stay on this Mac. SSH Bookmarks merges with the file in the new folder \
    and does not replace your library with an empty one.
    """

@MainActor
private struct SyncFolderRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hosts: HostStoreModel
    @State private var folderConfirm: FolderConfirm?
    let showsDivider: Bool

    private enum FolderConfirm {
        case iCloud
        case choose
    }

    var body: some View {
        row(.syncFolder, subtitle: Text(verbatim: settings.resolvedSyncDirectory.path), showsDivider: showsDivider) {
            HStack(spacing: 8) {
                Button("Use iCloud Drive") {
                    guard settings.syncFolderPath != nil else { return }
                    folderConfirm = .iCloud
                }
                Button("Choose Folder…") { folderConfirm = .choose }
            }
        }
        .alert(
            "Change the sync folder?",
            isPresented: Binding(get: { folderConfirm != nil }, set: { if !$0 { folderConfirm = nil } })
        ) {
            Button("Change Folder", action: applyFolderChange)
            Button("Cancel", role: .cancel) { folderConfirm = nil }
        } message: {
            Text(LocalizedStringKey(syncFolderChangeWarning))
        }
    }

    private func applyFolderChange() {
        let choice = folderConfirm
        folderConfirm = nil
        switch choice {
        case .iCloud:
            settings.syncFolderPath = nil
            if settings.syncEnabled { hosts.syncNow() }
        case .choose:
            chooseFolder()
        case nil:
            break
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.syncFolderPath = url.path
        if settings.syncEnabled { hosts.syncNow() }
    }
}

// MARK: - Diagnostics

@MainActor
private struct DiagnosticFileRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(.diagnosticFile, showsDivider: showsDivider) {
            Toggle("", isOn: $settings.diagnosticLogEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("diagnostics.file")
        }
    }
}

@MainActor
private struct DiagnosticRedactRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(.diagnosticRedactNames, showsDivider: showsDivider) {
            Toggle("", isOn: $settings.diagnosticRedactNames)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("diagnostics.redact")
        }
    }
}

@MainActor
private struct DiagnosticExportRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hosts: HostStoreModel
    let showsDivider: Bool

    var body: some View {
        row(.diagnosticExport, showsDivider: showsDivider) {
            Button("Export Diagnostic Log…") { DiagnosticActions.export(settings: settings, hosts: hosts) }
                .accessibilityIdentifier("diagnostics.export")
        }
    }
}

@MainActor
private struct DiagnosticCopyRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hosts: HostStoreModel
    let showsDivider: Bool

    var body: some View {
        row(.diagnosticCopy, showsDivider: showsDivider) {
            Button("Copy Diagnostic Info") { DiagnosticActions.copy(settings: settings, hosts: hosts) }
                .accessibilityIdentifier("diagnostics.copy")
        }
    }
}

@MainActor
private struct TunnelCountRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let showsDivider: Bool

    var body: some View {
        row(.showTunnelCount, showsDivider: showsDivider) {
            Toggle("", isOn: $settings.showTunnelCount)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("settings.tunnelCount")
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
            if let url = URL(string: "https://github.com/shellwalker/ssh-bookmarks") {
                Link(destination: url) { Text(verbatim: "github.com/shellwalker/ssh-bookmarks") }
            }
        }
    }
}
