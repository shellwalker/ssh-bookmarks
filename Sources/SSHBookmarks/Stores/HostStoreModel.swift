import AppKit
import Combine
import SSHBookmarksCore

/// 站点数据的 UI 状态层：包装 HostFileStore，提供增删改查、搜索与连接。
@MainActor
final class HostStoreModel: ObservableObject {
    static let shared = HostStoreModel()

    @Published private(set) var library: HostLibrary = .empty
    @Published var lastError: String?
    /// 回退到别的终端时的说明。不是错误，连接已经发出。
    @Published var lastNotice: String?
    /// 菜单栏空状态的「新建站点」：站点窗口出现后打开编辑器。
    @Published var presentNewHost = false
    @Published private(set) var canUndo = false

    let fileStore: HostFileStore
    private let keychain = KeychainService()
    private var undoStack: [HostLibrary] = []

    init(fileStore: HostFileStore? = nil) {
        if let fileStore {
            self.fileStore = fileStore
        } else if let directory = UITestLaunch.dataDirectory {
            self.fileStore = HostFileStore(fileURL: directory.appendingPathComponent("hosts.json"))
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            LegacyDataMigration.moveSupportFolderIfNeeded()
            self.fileStore = HostFileStore(fileURL: HostFileStore.defaultFileURL(appSupportDirectory: appSupport))
        }
    }

    // MARK: - Persistence

    func reload() {
        do {
            library = try fileStore.load()
        } catch {
            lastError = L10n.format("Failed to read hosts file: %@", error.localizedDescription)
            return
        }
        syncNow()
    }

    private var deviceId: String { SettingsStore.shared.deviceId }

    /// 先写本机 hosts.json，再按设置合并同步文件。返回打成平局的冲突条数；同步关闭时为 0。
    @discardableResult
    private func persist() -> Int {
        library = library.pruningTombstones(now: Date())
        do {
            try fileStore.save(library)
        } catch {
            lastError = L10n.format("Failed to save hosts file: %@", error.localizedDescription)
            return 0
        }
        let conflicts = applySync()
        if conflicts > 0 { lastNotice = syncConflictNotice(conflicts) }
        return conflicts
    }

    /// 设置里打开同步，或启动时拉取。不把“另一边较新”当成冲突。
    func syncNow() {
        let conflicts = applySync()
        if conflicts > 0 { lastNotice = syncConflictNotice(conflicts) }
    }

    private func syncConflictNotice(_ conflicts: Int) -> String {
        L10n.format(
            "Sync kept the greater device id for %lld tied items. When updatedAt differs, the newer side is kept.",
            Int64(conflicts)
        )
    }

    private func applySync() -> Int {
        guard SettingsStore.shared.syncEnabled else { return 0 }
        do {
            let result = try SyncReconciler.reconcile(
                local: library,
                directory: SettingsStore.shared.resolvedSyncDirectory,
                deviceId: deviceId
            )
            library = result.library
            try fileStore.save(library)
            return result.conflictCount
        } catch let error as SyncFormatError {
            switch error {
            case .newerSchema:
                lastError = String(localized: "Sync file is from a newer SSH Bookmarks. Update before syncing.")
            case .unreadablePrimary:
                lastError = String(localized: "The sync file could not be read. It was left unchanged.")
            case .secretKey:
                lastError = String(localized: "Refused to write the sync file because it contained a secret field.")
            }
            return 0
        } catch {
            lastError = L10n.format("Failed to sync hosts: %@", error.localizedDescription)
            return 0
        }
    }

    func revealDataFileInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileStore.fileURL])
    }

    // MARK: - Queries

    func sections(matching query: String) -> [HostSection] {
        library.sections(matching: query)
    }

    func host(id: UUID) -> SSHHost? {
        library.hosts.first { $0.id == id }
    }

    func hosts(filter: HostFilter, query: String) -> [SSHHost] {
        library.hosts(filter: filter, query: query)
    }

    func groupName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return library.groups.first { $0.id == id }?.name
    }

    // MARK: - Mutations

    func save(_ host: SSHHost) {
        var updated = host
        updated.updatedAt = Date()
        updated.updatedByDeviceId = deviceId
        library.upsert(updated)
        persist()
    }

    func delete(hostID: UUID) {
        registerUndoPoint()
        library.removeHost(id: hostID, deviceId: deviceId)
        keychain.deleteAll(hostID: hostID)
        persist()
    }

    func toggleFavorite(_ host: SSHHost) {
        var h = host
        h.isFavorite.toggle()
        save(h)
    }

    /// 复制站点，返回副本（名称加“副本”后缀）。
    @discardableResult
    func duplicate(_ host: SSHHost) -> SSHHost? {
        guard var copy = library.duplicateHost(id: host.id, labelSuffix: String(localized: " copy")) else { return nil }
        copy.updatedByDeviceId = deviceId
        library.upsert(copy)
        persist()
        return copy
    }

    func move(_ host: SSHHost, toGroup groupID: UUID?) {
        guard library.moveHost(id: host.id, toGroup: groupID) else { return }
        if var moved = library.hosts.first(where: { $0.id == host.id }) {
            moved.updatedByDeviceId = deviceId
            library.upsert(moved)
        }
        persist()
    }

    enum GroupNameError: LocalizedError {
        case empty
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .empty: return String(localized: "Group name cannot be empty.")
            case .duplicate(let name): return L10n.format("A group named “%@” already exists.", name)
            }
        }
    }

    @discardableResult
    func addGroup(named rawName: String) throws -> HostGroup {
        let name = HostInputParser.normalizedName(rawName)
        guard !name.isEmpty else { throw GroupNameError.empty }
        guard !library.hasGroup(named: name) else { throw GroupNameError.duplicate(name) }
        var group = HostGroup(name: name, sortOrder: (library.groups.map(\.sortOrder).max() ?? -1) + 1)
        group.updatedByDeviceId = deviceId
        library.upsert(group)
        persist()
        return group
    }

    func renameGroup(_ group: HostGroup, to rawName: String) throws {
        let name = HostInputParser.normalizedName(rawName)
        guard !name.isEmpty else { throw GroupNameError.empty }
        guard !library.hasGroup(named: name, excluding: group.id) else { throw GroupNameError.duplicate(name) }
        var g = group
        g.name = name
        g.updatedAt = Date()
        g.updatedByDeviceId = deviceId
        library.upsert(g)
        persist()
    }

    func deleteGroup(id: UUID) {
        registerUndoPoint()
        library.removeGroup(id: id, deviceId: deviceId)
        persist()
    }

    func undoLastChange() {
        guard let previous = undoStack.popLast() else { return }
        canUndo = !undoStack.isEmpty
        library = previous
        let conflicts = persist()
        if conflicts == 0 {
            lastNotice = String(
                localized: "Undid the last change. A deleted password stays removed from the Keychain."
            )
        }
    }

    private func registerUndoPoint() {
        undoStack.append(library)
        if undoStack.count > 20 { undoStack.removeFirst() }
        canUndo = !undoStack.isEmpty
    }

    @discardableResult
    func reparentGroup(id: UUID, parentID: UUID?) -> Bool {
        guard library.reparentGroup(id: id, parentID: parentID, deviceId: deviceId) else { return false }
        persist()
        return true
    }

    /// 从 ~/.ssh/config 导入。同名 hostname 跳过，不覆盖。HostName 只进备注。
    @discardableResult
    func importSSHConfig(from url: URL? = nil) -> SSHConfigImportPlan? {
        let url = url ?? UITestLaunch.sshDirectory.appendingPathComponent("config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = L10n.format("Cannot read %@", url.path)
            return nil
        }
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let entries = SSHConfigParser.parse(
            text,
            homeDirectory: home,
            readFile: { path in
                guard let data = fm.contents(atPath: path) else { return nil }
                return String(data: data, encoding: .utf8)
            },
            listDirectory: { directory in
                (try? fm.contentsOfDirectory(atPath: directory)) ?? []
            }
        )
        let plan = SSHConfigParser.planImport(entries: entries, existingHostnames: Set(library.hosts.map(\.hostname)))
        for var host in plan.hosts {
            host.updatedByDeviceId = deviceId
            library.upsert(host)
        }
        lastError = nil
        let conflicts = persist()
        if conflicts == 0 { lastNotice = importNotice(plan) }
        return plan
    }

    func importNotice(_ plan: SSHConfigImportPlan) -> String {
        let counts = L10n.format(
            "Imported %lld hosts. Skipped %lld duplicates.",
            Int64(plan.hosts.count),
            Int64(plan.skippedDuplicates)
        )
        let alias = String(localized: "Connections use the alias. HostName is saved in notes.")
        return counts + "\n" + alias
    }

    // MARK: - Connect

    func connect(_ host: SSHHost, settings: SettingsStore) {
        let launcher = TerminalLauncher(sshPath: settings.sshPath, terminal: settings.terminal, openMode: settings.openMode)
        let launching = SSHCommandBuilder.omittingRunningTunnels(host, runningForwardIDs: TunnelController.shared.runningForwardIDs)
        do {
            let notice = try launcher.launch(launching)
            DiagnosticLog.connect(
                host: host,
                terminal: settings.terminal.rawValue,
                askpass: host.authMethod == .password,
                fallback: notice?.used.rawValue
            )
            lastError = nil
            var h = host
            h.lastConnectedAt = Date()
            library.upsert(h)
            let conflicts = persist()
            if let notice {
                lastNotice = L10n.format(
                    "%@ is not installed. Opened this session in %@ instead.",
                    notice.missing.displayName,
                    notice.used.displayName
                )
            } else if conflicts == 0 {
                lastNotice = nil
            }
        } catch {
            lastError = error.localizedDescription
            lastNotice = nil
        }
    }
}
