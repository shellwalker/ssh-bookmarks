import AppKit
import MenuSSHCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case terminal
    case hosts
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .terminal: return "Terminal"
        case .hosts: return "Hosts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .hosts: return "server.rack"
        case .about: return "info.circle"
        }
    }
}

/// 设置窗口：左侧导航，右侧“设置 / 分类”面包屑 + 卡片式设置行（参考 magpie）。
@MainActor
struct SettingsWindowView: View {
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 6) {
                        Text("Settings").foregroundStyle(.secondary)
                        Text("/").foregroundStyle(.tertiary)
                        Text((pane ?? .general).title)
                    }
                    .font(.system(size: 15, weight: .semibold))

                    switch pane ?? .general {
                    case .general: GeneralSettingsPane()
                    case .terminal: TerminalSettingsPane()
                    case .hosts: HostsSettingsPane()
                    case .about: AboutSettingsPane()
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { AppActivation.bringToFront() }
    }
}

// MARK: - General

@MainActor
struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var launchAtLogin = LoginItemController.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        SettingsSection {
            SettingsRow("Appearance", subtitle: "Light, dark, or follow the system") {
                SegmentedSetting(selection: $settings.appearance, options: AppearanceMode.allCases) { $0.title }
            }
            SettingsRow(
                "Language",
                subtitle: settings.languageChangePending ? LocalizedStringKey("Restart MenuSSH to apply") : "Interface language",
                showsDivider: false
            ) {
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsSection {
            SettingsRow("Launch at Login", subtitle: loginItemSubtitle) {
                SegmentedSetting(
                    selection: Binding(
                        get: { launchAtLogin ? OnOff.on : OnOff.off },
                        set: { setLaunchAtLogin($0 == .on) }
                    ),
                    options: OnOff.allCases
                ) { $0.title }
            }
            SettingsRow(
                "Show in Dock",
                subtitle: "\"Follow Window\" shows the Dock icon only while a window is open",
                showsDivider: false
            ) {
                SegmentedSetting(selection: $settings.dockIconMode, options: DockIconMode.allCases) { $0.title }
            }
        }

        if let loginItemError {
            Text(loginItemError).font(.callout).foregroundStyle(.red)
        }
    }

    private var loginItemSubtitle: LocalizedStringKey {
        LoginItemController.requiresApproval
            ? LocalizedStringKey("Approve MenuSSH in System Settings › General › Login Items")
            : "Start MenuSSH automatically when you log in"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = LoginItemController.isEnabled
        if LoginItemController.requiresApproval {
            LoginItemController.openSystemSettings()
        }
    }
}

enum OnOff: String, CaseIterable, Identifiable {
    case off
    case on
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .on ? "On" : "Off" }
}

// MARK: - Terminal

@MainActor
struct TerminalSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsSection {
            SettingsRow("Session Terminal", subtitle: "Terminal used to open SSH sessions") {
                Picker("", selection: $settings.terminal) {
                    ForEach(TerminalApp.allCases) { app in
                        if TerminalLauncher.isInstalled(app) {
                            Text(app.pickerTitle).tag(app)
                        } else {
                            Text("\(Text(app.pickerTitle)) (not installed)").tag(app)
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(
                "Open In",
                subtitle: settings.terminal.supportsNewTab
                    ? LocalizedStringKey("Open each session in a new window or a new tab")
                    : "This terminal only supports new windows"
            ) {
                SegmentedSetting(selection: $settings.openMode, options: TerminalOpenMode.allCases) { $0.title }
                    .disabled(!settings.terminal.supportsNewTab)
            }
            SettingsRow("SSH Executable", subtitle: "Default: /usr/bin/ssh", showsDivider: false) {
                TextField("", text: $settings.sshPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }

        SettingsSection {
            SettingsRow(
                "Automation Permission",
                subtitle:
                    "Terminal, iTerm2 and Ghostty are controlled via AppleScript. If launching fails, allow MenuSSH under Privacy & Security › Automation.",
                showsDivider: false
            ) {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - Hosts

@MainActor
struct HostsSettingsPane: View {
    @EnvironmentObject private var hosts: HostStoreModel
    @State private var importMessage: String?

    var body: some View {
        SettingsSection {
            SettingsRow("Import ~/.ssh/config", subtitle: "Adds Host entries that are not in MenuSSH yet") {
                Button("Import") {
                    let count = hosts.importSSHConfig()
                    importMessage = String(localized: "Imported \(count) hosts")
                }
            }
            SettingsRow("Data File", subtitle: "Hosts are stored as JSON; passwords live in the Keychain", showsDivider: false) {
                Button("Show in Finder") { hosts.revealDataFileInFinder() }
            }
        }
        if let importMessage {
            Text(importMessage).font(.callout).foregroundStyle(.secondary)
        }
        Text(verbatim: hosts.fileStore.fileURL.path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

// MARK: - About

@MainActor
struct AboutSettingsPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsSection {
            SettingsRow("Version") {
                Text(verbatim: version).foregroundStyle(.secondary)
            }
            SettingsRow("Source Code", showsDivider: false) {
                Link("github.com/shellwalker/ssh-menu", destination: URL(string: "https://github.com/shellwalker/ssh-menu")!)
            }
        }
    }
}
