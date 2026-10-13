// Tests/ErgoptiPlusTests/OwnedRuntimeCoreExitObservationTests.swift
// Real native child/NOTE_EXITSTATUS controls; these observations never construct Core service authority.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeCoreExitObservationTests: XCTestCase {
	func testInvalidNativeProcessCannotAttach() {
		XCTAssertNil(OwnedRuntimeCoreExitObservation.attach(process: 0))
		XCTAssertNil(OwnedRuntimeCoreExitObservation.attach(process: -1))
	}
	func testRealOwnedChildWaitsThenProducesItsOriginalNativeExit() throws {
		let child = try NativeOwnedCat()
		defer { XCTAssertTrue(child.retire()) }
		let monitor = try XCTUnwrap(OwnedRuntimeCoreExitObservation.attach(process: child.pid))
		defer { XCTAssertTrue(monitor.retire()) }
		XCTAssertEqual(monitor.observe(), .waiting)
		try child.closeInput()
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		var observed = monitor.observe()
		while observed == .waiting, ProcessInfo.processInfo.systemUptime < deadline {
			Thread.sleep(forTimeInterval: 0.01); observed = monitor.observe()
		}
		XCTAssertEqual(observed, .exited)
		XCTAssertEqual(try child.waitForOrdinaryExit(), 0)
		XCTAssertTrue(monitor.retire()); XCTAssertTrue(monitor.retire())
		XCTAssertEqual(monitor.observe(), .exited)
	}
	func testRetiringWaitingNativeRegistrationCannotObserveLaterChild() throws {
		let child = try NativeOwnedCat()
		defer { XCTAssertTrue(child.retire()) }
		let monitor = try XCTUnwrap(OwnedRuntimeCoreExitObservation.attach(process: child.pid))
		defer { XCTAssertTrue(monitor.retire()) }
		XCTAssertEqual(monitor.observe(), .waiting)
		XCTAssertTrue(monitor.retire()); XCTAssertTrue(monitor.retire())
		XCTAssertEqual(monitor.observe(), .retired)
		try child.closeInput()
		XCTAssertEqual(try child.waitForOrdinaryExit(), 0)
		XCTAssertEqual(monitor.observe(), .retired)
	}
}

/// Test-only direct native child custody. Nothing here can construct a Core or privileged installation owner.
private final class NativeOwnedCat {
	let pid: pid_t
	private var input: Int32 = -1, status: Int32?, lost = false, closeRefused = false
	init() throws {
		var disposition = sigaction()
		guard Darwin.sigaction(SIGCHLD, nil, &disposition) == 0,
			unsafeBitCast(disposition.__sigaction_u.__sa_handler, to: UInt.self) == unsafeBitCast(SIG_DFL, to: UInt.self),
			disposition.sa_flags & SA_NOCLDWAIT == 0 else { throw OwnedRuntimeInstallFailure.source }
		var pipeEnds: [Int32] = [-1, -1]
		guard pipe(&pipeEnds) == 0 else { throw OwnedRuntimeInstallFailure.source }
		var readEnd = pipeEnds[0], writeEnd = pipeEnds[1], null = open("/dev/null", O_RDWR | O_CLOEXEC)
		defer { for fd in [readEnd, writeEnd, null] where fd >= 0 { Darwin.close(fd) } }
		guard readEnd > STDERR_FILENO, writeEnd > STDERR_FILENO, null > STDERR_FILENO else { throw OwnedRuntimeInstallFailure.source }
		var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else { throw OwnedRuntimeInstallFailure.source }
		defer { posix_spawn_file_actions_destroy(&actions) }
		guard posix_spawnattr_init(&attributes) == 0 else { throw OwnedRuntimeInstallFailure.source }
		defer { posix_spawnattr_destroy(&attributes) }
		guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
			posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO) == 0,
			posix_spawn_file_actions_adddup2(&actions, null, STDOUT_FILENO) == 0,
			posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0 else { throw OwnedRuntimeInstallFailure.source }
		for fd in [readEnd, writeEnd, null] {
			guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw OwnedRuntimeInstallFailure.source }
		}
		let argument = strdup("/bin/cat"), environment = strdup("LC_ALL=C")
		defer { if let argument { free(argument) }; if let environment { free(environment) } }
		guard let argument, let environment else { throw OwnedRuntimeInstallFailure.source }
		var argv: [UnsafeMutablePointer<CChar>?] = [argument, nil], env: [UnsafeMutablePointer<CChar>?] = [environment, nil]
		var child: pid_t = 0
		let result = argv.withUnsafeMutableBufferPointer { args in
			env.withUnsafeMutableBufferPointer { vars in posix_spawn(&child, "/bin/cat", &actions, &attributes, args.baseAddress, vars.baseAddress) }
		}
		guard result == 0, child > 0 else { throw OwnedRuntimeInstallFailure.source }
		pid = child; input = writeEnd; writeEnd = -1
		let originalRead = readEnd, originalNull = null; readEnd = -1; null = -1
		if Darwin.close(originalRead) != 0 { closeRefused = true }
		if Darwin.close(originalNull) != 0 { closeRefused = true }
	}
	deinit { _ = retire() }
	func closeInput() throws {
		guard input >= 0 else {
			if closeRefused { throw OwnedRuntimeInstallFailure.cleanupPending }; return
		}
		let original = input; input = -1
		guard Darwin.close(original) == 0 else { closeRefused = true; throw OwnedRuntimeInstallFailure.cleanupPending }
	}
	private func observeUntil(_ deadline: TimeInterval) -> Bool {
		if status != nil { return true }; if lost { return false }
		repeat {
			var observed: Int32 = 0
			let result = waitpid(pid, &observed, WNOHANG)
			if result == pid { status = observed; return true }
			if result == -1 && errno != EINTR { lost = true; return false }
			if ProcessInfo.processInfo.systemUptime >= deadline { return false }
			usleep(10_000)
		} while true
	}
	func waitForOrdinaryExit() throws -> Int32 {
		guard observeUntil(ProcessInfo.processInfo.systemUptime + 5), let status, status & 0x7f == 0,
			!closeRefused else { throw OwnedRuntimeInstallFailure.cleanupPending }
		return (status >> 8) & 0xff
	}
	func retire() -> Bool {
		do { try closeInput() } catch { closeRefused = true }
		if observeUntil(ProcessInfo.processInfo.systemUptime + 0.25) { return !closeRefused }
		guard !lost, status == nil else { return false }
		// Only this private unreaped child PID remains reserved through every signal; no Foundation process reaper owns it.
		guard Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH else { return false }
		if observeUntil(ProcessInfo.processInfo.systemUptime + 0.25) { return !closeRefused }
		guard !lost, status == nil else { return false }
		guard Darwin.kill(pid, SIGKILL) == 0 || errno == ESRCH else { return false }
		return observeUntil(ProcessInfo.processInfo.systemUptime + 5) && !closeRefused
	}
}
