import AppKit
import MenuSSHCore
import SwiftUI

/// 新建 / 编辑站点。编辑草稿，保存时才写回。
@MainActor
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SSHHost
    @State private var portText: String
    @State private var tagsText: String
    @State private var password = ""
    @State private var validationError: String?

    let groups: [HostGroup]
    let onSave: (SSHHost) -> Void

    private let keychain = KeychainService()

    init(host: SSHHost, groups: [HostGroup], onSave: @escaping (SSHHost) -> Void) {
        _draft = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _tagsText = State(initialValue: host.tags.joined(separator: ", "))
        self.groups = groups
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Label", text: $draft.label, prompt: Text("My Server"))
                    TextField("Host", text: $draft.hostname, prompt: Text("example.com or ssh-config alias"))
                    TextField("Port", text: $portText, prompt: Text("22"))
                    TextField("Username", text: $draft.username, prompt: Text("root"))
                    Picker("Group", selection: $draft.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(groups) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                    TextField("Tags", text: $tagsText, prompt: Text("prod, db"))
                    Toggle("Favorite", isOn: $draft.isFavorite)
                }
                Section("Authentication") {
                    Picker("Method", selection: $draft.authMethod) {
                        Text("Automatic (ssh config / agent)").tag(AuthMethod.automatic)
                        Text("Private Key").tag(AuthMethod.publicKey)
                        Text("Password").tag(AuthMethod.password)
                    }
                    if draft.authMethod == .publicKey {
                        HStack {
                            TextField(
                                "Key File",
                                text: Binding(
                                    get: { draft.identityFile ?? "" },
                                    set: { draft.identityFile = $0.isEmpty ? nil : $0 }
                                ), prompt: Text("~/.ssh/id_ed25519"))
                            Button("Choose…", action: chooseKeyFile)
                        }
                    }
                    if draft.authMethod == .password {
                        SecureField("Password", text: $password, prompt: Text("Stored in Keychain"))
                        Text("Password login will be wired through SSH_ASKPASS in milestone M3.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Advanced") {
                    TextField(
                        "Jump Host",
                        text: Binding(
                            get: { draft.jumpHost ?? "" },
                            set: { draft.jumpHost = $0.isEmpty ? nil : $0 }
                        ), prompt: Text("user@bastion:22"))
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let validationError {
                    Text(validationError).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    private func save() {
        var host = draft
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        if host.label.trimmingCharacters(in: .whitespaces).isEmpty { host.label = host.hostname }

        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        if trimmedPort.isEmpty {
            host.port = nil
        } else if let port = Int(trimmedPort), (1...65535).contains(port) {
            host.port = port
        } else {
            validationError = String(localized: "Port must be 1–65535")
            return
        }
        host.tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 先用命令构建器校验，拦截非法 hostname / 用户名等。
        do {
            _ = try SSHCommandBuilder().argv(for: host)
        } catch {
            validationError = String(localized: "Invalid: \(String(describing: error))")
            return
        }

        if host.authMethod == .password, !password.isEmpty {
            do {
                try keychain.set(password, account: KeychainService.account(hostID: host.id, kind: .password))
            } catch {
                validationError = String(localized: "Keychain error: \(String(describing: error))")
                return
            }
        }
        onSave(host)
        dismiss()
    }
}
