import Foundation

/// Persist configuration first, then compensate if the credential update fails.
/// The caller keeps its editor open whenever an error is returned.
public enum HostSaveTransaction {
    public static func perform(
        updated: SSHHost, save: (SSHHost) -> String?, rollback: () -> String?,
        updateCredentials: () throws -> Void, credentialError: (Error) -> String
    ) -> String? {
        if let error = save(updated) { return error }
        do {
            try updateCredentials()
            return nil
        } catch {
            let message = credentialError(error)
            if let rollbackError = rollback() { return message + "\n" + rollbackError }
            return message
        }
    }
}
