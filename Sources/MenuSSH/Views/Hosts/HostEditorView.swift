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
    @State private var discoveredKeys: [PublicKeyCandidate] = []
    @State private var showingCopyConfirm = false

    @EnvironmentObject private var settings: SettingsStore

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
                    publicKeyGuidance
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
                        Text("Password stays in the Keychain on this Mac and is not synced.")
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
        .onAppear(perform: preparePublicKeyDefault)
        .alert("Install the public key?", isPresented: $showingCopyConfirm) {
            Button("Open Terminal", action: installPublicKey)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                MenuSSH will open your terminal and run ssh-copy-id there. \
                You confirm the login in that window. It is never run in the background.
                """
            )
        }
    }

    @ViewBuilder
    private var publicKeyGuidance: some View {
        if discoveredKeys.isEmpty {
            Text("No public keys in ~/.ssh. Create one in Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: PublicKeyOnboarding.keygenCommand)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        } else {
            Text("A public key is recommended. The private key stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if discoveredKeys.count > 1 {
                Picker("Key File", selection: identitySelection) {
                    ForEach(discoveredKeys) { key in
                        Text(verbatim: key.fileName).tag(key.privatePath)
                    }
                }
            }
        }
        if draft.authMethod == .publicKey {
            Button("Install Public Key in Terminal…") { showingCopyConfirm = true }
                .disabled(draft.hostname.trimmingCharacters(in: .whitespaces).isEmpty || (draft.identityFile ?? "").isEmpty)
        }
    }

    private var identitySelection: Binding<String> {
        Binding(
            get: { draft.identityFile ?? "" },
            set: { draft.identityFile = $0.isEmpty ? nil : $0 }
        )
    }

    private func preparePublicKeyDefault() {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        discoveredKeys = PublicKeyOnboarding.candidates(fileNames: names, directory: directory)
        let isNew = draft.hostname.isEmpty && draft.label.isEmpty && draft.authMethod == .automatic
        guard isNew, let preferred = PublicKeyOnboarding.preferred(discoveredKeys) else { return }
        draft.authMethod = .publicKey
        draft.identityFile = preferred.privatePath
    }

    private func installPublicKey() {
        guard let identity = draft.identityFile, !identity.isEmpty else { return }
        let publicPath = identity.hasSuffix(".pub") ? identity : identity + ".pub"
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        let port: Int?
        if trimmedPort.isEmpty {
            port = nil
        } else if let value = Int(trimmedPort), (1...65535).contains(value) {
            port = value
        } else {
            fail(String(localized: "Port must be 1–65535."), field: .port)
            return
        }
        guard
            let args = PublicKeyOnboarding.copyIDArguments(
                publicPath: publicPath,
                username: draft.username,
                hostname: draft.hostname.trimmingCharacters(in: .whitespaces),
                port: port
            )
        else {
            fail(String(localized: "Host is required."), field: .hostname)
            return
        }
        let launcher = TerminalLauncher(sshPath: settings.sshPath, terminal: settings.terminal, openMode: settings.openMode)
        do {
            _ = try launcher.launchUserCommand(args)
        } catch {
            validationError = error.localizedDescription
        }
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
