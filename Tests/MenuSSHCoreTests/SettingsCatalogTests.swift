import XCTest

@testable import MenuSSHCore

final class SettingsCatalogTests: XCTestCase {
    func testEveryItemIsCatalogedOnce() {
        XCTAssertEqual(
            SettingsCatalog.items.map(\.id).sorted { $0.rawValue < $1.rawValue },
            SettingsItemID.allCases.sorted { $0.rawValue < $1.rawValue })
        for pane in SettingsPaneID.allCases {
            XCTAssertFalse(SettingsCatalog.items(in: pane).isEmpty, "\(pane)")
        }
    }

    func testGroups() {
        let general = SettingsCatalog.groups(in: .general)
        XCTAssertEqual(general.map { $0.map(\.id) }, [[.appearance, .language], [.launchAtLogin, .dockIcon, .closePanelAfterConnect]])
    }

    func testSearchEnglishChineseAndLocalizedTitles() {
        XCTAssertEqual(SettingsCatalog.search("").count, SettingsCatalog.items.count)
        XCTAssertEqual(SettingsCatalog.search("dock").map(\.id), [.dockIcon])
        XCTAssertEqual(SettingsCatalog.search("开机").map(\.id), [.launchAtLogin])
        XCTAssertEqual(SettingsCatalog.search("GHOSTTY").map(\.id), [.sessionTerminal])
        XCTAssertTrue(SettingsCatalog.search("自动化 权限").map(\.id) == [.automationPermission])
        XCTAssertEqual(SettingsCatalog.search("zzz").count, 0)
        XCTAssertEqual(SettingsCatalog.search("会话终端", localizedText: [.sessionTerminal: ["会话终端"]]).map(\.id), [.sessionTerminal])
    }

    func testGroupsOfSearchResultsSplitAcrossPanes() {
        let result = SettingsCatalog.search("ssh")
        let groups = SettingsCatalog.groups(of: result)
        XCTAssertEqual(groups.flatMap { $0 }.map(\.id), result.map(\.id))
        for g in groups { XCTAssertEqual(Set(g.map(\.pane)).count, 1) }
    }
}
