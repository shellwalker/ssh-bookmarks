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
    @State private var errorField: HostField?

    let groups: [HostGroup]
    let onSave: (SSHHost) -> Void

    private let keychain = KeychainService()

    init(host: SSHHost, groups: [HostGroup], onSave: @escaping (SSHHost) -> Void) {
        _draft = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _tagsText = State(initialValue: HostInputParser.formatTags(host.tags))
        self.groups = groups
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Label", text: $draft.label, prompt: Text("My Server"))
                    TextField("Host", text: $draft.hostname, prompt: Text("example.com or ssh-config alias"))
                        .foregroundStyle(errorField == .hostname ? Color.red : Color.primary)
                    TextField("Port", text: $portText, prompt: Text(verbatim: "22"))
                        .foregroundStyle(errorField == .port ? Color.red : Color.primary)
                    TextField("Username", text: $draft.username, prompt: Text(verbatim: "root"))
                        .foregroundStyle(errorField == .username ? Color.red : Color.primary)
                    Picker("Group", selection: $draft.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(groups) { group in
                            Text(verbatim: group.name).tag(UUID?.some(group.id))
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
                                ), prompt: Text(verbatim: "~/.ssh/id_ed25519"))
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
                        ), prompt: Text(verbatim: "user@bastion:22")
                    )
                    .foregroundStyle(errorField == .jumpHost ? Color.red : Color.primary)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let validationError {
                    Text(verbatim: validationError)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
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
        host.label = HostInputParser.normalizedName(host.label)
        if host.label.isEmpty { host.label = host.hostname }
        host.tags = HostInputParser.parseTags(tagsText)
        if let identity = host.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
            host.identityFile = identity
        } else {
            host.identityFile = nil
        }
        if let jump = host.jumpHost?.trimmingCharacters(in: .whitespaces), !jump.isEmpty {
            host.jumpHost = jump
        } else {
            host.jumpHost = nil
        }

        do {
            host.port = try HostInputParser.parsePort(portText)
        } catch let error as HostInputParser.PortError {
            fail(error.message, field: .port)
            return
        } catch {
            fail(error.localizedDescription, field: .port)
            return
        }

        // 用命令构建器做白名单校验，拦截非法主机名 / 用户名 / 跳板机等。
        do {
            _ = try SSHCommandBuilder().argv(for: host)
        } catch let error as SSHCommandError {
            fail(error.message, field: error.field)
            return
        } catch {
            fail(error.localizedDescription, field: nil)
            return
        }

        if host.authMethod == .password, !password.isEmpty {
            do {
                try keychain.set(password, account: KeychainService.account(hostID: host.id, kind: .password))
            } catch {
                fail(L10n.format("Keychain error: %@", error.localizedDescription), field: nil)
                return
            }
        }
        onSave(host)
        dismiss()
    }

    private func fail(_ message: String, field: HostField?) {
        validationError = message
        errorField = field
    }
}
