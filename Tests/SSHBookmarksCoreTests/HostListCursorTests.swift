import XCTest

@testable import SSHBookmarksCore

final class HostListCursorTests: XCTestCase {
    func makeSections() -> [HostSection] {
        let g = HostGroup(name: "G")
        let a = SSHHost(label: "a", hostname: "a", groupID: g.id, isFavorite: true)
        let b = SSHHost(label: "b", hostname: "b", groupID: g.id)
        let c = SSHHost(label: "c", hostname: "c")
        return HostLibrary(groups: [g], hosts: [a, b, c]).sections(matching: "")
    }

    func testFavoriteAppearsTwiceWithDistinctIDs() {
        let cursor = HostListCursor(sections: makeSections())
        XCTAssertEqual(cursor.entries.map(\.host.label), ["a", "a", "b", "c"])
        XCTAssertEqual(Set(cursor.entries.map(\.id)).count, 4)
        XCTAssertEqual(cursor.selectedIndex, 0)
    }

    func testMoveClampsAtBounds() {
        var cursor = HostListCursor(sections: makeSections())
        XCTAssertEqual(cursor.handle(.up), .select(cursor.entries[0].id))
        XCTAssertEqual(cursor.selectedIndex, 0)
        _ = cursor.handle(.down)
        _ = cursor.handle(.down)
        XCTAssertEqual(cursor.selectedEntry?.host.label, "b")
        _ = cursor.handle(.down)
        _ = cursor.handle(.down)
        XCTAssertEqual(cursor.selectedIndex, 3)
        _ = cursor.handle(.home)
        XCTAssertEqual(cursor.selectedIndex, 0)
        _ = cursor.handle(.end)
        XCTAssertEqual(cursor.selectedIndex, 3)
        cursor.pageSize = 2
        _ = cursor.handle(.pageUp)
        XCTAssertEqual(cursor.selectedIndex, 1)
        _ = cursor.handle(.pageDown)
        _ = cursor.handle(.pageDown)
        XCTAssertEqual(cursor.selectedIndex, 3)
    }

    func testEnterConnectsSelectedAndEscapeCloses() {
        var cursor = HostListCursor(sections: makeSections())
        _ = cursor.handle(.down)
        _ = cursor.handle(.down)
        guard case .connect(let host) = cursor.handle(.enter) else { return XCTFail() }
        XCTAssertEqual(host.label, "b")
        XCTAssertEqual(cursor.handle(.escape), .close)
    }

    func testEmptyList() {
        var cursor = HostListCursor(sections: [])
        XCTAssertNil(cursor.selectedIndex)
        XCTAssertEqual(cursor.handle(.down), .none)
        XCTAssertEqual(cursor.handle(.enter), .none)
        XCTAssertEqual(cursor.handle(.escape), .close)
    }

    func testResetAndUpdate() {
        var cursor = HostListCursor(sections: makeSections())
        _ = cursor.handle(.end)
        let selected = cursor.selectedID
        cursor.update(sections: makeSections().reversed())
        XCTAssertNotEqual(cursor.selectedID, selected)  // 新的 section 里 id 不同（UUID 重新生成）→ 回到第一项
        XCTAssertEqual(cursor.selectedIndex, 0)

        let sections = makeSections()
        cursor.reset(sections: sections)
        _ = cursor.handle(.end)
        let keep = cursor.selectedID
        cursor.update(sections: Array(sections.reversed()))
        XCTAssertEqual(cursor.selectedID, keep)
        XCTAssertEqual(cursor.selectedIndex, 0)

        cursor.reset(sections: sections)
        XCTAssertEqual(cursor.selectedIndex, 0)
        cursor.select(id: "nope")
        XCTAssertEqual(cursor.selectedIndex, 0)
        cursor.select(id: cursor.entries[2].id)
        XCTAssertEqual(cursor.selectedIndex, 2)
    }

    func testKeyCodes() {
        XCTAssertEqual(PanelKey(keyCode: 125), .down)
        XCTAssertEqual(PanelKey(keyCode: 126), .up)
        XCTAssertEqual(PanelKey(keyCode: 36), .enter)
        XCTAssertEqual(PanelKey(keyCode: 76), .enter)
        XCTAssertEqual(PanelKey(keyCode: 53), .escape)
        XCTAssertEqual(PanelKey(keyCode: 45, control: true), .down)
        XCTAssertEqual(PanelKey(keyCode: 35, control: true), .up)
        XCTAssertNil(PanelKey(keyCode: 45))
        XCTAssertNil(PanelKey(keyCode: 0))
    }
}
