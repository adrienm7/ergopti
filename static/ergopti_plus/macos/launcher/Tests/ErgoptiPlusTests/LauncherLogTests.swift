// Tests/ErgoptiPlusTests/LauncherLogTests.swift

// ==============================================================================
// MODULE: Launcher Persistent Log Tests
// DESCRIPTION:
// Regression coverage for F-MED-30 — the launcher's only diagnostic artifact on
// any failure path was a single NSLog call, invisible in any headless/automated
// launch context (no Console.app session watching, no attached debugger). A
// user reporting "it just doesn't start" gave the maintainers nothing to go on.
//
// FEATURES & RATIONALE:
// 1. LauncherLog is a top-level `enum` (not private) in the ErgoptiPlus
//    executable target, so `@testable import ErgoptiPlus` can call
//    LauncherLog.write(_:) directly — unlike AppDelegate's private methods,
//    this one entry point IS testable without a larger refactor.
// 2. The tests exercise short writes/EINTR and launch the real SwiftPM product
//    in multiple address spaces behind a shared start barrier. Exact record-set
//    equality proves no writer can overwrite or interleave a sibling record.
// 3. The documented-path test cleans up only bytes it can attribute to itself;
//    isolated concurrency tests use one owned 0700 temporary directory.
//
// NOTE: This target could not be built or executed in the environment this fix
// was authored in (no Xcode / macOS Swift toolchain available). Verify with
// `swift test --package-path static/ergopti_plus/macos/launcher` on macOS.
// ==============================================================================

import Darwin
import Dispatch
import Foundation
import XCTest
@testable import ErgoptiPlus

final class LauncherLogTests: XCTestCase {

	// ================================================================
	// ======= 1/ LauncherLog.write persists to the documented path =======
	// ================================================================

	private var logPath: String {
		return NSHomeDirectory() + "/Library/Logs/ErgoptiPlus/launcher.log"
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Resolves the real SwiftPM executable beside the XCTest bundle.
	private func launcherTestExecutable() throws -> URL {
		let productsDirectory = Bundle(for: LauncherLogTests.self)
			.bundleURL
			.deletingLastPathComponent()
		let candidates = [
			productsDirectory.appendingPathComponent("ErgoptiPlus"),
			productsDirectory
				.deletingLastPathComponent()
				.appendingPathComponent("ErgoptiPlus"),
		]
		guard let executable = candidates.first(where: {
			FileManager.default.isExecutableFile(atPath: $0.path)
		}) else {
			XCTFail("the real ErgoptiPlus SwiftPM product is required for log tests")
			throw NSError(domain: "ErgoptiLauncherLogTests", code: Int(ENOENT))
		}
		return executable
	}

	/// Creates the only directory shape accepted by the debug subprocess role.
	private func makeIsolatedLogDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-launcher-log-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		guard Darwin.chmod(directory.path, 0o700) == 0 else {
			throw NSError(domain: "ErgoptiLauncherLogTests", code: Int(errno))
		}
		return directory
	}

	/// Reads an exact byte count from a subprocess pipe under one monotonic bound.
	private func readExactBytes(
		from descriptor: Int32,
		count: Int,
		timeout: TimeInterval
	) -> [UInt8]? {
		guard count > 0, timeout > 0 else { return nil }
		var bytes = [UInt8](repeating: 0, count: count)
		var offset = 0
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		while offset < count {
			let remaining = deadline - ProcessInfo.processInfo.systemUptime
			guard remaining > 0 else { return nil }
			let milliseconds = min(remaining * 1_000, Double(Int32.max))
			var state = pollfd(
				fd: descriptor,
				events: Int16(POLLIN | POLLHUP | POLLERR),
				revents: 0
			)
			var pollResult: Int32
			repeat {
				pollResult = Darwin.poll(
					&state,
					nfds_t(1),
					Int32(milliseconds.rounded(.up))
				)
			} while pollResult == -1 && errno == EINTR
			guard pollResult > 0 else { return nil }

			let readCount = bytes.withUnsafeMutableBytes { buffer -> Int in
				guard let base = buffer.baseAddress else { return -1 }
				return Darwin.read(
					descriptor,
					base.advanced(by: offset),
					count - offset
				)
			}
			if readCount > 0 {
				offset += readCount
				continue
			}
			if readCount == -1 && errno == EINTR { continue }
			return nil
		}
		return bytes
	}

	/// Terminates only Process objects created by this XCTest, with one bound.
	private func stopExactProcesses(_ processes: [Process]) {
		for process in processes where process.isRunning { process.terminate() }
		let deadline = ProcessInfo.processInfo.systemUptime + 0.5
		while processes.contains(where: { $0.isRunning })
			&& ProcessInfo.processInfo.systemUptime < deadline {
			usleep(1_000)
		}
		for process in processes where process.isRunning {
			_ = Darwin.kill(process.processIdentifier, SIGKILL)
		}
		let killDeadline = ProcessInfo.processInfo.systemUptime + 0.5
		while processes.contains(where: { $0.isRunning })
			&& ProcessInfo.processInfo.systemUptime < killDeadline {
			usleep(1_000)
		}
	}
	#endif

	func testWriteAppendsATimestampedLineToTheDocumentedLogPath() throws {
		let tag = "LauncherLogTests-\(UUID().uuidString)"
		LauncherLog.write("test message \(tag)")

		XCTAssertTrue(
			FileManager.default.fileExists(atPath: logPath),
			"LauncherLog.write must create ~/Library/Logs/ErgoptiPlus/launcher.log on first use"
		)

		let contents = try String(contentsOfFile: logPath, encoding: .utf8)
		XCTAssertTrue(
			contents.contains(tag),
			"the written message must be persisted verbatim in launcher.log"
		)

		// Every line must start with a bracketed timestamp — the format the
		// fix's docstring promises (used to distinguish log entries when
		// diagnosing a report after the fact).
		let taggedLine = contents.split(separator: "\n").first { $0.contains(tag) }
		XCTAssertNotNil(taggedLine, "the tagged message must appear on its own line")
		XCTAssertTrue(
			taggedLine?.hasPrefix("[") == true,
			"each LauncherLog line must start with a bracketed timestamp, got: \(taggedLine ?? "<nil>")"
		)
	}

	func testWriteAppendsRatherThanOverwritingExistingContent() throws {
		let tagA = "LauncherLogTests-A-\(UUID().uuidString)"
		let tagB = "LauncherLogTests-B-\(UUID().uuidString)"

		LauncherLog.write("first message \(tagA)")
		LauncherLog.write("second message \(tagB)")

		let contents = try String(contentsOfFile: logPath, encoding: .utf8)
		XCTAssertTrue(contents.contains(tagA), "an earlier write must not be lost")
		XCTAssertTrue(contents.contains(tagB), "a later write must be appended, not replace the file")
	}

	func testConcurrentGuardianDiagnosticsRemainWholeAndVisible() throws {
		let tags = (0..<32).map { "GuardianLogTests-\($0)-\(UUID().uuidString)" }
		let group = DispatchGroup()
		for tag in tags {
			group.enter()
			DispatchQueue.global(qos: .userInitiated).async {
				LauncherLog.write("concurrent guardian diagnostic \(tag)")
				group.leave()
			}
		}
		XCTAssertEqual(group.wait(timeout: .now() + 3), .success)

		let contents = try String(contentsOfFile: logPath, encoding: .utf8)
		for tag in tags {
			XCTAssertEqual(
				contents.components(separatedBy: tag).count - 1,
				1,
				"every async guardian diagnostic must persist exactly once"
			)
		}
	}




	// ============================================================
	// ======= 2/ POSIX writes survive interruption and splits =======
	// ============================================================

	func testWriteDataRetriesEINTRAndCompletesPartialWrites() {
		let expected = Data("partial-write-regression".utf8)
		var observed = [UInt8]()
		var invocation = 0
		let result = writeLauncherLogData(
			expected,
			descriptor: 42,
			writeOperation: { descriptor, pointer, remaining in
				XCTAssertEqual(descriptor, 42)
				invocation += 1
				if invocation == 1 {
					errno = EINTR
					return -1
				}
				guard let pointer else { return -1 }
				let accepted = min(3, remaining)
				observed.append(contentsOf: UnsafeRawBufferPointer(
					start: pointer,
					count: accepted
				))
				return accepted
			}
		)

		XCTAssertTrue(result)
		XCTAssertGreaterThan(invocation, 2)
		XCTAssertEqual(Data(observed), expected)
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT




	// ===============================================================
	// ======= 3/ Advisory lock is honored across address spaces =======
	// ===============================================================

	func testSubprocessWaitsForTheInterprocessRecordLock() throws {
		let directory = try makeIsolatedLogDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let logURL = directory.appendingPathComponent("launcher.log")
		XCTAssertTrue(FileManager.default.createFile(
			atPath: logURL.path,
			contents: Data(),
			attributes: [.posixPermissions: 0o600]
		))
		XCTAssertEqual(Darwin.chmod(logURL.path, 0o600), 0)

		let owner = Darwin.open(logURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
		guard owner >= 0 else {
			return XCTFail("the test must open its isolated launcher.log")
		}
		guard Darwin.flock(owner, LOCK_EX | LOCK_NB) == 0 else {
			Darwin.close(owner)
			return XCTFail("the test must own launcher.log before the child starts")
		}
		var lockHeld = true
		defer {
			if lockHeld { _ = Darwin.flock(owner, LOCK_UN) }
			Darwin.close(owner)
		}

		let executable = try launcherTestExecutable()
		let blockedStartPipe = Pipe()
		let blockedBoundaryPipe = Pipe()
		let blockedProcess = Process()
		blockedProcess.executableURL = executable
		blockedProcess.arguments = [
			kLauncherLogAppendTestFlag,
			directory.path,
			UUID().uuidString,
			"blocked-writer",
			"1",
		]
		blockedProcess.standardInput = blockedStartPipe
		blockedProcess.standardOutput = blockedBoundaryPipe
		blockedProcess.standardError = FileHandle.nullDevice
		let blockedCompletion = DispatchSemaphore(value: 0)
		blockedProcess.terminationHandler = { _ in blockedCompletion.signal() }
		try blockedProcess.run()
		var exactProcesses = [blockedProcess]
		defer { stopExactProcesses(exactProcesses) }

		guard readExactBytes(
			from: blockedBoundaryPipe.fileHandleForReading.fileDescriptor,
			count: 1,
			timeout: 3
		) == [1] else {
			return XCTFail("the blocked child must reach its START barrier")
		}
		var start: UInt8 = 1
		XCTAssertEqual(Darwin.write(
			blockedStartPipe.fileHandleForWriting.fileDescriptor,
			&start,
			1
		), 1)
		XCTAssertEqual(
			readExactBytes(
				from: blockedBoundaryPipe.fileHandleForReading.fileDescriptor,
				count: 1,
				timeout: 3
			),
			[2],
			"the child must report the exact boundary immediately before flock"
		)
		guard blockedCompletion.wait(timeout: .now() + 3) == .success else {
			return XCTFail("a contended logger must honor its bounded lock timeout")
		}
		XCTAssertEqual(blockedProcess.terminationReason, .exit)
		XCTAssertEqual(
			blockedProcess.terminationStatus,
			LeaseWorkerExit.innerFailed.rawValue,
			"the child must fail closed instead of writing through a sibling LOCK_EX"
		)
		let blockedContents = try String(contentsOf: logURL, encoding: .utf8)
		XCTAssertTrue(
			blockedContents.isEmpty,
			"a writer that cannot acquire LOCK_EX must leave no partial record"
		)

		XCTAssertEqual(Darwin.flock(owner, LOCK_UN), 0)
		lockHeld = false

		let releasedStartPipe = Pipe()
		let releasedBoundaryPipe = Pipe()
		let releasedProcess = Process()
		let releasedSession = UUID().uuidString
		releasedProcess.executableURL = executable
		releasedProcess.arguments = [
			kLauncherLogAppendTestFlag,
			directory.path,
			releasedSession,
			"released-writer",
			"1",
		]
		releasedProcess.standardInput = releasedStartPipe
		releasedProcess.standardOutput = releasedBoundaryPipe
		releasedProcess.standardError = FileHandle.nullDevice
		let releasedCompletion = DispatchSemaphore(value: 0)
		releasedProcess.terminationHandler = { _ in releasedCompletion.signal() }
		try releasedProcess.run()
		exactProcesses.append(releasedProcess)
		guard readExactBytes(
			from: releasedBoundaryPipe.fileHandleForReading.fileDescriptor,
			count: 1,
			timeout: 3
		) == [1] else {
			return XCTFail("the released child must reach its START barrier")
		}
		start = 1
		XCTAssertEqual(Darwin.write(
			releasedStartPipe.fileHandleForWriting.fileDescriptor,
			&start,
			1
		), 1)
		XCTAssertEqual(
			readExactBytes(
				from: releasedBoundaryPipe.fileHandleForReading.fileDescriptor,
				count: 1,
				timeout: 3
			),
			[2]
		)
		guard releasedCompletion.wait(timeout: .now() + 3) == .success else {
			return XCTFail("the logger subprocess must exit after LOCK_EX is released")
		}
		XCTAssertEqual(releasedProcess.terminationReason, .exit)
		XCTAssertEqual(releasedProcess.terminationStatus, LeaseWorkerExit.success.rawValue)
		let releasedContents = try String(contentsOf: logURL, encoding: .utf8)
		XCTAssertTrue(releasedContents.contains("session=\(releasedSession) "))
	}




	// ============================================================
	// ======= 4/ Real multiprocess append remains lossless ========
	// ============================================================

	func testIndependentProcessesAppendEveryWholeRecordExactlyOnce() throws {
		let directory = try makeIsolatedLogDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let executable = try launcherTestExecutable()
		let session = UUID().uuidString
		let writerCount = 10
		let lineCount = 128
		let completion = DispatchGroup()
		var processes = [Process]()
		var startPipes = [Pipe]()
		var boundaryPipes = [Pipe]()
		defer {
			stopExactProcesses(processes)
		}

		for writer in 0..<writerCount {
			let startPipe = Pipe()
			let boundaryPipe = Pipe()
			let process = Process()
			process.executableURL = executable
			process.arguments = [
				kLauncherLogAppendTestFlag,
				directory.path,
				session,
				"writer-\(writer)",
				String(lineCount),
			]
			process.standardInput = startPipe
			process.standardOutput = boundaryPipe
			process.standardError = FileHandle.nullDevice
			completion.enter()
			process.terminationHandler = { _ in completion.leave() }
			do {
				try process.run()
			} catch {
				completion.leave()
				throw error
			}
			processes.append(process)
			startPipes.append(startPipe)
			boundaryPipes.append(boundaryPipe)
		}

		for pipe in boundaryPipes {
			guard readExactBytes(
				from: pipe.fileHandleForReading.fileDescriptor,
				count: 1,
				timeout: 5
			) == [1] else {
				return XCTFail("every real helper must reach the common START barrier")
			}
		}
		for pipe in startPipes {
			var start: UInt8 = 1
			XCTAssertEqual(Darwin.write(
				pipe.fileHandleForWriting.fileDescriptor,
				&start,
				1
			), 1)
		}
		for pipe in boundaryPipes {
			XCTAssertEqual(
				readExactBytes(
					from: pipe.fileHandleForReading.fileDescriptor,
					count: 1,
					timeout: 5
				),
				[2],
				"every writer must enter the production append boundary"
			)
		}
		guard completion.wait(timeout: .now() + 20) == .success else {
			return XCTFail("all exact logger subprocesses must finish within 20 seconds")
		}
		for process in processes {
			XCTAssertEqual(process.terminationReason, .exit)
			XCTAssertEqual(process.terminationStatus, LeaseWorkerExit.success.rawValue)
		}

		let payload = String(repeating: "x", count: 2_048)
		var expected = Set<String>()
		for writer in 0..<writerCount {
			for index in 0..<lineCount {
				expected.insert(
					"MULTIPROCESS session=\(session) writer=writer-\(writer) "
						+ "entry=\(index) payload=\(payload)"
				)
			}
		}
		let contents = try String(
			contentsOf: directory.appendingPathComponent("launcher.log"),
			encoding: .utf8
		)
		let observedRecords = contents.split(separator: "\n").compactMap { line -> String? in
			guard line.contains("session=\(session) "),
				let boundary = line.range(of: "] ")
			else { return nil }
			return String(line[boundary.upperBound...])
		}

		XCTAssertEqual(
			observedRecords.count,
			expected.count,
			"O_APPEND must not lose or duplicate any independently-written record"
		)
		XCTAssertEqual(
			Set(observedRecords),
			expected,
			"every line must retain one complete writer/index/payload record"
		)
	}
	#endif
}
