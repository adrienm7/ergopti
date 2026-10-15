// Tests/ErgoptiPlusTests/OwnedVirtualHIDDaemonReportTests.swift
import Foundation
import XCTest
@testable import ErgoptiPlus

/// Independent vendor-wire literals. They do not execute a Root, driver or installed daemon actor.
final class OwnedVirtualHIDDaemonReportTests: XCTestCase {
	private let status = Data([0, 0, 0, 19, 4, 1, 2, 3, 4, 5, 6, 7, 8,
		1, 1, 2, 1, 3, 0, 4, 0, 5, 0])
	private let acknowledgment = Data([0, 0, 0, 9, 5, 1, 2, 3, 4, 5, 6, 7, 8])

	func testExactFiveNamedBooleansAndSameRequestAcknowledgment() throws {
		let request = try XCTUnwrap(OwnedVirtualHIDDaemonReportProtocol.decode(status))
		XCTAssertTrue(request.values.driverActivated)
		XCTAssertTrue(request.values.driverConnected)
		XCTAssertFalse(request.values.driverVersionMismatched)
		XCTAssertFalse(request.values.virtualHIDKeyboardReady)
		XCTAssertFalse(request.values.virtualHIDPointingReady)
		XCTAssertEqual(OwnedVirtualHIDDaemonReportProtocol.acknowledgment(for: request), acknowledgment)
	}
	func testEveryNamedFieldHasItsOwnIndependentPosition() throws {
		for selected in 0..<5 {
			var bytes = status
			for (index, position) in [14, 16, 18, 20, 22].enumerated() { bytes[position] = index == selected ? 1 : 0 }
			let request = try XCTUnwrap(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
			XCTAssertEqual(request.values.driverActivated, selected == 0)
			XCTAssertEqual(request.values.driverConnected, selected == 1)
			XCTAssertEqual(request.values.driverVersionMismatched, selected == 2)
			XCTAssertEqual(request.values.virtualHIDKeyboardReady, selected == 3)
			XCTAssertEqual(request.values.virtualHIDPointingReady, selected == 4)
			XCTAssertEqual(OwnedVirtualHIDDaemonReportProtocol.acknowledgment(for: request), acknowledgment)
		}
	}
	func testAllFalseIsReportedDataWithoutCompatibilityOrReadyInference() throws {
		var bytes = status
		for position in [14, 16, 18, 20, 22] { bytes[position] = 0 }
		let request = try XCTUnwrap(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
		XCTAssertFalse(request.values.driverActivated)
		XCTAssertFalse(request.values.driverConnected)
		XCTAssertFalse(request.values.driverVersionMismatched)
		XCTAssertFalse(request.values.virtualHIDKeyboardReady)
		XCTAssertFalse(request.values.virtualHIDPointingReady)
	}
	func testMismatchIsOnlyTheObservedDaemonBoolean() throws {
		var bytes = status; bytes[18] = 1
		let request = try XCTUnwrap(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
		XCTAssertTrue(request.values.driverVersionMismatched)
		XCTAssertEqual(OwnedVirtualHIDDaemonReportProtocol.acknowledgment(for: request), acknowledgment)
	}
	func testEveryTruncatedStatusIsRefused() {
		for count in 0..<status.count {
			XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(Data(status.prefix(count))), "prefix \(count)")
		}
	}
	func testAdditionalOrCombinedFramesAreRefused() {
		XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(status + Data([0])))
		XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(status + status))
	}
	func testWrongLengthAndMessageTypesAreRefused() {
		for position in 0..<5 {
			var bytes = status; bytes[position] = 255
			XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
		}
		for type in [UInt8(0), 1, 2, 3, 5, 255] {
			var bytes = status; bytes[4] = type
			XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
		}
	}
	func testDuplicateMissingUnknownAndReorderedTagsAreRefused() {
		for position in [13, 15, 17, 19, 21] {
			for tag in [UInt8(0), 6, 255] {
				var bytes = status; bytes[position] = tag
				XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
			}
		}
		var duplicate = status; duplicate[15] = 1
		XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(duplicate))
		var reordered = status; reordered[13] = 2; reordered[15] = 1
		XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(reordered))
	}
	func testNonBooleanBytesCannotBeCoerced() {
		for position in [14, 16, 18, 20, 22] {
			for value in [UInt8(2), 255] {
				var bytes = status; bytes[position] = value
				XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
			}
		}
	}
	func testRequestIdentifierIsCopiedWithoutChoosingAnotherRequestOrHIDPayload() throws {
		var bytes = status; bytes.replaceSubrange(5..<13, with: [8, 7, 6, 5, 4, 3, 2, 1])
		let request = try XCTUnwrap(OwnedVirtualHIDDaemonReportProtocol.decode(bytes))
		let expected = Data([0, 0, 0, 9, 5, 8, 7, 6, 5, 4, 3, 2, 1])
		XCTAssertEqual(OwnedVirtualHIDDaemonReportProtocol.acknowledgment(for: request), expected)
		XCTAssertEqual(expected.count, 13)
		XCTAssertEqual(expected[4], 5)
	}
	func testHeartbeatIsExactControlDataAndNeverAReport() {
		let heartbeat = Data([0, 0, 0, 1, 0])
		XCTAssertTrue(OwnedVirtualHIDDaemonReportProtocol.isHeartbeat(heartbeat))
		XCTAssertNil(OwnedVirtualHIDDaemonReportProtocol.decode(heartbeat))
		XCTAssertFalse(OwnedVirtualHIDDaemonReportProtocol.isHeartbeat(heartbeat + Data([0])))
		for index in 0..<heartbeat.count {
			var bytes = heartbeat; bytes[index] = 255
			XCTAssertFalse(OwnedVirtualHIDDaemonReportProtocol.isHeartbeat(bytes))
		}
	}
	func testAdmissionOnTheRealMainTestThreadIsUnavailableWithoutNativeAcquisition() {
		XCTAssertTrue(Thread.isMainThread, "this constructor control requires the actual main XCTest thread")
		let owner = OwnedVirtualHIDDaemonReportObserver.acquire()
		switch owner.observe() {
		case .unavailable(.authority): break
		default: XCTFail("a main-thread constructor cannot acquire a Root report")
		}
		XCTAssertTrue(owner.retired())
		XCTAssertTrue(owner.retire())
	}
}
