// Tests/ErgoptiPlusTests/OwnedProgramForwardingTests.swift
// Real signed-role/native-child regressions for receipt forwarding, executed
// by the macOS launcher lane beside OwnedProgramWorkerTests.

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedProgramForwardingTests: XCTestCase {
	static func launcherExecutable() throws -> URL {
		let products = Bundle(for: OwnedProgramForwardingTests.self).bundleURL.deletingLastPathComponent()
		let candidates = [products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
		guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
			XCTFail("the real native ErgoptiPlus SwiftPM executable is required")
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
		}
		return executable
	}

	// 28 October audit lead: a terminal receipt the bridge could not forward
	// still set its verified terminal, so it exited 0 having delivered nothing.
	func testRefusedReceiptForwardingNeverReportsSuccess() throws {
		let session = try OwnedProgramTestSession(executable: OwnedProgramForwardingTests.launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "argv", "@FIXTURE_DIR@/must-not-exist.json",
		])
		try session.wait { session.markers.contains("V1 HELD") }
		try session.closeOutput()
		try session.send("CANCEL")
		try session.closeInput()
		let deadline = Date().addingTimeInterval(10)
		while session.process.isRunning && Date() < deadline { usleep(1_000) }
		if session.process.isRunning { session.process.terminate() }
		session.process.waitUntilExit()
		XCTAssertEqual(session.process.terminationReason, .exit)
		XCTAssertEqual(session.process.terminationStatus, 70,
			"a terminal receipt the caller never received must not become exit 0")
		XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("must-not-exist.json").path))
		try FileManager.default.removeItem(at: session.directory)
	}
}
