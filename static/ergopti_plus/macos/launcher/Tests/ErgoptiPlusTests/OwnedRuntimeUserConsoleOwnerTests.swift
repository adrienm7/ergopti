// Tests/ErgoptiPlusTests/OwnedRuntimeUserConsoleOwnerTests.swift
// Native observations and descriptor controls cannot create installed or capture authority.
import Darwin
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeUserConsoleOwnerTests: XCTestCase {
	func testXCTestCannotAcquireInstalledConsolePeer() {
		XCTAssertNil(OwnedRuntimeInstalledPeerOwner.acquire())
	}
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	func testCurrentXCTestImageCannotAuthenticateConsoleRole() {
		XCTAssertFalse(OwnedRuntimeUserConsoleOwner.fixtureUnqualifiedConsoleGuest(getpid()))
	}
	func testInvalidNativeGuestCannotAuthenticateConsoleRole() {
		XCTAssertFalse(OwnedRuntimeUserConsoleOwner.fixtureUnqualifiedConsoleGuest(0))
	}
	func testActualPipeStartsPendingWithoutInventingEOF() throws {
		var refused = false
		let descriptors = try XCTUnwrap(OwnedRuntimeUserConsoleOwner.fixturePipe(closeRefused: &refused))
		defer { for descriptor in descriptors { XCTAssertEqual(Darwin.close(descriptor), 0) } }
		var eof = false
		XCTAssertTrue(OwnedRuntimeUserConsoleOwner.fixtureDrain(descriptors[0], eof: &eof))
		XCTAssertFalse(eof); XCTAssertFalse(refused)
	}
	func testActualPipeEOFRequiresActualWriterClose() throws {
		var refused = false
		let descriptors = try XCTUnwrap(OwnedRuntimeUserConsoleOwner.fixturePipe(closeRefused: &refused))
		defer { XCTAssertEqual(Darwin.close(descriptors[0]), 0) }
		XCTAssertEqual(Darwin.close(descriptors[1]), 0)
		var eof = false
		XCTAssertTrue(OwnedRuntimeUserConsoleOwner.fixtureDrain(descriptors[0], eof: &eof))
		XCTAssertTrue(eof); XCTAssertFalse(refused)
	}
	func testBoundedOutputIsDiscardedBeforeRealEOF() throws {
		var refused = false
		let descriptors = try XCTUnwrap(OwnedRuntimeUserConsoleOwner.fixturePipe(closeRefused: &refused))
		defer { XCTAssertEqual(Darwin.close(descriptors[0]), 0) }
		let bytes = [UInt8](repeating: 65, count: 1024)
		XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, bytes.count) }, bytes.count)
		var eof = false
		XCTAssertTrue(OwnedRuntimeUserConsoleOwner.fixtureDrain(descriptors[0], eof: &eof)); XCTAssertFalse(eof)
		XCTAssertEqual(Darwin.close(descriptors[1]), 0)
		XCTAssertTrue(OwnedRuntimeUserConsoleOwner.fixtureDrain(descriptors[0], eof: &eof)); XCTAssertTrue(eof)
	}
	func testBothOriginalStreamsHaveIndependentEOF() throws {
		var refused = false
		let first = try XCTUnwrap(OwnedRuntimeUserConsoleOwner.fixturePipe(closeRefused: &refused))
		let second = try XCTUnwrap(OwnedRuntimeUserConsoleOwner.fixturePipe(closeRefused: &refused))
		defer { for descriptor in [first[0], second[0]] { XCTAssertEqual(Darwin.close(descriptor), 0) } }
		XCTAssertEqual(Darwin.close(first[1]), 0)
		var firstEOF = false, secondEOF = false
		XCTAssertTrue(OwnedRuntimeUserConsoleOwner.fixtureDrain(first[0], eof: &firstEOF))
		XCTAssertTrue(OwnedRuntimeUserConsoleOwner.fixtureDrain(second[0], eof: &secondEOF))
		XCTAssertTrue(firstEOF); XCTAssertFalse(secondEOF)
		XCTAssertEqual(Darwin.close(second[1]), 0)
		XCTAssertTrue(OwnedRuntimeUserConsoleOwner.fixtureDrain(second[0], eof: &secondEOF)); XCTAssertTrue(secondEOF)
	}
	func testInvalidReadNeverBecomesEOF() {
		var eof = false
		XCTAssertFalse(OwnedRuntimeUserConsoleOwner.fixtureDrain(-1, eof: &eof)); XCTAssertFalse(eof)
	}
	func testPipeEndsAreCLOEXECAndReaderIsNonblocking() throws {
		var refused = false
		let descriptors = try XCTUnwrap(OwnedRuntimeUserConsoleOwner.fixturePipe(closeRefused: &refused))
		defer { for descriptor in descriptors { XCTAssertEqual(Darwin.close(descriptor), 0) } }
		for descriptor in descriptors { XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0) }
		XCTAssertNotEqual(fcntl(descriptors[0], F_GETFL) & O_NONBLOCK, 0)
	}
	func testInvalidDescriptorCloseLatchesRefusalWithoutReusingAClosedFD() throws {
		var refused = false
		let descriptors = try XCTUnwrap(OwnedRuntimeUserConsoleOwner.fixturePipe(closeRefused: &refused))
		OwnedRuntimeUserConsoleOwner.fixtureClose(-1, refused: &refused)
		XCTAssertTrue(refused)
		for descriptor in descriptors { OwnedRuntimeUserConsoleOwner.fixtureClose(descriptor, refused: &refused) }
		XCTAssertTrue(refused)
	}
#endif
}
