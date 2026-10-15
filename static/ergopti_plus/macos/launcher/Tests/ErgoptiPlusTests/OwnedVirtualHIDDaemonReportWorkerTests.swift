// Tests/ErgoptiPlusTests/OwnedVirtualHIDDaemonReportWorkerTests.swift
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedVirtualHIDDaemonReportWorkerTests: XCTestCase {
	func testOnlyExactHeadlessArgumentShapeRoutesToReportWorker() {
		XCTAssertTrue(OwnedVirtualHIDDaemonReportWorker.handles(arguments: ["launcher", "--virtual-hid-daemon-report-worker"]))
		for arguments in [[], ["launcher"], ["--virtual-hid-daemon-report-worker"],
			["launcher", "--virtual-hid-driver-publication-worker"],
			["launcher", "--virtual-hid-daemon-report-worker", "extra"],
			["launcher", "--virtual-hid-daemon-report-worker=1"]] {
			XCTAssertFalse(OwnedVirtualHIDDaemonReportWorker.handles(arguments: arguments))
		}
	}
	func testInvalidRoutingDoesNotAcquireNativeResources() {
		XCTAssertEqual(OwnedVirtualHIDDaemonReportWorker.run(arguments: ["launcher", "--foreign"]), 64)
	}
	func testUnavailableAndCleanupDebtExportOnlyClosedTechnicalFields() throws {
		let failures: [(OwnedVirtualHIDDaemonReportObserver.Failure, String)] = [
			(.authority, "authority"), (.endpoint, "endpoint"), (.identity, "identity"),
			(.signature, "signature"), (.transport, "transport"), (.protocolFrame, "protocolFrame"),
			(.deadline, "deadline"), (.stopped, "stopped"), (.cleanup, "cleanup")
		]
		for (failure, category) in failures {
			for (observation, state) in [
				(OwnedVirtualHIDDaemonReportObserver.Observation.unavailable(failure), "unavailable"),
				(OwnedVirtualHIDDaemonReportObserver.Observation.cleanupPending(failure), "cleanupPending")
			] {
				let bytes = OwnedVirtualHIDDaemonReportWorker.encoded(observation)
				let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: String])
				XCTAssertEqual(decoded, ["state": state, "category": category, "remoteCleanup": "unobserved"])
				XCTAssertEqual(bytes.last, 10)
			}
		}
	}
}
