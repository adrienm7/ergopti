// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274NativePolicyQualificationTests.swift
//
// Compiles reviewed dormant policies with the real Mac SDK. These tests qualify
// decoding and refusal controls, never physical-device or stream coverage.

import CoreFoundation
import Darwin
import Dispatch
import Foundation
import XCTest

final class HS274NativePolicyQualificationTests: XCTestCase {

	private enum FixtureError: Error {
		case capture, launch, deadline, ownership, compilation, source
	}

	struct Receipt {
		let status: Int32
		let stdout: String
		let stderr: String
	}

	private enum ChildBudget: Equatable {
		case sdk, sourceCalibration

		var worker: String { self == .sdk ? "30" : "300" }
		var observation: Double { self == .sdk ? 35 : 305 }
	}

	/// The unchanged guardian reserves its worker through inherited-PGID census
	/// and reaps last. This invoker owns only that direct guardian and captures.
	private final class GuardianChild {
		let process = Process()
		private let completed = DispatchSemaphore(value: 0)
		private let output: URL
		private let errors: URL
		private let terminal: URL
		private var streams: [FileHandle] = []
		private var closedStreams: Set<Int> = []
		private var launched = false
		private var observedExit = false
		private var cached: Receipt?
		private let budget: ChildBudget

		init(executable: URL, arguments: [String], repository: URL, root: URL, budget: ChildBudget = .sdk) throws {
			self.budget = budget
			let identity = UUID().uuidString
			output = root.appendingPathComponent(identity + ".stdout")
			errors = root.appendingPathComponent(identity + ".stderr")
			terminal = root.appendingPathComponent(identity + ".group.json")
			func capture(_ path: URL) throws -> FileHandle {
				let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
				guard descriptor >= 0 else { throw FixtureError.capture }
				return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			}
			let out = try capture(output)
			do { streams = [out, try capture(errors)] }
			catch { try? out.close(); throw error }
			process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
			process.arguments = ["python3", repository.appendingPathComponent("tools/diagnostics/macos_owned_process.py").path,
				"run", terminal.path, budget.worker, "--", executable.path] + arguments
			process.environment = NativeFixtureChildEnvironment.make()
			process.standardOutput = streams[0]
			process.standardError = streams[1]
			process.terminationHandler = { [completed] _ in completed.signal() }
		}

		func start() throws {
			guard !launched else { throw FixtureError.launch }
			do { try process.run(); launched = true }
			catch { launched = process.processIdentifier > 0; throw error }
		}

		private func observeExit(_ seconds: Double) -> Bool {
			if observedExit { return !process.isRunning }
			guard completed.wait(timeout: .now() + seconds) == .success else { return false }
			observedExit = true
			return !process.isRunning
		}

		private func closeCaptures() throws {
			var refused = false
			for (index, stream) in streams.enumerated() where !closedStreams.contains(index) {
				do { try stream.close(); closedStreams.insert(index) }
				catch { refused = true }
			}
			guard !refused, closedStreams.count == streams.count else { throw FixtureError.capture }
		}

		/// Read only a complete ordinary owner file after the exact exit ACK.
		private func read(_ path: URL, maximum: Int64) throws -> Data {
			let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW)
			guard descriptor >= 0 else { throw FixtureError.capture }
			let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			do {
				var info = stat()
				guard fstat(descriptor, &info) == 0,
					info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
					info.st_size >= 0, info.st_size <= maximum else { throw FixtureError.capture }
				let data = try stream.read(upToCount: Int(maximum + 1)) ?? Data()
				guard Int64(data.count) == info.st_size else { throw FixtureError.capture }
				try stream.close()
				return data
			} catch { try? stream.close(); throw error }
		}

		private func admitTerminal() throws {
			guard observedExit, !process.isRunning else { throw FixtureError.ownership }
			let status = process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
			guard HS274NativePolicyQualificationTests.validTerminal(try read(terminal, maximum: 16_383),
				guardian: process.processIdentifier, status: status) else { throw FixtureError.ownership }
		}

		/// Never hard-kill the guardian that still owns a reserved worker/PGID.
		/// A missing terminal ACK retains every private input for the next retry.
		func retire() throws {
			if !launched { try closeCaptures(); return }
			if !observeExit(0) {
				if process.isRunning { process.terminate() }
				guard observeExit(10) else { throw FixtureError.ownership }
			}
			try closeCaptures()
			try admitTerminal()
		}

		func finish() throws -> Receipt {
			if let cached { return cached }
			guard launched else { throw FixtureError.launch }
			guard observeExit(budget.observation) else {
				try? retire()
				throw FixtureError.deadline
			}
			try retire()
			guard process.terminationReason == .exit else { throw FixtureError.ownership }
			guard let stdout = String(data: try read(output, maximum: 1_048_576), encoding: .utf8),
				let stderr = String(data: try read(errors, maximum: 1_048_576), encoding: .utf8) else {
				throw FixtureError.capture
			}
			let receipt = Receipt(status: process.terminationStatus, stdout: stdout, stderr: stderr)
			cached = receipt
			return receipt
		}
	}

	private var children: [GuardianChild] = []
	private let manager = FileManager.default

	private static var repository: URL {
		var result = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { result.deleteLastPathComponent() }
		return result
	}

	/// The finite publisher protocol uses six unescaped keys and scalar values.
	/// Check lexical cardinality before Foundation can collapse duplicate keys.
	private static func closedTerminalLexemes(_ data: Data) -> Bool {
		guard data.count < 16_384 else { return false }
		let bytes = Array(data)
		let allowed: Set<String> = ["schema", "guardian_pid", "worker_pid", "group_id", "closed", "exit_status"]
		let spaces: Set<UInt8> = [9, 10, 13, 32]
		let trueBytes: [UInt8] = [116, 114, 117, 101]
		let falseBytes: [UInt8] = [102, 97, 108, 115, 101]
		var seen: Set<String> = []
		var index = 0
		func whitespace() {
			while index < bytes.count, spaces.contains(bytes[index]) { index += 1 }
		}
		func take(_ byte: UInt8) -> Bool {
			whitespace()
			guard index < bytes.count, bytes[index] == byte else { return false }
			index += 1
			return true
		}
		guard take(123) else { return false } // {
		while true {
			guard take(34) else { return false } // "
			let start = index
			while index < bytes.count, bytes[index] == 95 || (bytes[index] >= 97 && bytes[index] <= 122) {
				index += 1
			}
			guard index < bytes.count, bytes[index] == 34,
				let key = String(bytes: bytes[start..<index], encoding: .utf8),
				allowed.contains(key), seen.insert(key).inserted else { return false }
			index += 1
			guard take(58) else { return false } // :
			whitespace()
			guard index < bytes.count else { return false }
			if key == "closed" {
				if bytes[index...].starts(with: trueBytes) { index += 4 } // true
				else if bytes[index...].starts(with: falseBytes) { index += 5 } // false
				else { return false }
			} else {
				let integerStart = index
				if index < bytes.count, bytes[index] == 45 { index += 1 } // -
				guard index < bytes.count else { return false }
				if bytes[index] == 48 { index += 1 }
				else {
					guard bytes[index] >= 49, bytes[index] <= 57 else { return false }
					while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
				}
				guard index - integerStart <= 11 else { return false } // Int32 fields
			}
			whitespace()
			guard index < bytes.count else { return false }
			if bytes[index] == 44 { index += 1; continue } // ,
			guard bytes[index] == 125 else { return false } // }
			index += 1
			break
		}
		whitespace()
		return index == bytes.count && seen == allowed
	}

	/// Receipt parsing is separate from physical exit observation; forged bytes
	/// can never replace the direct-child ACK required by GuardianChild.
	private static func validTerminal(_ data: Data, guardian: Int32, status: Int32) -> Bool {
		guard closedTerminalLexemes(data),
			let packet = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			Set(packet.keys) == Set(["schema", "guardian_pid", "worker_pid", "group_id", "closed", "exit_status"]) else { return false }
		func integer(_ key: String, minimum: Int64, maximum: Int64) -> Int64? {
			guard let number = packet[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
				number.doubleValue >= Double(minimum), number.doubleValue <= Double(maximum),
				number.doubleValue == Double(number.int64Value) else { return nil }
			return number.int64Value
		}
		guard integer("schema", minimum: 1, maximum: 1) == 1,
			integer("guardian_pid", minimum: 1, maximum: Int64(Int32.max)) == Int64(guardian),
			let worker = integer("worker_pid", minimum: 1, maximum: Int64(Int32.max)),
			integer("group_id", minimum: 1, maximum: Int64(Int32.max)) == worker,
			integer("exit_status", minimum: Int64(Int32.min), maximum: Int64(Int32.max)) == Int64(status),
			let closed = packet["closed"] as? NSNumber, CFGetTypeID(closed) == CFBooleanGetTypeID(),
			closed.boolValue else { return false }
		return true
	}

	/// Acknowledges every retained direct Guardian before private credential cleanup.
	/// A refusal keeps the complete child array for the fixture's independent retry.
	func retireOwnedChildren() throws {
		for child in children { try child.retire() }
	}

	func fixture(parent: URL? = nil, _ body: (URL) throws -> Void) throws {
		guard children.isEmpty else { throw FixtureError.ownership }
		let root = (parent ?? manager.temporaryDirectory.resolvingSymlinksInPath())
			.appendingPathComponent("ErgoptiHS274NativePolicy-" + UUID().uuidString)
		try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		let failuresBefore = try XCTUnwrap(testRun?.failureCount)
		var passed = false
		defer {
			var closed = true
			for child in children {
				do { try child.retire() }
				catch { closed = false; XCTFail("HS274 native guardian retirement refused; private inputs retained") }
			}
			if closed, passed, testRun?.failureCount == failuresBefore {
				do { try manager.removeItem(at: root) }
				catch { XCTFail("HS274 native policy fixture directory retirement refused") }
			} else { XCTFail("HS274 native policy qualification refused; private fixture retained at " + root.path) }
		}
		try body(root)
		passed = testRun?.failureCount == failuresBefore
	}

	func run(_ executable: URL, _ arguments: [String], root: URL) throws -> Receipt {
		let child = try GuardianChild(executable: executable, arguments: arguments, repository: Self.repository, root: root)
		children.append(child)
		try child.start()
		return try child.finish()
	}

	/// Full native compilation owns a separate finite calibration; SDK cases keep
	/// their original 30/35/10-second worker, observation, and retirement budgets.
	func runSourceCompilation(_ arguments: [String], root: URL) throws -> Receipt {
		let child = try GuardianChild(executable: URL(fileURLWithPath: "/usr/bin/env"),
			arguments: ["python3", source("hs274_native_build.py").path] + arguments,
			repository: Self.repository, root: root, budget: .sourceCalibration)
		children.append(child)
		try child.start()
		let receipt = try child.finish()
		if receipt.status != 0, arguments.count >= 2,
			arguments[0] == source("hs274_native_build.py").deletingLastPathComponent().path {
			let owner = URL(fileURLWithPath: arguments[1])
			if owner.path == arguments[1], owner.resolvingSymlinksInPath() == owner,
				owner == root || owner == root.appendingPathComponent("baseline") {
				printRetiredBaselineTransport(owner: owner, status: receipt.status, root: root)
			}
		}
		return receipt
	}

	/// Only the fixed owned consumer uses this second independent calibration.
	/// It retains its own native Guardian; ordinary SDK budgets stay intact.
	func runOwnedRuntimeCompilation(_ arguments: [String], root: URL) throws -> Receipt {
		let script = source("hs274_native_build.py").deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_build.py")
		let child = try GuardianChild(executable: URL(fileURLWithPath: "/usr/bin/env"),
			arguments: ["python3", script.path] + arguments,
			repository: Self.repository, root: root, budget: .sourceCalibration)
		children.append(child)
		try child.start()
		let receipt = try child.finish()
		if receipt.status != 0 {
			print("Retired owned compilation refusal code: "
				+ HS274RetiredBuildRefusal.code(receipt.stderr, producer: .owned))
		}
		return receipt
	}

	/// Partial Core constructor compilation has its own fixed Guardian calibration.
	/// It cannot replace either mandatory complete-source compilation entry.
	func runCoreConstructorCompilation(_ arguments: [String], root: URL) throws -> Receipt {
		let child = try GuardianChild(executable: URL(fileURLWithPath: "/usr/bin/env"),
			arguments: ["python3", source("owned_runtime_service_reference_core_fixture_calibration.py").path] + arguments,
			repository: Self.repository, root: root, budget: .sourceCalibration)
		children.append(child)
		try child.start()
		return try child.finish()
	}

	/// CI already archives this parent. Admit its canonical ordinary owner before
	/// creating a unique private child, so failures retain useful phase evidence.
	func compilationEvidenceParent() throws -> URL {
		let temporary = try XCTUnwrap(ProcessInfo.processInfo.environment["RUNNER_TEMP"],
			"Full source calibration requires the runner evidence directory")
		guard temporary.hasPrefix("/") else { throw FixtureError.source }
		let parent = URL(fileURLWithPath: temporary).resolvingSymlinksInPath()
			.appendingPathComponent("swift-launcher-evidence")
		guard parent.resolvingSymlinksInPath() == parent else { throw FixtureError.ownership }
		let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
		guard descriptor >= 0 else { throw FixtureError.ownership }
		defer { close(descriptor) }
		var info = stat()
		guard fstat(descriptor, &info) == 0,
			info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else {
			throw FixtureError.ownership
		}
		return parent
	}

	func compile(_ source: URL, standard: String, root: URL, frameworks: Bool = false) throws -> URL {
		let executable = root.appendingPathComponent("compiled-" + UUID().uuidString)
		var arguments = ["clang++", "-std=" + standard, "-Wall", "-Wextra", "-Werror", "-pedantic", source.path]
		if frameworks { arguments += ["-framework", "CoreFoundation", "-framework", "IOKit"] }
		arguments += ["-o", executable.path]
		let receipt = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments, root: root)
		guard receipt.status == 0 else {
			// Only this checked-in or privately copied public fixture source is compiled.
			XCTFail("HS274 owned native compilation refused status=" + String(receipt.status) + "; "
				+ String(reflecting: String((receipt.stdout + receipt.stderr).prefix(4096))))
			throw FixtureError.compilation
		}
		XCTAssertTrue(receipt.stdout.isEmpty)
		XCTAssertTrue(receipt.stderr.isEmpty)
		XCTAssertTrue(manager.isExecutableFile(atPath: executable.path))
		return executable
	}

	func source(_ name: String) -> URL {
		Self.repository.appendingPathComponent("tools/diagnostics/" + name)
	}

	func testActualClangRunsDormantPortablePolicyAndControlInBothStandards() throws {
		try fixture { root in
			for standard in ["c++17", "c++23"] {
				let policy = try compile(source("hs274-stream-key-policy-test.cpp"), standard: standard, root: root)
				let policyResult = try run(policy, [], root: root)
				XCTAssertEqual(policyResult.status, 0)
				XCTAssertEqual(policyResult.stdout, "PASS independent key policy assertions=92\n")
				XCTAssertTrue(policyResult.stderr.isEmpty)
				let control = try compile(source("hs274-observation-control-test.cpp"), standard: standard, root: root)
				let controlResult = try run(control, [], root: root)
				XCTAssertEqual(controlResult.status, 0)
				XCTAssertEqual(controlResult.stdout, "PASS pure observation controls assertions=93; native framework calls unexecuted\n")
				XCTAssertTrue(controlResult.stderr.isEmpty)
			}
		}
	}

	func testActualCoreFoundationDecoderUsesNoFixtureRegistryIdentity() throws {
		try fixture { root in
			let decoder = try compile(source("hs274-keyboard-type-observation-test.cpp"), standard: "c++17", root: root, frameworks: true)
			let receipt = try run(decoder, [], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS native decoder/identity controls assertions=31 owned_service_tested=false; availability and stream correlation unproved\n")
			XCTAssertTrue(receipt.stderr.isEmpty)
		}
	}

	func testActualNativeProbeRefusesMalformedRegistryArgumentsBeforeLookup() throws {
		try fixture { root in
			let probe = try compile(source("hs274-keyboard-type-probe.cpp"), standard: "c++17", root: root, frameworks: true)
			let cases: [[String]] = [[], ["1", "2"], [""], ["0"], ["00"], ["01"], ["+1"], ["-1"],
				[" 1"], ["1 "], ["1\n"], ["1\r"], ["1\t"], ["0x40"], ["1.0"], ["1e3"],
				["18446744073709551616"], ["999999999999999999999"]]
			for arguments in cases {
				let receipt = try run(probe, arguments, root: root)
				XCTAssertEqual(receipt.status, 2)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.isEmpty)
			}
		}
	}

	func testActualNativeMutantCannotDefaultAnUnknownKeyboardTypeToAnsi() throws {
		try fixture { root in
			let owned = root.appendingPathComponent("mutant")
			try manager.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
			for name in ["hs274-key-element.hpp", "hs274-stream-key-policy-test.cpp"] {
				try manager.copyItem(at: source(name), to: owned.appendingPathComponent(name))
			}
			let policy = try String(contentsOf: source("hs274-stream-key-policy.hpp"), encoding: .utf8)
			let before = "default: return keyboard_type::unavailable;"
			guard policy.components(separatedBy: before).count == 2 else { throw FixtureError.source }
			let changed = policy.replacingOccurrences(of: before, with: "default: return keyboard_type::ansi;")
			try changed.write(to: owned.appendingPathComponent("hs274-stream-key-policy.hpp"), atomically: true, encoding: .utf8)
			let mutant = try compile(owned.appendingPathComponent("hs274-stream-key-policy-test.cpp"), standard: "c++17", root: root)
			let receipt = try run(mutant, [], root: root)
			XCTAssertEqual(receipt.status, 1)
			XCTAssertTrue(receipt.stdout.isEmpty)
			XCTAssertEqual(receipt.stderr, "FAIL Unknown native ID must never become ANSI\n")
		}
	}

	func testGuardianTerminalReceiptRejectsForgedAndPartialControls() {
		let valid = "{\"schema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}"
		XCTAssertTrue(Self.validTerminal(Data(valid.utf8), guardian: 41, status: 0))
		let refused = [valid.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":true"),
			valid.replacingOccurrences(of: "\"guardian_pid\":41", with: "\"guardian_pid\":42"),
			valid.replacingOccurrences(of: "\"worker_pid\":42", with: "\"worker_pid\":0"),
			valid.replacingOccurrences(of: "\"group_id\":42", with: "\"group_id\":43"),
			valid.replacingOccurrences(of: "\"closed\":true", with: "\"closed\":1"),
			valid.replacingOccurrences(of: "\"closed\":true", with: "\"closed\":false"),
			valid.replacingOccurrences(of: "\"exit_status\":0", with: "\"exit_status\":1"),
			valid.replacingOccurrences(of: "\"worker_pid\":42", with: "\"worker_pid\":4294967296"),
			valid.replacingOccurrences(of: "\"group_id\":42", with: "\"group_id\":42.5"),
			valid.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1,\"extra\":0"),
			"{}", "{", "null"]
		for packet in refused { XCTAssertFalse(Self.validTerminal(Data(packet.utf8), guardian: 41, status: 0)) }
		XCTAssertFalse(Self.validTerminal(Data(repeating: 32, count: 16_384), guardian: 41, status: 0))
	}

	func testGuardianTerminalReceiptRejectsDuplicateAndEscapedPublisherFields() {
		let publisherWhitespace = " { \"closed\": true, \"group_id\": 42, \"exit_status\": 0, \"schema\": 1, \"worker_pid\": 42, \"guardian_pid\": 41 }\n"
		XCTAssertTrue(Self.validTerminal(Data(publisherWhitespace.utf8), guardian: 41, status: 0))
		let refused: [String] = [
			"{\"schema\":0,\"schema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"guardian_pid\":99,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"schema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":0,\"\\u0073chema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"guardian_pid\":99,\"guardian_\\u0070id\":41,\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"\\u0073chema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"guardian_pid\":41,\"worker_pid\":42.0,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":42e0,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"guardian_pid\":\"41\",\"worker_pid\":42,\"group_id\":42,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":042,\"closed\":true,\"exit_status\":0}",
			"{\"schema\":1,\"guardian_pid\":41,\"worker_pid\":42,\"group_id\":{\"value\":42},\"closed\":true,\"exit_status\":0}"
		]
		for packet in refused { XCTAssertFalse(Self.validTerminal(Data(packet.utf8), guardian: 41, status: 0)) }
	}
}
