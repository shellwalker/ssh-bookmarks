import AppKit
import SSHBookmarksCore
import SwiftUI

/// 点击菜单栏图标弹出的面板：搜索框 + 分组站点列表 + 底部操作。
///
/// 键盘：弹出即聚焦搜索框；↑/↓（或 ⌃P/⌃N）移动选中，Return 连接，Esc 关闭；鼠标点击同样连接。
@MainActor
struct MenuBarContentView: View {
    @EnvironmentObject private var hosts: HostStoreModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnels: TunnelController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @StateObject private var keyMonitor = PanelKeyMonitor()
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var cursor = HostListCursor()

    var body: some View {
        let sections = hosts.sections(matching: query)
        VStack(spacing: 0) {
            tunnelHeader
            searchField
                .padding(10)

            Divider()

            if sections.isEmpty {
                emptyState
                    .frame(height: 300)
            } else {
                hostList(sections)
                    .frame(height: 400)
            }

            if let error = hosts.lastError {
                Divider()
                statusLine(error, color: .red, symbol: "exclamationmark.triangle.fill")
            } else if let notice = hosts.lastNotice {
                Divider()
                statusLine(notice, color: .orange, symbol: "info.circle")
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .modifier(UITestContainer(identifier: UITestID.panel))
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

    private var tunnelHeader: some View {
        let running = tunnels.sessions.values.filter { $0.phase == .running || $0.phase == .starting }
        return Group {
            if settings.showTunnelCount, tunnels.runningCount > 0 {
                HStack {
                    Text("Running tunnels")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "\(tunnels.runningCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityIdentifier(UITestID.panelTunnelBadge)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                ForEach(running.sorted { $0.label < $1.label }) { session in
                    HStack {
                        Text(verbatim: "\(session.label) \(session.displayAddress)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Button("Stop") { stop(session) }
                            .font(.system(size: 11))
                            .accessibilityIdentifier(UITestID.tunnelStop(session.label, session.listenPort))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                }
                Divider()
            }
        }
    }

    private func tunnelRows(_ host: SSHHost) -> some View {
        let forwards = host.portForwards.filter { $0.quickToggle && $0.kind == .local }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(forwards) { forward in
                let session = tunnels.session(for: forward.id)
                HStack(spacing: 8) {
                    Toggle(
                        isOn: Binding(
                            get: { session?.phase == .running || session?.phase == .starting },
                            set: { _ in tunnels.toggle(host: host, forward: forward) }
                        )
                    ) {
                        Text(verbatim: forward.editorSummary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier(UITestID.tunnelToggle(host.label, forward.listenPort))
                    .accessibilityLabel(Text(verbatim: "\(host.label) \(forward.listenPort)"))
                    if session?.phase == .failed(.hostKeyNew) || session?.phase == .failed(.hostKeyChanged) {
                        Button("Open in Terminal to Trust") { tunnels.trustInTerminal(host: host, settings: settings) }
                            .font(.system(size: 11))
                            .accessibilityIdentifier(UITestID.tunnelTrust(host.label))
                    }
                }
                .padding(.horizontal, 16)
                if let message = session?.message, !message.isEmpty {
                    Text(verbatim: message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier(UITestID.tunnelMessage(host.label))
                }
            }
        }
    }

    private func stop(_ session: TunnelSession) {
        let owner = self.host(session.hostID) ?? SSHHost(label: session.label, hostname: session.hostname)
        let rule = forward(session) ?? placeholder(session)
        tunnels.toggle(host: owner, forward: rule)
    }

    private func host(_ id: UUID) -> SSHHost? { hosts.host(id: id) }

    private func forward(_ session: TunnelSession) -> PortForward? {
        hosts.host(id: session.hostID)?.portForwards.first { $0.id == session.id }
    }

    private func placeholder(_ session: TunnelSession) -> PortForward {
        PortForward(
            id: session.id, kind: .local, listenPort: session.listenPort,
            destinationHost: "127.0.0.1", destinationPort: 1, quickToggle: true
        )
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search hosts", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier(UITestID.panelSearch)
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
                        section.title(in: hosts.library)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(section.hosts) { host in
                            let entryID = HostListEntry(sectionID: section.id, host: host).id
                            VStack(alignment: .leading, spacing: 0) {
                                MenuHostButton(
                                    host: host,
                                    isSelected: cursor.selectedID == entryID,
                                    action: { connect(host) }
                                )
                                .id(entryID)
                                tunnelRows(host)
                            }
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
                Button("Import ~/.ssh/config") { hosts.importSSHConfig() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(UITestID.panelImport)
                Button("New Host") {
                    hosts.presentNewHost = true
                    open(WindowID.hosts)
                }
                .accessibilityIdentifier(UITestID.panelNewHost)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                open(WindowID.hosts)
            } label: {
                Label("Manage Hosts", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier(UITestID.panelManage)
            .font(.system(size: 12))
            Spacer(minLength: 8)
            Button {
                openSettings(pane: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier(UITestID.panelSettings)
            .font(.system(size: 12))
            Menu {
                Button("About SSH Bookmarks") { openSettings(pane: .about) }
                Button("Settings…") { openSettings(pane: nil) }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Quit SSH Bookmarks") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func statusLine(_ text: String, color: Color, symbol: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            MainActor.assumeIsolated {
                searchFocused = true
            }
        }
    }

    private func handle(_ key: PanelKey) -> Bool {
        switch cursor.handle(key) {
        case .none:
            // 列表为空时 Return 也吞掉，避免系统提示音；其它键交还给文本框。
            return key == .enter
        case .select(_):
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
        // 回退提示要留在面板上，不能马上关掉。
        if hosts.lastError == nil && hosts.lastNotice == nil && settings.closePanelAfterConnect {
            keyMonitor.close(using: dismiss)
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        AppActivation.bringToFront()
        // 测试模式的面板是普通窗口，关掉就没法再操作；菜单栏面板仍在打开窗口后收起。
        if !UITestLaunch.isEnabled {
            keyMonitor.close(using: dismiss)
        }
    }

    private func openSettings(pane: SettingsPaneID?) {
        settings.pendingSettingsPane = pane
        open(WindowID.settings)
    }
}

/// 一行站点按钮。悬停只改背景，不移动键盘选中项。
@MainActor
private struct MenuHostButton: View {
    let host: SSHHost
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HostRow(host: host)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rowFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(UITestContainer(identifier: UITestID.host(host.label)))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if hovering { return Color.primary.opacity(0.08) }
        return Color.clear
    }
}
