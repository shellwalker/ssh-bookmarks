import XCTest

@testable import MenuSSHCore

final class AskpassTokenTests: XCTestCase {
    func testTokenIsSingleUse() {
        var store = AskpassTokenStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let host = UUID()
        let token = store.issue(hostID: host, now: now, token: "abc123")
        XCTAssertEqual(store.redeem(token, now: now.addingTimeInterval(1)), host)
        XCTAssertNil(store.redeem(token, now: now.addingTimeInterval(1)))
    }

    func testExpiredTokenCannotBeRedeemed() {
        var store = AskpassTokenStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let token = store.issue(hostID: UUID(), now: now, ttl: 60, token: "soon")
        XCTAssertNil(store.redeem(token, now: now.addingTimeInterval(60)))
        XCTAssertNil(store.redeem(token, now: now.addingTimeInterval(61)))
    }

    func testUnknownTokenDoesNotDropOthers() {
        var store = AskpassTokenStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let host = UUID()
        _ = store.issue(hostID: host, now: now, token: "keep")
        XCTAssertNil(store.redeem("nope", now: now))
        XCTAssertEqual(store.redeem("keep", now: now), host)
    }

    func testFileRedeemIsSingleUse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("askpass-tokens.json")
        let now = Date(timeIntervalSince1970: 1_910_000_000)
        let host = UUID()
        let token = try AskpassTokenFile.issue(hostID: host, fileURL: url, now: now, token: "file-token")
        XCTAssertEqual(try AskpassTokenFile.redeem(token: token, fileURL: url, now: now.addingTimeInterval(5)), host)
        XCTAssertNil(try AskpassTokenFile.redeem(token: token, fileURL: url, now: now.addingTimeInterval(6)))
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("password"))
    }

    func testPromptAllowsPasswordAndRejectsOtherQuestions() {
        XCTAssertTrue(AskpassPrompt.isPasswordPrompt("alice@example.com's password: "))
        XCTAssertTrue(AskpassPrompt.isPasswordPrompt("Password:"))
        XCTAssertFalse(AskpassPrompt.isPasswordPrompt(""))
        XCTAssertFalse(AskpassPrompt.isPasswordPrompt("Enter passphrase for key '/Users/a/.ssh/id_ed25519': "))
        XCTAssertFalse(AskpassPrompt.isPasswordPrompt("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
    }

    func testLauncherScriptForcesAskpassAndDoesNotContainThePassword() {
        let script = AskpassLauncherScript.contents(
            askpassExecutable: "/Applications/MenuSSH.app/Contents/MacOS/MenuSSH",
            sshPath: "/usr/bin/ssh",
            token: "deadbeef"
        )
        XCTAssertNotNil(script)
        XCTAssertTrue(script?.contains("SSH_ASKPASS_REQUIRE=force") == true)
        XCTAssertTrue(script?.contains("MENUSH_ASKPASS_TOKEN=") == true)
        XCTAssertTrue(script?.contains("deadbeef") == true)
        XCTAssertTrue(script?.contains("rm -f -- \"$0\"") == true)
        XCTAssertFalse(script?.contains("hunter2") == true)
        XCTAssertNil(
            AskpassLauncherScript.contents(askpassExecutable: "/bin/MenuSSH", sshPath: "/usr/bin/ssh", token: "bad\ntoken"))
    }
}
