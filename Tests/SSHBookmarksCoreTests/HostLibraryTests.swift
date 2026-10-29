import XCTest

@testable import SSHBookmarksCore

final class HostLibraryTests: XCTestCase {
    func makeLibrary() -> HostLibrary {
        let prod = HostGroup(name: "Production", sortOrder: 0)
        let dev = HostGroup(name: "Dev", sortOrder: 1)
        return HostLibrary(
            groups: [dev, prod],
            hosts: [
                SSHHost(label: "API", hostname: "api.prod", username: "deploy", groupID: prod.id, tags: ["prod", "api"], isFavorite: true),
                SSHHost(label: "DB", hostname: "db.prod", groupID: prod.id, tags: ["prod", "postgres"]),
                SSHHost(label: "Scratch", hostname: "10.0.0.9", groupID: dev.id),
                SSHHost(label: "Home NAS", hostname: "nas.local"),
            ])
    }

    func testSectionsOrder() {
        let s = makeLibrary().sections(matching: "")
        XCTAssertEqual(s.count, 3)
        XCTAssertFalse(s.contains { $0.kind == .favorites })
        guard case .group(let g1) = s[0].kind, case .group(let g2) = s[1].kind else { return XCTFail() }
        XCTAssertEqual(g1.name, "Production")
        XCTAssertEqual(g2.name, "Dev")
        XCTAssertEqual(s[2].kind, .ungrouped)
        XCTAssertEqual(s[0].hosts.map(\.label), ["API", "DB"])
    }

    func testRecentSectionIsFirstAndHiddenWhileSearching() {
        var lib = makeLibrary()
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        lib.hosts[0].lastConnectedAt = older
        lib.hosts[3].lastConnectedAt = newer
        let sections = lib.sections(matching: "")
        XCTAssertEqual(sections.first?.kind, .recent)
        XCTAssertEqual(sections.first?.hosts.map(\.label), ["Home NAS", "API"])
        XCTAssertEqual(sections.first?.id, "recent")
        XCTAssertFalse(sections.contains { $0.kind == .favorites })
        let production = sections.first { if case .group(let group) = $0.kind { return group.name == "Production" }; return false }
        XCTAssertEqual(production?.hosts.map(\.label), ["DB"])
        XCTAssertFalse(lib.sections(matching: "api").contains { $0.kind == .recent })

        for index in lib.hosts.indices {
            lib.hosts[index].lastConnectedAt = Date(timeIntervalSince1970: TimeInterval(index))
        }
        XCTAssertEqual(lib.recentHosts().count, 4)
        let many = HostLibrary(
            hosts: (0..<10).map { index in
                SSHHost(
                    label: "h\(index)", hostname: "h\(index)", lastConnectedAt: Date(timeIntervalSince1970: TimeInterval(index)))
            })
        XCTAssertEqual(many.recentHosts().count, HostLibrary.recentSectionLimit)
        XCTAssertEqual(many.recentHosts().first?.label, "h9")
    }

    func testSearchMatchesTagsGroupsAndMultipleTokens() {
        let lib = makeLibrary()
        XCTAssertEqual(lib.hosts(matching: "postgres").map(\.label), ["DB"])
        XCTAssertEqual(lib.hosts(matching: "production").count, 2)
        XCTAssertEqual(lib.hosts(matching: "prod deploy").map(\.label), ["API"])
        XCTAssertEqual(lib.hosts(matching: "NAS").map(\.label), ["Home NAS"])
        XCTAssertTrue(lib.hosts(matching: "nothing-here").isEmpty)
        // 搜索时不单独显示“收藏”分区，避免重复。
        XCTAssertFalse(lib.sections(matching: "api").contains { $0.kind == .favorites })
    }

    func testGroupPathShowsAncestors() {
        let parent = HostGroup(name: "Production", sortOrder: 0)
        let child = HostGroup(name: "Edge", parentID: parent.id, sortOrder: 0)
        let library = HostLibrary(groups: [child, parent])
        XCTAssertEqual(library.groupPath(id: parent.id), "Production")
        XCTAssertEqual(library.groupPath(id: child.id), "Production / Edge")
        var cycle = library
        cycle.groups[1].parentID = child.id
        XCTAssertFalse(cycle.groupPath(id: child.id).isEmpty)
        XCTAssertLessThan(cycle.groupPath(id: child.id).count, 200)
    }

    func testRemoveGroupMovesHostsToUngrouped() {
        var lib = makeLibrary()
        let prodID = lib.groups.first { $0.name == "Production" }!.id
        lib.removeGroup(id: prodID)
        XCTAssertTrue(lib.hosts.filter { $0.groupID == prodID }.isEmpty)
        XCTAssertEqual(lib.groups.count, 1)
    }

    func testFileStoreRoundTripAndLenientDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostFileStore(fileURL: dir.appendingPathComponent("hosts.json"))
        XCTAssertEqual(try store.load(), .empty)

        let lib = makeLibrary()
        try store.save(lib)
        let loaded = try store.load()
        XCTAssertEqual(loaded.hosts.map(\.id), lib.hosts.map(\.id))
        XCTAssertEqual(loaded.groups.map(\.id), lib.groups.map(\.id))

        let minimal = #"{"schemaVersion":1,"groups":[],"hosts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","hostname":"x"}]}"#
        let decoded = try HostFileStore.makeDecoder().decode(HostLibrary.self, from: Data(minimal.utf8))
        XCTAssertEqual(decoded.hosts.first?.label, "x")
        XCTAssertEqual(decoded.hosts.first?.authMethod, .automatic)
    }

    func testDockIconMode() {
        XCTAssertFalse(DockIconMode.hidden.showsDockIcon(hasVisibleWindow: true))
        XCTAssertTrue(DockIconMode.visible.showsDockIcon(hasVisibleWindow: false))
        XCTAssertTrue(DockIconMode.followWindow.showsDockIcon(hasVisibleWindow: true))
        XCTAssertFalse(DockIconMode.followWindow.showsDockIcon(hasVisibleWindow: false))
    }
}
