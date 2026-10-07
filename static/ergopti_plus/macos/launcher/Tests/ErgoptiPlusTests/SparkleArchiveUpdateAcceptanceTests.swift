// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift
//
// Actual Sparkle updates target a separately compiled private application.
// XCTest, product installations, public feeds and the login Keychain stay outside
// the fixture. No native prerequisite is replaced with a stub or a skip.

import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Sparkle
import XCTest

final class SparkleArchiveUpdateAcceptanceTests: XCTestCase {
	private enum NativeCommandPhase: String {
		case nativeTool = "native-tool"
		case archiveBuild = "archive-build"
		case archiveSign = "archive-sign"
		case archiveSignForeign = "archive-sign-foreign"
		case generatedAppcast = "generated-appcast"
		case nativeProcessCensus = "native-process-census"
	}

	private enum Failure: Error {
		case prerequisite(String)
		case command(NativeCommandPhase, Int32)
		case deadline(String)
		case evidence(String)
	}

	private var phaseEvidence: ArchiveAcceptanceEvidence?
	private var evidenceRefused = false
	private func checkpoint(_ phase: String, status: String = "pending", closed: Bool = false, pids: [Int32] = []) {
		if let phaseEvidence, !phaseEvidence.record(phase, status: status, closed: closed, ownedPIDs: pids), !evidenceRefused {
			evidenceRefused = true
			XCTFail("Safe Sparkle phase evidence publication refused")
		}
	}

	private enum ObservedTermination {
		case unavailable
		case exit(Int32)
		case signal(Int32)
	}

	private enum StartupPhase: String, CaseIterable {
		case pythonEntry = "python-entry", importsReady = "imports-ready", cliDispatch = "cli-dispatch"
		case directoryAdmitted = "directory-admitted", nonceAdmitted = "nonce-admitted", socketBound = "socket-bound"
		case handlersInstalled = "handlers-installed", startPublishing = "start-publishing"
		case startPublished = "start-published", loopEntered = "loop-entered"
		case retirementBegin = "retirement-begin", retiredPublished = "retired-published"
	}

	private enum StartupCaptureCode: String { case unavailable, empty, malformed, observed }

	private struct StartupFacts {
		let capture: StartupCaptureCode
		let phase: StartupPhase?
		let bytes: Int?
		static let unavailable = StartupFacts(capture: .unavailable, phase: nil, bytes: nil)
	}

	/// Complete closed frames only; malformed or missing capture is no progress proof.
	private static func parseStartupFrames(_ bytes: Data) -> StartupFacts {
		guard bytes.count <= 512 else { return .unavailable }
		if bytes.isEmpty { return StartupFacts(capture: .empty, phase: nil, bytes: 0) }
		guard bytes.allSatisfy({ $0 < 128 }), bytes.last == 10,
			let text = String(data: bytes, encoding: .utf8) else {
			return StartupFacts(capture: .malformed, phase: nil, bytes: bytes.count)
		}
		let lines = String(text.dropLast()).components(separatedBy: "\n")
		guard lines.count <= StartupPhase.allCases.count else {
			return StartupFacts(capture: .malformed, phase: nil, bytes: bytes.count)
		}
		var last: StartupPhase?
		var index = -1
		for line in lines {
			let prefix = "SPARKLE_STARTUP/1 "
			guard line.hasPrefix(prefix), let phase = StartupPhase(rawValue: String(line.dropFirst(prefix.count))),
				let observed = StartupPhase.allCases.firstIndex(of: phase), observed > index,
				index != -1 || phase == .pythonEntry else {
				return StartupFacts(capture: .malformed, phase: nil, bytes: bytes.count)
			}
			index = observed; last = phase
		}
		return StartupFacts(capture: .observed, phase: last, bytes: bytes.count)
	}


	private enum UpdateProgressEvent: String, CaseIterable {
		case e0 = "started-1", e1 = "started-2", e2 = "updater-start-attempt"
		case e3 = "updater-started", e4 = "updater-policy-admitted", e5 = "check-requested-1"
		case e6 = "check-requested-2", e7 = "user-check-1", e8 = "user-check-2"
		case e9 = "start-refused", e10 = "unexpected-permission-1", e11 = "unexpected-permission-2"
		case e12 = "offer-refused-1", e13 = "offer-refused-2", e14 = "offered-1"
		case e15 = "offered-2", e16 = "not-found-1", e17 = "not-found-2"
		case e18 = "refused-1", e19 = "refused-2", e20 = "routed-1"
		case e21 = "routed-2", e22 = "download-1", e23 = "download-2"
		case e24 = "extracting-1", e25 = "extracting-2", e26 = "ready-1"
		case e27 = "ready-2", e28 = "installing-1", e29 = "installing-2"
		case e30 = "relaunch-requested-2", e31 = "cycle-refused-1", e32 = "cycle-refused-2"
		case e33 = "retry-accepted", e34 = "terminated-1", e35 = "terminated-2"
		case e36 = "transport-refused-1", e37 = "transport-refused-2", e38 = "control-refused-1"
		case e39 = "control-refused-2", e40 = "deadline-1", e41 = "deadline-2"
	}
	private enum UpdateProgressCapture: String { case unavailable, empty, malformed, observed }
	private struct UpdateProgressFacts {
		let capture: UpdateProgressCapture
		let events: [UpdateProgressEvent]
		static let unavailable = UpdateProgressFacts(capture: .unavailable, events: [])
	}

	/// Parse only complete fixed frames from the existing physically retired
	/// direct child's cached receipt. An inherited/relaunched PID is not borrowed.
	private static func parseUpdateProgress(_ text: String, expectedPID: Int32) -> UpdateProgressFacts {
		guard expectedPID > 0, text.utf8.count <= 4096 else { return .unavailable }
		if text.isEmpty { return UpdateProgressFacts(capture: .empty, events: []) }
		guard text.utf8.allSatisfy({ $0 < 128 }), text.hasSuffix("\n") else {
			return UpdateProgressFacts(capture: .malformed, events: [])
		}
		let lines = String(text.dropLast()).components(separatedBy: "\n")
		guard lines.count <= UpdateProgressEvent.allCases.count else { return .unavailable }
		let prefix = "SPARKLE_PROGRESS/1 pid=" + String(expectedPID) + " event="
		var events: [UpdateProgressEvent] = []
		for line in lines {
			guard line.hasPrefix(prefix), let event = UpdateProgressEvent(rawValue: String(line.dropFirst(prefix.count))),
				!events.contains(event) else {
				return UpdateProgressFacts(capture: .malformed, events: [])
			}
			events.append(event)
		}
		guard events.first == .e0 else { return UpdateProgressFacts(capture: .malformed, events: []) }
		return UpdateProgressFacts(capture: .observed, events: events)
	}

	private func updateProgressMessage(_ facts: UpdateProgressFacts) -> String {
		let events = facts.capture == .observed ? facts.events.map { $0.rawValue }.joined(separator: ",") : "unavailable"
		return "Native Sparkle update progress: capture=" + facts.capture.rawValue + " events=" + events
	}

	/// This existing counter is incremented after real resource read+close,
	/// before response writing. It does not acknowledge network delivery.
	private func resourceReadsMessage(_ value: Any?) -> String {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
			number.doubleValue.isFinite, (0...64).contains(number.intValue),
			number.doubleValue == Double(number.intValue) else {
			return "Native Sparkle network progress: admitted_resource_reads=unavailable"
		}
		return "Native Sparkle network progress: admitted_resource_reads=" + String(number.intValue)
	}

	private enum ChildRefusalCode: String, CaseIterable {
		case configuration, targetRoot = "target-root", targetBundle = "target-bundle"
		case receiptPublication = "receipt-publication", control, transport
	}

	/// Interpret only a single complete fixed frame from the existing private capture.
	/// Arbitrary native log lines, error descriptions and paths never become facts.
	private static func parseChildRefusalCode(_ text: String) -> String {
		guard !text.isEmpty, text.utf8.count <= 16_384, text.hasSuffix("\n") else { return "unavailable" }
		let prefix = "SPARKLE_CHILD_REFUSAL/1 "
		let frames = text.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
		guard frames.count == 1, let frame = frames.first,
			let code = ChildRefusalCode(rawValue: String(frame.dropFirst(prefix.count))) else { return "unavailable" }
		return code.rawValue
	}

	private struct Receipt {
		let status: Int32
		let stdout: String
		let stderr: String
	}

	private final class OwnedProcess {
		let process = Process()
		let completed = DispatchSemaphore(value: 0)
		let stdout: URL
		let stderr: URL
		let streams: [FileHandle]
		let guardianReceipt: URL?
		let originalExecutable: String
		private var launched = false
		private var startRequested = false
		private var observedExit = false
		private var closedStreams: Set<Int> = []
		private var cachedReceipt: Receipt?
		private let startupDiagnostics: Bool
		private var startupObserved = false
		private var startupNoticeEmitted = false
		private var startupFacts = StartupFacts.unavailable

		init(_ executable: String, _ arguments: [String], root: URL,
			guarded: Bool = false, workerTimeout: Double = 60, startupDiagnostics: Bool = false) throws {
			self.startupDiagnostics = startupDiagnostics
			let identity = UUID().uuidString
			originalExecutable = executable
			stdout = root.appendingPathComponent(identity + ".stdout")
			stderr = root.appendingPathComponent(identity + ".stderr")
			guardianReceipt = guarded ? root.appendingPathComponent(identity + ".group.json") : nil
			func capture(_ url: URL, readable: Bool = false) throws -> FileHandle {
				let descriptor: Int32
				if readable { descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
				else { descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
				guard descriptor >= 0 else { throw Failure.evidence("child-capture") }
				return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			}
			let output = try capture(stdout, readable: startupDiagnostics)
			do { streams = [output, try capture(stderr)] }
			catch { try? output.close(); throw error }
			if let guardianReceipt {
				var owner = URL(fileURLWithPath: #filePath)
				for _ in 0..<7 { owner.deleteLastPathComponent() }
				owner.appendPathComponent("tools/diagnostics/macos_owned_process.py")
				process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
				process.arguments = ["python3", owner.path, "run", guardianReceipt.path,
					String(workerTimeout), "--", executable] + arguments
			} else {
				process.executableURL = URL(fileURLWithPath: executable)
				process.arguments = arguments
			}
			process.environment = NativeFixtureChildEnvironment.make()
			if startupDiagnostics { process.environment?["ERGOPTI_SPARKLE_STARTUP_DIAGNOSTICS"] = "1" }
			process.standardOutput = streams[0]
			process.standardError = streams[1]
			process.terminationHandler = { [completed] _ in completed.signal() }
		}

		/// The caller registers this owner before attempting a native launch.
		/// Even a partially successful Foundation launch remains eligible for retry.
		func start() throws {
			guard !startRequested else { throw Failure.evidence("duplicate-native-launch") }
			startRequested = true
			do {
				try process.run()
				launched = true
			} catch {
				// A failed launch still owns both descriptors, and any native PID
				// acquired before Foundation reported the failure.
				launched = process.processIdentifier > 0
				try? retire()
				throw error
			}
		}

		private func observeExit(_ seconds: Double) -> Bool {
			if observedExit { return !process.isRunning }
			guard completed.wait(timeout: .now() + seconds) == .success else { return false }
			observedExit = true
			let ended = !process.isRunning
			if ended { observeStartupCapture() }
			return ended
		}

		private func closeCaptures() throws {
			var refused = false
			for (index, stream) in streams.enumerated() where !closedStreams.contains(index) {
				do { try stream.close(); closedStreams.insert(index) }
				catch { refused = true }
			}
			guard !refused, closedStreams.count == streams.count else {
				throw Failure.evidence("native-capture-retirement")
			}
		}

		/// The shared native guardian keeps WNOWAIT's leader reservation through
		/// PGID signals/census and reaps last. Its terminal ACK covers descendants
		/// that use system executable paths outside this fixture's path census.
		private func admitGuardRetirement() throws {
			guard let guardianReceipt else { return }
			let descriptor = open(guardianReceipt.path, O_RDONLY | O_NOFOLLOW)
			guard descriptor >= 0 else { throw Failure.evidence("owned-process-group-terminal") }
			let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			let data: Data
			do {
				data = try stream.readToEnd() ?? Data()
				try stream.close()
			} catch { try? stream.close(); throw error }
			guard data.count < 16_384,
				let packet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
				Set(packet.keys) == Set(["schema", "guardian_pid", "worker_pid", "group_id", "closed", "exit_status"]),
				packet["schema"] as? Int == 1,
				(packet["guardian_pid"] as? NSNumber)?.int32Value == process.processIdentifier,
				let worker = packet["worker_pid"] as? Int, worker > 0,
				packet["group_id"] as? Int == worker, packet["closed"] as? Bool == true else {
				throw Failure.evidence("owned-process-group-terminal")
			}
			let status = process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
			guard (packet["exit_status"] as? NSNumber)?.int32Value == status else {
				throw Failure.evidence("owned-process-group-status")
			}
		}

		/// Retirement can be retried after any failure. It only signals this
		/// unreaped direct child; the private launchd installer has a separate owner.
		func retire() throws {
			if !launched { try closeCaptures(); return }
			if !observedExit, !observeExit(0) {
				if process.isRunning { process.terminate() }
				if !observeExit(guardianReceipt == nil ? 5 : 10) {
					// Hard-killing a guardian would discard the still-reserved leader's
					// group identity. Keep that owner alive and retry it independently.
					guard guardianReceipt == nil else { throw Failure.evidence("owned-process-group-retirement-debt") }
					if process.isRunning {
						guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else {
							throw Failure.evidence("exact-native-child-kill")
						}
					}
					guard observeExit(5) else { throw Failure.evidence("native-child-reap") }
				}
			}
			guard observedExit, !process.isRunning else {
				throw Failure.evidence("native-child-retirement")
			}
			try closeCaptures()
			try admitGuardRetirement()
		}

		/// Reuse the still-owned output descriptor after the existing native exit ACK.
		/// No path reopen, new FD, wait, signal or closure owner is introduced.
		private func observeStartupCapture() {
			guard startupDiagnostics, launched, observedExit, !startupObserved, !closedStreams.contains(0) else { return }
			startupObserved = true // A refused capture never borrows a later descriptor.
			var metadata = stat()
			guard fstat(streams[0].fileDescriptor, &metadata) == 0,
				metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
				metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1,
				metadata.st_size >= 0, metadata.st_size <= 512 else { return }
			if metadata.st_size == 0 {
				startupFacts = StartupFacts(capture: .empty, phase: nil, bytes: 0); return
			}
			do {
				try streams[0].seek(toOffset: 0)
				guard let bytes = try streams[0].read(upToCount: 513), bytes.count == Int(metadata.st_size) else { return }
				startupFacts = SparkleArchiveUpdateAcceptanceTests.parseStartupFrames(bytes)
			} catch { startupFacts = .unavailable }
		}

		private func emitStartupNoticeOnce() {
			guard startupDiagnostics, !startupNoticeEmitted else { return }
			startupNoticeEmitted = true
			let phase = startupFacts.phase?.rawValue ?? "unavailable"
			let bytes = startupFacts.bytes.map { String($0) } ?? "unavailable"
			print("::notice title=Native Sparkle startup::phase=" + phase + " capture=" + startupFacts.capture.rawValue + " bytes=" + bytes)
		}

		/// Report only a native exit already acknowledged by this owner.
		/// Diagnostics never acquire another wait or alter child retirement.
		func observedTerminationFacts() -> ObservedTermination {
			guard launched, observedExit, !process.isRunning else { return .unavailable }
			emitStartupNoticeOnce()
			let status = process.terminationStatus
			switch process.terminationReason {
			case .exit where (0...255).contains(status): return .exit(status)
			case .uncaughtSignal where (1...64).contains(status): return .signal(status)
			default: return .unavailable
			}
		}

		/// Repeated observations reuse the physical exit ACK and immutable receipt;
		/// consuming the semaphore once can never turn an exited child into a timeout.
		func finish(_ seconds: Double) throws -> Receipt {
			if let cachedReceipt { return cachedReceipt }
			guard launched else { throw Failure.evidence("unlaunched-native-child") }
			guard observeExit(seconds) else {
				let primary = Failure.deadline(URL(fileURLWithPath: originalExecutable).lastPathComponent)
				try? retire()
				throw primary
			}
			try closeCaptures()
			try admitGuardRetirement()
			guard process.terminationReason == .exit else { throw Failure.evidence("native-child-signal") }
			let output = try Data(contentsOf: stdout)
			let errors = try Data(contentsOf: stderr)
			guard output.count < 4_000_000, errors.count < 4_000_000,
				let outputText = String(data: output, encoding: .utf8),
				let errorText = String(data: errors, encoding: .utf8) else {
				throw Failure.evidence("native-child-capture")
			}
			let receipt = Receipt(status: process.terminationStatus, stdout: outputText, stderr: errorText)
			cachedReceipt = receipt
			return receipt
		}

		/// The original finish() has already joined exit and closed both captures.
		/// No path reopen, descriptor, wait, signal or retirement attempt is added.

		/// finish() already acquired the actual exit ACK, closed captures and
		/// populated this immutable receipt. No new FD/wait/poll/signal is used.
		func observedUpdateProgress() -> UpdateProgressFacts {
			guard launched, observedExit, let cachedReceipt else { return .unavailable }
			return SparkleArchiveUpdateAcceptanceTests.parseUpdateProgress(cachedReceipt.stdout,
				expectedPID: process.processIdentifier)
		}

		func observedChildRefusalCode() -> String? {
			guard launched, observedExit, !process.isRunning, let cachedReceipt,
				cachedReceipt.status == 78 else { return nil }
			return SparkleArchiveUpdateAcceptanceTests.parseChildRefusalCode(cachedReceipt.stderr)
		}
	}

	private enum SignatureProbe: String { case installedKey = "installed-key", foreignKey = "foreign-key" }

	/// Closed cryptographic observations contain no signature, seed or archive bytes.
	private func signatureProbeMessage(_ probe: SignatureProbe, signature64: Bool, independentValid: Bool,
		installedValid: Bool, payloadEqual: Bool?, signatureEqual: Bool?) -> String {
		func fact(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "unavailable" }
		return "Native Sparkle signature facts: probe=" + probe.rawValue
			+ " signature64=" + fact(signature64) + " independent_valid=" + fact(independentValid)
			+ " installed_valid=" + fact(installedValid) + " payload_equal=" + fact(payloadEqual)
			+ " signature_equal=" + fact(signatureEqual)
	}

	/// Reuse the already bounded exit formatter; application status uses its own fixed label.
	private func applicationExitRefusalMessage(_ error: Error, termination: ObservedTermination) -> String {
		let projected: Error
		if case Failure.evidence(let fact) = error, fact == "application-retirement" {
			projected = Failure.evidence("server-retirement")
		} else { projected = error }
		return serverExitRefusalMessage(projected, termination: termination)
			.replacingOccurrences(of: "Native Sparkle server retirement refusal:",
				with: "Native Sparkle application retirement refusal:")
	}

	private let manager = FileManager.default
	private var commands: [OwnedProcess] = []
	private var retirementDebt = false

	/// Only fixed failure classes and bounded already-observed facts cross XCTest.
	private func serverExitRefusalMessage(_ error: Error, termination: ObservedTermination) -> String {
		let code: String
		switch error {
		case Failure.deadline: code = "deadline"
		case Failure.evidence(let fact):
			switch fact {
			case "server-retirement": code = "exit-status"
			case "native-child-signal": code = "native-signal"
			case "native-capture-retirement": code = "capture-retirement"
			case "native-child-capture": code = "capture-admission"
			case "unlaunched-native-child": code = "unlaunched"
			default: code = "unavailable"
			}
		default: code = "unavailable"
		}
		let reason: String
		let status: String
		switch termination {
		case .exit(let value) where (0...255).contains(value): reason = "exit"; status = String(value)
		case .signal(let value) where (1...64).contains(value): reason = "signal"; status = String(value)
		default: reason = "unavailable"; status = "unavailable"
		}
		return "Native Sparkle server retirement refusal: code=" + code + " native_reason=" + reason + " native_status=" + status
	}

	private struct OwnedCensusDirectory {
		let originalSpelling: String
		let physicalSpelling: String
		let device: dev_t
		let inode: ino_t
	}
	private var censusDirectories: [String: OwnedCensusDirectory] = [:]

	private var repository: URL {
		var result = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { result.deleteLastPathComponent() }
		return result
	}

	private func run(_ executable: String, _ arguments: [String], root: URL,
		expecting status: Int32 = 0, timeout: Double = 60, phase: NativeCommandPhase = .nativeTool) throws -> Receipt {
		checkpoint("command." + phase.rawValue + ".begin")
		let child = try OwnedProcess(executable, arguments, root: root, guarded: true, workerTimeout: timeout)
		commands.append(child)
		try child.start()
		let receipt: Receipt
		do { receipt = try child.finish(timeout + 10) }
		catch { retirementDebt = true; throw error }
		checkpoint("command." + phase.rawValue + ".end", status: receipt.status == status ? "accepted" : "refused")
		guard receipt.status == status else {
			// Compiler diagnostics concern only this checked-in fixture source.
			// Signing children keep their captured output private.
			if executable == "/usr/bin/xcrun" {
				XCTFail("Private Sparkle child compilation refused: "
					+ String(reflecting: String((receipt.stdout + receipt.stderr).prefix(6000))))
			}
			if phase == .nativeProcessCensus, !annotateCensusRefusal(receipt.stdout) {
				XCTFail("Native Sparkle census refusal: code=diagnostic-unavailable")
			}
			throw Failure.command(phase, receipt.status)
		}
		return receipt
	}

	/// Admit only fixed native facts, never arbitrary child diagnostics or paths.
	private func annotateCensusRefusal(_ stdout: String) -> Bool {
		guard stdout.utf8.count <= 512,
			let packet = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else { return false }
		func integer(_ key: String, maximum: Int64) -> Int64? {
			guard let value = packet[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
				value.doubleValue >= 0, value.doubleValue <= Double(maximum),
				value.doubleValue == Double(value.int64Value) else { return nil }
			return value.int64Value
		}
		if packet["code"] as? String == "directory-refused" {
			let reasons: Set<String> = ["metadata", "missing", "not-absolute", "not-directory", "mode", "owner", "canonical"]
			guard integer("schema", maximum: 4) == 4,
				Set(packet.keys) == Set(["schema", "code", "helper_pid", "reason"]),
				let helperPID = integer("helper_pid", maximum: Int64(Int32.max)), helperPID > 0,
				let reason = packet["reason"] as? String, reasons.contains(reason) else { return false }
			XCTFail("Native Sparkle census refusal: code=directory-refused helper_pid=\(helperPID) reason=\(reason)")
			return true
		}
		if packet["code"] as? String == "stage-refused" {
			let stages: Set<String> = ["private-root", "library", "inventory", "unexpected"]
			guard integer("schema", maximum: 3) == 3,
				Set(packet.keys) == Set(["schema", "code", "helper_pid", "stage"]),
				let helperPID = integer("helper_pid", maximum: Int64(Int32.max)), helperPID > 0,
				let stage = packet["stage"] as? String, stages.contains(stage) else { return false }
			XCTFail("Native Sparkle census refusal: code=stage-refused helper_pid=\(helperPID) stage=\(stage)")
			return true
		}
		guard packet["code"] as? String == "path-unavailable" else { return false }
		guard let schema = integer("schema", maximum: 2), schema == 1 || schema == 2,
			let helperPID = integer("helper_pid", maximum: Int64(Int32.max)), helperPID > 0,
			let pathErrno = integer("path_errno", maximum: 4095) else { return false }
		var summary = "Native Sparkle census refusal: code=path-unavailable helper_pid=\(helperPID) path_errno=\(pathErrno)"
		if schema == 1 {
			guard Set(packet.keys) == Set(["schema", "code", "helper_pid", "path_errno"]) else { return false }
		} else {
			let states: Set<String> = ["creating", "runnable", "sleeping", "stopped", "zombie",
				"unavailable", "identity-refused", "state-refused", "abi-refused", "diagnostic-refused"]
			guard Set(packet.keys) == Set(["schema", "code", "helper_pid", "path_errno",
				"bsd_bytes", "bsd_errno", "bsd_state"]),
				let bytes = integer("bsd_bytes", maximum: 4095),
				let nativeErrno = integer("bsd_errno", maximum: 4095),
				let state = packet["bsd_state"] as? String, states.contains(state) else { return false }
			if ["creating", "runnable", "sleeping", "stopped", "zombie"].contains(state) {
				guard bytes == 136, nativeErrno == 0 else { return false }
			}
			summary += " bsd_bytes=\(bytes) bsd_errno=\(nativeErrno) bsd_state=\(state)"
		}
		// These are snapshot facts, never an ownership-closure ACK or PID skip.
		// XCTest evidence must carry them even when raw CI logs are unavailable.
		XCTFail(summary)
		return true
	}

	private func privateDirectory(_ url: URL) throws {
		guard !manager.fileExists(atPath: url.path) else { throw Failure.prerequisite("private-directory-already-exists") }
		let spelling = url.path
		guard censusDirectories[spelling] == nil else { throw Failure.evidence("owned-census-directory-already-acquired") }
		try manager.createDirectory(at: url, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		var original = stat()
		guard Darwin.lstat(spelling, &original) == 0, original.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
			let resolved = Darwin.realpath(spelling, nil) else { throw Failure.evidence("owned-census-directory-acquisition") }
		defer { free(resolved) }
		// Foundation can return an alias spelling after resolving a file URL.
		// Keep POSIX bytes as a String, never normalize them through URL.path.
		let physical = String(cString: resolved)
		var target = stat()
		guard Darwin.lstat(physical, &target) == 0, target.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
			target.st_dev == original.st_dev, target.st_ino == original.st_ino else {
			throw Failure.evidence("owned-census-directory-acquisition")
		}
		censusDirectories[spelling] = OwnedCensusDirectory(originalSpelling: spelling, physicalSpelling: physical,
			device: original.st_dev, inode: original.st_ino)
	}

	/// Preserve the acquired directory; a later lookup never adopts a replacement.
	private func ownedCensusPath(_ url: URL) throws -> String {
		guard let owned = censusDirectories[url.path] else { throw Failure.evidence("owned-census-directory-unacquired") }
		for spelling in [owned.originalSpelling, owned.physicalSpelling] {
			var metadata = stat()
			guard Darwin.lstat(spelling, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
				metadata.st_dev == owned.device, metadata.st_ino == owned.inode else {
				throw Failure.evidence("owned-census-directory-identity")
			}
		}
		guard let resolved = Darwin.realpath(owned.physicalSpelling, nil) else {
			throw Failure.evidence("owned-census-directory-canonical")
		}
		defer { free(resolved) }
		guard String(cString: resolved) == owned.physicalSpelling else {
			throw Failure.evidence("owned-census-directory-canonical")
		}
		return owned.physicalSpelling
	}

	private func waitFor(_ name: String, root: URL, seconds: Double = 45) throws -> [String: Any] {
		checkpoint("wait." + name)
		let target = root.appendingPathComponent(name + ".json")
		let deadline = Date().addingTimeInterval(seconds)
		while !manager.fileExists(atPath: target.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
		guard manager.fileExists(atPath: target.path),
			let packet = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any] else {
			throw Failure.deadline(name)
		}
		checkpoint("observed." + name, status: "accepted")
		return packet
	}

	/// Polling children may admit only a complete, exclusive control record.
	/// Opening the final file before writing would briefly expose empty bytes.
	private func publishControl(_ name: String, nonce: String, root: URL) throws {
		let stage = root.appendingPathComponent("." + UUID().uuidString + ".control")
		let descriptor = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw Failure.evidence("private-control-acquisition") }
		let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		do {
			try stream.write(contentsOf: Data(nonce.utf8))
			try stream.synchronize()
			try stream.close()
		} catch { try? stream.close(); throw error }
		let target = root.appendingPathComponent(name)
		guard link(stage.path, target.path) == 0 else { throw Failure.evidence("private-control-publication") }
		guard unlink(stage.path) == 0 else { throw Failure.evidence("private-control-stage-retirement") }
	}

	/// Expectations come from the independent signed source, not the producer's
	/// snapshot implementation or a corpus regenerated from installed output.
	private func snapshot(_ app: URL) throws -> [String: [String]] {
		var result: [String: [String]] = [:]
		func visit(_ relative: String) throws {
			let target = relative.isEmpty ? app : app.appendingPathComponent(relative)
			let attributes = try manager.attributesOfItem(atPath: target.path)
			let type = attributes[.type] as? FileAttributeType
			let mode = String(try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue)
			if type == .typeSymbolicLink {
				result[relative] = ["link", try manager.destinationOfSymbolicLink(atPath: target.path)]
			} else if type == .typeDirectory {
				result[relative] = ["directory", mode]
				for name in try manager.contentsOfDirectory(atPath: target.path).sorted() {
					try visit(relative.isEmpty ? name : relative + "/" + name)
				}
			} else if type == .typeRegular {
				result[relative] = ["file", mode, hash(try Data(contentsOf: target))]
			} else { throw Failure.evidence("unsupported-source-file") }
		}
		try visit("")
		return result
	}

	private func hash(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	private func requirement(_ app: URL, root: URL) throws -> String {
		let display = try run("/usr/bin/codesign", ["-d", "-r-", app.path], root: root)
		let lines = (display.stdout + "\n" + display.stderr).components(separatedBy: .newlines)
			.map { $0.hasPrefix("# designated => ") ? String($0.dropFirst(2)) : $0 }
			.filter { $0.hasPrefix("designated => ") }
		guard lines.count == 1, !String(lines[0].dropFirst(14)).isEmpty else {
			throw Failure.evidence("unique-native-signing-requirement")
		}
		return String(lines[0].dropFirst(14))
	}

	private struct ReleaseRepository {
		let owner: String
		let name: String
		var archiveOrigin: String {
			"https://github.com/" + owner + "/" + name + "/releases/download/v2.0.0/ErgoptiPlus.app.tar.xz"
		}
	}

	/// Read the canonical checkout data, while keeping fixture tag/artifact expectations independent.
	private func releaseRepository() throws -> ReleaseRepository {
		let source = repository.appendingPathComponent("static/ergopti_plus/_shared/modules/updater/defaults.json")
		let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
		guard descriptor >= 0 else { throw Failure.prerequisite("canonical-release-repository") }
		let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		defer { try? stream.close() }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
			info.st_size > 0, info.st_size <= 65536,
			let bytes = try stream.read(upToCount: 65537), Int64(bytes.count) == info.st_size, bytes.count <= 65536,
			let defaults = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
			let github = defaults["github"] as? [String: Any],
			let owner = github["owner"] as? String, let name = github["repo"] as? String else {
			throw Failure.prerequisite("canonical-release-repository")
		}
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
		guard [owner, name].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 && $0.utf8.allSatisfy({ allowed.contains($0) }) }) else {
			throw Failure.prerequisite("canonical-release-repository-components")
		}
		return ReleaseRepository(owner: owner, name: name)
	}

	private func makeBundle(_ app: URL, compiled: URL, framework: URL, root: URL,
		nonce: String, port: Int, publicKey: String, version: String, identity: ReleaseRepository) throws {
		try privateDirectory(app)
		for relative in ["Contents", "Contents/MacOS", "Contents/Resources", "Contents/Frameworks"] {
			try privateDirectory(app.appendingPathComponent(relative))
		}
		let executable = app.appendingPathComponent("Contents/MacOS/PrivateSparkleChild")
		try manager.copyItem(at: compiled, to: executable)
		try manager.setAttributes([.posixPermissions: 0o751], ofItemAtPath: executable.path)
		_ = try run("/usr/bin/ditto", [framework.path, app.appendingPathComponent("Contents/Frameworks/Sparkle.framework").path], root: root)
		let plist: [String: Any] = [
			"CFBundleIdentifier": "org.ergoptiplus.archive-acceptance." + nonce,
			"CFBundleName": "ErgoptiPlus", "CFBundleExecutable": "PrivateSparkleChild",
			"CFBundlePackageType": "APPL", "CFBundleVersion": version,
			"CFBundleShortVersionString": version + ".0",
			"FixtureRoot": try ownedCensusPath(root), "FixtureNonce": nonce,
			"FixtureGitHubOwner": identity.owner, "FixtureGitHubRepo": identity.name,
			"FixtureArchiveOrigin": identity.archiveOrigin,
			"FixtureArchiveTransport": "http://localhost:" + String(port) + "/archive.tar.xz",
			"SUFeedURL": "http://localhost:" + String(port) + "/feed.xml",
			"SUEdPublicKey": publicKey, "SUVerifyUpdateBeforeExtraction": true,
			"SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
			"SUAllowsAutomaticUpdates": false, "SUEnableDownloaderService": false,
			"SUEnableInstallerLauncherService": false,
			"NSAppTransportSecurity": ["NSAllowsLocalNetworking": true]
		]
		try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
			.write(to: app.appendingPathComponent("Contents/Info.plist"))
		let resource = app.appendingPathComponent("Contents/Resources/independent.txt")
		try Data((version == "1" ? "Before update: café 😀\n" : "After update: café 😀\n").utf8).write(to: resource)
		try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: resource.path)
		try manager.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/independent-link").path,
			withDestinationPath: "independent.txt")
		_ = try run("/usr/bin/xattr", ["-w", "com.ergopti.sparkle-fixture", "retained-fixture-metadata", resource.path], root: root)
		_ = try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path], root: root)
		_ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], root: root)
	}

	/// Preserve the production generator's exact XML and canonical HTTPS origin.
	/// Only the signed disposable child's download request routes to loopback.
	private func generatedFeed(_ archives: URL, destination: URL, root: URL, identity: ReleaseRepository) throws -> Data {
		let generated = root.appendingPathComponent("generated-appcast-" + UUID().uuidString + ".xml")
		_ = try run("/usr/bin/env", ["ERGOPTI_VERSION=2.0.0", "ERGOPTI_BUILD=2", "ERGOPTI_CHANNEL=dev",
			"GH_OWNER=" + identity.owner, "GH_REPO=" + identity.name, "ARCHIVE_DIR=" + archives.path,
			"OUTPUT_PATH=" + generated.path, "node", repository.appendingPathComponent(
				"tools/build/macos-release-publication.cjs").path, "appcast"], root: root, phase: .generatedAppcast)
		let bytes = try Data(contentsOf: generated)
		let xml = try XCTUnwrap(String(data: bytes, encoding: .utf8))
		XCTAssertTrue(xml.contains("url=\"" + identity.archiveOrigin + "\""))
		XCTAssertFalse(xml.contains("http://localhost:"), "The producer's XML is never rewritten for fixture transport")
		XCTAssertTrue(xml.contains("<sparkle:version>2</sparkle:version>"))
		XCTAssertTrue(xml.contains("<sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>"))
		try bytes.write(to: destination, options: .atomic)
		XCTAssertTrue(try Data(contentsOf: destination) == bytes, "The served appcast must retain exact generated bytes")
		return bytes
	}

	/// Foundation can strip /private from an existing path. The native Python
	/// receiver and proc_pidpath require POSIX realpath spelling for the same root.
	private static func physicalDirectoryURL(_ directory: URL) throws -> URL {
		guard directory.isFileURL else { throw Failure.evidence("physical-fixture-directory") }
		let resolved: UnsafeMutablePointer<CChar>? = directory.withUnsafeFileSystemRepresentation { value in
			guard let value else { return nil }
			return Darwin.realpath(value, nil)
		}
		guard let resolved else { throw Failure.evidence("physical-fixture-directory") }
		defer { free(resolved) }
		var metadata = stat()
		guard lstat(resolved, &metadata) == 0,
			metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
			throw Failure.evidence("physical-fixture-directory")
		}
		guard let nativePath = String(validatingUTF8: resolved), nativePath.hasPrefix("/") else {
			throw Failure.evidence("physical-fixture-directory-encoding")
		}
		let result = URL(fileURLWithPath: nativePath, isDirectory: true)
		guard result.path == nativePath else { throw Failure.evidence("physical-fixture-directory-projection") }
		return result
	}

	func testPhysicalFixtureDirectoryUsesNativeRealpathThroughOwnedAlias() throws {
		let parent = try Self.physicalDirectoryURL(manager.temporaryDirectory)
		let root = parent.appendingPathComponent("ErgoptiSparkleRealpath-" + UUID().uuidString)
		try privateDirectory(root)
		defer {
			do { try manager.removeItem(at: root) }
			catch { XCTFail("Owned realpath fixture could not retire: \(error)") }
		}
		let target = root.appendingPathComponent("physical-directory")
		try privateDirectory(target)
		let alias = root.appendingPathComponent("owned-alias")
		try manager.createSymbolicLink(at: alias, withDestinationURL: target)
		let observed = try Self.physicalDirectoryURL(alias)
		// Independent native resolution admits the exact existing fixture, not
		// a hand-written /private prefix rule or the same helper's own receipt.
		let pointer: UnsafeMutablePointer<CChar>? = alias.withUnsafeFileSystemRepresentation { value in
			guard let value else { return nil }
			return Darwin.realpath(value, nil)
		}
		let expected = try XCTUnwrap(pointer)
		defer { free(expected) }
		XCTAssertEqual(observed.path, try XCTUnwrap(String(validatingUTF8: expected)))
		var nativeInfo = stat(), observedInfo = stat()
		XCTAssertEqual(lstat(expected, &nativeInfo), 0)
		XCTAssertEqual(lstat(observed.path, &observedInfo), 0)
		XCTAssertEqual(observedInfo.st_dev, nativeInfo.st_dev)
		XCTAssertEqual(observedInfo.st_ino, nativeInfo.st_ino)
		XCTAssertEqual(observedInfo.st_mode & mode_t(S_IFMT), mode_t(S_IFDIR))
		let ordinary = root.appendingPathComponent("ordinary-file")
		try Data("independent ordinary-file control".utf8).write(to: ordinary, options: .withoutOverwriting)
		XCTAssertThrowsError(try Self.physicalDirectoryURL(ordinary), "A real regular file cannot become a directory authority")
		XCTAssertThrowsError(try Self.physicalDirectoryURL(root.appendingPathComponent("missing")))
		XCTAssertThrowsError(try Self.physicalDirectoryURL(URL(string: "https://example.invalid/")!))
	}

	private func census(_ roots: [URL], root: URL) throws -> [[String: Any]] {
		let helper = repository.appendingPathComponent("tools/diagnostics/macos_sparkle_archive_fixture.py")
		let paths = try roots.map { try ownedCensusPath($0) }
		let response = try run("/usr/bin/env", ["python3", helper.path, "census"] + paths, root: root, phase: .nativeProcessCensus)
		guard let records = try JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [[String: Any]] else {
			throw Failure.evidence("native-process-census")
		}
		return records
	}

	/// A unique initially absent job label is the native installer's identity.
	/// Removal never targets a product updater or another fixture's job.
	private func removeInstallerJob(_ target: String, root: URL) throws {
		let query = try OwnedProcess("/bin/launchctl", ["print", target], root: root, guarded: true, workerTimeout: 10)
		commands.append(query)
		try query.start()
		let receipt = try query.finish(20)
		if receipt.status == 0 {
			guard receipt.stdout.contains(root.path) else { throw Failure.evidence("foreign-installer-job") }
			_ = try run("/bin/launchctl", ["bootout", target], root: root)
			let observation = try OwnedProcess("/bin/launchctl", ["print", target], root: root, guarded: true, workerTimeout: 10)
			commands.append(observation)
			try observation.start()
			let retired = try observation.finish(20)
			guard retired.status != 0,
				(retired.stdout + retired.stderr).contains("Could not find service") else {
				throw Failure.evidence("installer-job-retirement")
			}
		} else if !(receipt.stdout + receipt.stderr).contains("Could not find service") {
			throw Failure.evidence("installer-job-observation")
		}
	}

	func testChildRefusalCaptureProjectsOnlyOneCompleteClosedCategory() {
		for code in ["configuration", "target-root", "target-bundle", "receipt-publication", "control", "transport"] {
			XCTAssertEqual(Self.parseChildRefusalCode("Private arbitrary log must stay private\nSPARKLE_CHILD_REFUSAL/1 " + code + "\n"), code)
		}
		XCTAssertEqual(Self.parseChildRefusalCode(""), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode("SPARKLE_CHILD_REFUSAL/1 /private/never-exported\n"), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode("SPARKLE_CHILD_REFUSAL/1 configuration"), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode("SPARKLE_CHILD_REFUSAL/1 control\nSPARKLE_CHILD_REFUSAL/1 control\n"), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode("SPARKLE_CHILD_REFUSAL/1 control\nSPARKLE_CHILD_REFUSAL/1 receipt-publication\n"), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode(String(repeating: "x", count: 16_384) + "\n"), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode("SPARKLE_CHILD_REFUSAL/1 transport secret\n"), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode("raw SPARKLE_CHILD_REFUSAL/1 target-root\n"), "unavailable")
		XCTAssertEqual(Self.parseChildRefusalCode("Private Sparkle child target refused.\n"), "unavailable")
	}

	func testSignatureAndApplicationFactsContainOnlyClosedObservations() {
		XCTAssertEqual(signatureProbeMessage(.installedKey, signature64: true, independentValid: true,
			installedValid: true, payloadEqual: nil, signatureEqual: nil),
			"Native Sparkle signature facts: probe=installed-key signature64=true independent_valid=true installed_valid=true payload_equal=unavailable signature_equal=unavailable")
		XCTAssertEqual(signatureProbeMessage(.foreignKey, signature64: true, independentValid: true,
			installedValid: false, payloadEqual: true, signatureEqual: false),
			"Native Sparkle signature facts: probe=foreign-key signature64=true independent_valid=true installed_valid=false payload_equal=true signature_equal=false")
		XCTAssertEqual(applicationExitRefusalMessage(Failure.evidence("application-retirement"), termination: .exit(78)),
			"Native Sparkle application retirement refusal: code=exit-status native_reason=exit native_status=78")
		XCTAssertEqual(applicationExitRefusalMessage(Failure.deadline("private-never-exported"), termination: .signal(15)),
			"Native Sparkle application retirement refusal: code=deadline native_reason=signal native_status=15")
		XCTAssertEqual(applicationExitRefusalMessage(Failure.evidence("private-never-exported"), termination: .exit(256)),
			"Native Sparkle application retirement refusal: code=unavailable native_reason=unavailable native_status=unavailable")
	}


	func testUpdateProgressRequiresCompleteClosedFramesAndTheActualChildPID() {
		let text = "SPARKLE_PROGRESS/1 pid=321 event=started-1\nSPARKLE_PROGRESS/1 pid=321 event=check-requested-1\nSPARKLE_PROGRESS/1 pid=321 event=not-found-1\n"
		let facts = Self.parseUpdateProgress(text, expectedPID: 321)
		XCTAssertEqual(facts.capture, .observed)
		XCTAssertEqual(updateProgressMessage(facts), "Native Sparkle update progress: capture=observed events=started-1,check-requested-1,not-found-1")
		XCTAssertEqual(Self.parseUpdateProgress("", expectedPID: 321).capture, .empty)
		for invalid in [text.replacingOccurrences(of: "pid=321", with: "pid=322"),
			text.replacingOccurrences(of: "pid=321", with: "pid=0321"), String(text.dropLast()),
			text + "SPARKLE_PROGRESS/1 pid=321 event=not-found-1\n", text + "foreign private text\n",
			text.replacingOccurrences(of: "not-found-1", with: "invented"),
			text.replacingOccurrences(of: "not-found-1", with: "not-found-1\0"),
			"SPARKLE_PROGRESS/1 pid=321 event=check-requested-1\n"] {
			let rejected = Self.parseUpdateProgress(invalid, expectedPID: 321)
			XCTAssertNotEqual(rejected.capture, .observed)
			XCTAssertTrue(rejected.events.isEmpty)
			XCTAssertFalse(updateProgressMessage(rejected).contains("foreign private text"))
		}
		XCTAssertEqual(Self.parseUpdateProgress(String(repeating: "x", count: 4097), expectedPID: 321).capture, .unavailable)
		XCTAssertEqual(Self.parseUpdateProgress(text, expectedPID: 0).capture, .unavailable)
	}

	func testNetworkProgressCounterDoesNotInventSuccessfulDelivery() {
		XCTAssertEqual(resourceReadsMessage(NSNumber(value: 0)), "Native Sparkle network progress: admitted_resource_reads=0")
		XCTAssertEqual(resourceReadsMessage(NSNumber(value: 4)), "Native Sparkle network progress: admitted_resource_reads=4")
		let invalid: [Any?] = [nil, true, false, -1, 65, 1.5, "4", NSNumber(value: Double.infinity)]
		for value in invalid {
			XCTAssertEqual(resourceReadsMessage(value), "Native Sparkle network progress: admitted_resource_reads=unavailable")
		}
	}

	func testServerExitRefusalMessageProjectsOnlyClosedFacts() {
		XCTAssertEqual(serverExitRefusalMessage(Failure.deadline("private-input-never-exported"), termination: .unavailable),
			"Native Sparkle server retirement refusal: code=deadline native_reason=unavailable native_status=unavailable")
		XCTAssertEqual(serverExitRefusalMessage(Failure.evidence("server-retirement"), termination: .exit(23)),
			"Native Sparkle server retirement refusal: code=exit-status native_reason=exit native_status=23")
		XCTAssertEqual(serverExitRefusalMessage(Failure.deadline("private-input-never-exported"), termination: .signal(9)),
			"Native Sparkle server retirement refusal: code=deadline native_reason=signal native_status=9")
		XCTAssertEqual(serverExitRefusalMessage(Failure.evidence("private-input-never-exported"), termination: .exit(0)),
			"Native Sparkle server retirement refusal: code=unavailable native_reason=exit native_status=0")
		XCTAssertEqual(serverExitRefusalMessage(Failure.evidence("native-child-signal"), termination: .signal(15)),
			"Native Sparkle server retirement refusal: code=native-signal native_reason=signal native_status=15")
		XCTAssertEqual(serverExitRefusalMessage(Failure.evidence("native-capture-retirement"), termination: .exit(0)),
			"Native Sparkle server retirement refusal: code=capture-retirement native_reason=exit native_status=0")
		XCTAssertEqual(serverExitRefusalMessage(Failure.evidence("native-child-capture"), termination: .exit(0)),
			"Native Sparkle server retirement refusal: code=capture-admission native_reason=exit native_status=0")
		XCTAssertEqual(serverExitRefusalMessage(Failure.evidence("unlaunched-native-child"), termination: .unavailable),
			"Native Sparkle server retirement refusal: code=unlaunched native_reason=unavailable native_status=unavailable")
		for refused in [ObservedTermination.exit(-1), .exit(256), .signal(0), .signal(65)] {
			XCTAssertEqual(serverExitRefusalMessage(Failure.deadline("private-input-never-exported"), termination: refused),
				"Native Sparkle server retirement refusal: code=deadline native_reason=unavailable native_status=unavailable")
		}
	}

	func testDirectNativeChildExitACKAndCaptureRetirementAreIdempotent() throws {
		let root = manager.temporaryDirectory.resolvingSymlinksInPath()
			.appendingPathComponent("ErgoptiSparkleChildACK-" + UUID().uuidString)
		try privateDirectory(root)
		var child: OwnedProcess?
		var passed = false
		let failuresBefore = try XCTUnwrap(testRun?.failureCount)
		defer {
			do {
				try child?.retire()
				if passed { try manager.removeItem(at: root) }
				else { XCTFail("Native child ACK control retained at " + root.path) }
			} catch { XCTFail("Native child ACK retirement refused; inputs retained at " + root.path) }
		}
		child = try OwnedProcess("/usr/bin/true", [], root: root)
		let owner = try XCTUnwrap(child)
		try owner.start()
		let first = try owner.finish(5)
		let second = try owner.finish(0)
		XCTAssertEqual(first.status, 0)
		XCTAssertEqual(second.status, first.status)
		XCTAssertEqual(second.stdout, first.stdout)
		XCTAssertEqual(second.stderr, first.stderr)
		XCTAssertFalse(owner.process.isRunning)
		try owner.retire()
		try owner.retire()
		passed = testRun?.failureCount == failuresBefore
	}

	func testOwnedCensusPathAdmitsParentAliasWithoutAdoptingDirectoryReplacement() throws {
		let root = manager.temporaryDirectory.resolvingSymlinksInPath()
			.appendingPathComponent("ErgoptiSparkleDirectoryACK-" + UUID().uuidString)
		try privateDirectory(root)
		let failuresBefore = try XCTUnwrap(testRun?.failureCount)
		var passed = false
		defer {
			var closed = true
			for command in commands {
				do { try command.retire() }
				catch { closed = false; XCTFail("Owned directory control child retirement refused; inputs retained") }
			}
			if closed, passed, testRun?.failureCount == failuresBefore {
				do {
					_ = try ownedCensusPath(root)
					try manager.removeItem(at: root)
				} catch { XCTFail("Owned directory control input retirement refused; inputs retained") }
			} else { XCTFail("Owned directory control retained after refusal") }
		}
		let physicalParent = root.appendingPathComponent("physical-parent")
		try privateDirectory(physicalParent)
		let alias = root.appendingPathComponent("parent-alias")
		try manager.createSymbolicLink(at: alias, withDestinationURL: physicalParent)
		let child = alias.appendingPathComponent("child")
		try privateDirectory(child)
		let helper = repository.appendingPathComponent("tools/diagnostics/macos_sparkle_archive_fixture.py")
		let admission = "import importlib.util,sys; s=importlib.util.spec_from_file_location('owned_directory',sys.argv[1]); "
			+ "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.private_directory(sys.argv[2]); print('admitted')"
		// This independent parent alias reproduces the old real protocol refusal.
		let refused = try run("/usr/bin/env", ["python3", "-c", admission, helper.path, child.path], root: root, expecting: 1)
		XCTAssertTrue(refused.stdout.isEmpty)
		XCTAssertTrue(refused.stderr.contains("Private Sparkle directory refused"))
		let physical = try ownedCensusPath(child)
		XCTAssertFalse(physical.contains("/parent-alias/"))
		let accepted = try run("/usr/bin/env", ["python3", "-c", admission, helper.path, physical], root: root)
		XCTAssertEqual(accepted.stdout, "admitted\n")
		XCTAssertTrue(accepted.stderr.isEmpty)
		try manager.moveItem(at: child, to: physicalParent.appendingPathComponent("retired-child"))
		try manager.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		XCTAssertThrowsError(try ownedCensusPath(child))
		try manager.moveItem(at: child, to: physicalParent.appendingPathComponent("replacement-child"))
		try manager.createSymbolicLink(at: child, withDestinationURL: physicalParent.appendingPathComponent("retired-child"))
		XCTAssertThrowsError(try ownedCensusPath(child), "A symlink cannot adopt the original inode under another path")
		passed = testRun?.failureCount == failuresBefore
	}

	func testStartupFramesDistinguishActualPrefixEmptyAndRefusedCapture() {
		let valid = Data("SPARKLE_STARTUP/1 python-entry\nSPARKLE_STARTUP/1 imports-ready\nSPARKLE_STARTUP/1 cli-dispatch\n".utf8)
		let observed = Self.parseStartupFrames(valid)
		XCTAssertEqual(observed.capture, .observed)
		XCTAssertEqual(observed.phase, .cliDispatch)
		XCTAssertEqual(observed.bytes, valid.count)
		XCTAssertEqual(Self.parseStartupFrames(Data()).capture, .empty)
		for invalid in [
			"SPARKLE_STARTUP/1 imports-ready\n", "SPARKLE_STARTUP/1 python-entry",
			"SPARKLE_STARTUP/1 python-entry\nSPARKLE_STARTUP/1 python-entry\n",
			"SPARKLE_STARTUP/1 python-entry\nPRIVATE-NOISE\n",
			"SPARKLE_STARTUP/1 python-entry\nSPARKLE_STARTUP/1 unknown-phase\n",
		] {
			let facts = Self.parseStartupFrames(Data(invalid.utf8))
			XCTAssertEqual(facts.capture, .malformed)
			XCTAssertNil(facts.phase)
		}
		XCTAssertEqual(Self.parseStartupFrames(Data(repeating: 65, count: 513)).capture, .unavailable)
	}

	func testActualSparkleTarXZUpdateRefusesWrongKeyPreservesOldAppAndRetriesThroughRelaunch() throws {
		phaseEvidence = try ArchiveAcceptanceEvidence(owner: .sparkle)
		evidenceRefused = false
		checkpoint("candidate.begin")
		guard getuid() != 0 else { throw Failure.prerequisite("nonroot-aqua-user-session") }
		let identity = try releaseRepository()
		let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
		let bundleID = "org.ergoptiplus.archive-acceptance." + nonce
		let root = try Self.physicalDirectoryURL(manager.temporaryDirectory)
			.appendingPathComponent("ErgoptiSparkleArchive-" + nonce)
		try privateDirectory(root)
		let cacheParent = try manager.url(for: .cachesDirectory, in: .userDomainMask,
			appropriateFor: nil, create: false)
		let cache = try Self.physicalDirectoryURL(cacheParent).appendingPathComponent(bundleID)
		let job = "gui/" + String(getuid()) + "/" + bundleID + "-sparkle-updater"
		var cacheOwned = false
		var jobOwned = false
		var server: OwnedProcess?
		var application: OwnedProcess?
		let failuresBefore = try XCTUnwrap(testRun?.failureCount)
		var passed = false
		defer {
			checkpoint("cleanup.begin", pids: [application, server].compactMap { $0?.process.processIdentifier }.filter { $0 > 0 })
			func attempt(_ label: String, _ action: () throws -> Void) {
				do { try action() }
				catch {
					if label == "application-exit", let application {
						XCTFail(applicationExitRefusalMessage(error, termination: application.observedTerminationFacts()))
						if let code = application.observedChildRefusalCode() {
							XCTFail("Native Sparkle child refusal: category=" + code)
						}
					}
					retirementDebt = true
					checkpoint("cleanup.debt-" + label, status: "cleanup-debt")
					XCTFail("Private Sparkle retirement refused (" + label + "); fixture retained at " + root.path)
				}
			}
			if application != nil {
				attempt("application-control") {
					try publishControl("retire", nonce: nonce, root: root)
				}
				if let application, application.process.processIdentifier > 0 {
					attempt("application-exit") {
						defer { print("::notice title=Native Sparkle update::" + updateProgressMessage(application.observedUpdateProgress())) }
						let retired = try application.finish(15)
						guard retired.status == 0 else { throw Failure.evidence("application-retirement") }
					}
				}
			}
			if let server, server.process.processIdentifier > 0 {
				attempt("server-exit") {
					do {
						if server.process.isRunning { server.process.terminate() }
						let retired = try server.finish(10)
						guard retired.status == 0 else { throw Failure.evidence("server-retirement") }
					} catch {
						XCTFail(serverExitRefusalMessage(error, termination: server.observedTerminationFacts()))
						throw error
					}
				}
				attempt("server-terminal") {
					let terminal = try waitFor("server-retired", root: root.appendingPathComponent("www"), seconds: 2)
					guard terminal["nonce"] as? String == nonce,
						(terminal["pid"] as? NSNumber)?.int32Value == server.process.processIdentifier else {
						throw Failure.evidence("server-retirement-receipt")
					}
					print("::notice title=Native Sparkle network::" + resourceReadsMessage(terminal["requests"]))
				}
			}
			// Each owner gets an independent retry even when a different owner's
			// control, capture, exit or terminal receipt already refused.
			for command in commands { attempt("acquired-child") { try command.retire() } }
			if jobOwned { attempt("installer-job") { try removeInstallerJob(job, root: root) } }
			attempt("kernel-process-census") {
				let deadline = Date().addingTimeInterval(15)
				let roots = cacheOwned ? [root, cache] : [root]
				while !(try census(roots, root: root)).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
				guard try census(roots, root: root).isEmpty else { throw Failure.evidence("installer-or-relaunch-retirement") }
				Thread.sleep(forTimeInterval: 0.25)
				guard try census(roots, root: root).isEmpty else { throw Failure.evidence("late-native-relaunch") }
			}
			// Job and census commands were acquired during cleanup and retain the
			// same idempotent physical-retirement obligation as earlier children.
			for command in commands { attempt("cleanup-child") { try command.retire() } }
			if !retirementDebt {
				checkpoint("cleanup.closed", status: "accepted", closed: true,
					pids: [application, server].compactMap { $0?.process.processIdentifier }.filter { $0 > 0 })
			}
			if !retirementDebt, !evidenceRefused, passed, testRun?.failureCount == failuresBefore {
				attempt("private-inputs") {
					UserDefaults.standard.removePersistentDomain(forName: bundleID)
					guard UserDefaults.standard.synchronize() else { throw Failure.evidence("private-defaults-retirement") }
					if cacheOwned { try manager.removeItem(at: cache) }
					try manager.removeItem(at: root)
					XCTAssertFalse(manager.fileExists(atPath: root.path))
					XCTAssertFalse(manager.fileExists(atPath: cache.path))
				}
			} else { XCTFail("Private Sparkle fixture retained for inspection at " + root.path) }
		}

		_ = try run("/bin/launchctl", ["print", "gui/" + String(getuid())], root: root)
		let absent = try OwnedProcess("/bin/launchctl", ["print", job], root: root, guarded: true, workerTimeout: 10)
		commands.append(absent)
		try absent.start()
		let absence = try absent.finish(20)
		guard absence.status != 0, (absence.stdout + absence.stderr).contains("Could not find service"),
			UserDefaults.standard.persistentDomain(forName: bundleID) == nil else {
			throw Failure.prerequisite("private-installer-identity-already-exists")
		}
		jobOwned = true
		try privateDirectory(cache)
		cacheOwned = true
		let framework = Bundle(for: SPUUpdater.self)
		guard framework.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "2.9.2",
			let signer = ProcessInfo.processInfo.environment["SIGN_UPDATE"], manager.isExecutableFile(atPath: signer) else {
			throw Failure.prerequisite("pinned-native-sparkle-tools")
		}
		let helper = repository.appendingPathComponent("tools/diagnostics/macos_sparkle_archive_fixture.py")
		let www = root.appendingPathComponent("www")
		try privateDirectory(www)
		server = try OwnedProcess("/usr/bin/env", ["python3", helper.path, "serve", try ownedCensusPath(www), nonce], root: root, startupDiagnostics: true)
		commands.append(try XCTUnwrap(server))
		try server?.start()
		let listening = try waitFor("server-start", root: www, seconds: 10)
		let port = try XCTUnwrap(listening["port"] as? Int)
		guard listening["nonce"] as? String == nonce,
			(listening["pid"] as? NSNumber)?.int32Value == server?.process.processIdentifier,
			(1...65535).contains(port) else { throw Failure.evidence("private-loopback-server") }

		let compiled = root.appendingPathComponent("compiled-child")
		let childSource = repository.appendingPathComponent("tools/diagnostics/macos_sparkle_archive_child.swift")
		_ = try run("/usr/bin/xcrun", ["swiftc", childSource.path, "-F", framework.bundleURL.deletingLastPathComponent().path,
			"-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
			"-o", compiled.path], root: root)
		let key = Curve25519.Signing.PrivateKey()
		let foreignKey = Curve25519.Signing.PrivateKey()
		let keyFile = root.appendingPathComponent("private-file-key")
		try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyFile, options: .withoutOverwriting)
		try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
		for directory in ["installed", "source", "archives"] { try privateDirectory(root.appendingPathComponent(directory)) }
		let installed = root.appendingPathComponent("installed/ErgoptiPlus.app")
		let source = root.appendingPathComponent("source/ErgoptiPlus.app")
		for (app, version) in [(installed, "1"), (source, "2")] {
			try makeBundle(app, compiled: compiled, framework: framework.bundleURL, root: root,
				nonce: nonce, port: port, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), version: version, identity: identity)
		}
		let oldSnapshot = try snapshot(installed)
		let newSnapshot = try snapshot(source)
		let newRequirement = try requirement(source, root: root)
		let archives = root.appendingPathComponent("archives")
		_ = try run("/usr/bin/env", ["node", repository.appendingPathComponent("tools/build/macos-release-archives.cjs").path,
			source.path, archives.path], root: root, phase: .archiveBuild)
		_ = try run("/usr/bin/env", ["node", repository.appendingPathComponent("tools/build/macos-release-publication.cjs").path,
			"sign", archives.path, signer, keyFile.path], root: root, phase: .archiveSign)
		let payload = try Data(contentsOf: archives.appendingPathComponent("ErgoptiPlus.app.tar.xz"))
		let fragment = try String(contentsOf: archives.appendingPathComponent("_ErgoptiPlus.app.tar.xz.sig"), encoding: .utf8)
		let expression = try NSRegularExpression(pattern: #"^sparkle:edSignature="([A-Za-z0-9+/]{86}==)" length="([1-9][0-9]*)"\n$"#)
		let match = try XCTUnwrap(expression.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)))
		let signature = String(fragment[try XCTUnwrap(Range(match.range(at: 1), in: fragment))])
		let signatureBytes = try XCTUnwrap(Data(base64Encoded: signature))
		XCTAssertEqual(Int(fragment[try XCTUnwrap(Range(match.range(at: 2), in: fragment))]), payload.count)
		XCTAssertEqual(signatureBytes.count, 64, "The official installed signature has the exact Ed25519 length")
		XCTAssertTrue(key.publicKey.isValidSignature(signatureBytes, for: payload), "The native signer and independent Ed25519 public key must agree")
		XCTAssertFalse(foreignKey.publicKey.isValidSignature(signatureBytes, for: payload), "The foreign public key must refuse the actual installed-key signature")
		let independentInstalledSignature = try? key.signature(for: payload)
		let installedSignatureEqual = independentInstalledSignature.map { $0 == signatureBytes }
		print("::notice title=Native Sparkle signature::" + signatureProbeMessage(.installedKey,
			signature64: signatureBytes.count == 64,
			independentValid: key.publicKey.isValidSignature(signatureBytes, for: payload),
			installedValid: key.publicKey.isValidSignature(signatureBytes, for: payload),
			payloadEqual: nil, signatureEqual: installedSignatureEqual))
		let wrongSignature = try foreignKey.signature(for: payload)
		XCTAssertTrue(foreignKey.publicKey.isValidSignature(wrongSignature, for: payload))
		XCTAssertFalse(key.publicKey.isValidSignature(wrongSignature, for: payload))
		let foreignArchives = root.appendingPathComponent("foreign-key-archives")
		try privateDirectory(foreignArchives)
		for name in ["ErgoptiPlus.app.tar.xz", "ErgoptiPlus.app.zip"] {
			try manager.copyItem(at: archives.appendingPathComponent(name), to: foreignArchives.appendingPathComponent(name))
		}
		let foreignKeyFile = root.appendingPathComponent("foreign-file-key")
		try Data(foreignKey.rawRepresentation.base64EncodedString().utf8).write(to: foreignKeyFile, options: .withoutOverwriting)
		try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreignKeyFile.path)
		_ = try run("/usr/bin/env", ["node", repository.appendingPathComponent("tools/build/macos-release-publication.cjs").path,
			"sign", foreignArchives.path, signer, foreignKeyFile.path], root: root, phase: .archiveSignForeign)
		let foreignFragment = try String(contentsOf: foreignArchives.appendingPathComponent("_ErgoptiPlus.app.tar.xz.sig"), encoding: .utf8)
		let foreignMatch = try XCTUnwrap(expression.firstMatch(in: foreignFragment, range: NSRange(foreignFragment.startIndex..., in: foreignFragment)))
		let foreignSignature = String(foreignFragment[try XCTUnwrap(Range(foreignMatch.range(at: 1), in: foreignFragment))])
		let officialForeignSignature = try XCTUnwrap(Data(base64Encoded: foreignSignature))
		let copiedForeignPayload = try Data(contentsOf: foreignArchives.appendingPathComponent("ErgoptiPlus.app.tar.xz"))
		let officialForeignValid = foreignKey.publicKey.isValidSignature(officialForeignSignature, for: payload)
		let officialInstalledValid = key.publicKey.isValidSignature(officialForeignSignature, for: payload)
		let foreignPayloadEqual = copiedForeignPayload == payload
		print("::notice title=Native Sparkle signature::" + signatureProbeMessage(.foreignKey,
			signature64: officialForeignSignature.count == 64, independentValid: officialForeignValid,
			installedValid: officialInstalledValid, payloadEqual: foreignPayloadEqual,
			signatureEqual: officialForeignSignature == wrongSignature))
		XCTAssertEqual(officialForeignSignature.count, 64, "The official foreign signature has the exact Ed25519 length")
		XCTAssertTrue(officialForeignValid, "The independent foreign public key must validate the actual official signature")
		XCTAssertFalse(officialInstalledValid, "The installed public key must refuse the actual official foreign signature")
		XCTAssertTrue(foreignPayloadEqual, "The foreign signer must consume the same private archive bytes")
		// Official and CryptoKit signatures can differ while independently authenticating the same bytes.
		guard !copiedForeignPayload.isEmpty else { throw Failure.evidence("signature-payload-empty") }
		var alteredPayload = copiedForeignPayload
		alteredPayload[alteredPayload.startIndex] ^= 0x01
		XCTAssertEqual(alteredPayload.count, payload.count, "The counterfactual changes content without changing archive length")
		XCTAssertTrue(!foreignKey.publicKey.isValidSignature(officialForeignSignature, for: alteredPayload)
			&& !key.publicKey.isValidSignature(signatureBytes, for: alteredPayload),
			"Both official signatures must refuse a one-byte change to the independently authenticated archive")
		XCTAssertEqual(Int(foreignFragment[try XCTUnwrap(Range(foreignMatch.range(at: 2), in: foreignFragment))]), payload.count)
		try payload.write(to: www.appendingPathComponent("archive.tar.xz"), options: .withoutOverwriting)
		let refusedFeed = try generatedFeed(foreignArchives, destination: www.appendingPathComponent("feed.xml"), root: root, identity: identity)

		application = try OwnedProcess(installed.appendingPathComponent("Contents/MacOS/PrivateSparkleChild").path, [], root: root)
		commands.append(try XCTUnwrap(application))
		try application?.start()
		checkpoint("application.started", pids: application.map { [$0.process.processIdentifier] } ?? [])
		let started = try waitFor("started-1", root: root)
		XCTAssertEqual((started["pid"] as? NSNumber)?.int32Value, application?.process.processIdentifier)
		XCTAssertEqual(started["nonce"] as? String, nonce)
		let actual = try census([root, cache], root: root)
		XCTAssertTrue(actual.contains { ($0["pid"] as? NSNumber)?.int32Value == application?.process.processIdentifier
			&& $0["executable"] as? String == installed.appendingPathComponent("Contents/MacOS/PrivateSparkleChild").path })
		let refusal = try waitFor("refused-1", root: root)
		_ = try waitFor("cycle-refused-1", root: root)
		let details = try XCTUnwrap(refusal["details"] as? [String: Any])
		let errors = try XCTUnwrap(details["errors"] as? [[String: Any]])
		XCTAssertTrue(errors.contains { $0["domain"] as? String == SUSparkleErrorDomain
			&& ($0["code"] as? NSNumber)?.intValue == 3001 }, "Wrong-key refusal must reach actual Sparkle signature validation")
		XCTAssertEqual(try snapshot(installed), oldSnapshot, "A refused archive cannot alter the installed signed source")
		XCTAssertTrue(try XCTUnwrap(application).process.isRunning)
		XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("ready-1.json").path))
		XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("installing-1.json").path))
		XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("started-2.json").path))

		let acceptedFeed = try generatedFeed(archives, destination: www.appendingPathComponent("feed.xml"), root: root, identity: identity)
		try publishControl("retry", nonce: nonce, root: root)
		_ = try waitFor("retry-accepted", root: root)
		_ = try waitFor("ready-2", root: root)
		_ = try waitFor("installing-2", root: root)
		_ = try waitFor("relaunch-requested-2", root: root)
		let relaunched = try waitFor("started-2", root: root)
		XCTAssertEqual(relaunched["nonce"] as? String, nonce)
		XCTAssertEqual(relaunched["version"] as? String, "2")
		XCTAssertEqual((try waitFor("terminated-1", root: root))["version"] as? String, "1")
		let replacementPID = try XCTUnwrap((relaunched["pid"] as? NSNumber)?.int32Value)
		XCTAssertNotEqual(replacementPID, application?.process.processIdentifier)
		XCTAssertTrue(try census([root, cache], root: root).contains { ($0["pid"] as? NSNumber)?.int32Value == replacementPID
			&& $0["executable"] as? String == installed.appendingPathComponent("Contents/MacOS/PrivateSparkleChild").path })
		XCTAssertEqual(try snapshot(installed), newSnapshot, "Actual Sparkle installation must retain all source bytes, modes and relative links")
		XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Contents/Resources/independent.txt")),
			Data("After update: café 😀\n".utf8))
		XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: installed.appendingPathComponent("Contents/Resources/independent-link").path),
			"independent.txt")
		_ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + newRequirement, installed.path], root: root)
		XCTAssertEqual(try run("/usr/bin/xattr", ["-p", "com.ergopti.sparkle-fixture",
			installed.appendingPathComponent("Contents/Resources/independent.txt").path], root: root).stdout.trimmingCharacters(in: .newlines),
			"retained-fixture-metadata")
		let requests = try manager.contentsOfDirectory(at: www, includingPropertiesForKeys: nil)
			.filter { $0.lastPathComponent.hasPrefix("request-") }
		let downloaded = try requests.compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
			.filter { $0["path"] as? String == "/archive.tar.xz" }
		XCTAssertEqual(downloaded.count, 2, "Refusal and retry must both fetch the real tar.xz archive")
		let fetchedFeeds = try requests.compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
			.filter { $0["path"] as? String == "/feed.xml" }
		XCTAssertEqual(fetchedFeeds.count, 2, "Both native update cycles must consume the actual generated feed")
		XCTAssertEqual(Set(fetchedFeeds.compactMap { $0["sha256"] as? String }), Set([hash(refusedFeed), hash(acceptedFeed)]))
		for cycle in [1, 2] {
			let routing = try waitFor("routed-" + String(cycle), root: root)
			XCTAssertEqual(routing["nonce"] as? String, nonce)
			XCTAssertEqual((routing["pid"] as? NSNumber)?.int32Value, application?.process.processIdentifier)
			let details = try XCTUnwrap(routing["details"] as? [String: Any])
			XCTAssertEqual(details["origin"] as? String, identity.archiveOrigin)
			XCTAssertEqual(details["transport"] as? String, "http://localhost:" + String(port) + "/archive.tar.xz")
		}
		for receipt in downloaded {
			XCTAssertEqual(receipt["nonce"] as? String, nonce)
			XCTAssertEqual(receipt["sha256"] as? String, hash(payload))
			XCTAssertEqual(receipt["bytes"] as? Int, payload.count)
		}
		checkpoint("receipt.checked", status: testRun?.failureCount == failuresBefore ? "accepted" : "refused")
		passed = testRun?.failureCount == failuresBefore
	}
}
