import Foundation
import XCTest

@testable import SSHBookmarksCore

final class ReviewRegressionTests: XCTestCase {
    func testAskpassRejectsJumpAndUnknownPromptsWithoutConsumingToken() {
        let now = Date()
        let id = UUID()
        var store = AskpassTokenStore()
        let token = store.issue(hostID: id, username: "alice", hostname: "target", now: now, token: "bound")
        for prompt in ["alice@jump's password:", "bob@target's password:", "Password:", "Enter OTP:", "alice@target.evil's password:"] {
            XCTAssertNil(store.redeem(token, prompt: prompt, now: now), prompt)
            XCTAssertEqual(store.records.count, 1)
        }
        XCTAssertEqual(store.redeem(token, prompt: "alice@TARGET's password: ", now: now), id)
        XCTAssertNil(store.redeem(token, prompt: "alice@target's password:", now: now))
    }

    func testAskpassMatchesIPv6PortsAndExactUsername() {
        XCTAssertTrue(AskpassPrompt.matches("a@b@host's password:", username: "a@b", hostname: "host"))
        XCTAssertTrue(AskpassPrompt.matches("a@[::1]:2222's password:", username: "a", hostname: "::1"))
        XCTAssertTrue(AskpassPrompt.matches("a@::1's password:", username: "a", hostname: "::1"))
        XCTAssertTrue(AskpassPrompt.matches("a@host:2222's password:", username: "a", hostname: "host"))
        XCTAssertFalse(AskpassPrompt.matches("A@host's password:", username: "a", hostname: "host"))
        XCTAssertFalse(AskpassPrompt.matches("a@host's password:\n", username: "a", hostname: "host"))
        XCTAssertTrue(AskpassPrompt.matches("\(NSUserName())@host's password:", username: "", hostname: "host"))
        XCTAssertFalse(AskpassPrompt.matches("a@jump's password:", username: "", hostname: "host"))
        XCTAssertFalse(AskpassPrompt.matches("a@host's password:", username: "a", hostname: ""))
    }

    func testAskpassMatchesKeyboardInteractivePromptForTargetOnly() {
        XCTAssertTrue(AskpassPrompt.matches("(alice@target) Password: ", username: "alice", hostname: "target"))
        XCTAssertTrue(AskpassPrompt.matches("(\(NSUserName())@target) Password:", username: "", hostname: "TARGET"))
        XCTAssertFalse(AskpassPrompt.matches("(alice@jump) Password:", username: "alice", hostname: "target"))
        XCTAssertFalse(AskpassPrompt.matches("(alice@target) Verification code:", username: "alice", hostname: "target"))
        XCTAssertFalse(AskpassPrompt.matches("(alice@target) Password: hint", username: "alice", hostname: "target"))
    }

    func testLegacyUnboundTokenCannotAnswerPrompt() {
        let now = Date()
        var store = AskpassTokenStore(records: [AskpassTokenRecord(token: "old", hostID: UUID(), expiresAt: now.addingTimeInterval(60))])
        XCTAssertNil(store.redeem("old", prompt: "a@host's password:", now: now))
        XCTAssertEqual(store.records.count, 1)
    }

    func testFileMismatchLeavesTargetTokenUsable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tokens.json")
        let id = UUID()
        let now = Date()
        let token = try AskpassTokenFile.issue(hostID: id, username: "a", hostname: "target", fileURL: url, now: now)
        XCTAssertNil(try AskpassTokenFile.redeem(token: token, prompt: "a@jump's password:", fileURL: url, now: now))
        XCTAssertEqual(try AskpassTokenFile.redeem(token: token, prompt: "a@target's password:", fileURL: url, now: now), id)
    }

    func testDuplicateHostRegeneratesEveryForwardID() throws {
        let forwards = [
            PortForward(kind: .local, listenPort: 8080, destinationHost: "db", destinationPort: 80, quickToggle: true, reconnect: true),
            PortForward(kind: .dynamic, listenPort: 1080),
        ]
        let host = SSHHost(label: "a", hostname: "target", portForwards: forwards)
        var library = HostLibrary(hosts: [host])
        let copy = try XCTUnwrap(library.duplicateHost(id: host.id))
        XCTAssertNotEqual(copy.id, host.id)
        XCTAssertTrue(Set(copy.portForwards.map(\.id)).isDisjoint(with: Set(forwards.map(\.id))))
        XCTAssertEqual(Set(copy.portForwards.map(\.id)).count, forwards.count)
        for (original, duplicate) in zip(forwards, copy.portForwards) {
            var expected = original
            expected.id = duplicate.id
            XCTAssertEqual(expected, duplicate)
        }
        XCTAssertEqual(library.hosts.first, host)
    }

    func testTunnelForcesForegroundAndRejectsSupervisionOptionsOnlyForTunnels() throws {
        let forward = PortForward(kind: .local, listenPort: 8080, destinationHost: "db", destinationPort: 80)
        var host = SSHHost(label: "a", hostname: "target")
        let builder = SSHCommandBuilder()
        let args = try builder.tunnelArguments(for: host, forward: forward)
        XCTAssertTrue(args.contains("ForkAfterAuthentication=no"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("ControlPath=none"))
        for key in [
            "ForkAfterAuthentication", "ControlMaster", "ControlPath", "ControlPersist", "SessionType", "RemoteCommand", "RequestTTY",
            "ClearAllForwardings",
        ] {
            host.extraOptions = [SSHOption(key: key, value: "yes")]
            XCTAssertThrowsError(try builder.tunnelArguments(for: host, forward: forward), key)
            XCTAssertNoThrow(try builder.arguments(for: host), key)
        }
    }

    func testIPv6ForwardAddressesAreBracketed() throws {
        let builder = SSHCommandBuilder()
        for kind in [PortForward.Kind.local, .remote] {
            let forward = PortForward(kind: kind, bindAddress: "::1", listenPort: 8080, destinationHost: "fe80::1%lo0", destinationPort: 80)
            let host = SSHHost(label: "a", hostname: "target", portForwards: [forward])
            XCTAssertTrue(try builder.arguments(for: host).contains("[::1]:8080:[fe80::1%lo0]:80"))
        }
        let dynamic = PortForward(kind: .dynamic, bindAddress: "::1", listenPort: 1080)
        XCTAssertTrue(try builder.arguments(for: SSHHost(label: "a", hostname: "target", portForwards: [dynamic])).contains("[::1]:1080"))
    }

    func testInvalidProbePortsDoNotTrap() {
        for port in [-1, Int.min, 65536, Int.max] {
            XCTAssertNil(LocalPortProbe.hold(port: port))
            XCTAssertFalse(LocalPortProbe.isFree(host: "::1", port: port))
        }
    }

    func testIPv6ProbeDetectsHeldPort() throws {
        guard let held = LocalPortProbe.hold(host: "::1") else { throw XCTSkip("IPv6 loopback unavailable") }
        defer { held.release() }
        XCTAssertGreaterThan(held.port, 0)
        XCTAssertFalse(LocalPortProbe.isFree(host: "::1", port: held.port))
        held.release()
        XCTAssertTrue(LocalPortProbe.isFree(host: "::1", port: held.port))
    }

    func testConcurrentPortReleaseIsIdempotent() throws {
        let held = try XCTUnwrap(LocalPortProbe.hold())
        DispatchQueue.concurrentPerform(iterations: 100) { _ in held.release() }
        XCTAssertTrue(LocalPortProbe.isFree(port: held.port))
    }

    func testSearchToleratesDuplicateGroupIDs() {
        let group = HostGroup(name: "Production")
        var duplicate = group
        duplicate.name = "other"
        let host = SSHHost(label: "a", hostname: "target", groupID: group.id)
        XCTAssertEqual(HostLibrary(groups: [group, duplicate], hosts: [host]).hosts(matching: "production"), [host])
    }

    func testUndoDeletionPreservesLaterEditsAndBeatsTombstone() throws {
        let deleted = SSHHost(label: "deleted", hostname: "target")
        var edited = SSHHost(label: "before", hostname: "other")
        let before = HostLibrary(hosts: [deleted, edited])
        var library = before
        let deletionDate = Date(timeIntervalSince1970: 100)
        library.removeHost(id: deleted.id, now: deletionDate, deviceId: "remote")
        let undo = HostDeletionUndo(before: before, after: library)
        edited.label = "after"
        library.upsert(edited)
        let added = SSHHost(label: "new", hostname: "new")
        library.upsert(added)
        undo.restore(in: &library, now: deletionDate, deviceId: "local")
        XCTAssertTrue(library.hosts.contains(edited))
        XCTAssertTrue(library.hosts.contains(added))
        let restored = try XCTUnwrap(library.hosts.first { $0.id == deleted.id })
        XCTAssertGreaterThan(restored.updatedAt, deletionDate)
        XCTAssertEqual(restored.updatedByDeviceId, "local")
        XCTAssertTrue(library.tombstones.isEmpty)
    }

    func testUndoGroupDeletionPreservesEditedMembers() throws {
        let group = HostGroup(name: "g")
        let child = HostGroup(name: "child", parentID: group.id)
        let host = SSHHost(label: "a", hostname: "h", groupID: group.id)
        let before = HostLibrary(groups: [group, child], hosts: [host])
        var library = before
        library.removeGroup(id: group.id, deviceId: "d")
        let undo = HostDeletionUndo(before: before, after: library)
        library.hosts[0].label = "edited"
        undo.restore(in: &library, deviceId: "d")
        XCTAssertEqual(library.hosts[0].label, "edited")
        XCTAssertNil(library.hosts[0].groupID)
        XCTAssertEqual(library.groups.first { $0.id == child.id }?.parentID, group.id)
        XCTAssertTrue(library.groups.contains { $0.id == group.id })
    }

    func testManifestEscapesControlCharacters() throws {
        let value = "a\n\t\r\"\\\u{0001}b"
        let input = DiagnosticBundle.Input(version: value, build: "1", osVersion: value, sshPath: value, terminal: value, logText: "")
        let zip = DiagnosticBundle.makeZIP(input, redactor: DiagnosticRedactor(redactNames: false))
        // 首个 ZIP 本地头的固定长度 30，文件名之后紧跟不压缩的 manifest。
        let name = Data("manifest.json".utf8)
        let start = 30 + name.count
        let length = Int(zip[18]) | (Int(zip[19]) << 8) | (Int(zip[20]) << 16) | (Int(zip[21]) << 24)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: zip.subdata(in: start..<(start + length))) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, value)
        XCTAssertEqual(object["terminal"] as? String, value)
    }
    func testRetryUsesCurrentConfigurationAndHonorsDeletionAndSwitches() throws {
        let forward = PortForward(
            kind: .local, listenPort: 8080, destinationHost: "db", destinationPort: 80, quickToggle: true, reconnect: true)
        let host = SSHHost(label: "a", hostname: "old", portForwards: [forward])
        var library = HostLibrary(hosts: [host])
        library.hosts[0].hostname = "new"
        library.hosts[0].portForwards[0].destinationPort = 81
        let target = try XCTUnwrap(TunnelRetryTarget.current(in: library, hostID: host.id, forwardID: forward.id))
        XCTAssertEqual(target.host.hostname, "new")
        XCTAssertEqual(target.forward.destinationPort, 81)
        library.hosts[0].portForwards[0].reconnect = false
        XCTAssertNil(TunnelRetryTarget.current(in: library, hostID: host.id, forwardID: forward.id))
        library.hosts[0].portForwards[0].reconnect = true
        library.hosts[0].portForwards[0].quickToggle = false
        XCTAssertNil(TunnelRetryTarget.current(in: library, hostID: host.id, forwardID: forward.id))
        library.hosts[0].portForwards = []
        XCTAssertNil(TunnelRetryTarget.current(in: library, hostID: host.id, forwardID: forward.id))
        library.hosts = []
        XCTAssertNil(TunnelRetryTarget.current(in: library, hostID: host.id, forwardID: forward.id))
    }

    func testEightTunnelsCanRetryAfterOneExitReleasesCapacity() {
        let remaining = TunnelReducer.maxConcurrent - 1
        let step = TunnelReducer.onExit(kind: .timedOut, reconnect: true, failuresSoFar: 0, runningCount: remaining)
        XCTAssertTrue(step.spawn)
        XCTAssertEqual(step.retryAfter, 2)
    }

    func testConcurrentTokenIssuanceDoesNotLoseRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tokens.json")
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                _ = try AskpassTokenFile.issue(
                    hostID: id, username: "a", hostname: "target", fileURL: url, now: now, token: "token-\(index)")
            } catch {
                XCTFail("issue failed: \(error)")
            }
        }
        for index in 0..<20 {
            XCTAssertEqual(try AskpassTokenFile.redeem(token: "token-\(index)", prompt: "a@target's password:", fileURL: url, now: now), id)
        }
    }

}
