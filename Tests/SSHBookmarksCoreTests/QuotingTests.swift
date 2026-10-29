import XCTest

@testable import SSHBookmarksCore

final class QuotingTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(ShellQuoting.quote("abc"), "abc")
        XCTAssertEqual(ShellQuoting.quote(""), "''")
        XCTAssertEqual(ShellQuoting.quote("a b"), "'a b'")
        XCTAssertEqual(ShellQuoting.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuoting.quote("$(id)"), "'$(id)'")
        XCTAssertEqual(ShellQuoting.quote("~/x"), "'~/x'")
    }

    func testAppleScriptLiteral() {
        XCTAssertEqual(AppleScriptQuoting.stringLiteral("abc"), "\"abc\"")
        XCTAssertEqual(AppleScriptQuoting.stringLiteral("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(AppleScriptQuoting.stringLiteral("a\\b"), "\"a\\\\b\"")
        // 试图提前闭合字符串并注入 AppleScript：引号被转义，仍是一个字面量。
        XCTAssertEqual(
            AppleScriptQuoting.stringLiteral("x\" & (do shell script \"id\") & \""),
            "\"x\\\" & (do shell script \\\"id\\\") & \\\"\""
        )
    }
}
