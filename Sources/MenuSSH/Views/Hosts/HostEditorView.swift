import AppKit
import MenuSSHCore
import SwiftUI

/// 新建 / 编辑站点。编辑草稿，保存时才写回。
@MainActor
struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SSHHost
    @State private var baseline: SSHHost
    @State private var portText: String
    @State private var tagsText: String
    @State private var optionDrafts: [OptionDraft]
    @State private var password = ""
    @State private var storedPasswordExists = false
    @State private var removeStoredPassword = false
    @State private var validationError: String?
    @State private var errorField: HostField?
    @State private var discoveredPairs: [SSHIdentityChoice] = []
    @State private var discoveredPubs: [PublicKeyCandidate] = []
    @State private var identityNotices: [SSHIdentityInspection.Notice] = []
    @State private var keyPicker = ""
    @State private var showingCopyConfirm = false
    @State private var showingDiscard = false
    @State private var showingReplacePassword = false
    @State private var showingRemovePassword = false
    @State private var forwardDraft: PortForward?

    @EnvironmentObject private var settings: SettingsStore

    let outline: [GroupOutlineEntry]
    let otherHosts: [SSHHost]
    let onSave: (SSHHost) -> Void

    private let keychain = KeychainService()
    private let otherKeySentinel = "\u{0}other-file"

    init(host: SSHHost, outline: [GroupOutlineEntry], otherHosts: [SSHHost], onSave: @escaping (SSHHost) -> Void) {
        _draft = State(initialValue: host)
        _baseline = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _tagsText = State(initialValue: HostInputParser.formatTags(host.tags))
        _optionDrafts = State(initialValue: host.extraOptions.map { OptionDraft(key: $0.key, value: $0.value) })
        self.outline = outline
        self.otherHosts = otherHosts
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    generalSection
                    authenticationSection
                    advancedSection
                }
                .formStyle(.grouped)
            }
            .frame(height: 400)

            Divider()
            saveBar
        }
        .frame(width: 520)
        .sheet(item: $forwardDraft) { forward in
            PortForwardEditor(forward: forward) { saved in
                if let index = draft.portForwards.firstIndex(where: { $0.id == saved.id }) {
                    draft.portForwards[index] = saved
                } else {
                    draft.portForwards.append(saved)
                }
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: draft.identityFile) { _, newValue in
            refreshIdentity(newValue)
        }
        .onChange(of: keyPicker) { _, newValue in
            guard newValue == otherKeySentinel else {
                if !newValue.isEmpty { draft.identityFile = newValue }
                return
            }
            keyPicker = draft.identityFile ?? ""
            chooseKeyFile()
        }
        .alert("Install the public key?", isPresented: $showingCopyConfirm) {
            Button("Open Terminal", action: installPublicKey)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(copyIDConfirmText))
        }
        .alert("Discard unsaved changes?", isPresented: $showingDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This host has changes that have not been saved.")
        }
        .alert("Replace the saved password?", isPresented: $showingReplacePassword) {
            Button("Replace", action: commitSave)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The password in the Keychain for this host will be replaced.")
        }
        .alert("Remove the saved password?", isPresented: $showingRemovePassword) {
            Button("Remove Password", role: .destructive) {
                removeStoredPassword = true
                password = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The password will be removed from the Keychain on this Mac.")
        }
    }

    private var saveBar: some View {
        HStack {
            if let validationError {
                Text(verbatim: validationError)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", action: requestCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(UITestID.editorCancel)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(UITestID.editorSave)
                .disabled(draft.hostname.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(.bar)
    }

    private var generalSection: some View {
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
    }

    private var authenticationSection: some View {
        Section("Authentication") {
            Picker("Method", selection: $draft.authMethod) {
                Text("Automatic (ssh config / agent)").tag(AuthMethod.automatic)
                Text("Private Key").tag(AuthMethod.publicKey)
                Text("Password").tag(AuthMethod.password)
            }
            publicKeyGuidance
            if draft.authMethod == .publicKey {
                identityPicker
            }
            if draft.authMethod == .password {
                SecureField("Password", text: $password, prompt: Text("Stored in Keychain"))
                Text("Password stays in the Keychain on this Mac and is not synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if storedPasswordExists && !removeStoredPassword {
                    Button("Remove Saved Password") { showingRemovePassword = true }
                }
                if removeStoredPassword {
                    Text("The saved password will be removed when you save.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var identityPicker: some View {
        if !discoveredPairs.isEmpty {
            Picker("Key File", selection: $keyPicker) {
                Text("Choose a key").tag("")
                ForEach(discoveredPairs) { key in
                    Text(verbatim: key.pickerLabel).tag(key.privatePath)
                }
                Text("Other File…").tag(otherKeySentinel)
            }
            .accessibilityIdentifier(UITestID.editorKeyPicker)
        }
        HStack {
            TextField(
                "Key File",
                text: Binding(
                    get: { draft.identityFile ?? "" },
                    set: { draft.identityFile = $0.isEmpty ? nil : $0 }
                ), prompt: Text(verbatim: "~/.ssh/id_ed25519")
            )
            .accessibilityIdentifier(UITestID.editorIdentity)
            Button("Choose…", action: chooseKeyFile)
        }
        ForEach(identityNotices, id: \.self) { notice in
            Text(verbatim: identityCaption(notice))
                .font(.caption)
                .foregroundStyle(notice == .switchedFromPublicKey ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSection: some View {
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
            if let jumpIssue = currentJumpIssue {
                Text(verbatim: jumpIssueText(jumpIssue))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
            if SSHCommandBuilder.startupCommandLooksLikeSecret(draft.startupCommand) {
                Text(LocalizedStringKey(startupSecretWarning))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Agent Forwarding", isOn: $draft.forwardAgent)
                .accessibilityIdentifier(UITestID.editorForwardAgent)
            Text("Adds -o ForwardAgent=yes so the remote host can use your local agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            extraOptionsEditor
            portForwards
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private var extraOptionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SSH Options")
                .font(.callout)
            Text(LocalizedStringKey(extraOptionHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($optionDrafts) { $row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("Key", text: $row.key, prompt: Text(verbatim: "ServerAliveInterval"))
                            .accessibilityIdentifier(UITestID.editorOptionKey)
                        TextField("Value", text: $row.value, prompt: Text(verbatim: "30"))
                            .accessibilityIdentifier(UITestID.editorOptionValue)
                        Button("Delete", role: .destructive) {
                            optionDrafts.removeAll { $0.id == row.id }
                        }
                    }
                    if case .reject(let reason) = SSHCommandBuilder.normalizeExtraOption(key: row.key, value: row.value) {
                        Text(verbatim: reason.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button("Add Option") { optionDrafts.append(OptionDraft()) }
                .accessibilityIdentifier(UITestID.editorAddOption)
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
            ForEach(privilegedPorts, id: \.self) { port in
                Text(verbatim: L10n.format("Port %lld is privileged. Binding it may need extra permission.", Int64(port)))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Add Forward") {
                forwardDraft = PortForward(
                    kind: .local, listenPort: 8080, destinationHost: "127.0.0.1", destinationPort: 80)
            }
            .accessibilityIdentifier(UITestID.editorAddForward)
        }
    }

    private var privilegedPorts: [Int] {
        var seen = Set<Int>()
        return HostSafeguards.portForwardIssues(draft.portForwards).compactMap { issue in
            guard case .privileged(let port) = issue, seen.insert(port).inserted else { return nil }
            return port
        }
    }

    private var currentJumpIssue: HostSafeguards.JumpIssue? {
        let nodes = otherHosts.map { HostSafeguards.JumpNode(hostname: $0.hostname, jumpHost: $0.jumpHost) }
        return HostSafeguards.jumpIssue(hostname: draft.hostname, jumpHost: draft.jumpHost, others: nodes)
    }

    private var isDirty: Bool {
        if !password.isEmpty || removeStoredPassword { return true }
        if portText != (baseline.port.map(String.init) ?? "") { return true }
        if tagsText != HostInputParser.formatTags(baseline.tags) { return true }
        let options = optionDrafts.map { SSHOption(key: $0.key, value: $0.value) }
        return draft.label != baseline.label || draft.hostname != baseline.hostname || draft.username != baseline.username
            || draft.groupID != baseline.groupID || draft.isFavorite != baseline.isFavorite
            || draft.authMethod != baseline.authMethod || draft.identityFile != baseline.identityFile
            || draft.jumpHost != baseline.jumpHost || draft.startupCommand != baseline.startupCommand
            || draft.forwardAgent != baseline.forwardAgent || draft.notes != baseline.notes
            || draft.portForwards != baseline.portForwards || options != baseline.extraOptions
    }

    private func requestCancel() {
        if isDirty { showingDiscard = true } else { dismiss() }
    }

    private func applyJump(from host: SSHHost) {
        guard host.id != draft.id, let spec = JumpHostSpec.specification(for: host) else { return }
        let current = (draft.jumpHost ?? "").trimmingCharacters(in: .whitespaces)
        draft.jumpHost = current.isEmpty ? spec : current + "," + spec
    }

    @ViewBuilder
    private var publicKeyGuidance: some View {
        if discoveredPubs.isEmpty {
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
        }
        if draft.authMethod == .publicKey {
            Button("Install Public Key in Terminal…") { showingCopyConfirm = true }
                .disabled(draft.hostname.trimmingCharacters(in: .whitespaces).isEmpty || (draft.identityFile ?? "").isEmpty)
        }
    }

    private func prepare() {
        let directory = UITestLaunch.sshDirectory.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        discoveredPubs = PublicKeyOnboarding.candidates(fileNames: names, directory: directory)
        discoveredPairs = SSHKeyDiscovery.pairs(
            fileNames: names,
            directory: directory,
            readFile: { path in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                return String(data: data, encoding: .utf8)
            },
            privateKeyExists: { FileManager.default.fileExists(atPath: $0) }
        )
        let isNew = draft.hostname.isEmpty && draft.label.isEmpty && draft.authMethod == .automatic
        if isNew, let preferred = discoveredPairs.first(where: { $0.fileName == "id_ed25519" }) ?? discoveredPairs.first {
            draft.authMethod = .publicKey
            draft.identityFile = preferred.privatePath
            keyPicker = preferred.privatePath
        } else if let path = draft.identityFile, discoveredPairs.contains(where: { $0.privatePath == path }) {
            keyPicker = path
        }
        refreshIdentity(draft.identityFile)
        let account = KeychainService.account(hostID: draft.id, kind: .password)
        storedPasswordExists = (try? keychain.get(account: account)) != nil
    }

    private func refreshIdentity(_ raw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            identityNotices = []
            return
        }
        let result = SSHKeyDiscovery.inspect(
            path: raw,
            homeDirectory: NSHomeDirectory(),
            privateKeyExists: { FileManager.default.fileExists(atPath: $0) },
            privateKeyMode: { path in
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return (attrs?[.posixPermissions] as? NSNumber)?.uint16Value
            }
        )
        identityNotices = result.notices
        if result.path != raw {
            draft.identityFile = result.path
            return
        }
        if discoveredPairs.contains(where: { $0.privatePath == result.path }), keyPicker != result.path {
            keyPicker = result.path
        }
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
        panel.directoryURL = UITestLaunch.sshDirectory
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    private func save() {
        if !password.isEmpty && storedPasswordExists && !removeStoredPassword {
            showingReplacePassword = true
            return
        }
        commitSave()
    }

    private func commitSave() {
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

        var options: [SSHOption] = []
        for row in optionDrafts {
            switch SSHCommandBuilder.normalizeExtraOption(key: row.key, value: row.value) {
            case .drop:
                continue
            case .accept(let option):
                options.append(option)
            case .reject(let reason):
                fail(reason.message, field: .extraOptions)
                return
            }
        }
        host.extraOptions = options

        if let issue = HostSafeguards.jumpIssue(
            hostname: host.hostname,
            jumpHost: host.jumpHost,
            others: otherHosts.map { HostSafeguards.JumpNode(hostname: $0.hostname, jumpHost: $0.jumpHost) }
        ) {
            fail(jumpIssueText(issue), field: .jumpHost)
            return
        }
        if let duplicate = HostSafeguards.portForwardIssues(host.portForwards).compactMap({ issue -> Int? in
            if case .duplicateListen(let port) = issue { return port }
            return nil
        }).first {
            fail(L10n.format("Listen port %lld is used more than once.", Int64(duplicate)), field: .portForwards)
            return
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

        do {
            _ = try SSHCommandBuilder().argv(for: host)
        } catch let error as SSHCommandError {
            fail(error.message, field: error.field)
            return
        } catch {
            fail(error.localizedDescription, field: nil)
            return
        }

        let account = KeychainService.account(hostID: host.id, kind: .password)
        if removeStoredPassword {
            try? keychain.delete(account: account)
        } else if host.authMethod == .password, !password.isEmpty {
            do {
                try keychain.set(password, account: account)
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

    private func jumpIssueText(_ issue: HostSafeguards.JumpIssue) -> String {
        switch issue {
        case .referencesSelf:
            return String(localized: "Jump host cannot be this host.")
        case .cycle:
            return String(localized: "Jump hosts form a cycle.")
        }
    }

    private func identityCaption(_ notice: SSHIdentityInspection.Notice) -> String {
        switch notice {
        case .switchedFromPublicKey:
            return String(localized: "Using the matching private key instead of the .pub file.")
        case .missingPrivateKey:
            return String(localized: "This private key file is missing. ssh will not be able to use it.")
        case .permissionsTooOpen:
            return String(localized: permissionsWarning)
        }
    }
}

private struct OptionDraft: Identifiable, Equatable {
    var id = UUID()
    var key = ""
    var value = ""
}

private let extraOptionHint =
    "Keepalive and ControlMaster are best set in ~/.ssh/config. Options here apply only to this host."
private let startupSecretWarning =
    "Startup command looks like it contains a password. It is stored in the hosts file, not the Keychain."
private let permissionsWarning =
    "This private key is readable by the group or by other users. ssh refuses keys whose permissions are broader than 0600."
private let copyIDConfirmText = """
    MenuSSH will open your terminal and run ssh-copy-id there. \
    You confirm the login in that window. It is never run in the background.
    """

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
                    .accessibilityIdentifier(UITestID.forwardKind)
                    TextField("Bind Address", text: $bindAddress, prompt: Text(verbatim: "127.0.0.1"))
                    TextField("Listen Port", text: $listenPort, prompt: Text(verbatim: "8080"))
                        .accessibilityIdentifier(UITestID.forwardListen)
                    if kind == .dynamic {
                        Text("Dynamic forwards do not use a destination host or port.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
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
                    .accessibilityIdentifier(UITestID.forwardCancel)
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
