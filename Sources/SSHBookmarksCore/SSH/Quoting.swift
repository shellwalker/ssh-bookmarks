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
    /// 返回带双引号的 AppleScript 字符串字面量：转义 `\` 和 `"`。
    /// 防御性地把换行、回车、制表符写成 `\n` `\r` `\t`（SSHCommandBuilder 本身已拒绝控制字符）。
    public static func stringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension String {
    /// 是否包含控制字符或格式字符（换行、制表符、NUL、ESC、零宽字符、双向覆盖 U+202E、U+2028 行分隔符等）。
    /// 按 Unicode 通用类别判断，避免不同平台 CharacterSet 定义不一致。
    public var containsControlCharacters: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
}
