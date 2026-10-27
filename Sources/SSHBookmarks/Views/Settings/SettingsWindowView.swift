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
            List(SettingsPaneID.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .accessibilityIdentifier(UITestID.settingsPane(pane.rawValue))
                    .tag(pane)
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
        ForEach(Array(SettingsCatalog.groups(in: pane).enumerated()), id: \.offset) { _, group in
            card(group)
        }
        if pane == .hosts {
            DataFilePathLabel()
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
