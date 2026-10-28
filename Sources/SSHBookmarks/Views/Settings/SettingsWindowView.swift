import AppKit
import SSHBookmarksCore
import SwiftUI

/// 设置窗口（参考 magpie）：左侧“查找设置”+ 分类导航，右侧“设置 / 分类”面包屑 + 卡片，一行一项。
@MainActor
struct SettingsWindowView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var pane: SettingsPaneID? = .general
    @State private var searchText = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsPaneID.allCases, selection: $pane) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .accessibilityIdentifier(UITestID.settingsPane(pane.rawValue))
                        .tag(pane)
                }
                Text("SSH bookmarks in your menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("settings.slogan")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    breadcrumb
                    if isSearching {
                        searchResults
                    } else {
                        paneContent(pane ?? .general)
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(UITestContainer(identifier: UITestID.settings))
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search Settings"))
        .onAppear {
            AppActivation.bringToFront()
            applyPendingPane()
        }
        .onChange(of: settings.pendingSettingsPane) { _, _ in applyPendingPane() }
    }

    private func applyPendingPane() {
        guard let requested = settings.pendingSettingsPane else { return }
        pane = requested
        searchText = ""
        settings.pendingSettingsPane = nil
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Text("Settings").foregroundStyle(.secondary)
            Text(verbatim: "/").foregroundStyle(.tertiary)
            if isSearching {
                Text("Search Results")
            } else {
                Text((pane ?? .general).title)
            }
        }
        .font(.system(size: 15, weight: .semibold))
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPaneID) -> some View {
        switch pane {
        case .diagnostics:
            DiagnosticsPage()
        case .about:
            AboutPage()
        default:
            ForEach(Array(SettingsCatalog.groups(in: pane).enumerated()), id: \.offset) { _, group in
                card(group)
            }
            if pane == .hosts {
                DataFilePathLabel()
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let localized = Dictionary(uniqueKeysWithValues: SettingsItemID.allCases.map { ($0, $0.localizedSearchText) })
        let results = SettingsCatalog.search(searchText, localizedText: localized)
        if results.isEmpty {
            Text("No matching settings")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ForEach(Array(SettingsCatalog.groups(of: results).enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 6) {
                    if let first = group.first {
                        Button {
                            searchText = ""
                            pane = first.pane
                        } label: {
                            Text(first.pane.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 4)
                        .help("Show in its category")
                    }
                    card(group)
                }
            }
        }
    }

    private func card(_ items: [SettingsItem]) -> some View {
        SettingsSection {
            ForEach(items) { item in
                SettingsItemRow(id: item.id, showsDivider: item.id != items.last?.id)
            }
        }
    }
}

/// 站点数据文件路径（可选中复制）。
@MainActor
private struct DataFilePathLabel: View {
    @EnvironmentObject private var hosts: HostStoreModel

    var body: some View {
        Text(verbatim: hosts.fileStore.fileURL.path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.leading, 4)
    }
}

@MainActor
private struct DiagnosticsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hosts: HostStoreModel
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Local Log") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "The log records app version, connection and tunnel events, exit codes, and error categories. It stays on this Mac."
                    )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    SettingsItemRow(id: .diagnosticFile, showsDivider: true)
                    SettingsItemRow(id: .diagnosticRedactNames, showsDivider: true)
                    infoRow("Retention", value: "7 days")
                    infoRow("Size Limit", value: "About 10 MiB · up to 5 files")
                    infoRow("Current Log", value: currentSummary)
                    Text(verbatim: DiagnosticLog.logDirectory().path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                    HStack {
                        Button("Open Log Folder") {
                            notice = DiagnosticActions.revealLogFolder()
                        }
                        .accessibilityIdentifier("diagnostics.open")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    if let notice {
                        Text(verbatim: notice)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                }
            }
            SettingsSection("Export Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(exportDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    Button("Export Diagnostic Log…") { DiagnosticActions.export(settings: settings, hosts: hosts) }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("diagnostics.export")
                    Text("After you reproduce a problem, export the latest log and note the steps and the time it happened.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                    Button("Copy Diagnostic Info") { DiagnosticActions.copy(settings: settings, hosts: hosts) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("diagnostics.copy")
                }
            }
        }
    }

    private var exportDescription: LocalizedStringKey {
        LocalizedStringKey(
            "The ZIP contains the app version, macOS version, ssh version and path, terminal choice, "
                + "and recent connection and tunnel events. It never contains passwords, tokens, askpass secrets, "
                + "or private keys. With redaction on, hostnames and usernames are removed too."
        )
    }

    private var currentSummary: String {
        let files = DiagnosticLog.snapshots()
        let bytes = files.reduce(0) { $0 + $1.byteCount }
        return "\(files.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    private func infoRow(_ title: LocalizedStringKey, value: LocalizedStringKey) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

@MainActor
private struct AboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("SSH Bookmarks") {
                VStack(spacing: 0) {
                    aboutRow("Version", value: AppBuildInfo.versionLine)
                    Divider().padding(.leading, 12)
                    aboutRow("Build", value: AppBuildInfo.build)
                    Divider().padding(.leading, 12)
                    Text("SSH bookmarks in your menu bar.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("about.slogan")
                }
            }
            SettingsSection {
                SettingsItemRow(id: .sourceCode, showsDivider: false)
            }
        }
    }

    private func aboutRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(verbatim: value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

enum AppBuildInfo {
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let channel = info?["SSHBookmarksChannel"] as? String
        let label = channel == "release" ? String(localized: "Release") : String(localized: "Development")
        return "\(short) · \(label)"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
