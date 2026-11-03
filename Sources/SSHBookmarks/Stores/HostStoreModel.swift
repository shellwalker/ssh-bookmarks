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
    private var hasLoadedLibrary = false
    private var syncing = false
    private var syncSubscriptions = Set<AnyCancellable>()
    private var syncPresenter: SyncDirectoryPresenter?
    private var syncTask: Task<Void, Never>?
    private var undoStack: [HostDeletionUndo] = []

    init(fileStore: HostFileStore? = nil) {
        if let fileStore {
            self.fileStore = fileStore
        } else if let directory = UITestLaunch.dataDirectory {
            self.fileStore = HostFileStore(fileURL: directory.appendingPathComponent("hosts.json"))
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            LegacyDataMigration.moveSupportFolderIfNeeded()
            let url =
                LegacyDataMigration.supportMigrationFailed
                ? ProductPaths.legacySupportDirectory(applicationSupport: appSupport).appendingPathComponent("hosts.json")
                : HostFileStore.defaultFileURL(appSupportDirectory: appSupport)
            self.fileStore = HostFileStore(fileURL: url)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleSync() }
            }.store(in: &syncSubscriptions)
        SettingsStore.shared.$syncEnabled.combineLatest(SettingsStore.shared.$syncFolderPath)
            .sink { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateSyncMonitoring()
                    self?.scheduleSync()
                }
            }.store(in: &syncSubscriptions)
    }

    deinit {
        syncTask?.cancel()
        syncPresenter?.stop()
    }

    private func updateSyncMonitoring() {
        let settings = SettingsStore.shared
        let directory = settings.resolvedSyncDirectory
        if settings.syncEnabled, syncPresenter?.presentedItemURL == directory { return }
        syncPresenter?.stop()
        syncPresenter = nil
        guard settings.syncEnabled else { return }
        syncPresenter = SyncDirectoryPresenter(directory: directory) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleSync() }
        }
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    private func checkWritable() -> Bool {
        if LegacyDataMigration.supportMigrationFailed || LegacyDataMigration.iCloudMigrationFailed {
            lastError = String(localized: "Data migration failed. Changes are disabled until migration succeeds. Restart to retry.")
            return false
        }
        guard library.schemaVersion <= HostLibrary.currentSchemaVersion else {
            lastError = String(localized: "Hosts file is from a newer SSH Bookmarks. Update before making changes.")
            return false
        }
        return true
    }

    // MARK: - Persistence

    func reload() {
        hasLoadedLibrary = false
        do {
            library = try fileStore.load()
            hasLoadedLibrary = true
        } catch {
            lastError = L10n.format("Failed to read hosts file: %@", error.localizedDescription)
            return
        }
        guard checkWritable() else { return }
        updateSyncMonitoring()
        syncNow()
    }

    private var deviceId: String { SettingsStore.shared.deviceId }

    /// 先写本机 hosts.json，再按设置合并同步文件。nil 表示本机保存失败，0 表示没有平局冲突。
    @discardableResult
    private func persist() -> Int? {
        guard checkWritable() else { return nil }
        library = library.pruningTombstones(now: Date())
        do {
            try fileStore.save(library)
        } catch {
            if error as? HostFileStoreError == .newerSchema {
                lastError = String(localized: "Hosts file is from a newer SSH Bookmarks. Update before making changes.")
            } else {
                lastError = L10n.format("Failed to save hosts file: %@", error.localizedDescription)
            }
            return nil
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
        guard hasLoadedLibrary, SettingsStore.shared.syncEnabled, !syncing, checkWritable() else { return 0 }
        syncing = true
        defer { syncing = false }
        do {
            let result = try SyncReconciler.reconcile(
                local: library,
                directory: SettingsStore.shared.resolvedSyncDirectory,
                deviceId: deviceId
            )
            let deletedIDs = Set(library.hosts.map(\.id)).subtracting(result.library.hosts.map(\.id))
            if result.library != library {
                try fileStore.save(result.library)
                let before = library
                library = result.library
                for id in deletedIDs { TunnelController.shared.stop(hostID: id) }
                reconcileTunnels(from: before)
            }
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

    @discardableResult
    func save(_ host: SSHHost) -> Bool {
        guard checkWritable() else { return false }
        let before = library
        var updated = host
        updated.updatedAt = Date()
        updated.updatedByDeviceId = deviceId
        library.upsert(updated)
        guard persist() != nil else { library = before; return false }
        reconcileTunnels(from: before)
        return true
    }

    private func reconcileTunnels(from before: HostLibrary) {
        for old in before.hosts {
            if let new = host(id: old.id) { TunnelController.shared.reconcile(old: old, new: new) }
        }
    }

    /// Compensate a failed editor credential update without changing credentials again.
    func restoreHost(_ baseline: SSHHost?, hostID: UUID) -> Bool {
        if let baseline { return save(baseline) }
        let before = library
        guard checkWritable() else { return false }
        library.removeHost(id: hostID, deviceId: deviceId)
        guard persist() != nil else { library = before; return false }
        TunnelController.shared.stop(hostID: hostID)
        return true
    }

    func delete(hostID: UUID) {
        let before = library
        guard checkWritable() else { return }
        library.removeHost(id: hostID, deviceId: deviceId)
        guard persist() != nil else { library = before; return }
        TunnelController.shared.stop(hostID: hostID)
        registerUndoPoint(before: before)
        do {
            try keychain.deleteAll(hostID: hostID)
        } catch {
            lastError = L10n.format("Keychain error: %@", error.localizedDescription)
        }
    }

    func toggleFavorite(_ host: SSHHost) {
        var h = host
        h.isFavorite.toggle()
        save(h)
    }

    /// 复制站点，返回副本（名称加“副本”后缀）。
    @discardableResult
    func duplicate(_ host: SSHHost) -> SSHHost? {
        guard checkWritable() else { return nil }
        let before = library
        guard var copy = library.duplicateHost(id: host.id, labelSuffix: String(localized: " copy")) else { return nil }
        copy.updatedByDeviceId = deviceId
        library.upsert(copy)
        guard persist() != nil else { library = before; return nil }
        return copy
    }

    func move(_ host: SSHHost, toGroup groupID: UUID?) {
        guard checkWritable() else { return }
        let before = library
        guard library.moveHost(id: host.id, toGroup: groupID) else { return }
        if var moved = library.hosts.first(where: { $0.id == host.id }) {
            moved.updatedByDeviceId = deviceId
            library.upsert(moved)
        }
        if persist() == nil { library = before }
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
        guard checkWritable() else { throw persistenceError() }
        let before = library
        let name = HostInputParser.normalizedName(rawName)
        guard !name.isEmpty else { throw GroupNameError.empty }
        guard !library.hasGroup(named: name) else { throw GroupNameError.duplicate(name) }
        var group = HostGroup(name: name, sortOrder: (library.groups.map(\.sortOrder).max() ?? -1) + 1)
        group.updatedByDeviceId = deviceId
        library.upsert(group)
        guard persist() != nil else { library = before; throw persistenceError() }
        return group
    }

    func renameGroup(_ group: HostGroup, to rawName: String) throws {
        guard checkWritable() else { throw persistenceError() }
        let before = library
        let name = HostInputParser.normalizedName(rawName)
        guard !name.isEmpty else { throw GroupNameError.empty }
        guard !library.hasGroup(named: name, excluding: group.id) else { throw GroupNameError.duplicate(name) }
        var g = group
        g.name = name
        g.updatedAt = Date()
        g.updatedByDeviceId = deviceId
        library.upsert(g)
        guard persist() != nil else { library = before; throw persistenceError() }
    }

    func deleteGroup(id: UUID) {
        guard checkWritable() else { return }
        let before = library
        library.removeGroup(id: id, deviceId: deviceId)
        guard persist() != nil else { library = before; return }
        registerUndoPoint(before: before)
    }

    func undoLastChange() {
        guard checkWritable(), let previous = undoStack.last else { return }
        let before = library
        previous.restore(in: &library, deviceId: deviceId)
        guard let conflicts = persist() else { library = before; return }
        undoStack.removeLast()
        canUndo = !undoStack.isEmpty
        if conflicts == 0 {
            lastNotice = String(
                localized: "Undid the last change. A deleted password stays removed from the Keychain."
            )
        }
    }

    private func persistenceError() -> NSError {
        NSError(domain: "SSHBookmarks.Persistence", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError ?? ""])
    }

    private func registerUndoPoint(before: HostLibrary) {
        undoStack.append(HostDeletionUndo(before: before, after: library))
        if undoStack.count > 20 { undoStack.removeFirst() }
        canUndo = !undoStack.isEmpty
    }

    @discardableResult
    func reparentGroup(id: UUID, parentID: UUID?) -> Bool {
        guard checkWritable() else { return false }
        let before = library
        guard library.reparentGroup(id: id, parentID: parentID, deviceId: deviceId) else { return false }
        guard persist() != nil else { library = before; return false }
        return true
    }

    /// 从 ~/.ssh/config 导入。同名 hostname 跳过，不覆盖。HostName 只进备注。
    @discardableResult
    func importSSHConfig(from url: URL? = nil) -> SSHConfigImportPlan? {
        guard checkWritable() else { return nil }
        let before = library
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
        guard let conflicts = persist() else { library = before; return nil }
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
            let before = library
            let conflicts: Int?
            if checkWritable() {
                library.upsert(h)
                conflicts = persist()
                if conflicts == nil { library = before }
            } else {
                conflicts = nil
            }
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
