import XCTest

@testable import MenuSSHCore

final class TerminalFallbackTests: XCTestCase {
    func testKeepsPreferredWhenInstalled() {
        let result = TerminalFallback.resolve(preferred: .ghostty, installed: [.ghostty, .terminal])
        XCTAssertEqual(result.terminal, .ghostty)
        XCTAssertNil(result.notice)
    }

    func testTerminalIsUsedEvenWhenNotReportedInstalled() {
        let result = TerminalFallback.resolve(preferred: .terminal, installed: [])
        XCTAssertEqual(result.terminal, .terminal)
        XCTAssertNil(result.notice)
    }

    func testFallsThroughToNextInstalledThenTerminal() {
        let toITerm = TerminalFallback.resolve(preferred: .ghostty, installed: [.iTerm2, .terminal])
        XCTAssertEqual(toITerm.terminal, .iTerm2)
        XCTAssertEqual(toITerm.notice, TerminalFallbackNotice(missing: .ghostty, used: .iTerm2))

        let toGhostty = TerminalFallback.resolve(preferred: .iTerm2, installed: [.ghostty])
        XCTAssertEqual(toGhostty.terminal, .ghostty)
        XCTAssertEqual(toGhostty.notice, TerminalFallbackNotice(missing: .iTerm2, used: .ghostty))

        let toTerminal = TerminalFallback.resolve(preferred: .ghostty, installed: [])
        XCTAssertEqual(toTerminal.terminal, .terminal)
        XCTAssertEqual(toTerminal.notice, TerminalFallbackNotice(missing: .ghostty, used: .terminal))
    }

    func testMissingITermDoesNotInventAGhosttyInstall() {
        let result = TerminalFallback.resolve(preferred: .iTerm2, installed: [])
        XCTAssertEqual(result.terminal, .terminal)
        XCTAssertEqual(result.notice?.used, .terminal)
    }
}
