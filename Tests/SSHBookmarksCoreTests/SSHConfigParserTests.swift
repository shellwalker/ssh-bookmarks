import XCTest

@testable import SSHBookmarksCore

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
        XCTAssertEqual(hosts[0].port, 2201)
        XCTAssertEqual(hosts[0].username, "deploy")
        XCTAssertEqual(hosts[0].identityFile, "~/.ssh/prod")
        XCTAssertEqual(hosts[0].authMethod, .publicKey)
        XCTAssertEqual(hosts[0].notes, "HostName 10.0.0.15")
        XCTAssertEqual(hosts[0].tags, ["ssh-config"])
        XCTAssertEqual(hosts[2].jumpHost, "edge")
        XCTAssertEqual(hosts[2].notes, "HostName jump.example.com")
        XCTAssertEqual(hosts[2].authMethod, .automatic)
    }

    func testIncludeFillsFieldsAndSkipsCycles() {
        let home = "/Users/me"
        let files = [
            "/Users/me/.ssh/config.d/notes.txt": "Host notes\n    User n\n",
            "/Users/me/.ssh/config.d/web.conf": """
                Host web
                    User alice
                    Port 2222
                    IdentityFile ~/.ssh/id_ed25519
                    ProxyJump user@bastion:22
                    HostName 10.1.1.1
                """,
            "/Users/me/.ssh/config.d/.hidden": "Host hidden\n    User nope\n",
            "/Users/me/.ssh/loop.conf": """
                Include loop.conf
                Host looped
                    User bob
                Host bad
                    User -root
                    IdentityFile -secret
                    Port 99999
                    ProxyJump -oProxyCommand=x
                """,
        ]
        let text = """
            Include config.d/*
            Include loop.conf
            Match host x
                Include loop.conf
            """
        let entries = SSHConfigParser.parse(
            text,
            homeDirectory: home,
            readFile: { files[$0] },
            listDirectory: { directory in
                directory == "/Users/me/.ssh/config.d" ? ["web.conf", ".hidden", "notes.txt"] : []
            }
        )
        XCTAssertEqual(entries.map(\.alias), ["notes", "web", "looped", "bad"])
        let hosts = SSHConfigParser.makeHosts(from: entries)
        XCTAssertEqual(hosts[1].hostname, "web")
        XCTAssertEqual(hosts[1].username, "alice")
        XCTAssertEqual(hosts[1].port, 2222)
        XCTAssertEqual(hosts[1].identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(hosts[1].authMethod, .publicKey)
        XCTAssertEqual(hosts[1].jumpHost, "user@bastion:22")
        XCTAssertEqual(hosts[1].notes, "HostName 10.1.1.1")
        XCTAssertEqual(hosts[2].username, "bob")
        XCTAssertEqual(hosts[3].username, "")
        XCTAssertNil(hosts[3].identityFile)
        XCTAssertNil(hosts[3].port)
        XCTAssertNil(hosts[3].jumpHost)
        XCTAssertFalse(entries.contains { $0.alias == "hidden" })
        XCTAssertFalse(SSHConfigParser.globMatch(pattern: "*", name: ".hidden"))
        XCTAssertTrue(SSHConfigParser.globMatch(pattern: "*.conf", name: "web.conf"))
        XCTAssertTrue(SSHConfigParser.globMatch(pattern: ".?*", name: ".hidden"))
    }

    func testIncludeInsideHostAppliesKeywords() {
        let files = ["/Users/me/.ssh/snippet": "User carol\n"]
        let entries = SSHConfigParser.parse(
            "Host app\n    Include snippet\n",
            homeDirectory: "/Users/me",
            readFile: { files[$0] },
            listDirectory: { _ in [] }
        )
        XCTAssertEqual(entries.map(\.alias), ["app"])
        XCTAssertEqual(entries.first?.user, "carol")
    }

    func testPlanImportSkipsDuplicatesAndKeepsHostNameInNotes() {
        let entries = SSHConfigParser.parse(
            """
            Host ci-alias
                HostName 10.1.0.8
                User ci
            Host again
                HostName 10.0.0.2
            Host ci-alias
                HostName 10.9.9.9
            """
        )
        let plan = SSHConfigParser.planImport(entries: entries, existingHostnames: ["again", "Other"])
        XCTAssertEqual(plan.skippedDuplicates, 2)
        XCTAssertEqual(plan.hosts.map(\.hostname), ["ci-alias"])
        XCTAssertEqual(plan.hosts.first?.label, "ci-alias")
        XCTAssertEqual(plan.hosts.first?.notes, "HostName 10.1.0.8")
        XCTAssertEqual(plan.hosts.first?.username, "ci")
    }
}
