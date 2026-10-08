// Tests/ErgoptiPlusTests/KeyboardSourceTestSelection.swift

// ==============================================================================
// MODULE: Native Keyboard Fixture Selection Completion
// DESCRIPTION:
// Owns test-only Carbon selection on the actual main thread/run loop. A status
// zero call does not acknowledge a stale copied-current source. One five-second
// absolute scope cap is shared by selection and both restoration attempts.
// ==============================================================================

import Carbon
import Foundation
import XCTest

struct KeyboardSelectionObservation: Equatable {
	let identifier: String
	let selected: Bool
	let enabled: Bool

	func acknowledges(_ target: String) -> Bool {
		identifier == target && selected && enabled
	}
}

// The ports separate controlled event/deadline witnesses from actual Carbon
// observations; the native adapter below supplies no substitute source identity.
final class KeyboardSelectionCompletion {
	let generation: UInt64
	private let deadline: TimeInterval
	private let now: () -> TimeInterval
	private let owner: () -> Bool
	private let read: () -> KeyboardSelectionObservation?
	private let service: (TimeInterval) -> Void
	private var lastTime: TimeInterval?
	private var serial: UInt64 = 0
	private var retired = false
	private var busy = false

	init(generation: UInt64, deadline: TimeInterval, now: @escaping () -> TimeInterval,
		owner: @escaping () -> Bool, read: @escaping () -> KeyboardSelectionObservation?,
		service: @escaping (TimeInterval) -> Void) {
		self.generation = generation
		self.deadline = deadline
		self.now = now
		self.owner = owner
		self.read = read
		self.service = service
	}

	func notification(generation: UInt64) {
		guard !retired, generation == self.generation, owner() else { return }
		guard serial < UInt64.max else { retire(); return }
		serial += 1
	}

	func retire() { retired = true }

	private func remaining() -> TimeInterval? {
		guard !retired, owner() else { return nil }
		let time = now()
		guard time.isFinite, deadline.isFinite, time < deadline,
			lastTime.map({ time >= $0 }) ?? true else { retire(); return nil }
		lastTime = time
		guard !retired, owner() else { return nil }
		return deadline - time
	}

	private func observed(_ target: String) -> Bool {
		guard remaining() != nil else { return false }
		let snapshot = read()
		guard remaining() != nil else { return false }
		return snapshot?.acknowledges(target) == true
	}

	func complete(target: String, status: OSStatus) -> Bool {
		guard !busy else { retire(); return false }
		busy = true
		defer { busy = false }
		guard status == noErr, !target.isEmpty, remaining() != nil else { return false }
		// Already selected sources need no new notification (TISSelect is a no-op).
		var previous = serial
		if observed(target) { return true }
		while let left = remaining() {
			// Include a genuine notification delivered during the preceding read.
			// Unrelated main-run-loop work is not a selection completion cue.
			if serial != previous {
				previous = serial
				if observed(target) { return true }
				continue
			}
			service(left)
			guard remaining() != nil else { return false }
		}
		return false
	}
}

final class KeyboardSelectionCleanupDebt {
	private var sources: [String: AnyObject] = [:]
	var unresolved: Bool { !sources.isEmpty }
	var identifiers: [String] { sources.keys.sorted() }

	func retain(identifier: String, source: AnyObject) {
		// A duplicate must not replace the exact object whose enabling is owed.
		if sources[identifier] == nil { sources[identifier] = source }
	}

	func release(identifier: String, source: AnyObject, originalID: String,
		current: KeyboardSelectionObservation?, status: OSStatus, disabled: Bool) -> Bool {
		guard let held = sources[identifier], held === source, status == noErr,
			!originalID.isEmpty, originalID != identifier, disabled,
			current?.acknowledges(originalID) == true else { return false }
		sources.removeValue(forKey: identifier)
		return true
	}
}

final class KeyboardSourceTestSelection {
	enum Failure: Error {
		case wrongThreadOrRunLoop, reentered, outstandingCleanupDebt, invalidOriginal, unacknowledgedSelection
	}

	private static let lock = NSLock()
	private static var active: KeyboardSourceTestSelection?
	private static var nextGeneration: UInt64 = 0
	private static let debt = KeyboardSelectionCleanupDebt()
	private let generation: UInt64
	private let deadline: TimeInterval
	private var closed = false
	private var poisoned = false
	private var observerInstalled = false

	private lazy var completion = KeyboardSelectionCompletion(generation: generation, deadline: deadline,
		now: { ProcessInfo.processInfo.systemUptime }, owner: { [weak self] in self?.isCurrent == true },
		read: { Self.currentObservation() }, service: { [weak self] left in
			guard self?.isCurrent == true else { return }
			// Distributed TIS notifications require the owning main run loop in its
			// default/common mode. No timer, sleep, polling read, or selection retry.
			let result = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, left, true)
			if result == .finished || result == .stopped { self?.poison() }
		})

	init() throws {
		guard Self.onMainOwner else { throw Failure.wrongThreadOrRunLoop }
		Self.lock.lock()
		guard Self.active == nil else {
			Self.active?.poisoned = true
			Self.lock.unlock()
			throw Failure.reentered
		}
		guard !Self.debt.unresolved else { Self.lock.unlock(); throw Failure.outstandingCleanupDebt }
		guard Self.nextGeneration < UInt64.max else { Self.lock.unlock(); throw Failure.reentered }
		Self.nextGeneration += 1
		generation = Self.nextGeneration
		deadline = ProcessInfo.processInfo.systemUptime + 5
		Self.active = self
		Self.lock.unlock()
		CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(),
			Unmanaged.passUnretained(self).toOpaque(), { _, pointer, _, _, _ in
				guard let pointer = pointer else { return }
				let owner = Unmanaged<KeyboardSourceTestSelection>.fromOpaque(pointer).takeUnretainedValue()
				guard KeyboardSourceTestSelection.onMainOwner else { owner.poison(); return }
				owner.completion.notification(generation: owner.generation)
			}, kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
		observerInstalled = true
	}

	private static var onMainOwner: Bool {
		Thread.isMainThread && CFEqual(CFRunLoopGetCurrent(), CFRunLoopGetMain())
	}

	var isCurrent: Bool {
		guard Self.onMainOwner else { return false }
		Self.lock.lock()
		defer { Self.lock.unlock() }
		return Self.active === self && !closed && !poisoned
	}

	private func poison() {
		Self.lock.lock()
		poisoned = true
		Self.lock.unlock()
	}

	private static func identifier(_ source: TISInputSource) -> String? {
		guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
		let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
		guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
		let text = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
		return text.isEmpty ? nil : text
	}

	private static func flag(_ source: TISInputSource, _ key: CFString) -> Bool? {
		guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
		let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
		guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
		return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
	}

	private static func observation(_ source: TISInputSource) -> KeyboardSelectionObservation? {
		guard onMainOwner, let id = identifier(source),
			let selected = flag(source, kTISPropertyInputSourceIsSelected),
			let enabled = flag(source, kTISPropertyInputSourceIsEnabled) else { return nil }
		return KeyboardSelectionObservation(identifier: id, selected: selected, enabled: enabled)
	}

	private static func currentObservation() -> KeyboardSelectionObservation? {
		guard onMainOwner, let copied = TISCopyCurrentKeyboardInputSource() else { return nil }
		return observation(copied.takeRetainedValue())
	}

	func validateOriginal(_ original: TISInputSource) throws {
		guard isCurrent, let captured = Self.observation(original),
			captured.acknowledges(captured.identifier),
			Self.currentObservation()?.acknowledges(captured.identifier) == true,
			isCurrent, ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.invalidOriginal }
	}

	func acknowledge(_ source: TISInputSource, status: OSStatus) -> Bool {
		guard isCurrent, let id = Self.identifier(source), isCurrent else { return false }
		return completion.complete(target: id, status: status)
	}

	func prepareSelection() throws {
		guard isCurrent, ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.unacknowledgedSelection }
	}

	func requireSelection(_ source: TISInputSource, status: OSStatus) throws {
		guard acknowledge(source, status: status) else { throw Failure.unacknowledgedSelection }
	}

	func retainEnabled(_ source: TISInputSource) throws {
		guard isCurrent, ProcessInfo.processInfo.systemUptime < deadline,
			let id = Self.identifier(source), isCurrent else { throw Failure.unacknowledgedSelection }
		// Acquire exact cleanup debt before the foreign enabling call. A refusal
		// or reentry after that call must not lose the potentially enabled source.
		Self.debt.retain(identifier: id, source: source)
		guard isCurrent, ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.unacknowledgedSelection }
	}

	func mayDisable(_ source: TISInputSource, original: TISInputSource) -> Bool {
		guard isCurrent, let sourceID = Self.identifier(source), let originalID = Self.identifier(original),
			sourceID != originalID else { return false }
		return acknowledge(original, status: noErr)
	}

	func releaseDisabled(_ source: TISInputSource, original: TISInputSource, status: OSStatus) {
		guard isCurrent, ProcessInfo.processInfo.systemUptime < deadline,
			let sourceID = Self.identifier(source), let originalID = Self.identifier(original),
			let disabled = Self.flag(source, kTISPropertyInputSourceIsEnabled),
			let current = Self.currentObservation(), isCurrent,
			ProcessInfo.processInfo.systemUptime < deadline,
			Self.debt.release(identifier: sourceID, source: source, originalID: originalID,
				current: current, status: status, disabled: !disabled) else {
			XCTFail("Native disabling did not settle exact input-source cleanup debt")
			return
		}
	}

	func close() {
		guard Self.onMainOwner else { poison(); XCTFail("Input-source owner closed off the main run loop"); return }
		guard !closed else { return }
		completion.retire()
		if observerInstalled {
			CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDistributedCenter(),
				Unmanaged.passUnretained(self).toOpaque())
			observerInstalled = false
		}
		Self.lock.lock()
		closed = true
		if Self.active === self { Self.active = nil }
		Self.lock.unlock()
		if Self.debt.unresolved {
			XCTFail("Unacknowledged native restoration retains cleanup debt: \(Self.debt.identifiers.joined(separator: ", "))")
		}
	}
}
