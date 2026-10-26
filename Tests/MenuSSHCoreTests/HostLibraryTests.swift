import XCTest

@testable import MenuSSHCore

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
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[0].kind, .favorites)
        guard case .group(let g1) = s[1].kind, case .group(let g2) = s[2].kind else { return XCTFail() }
        XCTAssertEqual(g1.name, "Production")
        XCTAssertEqual(g2.name, "Dev")
        XCTAssertEqual(s[3].kind, .ungrouped)
        XCTAssertEqual(s[1].hosts.map(\.label), ["API", "DB"])
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
