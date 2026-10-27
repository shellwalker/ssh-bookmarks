import Foundation

/// 一把 `~/.ssh` 里的密钥：私钥旁边有同名 `.pub`。
public struct SSHIdentityChoice: Equatable, Sendable, Identifiable {
    public var fileName: String
    public var privatePath: String
    public var publicPath: String
    public var keyType: String
    public var comment: String?

    public var id: String { privatePath }

    public init(fileName: String, privatePath: String, publicPath: String, keyType: String, comment: String?) {
        self.fileName = fileName
        self.privatePath = privatePath
        self.publicPath = publicPath
        self.keyType = keyType
        self.comment = comment
    }

    /// 选择器里的一行：文件名、类型、注释。
    public var pickerLabel: String {
        if let comment, !comment.isEmpty {
            return "\(fileName) — \(keyType) — \(comment)"
        }
        if keyType.isEmpty { return fileName }
        return "\(fileName) — \(keyType)"
    }
}

public struct SSHIdentityInspection: Equatable, Sendable {
    public enum Notice: Equatable, Hashable, Sendable {
        /// 用户选了 `.pub`，路径已改成对应私钥。
        case switchedFromPublicKey
        case missingPrivateKey
        /// 权限宽于 0600（组或其他用户可读），ssh 会拒绝。
        case permissionsTooOpen
    }

    public var path: String
    public var notices: [Notice]

    public init(path: String, notices: [Notice]) {
        self.path = path
        self.notices = notices
    }
}

/// 列出密钥、解析 `.pub`，并检查私钥是否存在、权限是否过宽。不读私钥内容。
public enum SSHKeyDiscovery {
    /// 这些名字不是密钥，即使目录里出现也不列入选择器。
    public static let ignoredFileNames: Set<String> = [
        "known_hosts", "known_hosts.old", "config", "authorized_keys", "authorized_keys2",
    ]

    public static func expandingTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + String(path.dropFirst(1)) }
        return path
    }

    /// `.pub` 路径换成同名私钥路径；其它路径原样返回。
    public static func privatePath(forPublicOrPrivate path: String) -> String {
        path.hasSuffix(".pub") ? String(path.dropLast(4)) : path
    }

    /// OpenSSH：模式里组或其他用户有任何权限位（`mode & 077 != 0`）就拒绝。
    public static func privateKeyPermissionsTooOpen(_ mode: UInt16) -> Bool {
        (mode & 0o077) != 0
    }

    /// 解析一行 OpenSSH 公钥：`type base64 comment...`。注释可含空格。
    public static func parsePublicKey(_ text: String) -> (type: String, comment: String?)? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, isPublicKeyType(parts[0]) else { continue }
            let comment = parts.count > 2 ? parts.dropFirst(2).joined(separator: " ") : nil
            return (parts[0], comment?.isEmpty == true ? nil : comment)
        }
        return nil
    }

    /// 只收录「私钥存在，且旁边有 `.pub`」的密钥。`known_hosts` / `config` / `authorized_keys` 排除。
    public static func pairs(
        fileNames: [String],
        directory: String,
        readFile: (String) -> String?,
        privateKeyExists: (String) -> Bool
    ) -> [SSHIdentityChoice] {
        let root = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        var found: [SSHIdentityChoice] = []
        for name in fileNames {
            guard name.hasSuffix(".pub"), !name.hasPrefix("."), !name.contains("/"), !name.containsControlCharacters else { continue }
            let privateName = String(name.dropLast(4))
            if ignoredFileNames.contains(name) || ignoredFileNames.contains(privateName) { continue }
            let privatePath = root + "/" + privateName
            let publicPath = root + "/" + name
            guard privateKeyExists(privatePath) else { continue }
            let parsed = readFile(publicPath).flatMap(parsePublicKey)
            found.append(
                SSHIdentityChoice(
                    fileName: privateName,
                    privatePath: privatePath,
                    publicPath: publicPath,
                    keyType: parsed?.type ?? "",
                    comment: parsed?.comment
                )
            )
        }
        return found.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// 选了 `.pub` 就改用私钥。缺文件或权限过宽只产生提示，不改掉用户的路径。
    public static func inspect(
        path raw: String,
        homeDirectory: String,
        privateKeyExists: (String) -> Bool,
        privateKeyMode: (String) -> UInt16?
    ) -> SSHIdentityInspection {
        let trimmed = raw.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        var notices: [SSHIdentityInspection.Notice] = []
        var stored = trimmed
        if stored.hasSuffix(".pub") {
            stored = String(stored.dropLast(4))
            notices.append(.switchedFromPublicKey)
        }
        let expanded = expandingTilde(stored, homeDirectory: homeDirectory)
        if expanded.isEmpty || !privateKeyExists(expanded) {
            notices.append(.missingPrivateKey)
        } else if let mode = privateKeyMode(expanded), privateKeyPermissionsTooOpen(mode) {
            notices.append(.permissionsTooOpen)
        }
        return SSHIdentityInspection(path: stored, notices: notices)
    }

    private static func isPublicKeyType(_ type: String) -> Bool {
        switch type {
        case "ssh-ed25519", "ssh-rsa", "ssh-dss",
            "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return true
        default:
            return type.hasPrefix("sk-ssh-") || type.hasPrefix("sk-ecdsa-")
        }
    }
}
