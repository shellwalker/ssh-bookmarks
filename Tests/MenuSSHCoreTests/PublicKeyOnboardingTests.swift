import XCTest

@testable import MenuSSHCore

final class PublicKeyOnboardingTests: XCTestCase {
    func testPrefersEd25519ThenFallsBackAlphabetically() {
        let names = ["id_rsa.pub", "id_ed25519.pub", "work.pub", ".hidden.pub", "not-a-key"]
        let found = PublicKeyOnboarding.candidates(fileNames: names, directory: "/Users/a/.ssh")
        XCTAssertEqual(found.map(\.fileName), ["id_ed25519.pub", "id_rsa.pub", "work.pub"])
        XCTAssertEqual(PublicKeyOnboarding.preferred(found)?.privatePath, "/Users/a/.ssh/id_ed25519")
        let without = PublicKeyOnboarding.candidates(fileNames: ["zeta.pub", "alpha.pub"], directory: "/tmp/ssh")
        XCTAssertEqual(PublicKeyOnboarding.preferred(without)?.fileName, "alpha.pub")
    }

    func testKeygenCommandAndCopyIDArguments() {
        XCTAssertEqual(PublicKeyOnboarding.keygenCommand, "ssh-keygen -t ed25519")
        let args = PublicKeyOnboarding.copyIDArguments(
            publicPath: "/Users/a/.ssh/id_ed25519.pub", username: "alice", hostname: "example.com", port: 2201)
        XCTAssertEqual(
            args, ["ssh-copy-id", "-i", "/Users/a/.ssh/id_ed25519.pub", "-p", "2201", "alice@example.com"])
        XCTAssertNil(
            PublicKeyOnboarding.copyIDArguments(
                publicPath: "/tmp/k.pub", username: "alice", hostname: "-oProxyCommand=evil", port: nil))
        XCTAssertNil(
            PublicKeyOnboarding.copyIDArguments(
                publicPath: "/tmp/k.pub", username: "bad name", hostname: "example.com", port: nil))
        let line = ShellQuoting.join(args ?? [])
        XCTAssertFalse(line.contains("password"))
        XCTAssertFalse(line.contains("hunter2"))
    }

    func testCopyIDBracketsIPv6() {
        let args = PublicKeyOnboarding.copyIDArguments(publicPath: "/tmp/id_ed25519.pub", username: "alice", hostname: "fe80::1", port: nil)
        XCTAssertEqual(args?.last, "alice@[fe80::1]")
    }
}
