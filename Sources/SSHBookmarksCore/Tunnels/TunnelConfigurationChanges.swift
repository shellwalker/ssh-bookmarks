import Foundation

public struct TunnelConfigurationChanges: Equatable, Sendable {
    public var stop: [UUID] = []
    public var restart: [UUID] = []

    public static func between(_ old: SSHHost, _ new: SSHHost) -> Self {
        var changes = Self()
        let builder = SSHCommandBuilder()
        for forward in old.portForwards where forward.kind == .local && forward.quickToggle {
            guard let replacement = new.portForwards.first(where: { $0.id == forward.id }),
                replacement.kind == .local, replacement.quickToggle
            else {
                changes.stop.append(forward.id)
                continue
            }
            let before = try? builder.tunnelArguments(for: old, forward: forward)
            let after = try? builder.tunnelArguments(for: new, forward: replacement)
            if before != after || forward.reconnect != replacement.reconnect || old.authMethod != new.authMethod {
                changes.restart.append(forward.id)
            }
        }
        return changes
    }
}
