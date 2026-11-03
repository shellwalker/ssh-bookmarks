import Foundation
import XCTest

@testable import SSHBookmarksCore

final class Review2AskpassTests: XCTestCase {
    func testEmptyUsernameOnlyAnswersForLocalSSHUser() {
        XCTAssertFalse(AskpassPrompt.matches("other@server's password:", username: "", hostname: "server"))
        XCTAssertTrue(AskpassPrompt.matches("\(NSUserName())@server's password:", username: "", hostname: "server"))
        var store = AskpassTokenStore()
        _ = store.issue(hostID: UUID(), username: "", hostname: "server", now: Date(), token: "test")
        XCTAssertEqual(store.records.first?.username, NSUserName())
    }

    func testSameHostnameJumpWithDifferentPortDisablesAutomaticPassword() {
        var host = SSHHost(label: "test", hostname: "SERVER", port: 2222, username: "alice", jumpHost: "alice@server:22")
        XCTAssertFalse(AskpassSafety.canAutomaticallyAuthenticate(host))
        host.jumpHost = "alice@other:22,alice@SERVER:2200"
        XCTAssertFalse(AskpassSafety.canAutomaticallyAuthenticate(host))
        host.jumpHost = "alice@other:22"
        XCTAssertTrue(AskpassSafety.canAutomaticallyAuthenticate(host))
        host.hostname = "::1"
        host.jumpHost = "alice@[::1]:22"
        XCTAssertFalse(AskpassSafety.canAutomaticallyAuthenticate(host))
        host.jumpHost = nil
        host.extraOptions = [SSHOption(key: "ProxyJump", value: "alice@[::1]:22")]
        XCTAssertFalse(AskpassSafety.canAutomaticallyAuthenticate(host))
    }
}
