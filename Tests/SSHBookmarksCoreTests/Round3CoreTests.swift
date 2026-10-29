import XCTest

@testable import SSHBookmarksCore

final class Round3CoreTests: XCTestCase {
    func testOldPortForwardDecodesWithTogglesOffAndSchemaWritesV3() throws {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let json = """
            {"schemaVersion":2,"groups":[],"tombstones":[],"hosts":[{
              "id":"\(id.uuidString)","hostname":"h","label":"h",
              "portForwards":[{"id":"\(id.uuidString)","kind":"local","listenPort":8080,
                "destinationHost":"127.0.0.1","destinationPort":80}]
            }]}
            """
        let library = try HostFileStore.makeDecoder().decode(HostLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.schemaVersion, 2)
        XCTAssertEqual(library.hosts[0].portForwards[0].quickToggle, false)
        XCTAssertEqual(library.hosts[0].portForwards[0].reconnect, false)
        let encoded = try JSONSerialization.jsonObject(with: try HostFileStore.makeEncoder().encode(library)) as? [String: Any]
        XCTAssertEqual(encoded?["schemaVersion"] as? Int, HostLibrary.currentSchemaVersion)
        XCTAssertEqual(HostLibrary.currentSchemaVersion, 3)
        XCTAssertEqual(SyncDocument.currentSchemaVersion, 3)

        let sync = #"{"schemaVersion":2,"deviceId":"d","groups":[],"hosts":[],"tombstones":[]}"#
        let document = try SyncCodec.decode(Data(sync.utf8))
        XCTAssertEqual(document.schemaVersion, 2)
    }

    func testTunnelArgumentsForceHostKeyCheckAndLetTheUserOverrideKeepalive() throws {
        var host = SSHHost(
            label: "db",
            hostname: "db.internal",
            port: 22,
            username: "alice",
            authMethod: .publicKey,
            identityFile: "~/.ssh/id_ed25519",
            jumpHost: "bastion",
            extraOptions: [
                SSHOption(key: "StrictHostKeyChecking", value: "no"),
                SSHOption(key: "ServerAliveInterval", value: "5"),
                SSHOption(key: "UserKnownHostsFile", value: "/tmp/known"),
            ],
            forwardAgent: true
        )
        let forward = PortForward(kind: .local, listenPort: 15432, destinationHost: "10.0.0.8", destinationPort: 5432, quickToggle: true)
        let other = PortForward(kind: .remote, listenPort: 1, destinationHost: "h", destinationPort: 2)
        host.portForwards = [forward, other]
        let args = try SSHCommandBuilder(homeDirectory: "/Users/a").tunnelArguments(for: host, forward: forward)
        XCTAssertEqual(args.first, "/usr/bin/ssh")
        XCTAssertEqual(args[1], "-N")
        let yes = try XCTUnwrap(args.firstIndex(of: "StrictHostKeyChecking=yes"))
        let userNo = try XCTUnwrap(args.firstIndex(of: "StrictHostKeyChecking=no"))
        let userAlive = try XCTUnwrap(args.firstIndex(of: "ServerAliveInterval=5"))
        let defaultAlive = try XCTUnwrap(args.firstIndex(of: "ServerAliveInterval=15"))
        let exit = try XCTUnwrap(args.firstIndex(of: "ExitOnForwardFailure=yes"))
        XCTAssertLessThan(yes, userNo)
        XCTAssertLessThan(exit, userNo)
        XCTAssertLessThan(userAlive, defaultAlive)
        XCTAssertTrue(args.contains("ServerAliveCountMax=3"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("-L"))
        XCTAssertTrue(args.contains("15432:10.0.0.8:5432"))
        XCTAssertFalse(args.contains("-R"))
        XCTAssertEqual(args.suffix(2).map { $0 }, ["--", "db.internal"])
        XCTAssertTrue(args.contains("/Users/a/.ssh/id_ed25519"))
        XCTAssertTrue(args.contains("-J"))
        XCTAssertFalse(args.contains("StrictHostKeyChecking=no") && args.first == "no")
        XCTAssertFalse(args.contains("UserKnownHostsFile=/dev/null"))

        host.authMethod = AuthMethod.password
        host.identityFile = nil
        let passwordArgs = try SSHCommandBuilder().tunnelArguments(for: host, forward: forward)
        XCTAssertFalse(passwordArgs.contains("BatchMode=yes"))
        XCTAssertThrowsError(try SSHCommandBuilder().tunnelArguments(for: host, forward: other))
    }

    func testRunningTunnelsAreOmittedFromTheInteractiveHost() {
        let running = UUID()
        let host = SSHHost(
            label: "h",
            hostname: "h",
            portForwards: [
                PortForward(id: running, kind: .local, listenPort: 1, destinationHost: "d", destinationPort: 2),
                PortForward(kind: .local, listenPort: 3, destinationHost: "d", destinationPort: 4),
            ]
        )
        let stripped = SSHCommandBuilder.omittingRunningTunnels(host, runningForwardIDs: [running])
        XCTAssertEqual(stripped.portForwards.map(\.listenPort), [3])
    }

    func testRedactorRemovesSecretsAndOptionalNames() {
        let token = String(repeating: "ab", count: 32)
        let sample = """
            password=hunter2 SSHBOOKMARKS_ASKPASS_TOKEN=\(token)
            SSH_ASKPASS=/Users/alice/SSHBookmarks
            ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample alice@db.internal
            -----BEGIN OPENSSH PRIVATE KEY-----
            secretmaterial
            -----END OPENSSH PRIVATE KEY-----
            exit=255 port=15432 db.internal alice
            """
        let redacted = DiagnosticRedactor(redactNames: true, hostnames: ["db.internal"], usernames: ["alice"]).redact(sample)
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains(token))
        XCTAssertFalse(redacted.contains("SSHBOOKMARKS_ASKPASS_TOKEN=\(token)"))
        XCTAssertFalse(redacted.contains("/Users/alice/SSHBookmarks"))
        XCTAssertFalse(redacted.contains("AAAAC3NzaC1lZDI1NTE5AAAAIexample"))
        XCTAssertFalse(redacted.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertFalse(redacted.contains("secretmaterial"))
        XCTAssertFalse(redacted.contains("db.internal"))
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertTrue(redacted.contains("[key]"))
        XCTAssertTrue(redacted.contains("[private-key]"))
        XCTAssertTrue(redacted.contains("exit=255"))
        XCTAssertTrue(redacted.contains("port=15432"))

        let named = DiagnosticRedactor(redactNames: false, hostnames: ["db.internal"], usernames: ["alice"]).redact(sample)
        XCTAssertTrue(named.contains("db.internal"))
        XCTAssertFalse(named.contains("hunter2"))
    }

    func testDiagnosticZipAndPasteboardContainNoSecrets() {
        let token = String(repeating: "cd", count: 32)
        let input = DiagnosticBundle.Input(
            version: "0.1.0",
            build: "12",
            osVersion: "macOS 14",
            sshPath: "/usr/bin/ssh",
            terminal: "Terminal",
            logText: "password=hunter2 MENUSH_ASKPASS_TOKEN=\(token) exit=1 port=22 db.internal"
        )
        let redactor = DiagnosticRedactor(redactNames: true, hostnames: ["db.internal"], usernames: ["alice"])
        let zip = DiagnosticBundle.makeZIP(input, redactor: redactor)
        let text = String(decoding: zip, as: UTF8.self)
        XCTAssertTrue(text.contains("manifest.json"))
        XCTAssertTrue(text.contains("diagnostics.log"))
        XCTAssertTrue(text.contains("exit=1"))
        XCTAssertTrue(text.contains("port=22"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains(token))
        XCTAssertFalse(text.contains("db.internal"))
        let pasted = DiagnosticBundle.pasteboardText(input, redactor: redactor)
        XCTAssertFalse(pasted.contains("hunter2"))
        XCTAssertFalse(pasted.contains(token))
        XCTAssertTrue(pasted.contains("0.1.0"))
    }

    func testRetentionDropsOldFilesAndCapsCount() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let old = DiagnosticFileSnapshot(name: "diagnostics.log.2", byteCount: 10, modifiedAt: now.addingTimeInterval(-(8 * 24 * 60 * 60)))
        let current = DiagnosticFileSnapshot(
            name: DiagnosticRetention.currentName, byteCount: DiagnosticRetention.perFileBytes, modifiedAt: now)
        var files = [current, old]
        for index in 1...3 {
            files.append(DiagnosticFileSnapshot(name: "diagnostics.log.\(index)", byteCount: 10, modifiedAt: now))
        }
        let plan = DiagnosticRetention.plan(files: files, appending: 1, now: now)
        XCTAssertTrue(plan.rotate)
        XCTAssertTrue(plan.delete.contains("diagnostics.log.2"))
        XCTAssertEqual(DiagnosticRetention.maxFiles, 5)
        XCTAssertEqual(TunnelReducer.backoff(afterFailure: 1), 2)
        XCTAssertEqual(TunnelReducer.backoff(afterFailure: 5), 30)
        XCTAssertEqual(TunnelReducer.backoff(afterFailure: 9), 30)
    }

    func testTunnelReducerRetriesOnlyRecoverableFailures() {
        let started = TunnelReducer.onStart(runningCount: 0, portBusy: false)
        XCTAssertTrue(started.spawn)
        XCTAssertFalse(TunnelReducer.onStart(runningCount: 0, portBusy: true).spawn)
        XCTAssertFalse(TunnelReducer.onStart(runningCount: 8, portBusy: false).spawn)
        let stop = TunnelReducer.onUserStop()
        XCTAssertTrue(stop.stop)
        XCTAssertNil(stop.retryAfter)

        let hostKey = TunnelReducer.onExit(kind: .hostKeyChanged, reconnect: true, failuresSoFar: 0, runningCount: 1)
        XCTAssertFalse(hostKey.spawn)
        XCTAssertEqual(hostKey.phase, .failed(.hostKeyChanged))

        let first = TunnelReducer.onExit(kind: .timedOut, reconnect: true, failuresSoFar: 0, runningCount: 1)
        XCTAssertEqual(first.retryAfter, 2)
        XCTAssertTrue(first.spawn)
        let fifth = TunnelReducer.onExit(kind: .other, reconnect: true, failuresSoFar: 4, runningCount: 1)
        XCTAssertEqual(fifth.retryAfter, 30)
        let sixth = TunnelReducer.onExit(kind: .other, reconnect: true, failuresSoFar: 5, runningCount: 1)
        XCTAssertFalse(sixth.spawn)
        XCTAssertNil(sixth.retryAfter)
        let off = TunnelReducer.onExit(kind: .jumpFailed, reconnect: false, failuresSoFar: 0, runningCount: 0)
        XCTAssertFalse(off.spawn)
    }

    func testFailureClassifierAndOrphans() {
        XCTAssertEqual(TunnelFailureClassifier.classify(stderr: "REMOTE HOST IDENTIFICATION HAS CHANGED"), .hostKeyChanged)
        XCTAssertEqual(TunnelFailureClassifier.classify(stderr: "Host key verification failed."), .hostKeyNew)
        XCTAssertEqual(TunnelFailureClassifier.classify(stderr: "bind: Address already in use"), .portInUse)
        XCTAssertEqual(TunnelFailureClassifier.classify(stderr: "channel 0: open failed"), .other)
        XCTAssertEqual(TunnelOrphanDecision.decide(processAlive: true, startTimeMatches: true, executableMatches: true), .terminate)
        XCTAssertEqual(TunnelOrphanDecision.decide(processAlive: true, startTimeMatches: false, executableMatches: true), .forget)
        XCTAssertEqual(TunnelOrphanDecision.decide(processAlive: false, startTimeMatches: true, executableMatches: true), .forget)
    }

    func testLocalPortProbeNoticesAHeldPort() {
        guard let held = LocalPortProbe.hold() else {
            XCTFail("could not bind an ephemeral port")
            return
        }
        defer { held.release() }
        XCTAssertFalse(LocalPortProbe.isFree(port: held.port))
        held.release()
        XCTAssertTrue(LocalPortProbe.isFree(port: held.port))
    }
}
