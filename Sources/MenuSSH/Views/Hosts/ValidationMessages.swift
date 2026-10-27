import Foundation
import MenuSSHCore

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
        case .invalidSSHPath(_):
            return String(localized: "SSH executable must be an absolute path.")
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
