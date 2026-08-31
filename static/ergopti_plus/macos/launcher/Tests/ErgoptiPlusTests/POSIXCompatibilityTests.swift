// Tests/ErgoptiPlusTests/POSIXCompatibilityTests.swift

// ==============================================================================
// MODULE: POSIX Compatibility Tests
// DESCRIPTION:
// Regression coverage for Swift SDK changes that made the prior direct flock
// and process-environment imports fail during release compilation.
//
// FEATURES & RATIONALE:
// 1. Calls the real BSD lock symbol through the compatibility wrapper.
// 2. Checks exact owned envp contents and its required nil terminator.
// 3. Observes one real child signal through kqueue NOTE_EXITSTATUS.
// ==============================================================================

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class POSIXCompatibilityTests: XCTestCase {
	/// Resolves the debug launcher product that owns the POSIX helper roles.
	private func launcherTestExecutable() throws -> URL {
		let productsDirectory = Bundle(for: POSIXCompatibilityTests.self)
			.bundleURL
			.deletingLastPathComponent()
		let candidates = [
			productsDirectory.appendingPathComponent("ErgoptiPlus"),
			productsDirectory
				.deletingLastPathComponent()
				.appendingPathComponent("ErgoptiPlus"),
		]
		guard let executable = candidates.first(where: {
			FileManager.default.isExecutableFile(atPath: $0.path)
		}) else {
			XCTFail("the real ErgoptiPlus SwiftPM product is required for the POSIX test")
			throw NSError(domain: "ErgoptiPOSIXTests", code: Int(ENOENT))
		}
		return executable
	}

	/// Proves the symbol-level wrapper still reaches BSD flock on the active SDK.
	func testFlockCompatibilityWrapperLocksAndUnlocks() throws {
		let path = FileManager.default.temporaryDirectory
			.appendingPathComponent("ergopti-flock-\(UUID().uuidString)").path
		XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
		defer { try? FileManager.default.removeItem(atPath: path) }
		let descriptor = Darwin.open(path, O_RDWR)
		guard descriptor >= 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		defer { _ = Darwin.close(descriptor) }

		XCTAssertEqual(ergoptiFlock(descriptor, LOCK_EX | LOCK_NB), 0)
		XCTAssertEqual(ergoptiFlock(descriptor, LOCK_UN), 0)
	}

	/// Proves spawn environments are owned, deterministic, and nil-terminated.
	func testEnvironmentDuplicationBuildsCStringVector() throws {
		guard let duplicated = duplicateProcessEnvironment([
			"SECOND": "two",
			"FIRST": "one",
		]) else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
		}
		defer { for case let pointer? in duplicated { free(pointer) } }

		XCTAssertEqual(duplicated.count, 3)
		XCTAssertEqual(duplicated.dropLast().compactMap { pointer in
			pointer.map { String(cString: $0) }
		}, ["FIRST=one", "SECOND=two"])
		XCTAssertNil(duplicated.last!)
	}

	/// Proves the kernel seam returns the real wait status instead of a fixed zero.
	func testProcessExitMonitorReturnsSignalWaitStatus() throws {
		let lockURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ergopti-exit-monitor-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: lockURL) }
		let process = Process()
		let readyPipe = Pipe()
		// Use the owned helper rather than assuming a system utility path exists.
		process.executableURL = try launcherTestExecutable()
		process.arguments = [kPOSIXTestHelperFlag, "hold-exclusive", lockURL.path]
		process.standardOutput = readyPipe
		process.standardError = FileHandle.nullDevice
		try process.run()
		let child = process.processIdentifier
		defer {
			if process.isRunning { _ = Darwin.kill(child, SIGKILL) }
			process.waitUntilExit()
		}
		XCTAssertEqual(readyPipe.fileHandleForReading.readData(ofLength: 1), Data([1]))
		var errorCode: Int32 = 0
		let descriptor = ergoptiOpenProcessExitMonitor(child, errorCode: &errorCode)
		XCTAssertGreaterThanOrEqual(descriptor, 0)
		XCTAssertEqual(errorCode, 0)
		guard descriptor >= 0 else { return }
		defer { _ = Darwin.close(descriptor) }

		XCTAssertEqual(Darwin.kill(child, SIGKILL), 0)
		let deadline = Date().addingTimeInterval(2)
		var rawStatus: Int32 = 0
		var readResult: Int32 = 0
		repeat {
			readResult = ergoptiReadProcessExitMonitor(
				descriptor,
				rawStatus: &rawStatus,
				errorCode: &errorCode
			)
			if readResult == 0 { usleep(1_000) }
		} while readResult == 0 && Date() < deadline

		XCTAssertEqual(readResult, 1)
		XCTAssertEqual(errorCode, 0)
		XCTAssertEqual(
			decodeEmbeddedProcessWaitStatus(rawStatus),
			.signaled(signal: SIGKILL)
		)
	}
}
