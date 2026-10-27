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
    @State private var forwardDraft: PortForward?

    @EnvironmentObject private var settings: SettingsStore

    let outline: [GroupOutlineEntry]
    let otherHosts: [SSHHost]
    let onSave: (SSHHost) -> Void

    private let keychain = KeychainService()

    init(host: SSHHost, outline: [GroupOutlineEntry], otherHosts: [SSHHost], onSave: @escaping (SSHHost) -> Void) {
        _draft = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _tagsText = State(initialValue: HostInputParser.formatTags(host.tags))
        self.outline = outline
        self.otherHosts = otherHosts
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Label", text: $draft.label, prompt: Text("My Server"))
                        .accessibilityIdentifier(UITestID.editorLabel)
                    TextField("Host", text: $draft.hostname, prompt: Text("example.com or ssh-config alias"))
                        .foregroundStyle(errorField == .hostname ? Color.red : Color.primary)
                        .accessibilityIdentifier(UITestID.editorHost)
                    TextField("Port", text: $portText, prompt: Text(verbatim: "22"))
                        .foregroundStyle(errorField == .port ? Color.red : Color.primary)
                        .accessibilityIdentifier(UITestID.editorPort)
                    TextField("Username", text: $draft.username, prompt: Text(verbatim: "root"))
                        .foregroundStyle(errorField == .username ? Color.red : Color.primary)
                        .accessibilityIdentifier(UITestID.editorUser)
                    Picker("Group", selection: $draft.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(outline) { entry in
                            Text(verbatim: String(repeating: "  ", count: entry.depth) + entry.group.name)
                                .tag(UUID?.some(entry.group.id))
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
                        ), prompt: Text(verbatim: "user@bastion:22,edge")
                    )
                    .foregroundStyle(errorField == .jumpHost ? Color.red : Color.primary)
                    .accessibilityIdentifier(UITestID.editorJump)
                    Text("Comma-separated hops, nearest first. Example: user@bastion:22,edge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !otherHosts.isEmpty {
                        Menu("Use Host as Jump") {
                            ForEach(otherHosts) { other in
                                Button {
                                    applyJump(from: other)
                                } label: {
                                    Text(verbatim: other.label)
                                }
                                .accessibilityIdentifier(UITestID.jumpPick(other.label))
                                .disabled(JumpHostSpec.specification(for: other) == nil)
                            }
                        }
                        .accessibilityIdentifier(UITestID.editorUseJump)
                    }
                    TextField(
                        "Startup Command",
                        text: $draft.startupCommand,
                        prompt: Text(verbatim: "cd /app && tmux attach")
                    )
                    .foregroundStyle(errorField == .startupCommand ? Color.red : Color.primary)
                    .accessibilityIdentifier(UITestID.editorStartup)
                    Text("One line typed after the ssh command. Control characters are rejected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Agent Forwarding", isOn: $draft.forwardAgent)
                        .accessibilityIdentifier(UITestID.editorForwardAgent)
                    Text("Adds -o ForwardAgent=yes so the remote host can use your local agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    portForwards
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
                    .accessibilityIdentifier(UITestID.editorCancel)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UITestID.editorSave)
                    .disabled(draft.hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: UITestLaunch.isEnabled ? 760 : 680)
        .sheet(item: $forwardDraft) { forward in
            PortForwardEditor(forward: forward) { saved in
                if let index = draft.portForwards.firstIndex(where: { $0.id == saved.id }) {
                    draft.portForwards[index] = saved
                } else {
                    draft.portForwards.append(saved)
                }
            }
        }
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

    private var portForwards: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Port Forwarding")
                .font(.callout)
            if draft.portForwards.isEmpty {
                Text("No port forwards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.portForwards) { forward in
                HStack {
                    Text(verbatim: forward.editorSummary)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Edit…") { forwardDraft = forward }
                    Button("Delete", role: .destructive) {
                        draft.portForwards.removeAll { $0.id == forward.id }
                    }
                }
            }
            Button("Add Forward") {
                forwardDraft = PortForward(
                    kind: .local, listenPort: 8080, destinationHost: "127.0.0.1", destinationPort: 80)
            }
            .accessibilityIdentifier(UITestID.editorAddForward)
        }
    }

    private func applyJump(from host: SSHHost) {
        guard let spec = JumpHostSpec.specification(for: host) else { return }
        let current = (draft.jumpHost ?? "").trimmingCharacters(in: .whitespaces)
        draft.jumpHost = current.isEmpty ? spec : current + "," + spec
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
            if let startup = try SSHCommandBuilder.startupCommand(host.startupCommand) {
                host.startupCommand = startup
            } else {
                host.startupCommand = ""
            }
        } catch let error as SSHCommandError {
            fail(error.message, field: error.field)
            return
        } catch {
            fail(error.localizedDescription, field: .startupCommand)
            return
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

private struct PortForwardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PortForward.Kind
    @State private var bindAddress: String
    @State private var listenPort: String
    @State private var destinationHost: String
    @State private var destinationPort: String
    @State private var error: String?
    private let originalID: UUID
    private let onSave: (PortForward) -> Void

    init(forward: PortForward, onSave: @escaping (PortForward) -> Void) {
        _kind = State(initialValue: forward.kind)
        _bindAddress = State(initialValue: forward.bindAddress ?? "")
        _listenPort = State(initialValue: String(forward.listenPort))
        _destinationHost = State(initialValue: forward.destinationHost ?? "")
        _destinationPort = State(initialValue: forward.destinationPort.map(String.init) ?? "")
        originalID = forward.id
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Port Forwarding") {
                    Picker("Kind", selection: $kind) {
                        Text("Local").tag(PortForward.Kind.local)
                        Text("Remote").tag(PortForward.Kind.remote)
                        Text("Dynamic").tag(PortForward.Kind.dynamic)
                    }
                    TextField("Bind Address", text: $bindAddress, prompt: Text(verbatim: "127.0.0.1"))
                    TextField("Listen Port", text: $listenPort, prompt: Text(verbatim: "8080"))
                        .accessibilityIdentifier(UITestID.forwardListen)
                    if kind != .dynamic {
                        TextField("Destination Host", text: $destinationHost, prompt: Text(verbatim: "127.0.0.1"))
                            .accessibilityIdentifier(UITestID.forwardDestinationHost)
                        TextField("Destination Port", text: $destinationPort, prompt: Text(verbatim: "80"))
                            .accessibilityIdentifier(UITestID.forwardDestinationPort)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(verbatim: error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(UITestID.forwardSave)
            }
            .padding(12)
        }
        .frame(width: 420, height: 320)
    }

    private func save() {
        let listen = Int(listenPort.trimmingCharacters(in: .whitespaces)) ?? 0
        let destPort = Int(destinationPort.trimmingCharacters(in: .whitespaces))
        let bind = bindAddress.trimmingCharacters(in: .whitespaces)
        let destHost = destinationHost.trimmingCharacters(in: .whitespaces)
        let forward = PortForward(
            id: originalID,
            kind: kind,
            bindAddress: bind.isEmpty ? nil : bind,
            listenPort: listen,
            destinationHost: kind == .dynamic || destHost.isEmpty ? nil : destHost,
            destinationPort: kind == .dynamic ? nil : destPort
        )
        let probe = SSHHost(label: "probe", hostname: "example.com", portForwards: [forward])
        do {
            _ = try SSHCommandBuilder().argv(for: probe)
        } catch let commandError as SSHCommandError {
            error = commandError.message
            return
        } catch {
            self.error = error.localizedDescription
            return
        }
        onSave(forward)
        dismiss()
    }
}

extension PortForward {
    var editorSummary: String {
        let bind = bindAddress.map { "\($0):" } ?? ""
        switch kind {
        case .dynamic:
            return "D \(bind)\(listenPort)"
        case .local:
            let dest = "\(destinationHost ?? ""):\(destinationPort.map(String.init) ?? "")"
            return "L \(bind)\(listenPort):\(dest)"
        case .remote:
            let dest = "\(destinationHost ?? ""):\(destinationPort.map(String.init) ?? "")"
            return "R \(bind)\(listenPort):\(dest)"
        }
    }
}
