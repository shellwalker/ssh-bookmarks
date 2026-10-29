import XCTest

@testable import SSHBookmarksCore

final class HostFilterTests: XCTestCase {
    let prod = HostGroup(name: "Production", sortOrder: 0)
    let dev = HostGroup(name: "Dev", sortOrder: 1)

    func makeLibrary() -> HostLibrary {
        HostLibrary(
            groups: [dev, prod],
            hosts: [
                SSHHost(label: "db", hostname: "db.prod", groupID: prod.id, tags: ["Prod", "postgres"]),
                SSHHost(label: "API", hostname: "api.prod", groupID: prod.id, tags: ["prod"], isFavorite: true),
                SSHHost(label: "scratch", hostname: "10.0.0.9", groupID: dev.id, tags: ["tmp"]),
                SSHHost(label: "NAS", hostname: "nas.local"),
                SSHHost(label: "Orphan", hostname: "o", groupID: UUID()),
            ])
    }

    func testFilters() {
        let lib = makeLibrary()
        XCTAssertEqual(lib.hosts(filter: .all, query: "").map(\.label), ["API", "db", "NAS", "Orphan", "scratch"])
        XCTAssertEqual(lib.hosts(filter: .favorites, query: "").map(\.label), ["API"])
        XCTAssertEqual(lib.hosts(filter: .group(prod.id), query: "").map(\.label), ["API", "db"])
        XCTAssertEqual(lib.hosts(filter: .ungrouped, query: "").map(\.label), ["NAS", "Orphan"])
        XCTAssertEqual(lib.hosts(filter: .tag("PROD"), query: "").map(\.label), ["API", "db"])
        XCTAssertEqual(lib.hosts(filter: .group(prod.id), query: "postgres").map(\.label), ["db"])
        XCTAssertEqual(lib.count(for: .tag("tmp")), 1)
    }

    func testAllTagsDedupesCaseInsensitively() {
        let tags = makeLibrary().allTags
        XCTAssertEqual(tags.map(\.tag), ["postgres", "Prod", "tmp"])
        XCTAssertEqual(tags.first { $0.tag == "Prod" }?.count, 2)
    }

    func testSortedGroups() {
        XCTAssertEqual(makeLibrary().sortedGroups.map(\.name), ["Production", "Dev"])
    }

    func testDuplicateHost() throws {
        var lib = makeLibrary()
        var original = lib.hosts[1]
        original.lastConnectedAt = Date()
        lib.upsert(original)
        let copy = try XCTUnwrap(lib.duplicateHost(id: original.id, labelSuffix: " 副本"))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.label, "API 副本")
        XCTAssertEqual(copy.hostname, original.hostname)
        XCTAssertNil(copy.lastConnectedAt)
        XCTAssertEqual(lib.hosts.count, 6)
        XCTAssertNil(lib.duplicateHost(id: UUID()))
    }

    func testMoveHost() {
        var lib = makeLibrary()
        let nas = lib.hosts[3]
        XCTAssertTrue(lib.moveHost(id: nas.id, toGroup: dev.id))
        XCTAssertEqual(lib.hosts[3].groupID, dev.id)
        XCTAssertFalse(lib.moveHost(id: nas.id, toGroup: UUID()))
        XCTAssertEqual(lib.hosts[3].groupID, dev.id)
        XCTAssertTrue(lib.moveHost(id: nas.id, toGroup: nil))
        XCTAssertNil(lib.hosts[3].groupID)
    }

    func testParentGroupIncludesDescendants() {
        let child = HostGroup(name: "Child", parentID: prod.id, sortOrder: 2)
        var lib = makeLibrary()
        lib.groups.append(child)
        lib.hosts.append(SSHHost(label: "leaf", hostname: "leaf.example", groupID: child.id))
        XCTAssertEqual(lib.hosts(filter: .group(prod.id), query: "").map(\.label), ["API", "db", "leaf"])
        XCTAssertEqual(lib.hosts(filter: .group(child.id), query: "").map(\.label), ["leaf"])
        XCTAssertEqual(lib.count(for: .group(prod.id)), 3)
        XCTAssertEqual(lib.groupIDs(inTreeOf: prod.id), Set([prod.id, child.id]))
    }

    func testGroupOutlineAndReparentRejectsCycles() {
        let root = HostGroup(name: "Root", sortOrder: 0)
        let child = HostGroup(name: "Child", parentID: root.id, sortOrder: 0)
        let leaf = HostGroup(name: "Leaf", parentID: child.id, sortOrder: 0)
        let orphan = HostGroup(name: "Orphan", parentID: UUID(), sortOrder: 1)
        var lib = HostLibrary(groups: [leaf, orphan, child, root])
        let outline = lib.groupOutline()
        XCTAssertEqual(outline.map(\.group.name), ["Root", "Child", "Leaf", "Orphan"])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 2, 0])
        XCTAssertFalse(lib.reparentGroup(id: root.id, parentID: leaf.id))
        XCTAssertFalse(lib.reparentGroup(id: root.id, parentID: root.id))
        XCTAssertFalse(lib.reparentGroup(id: root.id, parentID: UUID()))
        XCTAssertNil(lib.groups.first { $0.id == root.id }?.parentID)
        XCTAssertTrue(lib.reparentGroup(id: child.id, parentID: nil))
        XCTAssertNil(lib.groups.first { $0.id == child.id }?.parentID)
        let a = HostGroup(name: "A", parentID: nil)
        var b = HostGroup(name: "B")
        b.parentID = a.id
        var cycleA = a
        cycleA.parentID = b.id
        let cycled = HostLibrary(groups: [cycleA, b])
        XCTAssertEqual(Set(cycled.groupOutline().map(\.group.name)), Set(["A", "B"]))
    }

    func testHasGroupNamed() {
        let lib = makeLibrary()
        XCTAssertTrue(lib.hasGroup(named: "  production "))
        XCTAssertFalse(lib.hasGroup(named: "Production", excluding: prod.id))
        XCTAssertFalse(lib.hasGroup(named: "Staging"))
    }
}
