// Tests/ErgoptiPlusTests/OwnedRuntimeNamespaceCloseOrderTests.swift
// Real flock observations verify custody; no fixture creates production image/process authority.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeNamespaceCloseOrderTests: XCTestCase {
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private func fixture(_ body: (URL) throws -> Void) throws {
		let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: parent) }
		try body(parent)
	}
	func testNativeEarlierCloseRefusalKeepsActualNamespaceLocked() throws {
		try fixture { parent in
			let held = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false, create: true)
			XCTAssertTrue(held.fixtureObserveEarlierNativeCloseRefusal())
			XCTAssertFalse(held.current())
			XCTAssertFalse(held.retire()); XCTAssertFalse(held.current())
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true))
			XCTAssertFalse(held.retire())
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true))
		}
	}
	func testCallerReferenceLossCannotRetireOriginalNativeNamespace() throws {
		try fixture { parent in
			var held: OwnedRuntimeServiceLifecycleLock? = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false, create: true)
			weak var original = held
			held = nil
			XCTAssertNotNil(original)
			XCTAssertThrowsError(try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true))
			let recovered = try XCTUnwrap(original)
			XCTAssertTrue(recovered.retire())
			let writer = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: true)
			XCTAssertTrue(writer.retire())
		}
	}
#endif
}
