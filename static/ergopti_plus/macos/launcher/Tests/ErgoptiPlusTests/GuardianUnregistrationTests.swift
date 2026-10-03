// Tests/ErgoptiPlusTests/GuardianUnregistrationTests.swift
// Exercise native receipts without changing the test user's Background Items.

import Darwin
import Foundation
import ServiceManagement
import XCTest
@testable import ErgoptiPlus

@available(macOS 13.0, *)
private final class UnregistrationService: RemapGuardianUnregisteringService {
	var status: SMAppService.Status
	var after: SMAppService.Status
	var calls = 0
	var refuses = false

	init(_ status: SMAppService.Status, after: SMAppService.Status = .notRegistered) {
		self.status = status
		self.after = after
	}

	func unregister() throws {
		calls += 1
		if refuses { throw NSError(domain: "test", code: 1) }
		status = after
	}
}

final class GuardianUnregistrationTests: XCTestCase {
	private let executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
	private let environment = ["ERGOPTI_LAUNCHER_DEVICE": "11", "ERGOPTI_LAUNCHER_INODE": "22"]
	private let identity = LeaseExecutableIdentity(device: "11", inode: "22")

	func testUnregisterDispatchIsHeadlessAndIdentityPrecedesEffects() {
		XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: [executable, kUnregisterRemapGuardianFlag]))
		var effects = 0
		let code = runGuardianUnregistration(
			arguments: [executable, kUnregisterRemapGuardianFlag], executablePath: executable,
			environment: environment, identityReader: { _ in nil },
			unregister: { _ in effects += 1; return .unregistered },
			writeResult: { _ in effects += 1; return true }
		)
		XCTAssertEqual(code, LeaseWorkerExit.invalidArguments.rawValue)
		XCTAssertEqual(effects, 0)
	}

	func testUnregisterPublishesStrictNativeReceiptAndRejectsOutputLoss() {
		for result in [RemapGuardianUnregistrationResult.unregistered, .refused] {
			var output = Data()
			var paths: [String] = []
			let code = runGuardianUnregistration(
				arguments: [executable, kUnregisterRemapGuardianFlag], executablePath: executable,
				environment: environment, identityReader: { _ in self.identity },
				unregister: { paths.append($0); return result },
				writeResult: { output.append($0); return true }
			)
			XCTAssertEqual(code, 0)
			XCTAssertEqual(paths, [executable])
			XCTAssertEqual(output, Data((result.rawValue + "\n").utf8))
		}
		XCTAssertEqual(runGuardianUnregistration(
			arguments: [executable, kUnregisterRemapGuardianFlag], executablePath: executable,
			environment: environment, identityReader: { _ in self.identity },
			unregister: { _ in .unregistered }, writeResult: { _ in false }
		), LeaseWorkerExit.innerFailed.rawValue)
	}

	@available(macOS 13.0, *)
	func testModernRemovalRequiresReadbackAndPreservesRefusal() {
		for before in [SMAppService.Status.enabled, .requiresApproval] {
			for after in [SMAppService.Status.notRegistered, .notFound, .enabled, .requiresApproval] {
				let service = UnregistrationService(before, after: after)
				XCTAssertEqual(unregisterModernRemapGuardian(service: service),
					after == .notRegistered || after == .notFound)
				XCTAssertEqual(service.calls, 1)
			}
			let service = UnregistrationService(before)
			service.refuses = true
			XCTAssertFalse(unregisterModernRemapGuardian(service: service))
			XCTAssertEqual(service.status, before)
		}
		for absent in [SMAppService.Status.notRegistered, .notFound] {
			let service = UnregistrationService(absent)
			XCTAssertTrue(unregisterModernRemapGuardian(service: service))
			XCTAssertEqual(service.calls, 0)
		}
	}

	func testEveryRemovalBoundaryRefusesWithoutSkippingSafetyOrder() {
		let expected = ["records", "legacy", "modern", "exit", "records"]
		for refusedIndex in 0...expected.count {
			var calls: [String] = []
			func observe(_ label: String) -> Bool {
				calls.append(label)
				return calls.count != refusedIndex
			}
			let result = performRemapGuardianUnregistration(
				leasesAreEmpty: { observe("records") }, removeLegacy: { observe("legacy") },
				unregisterModern: { observe("modern") }, guardianHasExited: { observe("exit") }
			)
			XCTAssertEqual(result, refusedIndex == 0 ? .unregistered : .refused)
			XCTAssertEqual(calls, refusedIndex == 0 ? expected : Array(expected.prefix(refusedIndex)))
		}
	}

	func testRecordObservationDoesNotCreateOrFollowNamespace() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		XCTAssertTrue(remapGuardianLeaseRecordsAreEmpty(paths))
		XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
		try FileManager.default.createDirectory(atPath: paths.records, withIntermediateDirectories: true)
		XCTAssertTrue(remapGuardianLeaseRecordsAreEmpty(paths))
		let record = paths.records + "/foreign"
		try Data("retained".utf8).write(to: URL(fileURLWithPath: record))
		XCTAssertFalse(remapGuardianLeaseRecordsAreEmpty(paths))
		XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record)), Data("retained".utf8))
		try FileManager.default.removeItem(atPath: paths.records)
		let target = home.appendingPathComponent("foreign")
		try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(atPath: paths.records, withDestinationPath: target.path)
		XCTAssertFalse(remapGuardianLeaseRecordsAreEmpty(paths))
	}

	/// Calls the production POSIX port without creating or removing any job.
	func testNativeLaunchctlDistinguishesAbsentJobFromExecutionFailure() {
		let missing = "gui/\(getuid())/com.ergoptiplus.test-missing-" + UUID().uuidString
		XCTAssertEqual(PosixGuardianLaunchctlRunner().exitStatus(arguments: ["print", missing]),
			kGuardianLaunchctlUnknownServiceStatus)
	}

	func testBoundedReceiptWaitAllowsFinalExitAndRefusesPersistentDebt() {
		var clock: TimeInterval = 0
		XCTAssertTrue(waitForRemapGuardianUnregistrationObservation(
			observe: { clock == 2 }, now: { clock }, pause: { clock += 1 }, timeout: 3
		))
		XCTAssertEqual(clock, 2)
		XCTAssertFalse(waitForRemapGuardianUnregistrationObservation(
			observe: { false }, now: { clock }, pause: { clock += 1 }, timeout: 3
		))
		XCTAssertEqual(clock, 5)
	}
}
