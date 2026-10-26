import AppKit
import MenuSSHCore
import SwiftUI

/// 点击菜单栏图标弹出的面板：搜索框 + 分组站点列表 + 底部操作。
///
/// 键盘：弹出即聚焦搜索框；↑/↓（或 ⌃P/⌃N）移动选中，Return 连接，Esc 关闭；鼠标点击同样连接。
@MainActor
struct MenuBarContentView: View {
    @EnvironmentObject private var hosts: HostStoreModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @StateObject private var keyMonitor = PanelKeyMonitor()
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var cursor = HostListCursor()

    var body: some View {
        let sections = hosts.sections(matching: query)
        VStack(spacing: 0) {
            searchField
                .padding(10)

            Divider()

            if sections.isEmpty {
                emptyState
                    .frame(height: 260)
            } else {
                hostList(sections)
                    .frame(height: 320)
            }

            if let error = hosts.lastError {
                Divider()
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .background(WindowReader { window in keyMonitor.attach(to: window) })
        .onAppear {
            keyMonitor.onKey = { key in handle(key) }
            keyMonitor.onOpen = { panelOpened() }
            cursor.reset(sections: sections)
            focusSearchField()
        }
        .onChange(of: query) { _, newQuery in
            cursor.reset(sections: hosts.sections(matching: newQuery))
        }
        .onChange(of: hosts.library) { _, _ in
            cursor.update(sections: hosts.sections(matching: query))
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search hosts", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    focusSearchField()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }

    // MARK: List

    private func hostList(_ sections: [HostSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        section.title
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(section.hosts) { host in
                            let entryID = HostListEntry(sectionID: section.id, host: host).id
                            MenuHostButton(
                                host: host,
                                isSelected: cursor.selectedID == entryID,
                                onHover: { cursor.select(id: entryID) },
                                action: { connect(host) }
                            )
                            .id(entryID)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: cursor.selectedID) { _, newID in
                guard let newID else { return }
                proxy.scrollTo(newID)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? LocalizedStringKey("No hosts yet") : "No matching hosts")
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Button("Add Host…") { open(WindowID.hosts) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                open(WindowID.hosts)
            } label: {
                Label("Manage Hosts", systemImage: "square.grid.2x2")
            }
            Spacer()
            Button {
                open(WindowID.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit MenuSSH")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    /// 每次弹出：清空搜索、选中第一项、聚焦搜索框。
    private func panelOpened() {
        query = ""
        cursor.reset(sections: hosts.sections(matching: ""))
        focusSearchField()
    }

    private func focusSearchField() {
        // 窗口刚成为 key window 时立即设置焦点可能被 SwiftUI 覆盖，推迟到下一轮 runloop。
        DispatchQueue.main.async {
            MainActor.assumeIsolated { searchFocused = true }
        }
    }

    private func handle(_ key: PanelKey) -> Bool {
        switch cursor.handle(key) {
        case .none:
            // 列表为空时 Return 也吞掉，避免系统提示音；其它键交还给文本框。
            return key == .enter
        case .select:
            return true
        case .connect(let host):
            connect(host)
            return true
        case .close:
            keyMonitor.close(using: dismiss)
            return true
        }
    }

    private func connect(_ host: SSHHost) {
        hosts.connect(host, settings: settings)
        if hosts.lastError == nil && settings.closePanelAfterConnect {
            keyMonitor.close(using: dismiss)
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        AppActivation.bringToFront()
        keyMonitor.close(using: dismiss)
    }
}

/// 一行站点按钮：键盘选中或鼠标悬停时高亮。
@MainActor
private struct MenuHostButton: View {
    let host: SSHHost
    let isSelected: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HostRow(host: host)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { inside in
            if inside { onHover() }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
