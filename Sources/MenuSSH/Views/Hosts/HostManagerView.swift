import AppKit
import MenuSSHCore
import SwiftUI

/// 主窗口：左侧“全部 / 收藏 / 分组 / 标签”，右侧可搜索的站点列表。双击或 Return 连接。
@MainActor
struct HostManagerView: View {
    @EnvironmentObject private var hosts: HostStoreModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @State private var filter: HostFilter? = .all
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editingHost: SSHHost?

    // 分组新建 / 重命名共用一个输入弹窗。
    @State private var groupNameDraft = ""
    @State private var showingNewGroup = false
    @State private var renamingGroup: HostGroup?
    @State private var showingRenameGroup = false
    @State private var groupError: String?

    @State private var hostPendingDeletion: SSHHost?
    @State private var groupPendingDeletion: HostGroup?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            hostList
        }
        .modifier(UITestContainer(identifier: UITestID.hosts))
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search hosts"))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editingHost = SSHHost(label: "", hostname: "", groupID: currentGroupID)
                } label: {
                    Label("New Host", systemImage: "plus")
                }
                .accessibilityIdentifier(UITestID.hostsNew)
                .keyboardShortcut("n", modifiers: .command)
                Button {
                    hosts.importSSHConfig()
                } label: {
                    Label("Import ~/.ssh/config", systemImage: "square.and.arrow.down")
                }
                Button {
                    settings.pendingSettingsPane = nil
                    openWindow(id: WindowID.settings)
                    AppActivation.bringToFront()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier(UITestID.hostsSettings)
            }
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(
                host: host,
                outline: hosts.library.groupOutline(),
                otherHosts: hosts.library.hosts
                    .filter { $0.id != host.id }
                    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            ) { saved in
                hosts.save(saved)
                selection = saved.id
            }
        }
        .alert("New Group", isPresented: $showingNewGroup) {
            TextField("Name", text: $groupNameDraft)
                .accessibilityIdentifier(UITestID.groupName)
            Button("Create") { commitGroupName(nil) }
                .accessibilityIdentifier(UITestID.groupCreate)
            Button("Cancel", role: .cancel) { groupNameDraft = "" }
        }
        // TextField 只能放在 isPresented 版本的 alert 里；presenting 版本在 macOS 上不接受文本框。
        // 分组对象单独保存，按钮触发时仍能拿到被重命名的那一项。
        .alert("Rename Group", isPresented: $showingRenameGroup) {
            TextField("Name", text: $groupNameDraft)
            Button("Rename") {
                if let group = renamingGroup { commitGroupName(group) }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) {
                groupNameDraft = ""
                renamingGroup = nil
            }
        }
        .alert(
            "Cannot Save Group",
            isPresented: Binding(get: { groupError != nil }, set: { if !$0 { groupError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: groupError ?? "")
        }
        .confirmationDialog(
            "Delete this host?",
            isPresented: Binding(get: { hostPendingDeletion != nil }, set: { if !$0 { hostPendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: hostPendingDeletion
        ) { host in
            Button("Delete", role: .destructive) {
                hosts.delete(hostID: host.id)
                if selection == host.id { selection = nil }
            }
        } message: { host in
            Text(verbatim: L10n.format("“%@” and its saved password will be removed.", host.label))
        }
        .confirmationDialog(
            "Delete this group?",
            isPresented: Binding(get: { groupPendingDeletion != nil }, set: { if !$0 { groupPendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: groupPendingDeletion
        ) { group in
            Button("Delete Group", role: .destructive) {
                hosts.deleteGroup(id: group.id)
                if filter == .group(group.id) { filter = .all }
            }
        } message: { group in
            Text(verbatim: L10n.format("Hosts in “%@” will be moved to Ungrouped.", group.name))
        }
        .onAppear { AppActivation.bringToFront() }
    }

    private var currentGroupID: UUID? {
        if case .group(let id) = filter { return id }
        return nil
    }

    @ViewBuilder
    private func nestMenu(for group: HostGroup) -> some View {
        let candidates = hosts.library.groupOutline().filter { $0.group.id != group.id }
        if !candidates.isEmpty {
            Menu("Nest Under") {
                ForEach(candidates) { entry in
                    Button {
                        hosts.reparentGroup(id: group.id, parentID: entry.group.id)
                    } label: {
                        Text(verbatim: String(repeating: "  ", count: entry.depth) + entry.group.name)
                    }
                    .accessibilityIdentifier(UITestID.groupNest(entry.group.name))
                    .disabled(hosts.library.groupIDs(inTreeOf: group.id).contains(entry.group.id))
                }
            }
        }
    }

    private func commitGroupName(_ group: HostGroup?) {
        let name = groupNameDraft
        groupNameDraft = ""
        do {
            if let group {
                try hosts.renameGroup(group, to: name)
            } else {
                let created = try hosts.addGroup(named: name)
                filter = .group(created.id)
            }
        } catch {
            groupError = error.localizedDescription
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                Label("All Hosts", systemImage: "server.rack")
                    .badge(hosts.library.hosts.count)
                    .tag(HostFilter.all)
                Label("Favorites", systemImage: "star")
                    .badge(hosts.library.count(for: .favorites))
                    .tag(HostFilter.favorites)
            }
            Section("Groups") {
                ForEach(hosts.library.groupOutline()) { entry in
                    let group = entry.group
                    Label {
                        Text(verbatim: group.name)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .padding(.leading, CGFloat(entry.depth) * 12)
                    .badge(hosts.library.count(for: .group(group.id)))
                    .accessibilityIdentifier(UITestID.group(group.name))
                    .tag(HostFilter.group(group.id))
                    .contextMenu {
                        Button("Rename…") {
                            groupNameDraft = group.name
                            renamingGroup = group
                            showingRenameGroup = true
                        }
                        nestMenu(for: group)
                        Button("Move to Top Level") {
                            hosts.reparentGroup(id: group.id, parentID: nil)
                        }
                        .disabled(group.parentID == nil)
                        Button("Delete Group…", role: .destructive) { groupPendingDeletion = group }
                    }
                }
                Label("Ungrouped", systemImage: "tray")
                    .badge(hosts.library.count(for: .ungrouped))
                    .tag(HostFilter.ungrouped)
            }
            let tags = hosts.library.allTags
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags) { tag in
                        Label {
                            Text(verbatim: tag.tag)
                        } icon: {
                            Image(systemName: "tag")
                        }
                        .badge(tag.count)
                        .tag(HostFilter.tag(tag.tag))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                groupNameDraft = ""
                showingNewGroup = true
            } label: {
                Label("New Group", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier(UITestID.hostsNewGroup)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.bar)
        }
    }

    // MARK: Host list

    @ViewBuilder
    private var hostList: some View {
        let list = hosts.hosts(filter: filter ?? .all, query: query)
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
            .onDeleteCommand {
                if let id = selection, let host = hosts.host(id: id) { hostPendingDeletion = host }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = hosts.lastError {
                    Text(verbatim: error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.bar)
                } else if let notice = hosts.lastNotice {
                    Label {
                        Text(verbatim: notice)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
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
        Divider()
        Button("Edit…") { editingHost = host }
            .accessibilityIdentifier(UITestID.hostEdit)
        Button("Duplicate") {
            if let copy = hosts.duplicate(host) { selection = copy.id }
        }
        Button(host.isFavorite ? LocalizedStringKey("Remove from Favorites") : "Add to Favorites") { hosts.toggleFavorite(host) }
        Menu("Move to Group") {
            Button("Ungrouped") { hosts.move(host, toGroup: nil) }
                .disabled(host.groupID == nil)
            if !hosts.library.groups.isEmpty { Divider() }
            ForEach(hosts.library.sortedGroups) { group in
                Button {
                    hosts.move(host, toGroup: group.id)
                } label: {
                    Text(verbatim: group.name)
                }
                .disabled(host.groupID == group.id)
            }
        }
        Button("Copy SSH Command") {
            let builder = SSHCommandBuilder(sshPath: settings.sshPath)
            if let line = try? builder.commandLine(for: host) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { hostPendingDeletion = host }
    }
}
