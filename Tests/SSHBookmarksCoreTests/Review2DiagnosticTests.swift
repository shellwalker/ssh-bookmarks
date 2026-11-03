import Foundation
import XCTest

@testable import SSHBookmarksCore

final class Review2DiagnosticTests: XCTestCase {
    func testDiagnosticExportReportsWriteFailureAndCanRetry() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = Data("zip payload".utf8)
        XCTAssertThrowsError(try DiagnosticBundle.write(data, to: root))
        let output = root.appendingPathComponent("diagnostics.zip")
        try DiagnosticBundle.write(data, to: output)
        XCTAssertEqual(try Data(contentsOf: output), data)
    }

    func testReviewStringsHaveEnglishAndChineseTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let keys = ["example.com or ssh-config alias", "Failed to compile AppleScript", "Failed to export diagnostics"]
        for language in ["en", "zh-Hans"] {
            let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let data = try Data(contentsOf: url)
            let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(values[key], key)
                XCTAssertFalse(value.isEmpty)
                if language == "zh-Hans" { XCTAssertNotEqual(value, key) }
            }
        }
    }
}
