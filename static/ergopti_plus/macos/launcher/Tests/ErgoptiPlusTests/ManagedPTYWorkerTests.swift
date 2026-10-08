// Tests/ErgoptiPlusTests/ManagedPTYWorkerTests.swift
// Actual native TTY bytes and process retirement remain independent evidence.

import CPOSIXCompatibility
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Sparkle
import XCTest
@testable import ErgoptiPlus

private final class ManagedPTYTestSession {
	enum Failure: Error { case prerequisite, deadline, retirement, stream }
	let root: URL
	let source: URL
	let receipt: URL
	let nonce = UUID().uuidString
	let process = Process()
	private let input = Pipe()
	private let output = Pipe()
	private let error = Pipe()
	private var outputEOF = false
	private var errorEOF = false
	private var provenRetired = false
	private(set) var bytes = Data()
	private(set) var errorBytes = Data()

	init(script: String, milliseconds: Int = 10_000, wrongDigest: Bool = false, inheritedStartup: Bool = false, sourceName: String = "ensure-mlx-deps.sh") throws {
		let manager = FileManager.default
		root = manager.temporaryDirectory.appendingPathComponent("ergopti-native-pty-" + UUID().uuidString).resolvingSymlinksInPath()
		let app = root.appendingPathComponent("Fixture.app")
		let contents = app.appendingPathComponent("Contents")
		let executable = contents.appendingPathComponent("MacOS/ErgoptiPlus")
		source = contents.appendingPathComponent("Resources/static/ergopti_plus/macos/modules/llm/" + sourceName)
		receipt = root.appendingPathComponent("receipt.json")
		try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let products = Bundle(for: ManagedPTYWorkerTests.self).bundleURL.deletingLastPathComponent()
		let candidates = [products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
		guard let original = candidates.first(where: { manager.isExecutableFile(atPath: $0.path) }) else {
			throw Failure.prerequisite
		}
		try manager.copyItem(at: original, to: executable)
		let frameworks = contents.appendingPathComponent("Frameworks")
		try manager.createDirectory(at: frameworks, withIntermediateDirectories: false)
		try manager.copyItem(at: Bundle(for: SPUUpdater.self).bundleURL, to: frameworks.appendingPathComponent("Sparkle.framework"))
		try PropertyListSerialization.data(fromPropertyList: [
			"CFBundleIdentifier": "org.ergoptiplus.native-pty." + nonce,
			"CFBundleExecutable": "ErgoptiPlus", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
		], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
		let sourceBytes = Data(script.utf8)
		try sourceBytes.write(to: source)
		guard manager.createFile(atPath: receipt.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
			throw Failure.prerequisite
		}
		let digest = wrongDigest ? String(repeating: "0", count: 64) : SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
		var pairs = [["PROJECT_ROOT", root.path]]
		if sourceName == "ensure-ollama-deps.sh" {
			pairs += [["ERGOPTI_NATIVE_ARCH", "arm64"], ["ERGOPTI_NATIVE_PYTHONS", ""],
				["ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN", ""],
				["ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR", root.appendingPathComponent("Library/Application Support/Ergopti/ollama").path],
				["ERGOPTI_BOOTSTRAP_PYTHON", ""]]
			var environment = ProcessInfo.processInfo.environment; environment["HOME"] = root.path
			process.environment = environment
		}
		let request: [String: Any] = ["version": 1, "source_path": source.path, "source_sha256": digest,
			"environment": pairs, "timeout_ms": milliseconds,
			"receipt_path": receipt.path, "nonce": nonce]
		process.executableURL = executable
		process.arguments = ["--managed-pty-worker", String(milliseconds)]
		if inheritedStartup {
			let startup = root.appendingPathComponent("foreign-bash-env")
			try Data("printf UNADMITTED-STARTUP\nexit 93\n".utf8).write(to: startup)
			var environment = ProcessInfo.processInfo.environment
			environment["BASH_ENV"] = startup.path
			process.environment = environment
		}
		if sourceName == "ensure-ollama-native-deps.sh" {
			var environment = ProcessInfo.processInfo.environment
			environment["ERGOPTI_BOOTSTRAP_TIMEOUT_MS"] = "999999999"
			process.environment = environment
		}
		process.standardInput = input
		process.standardOutput = output
		process.standardError = error
		try process.run()
		try input.fileHandleForReading.close()
		try output.fileHandleForWriting.close()
		try error.fileHandleForWriting.close()
		guard ManagedPTYWorker.nonblocking(output.fileHandleForReading.fileDescriptor),
			ManagedPTYWorker.nonblocking(error.fileHandleForReading.fileDescriptor) else { throw Failure.stream }
		var payload = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
		payload.append(10)
		try input.fileHandleForWriting.write(contentsOf: payload)
		try input.fileHandleForWriting.close()
	}

	private func drain(_ handle: FileHandle, into destination: inout Data, eof: inout Bool) throws {
		guard !eof else { return }
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
			if count > 0 {
				guard destination.count + count <= 1_048_576 else { throw Failure.stream }
				destination.append(contentsOf: buffer.prefix(count))
			} else if count == 0 { eof = true; return }
			else if errno == EINTR { continue }
			else if errno == EAGAIN || errno == EWOULDBLOCK { return }
			else { throw Failure.stream }
		}
	}

	func wait(seconds: TimeInterval = 30, until predicate: () -> Bool) throws {
		let started = ProcessInfo.processInfo.systemUptime
		while true {
			try drain(output.fileHandleForReading, into: &bytes, eof: &outputEOF)
			try drain(error.fileHandleForReading, into: &errorBytes, eof: &errorEOF)
			if predicate() { return }
			guard ProcessInfo.processInfo.systemUptime - started < seconds else { throw Failure.deadline }
			var event = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
			_ = Darwin.poll(&event, 1, 20)
		}
	}

	func finish(worker: Int32, admitted: Bool, exit: Int? = nil) throws {
		try wait { !process.isRunning && outputEOF && errorEOF }
		process.waitUntilExit()
		XCTAssertEqual(process.terminationReason, .exit)
		XCTAssertEqual(process.terminationStatus, worker)
		XCTAssertTrue(errorBytes.isEmpty, "PTY stderr belongs to the same native terminal stream")
		let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
		let keys: Set<String> = ["version", "nonce", "state", "group_retired", "guardian_reaped", "pty_eof",
			"handles_closed", "status_valid", "exit_status", "worker_status", "source_admitted"]
		XCTAssertEqual(Set(fields.keys), keys)
		XCTAssertEqual(fields["version"] as? Int, 1)
		XCTAssertEqual(fields["nonce"] as? String, nonce)
		XCTAssertEqual(fields["state"] as? String, "retired")
		for key in ["group_retired", "guardian_reaped", "pty_eof", "handles_closed", "status_valid", "source_admitted"] {
			let number = try XCTUnwrap(fields[key] as? NSNumber)
			XCTAssertEqual(CFGetTypeID(number), CFBooleanGetTypeID(), "Literal native boolean: " + key)
			XCTAssertEqual(number.boolValue, key == "source_admitted" ? admitted : true)
		}
		let payloadStatus = try XCTUnwrap(fields["exit_status"] as? NSNumber)
		let workerStatus = try XCTUnwrap(fields["worker_status"] as? NSNumber)
		XCTAssertNotEqual(CFGetTypeID(payloadStatus), CFBooleanGetTypeID())
		XCTAssertNotEqual(CFGetTypeID(workerStatus), CFBooleanGetTypeID())
		XCTAssertTrue((0...255).contains(payloadStatus.intValue))
		XCTAssertEqual(workerStatus.int32Value, worker)
		if let exit { XCTAssertEqual(payloadStatus.intValue, exit) }
		guard process.terminationReason == .exit, process.terminationStatus == worker,
			Set(fields.keys) == keys, fields["nonce"] as? String == nonce,
			fields["state"] as? String == "retired",
			["group_retired", "guardian_reaped", "pty_eof", "handles_closed", "status_valid"].allSatisfy({
				guard let value = fields[$0] as? NSNumber else { return false }
				return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
			}), workerStatus.int32Value == worker else { throw Failure.retirement }
		provenRetired = true
	}

	func cleanup() {
		do {
			if process.isRunning { process.terminate(); try wait { !process.isRunning && outputEOF && errorEOF } }
			try output.fileHandleForReading.close()
			try error.fileHandleForReading.close()
			guard provenRetired else {
				XCTFail("native PTY retirement is unproven; fixture retained at " + root.path)
				return
			}
			try FileManager.default.removeItem(at: root)
		} catch { XCTFail("native PTY cleanup remains unverified; fixture retained at " + root.path) }
	}

	func finishBridgeHardDeath(observations: [ergopti_owned_program_observation]) throws {
		try wait { !process.isRunning && outputEOF && errorEOF }
		process.waitUntilExit()
		XCTAssertEqual(process.terminationReason, .uncaughtSignal)
		XCTAssertEqual(process.terminationStatus, SIGKILL)
		XCTAssertEqual(try Data(contentsOf: receipt).count, 0,
			"A dead bridge cannot claim that it reaped its surviving guardian")
		for original in observations {
			let current = ergopti_owned_program_observe(original.process_id)
			let identityGone = current.error_code == ESRCH || current.error_code == ENOENT
			let sameIdentity = current.start_seconds == original.start_seconds
				&& current.start_microseconds == original.start_microseconds
			guard identityGone || (current.error_code == 0 && (!sameIdentity || current.nonlive)) else {
				throw Failure.retirement
			}
		}
		// These observations belong to this literal, bounded fixture scope. They
		// permit fixture cleanup, while its absent receipt keeps UI admission shut.
		provenRetired = true
	}
}

final class ManagedPTYWorkerTests: XCTestCase {
	func testRetainedSourceSnapshotCannotFollowLaterPathReplacement() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: root) }
		let source = root.appendingPathComponent("source.sh")
		try Data("abc".utf8).write(to: source)
		let request = ManagedPTYRequest(sourcePath: source.path,
			sourceSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
			environment: [], timeoutMilliseconds: 1000, receiptPath: root.appendingPathComponent("receipt").path,
			nonce: "independent-snapshot")
		let descriptor = try XCTUnwrap(ManagedPTYSource.snapshot(request, interrupted: { false }))
		defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
		var info = stat()
		XCTAssertEqual(fstat(descriptor, &info), 0)
		XCTAssertEqual(info.st_nlink, 0, "No later pathname lookup can replace the admitted source")
		XCTAssertEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
		XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
		try FileManager.default.removeItem(at: source)
		try Data("foreign".utf8).write(to: source)
		var bytes = [UInt8](repeating: 0, count: 16)
		let count = Darwin.read(descriptor, &bytes, bytes.count)
		XCTAssertEqual(count, 3)
		XCTAssertEqual(Data(bytes.prefix(max(0, count))), Data("abc".utf8))
		XCTAssertNil(ManagedPTYSource.snapshot(request, interrupted: { false }), "The changed source no longer matches the independent pin")
	}

	func testPrivateAdmissionRejectsBooleanBudgetCommandsAndEnvironmentOverrides() throws {
		var fields: [String: Any] = ["version": 1, "source_path": "/owned/ensure-mlx-deps.sh",
			"source_sha256": String(repeating: "a", count: 64), "environment": [["PROJECT_ROOT", "/owned"]],
			"timeout_ms": 3000, "receipt_path": "/owned/receipt", "nonce": "literal-owned-1"]
		XCTAssertNotNil(ManagedPTYRequest.parse(try JSONSerialization.data(withJSONObject: fields)))
		for (key, value) in [("version", true as Any), ("timeout_ms", true), ("timeout_ms", 3.5),
			("source_sha256", String(repeating: "x", count: 64)), ("nonce", "escaped\"value"),
			("environment", [["PATH", "/foreign"]]), ("environment", [["PROJECT_ROOT", "/one"], ["PROJECT_ROOT", "/two"]])] {
			var invalid = fields
			invalid[key] = value
			XCTAssertNil(ManagedPTYRequest.parse(try JSONSerialization.data(withJSONObject: invalid)), key)
		}
		fields["command"] = ["/bin/echo", "foreign"]
		XCTAssertNil(ManagedPTYRequest.parse(try JSONSerialization.data(withJSONObject: fields)))
		var owner: OpaquePointer?
		XCTAssertEqual(ergopti_owned_program_prepare_with_tty_source("/bin/bash", nil, nil, -1, -1, &owner), EINVAL)
		XCTAssertNil(owner, "A rejected borrowed capability cannot create native cleanup debt")
	}

	func testActualTTYAndRawChildReceiptSpoofCannotReplacePrivilegedClosure() throws {
		let session = try ManagedPTYTestSession(script: """
		#!/bin/bash
		test -t 0 && test -t 1 && test -t 2 || exit 91
		printf 'PTY-OWNED\\000BYTES\\n'
		printf 'RETIRED 0 0 1\\n'
		printf 'stderr-on-tty\\n' >&2
		test "$ERGOPTI_BOOTSTRAP_SCRIPT_DIR" = "${PROJECT_ROOT}/Fixture.app/Contents/Resources/static/ergopti_plus/macos/modules/llm" || exit 92
		exit 7
		""" + "\n", inheritedStartup: true)
		defer { session.cleanup() }
		try session.finish(worker: 7, admitted: true, exit: 7)
		XCTAssertNotNil(session.bytes.range(of: Data("PTY-OWNED\0BYTES".utf8)))
		XCTAssertNotNil(session.bytes.range(of: Data("RETIRED 0 0 1".utf8)))
		XCTAssertNotNil(session.bytes.range(of: Data("stderr-on-tty".utf8)))
		XCTAssertNil(session.bytes.range(of: Data("UNADMITTED-STARTUP".utf8)))
	}

	func testSourcePinRefusesBeforePayloadAndReportsClosedEmptyScope() throws {
		let session = try ManagedPTYTestSession(script: "#!/bin/bash\nprintf forbidden-payload\n", wrongDigest: true)
		defer { session.cleanup() }
		try session.finish(worker: 64, admitted: false, exit: 64)
		XCTAssertTrue(session.bytes.isEmpty)
	}

	func testTerminalEOFBeforeLeaderExitIsNotCancellationOrRetirement() throws {
		let session = try ManagedPTYTestSession(script: """
		#!/bin/bash
		printf 'CLOSING-TTY\\n'
		exec 0<&- 1>&- 2>&-
		/bin/sleep 0.2
		exit 0
		""" + "\n")
		defer { session.cleanup() }
		try session.finish(worker: 0, admitted: true, exit: 0)
		XCTAssertNotNil(session.bytes.range(of: Data("CLOSING-TTY".utf8)))
	}

	func testPauseRetainsLeaderUntilLingeringNativeGroupAndPTYAreClosed() throws {
		let session = try ManagedPTYTestSession(script: """
		#!/bin/bash
		/bin/sleep 30 &
		printf '%s\\n' "$!" > "$PROJECT_ROOT/child.pid"
		printf 'LEADER-EXITING\\n'
		exit 0
		""" + "\n")
		defer { session.cleanup() }
		try session.wait { session.bytes.range(of: Data("LEADER-EXITING".utf8)) != nil }
		let childText = try String(contentsOf: session.root.appendingPathComponent("child.pid"), encoding: .utf8)
		let child = try XCTUnwrap(pid_t(childText.trimmingCharacters(in: .whitespacesAndNewlines)))
		let initial = ergopti_owned_program_observe(child)
		XCTAssertEqual(initial.error_code, 0)
		XCTAssertFalse(initial.nonlive)
		XCTAssertTrue(session.process.isRunning, "Leader EOF cannot release a live native descendant")
		XCTAssertEqual(try Data(contentsOf: session.receipt).count, 0)
		session.process.terminate()
		try session.finish(worker: 130, admitted: true, exit: 0)
		let final = ergopti_owned_program_observe(child)
		XCTAssertTrue(final.error_code == ESRCH || final.error_code == ENOENT || final.nonlive,
			"The original descendant must be nonlive before successor admission")
	}

	func testOriginalDeadlineCancelsActualTerminalOwnerBeforeReceipt() throws {
		let session = try ManagedPTYTestSession(script: "#!/bin/bash\nprintf WAITING\n/bin/sleep 30\n", milliseconds: 2000)
		defer { session.cleanup() }
		let started = ProcessInfo.processInfo.systemUptime
		try session.finish(worker: 124, admitted: true)
		XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 10)
	}

	func testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope() throws {
		let session = try ManagedPTYTestSession(script: """
		#!/bin/bash
		/bin/sleep 30 &
		printf '%s %s %s\\n' "$$" "$PPID" "$!" > "$PROJECT_ROOT/scope.pids"
		printf 'SCOPE-READY\\n'
		wait
		""" + "\n")
		defer { session.cleanup() }
		try session.wait { session.bytes.range(of: Data("SCOPE-READY".utf8)) != nil }
		let text = try String(contentsOf: session.root.appendingPathComponent("scope.pids"), encoding: .utf8)
		let pids = text.split(whereSeparator: { $0.isWhitespace }).compactMap { pid_t($0) }
		XCTAssertEqual(pids.count, 3)
		let originals = pids.map { ergopti_owned_program_observe($0) }
		guard originals.count == 3, originals.allSatisfy({ $0.error_code == 0 && !$0.nonlive }),
			session.process.isRunning else { throw ManagedPTYTestSession.Failure.retirement }
		XCTAssertEqual(Darwin.kill(session.process.processIdentifier, SIGKILL), 0)
		try session.finishBridgeHardDeath(observations: originals)
	}

	func testSecondPinnedInstallerUsesActualTTYRetainedSourceAndOriginalBudget() throws {
		let session = try ManagedPTYTestSession(script: """
		#!/bin/bash
		test "$0" = /dev/fd/3 || exit 91
		test -t 0 && test -t 1 && test -t 2 || exit 92
		test "$ERGOPTI_BOOTSTRAP_SCRIPT_DIR" = "${PROJECT_ROOT}/Fixture.app/Contents/Resources/static/ergopti_plus/macos/modules/llm" || exit 93
		case "$ERGOPTI_BOOTSTRAP_TIMEOUT_MS" in ''|*[!0-9]*) exit 94;; esac
		test "$ERGOPTI_BOOTSTRAP_TIMEOUT_MS" -gt 0 && test "$ERGOPTI_BOOTSTRAP_TIMEOUT_MS" -le 5000 || exit 95
		printf 'SECOND-INSTALLER-OWNED\\n'
		""" + "\n", milliseconds: 5000, sourceName: "ensure-ollama-native-deps.sh")
		defer { session.cleanup() }
		try session.finish(worker: 0, admitted: true, exit: 0)
		XCTAssertTrue(session.bytes.range(of: Data("SECOND-INSTALLER-OWNED".utf8)) != nil)
	}

	func testThirdInstallerCannotBorrowTheSecondPinnedSourceAdmission() throws {
		let session = try ManagedPTYTestSession(script: "#!/bin/bash\nprintf UNADMITTED-INSTALLER\n", sourceName: "unadmitted-bootstrap.sh")
		defer { session.cleanup() }
		try session.finish(worker: 64, admitted: false, exit: 64)
		XCTAssertTrue(session.bytes.isEmpty)
	}

	func testOfficialThirdPinnedInstallerReceivesOnlyItsPrivateEnvironmentContract() throws {
		let session = try ManagedPTYTestSession(script: """
		#!/bin/bash
		test "$0" = /dev/fd/3 && test -t 0 && test -t 1 && test -t 2 || exit 91
		test -z "$ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN" && test -z "$ERGOPTI_BOOTSTRAP_PYTHON" || exit 92
		test "$ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR" = "$HOME/Library/Application Support/Ergopti/ollama" || exit 93
		test "$ERGOPTI_BOOTSTRAP_TIMEOUT_MS" -gt 0 && test "$ERGOPTI_BOOTSTRAP_TIMEOUT_MS" -le 5000 || exit 94
		printf 'OFFICIAL-INSTALLER-PRIVATE-INPUT\\n'
		""" + "\n", milliseconds: 5000, sourceName: "ensure-ollama-deps.sh")
		defer { session.cleanup() }
		try session.finish(worker: 0, admitted: true, exit: 0)
		XCTAssertNotNil(session.bytes.range(of: Data("OFFICIAL-INSTALLER-PRIVATE-INPUT".utf8)))
	}
}
