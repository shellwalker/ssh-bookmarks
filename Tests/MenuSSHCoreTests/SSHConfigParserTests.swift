import XCTest

@testable import MenuSSHCore

final class SSHConfigParserTests: XCTestCase {
    func testParse() {
        let text = """
            # comment
            Host *
                ServerAliveInterval 60

            Host prod-api api
                HostName 10.0.0.15
                User deploy
                Port 2201
                IdentityFile ~/.ssh/prod
                Port 9999

            Host=bastion
                HostName=jump.example.com
                ProxyJump "edge"

            Match host foo
                User ignored

            Host *.internal !secret
                User nope
            """
        let entries = SSHConfigParser.parse(text)
        XCTAssertEqual(entries.map(\.alias), ["prod-api", "api", "bastion"])
        XCTAssertEqual(
            entries[0], SSHConfigEntry(alias: "prod-api", hostName: "10.0.0.15", user: "deploy", port: 2201, identityFile: "~/.ssh/prod"))
        XCTAssertEqual(entries[2].hostName, "jump.example.com")
        XCTAssertEqual(entries[2].proxyJump, "edge")

        let hosts = SSHConfigParser.makeHosts(from: entries)
        XCTAssertEqual(hosts[0].hostname, "prod-api")
        XCTAssertNil(hosts[0].port)
        XCTAssertEqual(hosts[0].tags, ["ssh-config"])
    }
}
