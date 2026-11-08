// Tests/ErgoptiPlusTests/OwnedRuntimeInstallSourceTrailTests.swift
// A `.source` install refusal names its check on the trail; the 2026-11-08 field install said only publish-failed-source.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeInstallSourceTrailTests: XCTestCase {
	private struct CaptureFailure: Error { let errno: Int32 }
	/// Runs `body` with the process's standard error redirected into a pipe and returns what it wrote.
	private func capturedStandardError(_ body: () -> Void) throws -> String {
		var ends: [Int32] = [-1, -1]
		guard pipe(&ends) == 0 else { throw CaptureFailure(errno: errno) }
		let saved = dup(STDERR_FILENO)
		guard saved >= 0, dup2(ends[1], STDERR_FILENO) >= 0 else {
			let failure = CaptureFailure(errno: errno); Darwin.close(ends[0]); Darwin.close(ends[1]); throw failure
		}
		Darwin.close(ends[1])
		body()
		dup2(saved, STDERR_FILENO); Darwin.close(saved)
		var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = Darwin.read(ends[0], &buffer, buffer.count)
			if count <= 0 { break }
			output.append(contentsOf: buffer.prefix(count))
		}
		Darwin.close(ends[0])
		return String(decoding: output, as: UTF8.self)
	}

	func testSourceRefusalNamesTheCheckAndTheRelativePath() throws {
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		// /var is a symlink on macOS and the tree refuses any symlinked ancestor.
		let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
			.appendingPathComponent("ergopti-source-trail-" + UUID().uuidString, isDirectory: true)
		let source = base.appendingPathComponent("source", isDirectory: true)
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o755])
		defer { try? FileManager.default.removeItem(at: base) }
		try Data("payload".utf8).write(to: source.appendingPathComponent("a"))
		try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "a")
		var thrown: Error?
		let trail = try capturedStandardError {
			do { try OwnedRuntimeInstallWorker.fixtureCopy(source: source, destination: base.appendingPathComponent("copy")) }
			catch { thrown = error }
		}
		XCTAssertEqual(thrown as? OwnedRuntimeInstallFailure, .source, "the case callers compare stays .source")
		XCTAssertTrue(trail.contains("OWNED_RUNTIME_INSTALL_TRAIL|source-entry-kind-120000-links-1-link\n"), trail)
		#else
		throw XCTSkip("The install worker fixtures exist only in debug test builds.")
		#endif
	}
}
