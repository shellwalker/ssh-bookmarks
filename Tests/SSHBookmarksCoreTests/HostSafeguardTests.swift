import XCTest

@testable import SSHBookmarksCore

final class HostSafeguardTests: XCTestCase {
    func testJumpRejectsSelfAndCycles() {
        let bastion = HostSafeguards.JumpNode(hostname: "bastion.example", jumpHost: "edge.example")
        let edge = HostSafeguards.JumpNode(hostname: "edge.example", jumpHost: nil)
        XCTAssertEqual(
            HostSafeguards.jumpIssue(hostname: "web.example", jumpHost: "web.example", others: []),
            .referencesSelf
        )
        XCTAssertEqual(
            HostSafeguards.jumpIssue(hostname: "web.example", jumpHost: "alice@web.example:22", others: []),
            .referencesSelf
        )
        XCTAssertNil(HostSafeguards.jumpIssue(hostname: "web.example", jumpHost: "alice@bastion.example:22", others: [bastion, edge]))
        XCTAssertEqual(
            HostSafeguards.jumpIssue(
                hostname: "edge.example", jumpHost: "bastion.example", others: [bastion, edge]),
            .cycle
        )
        XCTAssertEqual(HostSafeguards.hopHosts("alice@[fe80::1]:22,edge"), ["fe80::1", "edge"])
    }

    func testPortForwardDuplicatesAndPrivilegedPorts() {
        let forwards = [
            PortForward(kind: .local, listenPort: 80, destinationHost: "127.0.0.1", destinationPort: 80),
            PortForward(kind: .dynamic, listenPort: 80),
            PortForward(kind: .local, listenPort: 8080, destinationHost: "127.0.0.1", destinationPort: 80),
            PortForward(kind: .remote, listenPort: 22, destinationHost: "127.0.0.1", destinationPort: 22),
        ]
        let issues = HostSafeguards.portForwardIssues(forwards)
        XCTAssertTrue(issues.contains(.duplicateListen(80)))
        XCTAssertTrue(issues.contains(.privileged(80)))
        XCTAssertFalse(issues.contains(.privileged(8080)))
        XCTAssertFalse(issues.contains(.duplicateListen(22)))
        XCTAssertTrue(HostSafeguards.portForwardIssues([PortForward(kind: .dynamic, listenPort: 1080)]).isEmpty)
    }
}
