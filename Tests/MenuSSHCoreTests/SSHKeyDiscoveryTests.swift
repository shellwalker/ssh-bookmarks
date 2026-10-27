import XCTest

@testable import MenuSSHCore

final class SSHKeyDiscoveryTests: XCTestCase {
    func testPublicKeyMapsToPrivateAndParsesTypeAndComment() {
        XCTAssertEqual(SSHKeyDiscovery.privatePath(forPublicOrPrivate: "/Users/a/.ssh/id_ed25519.pub"), "/Users/a/.ssh/id_ed25519")
        XCTAssertEqual(SSHKeyDiscovery.privatePath(forPublicOrPrivate: "/Users/a/.ssh/id_ed25519"), "/Users/a/.ssh/id_ed25519")
        let parsed = SSHKeyDiscovery.parsePublicKey(
            "# comment\n\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake alice@mac extra\n"
        )
        XCTAssertEqual(parsed?.type, "ssh-ed25519")
        XCTAssertEqual(parsed?.comment, "alice@mac extra")
        XCTAssertEqual(
            SSHKeyDiscovery.parsePublicKey("sk-ssh-ed25519@openssh.com AAAA fido")?.type, "sk-ssh-ed25519@openssh.com")
        XCTAssertNil(SSHKeyDiscovery.parsePublicKey("not-a-key"))
    }

    func testPairsIgnoreNonKeysAndRequireThePrivateFile() {
        let names = [
            "id_ed25519", "id_ed25519.pub", "id_rsa.pub", "known_hosts", "known_hosts.old", "config", "authorized_keys",
            "config.pub", "authorized_keys.pub", ".hidden.pub",
        ]
        let pubs = [
            "/tmp/ssh/id_ed25519.pub": "ssh-ed25519 AAAAC3 menush@ci",
            "/tmp/ssh/config.pub": "ssh-ed25519 AAAA no",
        ]
        let pairs = SSHKeyDiscovery.pairs(
            fileNames: names,
            directory: "/tmp/ssh",
            readFile: { pubs[$0] },
            privateKeyExists: { $0 == "/tmp/ssh/id_ed25519" }
        )
        XCTAssertEqual(pairs.map(\.fileName), ["id_ed25519"])
        XCTAssertEqual(pairs.first?.keyType, "ssh-ed25519")
        XCTAssertEqual(pairs.first?.comment, "menush@ci")
        XCTAssertEqual(pairs.first?.pickerLabel, "id_ed25519 — ssh-ed25519 — menush@ci")
    }

    func testInspectSwitchesPubAndWarnsOnMissingOrOpenPermissions() {
        let missing = SSHKeyDiscovery.inspect(
            path: "~/.ssh/id_ed25519.pub", homeDirectory: "/Users/a", privateKeyExists: { _ in false }, privateKeyMode: { _ in nil })
        XCTAssertEqual(missing.path, "~/.ssh/id_ed25519")
        XCTAssertEqual(missing.notices, [.switchedFromPublicKey, .missingPrivateKey])

        let open = SSHKeyDiscovery.inspect(
            path: "/tmp/id_rsa",
            homeDirectory: "/Users/a",
            privateKeyExists: { $0 == "/tmp/id_rsa" },
            privateKeyMode: { _ in 0o644 }
        )
        XCTAssertEqual(open.notices, [.permissionsTooOpen])
        XCTAssertFalse(SSHKeyDiscovery.privateKeyPermissionsTooOpen(0o600))
        XCTAssertFalse(SSHKeyDiscovery.privateKeyPermissionsTooOpen(0o400))
        XCTAssertTrue(SSHKeyDiscovery.privateKeyPermissionsTooOpen(0o640))
    }
}
