import Foundation

public struct PublicKeyCandidate: Equatable, Sendable, Identifiable {
    public var fileName: String
    public var publicPath: String
    public var privatePath: String

    public var id: String { publicPath }

    public init(fileName: String, publicPath: String, privatePath: String) {
        self.fileName = fileName
        self.publicPath = publicPath
        self.privatePath = privatePath
    }
}

/// 新建站点时优先公钥。这里只生成要给用户看的命令，不执行。
public enum PublicKeyOnboarding {
    public static let keygenCommand = "ssh-keygen -t ed25519"

    public static func candidates(fileNames: [String], directory: String) -> [PublicKeyCandidate] {
        let root = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return
            fileNames
            .filter { name in
                name.hasSuffix(".pub") && !name.hasPrefix(".") && !name.contains("/") && !name.containsControlCharacters
            }
            .map { name in
                let publicPath = root + "/" + name
                let privatePath = String(publicPath.dropLast(4))
                return PublicKeyCandidate(fileName: name, publicPath: publicPath, privatePath: privatePath)
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// 有 `id_ed25519.pub` 就用它，否则用排序后的第一把。
    public static func preferred(_ candidates: [PublicKeyCandidate]) -> PublicKeyCandidate? {
        candidates.first { $0.fileName == "id_ed25519.pub" } ?? candidates.first
    }

    /// 在用户自己的终端里运行的 argv。主机名不合法时返回 nil，调用方不得执行。
    public static func copyIDArguments(publicPath: String, username: String, hostname: String, port: Int?) -> [String]? {
        let host = hostname.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        let user = username.trimmingCharacters(in: SSHCommandBuilder.plainSpaces)
        guard SSHCommandBuilder.isValidPath(publicPath), SSHCommandBuilder.isValidHostname(host) else { return nil }
        if !user.isEmpty && !SSHCommandBuilder.isValidUsername(user) { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        var args = ["ssh-copy-id", "-i", publicPath]
        if let port {
            args += ["-p", String(port)]
        }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        if user.isEmpty {
            args.append(bracketed)
        } else {
            args.append("\(user)@\(bracketed)")
        }
        return args
    }
}
