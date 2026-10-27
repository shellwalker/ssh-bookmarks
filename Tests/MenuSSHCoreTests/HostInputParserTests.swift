import XCTest

@testable import MenuSSHCore

final class HostInputParserTests: XCTestCase {
    func testPort() throws {
        XCTAssertNil(try HostInputParser.parsePort(""))
        XCTAssertNil(try HostInputParser.parsePort("   "))
        XCTAssertEqual(try HostInputParser.parsePort(" 2222 "), 2222)
        XCTAssertEqual(try HostInputParser.parsePort("1"), 1)
        XCTAssertEqual(try HostInputParser.parsePort("65535"), 65535)
        for bad in ["0", "65536", "99999999", "99999999999999999999999"] {
            XCTAssertThrowsError(try HostInputParser.parsePort(bad), bad) { XCTAssertEqual($0 as? HostInputParser.PortError, .outOfRange) }
        }
        for bad in ["-1", "+22", "22a", "2 2", "0x16", "２２", "٢٢", "22;id"] {
            XCTAssertThrowsError(try HostInputParser.parsePort(bad), bad) { XCTAssertEqual($0 as? HostInputParser.PortError, .notANumber) }
        }
    }

    func testTags() {
        XCTAssertEqual(HostInputParser.parseTags(""), [])
        XCTAssertEqual(HostInputParser.parseTags(" prod , db,,  "), ["prod", "db"])
        XCTAssertEqual(HostInputParser.parseTags("prod，数据库、Prod;web\nweb"), ["prod", "数据库", "web"])
        XCTAssertEqual(HostInputParser.parseTags("my  tag\t x"), ["my tag x"])
        XCTAssertEqual(HostInputParser.parseTags("a\u{200B}b, c\u{0}"), ["a b", "c"])
        XCTAssertEqual(HostInputParser.formatTags(["a", "b"]), "a, b")
    }

    func testNormalizedName() {
        XCTAssertEqual(HostInputParser.normalizedName("  Prod \n Servers "), "Prod Servers")
        XCTAssertEqual(HostInputParser.normalizedName("\u{202E}evil"), "evil")
    }

    func testAvatarInitial() {
        XCTAssertEqual(SSHHost(label: "web", hostname: "h").avatarInitial, "W")
        XCTAssertEqual(SSHHost(label: "  ", hostname: "db.local").avatarInitial, "D")
        XCTAssertEqual(SSHHost(label: "生产库", hostname: "h").avatarInitial, "生")
        XCTAssertEqual(SSHHost(label: "🇨🇳 cn", hostname: "h").avatarInitial, "🇨🇳")
        XCTAssertEqual(SSHHost(label: "", hostname: "").avatarInitial, "?")
    }

    func testAvatarColorIsStable() {
        let host = SSHHost(label: "a", hostname: "h")
        XCTAssertEqual(host.avatarColorIndex(paletteCount: 8), host.avatarColorIndex(paletteCount: 8))
        XCTAssertTrue((0..<8).contains(host.avatarColorIndex(paletteCount: 8)))
        XCTAssertEqual(host.avatarColorIndex(paletteCount: 0), 0)
    }
}

final class HostSubtitleTests: XCTestCase {
    func testSubtitle() {
        XCTAssertEqual(SSHHost(label: "a", hostname: "10.0.0.15", port: 2201, username: "deploy").subtitle, "deploy@10.0.0.15:2201")
        XCTAssertEqual(SSHHost(label: "a", hostname: "h", port: 22, username: "root").subtitle, "root@h:22")
        XCTAssertEqual(SSHHost(label: "a", hostname: "alias").subtitle, "alias")
        XCTAssertEqual(SSHHost(label: "a", hostname: "fe80::1", port: 22).subtitle, "[fe80::1]:22")
    }
}
