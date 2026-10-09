// Tests/ErgoptiPlusTests/GuardianRegistrationTests.swift
// Verify headless registration without changing the test user's background items.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class GuardianRegistrationTests: XCTestCase {
	private let executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
	private let environment = ["ERGOPTI_LAUNCHER_DEVICE": "11", "ERGOPTI_LAUNCHER_INODE": "22"]
	private let identity = LeaseExecutableIdentity(device: "11", inode: "22")

	/// This role must branch before the application bootstrap or Sparkle startup.
	func testRegistrationCommandIsHeadless() {
		XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: [executable, "--register-remap-guardian"]))
	}

	/// Approval and unavailable statuses must reach the caller without becoming ready.
	func testRegistrationPreservesEveryNativeStatus() {
		for status in [RemapGuardianRegistrationStatus.ready, .requiresApproval, .unavailable] {
			var paths: [String] = []
			var output = Data()
			let code = runGuardianRegistration(
				arguments: [executable, kRegisterRemapGuardianFlag],
				executablePath: executable, environment: environment,
				identityReader: { _ in self.identity },
				register: { paths.append($0); return status },
				writeResult: { output.append($0); return true }
			)
			XCTAssertEqual(code, 0)
			XCTAssertEqual(paths, [executable])
			XCTAssertEqual(String(data: output, encoding: .utf8), status.rawValue + "\n")
		}
	}

	/// Invalid commands must neither register a service nor publish a status.
	func testRegistrationRejectsInvalidIdentityBeforeSideEffects() {
		let valid = [executable, kRegisterRemapGuardianFlag]
		let cases: [([String], String?, [String: String], LeaseExecutableIdentity?)] = [
			([executable], executable, environment, identity),
			(valid + ["extra"], executable, environment, identity),
			([executable, kRemapGuardianStatusFlag], executable, environment, identity),
			(valid, nil, environment, identity),
			(valid, "relative", environment, identity),
			(valid, executable, [:], identity),
			(valid, executable, environment, nil),
			(valid, executable, environment, LeaseExecutableIdentity(device: "11", inode: "23")),
		]
		for (arguments, path, values, observed) in cases {
			var effects = 0
			let code = runGuardianRegistration(
				arguments: arguments, executablePath: path, environment: values,
				identityReader: { _ in observed },
				register: { _ in effects += 1; return .ready },
				writeResult: { _ in effects += 1; return true }
			)
			XCTAssertEqual(code, 64)
			XCTAssertEqual(effects, 0)
		}
	}

	/// A lost status write cannot acknowledge successful command delivery.
	func testRegistrationReportsOutputFailure() {
		let code = runGuardianRegistration(
			arguments: [executable, kRegisterRemapGuardianFlag],
			executablePath: executable, environment: environment,
			identityReader: { _ in self.identity }, register: { _ in .ready },
			writeResult: { _ in false }
		)
		XCTAssertEqual(code, LeaseWorkerExit.innerFailed.rawValue)
	}
}
