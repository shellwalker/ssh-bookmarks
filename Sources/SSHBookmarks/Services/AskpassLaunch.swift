import Foundation
import SSHBookmarksCore

enum AskpassPaths {
    static func applicationSupport() -> URL {
        LegacyDataMigration.moveSupportFolderIfNeeded()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProductPaths.supportDirectory(applicationSupport: root)
    }

    static func tokenFileURL() -> URL {
        applicationSupport().appendingPathComponent("askpass-tokens.json")
    }

    static func launcherDirectory() -> URL {
        applicationSupport().appendingPathComponent("askpass-launchers", isDirectory: true)
    }
}

/// 为这一次连接签发令牌，并写出一个 0700 的启动脚本。脚本和令牌都不含密码。
enum AskpassLaunch {
    static func commandArgv(host: SSHHost, sshArguments: [String], sshPath: String) throws -> [String]? {
        guard host.authMethod == .password else { return nil }
        let account = KeychainService.account(hostID: host.id, kind: .password)
        // 只判断钥匙串里有没有密码。密码本身不进入脚本、参数或日志。
        guard try KeychainService().get(account: account)?.isEmpty == false else { return nil }
        guard let executable = Bundle.main.executablePath else { return nil }
        let token = try AskpassTokenFile.issue(hostID: host.id, fileURL: AskpassPaths.tokenFileURL(), now: Date())
        guard let script = AskpassLauncherScript.contents(askpassExecutable: executable, sshPath: sshPath, token: token) else {
            return nil
        }
        let url = AskpassPaths.launcherDirectory().appendingPathComponent("launch-\(UUID().uuidString).command")
        try AtomicFileWrite.write(Data(script.utf8), to: url, permissions: 0o700)
        return [url.path] + sshArguments
    }
}

/// ssh 通过 SSH_ASKPASS 拉起的第二个进程。没有一次性令牌就不会读钥匙串。
enum AskpassMain {
    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let token = AskpassTokenStore.token(in: environment), !token.isEmpty else { exit(1) }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard AskpassPrompt.isPasswordPrompt(prompt) else { exit(2) }
        guard let hostID = try? AskpassTokenFile.redeem(token: token, fileURL: AskpassPaths.tokenFileURL(), now: Date()) else {
            exit(1)
        }
        guard let password = try? KeychainService().get(account: KeychainService.account(hostID: hostID, kind: .password)) else {
            exit(1)
        }
        var data = Data(password.utf8)
        if !password.hasSuffix("\n") {
            data.append(Data("\n".utf8))
        }
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            exit(1)
        }
        exit(0)
    }
}
