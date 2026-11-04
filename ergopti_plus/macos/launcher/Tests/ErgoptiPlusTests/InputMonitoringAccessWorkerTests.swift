// Tests/ErgoptiPlusTests/InputMonitoringAccessWorkerTests.swift
// The Input Monitoring reader answers from IOHIDCheckAccess only (ledger L32).

import IOKit.hid
import XCTest
@testable import ErgoptiPlus

final class InputMonitoringAccessWorkerTests: XCTestCase {
	func testMapsEveryIOKitVerdictOntoAClosedAnswer() {
		XCTAssertEqual(inputMonitoringAccess(from: kIOHIDAccessTypeGranted), .granted)
		XCTAssertEqual(inputMonitoringAccess(from: kIOHIDAccessTypeDenied), .denied)
		XCTAssertEqual(inputMonitoringAccess(from: kIOHIDAccessTypeUnknown), .unknown)
	}

	func testRefusesEveryOtherArgumentListWithoutReadingTheGrant() {
		var reads = 0
		let check: (IOHIDRequestType) -> IOHIDAccessType = { _ in reads += 1; return kIOHIDAccessTypeGranted }
		for arguments in [["ErgoptiPlus", "--input-monitoring"], ["ErgoptiPlus", "--input-monitoring", "request"],
			["ErgoptiPlus", "--input-monitoring", "status", "extra"]] {
			XCTAssertEqual(InputMonitoringAccessWorker.run(arguments: arguments, check: check), 64)
		}
		XCTAssertEqual(reads, 0, "a malformed role reads nothing")
	}

	func testReadsOnlyTheListenEventGrant() {
		var asked: [IOHIDRequestType] = []
		let status = InputMonitoringAccessWorker.run(
			arguments: ["ErgoptiPlus", InputMonitoringAccessWorker.flag, "status"],
			check: { request in asked.append(request); return kIOHIDAccessTypeDenied })
		XCTAssertEqual(status, 0)
		XCTAssertEqual(asked, [kIOHIDRequestTypeListenEvent])
	}

	func testDispatchesOnlyItsOwnFlag() {
		XCTAssertTrue(InputMonitoringAccessWorker.handles(arguments: ["ErgoptiPlus", "--input-monitoring", "status"]))
		XCTAssertFalse(InputMonitoringAccessWorker.handles(arguments: ["ErgoptiPlus", "--login-startup", "status"]))
		XCTAssertFalse(InputMonitoringAccessWorker.handles(arguments: ["ErgoptiPlus"]))
	}
}
