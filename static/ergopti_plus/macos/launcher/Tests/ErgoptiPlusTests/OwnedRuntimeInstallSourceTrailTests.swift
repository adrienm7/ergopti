// Tests/ErgoptiPlusTests/OwnedRuntimeInstallSourceTrailTests.swift
// Every install refusal names its case, check and line on the trail; the 2026-11-08 field install said only publish-failed-source.
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

	func testSourceRefusalNamesTheCheckThePathAndTheLine() throws {
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		// /var is a symlink on macOS and the tree refuses any symlinked ancestor. realpath, not
		// resolvingSymlinksInPath: Foundation maps /private/var back to /var (CI run 42524217610).
		guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw CaptureFailure(errno: errno) }
		let temporary = String(cString: resolved); free(resolved)
		let base = URL(fileURLWithPath: temporary, isDirectory: true)
			.appendingPathComponent("ergopti-source-trail-" + UUID().uuidString, isDirectory: true)
		let source = base.appendingPathComponent("source", isDirectory: true)
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o755])
		defer { try? FileManager.default.removeItem(at: base) }
		try Data("payload".utf8).write(to: source.appendingPathComponent("a"))
		try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "a")
		OwnedRuntimeInstallTrail.recordsRefusalsForTests = true
		defer { OwnedRuntimeInstallTrail.recordsRefusalsForTests = false }
		var thrown: Error?
		let trail = try capturedStandardError {
			do { try OwnedRuntimeInstallWorker.fixtureCopy(source: source, destination: base.appendingPathComponent("copy")) }
			catch { thrown = error }
		}
		XCTAssertEqual(thrown as? OwnedRuntimeInstallFailure, .source, "the case callers compare stays .source")
		XCTAssertTrue(trail.contains("OWNED_RUNTIME_INSTALL_TRAIL|refused-source-entry-kind-120000-links-1-link@OwnedRuntimeInstallWorker.swift:"), trail)
		XCTAssertEqual(trail.components(separatedBy: "OWNED_RUNTIME_INSTALL_TRAIL|").count - 1, 1, "one refusal, one trail line: " + trail)
		#else
		throw XCTSkip("The install worker fixtures exist only in debug test builds.")
		#endif
	}
}

extension OwnedRuntimeInstallSourceTrailTests {
	/// The resident launcher shares these owners and probes them on purpose: it never writes their refusals.
	func testOutsideTheHelperARefusalWritesNoTrail() throws {
		let trail = try capturedStandardError { _ = OwnedRuntimeInstallFailure.traced(.destination, "probe") }
		XCTAssertEqual(trail, "")
	}
}

extension OwnedRuntimeInstallSourceTrailTests {
	/// The helper runs under the private umask 077; the folders it publishes must still be readable by the user.
	func testPublishedFoldersAreReadableUnderThePrivateUmask() throws {
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw CaptureFailure(errno: errno) }
		let temporary = String(cString: resolved); free(resolved)
		let base = URL(fileURLWithPath: temporary, isDirectory: true)
			.appendingPathComponent("ergopti-published-mode-" + UUID().uuidString, isDirectory: true)
		let source = base.appendingPathComponent("source", isDirectory: true)
		try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o755])
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
		defer { try? FileManager.default.removeItem(at: base) }
		try Data("cli".utf8).write(to: source.appendingPathComponent("bin/cli"))
		let copy = base.appendingPathComponent("copy")
		// Field report 2026-11-09: under the helper's umask the published Runtime came out drwx------.
		let previous = umask(kPrivateProcessUmask)
		defer { _ = umask(previous) }
		try OwnedRuntimeInstallWorker.fixtureCopy(source: source, destination: copy)
		for folder in [copy, copy.appendingPathComponent("bin")] {
			var observed = stat()
			XCTAssertEqual(lstat(folder.path, &observed), 0, folder.path)
			XCTAssertEqual(observed.st_mode & 0o777, OwnedRuntimeInstallScratch.publishedDirectoryMode, folder.path)
		}
		#else
		throw XCTSkip("The install worker fixtures exist only in debug test builds.")
		#endif
	}
}
