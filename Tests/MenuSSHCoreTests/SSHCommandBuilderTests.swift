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

    func testCommandLineQuotesUnsafeValues() throws {
        let host = SSHHost(label: "q", hostname: "h", username: "deploy", authMethod: .publicKey, identityFile: "/Users/me/O'Brien Keys/id")
        let line = try builder.commandLine(for: host)
        XCTAssertEqual(line, "/usr/bin/ssh -l deploy -i '/Users/me/O'\\''Brien Keys/id' -o IdentitiesOnly=yes -- h")
    }
}
