import Foundation
import XCTest

@testable import SSHBookmarksCore

final class Review2TunnelTests: XCTestCase {
    func testExecutableIdentityResolvesSymlinksAndLegacyPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ssh")
        let link = root.appendingPathComponent("linked-ssh")
        try Data().write(to: executable)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(TunnelProcessIdentity.normalizedPath(link.path), executable.path)
        XCTAssertTrue(TunnelProcessIdentity.pathsMatch(link.path, executable.path))
        XCTAssertFalse(TunnelProcessIdentity.pathsMatch(link.path, root.appendingPathComponent("other").path))
    }

    func testCleanupUsesStoppedIdentityAndRejectsReusedPID() {
        let old = TunnelProcessIdentity(pid: 123, startedAt: Date(timeIntervalSince1970: 10), executablePath: "/bin/ssh")
        XCTAssertTrue(
            old.canSignal(observedStart: old.startedAt, observedPath: "/bin/ssh", leaderAlive: true, groupAlive: true, ownsGroup: true))
        XCTAssertFalse(
            old.canSignal(
                observedStart: Date(timeIntervalSince1970: 20), observedPath: "/bin/ssh", leaderAlive: true, groupAlive: true,
                ownsGroup: true))
        XCTAssertTrue(old.canSignal(observedStart: nil, observedPath: nil, leaderAlive: false, groupAlive: true, ownsGroup: true))
        XCTAssertFalse(old.canSignal(observedStart: nil, observedPath: nil, leaderAlive: false, groupAlive: true, ownsGroup: false))
    }
}

extension Review2TunnelTests {
    func testForwardChangesStopDeletedAndDisabledAndRestartChanged() {
        let a = PortForward(kind: .local, listenPort: 9001, destinationHost: "db", destinationPort: 5432, quickToggle: true)
        let b = PortForward(kind: .local, listenPort: 9002, destinationHost: "db", destinationPort: 5432, quickToggle: true)
        let c = PortForward(kind: .local, listenPort: 9003, destinationHost: "db", destinationPort: 5432, quickToggle: true)
        let old = SSHHost(label: "test", hostname: "server", portForwards: [a, b, c])
        var new = old
        var disabled = b
        disabled.quickToggle = false
        var changed = c
        changed.destinationHost = "new-db"
        new.portForwards = [disabled, changed]
        let changes = TunnelConfigurationChanges.between(old, new)
        XCTAssertEqual(changes.stop, [a.id, b.id])
        XCTAssertEqual(changes.restart, [c.id])
        XCTAssertEqual(TunnelConfigurationChanges.between(old, old).restart, [])
    }

    func testForwardChangesIncludeEndpointAndListenChangesButIgnoreLabels() {
        let f = PortForward(kind: .local, listenPort: 9001, destinationHost: "db", destinationPort: 5432, quickToggle: true)
        let old = SSHHost(label: "test", hostname: "server", portForwards: [f])
        var new = old
        new.label = "renamed"
        XCTAssertEqual(TunnelConfigurationChanges.between(old, new).restart, [])
        new.portForwards[0].bindAddress = "::1"
        XCTAssertEqual(TunnelConfigurationChanges.between(old, new).restart, [f.id])
        new = old
        new.portForwards[0].listenPort = 9002
        XCTAssertEqual(TunnelConfigurationChanges.between(old, new).restart, [f.id])
        new = old
        new.hostname = "new-server"
        XCTAssertEqual(TunnelConfigurationChanges.between(old, new).restart, [f.id])
    }
}

extension Review2TunnelTests {
    func testStoppedAndOrphanCleanupEscalatesWithBoundedRetries() {
        let old = TunnelProcessIdentity(pid: 123, startedAt: Date(timeIntervalSince1970: 10), executablePath: "/bin/ssh")
        var cleanup = TunnelCleanupPlan(identity: old)
        let replacement = TunnelProcessIdentity(pid: 124, startedAt: Date(timeIntervalSince1970: 20), executablePath: "/bin/ssh")
        XCTAssertNotEqual(old, replacement)
        // A replacement session has no effect on the captured old process's escalation.
        for _ in 0..<5 {
            XCTAssertEqual(
                cleanup.advance(
                    observedStart: old.startedAt, observedPath: old.executablePath,
                    leaderAlive: true, groupAlive: true, ownsGroup: true), .retry(kill: true))
        }
        XCTAssertEqual(
            cleanup.advance(
                observedStart: old.startedAt, observedPath: old.executablePath,
                leaderAlive: true, groupAlive: true, ownsGroup: true), .retain)
        XCTAssertEqual(
            cleanup.advance(
                observedStart: nil, observedPath: nil, leaderAlive: false, groupAlive: false, ownsGroup: true), .finished)
    }

    func testCleanupNeverKillsAReusedPIDButStillChecksForGroupExit() {
        let old = TunnelProcessIdentity(pid: 123, startedAt: Date(timeIntervalSince1970: 10), executablePath: "/bin/ssh")
        var cleanup = TunnelCleanupPlan(identity: old)
        XCTAssertEqual(
            cleanup.advance(
                observedStart: Date(timeIntervalSince1970: 20), observedPath: "/bin/ssh",
                leaderAlive: true, groupAlive: true, ownsGroup: true), .retry(kill: false))
        XCTAssertEqual(
            cleanup.advance(
                observedStart: nil, observedPath: nil, leaderAlive: false, groupAlive: true, ownsGroup: true), .retry(kill: true))
    }
}
