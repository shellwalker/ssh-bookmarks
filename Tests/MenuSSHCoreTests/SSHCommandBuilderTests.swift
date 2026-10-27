import XCTest

@testable import MenuSSHCore

final class SSHCommandBuilderTests: XCTestCase {
    let builder = SSHCommandBuilder(sshPath: "/usr/bin/ssh", homeDirectory: "/Users/test")

    func testMinimalHostUsesSSHConfigDefaults() throws {
        let host = SSHHost(label: "web", hostname: "web.example.com")
        XCTAssertEqual(try builder.argv(for: host), ["/usr/bin/ssh", "--", "web.example.com"])
    }

    func testFullHost() throws {
        let host = SSHHost(
            label: "prod",
            hostname: "10.0.0.15",
            port: 2201,
            username: "deploy",
            authMethod: .publicKey,
            identityFile: "~/.ssh/id_ed25519",
            jumpHost: "bastion@jump.example.com:22",
            portForwards: [
                PortForward(kind: .local, listenPort: 5432, destinationHost: "127.0.0.1", destinationPort: 5432),
                PortForward(kind: .dynamic, bindAddress: "127.0.0.1", listenPort: 1080),
            ],
            extraOptions: [SSHOption(key: "ServerAliveInterval", value: "30")]
        )
        XCTAssertEqual(
            try builder.arguments(for: host),
            [
                "-l", "deploy",
                "-p", "2201",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "IdentitiesOnly=yes",
                "-J", "bastion@jump.example.com:22",
                "-L", "5432:127.0.0.1:5432",
                "-D", "127.0.0.1:1080",
                "-o", "ServerAliveInterval=30",
                "--", "10.0.0.15",
            ])
    }

    func testIdentityFileIgnoredUnlessPublicKeyAuth() throws {
        let host = SSHHost(label: "a", hostname: "a", authMethod: .automatic, identityFile: "~/.ssh/k")
        XCTAssertEqual(try builder.arguments(for: host), ["--", "a"])
    }

    func testRejectsOptionInjectionInHostname() {
        let host = SSHHost(label: "evil", hostname: "-oProxyCommand=touch /tmp/pwned")
        XCTAssertThrowsError(try builder.argv(for: host))
    }

    func testRejectsShellMetacharactersInHostname() {
        for bad in ["a;rm -rf ~", "a$(id)", "a`id`", "a b", "a\nid", "a|b", "a&b"] {
            XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: bad)), bad)
        }
    }

    func testRejectsControlCharactersEverywhere() {
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", username: "root\nid")))
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", authMethod: .publicKey, identityFile: "/k\r")))
        XCTAssertThrowsError(
            try builder.argv(for: SSHHost(label: "x", hostname: "h", extraOptions: [SSHOption(key: "User", value: "a\nb")])))
    }

    func testRejectsLeadingDashUsernameAndJump() {
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", username: "-oFoo")))
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", jumpHost: "-oProxyCommand=x")))
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", jumpHost: "a,,b")))
    }

    func testRejectsBadPortAndOptionKey() {
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", port: 0)))
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", port: 70000)))
        XCTAssertThrowsError(
            try builder.argv(for: SSHHost(label: "x", hostname: "h", extraOptions: [SSHOption(key: "Bad Key", value: "1")])))
    }

    func testIPv6Hostname() throws {
        XCTAssertEqual(try builder.arguments(for: SSHHost(label: "v6", hostname: "fe80::1%en0")), ["--", "fe80::1%en0"])
    }

    func testForwardAgentPrecedesExtraOptions() throws {
        var host = SSHHost(
            label: "a",
            hostname: "h",
            extraOptions: [SSHOption(key: "ForwardAgent", value: "no")],
            forwardAgent: true
        )
        let args = try builder.arguments(for: host)
        let enabled = try XCTUnwrap(args.firstIndex(of: "ForwardAgent=yes"))
        let overridden = try XCTUnwrap(args.firstIndex(of: "ForwardAgent=no"))
        XCTAssertLessThan(enabled, overridden)
        host.forwardAgent = false
        XCTAssertFalse(try builder.arguments(for: host).contains("ForwardAgent=yes"))
    }

    func testRemoteForward() throws {
        let host = SSHHost(
            label: "a",
            hostname: "h",
            portForwards: [
                PortForward(kind: .remote, bindAddress: "127.0.0.1", listenPort: 9000, destinationHost: "10.0.0.2", destinationPort: 80)
            ]
        )
        XCTAssertEqual(try builder.arguments(for: host), ["-R", "127.0.0.1:9000:10.0.0.2:80", "--", "h"])
    }

    func testStartupCommandWhitelist() throws {
        XCTAssertNil(try SSHCommandBuilder.startupCommand("   "))
        XCTAssertEqual(try SSHCommandBuilder.startupCommand(" cd /app && tmux attach "), "cd /app && tmux attach")
        XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", startupCommand: "id\nwhoami")))
        XCTAssertThrowsError(try SSHCommandBuilder.startupCommand(String(repeating: "a", count: 501)))
        let host = SSHHost(label: "x", hostname: "h", startupCommand: "cd /app && tmux attach")
        XCTAssertEqual(try builder.arguments(for: host), ["--", "h"])
    }

    func testJumpHostSpecification() {
        let host = SSHHost(label: "edge", hostname: "edge.example", port: 22, username: "deploy")
        XCTAssertEqual(JumpHostSpec.specification(for: host), "deploy@edge.example:22")
        let v6 = SSHHost(label: "v6", hostname: "fe80::1%en0", username: "root")
        XCTAssertEqual(JumpHostSpec.specification(for: v6), "root@[fe80::1%en0]")
        XCTAssertNil(JumpHostSpec.specification(for: SSHHost(label: "bad", hostname: "-oProxyCommand=x")))
        XCTAssertNil(JumpHostSpec.specification(for: SSHHost(label: "bad", hostname: "h", username: "a b")))
    }

    func testCommandLineQuotesUnsafeValues() throws {
        let host = SSHHost(label: "q", hostname: "h", username: "deploy", authMethod: .publicKey, identityFile: "/Users/me/O'Brien Keys/id")
        let line = try builder.commandLine(for: host)
        XCTAssertEqual(line, "/usr/bin/ssh -l deploy -i '/Users/me/O'\\''Brien Keys/id' -o IdentitiesOnly=yes -- h")
    }
}
