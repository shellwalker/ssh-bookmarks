import AppKit
import MenuSSHCore

/// 站点数据的 UI 状态层：包装 HostFileStore，提供增删改查、搜索与连接。
@MainActor
final class HostStoreModel: ObservableObject {
    static let shared = HostStoreModel()

    @Published private(set) var library: HostLibrary = .empty
    @Published var lastError: String?

    let fileStore: HostFileStore
    private let keychain = KeychainService()

    init(fileStore: HostFileStore? = nil) {
        if let fileStore {
            self.fileStore = fileStore
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileStore = HostFileStore(fileURL: HostFileStore.defaultFileURL(appSupportDirectory: appSupport))
        }
    }

    // MARK: - Persistence

    func reload() {
        do {
            library = try fileStore.load()
        } catch {
            lastError = String(localized: "Failed to read hosts file: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            try fileStore.save(library)
        } catch {
            lastError = String(localized: "Failed to save hosts file: \(error.localizedDescription)")
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

    func groupName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return library.groups.first { $0.id == id }?.name
    }

    // MARK: - Mutations

    func save(_ host: SSHHost) {
        var updated = host
        updated.updatedAt = Date()
        library.upsert(updated)
        persist()
    }

    func delete(hostID: UUID) {
        library.removeHost(id: hostID)
        keychain.deleteAll(hostID: hostID)
        persist()
    }

    func toggleFavorite(_ host: SSHHost) {
        var h = host
        h.isFavorite.toggle()
        save(h)
    }

    @discardableResult
    func addGroup(named name: String) -> HostGroup {
        let group = HostGroup(name: name, sortOrder: (library.groups.map(\.sortOrder).max() ?? -1) + 1)
        library.upsert(group)
        persist()
        return group
    }

    func renameGroup(_ group: HostGroup, to name: String) {
        var g = group
        g.name = name
        library.upsert(g)
        persist()
    }

    func deleteGroup(id: UUID) {
        library.removeGroup(id: id)
        persist()
    }

    /// 从 ~/.ssh/config 导入（跳过已存在的同名 hostname）。返回导入数量。
    @discardableResult
    func importSSHConfig(from url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = String(localized: "Cannot read \(url.path)")
            return 0
        }
        let existing = Set(library.hosts.map { $0.hostname.lowercased() })
        let newHosts = SSHConfigParser.makeHosts(from: SSHConfigParser.parse(text))
            .filter { !existing.contains($0.hostname.lowercased()) }
        for h in newHosts { library.upsert(h) }
        persist()
        return newHosts.count
    }

    // MARK: - Connect

    func connect(_ host: SSHHost, settings: SettingsStore) {
        let launcher = TerminalLauncher(sshPath: settings.sshPath, terminal: settings.terminal, openMode: settings.openMode)
        do {
            try launcher.launch(host)
            lastError = nil
            var h = host
            h.lastConnectedAt = Date()
            library.upsert(h)
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
