import XCTest

@testable import MenuSSHCore

/// 本机临时 sshd 上的真实连接。未设置 MENUSH_INTEGRATION 时跳过，避免普通 `swift test` 依赖 sshd。
final class SSHIntegrationTests: XCTestCase {
    private var children: [Process] = []
    private var logs: [String: URL] = [:]

    override func tearDown() {
        for process in children where process.isRunning {
            process.terminate()
        }
        children.removeAll()
        super.tearDown()
    }

    func testPublicKeyLogin() throws {
        let fixture = try loadFixture()
        let (status, output) = try runSSH(try pubkeyArgv(fixture, port: fixture.portB, remote: ["echo", "pubkey-ok"]), fixture: fixture)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("pubkey-ok"), output)
    }

    func testPasswordLoginUsesAskpass() throws {
        let fixture = try loadFixture()
        var host = endpoint(fixture, port: fixture.portB, publicKey: false)
        host.extraOptions.append(SSHOption(key: "PubkeyAuthentication", value: "no"))
        host.extraOptions.append(SSHOption(key: "NumberOfPasswordPrompts", value: "1"))
        let argv = try SSHCommandBuilder().argv(for: host) + ["echo", "password-ok"]
        var env = cleanEnvironment(fixture)
        env["SSH_ASKPASS"] = fixture.askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = "menush-ci"
        let (status, output) = try run(argv, env: env, timeout: 20)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("password-ok"), output)
        XCTAssertFalse(output.contains("menush-ci-"), "askpass output must not echo the password")
    }

    func testProxyJumpBetweenTwoServers() throws {
        let fixture = try loadFixture()
        var host = endpoint(fixture, port: fixture.portB, publicKey: true)
        host.jumpHost = "\(fixture.user)@127.0.0.1:\(fixture.portA)"
        let argv = try SSHCommandBuilder().argv(for: host) + ["echo", "jump-ok"]
        let (status, output) = try runSSH(argv, fixture: fixture)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("jump-ok"), output)
    }

    func testLocalRemoteAndDynamicForwards() throws {
        let fixture = try loadFixture()
        let httpPort = 18081
        let localPort = 19081
        let remotePort = 19181
        let socksPort = 11081
        var httpEnv = cleanEnvironment(fixture)
        httpEnv["PYTHONUNBUFFERED"] = "1"
        let server = try startProcess(
            [try pythonPath(), "-m", "http.server", "\(httpPort)", "--bind", "127.0.0.1"],
            env: httpEnv,
            logName: "http"
        )
        children.append(server)
        Thread.sleep(forTimeInterval: 0.8)

        let localForward = PortForward(
            kind: .local, listenPort: localPort, destinationHost: "127.0.0.1", destinationPort: httpPort)
        let local = try backgroundSSH(try forwardArgv(fixture, forward: localForward), fixture: fixture, logName: "local")
        let remote = try backgroundSSH(
            try forwardArgv(
                fixture,
                forward: PortForward(kind: .remote, listenPort: remotePort, destinationHost: "127.0.0.1", destinationPort: httpPort)
            ),
            fixture: fixture,
            logName: "remote"
        )
        let dynamic = try backgroundSSH(
            try forwardArgv(fixture, forward: PortForward(kind: .dynamic, bindAddress: "127.0.0.1", listenPort: socksPort)),
            fixture: fixture,
            logName: "dynamic"
        )
        let localCurl = try retryCurl(
            ["/usr/bin/curl", "-sS", "--max-time", "5", "http://127.0.0.1:\(localPort)/"], fixture: fixture)
        XCTAssertTrue(localCurl.contains("Directory listing"), localCurl + logTail("local") + logTail("http"))
        let remoteCurl = try retryCurl(
            ["/usr/bin/curl", "-sS", "--max-time", "5", "http://127.0.0.1:\(remotePort)/"], fixture: fixture)
        XCTAssertTrue(remoteCurl.contains("Directory listing"), remoteCurl + logTail("remote"))
        let socks = try retryCurl(
            [
                "/usr/bin/curl", "-sS", "--max-time", "5", "--socks5-hostname", "127.0.0.1:\(socksPort)",
                "http://127.0.0.1:\(httpPort)/",
            ],
            fixture: fixture
        )
        XCTAssertTrue(socks.contains("Directory listing"), socks + logTail("dynamic"))
        _ = local
        _ = remote
        _ = dynamic
    }

    func testStartupCommandRunsInTheSession() throws {
        let fixture = try loadFixture()
        var host = endpoint(fixture, port: fixture.portB, publicKey: true)
        host.startupCommand = "echo MENUSH_STARTUP_OK"
        let argv = try SSHCommandBuilder().argv(for: host)
        let payload = try JSONSerialization.data(withJSONObject: argv)
        let encoded = String(decoding: payload, as: UTF8.self)
        let script = """
            import json, os, pty, select, time, sys
            argv = json.loads(sys.argv[1])
            startup = sys.argv[2]
            pid, fd = pty.fork()
            if pid == 0:
                os.execv(argv[0], argv)
            buf = b""
            sent = False
            start = time.time()
            while time.time() - start < 20:
                ready, _, _ = select.select([fd], [], [], 0.2)
                if ready:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    buf += chunk
                if not sent and time.time() - start > 2.5:
                    os.write(fd, (startup + "\\n").encode())
                    sent = True
                if b"MENUSH_STARTUP_OK" in buf:
                    os.write(fd, b"exit\\n")
                    break
            sys.stdout.buffer.write(buf)
            sys.exit(0 if b"MENUSH_STARTUP_OK" in buf else 1)
            """
        let url = URL(fileURLWithPath: fixture.home).appendingPathComponent("startup.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let (status, output) = try run(
            [try pythonPath(), url.path, encoded, host.startupCommand],
            env: cleanEnvironment(fixture),
            timeout: 25
        )
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("MENUSH_STARTUP_OK"), output)
    }

    func testForwardAgent() throws {
        let fixture = try loadFixture()
        let agent = try run(["/usr/bin/ssh-agent", "-s"], env: cleanEnvironment(fixture))
        XCTAssertEqual(agent.0, 0, agent.1)
        let sock = try value("SSH_AUTH_SOCK", in: agent.1)
        let pid = try value("SSH_AGENT_PID", in: agent.1)
        defer { _ = try? run(["/usr/bin/kill", pid], env: cleanEnvironment(fixture)) }
        var env = cleanEnvironment(fixture)
        env["SSH_AUTH_SOCK"] = sock
        env["SSH_AGENT_PID"] = pid
        let added = try run(["/usr/bin/ssh-add", fixture.key], env: env)
        XCTAssertEqual(added.0, 0, added.1)
        var host = endpoint(fixture, port: fixture.portB, publicKey: true)
        host.forwardAgent = true
        // ssh 会把远端参数用空格拼成一条命令。单独一个参数，避免远端 shell 把 -c 的脚本拆开。
        let argv = try SSHCommandBuilder().argv(for: host) + ["sh -c 'test -n \"${SSH_AUTH_SOCK}\" && echo agent-ok'"]
        let (status, output) = try run(argv, env: env, timeout: 20)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("agent-ok"), output)
    }

    func testIncludedSSHConfigImportsFieldsAndConnects() throws {
        let fixture = try loadFixture()
        let sshDir = URL(fileURLWithPath: fixture.home).appendingPathComponent(".ssh")
        let configDir = sshDir.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let included = """
            Host web
                User \(fixture.user)
                Port \(fixture.portB)
                IdentityFile \(fixture.key)
                ProxyJump \(fixture.user)@127.0.0.1:\(fixture.portA)
                HostName 127.0.0.1
            """
        try included.write(to: configDir.appendingPathComponent("web.conf"), atomically: true, encoding: .utf8)
        try "Include config.d/*.conf\n".write(to: sshDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let text = try String(contentsOf: sshDir.appendingPathComponent("config"))
        let entries = SSHConfigParser.parse(
            text,
            homeDirectory: fixture.home,
            readFile: { path in
                (try? String(contentsOfFile: path, encoding: .utf8))
            },
            listDirectory: { directory in
                (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            }
        )
        XCTAssertEqual(entries.map(\.alias), ["web"])
        let imported = try XCTUnwrap(SSHConfigParser.makeHosts(from: entries).first)
        XCTAssertEqual(imported.username, fixture.user)
        XCTAssertEqual(imported.port, fixture.portB)
        XCTAssertEqual(imported.identityFile, fixture.key)
        XCTAssertEqual(imported.authMethod, .publicKey)
        XCTAssertEqual(imported.jumpHost, "\(fixture.user)@127.0.0.1:\(fixture.portA)")
        XCTAssertEqual(imported.hostname, "web")
        var host = imported
        host.hostname = try XCTUnwrap(entries.first?.hostName)
        host.extraOptions = endpoint(fixture, port: fixture.portB, publicKey: true).extraOptions
        let argv = try SSHCommandBuilder().argv(for: host) + ["echo", "import-ok"]
        let (status, output) = try runSSH(argv, fixture: fixture)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("import-ok"), output)
    }

    // MARK: - Helpers

    private struct Fixture {
        var user: String
        var key: String
        var portA: Int
        var portB: Int
        var askpass: String
        var home: String
    }

    private func loadFixture() throws -> Fixture {
        let env = ProcessInfo.processInfo.environment
        guard env["MENUSH_INTEGRATION"] == "1" else {
            throw XCTSkip("Set MENUSH_INTEGRATION=1 after Scripts/ci_sshd_fixture.sh start")
        }
        func need(_ key: String) throws -> String {
            let value = env[key] ?? ""
            if value.isEmpty { throw IntegrationFailure("missing \(key)") }
            return value
        }
        return Fixture(
            user: try need("MENUSH_SSH_USER"),
            key: try need("MENUSH_SSH_KEY"),
            portA: Int(try need("MENUSH_SSH_PORT_A")) ?? 0,
            portB: Int(try need("MENUSH_SSH_PORT_B")) ?? 0,
            askpass: try need("MENUSH_SSH_ASKPASS"),
            home: try need("MENUSH_SSH_HOME")
        )
    }

    private func endpoint(_ fixture: Fixture, port: Int, publicKey: Bool) -> SSHHost {
        var options = [
            SSHOption(key: "StrictHostKeyChecking", value: "no"),
            SSHOption(key: "UserKnownHostsFile", value: "/dev/null"),
            SSHOption(key: "ConnectTimeout", value: "8"),
        ]
        if publicKey {
            options.append(SSHOption(key: "BatchMode", value: "yes"))
        }
        return SSHHost(
            label: "ci",
            hostname: "127.0.0.1",
            port: port,
            username: fixture.user,
            authMethod: publicKey ? .publicKey : .password,
            identityFile: publicKey ? fixture.key : nil,
            extraOptions: options
        )
    }

    private func pubkeyArgv(_ fixture: Fixture, port: Int, remote: [String]) throws -> [String] {
        try SSHCommandBuilder().argv(for: endpoint(fixture, port: port, publicKey: true)) + remote
    }

    private func forwardArgv(_ fixture: Fixture, forward: PortForward) throws -> [String] {
        var host = endpoint(fixture, port: fixture.portB, publicKey: true)
        host.portForwards = [forward]
        return try SSHCommandBuilder().argv(for: host) + ["sleep", "20"]
    }

    private func cleanEnvironment(_ fixture: Fixture) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": fixture.home,
            "LANG": "en_US.UTF-8",
        ]
    }

    private func runSSH(_ argv: [String], fixture: Fixture) throws -> (Int32, String) {
        try run(argv, env: cleanEnvironment(fixture), timeout: 20)
    }

    private func backgroundSSH(_ argv: [String], fixture: Fixture, logName: String) throws -> Process {
        let process = try startProcess(argv, env: cleanEnvironment(fixture), logName: logName)
        children.append(process)
        return process
    }

    private func startProcess(_ argv: [String], env: [String: String], logName: String) throws -> Process {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("\(logName).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logs[logName] = logURL
        let handle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    private func pythonPath() throws -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates =
            path.split(separator: ":").map { "\($0)/python3" } + [
                "/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3",
            ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw IntegrationFailure("python3 not found")
    }

    private func retryCurl(_ argv: [String], fixture: Fixture) throws -> String {
        var last = ""
        for _ in 0..<8 {
            let result = try run(argv, env: cleanEnvironment(fixture), timeout: 8)
            last = result.1
            if result.0 == 0, last.contains("Directory listing") { return last }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return last
    }

    private func logTail(_ name: String) -> String {
        guard let url = logs[name], let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return "\n[\(name)] \(text.suffix(500))"
    }

    private func run(_ argv: [String], env: [String: String], timeout: TimeInterval) throws -> (Int32, String) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("out.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            return (124, text + "\n(timeout)")
        }
        try handle.close()
        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, text)
    }

    private func value(_ name: String, in text: String) throws -> String {
        let pattern = "\(name)=([^;]+)"
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let expression = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: range))
        let piece = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
        XCTAssertFalse(piece.isEmpty)
        return piece
    }
}

private struct IntegrationFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// 同步文件在 macOS runner 上再走一遍：旧 schema 可读、合并后升到 v2、密码键不出现。
final class SyncSchemaIntegrationTests: XCTestCase {
    func testSchemaV1MergesToV2WithoutPasswordKeys() throws {
        guard ProcessInfo.processInfo.environment["MENUSH_INTEGRATION"] == "1" else {
            throw XCTSkip("Set MENUSH_INTEGRATION=1 to run the sync file check on the runner")
        }
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let legacy = """
            {"schemaVersion":1,"deviceId":"old","groups":[],"tombstones":[],
            "hosts":[{"id":"\(id.uuidString)","hostname":"h","label":"from-v1",
            "notes":"password stays out","updatedAt":"2026-01-01T00:00:00Z"}]}
            """
        let decoded = try SyncCodec.decode(Data(legacy.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.hosts.first?.forwardAgent, false)
        XCTAssertEqual(decoded.hosts.first?.startupCommand, "")
        var newer = SSHHost(
            id: id, label: "from-v2", hostname: "h", forwardAgent: true, startupCommand: "echo hi",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), updatedByDeviceId: "new-device")
        newer.notes = "password stays out"
        let local = SyncDocument(deviceId: "new-device", hosts: [newer])
        let merged = SyncMerger.merge(local: local, remote: decoded, now: Date(), writingDeviceId: "new-device")
        XCTAssertEqual(merged.document.hosts.first?.label, "from-v2")
        XCTAssertEqual(merged.document.hosts.first?.forwardAgent, true)
        let data = try SyncCodec.encode(merged.document)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, SyncDocument.currentSchemaVersion)
        let keys = SyncSecretScan.keys(in: try JSONSerialization.jsonObject(with: data))
        XCTAssertTrue(keys.contains("forwardagent"))
        XCTAssertTrue(keys.contains("startupcommand"))
        XCTAssertTrue(keys.isDisjoint(with: SyncSecretScan.forbiddenKeys))
        XCTAssertFalse(keys.contains("password"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("password stays out"))
    }
}
