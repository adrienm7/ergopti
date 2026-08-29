// Sources/ErgoptiPlus/EmbeddedProcessExitMonitor.swift

/**
 ==============================================================================
 MODULE: Embedded Process Exit Monitor
 DESCRIPTION:
 Owns a one-shot kqueue process filter so the launcher receives Hammerspoon's
 real wait status instead of inferring success from an AppKit notification.

 FEATURES & RATIONALE:
 1. Kernel authority: NOTE_EXITSTATUS distinguishes clean exit from signal death.
 2. Exact ownership: cancellation revokes the callback and closes one kqueue.
 3. Main-thread handoff: AppDelegate receives a typed terminal observation.
 ==============================================================================
 */

import Darwin
import Dispatch
import Foundation

/// Typed terminal state derived from the kernel wait status.
enum EmbeddedProcessExit: Equatable {
	case exited(code: Int32)
	case signaled(signal: Int32)
	case unavailable(errorCode: Int32)
}

/// Decodes the wait(2)-format status returned by NOTE_EXITSTATUS.
func decodeEmbeddedProcessWaitStatus(_ rawStatus: Int32) -> EmbeddedProcessExit {
	let terminationBits = rawStatus & 0x7f
	if terminationBits == 0 {
		return .exited(code: (rawStatus >> 8) & 0xff)
	}
	if terminationBits != 0x7f {
		return .signaled(signal: terminationBits)
	}
	return .unavailable(errorCode: EPROTO)
}

/// Revocable ownership of one process-exit observation.
protocol EmbeddedProcessExitMonitoring: AnyObject {
	func cancel()
}

/// Injectable constructor used by AppDelegate and XCTest.
typealias EmbeddedProcessExitMonitorFactory = (
	pid_t,
	@escaping (EmbeddedProcessExit) -> Void
) -> EmbeddedProcessExitMonitoring?

/// Creates the production kqueue-backed process monitor.
func makeEmbeddedProcessExitMonitor(
	processIdentifier: pid_t,
	completion: @escaping (EmbeddedProcessExit) -> Void
) -> EmbeddedProcessExitMonitoring? {
	KqueueEmbeddedProcessExitMonitor(
		processIdentifier: processIdentifier,
		completion: completion
	)
}

private final class KqueueEmbeddedProcessExitMonitor: EmbeddedProcessExitMonitoring {
	private let descriptor: Int32
	private let source: DispatchSourceRead
	private let stateLock = NSLock()
	private var completion: ((EmbeddedProcessExit) -> Void)?
	private var cancelled = false

	init?(
		processIdentifier: pid_t,
		completion: @escaping (EmbeddedProcessExit) -> Void
	) {
		var errorCode: Int32 = 0
		let descriptor = ergoptiOpenProcessExitMonitor(
			processIdentifier,
			errorCode: &errorCode
		)
		guard descriptor >= 0 else {
			LauncherLog.write(
				"process exit monitor attach failed for pid \(processIdentifier): errno \(errorCode)"
			)
			return nil
		}

		self.descriptor = descriptor
		self.completion = completion
		self.source = DispatchSource.makeReadSource(
			fileDescriptor: descriptor,
			queue: DispatchQueue.global(qos: .userInitiated)
		)
		self.source.setEventHandler { [weak self] in self?.consumeAvailableExit() }
		self.source.setCancelHandler { _ = Darwin.close(descriptor) }
		self.source.resume()
	}

	deinit { cancel() }

	func cancel() {
		stateLock.lock()
		guard !cancelled else {
			stateLock.unlock()
			return
		}
		cancelled = true
		completion = nil
		stateLock.unlock()
		source.cancel()
	}

	private func consumeAvailableExit() {
		var rawStatus: Int32 = 0
		var errorCode: Int32 = 0
		let readResult = ergoptiReadProcessExitMonitor(
			descriptor,
			rawStatus: &rawStatus,
			errorCode: &errorCode
		)
		guard readResult != 0 else { return }
		let exit = readResult == 1
			? decodeEmbeddedProcessWaitStatus(rawStatus)
			: .unavailable(errorCode: errorCode)

		stateLock.lock()
		guard !cancelled, let callback = completion else {
			stateLock.unlock()
			return
		}
		cancelled = true
		completion = nil
		stateLock.unlock()
		source.cancel()
		callback(exit)
	}
}
