// Sources/ErgoptiPlus/OwnedRuntimeCoreExitObservation.swift
// Polls the genuine native NOTE_EXITSTATUS registration without GUI callbacks or asynchronous close debt.
import CPOSIXCompatibility
import Darwin
import Foundation

/// A process-exit observation alone supplies no process incarnation, job or service retirement authority.
final class OwnedRuntimeCoreExitObservation {
	enum State: Equatable { case waiting, exited, refused, retired }
	private let descriptor: Int32
	private let lock = NSLock()
	private var state: State = .waiting
	private var closeAttempted = false, closeRefused = false
	private init(descriptor: Int32) { self.descriptor = descriptor }
	static func attach(process: pid_t) -> OwnedRuntimeCoreExitObservation? {
		guard process > 0 else { return nil }
		var error: Int32 = 0
		let descriptor = ergopti_process_exit_monitor_open(process, &error)
		guard descriptor >= 0 else { return nil }
		return OwnedRuntimeCoreExitObservation(descriptor: descriptor)
	}
	func observe() -> State {
		lock.lock(); defer { lock.unlock() }
		guard state == .waiting, !closeAttempted else { return state }
		var status: Int32 = 0, error: Int32 = 0
		let result = ergopti_process_exit_monitor_read(descriptor, &status, &error)
		if result == 1 { state = .exited }
		else if result != 0 { state = .refused }
		return state
	}
	/// Native descriptor close is acknowledged once. A failed close stays failed without retrying a reused FD.
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if !closeAttempted {
			closeAttempted = true; closeRefused = Darwin.close(descriptor) != 0
			if state != .exited { state = .retired }
		}
		return !closeRefused
	}
	deinit { _ = retire() }
}
