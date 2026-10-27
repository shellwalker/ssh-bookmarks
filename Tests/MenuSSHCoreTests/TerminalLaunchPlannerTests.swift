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

    func testMechanismIgnoresVersionExceptGhostty() {
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .terminal, version: "2.14"), .appleScript)
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .terminal, version: nil), .appleScript)
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .iTerm2, version: "3.4.0"), .appleScript)
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .iTerm2, version: "3.5.10"), .appleScript)
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .ghostty, version: "1.2.9"), .legacyGhosttyProcess)
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .ghostty, version: nil), .legacyGhosttyProcess)
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .ghostty, version: "1.3.0"), .appleScript)
        XCTAssertEqual(TerminalLaunchPlanner.mechanism(for: .ghostty, version: "1.3.1"), .appleScript)
    }

    func testStartupCommandIsASecondLine() {
        let plan = TerminalLaunchPlanner.plan(
            terminal: .terminal, argv: argv, mode: .newWindow, startupCommand: "cd /app && tmux attach")
        guard case .appleScript(let src) = plan else { return XCTFail("expected AppleScript") }
        XCTAssertTrue(src.contains("/usr/bin/ssh -l 'o'\\''brien' -- h\\ncd /app && tmux attach"))
    }

    func testStartupCommandEscapesQuotesAndBackslashes() {
        let plan = TerminalLaunchPlanner.plan(terminal: .iTerm2, argv: argv, mode: .newWindow, startupCommand: "echo \"a\\b\"")
        guard case .appleScript(let src) = plan else { return XCTFail("expected AppleScript") }
        XCTAssertTrue(src.contains("\\necho \\\"a\\\\b\\\""))
    }

    func testLegacyGhosttyWrapsStartupInShell() {
        let plan = TerminalLaunchPlanner.plan(
            terminal: .ghostty, argv: argv, mode: .newWindow, ghosttyVersion: "1.2.3", startupCommand: "tmux attach")
        XCTAssertEqual(
            plan,
            .process(
                executable: "/usr/bin/open",
                arguments: [
                    "-na", "Ghostty", "--args", "--quit-after-last-window-closed=true", "-e", "/bin/sh", "-c",
                    "/usr/bin/ssh -l 'o'\\''brien' -- h\ntmux attach",
                ]
            ))
    }

    func testVersionCompare() {
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.3.0", "1.3.0"), .orderedSame)
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.2.10", "1.3.0"), .orderedAscending)
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.10", "1.3.0"), .orderedDescending)
        XCTAssertEqual(TerminalLaunchPlanner.compareVersions("1.3", "1.3.0"), .orderedSame)
    }
}
