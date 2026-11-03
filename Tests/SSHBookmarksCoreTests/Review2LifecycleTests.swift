import Foundation
import XCTest

@testable import SSHBookmarksCore

final class Review2LifecycleTests: XCTestCase {
    func testExitDrainsStderrBeforeClassifying() throws {
        let pipe = Pipe()
        let capture = TunnelStderrCapture(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("Permission denied (publickey).".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(TunnelFailureClassifier.classify(stderr: capture.finish(), exitCode: 255), .authentication)
    }

    func testStderrCaptureRetainsBoundedTail() throws {
        let pipe = Pipe()
        let capture = TunnelStderrCapture(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data(String(repeating: "x", count: 3000).utf8))
        try pipe.fileHandleForWriting.write(contentsOf: Data("Host key verification failed".utf8))
        try pipe.fileHandleForWriting.close()
        let tail = capture.finish()
        XCTAssertLessThanOrEqual(tail.utf8.count, 2048)
        XCTAssertEqual(TunnelFailureClassifier.classify(stderr: tail), .hostKeyNew)
    }

    func testRelaunchHelperWaitsUntilOriginalProcessExits() throws {
        let original = try Review2Process.start("/bin/sleep", ["5"])
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let helper = try Review2Process.start(
            "/bin/sh",
            [
                "-c", AppRelaunchScript.contents.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/touch"),
                marker.path, String(original),
            ])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        Review2Process.terminate(original)
        _ = Review2Process.wait(original)
        XCTAssertEqual(Review2Process.wait(helper), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRelaunchWaitsForPIDWithBoundedDeadline() {
        let script = AppRelaunchScript.contents
        XCTAssertTrue(script.contains("kill -0"))
        XCTAssertTrue(script.contains("sleep 0.2"))
        XCTAssertTrue(script.contains("50"))
        XCTAssertTrue(script.contains("exit 1"))
        XCTAssertTrue(script.contains("/usr/bin/open"))
    }
}
