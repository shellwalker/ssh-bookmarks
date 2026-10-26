import Foundation

/// POSIX shell 引用。输出同时兼容 sh / bash / zsh / fish（单引号 + `'\''`）。
public enum ShellQuoting {
    private static let safeScalars: Set<Unicode.Scalar> = {
        var s = Set<Unicode.Scalar>()
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_".unicodeScalars {
            s.insert(c)
        }
        return s
    }()

    /// 引用单个参数。只含安全字符时原样返回，否则用单引号包裹。
    public static func quote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        if argument.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 把 argv 拼成一条可安全输入到 shell 的命令行。
    public static func join(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }
}

/// AppleScript 字符串字面量转义。
public enum AppleScriptQuoting {
    /// 返回带双引号的 AppleScript 字符串字面量。只转义 `\` 和 `"`；
    /// 调用方必须保证内容不含换行等控制字符（SSHCommandBuilder 已做校验）。
    public static func stringLiteral(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

extension String {
    /// 是否包含控制字符（换行、制表符、NUL、ESC 等）。
    var containsControlCharacters: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
