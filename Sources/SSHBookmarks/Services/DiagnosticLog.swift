import AppKit
import Foundation
import OSLog
import SSHBookmarksCore
import UniformTypeIdentifiers

enum AppLog {
    static let subsystem = ProductIdentity.bundleIdentifier
    static let ssh = Logger(subsystem: subsystem, category: "ssh")
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    static let askpass = Logger(subsystem: subsystem, category: "askpass")
    static let sync = Logger(subsystem: subsystem, category: "sync")
}

/// 统一日志始终走 os.Logger。文件默认关，写入前先脱敏。
@MainActor
enum DiagnosticLog {
    static func connect(host: SSHHost, terminal: String, askpass: Bool, fallback: String?) {
        let used = fallback ?? "-"
        AppLog.ssh.info("connect terminal=\(terminal, privacy: .public) askpass=\(askpass, privacy: .public)")
        AppLog.ssh.info("connect host=\(host.hostname, privacy: .private) user=\(host.username, privacy: .private)")
        let line = "connect terminal=\(terminal) askpass=\(askpass) fallback=\(used) host=\(host.hostname) user=\(host.username)"
        write(line, namesFrom: [host])
    }

    static func tunnel(event: String, port: Int, kind: String, exitCode: Int32?, detail: String, hosts: [SSHHost]) {
        let code = exitCode.map(String.init) ?? "-"
        AppLog.tunnel.info("tunnel \(event, privacy: .public) port=\(port, privacy: .public)")
        AppLog.tunnel.info("tunnel kind=\(kind, privacy: .public) exit=\(code, privacy: .public)")
        let tail = String(detail.prefix(500))
        write("tunnel event=\(event) port=\(port) kind=\(kind) exit=\(code) \(tail)", namesFrom: hosts)
    }

    static func askpassIssued() {
        AppLog.askpass.info("askpass token issued")
        write("askpass issued", namesFrom: [])
    }

    static func syncFailure(_ message: String) {
        AppLog.sync.error("sync failed \(message, privacy: .public)")
        write("sync failed \(message)", namesFrom: [])
    }

    static func write(_ line: String, namesFrom hosts: [SSHHost]) {
        guard SettingsStore.shared.diagnosticLogEnabled else { return }
        guard !UITestLaunch.isEnabled else { return }
        let redactor = DiagnosticRedactor(
            redactNames: SettingsStore.shared.diagnosticRedactNames,
            hostnames: hosts.map(\.hostname),
            usernames: hosts.map(\.username)
        )
        let stamped = "\(isoNow()) \(redactor.redact(line))"
        do {
            try append(stamped)
        } catch {
            AppLog.ssh.error("diagnostic file write failed \(error.localizedDescription, privacy: .public)")
        }
    }

    static func logDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProductPaths.logsDirectory(applicationSupport: root)
    }

    static func snapshots() -> [DiagnosticFileSnapshot] {
        let directory = logDirectory()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix(DiagnosticRetention.currentName) else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return DiagnosticFileSnapshot(
                name: url.lastPathComponent,
                byteCount: values?.fileSize ?? 0,
                modifiedAt: values?.contentModificationDate ?? .distantPast
            )
        }
    }

    static func currentText() -> String {
        let url = logDirectory().appendingPathComponent(DiagnosticRetention.currentName)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func append(_ line: String) throws {
        let fm = FileManager.default
        let directory = logDirectory()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        let payload = Data((line + "\n").utf8)
        let plan = DiagnosticRetention.plan(files: snapshots(), appending: payload.count, now: now)
        for name in plan.delete {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        if plan.rotate {
            try rotate(in: directory)
        }
        let url = directory.appendingPathComponent(DiagnosticRetention.currentName)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }

    /// 把 `diagnostics.log` 改成 `.1`，原来的 `.1` 顺移到 `.2`，直到最多 5 个文件。
    private static func rotate(in directory: URL) throws {
        let fm = FileManager.default
        let current = directory.appendingPathComponent(DiagnosticRetention.currentName)
        guard fm.fileExists(atPath: current.path) else { return }
        for index in stride(from: DiagnosticRetention.maxFiles - 1, through: 1, by: -1) {
            let source =
                index == 1
                ? current
                : directory.appendingPathComponent("\(DiagnosticRetention.currentName).\(index - 1)")
            let destination = directory.appendingPathComponent("\(DiagnosticRetention.currentName).\(index)")
            guard fm.fileExists(atPath: source.path) else { continue }
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.moveItem(at: source, to: destination)
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

@MainActor
enum DiagnosticActions {
    static func bundleInput(settings: SettingsStore, hosts: HostStoreModel) -> DiagnosticBundle.Input {
        let info = Bundle.main.infoDictionary
        let ssh = settings.sshPath
        let version = (try? sshVersion(ssh)) ?? ssh
        return DiagnosticBundle.Input(
            version: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            sshPath: "\(ssh) \(version)",
            terminal: settings.terminal.rawValue,
            logText: DiagnosticLog.currentText()
        )
    }

    static func redactor(settings: SettingsStore, hosts: HostStoreModel) -> DiagnosticRedactor {
        DiagnosticRedactor(
            redactNames: settings.diagnosticRedactNames,
            hostnames: hosts.library.hosts.map(\.hostname),
            usernames: hosts.library.hosts.map(\.username)
        )
    }

    static func export(settings: SettingsStore, hosts: HostStoreModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "SSH-Bookmarks-diagnostics.zip"
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let input = bundleInput(settings: settings, hosts: hosts)
        let data = DiagnosticBundle.makeZIP(input, redactor: redactor(settings: settings, hosts: hosts))
        try? data.write(to: url, options: .atomic)
    }

    static func copy(settings: SettingsStore, hosts: HostStoreModel) {
        let text = DiagnosticBundle.pasteboardText(
            bundleInput(settings: settings, hosts: hosts), redactor: redactor(settings: settings, hosts: hosts))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func revealLogFolder() -> String? {
        let directory = DiagnosticLog.logDirectory()
        let files = DiagnosticLog.snapshots()
        guard !files.isEmpty else { return String(localized: "No diagnostic log yet") }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
        return nil
    }

    private static func sshVersion(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-V"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
