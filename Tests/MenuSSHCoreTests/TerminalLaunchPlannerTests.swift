import XCTest

@testable import MenuSSHCore

final class TerminalLaunchPlannerTests: XCTestCase {
    let argv = ["/usr/bin/ssh", "-l", "o'brien", "--", "h"]

    func testTerminalUsesDoScript() {
        guard case .appleScript(let src) = TerminalLaunchPlanner.plan(terminal: .terminal, argv: argv, mode: .newWindow) else {
            return XCTFail("expected AppleScript")
        }
        XCTAssertTrue(src.contains("tell application id \"com.apple.Terminal\""))
        XCTAssertTrue(src.contains("do script \"/usr/bin/ssh -l 'o'\\\\''brien' -- h\""))
    }

    func testITermNewTab() {
        guard case .appleScript(let src) = TerminalLaunchPlanner.plan(terminal: .iTerm2, argv: argv, mode: .newTab) else {
            return XCTFail("expected AppleScript")
        }
        XCTAssertTrue(src.contains("create tab with default profile"))
        XCTAssertTrue(src.contains("write text"))
    }

    func testGhosttyModernUsesAppleScript() {
        let plan = TerminalLaunchPlanner.plan(terminal: .ghostty, argv: argv, mode: .newWindow, ghosttyVersion: "1.3.1")
        guard case .appleScript(let src) = plan else { return XCTFail("expected AppleScript") }
        XCTAssertTrue(src.contains("new surface configuration"))
        XCTAssertTrue(src.contains("new window with configuration cfg"))
    }

    func testGhosttyLegacyFallsBackToOpen() {
        let plan = TerminalLaunchPlanner.plan(terminal: .ghostty, argv: argv, mode: .newWindow, ghosttyVersion: "1.2.3")
        XCTAssertEqual(
            plan,
            .process(
                executable: "/usr/bin/open",
                arguments: ["-na", "Ghostty", "--args", "--quit-after-last-window-closed=true", "-e"] + argv
            ))
        XCTAssertEqual(
            TerminalLaunchPlanner.plan(terminal: .ghostty, argv: argv, mode: .newTab, ghosttyVersion: nil),
            plan
        )
    }

    func testVersionCompare() {
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.3.0", "1.3.0"), .orderedSame)
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.2.10", "1.3.0"), .orderedAscending)
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.10", "1.3.0"), .orderedDescending)
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.3", "1.3.0"), .orderedSame)
    }
}
