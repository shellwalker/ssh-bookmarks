import Foundation
import SSHBookmarksCore

// 校验错误的界面文案（Core 只给出错误类型和字段）。

extension SSHCommandError {
    var message: String {
        switch self {
        case .emptyHostname:
            return String(localized: "Host is required.")
        case .invalidHostname(_):
            return String(
                localized: "Host may only contain ASCII letters, digits and . - _ : %. Use punycode (xn--) for international domains.")
        case .invalidUsername(_):
            return String(localized: "Username may only contain ASCII letters, digits and . _ - @, and cannot start with -.")
        case .invalidPort(_):
            return String(localized: "Port must be 1–65535.")
        case .invalidIdentityFile(_):
            return String(localized: "Key file path cannot start with - or contain control characters.")
        case .invalidJumpHost(_):
            return String(localized: "Jump host must look like user@host:port (comma-separated for multiple hops).")
        case .invalidOption(let key):
            return L10n.format("SSH option %@ is not allowed or has an invalid value.", key)
        case .invalidPortForward(_):
            return String(localized: "Invalid port forward.")
        case .invalidStartupCommand(_):
            return String(localized: "Startup command must be a single line without control characters.")
        case .invalidSSHPath(_):
            return String(localized: "SSH executable must be an absolute path.")
        }
    }
}

extension ExtraOptionRejection {
    var message: String {
        switch self {
        case .emptyKey:
            return String(localized: "Option name is required.")
        case .invalidKey:
            return String(localized: "Option names may only contain letters.")
        case .blockedKey(let key):
            return L10n.format(
                "Option %@ is blocked because it can run a command or load code on this Mac. Set it in ~/.ssh/config instead.",
                key
            )
        case .emptyValue:
            return String(localized: "Option value is required.")
        case .controlCharacter:
            return String(localized: "Option value cannot contain control characters.")
        }
    }
}

extension HostInputParser.PortError {
    var message: String {
        switch self {
        case .notANumber: return String(localized: "Port must be a number.")
        case .outOfRange: return String(localized: "Port must be 1–65535.")
        }
    }
}
