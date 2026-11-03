import Foundation
import XCTest

@testable import SSHBookmarksCore

final class LocalizedCountTests: XCTestCase {
    func testDiagnosticsCounts() {
        for count in [0, 1, 2] {
            let key = LocalizedCount.diagnosticSummaryKey(count: count)
            XCTAssertEqual(String(format: key, Int64(count), "Zero KB"), "\(count) \(count == 1 ? "file" : "files") · Zero KB")
        }
    }

    func testImportCountsVaryIndependently() {
        for imported in [0, 1, 2] {
            for skipped in [0, 1, 2] {
                let key = LocalizedCount.importSummaryKey(imported: imported, skipped: skipped)
                XCTAssertEqual(
                    String(format: key, Int64(imported), Int64(skipped)),
                    "Imported \(imported) \(imported == 1 ? "host" : "hosts"). Skipped \(skipped) \(skipped == 1 ? "duplicate" : "duplicates")."
                )
            }
        }
    }
    func testLocalizedResourcesAndUngroupedPorts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["en", "zh-Hans"] {
            let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let strings = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            for count in [0, 1, 2] {
                let key = LocalizedCount.diagnosticSummaryKey(count: count)
                let translated = try XCTUnwrap(strings[key])
                let expected = language == "en" ? "\(count) \(count == 1 ? "file" : "files") · KB" : "\(count) 个文件 · KB"
                XCTAssertEqual(String(format: translated, Int64(count), "KB"), expected)
                for skipped in [0, 1, 2] {
                    let importKey = LocalizedCount.importSummaryKey(imported: count, skipped: skipped)
                    let translation = try XCTUnwrap(strings[importKey])
                    if language == "zh-Hans" {
                        XCTAssertEqual(
                            String(format: translation, Int64(count), Int64(skipped)),
                            "已导入 \(count) 个站点。已跳过 \(skipped) 个重复项。")
                    } else {
                        XCTAssertEqual(translation, importKey)
                    }
                }
            }
            for key in [
                "Local port %@ is already in use", "No permission to listen on port %@",
                "Listen on privileged port %@?", "Listen port %@ is used more than once.",
                "Port %@ is privileged. Binding it may need extra permission.",
            ] {
                let translated = try XCTUnwrap(strings[key])
                for locale in ["en_US", "de_DE", "zh_CN"] {
                    let message = String(format: translated, locale: Locale(identifier: locale), arguments: [String(15432)])
                    XCTAssertTrue(message.contains("15432"), message)
                    XCTAssertFalse(message.contains("15,432"), message)
                    XCTAssertFalse(message.contains("15.432"), message)
                }
            }
        }
    }
}
