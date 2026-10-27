import Foundation
import XCTest

@testable import SSHBookmarksCore

/// 命令注入相关的回归测试：校验白名单 + shell 转义 + AppleScript 转义三层防护。
final class InjectionTests: XCTestCase {
    let builder = SSHCommandBuilder(sshPath: "/usr/bin/ssh", homeDirectory: "/Users/test")

    /// 常见攻击载荷。
    static let payloads: [String] = [
        "a b",  // 空格
        "a'b",  // 单引号
        "a\"b",  // 双引号
        "a;id",  // 分号
        "a`id`",  // 反引号
        "a$(id)",  // 命令替换
        "${HOME}",  // 变量展开
        "a\nid",  // 换行
        "a\rid",  // 回车
        "a\tb",  // 制表符
        "a\0b",  // NUL
        "a|id",
        "a&id",
        "a>x",
        "a<x",
        "a*",
        "a?",
        "~root",
        "a\\b",  // 反斜杠
        "a#b",
        "a!b",
        "a(b)",
        "a{b,c}",
        "-oProxyCommand=id",
        "例子.com",  // Unicode（非 punycode）
        "ex；id",  // 全角分号
        "a\u{200B}b",  // 零宽空格
        "a\u{202E}b",  // 双向覆盖
        "😀",
        "",
    ]

    // MARK: - 白名单

    func testHostnameWhitelistRejectsAllPayloads() {
        for p in Self.payloads {
            XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: p)), "hostname \(p.debugDescription)")
        }
    }

    func testUsernameWhitelistRejectsAllPayloads() {
        for p in Self.payloads where !p.isEmpty {
            XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", username: p)), "username \(p.debugDescription)")
        }
    }

    func testJumpHostRejectsPayloads() {
        for p in Self.payloads where !p.isEmpty {
            XCTAssertThrowsError(try builder.argv(for: SSHHost(label: "x", hostname: "h", jumpHost: p)), "jump \(p.debugDescription)")
            XCTAssertThrowsError(
                try builder.argv(for: SSHHost(label: "x", hostname: "h", jumpHost: "u@\(p)")), "jump host part \(p.debugDescription)")
        }
    }

    func testValidHostnamesAndUsernames() throws {
        for h in ["example.com", "xn--fsqu00a.xn--0zwm56d", "10.0.0.1", "fe80::1%en0", "::1", "my_alias", "web-01"] {
            XCTAssertNoThrow(try builder.argv(for: SSHHost(label: "x", hostname: h)), h)
        }
        for u in ["root", "deploy_bot", "first.last", "user@corp.example.com", "a-b", "u123"] {
            XCTAssertNoThrow(try builder.argv(for: SSHHost(label: "x", hostname: "h", username: u)), u)
        }
    }

    func testValidJumpSpecs() {
        for j in ["bastion", "u@bastion", "u@bastion:2222", "a,b@c:22", "[fe80::1]:22", "u@[::1]"] {
            XCTAssertTrue(SSHCommandBuilder.isValidJumpSpec(j), j)
        }
        for j in ["u@", "@h", "h:", "h:0", "h:99999", "h:22:33", "[::1", "[::1]x", "a,,b", ",a"] {
            XCTAssertFalse(SSHCommandBuilder.isValidJumpSpec(j), j)
        }
    }

    func testBlockedOptionKeys() {
        for key in ["ProxyCommand", "proxycommand", "LocalCommand", "PermitLocalCommand", "KnownHostsCommand", "Include", "Match"] {
            let host = SSHHost(label: "x", hostname: "h", extraOptions: [SSHOption(key: key, value: "id")])
            XCTAssertThrowsError(try builder.argv(for: host), key)
        }
        let ok = SSHHost(label: "x", hostname: "h", extraOptions: [SSHOption(key: "ServerAliveInterval", value: "30")])
        XCTAssertNoThrow(try builder.argv(for: ok))
    }

    func testSSHPathMustBeAbsolute() {
        XCTAssertThrowsError(try SSHCommandBuilder(sshPath: "ssh").argv(for: SSHHost(label: "x", hostname: "h")))
        XCTAssertThrowsError(try SSHCommandBuilder(sshPath: "/usr/bin/ssh\nid").argv(for: SSHHost(label: "x", hostname: "h")))
    }

    func testErrorFieldMapping() {
        do {
            _ = try builder.argv(for: SSHHost(label: "x", hostname: "h", username: "a b"))
            XCTFail("expected error")
        } catch let error as SSHCommandError {
            XCTAssertEqual(error.field, .username)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - 允许任意字符的字段（私钥路径、选项值）：靠转义保证安全

    /// 私钥路径允许空格、引号、Unicode 等，但必须在 shell 中还原为同一个参数。
    static let pathPayloads: [String] = [
        "/Users/me/My Keys/id",
        "/Users/me/o'brien/id",
        "/Users/me/a\"b/id",
        "/Users/me/a;id",
        "/Users/me/a`id`",
        "/Users/me/$(id)",
        "/Users/me/${HOME}",
        "/Users/me/a\\b",
        "/Users/me/a|b&c>d<e",
        "/Users/me/*?[x]",
        "/Users/张三/.ssh/密钥 1",
        "/Users/me/😀/id",
        "/Users/me/'\"'\"'",
    ]

    func testPathControlAndFormatCharactersRejected() {
        for bad in ["/k\n", "/k\r", "/k\0", "/k\u{1B}[31m", "/k\u{202E}", "/k\u{200B}", "-oProxyCommand=id"] {
            let host = SSHHost(label: "x", hostname: "h", authMethod: .publicKey, identityFile: bad)
            XCTAssertThrowsError(try builder.argv(for: host), bad.debugDescription)
        }
    }

    /// 端到端：转义后的命令行交给真实的 /bin/sh 解析，得到的 argv 必须与原始 argv 完全一致，且不执行任何注入。
    func testShellRoundTripThroughRealShell() throws {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(shells.isEmpty, "no POSIX shell available")

        for path in Self.pathPayloads {
            let host = SSHHost(
                label: "x", hostname: "h", username: "deploy", authMethod: .publicKey, identityFile: path,
                extraOptions: [SSHOption(key: "SetEnv", value: "NOTE=\(path)")])
            let argv = try builder.argv(for: host)
            let line = ShellQuoting.join(argv)
            for shell in shells {
                XCTAssertEqual(try Self.parseWithShell(shell, line), argv, "\(shell): \(line)")
            }
        }
    }

    /// AppleScript 层：解码字面量后必须得到原命令行，并且字面量在预期位置结束（没有被提前闭合）。
    func testAppleScriptLiteralRoundTrip() throws {
        for path in Self.pathPayloads {
            let host = SSHHost(label: "x", hostname: "h", authMethod: .publicKey, identityFile: path)
            let line = try builder.commandLine(for: host)
            let literal = AppleScriptQuoting.stringLiteral(line)
            let (decoded, consumed) = try XCTUnwrap(Self.decodeAppleScriptLiteral(literal))
            XCTAssertEqual(decoded, line)
            XCTAssertEqual(consumed, literal.unicodeScalars.count, "literal closed early: \(literal)")
        }
    }

    func testAppleScriptLiteralEscapesControlCharactersDefensively() {
        XCTAssertEqual(AppleScriptQuoting.stringLiteral("a\nb\rc\td"), "\"a\\nb\\rc\\td\"")
    }

    func testEveryTerminalPlanEmbedsExactlyOneEscapedLiteral() throws {
        let host = SSHHost(label: "x", hostname: "h", authMethod: .publicKey, identityFile: "/Users/me/a\"b\\c d/$(id)")
        let argv = try builder.argv(for: host)
        let line = ShellQuoting.join(argv)
        let literal = AppleScriptQuoting.stringLiteral(line)
        for terminal in TerminalApp.allCases {
            for mode in TerminalOpenMode.allCases {
                switch TerminalLaunchPlanner.plan(terminal: terminal, argv: argv, mode: mode, ghosttyVersion: "1.3.0") {
                case .appleScript(let script):
                    XCTAssertTrue(script.contains(literal), "\(terminal) \(mode)")
                    XCTAssertFalse(script.contains(line), "raw (unescaped) command leaked into script: \(terminal)")
                case .process(_, let args):
                    XCTAssertEqual(Array(args.suffix(argv.count)), argv)
                }
            }
        }
    }

    // MARK: - Helpers

    static func parseWithShell(_ shell: String, _ line: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // printf 把每个参数以 NUL 结尾输出；命令行里的第一个词（ssh 路径）也作为参数输出。
        process.arguments = ["-c", "printf '%s\\0' " + line]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = "/nonexistent-home"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// 最小 AppleScript 字符串字面量解码器：返回 (内容, 消耗的 scalar 数)。
    static func decodeAppleScriptLiteral(_ s: String) -> (String, Int)? {
        let scalars = Array(s.unicodeScalars)
        guard scalars.first == "\"" else { return nil }
        var out = String.UnicodeScalarView()
        var i = 1
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\" {
                guard i + 1 < scalars.count else { return nil }
                switch scalars[i + 1] {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(scalars[i + 1])
                }
                i += 2
            } else if c == "\"" {
                return (String(out), i + 1)
            } else {
                out.append(c)
                i += 1
            }
        }
        return nil
    }
}
