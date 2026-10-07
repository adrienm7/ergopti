// Tests/ErgoptiPlusTests/KeyboardSourceTestSelectionTests.swift

// ==============================================================================
// MODULE: Keyboard Fixture Completion Controls
// DESCRIPTION:
// Frozen independent completion expectations. Scripted reads model native events;
// only the explicit owner checks exercise the actual calling thread/run loop.
// ==============================================================================

import Carbon
import Foundation
import XCTest

final class KeyboardSourceTestSelectionTests: XCTestCase {
	private let us = KeyboardSelectionObservation(identifier: "com.apple.keylayout.US", selected: true, enabled: true)
	private let french = KeyboardSelectionObservation(identifier: "com.apple.keylayout.French", selected: true, enabled: true)

	func testAlreadySettledNeedsNoNotification() {
		var services = 0
		let fence = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { 0 },
			owner: { true }, read: { self.us }, service: { _ in services += 1 })
		XCTAssertTrue(fence.complete(target: us.identifier, status: noErr))
		XCTAssertEqual(services, 0)
	}

	func testStatusZeroAndSelectedTargetCannotAdmitStaleCopiedCurrent() {
		var time = 0.0
		let fence = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { time },
			owner: { true }, read: { self.french }, service: { remaining in time += remaining })
		XCTAssertFalse(fence.complete(target: us.identifier, status: noErr))
		XCTAssertEqual(time, 5)
	}

	func testRestoreRequiresFreshExactCurrentBeforeDisable() {
		var current = french
		var time = 0.0
		var operations = ["restore.status0"]
		var fence: KeyboardSelectionCompletion!
		fence = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { time },
			owner: { true }, read: { current }, service: { _ in
				operations.append("native.notification")
				current = self.us
				time = 1
				fence.notification(generation: 7)
			})
		if fence.complete(target: us.identifier, status: noErr) { operations.append("disable.French") }
		XCTAssertEqual(operations, ["restore.status0", "native.notification", "disable.French"])
	}

	func testWrongEventAndWrongGenerationNeverAcknowledge() {
		var time = 0.0
		var reads = 0
		var services = 0
		var fence: KeyboardSelectionCompletion!
		fence = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { time },
			owner: { true }, read: { reads += 1; return self.french }, service: { _ in
				services += 1
				time = Double(services)
				fence.notification(generation: services == 1 ? 6 : 7)
			})
		XCTAssertFalse(fence.complete(target: us.identifier, status: noErr))
		XCTAssertEqual(services, 5)
		XCTAssertEqual(reads, 4, "Initial read and three current-generation events before the absolute cap")
	}

	func testSelectedAndEnabledAreRequiredTogetherWithCurrentIdentity() {
		for flags in [(false, true), (true, false), (false, false)] {
			var time = 0.0
			let current = KeyboardSelectionObservation(identifier: us.identifier, selected: flags.0, enabled: flags.1)
			let fence = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { time },
				owner: { true }, read: { current }, service: { remaining in time += remaining })
			XCTAssertFalse(fence.complete(target: us.identifier, status: noErr))
		}
	}

	func testNativeRefusalIsNotSyntheticCompletion() {
		var reads = 0
		let fence = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { 0 },
			owner: { true }, read: { reads += 1; return self.us },
			service: { _ in XCTFail("A native refusal must not wait") })
		XCTAssertFalse(fence.complete(target: us.identifier, status: -50))
		XCTAssertEqual(reads, 0)
	}

	func testAbsoluteDeadlineIsSharedAcrossSelectionAndRestore() {
		var time = 0.0
		var current = us
		let fence = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { time },
			owner: { true }, read: { current }, service: { remaining in time += remaining })
		XCTAssertTrue(fence.complete(target: us.identifier, status: noErr))
		current = french
		time = 4
		XCTAssertFalse(fence.complete(target: us.identifier, status: noErr))
		XCTAssertEqual(time, 5, "Restoration cannot renew the scope budget")
		current = us
		XCTAssertFalse(fence.complete(target: us.identifier, status: noErr))
	}

	func testRetiredAndReenteredOwnerCannotReturnPositiveAcknowledgment() {
		let retired = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { 0 },
			owner: { true }, read: { self.us }, service: { _ in })
		retired.retire()
		retired.notification(generation: 7)
		XCTAssertFalse(retired.complete(target: us.identifier, status: noErr))
		var reentered: KeyboardSelectionCompletion!
		reentered = KeyboardSelectionCompletion(generation: 8, deadline: 5, now: { 0 },
			owner: { true }, read: {
				XCTAssertFalse(reentered.complete(target: self.us.identifier, status: noErr))
				return self.us
			}, service: { _ in })
		XCTAssertFalse(reentered.complete(target: us.identifier, status: noErr))
	}

	func testOwnerLossDuringFreshReadAndBackwardClockRefuse() {
		var owner = true
		let lost = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { 0 },
			owner: { owner }, read: { owner = false; return self.us }, service: { _ in })
		XCTAssertFalse(lost.complete(target: us.identifier, status: noErr))
		var time = 1.0
		let backwards = KeyboardSelectionCompletion(generation: 7, deadline: 5, now: { time },
			owner: { true }, read: { time = 0; return self.us }, service: { _ in })
		XCTAssertFalse(backwards.complete(target: us.identifier, status: noErr))
	}

	func testActualBackgroundThreadCannotAcquireNativeCarbonOwner() {
		let rejected = expectation(description: "Actual background owner refused before any Carbon read")
		DispatchQueue.global().async {
			XCTAssertFalse(Thread.isMainThread)
			XCTAssertThrowsError(try KeyboardSourceTestSelection())
			rejected.fulfill()
		}
		wait(for: [rejected], timeout: 1)
	}

	func testActualMainThreadAndRunLoopOwnSingleGeneration() throws {
		XCTAssertTrue(Thread.isMainThread, "XCTest must own the main thread; no actor assumption")
		let owner = try KeyboardSourceTestSelection()
		defer { owner.close() }
		XCTAssertTrue(CFEqual(CFRunLoopGetCurrent(), CFRunLoopGetMain()))
		XCTAssertThrowsError(try KeyboardSourceTestSelection())
		XCTAssertFalse(owner.isCurrent, "Reentrant scope poisons the outer generation")
	}
	func testUnacknowledgedRestorationRetainsExactCleanupDebt() {
		let debt = KeyboardSelectionCleanupDebt()
		let source = NSObject()
		debt.retain(identifier: french.identifier, source: source)
		XCTAssertFalse(debt.release(identifier: french.identifier, source: source,
			originalID: us.identifier, current: french, status: noErr, disabled: true))
		XCTAssertTrue(debt.unresolved)
		XCTAssertFalse(debt.release(identifier: french.identifier, source: source,
			originalID: us.identifier, current: us, status: -50, disabled: true))
		XCTAssertTrue(debt.unresolved)
		XCTAssertFalse(debt.release(identifier: french.identifier, source: source,
			originalID: us.identifier, current: us, status: noErr, disabled: false))
		XCTAssertTrue(debt.unresolved)
		XCTAssertFalse(debt.release(identifier: french.identifier, source: NSObject(),
			originalID: us.identifier, current: us, status: noErr, disabled: true))
		XCTAssertTrue(debt.unresolved)
		XCTAssertTrue(debt.release(identifier: french.identifier, source: source,
			originalID: us.identifier, current: us, status: noErr, disabled: true))
		XCTAssertFalse(debt.unresolved)
	}

}
