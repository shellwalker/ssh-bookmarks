import AppKit
import MenuSSHCore
import SwiftUI

/// 侧边栏筛选项。
enum HostFilter: Hashable {
    case all
    case favorites
    case group(UUID)
    case ungrouped
}

/// 主窗口：左侧“全部 / 收藏 / 分组”，右侧可搜索的站点列表，双击连接。
@MainActor
struct HostManagerView: View {
    @EnvironmentObject private var hosts: HostStoreModel
    @EnvironmentObject private var settings: SettingsStore
    @State private var filter: HostFilter? = .all
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editingHost: SSHHost?
    @State private var newGroupName = ""
    @State private var showingNewGroup = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            hostList
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search hosts"))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editingHost = SSHHost(label: "", hostname: "", groupID: currentGroupID)
                } label: {
                    Label("New Host", systemImage: "plus")
                }
                Button {
                    hosts.importSSHConfig()
                } label: {
                    Label("Import ~/.ssh/config", systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, groups: hosts.library.groups) { saved in
                hosts.save(saved)
            }
        }
        .alert("New Group", isPresented: $showingNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { hosts.addGroup(named: name) }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
        .onAppear { AppActivation.bringToFront() }
    }

    private var currentGroupID: UUID? {
        if case .group(let id) = filter { return id }
        return nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                Label("All Hosts", systemImage: "server.rack").tag(HostFilter.all)
                Label("Favorites", systemImage: "star").tag(HostFilter.favorites)
            }
            Section("Groups") {
                ForEach(hosts.library.groups.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }) { group in
                    Label {
                        Text(verbatim: group.name)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(HostFilter.group(group.id))
                    .contextMenu {
                        Button("Delete Group", role: .destructive) { hosts.deleteGroup(id: group.id) }
                    }
                }
                Label("Ungrouped", systemImage: "tray").tag(HostFilter.ungrouped)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showingNewGroup = true
            } label: {
                Label("New Group", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    // MARK: Host list

    private var filteredHosts: [SSHHost] {
        let matched = hosts.library.hosts(matching: query)
        let list: [SSHHost]
        switch filter ?? .all {
        case .all: list = matched
        case .favorites: list = matched.filter(\.isFavorite)
        case .group(let id): list = matched.filter { $0.groupID == id }
        case .ungrouped: list = matched.filter { $0.groupID == nil }
        }
        return list.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    @ViewBuilder
    private var hostList: some View {
        let list = filteredHosts
        if list.isEmpty {
            ContentUnavailableView {
                Label(query.isEmpty ? LocalizedStringKey("No hosts") : "No matching hosts", systemImage: "server.rack")
            } actions: {
                Button("New Host") {
                    editingHost = SSHHost(label: "", hostname: "", groupID: currentGroupID)
                }
            }
        } else {
            List(list, selection: $selection) { host in
                HostRow(host: host, groupName: hosts.groupName(for: host.groupID))
                    .padding(.vertical, 3)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let host = hosts.host(id: id) {
                    hostMenu(for: host)
                }
            } primaryAction: { ids in
                if let id = ids.first, let host = hosts.host(id: id) {
                    hosts.connect(host, settings: settings)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = hosts.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.bar)
                }
            }
        }
    }

    @ViewBuilder
    private func hostMenu(for host: SSHHost) -> some View {
        Button("Connect") { hosts.connect(host, settings: settings) }
        Button("Edit…") { editingHost = host }
        Button(host.isFavorite ? LocalizedStringKey("Remove from Favorites") : "Add to Favorites") { hosts.toggleFavorite(host) }
        Button("Copy SSH Command") {
            let builder = SSHCommandBuilder(sshPath: settings.sshPath)
            if let line = try? builder.commandLine(for: host) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { hosts.delete(hostID: host.id) }
    }
}
