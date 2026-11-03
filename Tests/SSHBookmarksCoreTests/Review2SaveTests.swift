import XCTest

@testable import SSHBookmarksCore

final class Review2SaveTests: XCTestCase {
    func testCredentialFailureRestoresSavedHost() {
        let baseline = SSHHost(label: "test", hostname: "old.example")
        var updated = baseline
        updated.hostname = "new.example"
        var stored = baseline
        var saves: [String] = []
        let error = HostSaveTransaction.perform(
            updated: updated,
            save: { host in
                stored = host; saves.append(host.hostname); return nil
            },
            rollback: {
                stored = baseline; saves.append(baseline.hostname); return nil
            },
            updateCredentials: { throw CocoaError(.fileWriteNoPermission) },
            credentialError: { _ in "keychain failed" })
        XCTAssertEqual(error, "keychain failed")
        XCTAssertEqual(stored, baseline)
        XCTAssertEqual(saves, ["new.example", "old.example"])
    }

    func testNewHostCredentialFailureRemovesDraftInsteadOfSavingEmptyBaseline() {
        let host = SSHHost(label: "new", hostname: "server")
        var stored: SSHHost?
        let error = HostSaveTransaction.perform(
            updated: host,
            save: {
                stored = $0; return nil
            },
            rollback: {
                stored = nil; return nil
            },
            updateCredentials: { throw CocoaError(.fileWriteNoPermission) },
            credentialError: { _ in "keychain failed" })
        XCTAssertEqual(error, "keychain failed")
        XCTAssertNil(stored)
    }

    func testSaveFailureDoesNotTouchCredentials() {
        let host = SSHHost(label: "test", hostname: "server")
        var touched = false
        let error = HostSaveTransaction.perform(
            updated: host, save: { _ in "save failed" },
            rollback: {
                XCTFail("unexpected rollback"); return nil
            },
            updateCredentials: { touched = true }, credentialError: { _ in "keychain failed" })
        XCTAssertEqual(error, "save failed")
        XCTAssertFalse(touched)
    }

    func testRollbackFailureIsReportedAndSuccessKeepsNewHost() {
        let host = SSHHost(label: "test", hostname: "server")
        var count = 0
        let error = HostSaveTransaction.perform(
            updated: host,
            save: { _ in
                count += 1; return count == 1 ? nil : "rollback failed"
            },
            rollback: {
                count += 1; return "rollback failed"
            },
            updateCredentials: { throw CocoaError(.fileWriteNoPermission) },
            credentialError: { _ in "keychain failed" })
        XCTAssertEqual(error, "keychain failed\nrollback failed")
        XCTAssertNil(
            HostSaveTransaction.perform(
                updated: host, save: { _ in nil },
                rollback: {
                    XCTFail("unexpected rollback"); return nil
                },
                updateCredentials: {}, credentialError: { _ in "unexpected" }))
    }
}
