// Tests/ErgoptiPlusTests/OwnedVirtualHIDDaemonReportMainOperationTests.swift
import CPOSIXCompatibility
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

/// Handwritten report-purpose receiving; no positive Root, administrator or native peer is fabricated.
final class OwnedVirtualHIDDaemonReportMainOperationTests: XCTestCase {
	private let nonce = Data(repeating: 0x5A, count: 32)
	private func request(operation: UInt8 = 1) -> Data {
		var data = Data([69, 71, 82, 86, 72, 82, 48, 49, 0, operation, 0, 0, 0, 0, 0, 0])
		data.append(Data(repeating: 0, count: 16)); data.append(nonce); return data
	}
	private func historical() -> Data {
		var data = request(); data[8] = 1; data[10] = 1
		data.replaceSubrange(11..<16, with: [1, 0, 1, 0, 0]); return data
	}
	func testSeparateReportRequestHasExactClosedPurposeAndNonce() throws {
		let frame = try XCTUnwrap(OwnedVHDReportWire.decode(request(), direction: 0, nonce: nonce))
		XCTAssertEqual(frame.operation, 1); XCTAssertEqual(frame.result, 0)
		XCTAssertEqual(frame.fields, [0, 0, 0, 0, 0]); XCTAssertEqual(frame.nonce, nonce)
		XCTAssertEqual(OwnedVHDReportWire.encode(direction: 0, operation: 1, nonce: nonce), request())
	}
	func testNegativeWithdrawalIsDistinctAndCarriesNoReportFields() throws {
		let frame = try XCTUnwrap(OwnedVHDReportWire.decode(request(operation: 2), direction: 0, nonce: nonce))
		XCTAssertEqual(frame.operation, 2); XCTAssertEqual(frame.result, 0); XCTAssertEqual(frame.fields, [0, 0, 0, 0, 0])
		XCTAssertEqual(OwnedVHDReportWire.encode(direction: 0, operation: 2, nonce: nonce), request(operation: 2))
	}
	func testHistoricalFieldsAreExactObserverConnectionData() throws {
		let frame = try XCTUnwrap(OwnedVHDReportWire.decode(historical(), direction: 1, nonce: nonce))
		XCTAssertEqual(frame.result, 1); XCTAssertEqual(frame.fields, [1, 0, 1, 0, 0])
		XCTAssertEqual(OwnedVHDReportWire.encode(direction: 1, operation: 1, result: 1, fields: [1, 0, 1, 0, 0], nonce: nonce), historical())
		// The last two values describe this passive connection's uninitialized virtual devices, not the producer's READY.
	}
	func testEveryTruncationAndAdditionalBytesAreRefused() {
		for size in 0..<64 { XCTAssertNil(OwnedVHDReportWire.decode(Data(request().prefix(size)), direction: 0)) }
		XCTAssertNil(OwnedVHDReportWire.decode(request() + Data([0]), direction: 0))
		XCTAssertNil(OwnedVHDReportWire.decode(request() + request(), direction: 0))
	}
	func testPublicationMagicWrongDirectionUnknownOperationAndReservedBytesRefuse() {
		var bytes = request(); bytes.replaceSubrange(0..<8, with: Data("EGRVHP01".utf8)); XCTAssertNil(OwnedVHDReportWire.decode(bytes, direction: 0))
		XCTAssertNil(OwnedVHDReportWire.decode(request(), direction: 1))
		for operation in [UInt8(0), 3, 255] { XCTAssertNil(OwnedVHDReportWire.decode(request(operation: operation), direction: 0)) }
		for index in 10..<32 { var bytes = request(); bytes[index] = 1; XCTAssertNil(OwnedVHDReportWire.decode(bytes, direction: 0)) }
	}
	func testUnknownResultNonBooleanAndRefusalWithReportFieldsRefuse() {
		for result in [UInt8(0), 4, 255] { var bytes = historical(); bytes[10] = result; XCTAssertNil(OwnedVHDReportWire.decode(bytes, direction: 1)) }
		for index in 11..<16 { var bytes = historical(); bytes[index] = 2; XCTAssertNil(OwnedVHDReportWire.decode(bytes, direction: 1)) }
		for result in [UInt8(2), 3] { var bytes = historical(); bytes[10] = result; XCTAssertNil(OwnedVHDReportWire.decode(bytes, direction: 1)) }
	}
	func testRefusalAndDebtHaveOnlyClosedZeroFields() throws {
		for result in [UInt8(2), 3] {
			var bytes = request(); bytes[8] = 1; bytes[10] = result
			let frame = try XCTUnwrap(OwnedVHDReportWire.decode(bytes, direction: 1, nonce: nonce))
			XCTAssertEqual(frame.result, result); XCTAssertEqual(frame.fields, [0, 0, 0, 0, 0])
		}
	}
	func testZeroWrongAndPreviousNonceCannotQualifyTheNewOwner() {
		var zero = request(); zero.replaceSubrange(32..<64, with: Data(repeating: 0, count: 32)); XCTAssertNil(OwnedVHDReportWire.decode(zero, direction: 0))
		XCTAssertNil(OwnedVHDReportWire.decode(request(), direction: 0, nonce: Data(repeating: 0xA5, count: 32)))
		XCTAssertNil(OwnedVHDReportWire.encode(direction: 0, operation: 1, nonce: Data(repeating: 1, count: 31)))
	}
	func testRoutesArePurposeSpecificWithoutArbitraryPathAuthority() {
		XCTAssertTrue(OwnedVirtualHIDDaemonReportRequestChannel.validRoute("/private/tmp/.ergopti-vhd-report-0123456789abcdef0123456789abcdef/channel.sock"))
		for path in ["/tmp/.ergopti-vhd-report-0123456789abcdef0123456789abcdef/channel.sock", "/private/tmp/.ergopti-vhd-0123456789abcdef0123456789abcdef/channel.sock", "/private/tmp/.ergopti-vhd-report-0123456789abcdef0123456789abcdeF/channel.sock", "/private/tmp/.ergopti-vhd-report-0123456789abcdef0123456789abcdef/../channel.sock", "/private/tmp/.ergopti-vhd-report-0123456789abcdef0123456789abcdef/channel.sock\n"] {
			XCTAssertFalse(OwnedVirtualHIDDaemonReportRequestChannel.validRoute(path))
		}
	}
	func testMainRequestFlagIsExactAndNeverAnInstallOrRootDispatch() {
		XCTAssertTrue(OwnedVirtualHIDDaemonReportMainOperation.handles(arguments: ["Main", "--request-virtual-hid-daemon-report"]))
		for arguments in [["Main"], ["Main", "--request-virtual-hid-daemon-report", "extra"], ["Main", "--virtual-hid-daemon-report-worker"], ["Main", "--owned-install-first"], ["Main", "--virtual-hid-driver-publication-worker"]] {
			XCTAssertFalse(OwnedVirtualHIDDaemonReportMainOperation.handles(arguments: arguments))
		}
	}
	func testRealMainThreadCannotMintMainOperationOrRootRequest() {
		XCTAssertTrue(Thread.isMainThread, "constructor control requires the actual main XCTest thread")
		let main = OwnedVirtualHIDDaemonReportMainOperation.acquire(); XCTAssertFalse(main.start()); XCTAssertTrue(main.retire()); XCTAssertTrue(main.retired())
		let root = OwnedVirtualHIDDaemonReportRequestChannel.Root.acquire(); XCTAssertFalse(root.current()); XCTAssertNil(root.receiveRequest())
		XCTAssertNotNil(root.retire()); XCTAssertTrue(root.retired())
	}
	func testRealKernelSelfImageObservationHasCurrentOriginalBirth() {
		var image = ergopti_vhd_report_self_image()
		XCTAssertEqual(ergopti_vhd_report_self_image_capture(&image), 0, "requires the real signed Darwin test process, never a modeled image")
		XCTAssertEqual(image.pid, getpid())
		let birth = ergopti_owned_program_observe(getpid())
		XCTAssertEqual(birth.error_code, 0); XCTAssertFalse(birth.nonlive)
		XCTAssertEqual(image.seconds, birth.start_seconds); XCTAssertEqual(image.microseconds, birth.start_microseconds)
		XCTAssertEqual(ergopti_vhd_report_self_image_matches(&image), 0)
	}
	func testForeignOrEmptyKernelImageCannotQualifyThisProcess() {
		var empty = ergopti_vhd_report_self_image()
		XCTAssertNotEqual(ergopti_vhd_report_self_image_matches(&empty), 0)
		empty.pid = getpid() + 1
		XCTAssertNotEqual(ergopti_vhd_report_self_image_matches(&empty), 0)
	}

}

/// Pure closed reply controls, never a native process/source/retirement grant.
final class OwnedVirtualHIDDaemonReportPurposeQueryTests: XCTestCase {
	private let reply = Data("OWNED_VHD_DAEMON_REPORT_PURPOSE|1|readonly-historical\n".utf8)
	func testExactPurposeReplyIsDataOnly() {
		XCTAssertTrue(OwnedVirtualHIDDaemonReportMainOperation.acceptsPurposeReply(reply, errors: Data(), status: 0))
	}
	func testDefaultHelperAndNonzeroExitRefuseEvenMatchingOutput() {
		for status: Int32 in [64, 75, 77, 1, -1] {
			XCTAssertFalse(OwnedVirtualHIDDaemonReportMainOperation.acceptsPurposeReply(reply, errors: Data(), status: status))
		}
	}
	func testTruncatedExtraOrForeignPurposeCannotQualify() {
		for bytes in [Data(), Data(reply.dropLast()), reply + Data("extra".utf8), Data("OWNED_RUNTIME_INSTALL|1|filesPublishedStagingRetired\n".utf8)] {
			XCTAssertFalse(OwnedVirtualHIDDaemonReportMainOperation.acceptsPurposeReply(bytes, errors: Data(), status: 0))
		}
	}
	func testAnyErrorOutputRefusesThePurposeReply() {
		XCTAssertFalse(OwnedVirtualHIDDaemonReportMainOperation.acceptsPurposeReply(reply, errors: Data([0]), status: 0))
	}
}
