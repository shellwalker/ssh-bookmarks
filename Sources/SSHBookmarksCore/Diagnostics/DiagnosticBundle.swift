import Foundation

/// 导出用的诊断包。内容先脱敏再打包，包里没有密码、令牌或私钥。
public enum DiagnosticBundle {
    public struct Input: Equatable, Sendable {
        public var version: String
        public var build: String
        public var osVersion: String
        public var sshPath: String
        public var terminal: String
        public var logText: String

        public init(version: String, build: String, osVersion: String, sshPath: String, terminal: String, logText: String) {
            self.version = version
            self.build = build
            self.osVersion = osVersion
            self.sshPath = sshPath
            self.terminal = terminal
            self.logText = logText
        }
    }

    public static func makeZIP(_ input: Input, redactor: DiagnosticRedactor) -> Data {
        let log = redactor.redact(input.logText)
        let manifest = """
            {
              "app": "SSH Bookmarks",
              "version": \(jsonString(input.version)),
              "build": \(jsonString(input.build)),
              "os": \(jsonString(redactor.redact(input.osVersion))),
              "sshPath": \(jsonString(redactor.redact(input.sshPath))),
              "terminal": \(jsonString(input.terminal)),
              "redactsNames": \(redactor.redactNames),
              "containsPasswords": false
            }
            """
        return StoredZip.archive([
            ("manifest.json", Data(manifest.utf8)),
            ("diagnostics.log", Data(log.utf8)),
        ])
    }

    /// 复制到剪贴板的短文本。再过一次脱敏。
    public static func pasteboardText(_ input: Input, redactor: DiagnosticRedactor) -> String {
        let log = redactor.redact(input.logText)
        let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
        return redactor.redact(
            """
            SSH Bookmarks \(input.version) (\(input.build))
            \(input.osVersion)
            ssh: \(input.sshPath)
            terminal: \(input.terminal)
            \(tail)
            """
        )
    }

    private static func jsonString(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
