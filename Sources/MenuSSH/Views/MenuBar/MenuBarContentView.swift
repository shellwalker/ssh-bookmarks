import AppKit
import MenuSSHCore
import SwiftUI

/// 点击菜单栏图标弹出的面板：搜索框 + 分组站点列表 + 底部操作。
@MainActor
struct MenuBarContentView: View {
    @EnvironmentObject private var hosts: HostStoreModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

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
                                MenuHostButton(host: host) { connect(host) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(height: 320)
            }

            if let error = hosts.lastError {
                Divider()
                Text(error)
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
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search hosts", text: $query)
                .textFieldStyle(.plain)
                .onSubmit {
                    if let first = hosts.sections(matching: query).first?.hosts.first {
                        connect(first)
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
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

    private func connect(_ host: SSHHost) {
        hosts.connect(host, settings: settings)
        if hosts.lastError == nil && settings.closePanelAfterConnect {
            dismiss()
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        AppActivation.bringToFront()
        dismiss()
    }
}

/// 可悬停高亮的站点按钮。
@MainActor
private struct MenuHostButton: View {
    let host: SSHHost
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HostRow(host: host)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}
