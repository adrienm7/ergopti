// Tests/ErgoptiPlusTests/KarabinerLeaseWorkerTests.swift

// ==============================================================================
// MODULE: Karabiner Lease Worker Tests
// DESCRIPTION:
// Exercises the native multi-role lease guardian without depending on a running
// Karabiner installation. Scripted channels and CLI children cover every async
// loss phase, while a real POSIX group harness kills one orphaned descendant
// without reaching unrelated shared-process simulations.
//
// FEATURES & RATIONALE:
// 1. Behavioral Loss Matrix: EOF, STOP, child timeout, outer loss, and inner
//    loss are driven through runtime state rather than asserted by source grep.
// 2. Tombstone Ordering: a late orphan mode writer is applied after cleanup to
//    prove revoked=1 still makes the generation ineffective.
// 3. Process Isolation: timeout and liveness preemption signal only the exact
//    direct fake CLI child while a concurrently running sibling remains alive.
// 4. Bounded Protocol: malformed identities, oversized lines, and line floods
//    fail before any child runner can observe a payload.
// 5. Cross-Reset Confinement: a positive counterfactual proves tombstone loss
//    on Core restart, then owned-group termination removes the late writer.
// 6. POSIX Inheritance: behavioral tests cover SIGCHLD reaping, SIGHUP reset,
//    collision-proof descriptors, stopped groups, and unrelated siblings.
// 7. EINTR Boundaries: injected post-read interruptions prove exact diagnostics
//    and terminal ownership loss still outrank buffered live protocol lines.
// 8. Executable Identity: every same-executable spawn revalidates the GUI-exported
//    vnode so an app-path replacement cannot become a lease authority silently.
// 9. Authenticated Recovery: an outer that loses its inner after READY falls back
//    to exact canonical-CLI fencing when every replacement spawn is unavailable.
// ==============================================================================

import Darwin
import Dispatch
import Foundation
import XCTest
@testable import ErgoptiPlus

/// Shell loop whose append-only marker proves that a sibling still executes.
private let kSiblingProgressCommand =
	"while :; do printf '.\\n' >> \"$1\"; /bin/sleep \"$2\"; done"
/// Delay passed to the shell witness between marker appends.
private let kSiblingProgressIntervalArgument = "0.02"
/// Maximum wait for one healthy sibling marker append.
private let kSiblingProgressTimeoutSeconds: TimeInterval = 2
/// Observation window in which a stopped sibling must make no progress.
private let kStoppedSiblingObservationSeconds: TimeInterval = 0.2
/// Grace before test cleanup force-kills its exact sibling child.
private let kSiblingTerminationGraceSeconds: TimeInterval = 0.5
/// Marker polling interval used only by the POSIX test witness.
private let kSiblingProgressPollMicroseconds: useconds_t = 10_000

/// Keeps one unrelated test process and its execution-progress witness together.
private struct ProgressingTestSibling {
	let process: Process
	let directory: URL
	let progressFile: URL
}

/// Verifies the native lease guardian’s loss, ordering, and PID-isolation contracts.
final class KarabinerLeaseWorkerTests: XCTestCase {
	private let token = "00112233445566778899aabbccddeeff"

	/// Builds one canonical generation without exercising argv parsing.
	/// - Parameter initialMode: Active or paused starting mode.
	/// - Returns: Exact identity accepted by every runtime test.
	private func makeIdentity(initialMode: Int = kLeaseModeActive) -> LeaseIdentity {
		return LeaseIdentity(
			cliPath: "/tmp/fake-karabiner-cli",
			token: token,
			modeName: "ergopti_mode_\(token)",
			revokedName: "ergopti_revoked_\(token)",
			initialMode: initialMode,
			heartbeatSeconds: 5
		)
	}

	/// Runs the inner runtime with a scripted channel and child executor.
	/// - Parameters:
	///   - events: Ordered outer commands or liveness losses.
	///   - results: Per-CLI scripted results, with success as the default.
	///   - probeCalls: CLI call indexes that must inspect pending STOP or EOF.
	/// - Returns: Exit code, channel acknowledgements, payloads, and concurrency.
	private func runInner(
		events: [LeaseInnerChannelEvent],
		results: [LeaseCLIResult] = [],
		probeCalls: Set<Int> = []
	) -> (
		exitCode: Int32,
		acknowledgements: [LeaseInnerAcknowledgement],
		payloads: [String],
		maximumConcurrentChildren: Int,
		executionTimes: [TimeInterval]
	) {
		let channel = ScriptedLeaseInnerChannel(events: events)
		var monotonicTime: TimeInterval = 0
		let executor = ScriptedLeaseCLIExecutor(
			results: results,
			probeCalls: probeCalls,
			timestamp: { monotonicTime }
		)
		let runtime = KarabinerLeaseInnerRuntime(
			identity: makeIdentity(),
			channel: channel,
			executor: executor,
			cliTimeout: 0.05,
			fenceConfirmationGrace: 0.25,
			uptime: { monotonicTime },
			sleep: { microseconds in
				monotonicTime += Double(microseconds) / 1_000_000
			}
		)
		let exitCode = runtime.run()
		return (
			exitCode,
			channel.acknowledgements,
			executor.payloads,
			executor.maximumConcurrentChildren,
			executor.executionTimes
		)
	}





	// ========================================
	// ========================================
	// ======= 1/ Identity and Payloads =======
	// ========================================
	// ========================================

	/// Proves the public worker accepts only the final mode/tombstone argv shape.
	func testWorkerIdentityUsesOneModeAndOneTombstone() {
		let arguments = [
			"/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
			kKarabinerLeaseWorkerFlag,
			kCanonicalKarabinerCLIPath,
			"ergopti_mode_\(token)",
			"ergopti_revoked_\(token)",
			"2",
			"5",
		]

		let identity = LeaseIdentity.parse(arguments: arguments, role: .worker)

		XCTAssertEqual(identity?.token, token)
		XCTAssertEqual(identity?.initialMode, kLeaseModePaused)
		XCTAssertEqual(identity?.heartbeatSeconds, 5)
		XCTAssertNil(
			LeaseIdentity.parse(
				arguments: Array(arguments.prefix(4)) + [
					"ergopti_pause_\(token)",
					"ergopti_revoked_\(token)",
					"1",
					"5",
				],
				role: .worker
			),
			"legacy lease/pause argv must never reactivate the removed split contract"
		)
	}

	/// Proves the Lua helper identity comes from the running launcher's file.
	func testLauncherExecutableFileIdentityMatchesLstat() throws {
		let fixture = try makeExecutableFixture(body: "exit 0\n")
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		var attributes = stat()
		XCTAssertEqual(fixture.path.withCString { Darwin.lstat($0, &attributes) }, 0)

		let identity = try XCTUnwrap(
			launcherExecutableFileIdentity(at: fixture.path)
		)

		XCTAssertEqual(identity.device, String(attributes.st_dev))
		XCTAssertEqual(identity.inode, String(attributes.st_ino))
		XCTAssertNil(launcherExecutableFileIdentity(at: nil))
		XCTAssertNil(launcherExecutableFileIdentity(at: fixture.path + ".missing"))
	}

	/// Proves inherited launcher identity accepts only canonical exact stat text.
	func testLeaseExecutableIdentityParsesCanonicalEnvironment() throws {
		let fixture = try makeExecutableFixture(body: "exit 0\n")
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let observed = try XCTUnwrap(LeaseExecutableIdentity.capture(at: fixture.path))
		let parsed = LeaseExecutableIdentity.parse(environment: [
			kLauncherDeviceEnvironment: observed.device,
			kLauncherInodeEnvironment: observed.inode,
		])

		XCTAssertEqual(parsed, observed)
		XCTAssertEqual(
			LeaseExecutableIdentity.parse(device: observed.device, inode: observed.inode),
			observed
		)
		for malformed in ["", "01", "-1", " 1", "١"] {
			XCTAssertNil(LeaseExecutableIdentity.parse(environment: [
				kLauncherDeviceEnvironment: malformed,
				kLauncherInodeEnvironment: observed.inode,
			]))
			XCTAssertNil(LeaseExecutableIdentity.parse(
				device: malformed,
				inode: observed.inode
			))
		}
		XCTAssertNil(LeaseExecutableIdentity.parse(environment: [
			kLauncherDeviceEnvironment: observed.device,
		]))
	}

	/// Proves a cached path cannot authorize a replacement self-respawn.
	func testInnerSpawnerRevalidatesExecutableBeforeEverySpawn() throws {
		let fixture = try makeExecutableFixture(body: "exit 0\n")
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let replacementMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("replacement-executed.marker")
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: replacementMarker.path,
			revokedName: "unused",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let spawner = PosixLeaseInnerSpawner(executablePath: fixture.path)
		let first = try XCTUnwrap(spawner.spawn(identity: identity))
		first.closeSocket()
		first.terminateOwnedProcessGroupAndReap()

		try ("#!/bin/sh\n: > \"$3\"\nexit 0\n").write(
			to: fixture,
			atomically: true,
			encoding: .utf8
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: fixture.path
		)
		let replacement = spawner.spawn(identity: identity)
		if let replacement {
			_ = waitForFile(at: replacementMarker, timeout: 1)
			replacement.closeSocket()
			replacement.terminateOwnedProcessGroupAndReap()
		}

		XCTAssertNil(
			replacement,
			"a new inode at the same bundle path must not become a private lease child"
		)
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: replacementMarker.path),
			"rejected replacement code must never execute"
		)
	}

	/// Proves replacement cannot win between the final lstat and posix_spawn.
	func testInnerSpawnerKillsRacingReplacementBeforeUserSpaceExecution() throws {
		let fixture = try makeExecutableFixture(body: "exit 0\n")
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let expectedIdentity = try XCTUnwrap(LeaseExecutableIdentity.capture(at: fixture.path))
		let replacementMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("racing-replacement-executed.marker")
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: replacementMarker.path,
			revokedName: "unused",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		var identityReads = 0
		var replacementError: Error?
		let spawner = PosixLeaseInnerSpawner(
			executablePath: fixture.path,
			expectedExecutableIdentity: expectedIdentity,
			executableIdentityReader: { path in
				identityReads += 1
				let observed = LeaseExecutableIdentity.capture(at: path)
				if identityReads == 1 {
					do {
						try ("#!/bin/sh\n: > \"$3\"\nexit 0\n").write(
							to: fixture,
							atomically: true,
							encoding: .utf8
						)
						try FileManager.default.setAttributes(
							[.posixPermissions: 0o700],
							ofItemAtPath: fixture.path
						)
					} catch {
						replacementError = error
					}
				}
				return observed
			}
		)

		let replacement = spawner.spawn(identity: identity)
		if let replacement {
			_ = waitForFile(at: replacementMarker, timeout: 1)
			replacement.closeSocket()
			replacement.terminateOwnedProcessGroupAndReap()
		}

		XCTAssertNil(replacementError)
		XCTAssertEqual(identityReads, 1, "the injected pre-spawn read must create the race")
		XCTAssertNil(replacement, "a vnode swap during spawn must not become an inner")
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: replacementMarker.path),
			"the suspended replacement must be killed before any user-space instruction"
		)
	}

	/// Proves a resumed inner authenticates its launch identity before fd 3/runtime.
	func testInnerInvocationRejectsAReplacedLauncherVnode() throws {
		let fixture = try makeExecutableFixture(body: "exit 0\n")
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let expectedIdentity = try XCTUnwrap(LeaseExecutableIdentity.capture(at: fixture.path))
		let arguments = [
			fixture.path,
			kKarabinerLeaseInnerFlag,
			kCanonicalKarabinerCLIPath,
			"ergopti_mode_\(token)",
			"ergopti_revoked_\(token)",
			"5",
			expectedIdentity.device,
			expectedIdentity.inode,
		]

		XCTAssertNotNil(validatedInnerLeaseIdentity(
			arguments: arguments,
			executablePath: fixture.path
		))
		try ("#!/bin/sh\nexit 0\n").write(
			to: fixture,
			atomically: true,
			encoding: .utf8
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: fixture.path
		)

		XCTAssertNil(validatedInnerLeaseIdentity(
			arguments: arguments,
			executablePath: fixture.path
		), "a private inner must reject a vnode different from its serialized authority")
	}

	/// Proves invalid identity data fails before any executable can be launched.
	func testIdentityRejectsMismatchedNamesAndUnboundedHeartbeat() {
		let base = [
			"/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
			kKarabinerLeaseWorkerFlag,
			kCanonicalKarabinerCLIPath,
			"ergopti_mode_\(token)",
			"ergopti_revoked_ffeeddccbbaa99887766554433221100",
			"1",
			"5",
		]
		XCTAssertNil(LeaseIdentity.parse(arguments: base, role: .worker))

		for heartbeat in ["0", "nan", "inf", "86401"] {
			var arguments = base
			arguments[4] = "ergopti_revoked_\(token)"
			arguments[6] = heartbeat
			XCTAssertNil(
				LeaseIdentity.parse(arguments: arguments, role: .worker),
				"heartbeat \(heartbeat) must fail before any mode write"
			)
		}
		let innerBase = [
			"/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
			kKarabinerLeaseInnerFlag,
			kCanonicalKarabinerCLIPath,
			"ergopti_mode_\(token)",
			"ergopti_revoked_\(token)",
		]
		XCTAssertNil(LeaseIdentity.parse(arguments: innerBase, role: .inner))
		let innerIdentity = ["5", "123", "456"]
		XCTAssertNotNil(LeaseIdentity.parse(arguments: innerBase + innerIdentity, role: .inner))
		XCTAssertNil(
			LeaseIdentity.parse(arguments: innerBase + ["86401", "123", "456"], role: .inner)
		)
		for malformed in ["", "01", "-1", " 1", "١"] {
			XCTAssertNil(LeaseIdentity.parse(
				arguments: innerBase + ["5", malformed, "456"],
				role: .inner
			))
		}
	}

	/// Proves no shared stock Karabiner executable can cross the CLI boundary.
	func testIdentityRejectsEverySharedKarabinerProcessFamily() {
		XCTAssertEqual(
			kCanonicalKarabinerCLIPath,
			"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
		)
		let supportPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/"
		let forbiddenPaths = [
			"/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements",
			"/Applications/Karabiner-Elements.app/Contents/Library/LoginItems/"
				+ "Karabiner-Menu.app/Contents/MacOS/Karabiner-Menu",
			supportPath
				+ "Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service",
			supportPath + "bin/karabiner_console_user_server",
			supportPath + "bin/karabiner_grabber",
			supportPath + "bin/karabiner_session_monitor",
			supportPath + "bin/karabiner_observer",
			supportPath + "Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/"
				+ "Karabiner-VirtualHIDDevice-Manager",
			"/tmp/karabiner_cli",
		]
		let roles: [(LeaseInvocationRole, String, [String])] = [
			(.worker, kKarabinerLeaseWorkerFlag, ["1", "5"]),
			(.revoke, kKarabinerLeaseRevokeFlag, []),
			(.inner, kKarabinerLeaseInnerFlag, ["5", "123", "456"]),
		]
		for (role, flag, suffix) in roles {
			let arguments = [
				"/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
				flag,
				kCanonicalKarabinerCLIPath,
				"ergopti_mode_\(token)",
				"ergopti_revoked_\(token)",
			] + suffix
			XCTAssertNotNil(
				LeaseIdentity.parse(arguments: arguments, role: role),
				"the positive control for \(flag) must reach CLI identity validation"
			)
		}

		for forbiddenPath in forbiddenPaths {
			for (role, flag, suffix) in roles {
				let arguments = [
					"/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
					flag,
					forbiddenPath,
					"ergopti_mode_\(token)",
					"ergopti_revoked_\(token)",
				] + suffix
				XCTAssertNil(
					LeaseIdentity.parse(arguments: arguments, role: role),
					"\(forbiddenPath) must never become a signalable direct child"
				)
			}
		}
	}

	/// Proves live writers cannot clear the monotone tombstone.
	func testLivePayloadNeverMentionsRevokedAndFenceRepeatsIdentically() {
		let identity = makeIdentity()
		let active = LeasePayloads.mode(identity: identity, mode: kLeaseModeActive)
		let paused = LeasePayloads.mode(identity: identity, mode: kLeaseModePaused)
		let firstFence = LeasePayloads.fence(identity: identity)
		let finalFence = LeasePayloads.fence(identity: identity)

		XCTAssertEqual(active, "{\"ergopti_mode_\(token)\":1}")
		XCTAssertEqual(paused, "{\"ergopti_mode_\(token)\":2}")
		XCTAssertFalse(active.contains("revoked"))
		XCTAssertFalse(paused.contains("revoked"))
		XCTAssertEqual(
			firstFence,
			"{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		)
		XCTAssertEqual(firstFence, finalFence)
	}

	/// Proves every internal role stays on the headless bootstrap branch.
	func testAllLeaseRolesAreHandledBeforeApplicationBootstrap() {
		for flag in [
			kKarabinerLeaseWorkerFlag,
			kKarabinerLeaseRevokeFlag,
			kKarabinerLeaseInnerFlag,
		] {
			XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: ["ErgoptiPlus", flag]))
		}
		XCTAssertFalse(KarabinerLeaseWorker.handles(arguments: ["ErgoptiPlus"]))
	}

	/// Proves headless dispatch and helper export precede every GUI/child side effect.
	func testHeadlessDispatchAndHelperExportAreOrderedBeforeSideEffects() throws {
		let testFile = URL(fileURLWithPath: #filePath)
		let launcherRoot = testFile
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let mainURL = launcherRoot
			.appendingPathComponent("Sources/ErgoptiPlus/main.swift")
		let source = try String(contentsOf: mainURL, encoding: .utf8)
		let headless = try XCTUnwrap(
			source.range(of: "KarabinerLeaseWorker.handles")?.lowerBound
		)
		let preferences = try XCTUnwrap(
			source.range(of: "let _earlyInitLua")?.lowerBound
		)
		let application = try XCTUnwrap(
			source.range(of: "NSApplication.shared")?.lowerBound
		)
		let helperExport = try XCTUnwrap(
			source.range(of: "env[\"ERGOPTI_LAUNCHER_EXECUTABLE\"]")?.lowerBound
		)
		let deviceExport = try XCTUnwrap(
			source.range(of: "env[\"ERGOPTI_LAUNCHER_DEVICE\"]")?.lowerBound
		)
		let inodeExport = try XCTUnwrap(
			source.range(of: "env[\"ERGOPTI_LAUNCHER_INODE\"]")?.lowerBound
		)
		let childStart = try XCTUnwrap(
			source.range(of: "try processRunner(proc)")?.lowerBound
		)

		XCTAssertLessThan(headless, preferences)
		XCTAssertLessThan(headless, application)
		XCTAssertLessThan(helperExport, childStart)
		XCTAssertLessThan(deviceExport, childStart)
		XCTAssertLessThan(inodeExport, childStart)
	}

	/// Proves socketpair endpoints can never alias stdio or the fixed inner fd.
	func testReservedSocketEndpointsStayAboveEveryFileActionTarget() throws {
		let sockets = try XCTUnwrap(makeReservedLeaseSocketEndpoints())
		defer {
			_ = Darwin.close(sockets.outerDescriptor)
			_ = Darwin.close(sockets.innerDescriptor)
		}

		XCTAssertGreaterThan(sockets.outerDescriptor, STDERR_FILENO)
		XCTAssertGreaterThan(sockets.innerDescriptor, STDERR_FILENO)
		XCTAssertNotEqual(sockets.outerDescriptor, 3)
		XCTAssertNotEqual(sockets.innerDescriptor, 3)
		XCTAssertNotEqual(sockets.outerDescriptor, sockets.innerDescriptor)
		XCTAssertNotEqual(
			fcntl(sockets.outerDescriptor, F_GETFD) & FD_CLOEXEC,
			0
		)
		XCTAssertNotEqual(
			fcntl(sockets.innerDescriptor, F_GETFD) & FD_CLOEXEC,
			0
		)
	}

	/// Reproduces the reservation root cause with inherited fd 0...3 all closed.
	func testReservedSocketsStayAboveFD3WhenLowDescriptorsAreClosed() {
		var rawReportPipe = [Int32](repeating: -1, count: 2)
		let pipeStatus = rawReportPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(pipeStatus, 0)
		guard pipeStatus == 0 else { return }
		let reportRead = fcntl(rawReportPipe[0], F_DUPFD_CLOEXEC, 10)
		let reportWrite = fcntl(rawReportPipe[1], F_DUPFD_CLOEXEC, 10)
		_ = Darwin.close(rawReportPipe[0])
		_ = Darwin.close(rawReportPipe[1])
		XCTAssertGreaterThanOrEqual(reportRead, 10)
		XCTAssertGreaterThanOrEqual(reportWrite, 10)
		guard reportRead >= 10, reportWrite >= 10 else {
			if reportRead >= 0 { _ = Darwin.close(reportRead) }
			if reportWrite >= 0 { _ = Darwin.close(reportWrite) }
			return
		}

		let harnessPID = Darwin.fork()
		guard harnessPID >= 0 else {
			XCTFail("the closed-descriptor harness must fork")
			_ = Darwin.close(reportRead)
			_ = Darwin.close(reportWrite)
			return
		}
		if harnessPID == 0 {
			_ = Darwin.close(reportRead)
			_ = Darwin.close(0)
			_ = Darwin.close(1)
			_ = Darwin.close(2)
			_ = Darwin.close(3)
			var succeeded = false
			if let sockets = makeReservedLeaseSocketEndpoints() {
				succeeded = sockets.outerDescriptor > kInnerControlDescriptor
					&& sockets.innerDescriptor > kInnerControlDescriptor
					&& sockets.outerDescriptor != sockets.innerDescriptor
					&& fcntl(sockets.outerDescriptor, F_GETFD) & FD_CLOEXEC != 0
					&& fcntl(sockets.innerDescriptor, F_GETFD) & FD_CLOEXEC != 0
				_ = Darwin.close(sockets.outerDescriptor)
				_ = Darwin.close(sockets.innerDescriptor)
			}
			var report: UInt8 = succeeded ? 1 : 0
			_ = withUnsafePointer(to: &report) { pointer in
				Darwin.write(reportWrite, pointer, 1)
			}
			_ = Darwin.close(reportWrite)
			Darwin._exit(succeeded ? 0 : 1)
		}
		XCTAssertGreaterThan(harnessPID, 0)

		_ = Darwin.close(reportWrite)
		var reportPoll = pollfd(
			fd: reportRead,
			events: Int16(POLLIN | POLLHUP | POLLERR),
			revents: 0
		)
		guard Darwin.poll(&reportPoll, 1, 5_000) > 0 else {
			_ = Darwin.kill(harnessPID, SIGKILL)
			var status: Int32 = 0
			while waitpid(harnessPID, &status, 0) == -1 && errno == EINTR {}
			_ = Darwin.close(reportRead)
			XCTFail("the closed-descriptor subprocess exceeded its bounded deadline")
			return
		}
		var report: UInt8 = 0
		let reportBytes = withUnsafeMutablePointer(to: &report) { pointer in
			Darwin.read(reportRead, pointer, 1)
		}
		_ = Darwin.close(reportRead)
		var status: Int32 = 0
		let waited = waitpid(harnessPID, &status, 0)

		XCTAssertEqual(waited, harnessPID)
		XCTAssertEqual(reportBytes, 1)
		XCTAssertEqual(report, 1)
		XCTAssertEqual((status >> 8) & 0xFF, 0)
	}

	/// Proves the exact inner socket cannot leak through exec into a CLI child.
	func testPreparedInnerControlDescriptorClosesAcrossCLIExec() throws {
		var sockets = [Int32](repeating: -1, count: 2)
		let socketStatus = sockets.withUnsafeMutableBufferPointer { buffer in
			Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
		}
		XCTAssertEqual(socketStatus, 0)
		guard socketStatus == 0 else { return }
		defer {
			_ = Darwin.close(sockets[0])
			_ = Darwin.close(sockets[1])
		}
		let inheritedPath = "/dev/fd/\(sockets[1])"
		let fixture = try makeExecutableFixture(
			body: "if printf inherited 2>/dev/null >\"\(inheritedPath)\"; then\n"
				+ "  exit 42\nfi\nexit 0\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let executor = PosixLeaseCLIExecutor()

		XCTAssertEqual(
			executor.execute(
				cliPath: fixture.path,
				payload: "{}",
				timeout: 1,
				interruption: { .none }
			),
			.failed(42),
			"the counterfactual proves an ordinary socket descriptor survives exec"
		)
		XCTAssertTrue(prepareInnerControlDescriptor(sockets[1]))
		XCTAssertNotEqual(fcntl(sockets[1], F_GETFD) & FD_CLOEXEC, 0)
		XCTAssertEqual(
			executor.execute(
				cliPath: fixture.path,
				payload: "{}",
				timeout: 1,
				interruption: { .none }
			),
			.success
		)
	}

	/// Proves inherited SIGCHLD ignore cannot auto-reap an exact owned child.
	func testChildReapingPreparationRestoresWaitpidOwnership() {
		let previousDisposition = Darwin.signal(SIGCHLD, SIG_IGN)
		defer { _ = Darwin.signal(SIGCHLD, previousDisposition) }
		prepareLeaseChildReaping()

		guard let rawArguments = duplicateLeaseArguments(["/usr/bin/true"]) else {
			XCTFail("the child-reaping harness must allocate argv")
			return
		}
		defer {
			for case let pointer? in rawArguments { free(pointer) }
		}
		var mutableArguments = rawArguments
		var processID: pid_t = 0
		let spawnStatus = mutableArguments.withUnsafeMutableBufferPointer { buffer in
			posix_spawn(
				&processID,
				"/usr/bin/true",
				nil,
				nil,
				buffer.baseAddress,
				_NSGetEnviron().pointee
			)
		}
		guard spawnStatus == 0 else {
			XCTFail("the child-reaping harness failed to spawn: \(spawnStatus)")
			return
		}
		var status: Int32 = 0

		XCTAssertEqual(waitpid(processID, &status, 0), processID)
	}

	/// Proves POSIX initializer errors are returned directly, never stale errno.
	func testCLIFileActionInitializationPreservesReturnedError() {
		errno = ENOENT
		var initializerCalls = 0
		let executor = PosixLeaseCLIExecutor(initializeFileActions: { _ in
			initializerCalls += 1
			return EBUSY
		})

		let result = executor.execute(
			cliPath: "/usr/bin/true",
			payload: "{}",
			timeout: 1,
			interruption: { .none }
		)

		XCTAssertEqual(result, .spawnFailed(EBUSY))
		XCTAssertEqual(initializerCalls, 1)
	}

	/// Proves a CLI close-action failure aborts before creating any child.
	func testCLICloseActionFailureRefusesSpawn() {
		let standardDescriptors = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
		guard standardDescriptors.allSatisfy({ fcntl($0, F_GETFD) >= 0 }) else {
			XCTFail("the CLI close-action harness requires open standard descriptors")
			return
		}
		var closeDescriptors: [Int32] = []
		let executor = PosixLeaseCLIExecutor(addCloseAction: { _, descriptor in
			closeDescriptors.append(descriptor)
			return EIO
		})

		let result = executor.execute(
			cliPath: "/usr/bin/true",
			payload: "{}",
			timeout: 1,
			interruption: { .none }
		)

		XCTAssertEqual(result, .spawnFailed(EIO))
		XCTAssertEqual(closeDescriptors.count, 1)
		for descriptor in closeDescriptors {
			errno = 0
			let probeStatus = fcntl(descriptor, F_GETFD)
			let probeError = errno
			XCTAssertEqual(probeStatus, -1)
			XCTAssertEqual(probeError, EBADF)
		}
	}

	/// Proves exit zero is clean only when combined stdout and stderr reach empty EOF.
	func testCLIRequiresCompletelyEmptyDiagnosticsForSuccess() throws {
		let cases: [(body: String, expected: LeaseCLIResult)] = [
			("exit 0\n", .success),
			("printf 'stdout diagnostic\\n'\nexit 0\n", .diagnosticOutput),
			("printf 'stderr diagnostic\\n' >&2\nexit 0\n", .diagnosticOutput),
			("printf x\nexit 0\n", .diagnosticOutput),
		]

		for testCase in cases {
			let fixture = try makeExecutableFixture(body: testCase.body)
			defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
			let result = PosixLeaseCLIExecutor().execute(
				cliPath: fixture.path,
				payload: "{}",
				timeout: 1,
				interruption: { .none }
			)
			XCTAssertEqual(result, testCase.expected)
		}
	}

	/// Proves diagnostics larger than a pipe are drained while the child runs.
	func testCLILargeDiagnosticOutputCannotDeadlockBeforeExit() throws {
		let fixture = try makeExecutableFixture(
			body: "dd if=/dev/zero bs=65536 count=32 2>/dev/null\nexit 0\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

		let started = ProcessInfo.processInfo.systemUptime
		let result = PosixLeaseCLIExecutor().execute(
			cliPath: fixture.path,
			payload: "{}",
			timeout: 3,
			interruption: { .none }
		)

		XCTAssertEqual(result, .diagnosticOutput)
		XCTAssertLessThan(
			ProcessInfo.processInfo.systemUptime - started,
			3,
			"combined output must drain concurrently instead of filling the child pipe"
		)
	}

	/// Proves an always-readable diagnostic source yields after one bounded turn.
	func testCLIDiagnosticDrainBoundsEachTurnUnderContinuousOutput() {
		var readCalls = 0
		let result = drainLeaseDiagnostics(from: -1) { _, buffer in
			readCalls += 1
			return buffer.count
		}

		switch result {
		case .progressed(let byteCount):
			XCTAssertEqual(
				byteCount,
				kCLIDiagnosticReadBytes * kMaximumCLIDiagnosticChunksPerDrain
			)
		default:
			XCTFail("a continuously readable source must yield after one bounded drain turn")
		}
		XCTAssertEqual(readCalls, kMaximumCLIDiagnosticChunksPerDrain)
	}

	/// Proves every inner close-action position rejects spawn on its own failure.
	func testInnerSpawnerCloseActionFailureRefusesEverySpawnPosition() throws {
		var baselineCloseCalls = 0
		let baselineSpawner = PosixLeaseInnerSpawner(
			executablePath: "/usr/bin/true",
			addCloseAction: { fileActions, descriptor in
				baselineCloseCalls += 1
				return addLeaseSpawnCloseAction(
					fileActions: &fileActions,
					descriptor: descriptor
				)
			}
		)
		let baselineInner = try XCTUnwrap(
			baselineSpawner.spawn(identity: makeIdentity())
		)
		baselineInner.closeSocket()
		baselineInner.reapAfterFenceOrTerminate()
		XCTAssertGreaterThanOrEqual(baselineCloseCalls, 2)
		XCTAssertLessThanOrEqual(baselineCloseCalls, 3)
		guard baselineCloseCalls >= 2 else { return }

		for failingCall in 1...baselineCloseCalls {
			var closeCalls = 0
			var closeDescriptors: [Int32] = []
			let spawner = PosixLeaseInnerSpawner(
				executablePath: "/usr/bin/true",
				addCloseAction: { fileActions, descriptor in
					closeCalls += 1
					closeDescriptors.append(descriptor)
					if closeCalls == failingCall { return EIO }
					return addLeaseSpawnCloseAction(
						fileActions: &fileActions,
						descriptor: descriptor
					)
				}
			)
			let unexpectedInner = spawner.spawn(identity: makeIdentity())
			if let unexpectedInner {
				unexpectedInner.closeSocket()
				unexpectedInner.terminateOwnedProcessGroupAndReap()
			}

			XCTAssertNil(
				unexpectedInner,
				"close-action failure \(failingCall) must abort before posix_spawn"
			)
			XCTAssertEqual(closeCalls, failingCall)
			for descriptor in closeDescriptors {
				errno = 0
				let probeStatus = fcntl(descriptor, F_GETFD)
				let probeError = errno
				XCTAssertEqual(probeStatus, -1)
				XCTAssertEqual(probeError, EBADF)
			}
		}
	}

	/// Proves process-group ownership is atomic and every group signal precedes reap.
	func testInnerProcessGroupOwnershipCannotRaceOrOutliveReap() throws {
		let testFile = URL(fileURLWithPath: #filePath)
		let launcherRoot = testFile
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let sourceURL = launcherRoot
			.appendingPathComponent("Sources/ErgoptiPlus/KarabinerLeaseWorker.swift")
		let source = try String(contentsOf: sourceURL, encoding: .utf8)
		XCTAssertEqual(
			source.components(separatedBy: "posix_spawn_file_actions_addclose").count - 1,
			1,
			"every raw close action must route through the single checked seam"
		)
		XCTAssertFalse(
			source.contains("_ = posix_spawn_file_actions_addclose"),
			"no close-action status may be discarded"
		)
		let injectedCloseOwners = source.components(
			separatedBy: "private let addCloseAction: LeaseSpawnCloseAction"
		).count - 1
		let checkedCloseCalls = source.components(
			separatedBy: "let closeStatus = addCloseAction(&fileActions"
		).count - 1
		let closeFailureGuards = source.components(
			separatedBy: "guard closeStatus == 0"
		).count - 1
		XCTAssertGreaterThanOrEqual(injectedCloseOwners, 2)
		XCTAssertEqual(checkedCloseCalls, injectedCloseOwners)
		XCTAssertEqual(closeFailureGuards, checkedCloseCalls)
		let spawnerStart = try XCTUnwrap(
			source.range(of: "final class PosixLeaseInnerSpawner")?.lowerBound
		)
		let outerStart = try XCTUnwrap(
			source.range(of: "final class KarabinerLeaseOuterRuntime")?.lowerBound
		)
		let spawnerSource = String(source[spawnerStart..<outerStart])
		let groupFlag = try XCTUnwrap(
			spawnerSource.range(of: "POSIX_SPAWN_SETPGROUP")?.lowerBound
		)
		let groupValue = try XCTUnwrap(
			spawnerSource.range(
				of: "posix_spawnattr_setpgroup(&spawnAttributes, 0)"
			)?.lowerBound
		)
		let spawn = try XCTUnwrap(
			spawnerSource.range(of: "posix_spawn(")?.lowerBound
		)

		XCTAssertLessThan(groupFlag, spawn)
		XCTAssertLessThan(groupValue, spawn)
		XCTAssertTrue(spawnerSource.contains("&spawnAttributes,"))
		let reservedSockets = try XCTUnwrap(
			spawnerSource.range(of: "makeReservedLeaseSocketEndpoints()")?.lowerBound
		)
		let nullOpen = try XCTUnwrap(
			spawnerSource.range(of: "Darwin.open(\"/dev/null\"")?.lowerBound
		)
		XCTAssertLessThan(reservedSockets, nullOpen)
		XCTAssertEqual(source.components(separatedBy: "F_DUPFD_CLOEXEC").count - 1, 2)
		XCTAssertTrue(source.contains("fileprivate init(processID: pid_t"))
		XCTAssertTrue(source.contains("processGroupID = processID"))
		let dispatchStart = try XCTUnwrap(
			source.range(of: "static func run(arguments: [String])")?.lowerBound
		)
		let dispatchSource = String(source[dispatchStart...])
		let childReapingReset = try XCTUnwrap(
			dispatchSource.range(of: "prepareLeaseChildReaping()")?.lowerBound
		)
		let innerDispatch = try XCTUnwrap(
			dispatchSource.range(of: "if arguments[1] == kKarabinerLeaseInnerFlag")?.lowerBound
		)
		XCTAssertLessThan(childReapingReset, innerDispatch)
		let detachedDispatch = try XCTUnwrap(
			dispatchSource.range(of: "let detached = arguments[1]")?.lowerBound
		)
		let innerDispatchSource = String(dispatchSource[innerDispatch..<detachedDispatch])
		let innerIdentityCheck = try XCTUnwrap(
			innerDispatchSource.range(of: "validatedInnerLeaseIdentity(")?.lowerBound
		)
		let innerDescriptorPrepare = try XCTUnwrap(
			innerDispatchSource.range(of: "prepareInnerControlDescriptor(")?.lowerBound
		)
		XCTAssertLessThan(
			innerIdentityCheck,
			innerDescriptorPrepare,
			"the inner must authenticate its executable before touching fd 3 or runtime state"
		)

		let terminationStart = try XCTUnwrap(
			source.range(of: "func terminateOwnedProcessGroupAndReap()")?.lowerBound
		)
		let terminationEnd = try XCTUnwrap(
			source.range(
				of: "/// Abstracts same-executable inner role creation.",
				range: terminationStart..<source.endIndex
			)?.lowerBound
		)
		let terminationSource = String(source[terminationStart..<terminationEnd])
		let term = try XCTUnwrap(
			terminationSource.range(of: "killpg(processGroupID, SIGTERM)")?.lowerBound
		)
		let kill = try XCTUnwrap(
			terminationSource.range(of: "killpg(processGroupID, SIGKILL)")?.lowerBound
		)
		let reap = try XCTUnwrap(
			terminationSource.range(of: "reapBlocking()")?.lowerBound
		)

		XCTAssertLessThan(term, kill)
		XCTAssertLessThan(kill, reap)

		let recoveryStart = try XCTUnwrap(
			source.range(of: "case .fenceAndFinish(let exitCode")?.lowerBound
		)
		let normalFinish = try XCTUnwrap(
			source.range(
				of: "case .finish(let exitCode)",
				range: recoveryStart..<source.endIndex
			)?.lowerBound
		)
		let recoverySource = String(source[recoveryStart..<normalFinish])
		let retireGroup = try XCTUnwrap(
			recoverySource.range(of: "retireCurrentAfterSupervisionLoss()")?.lowerBound
		)
		let replacementFence = try XCTUnwrap(
			recoverySource.range(of: "recoverFenceUntilSuccess()")?.lowerBound
		)

		XCTAssertLessThan(retireGroup, replacementFence)
		XCTAssertTrue(
			source[normalFinish...].hasPrefix(
				"case .finish(let exitCode):\n\t\t\t\tcommandDeadline.clear()"
					+ "\n\t\t\t\tretireCurrentAfterFence()"
			)
		)
		XCTAssertTrue(
			source.contains(
				"private func retireCurrentAfterFence() {"
					+ "\n\t\tguard let current = inner else { return }"
					+ "\n\t\tcurrent.closeSocket()"
					+ "\n\t\tcurrent.reapAfterFenceOrTerminate()"
			)
		)
		XCTAssertTrue(
			source.contains("if commandDeadline.isExpired(at: now)")
		)
		XCTAssertTrue(
			source.contains("let deadline = uptime() + kPrivateFenceAckTimeoutSeconds")
		)
		let outerRunStart = try XCTUnwrap(
			source.range(
				of: "func run() -> Int32 {",
				range: outerStart..<source.endIndex
			)?.lowerBound
		)
		let consumeParentStart = try XCTUnwrap(
			source.range(
				of: "private func consumeParentInput()",
				range: outerRunStart..<source.endIndex
			)?.lowerBound
		)
		let outerRunSource = String(source[outerRunStart..<consumeParentStart])
		XCTAssertNil(
			outerRunSource.range(of: "heartbeatDue"),
			"the outer must never manufacture liveness after Hammerspoon disappears"
		)
		let timedPoll = try XCTUnwrap(
			outerRunSource.range(of: "let pollResult = poller(&descriptors, timeout)")?.lowerBound
		)
		let boundaryPoll = try XCTUnwrap(
			outerRunSource.range(
				of: "let boundaryPollResult = poller(&descriptors, 0)"
			)?.lowerBound
		)
		let deadlineCheck = try XCTUnwrap(
			outerRunSource.range(of: "commandDeadline.isExpired(at: now)")?.lowerBound
		)
		XCTAssertLessThan(timedPoll, boundaryPoll)
		XCTAssertLessThan(boundaryPoll, deadlineCheck)
		let executorStart = try XCTUnwrap(
			source.range(of: "final class PosixLeaseCLIExecutor")?.lowerBound
		)
		let innerRuntimeStart = try XCTUnwrap(
			source.range(of: "final class KarabinerLeaseInnerRuntime")?.lowerBound
		)
		let executorSource = String(source[executorStart..<innerRuntimeStart])
		XCTAssertTrue(executorSource.contains("POSIX_SPAWN_SETSIGDEF"))
		XCTAssertTrue(executorSource.contains("sigaddset(&defaultSignals, SIGHUP)"))
		XCTAssertTrue(innerDispatchSource.contains("Darwin.signal(SIGHUP, SIG_IGN)"))
		XCTAssertTrue(
			innerDispatchSource.contains(
				"prepareInnerControlDescriptor(kInnerControlDescriptor)"
			)
		)
	}





	// ===================================
	// ===================================
	// ======= 2/ Bounded Protocol =======
	// ===================================
	// ===================================

	/// Proves partial lines remain bounded and strict UTF-8 is mandatory.
	func testBoundedLineDecoderRejectsOversizeAndMalformedUTF8() {
		var oversized = BoundedLeaseLineDecoder()
		let longLine = Array(repeating: UInt8(0x41), count: 129)
		XCTAssertEqual(oversized.append(longLine[...]), .invalid)

		var malformed = BoundedLeaseLineDecoder()
		let invalidUTF8: [UInt8] = [0xC3, 0x28, 0x0A]
		XCTAssertEqual(malformed.append(invalidUTF8[...]), .invalid)
	}

	/// Proves one ready read cannot allocate an unbounded command queue.
	func testBoundedLineDecoderRejectsLineFlood() {
		var decoder = BoundedLeaseLineDecoder()
		let flood = Array(String(repeating: "PAUSE\n", count: 33).utf8)
		XCTAssertEqual(decoder.append(flood[...]), .invalid)

		var unterminated = BoundedLeaseLineDecoder()
		let eofFlood = Array((String(repeating: "A\n", count: 32) + "A").utf8)
		XCTAssertEqual(unterminated.append(eofFlood[...], eof: true), .invalid)
	}

	/// Proves post-read EINTR retries stay zero-delay, clear stale bits, and stop.
	func testBoundaryPollRetriesInterruptedCallsWithinFixedZeroDelayBudget() {
		var descriptor = pollfd(
			fd: -1,
			events: Int16(POLLIN | POLLHUP | POLLERR),
			revents: Int16(POLLHUP)
		)
		var attempts = 0
		var observedTimeouts: [Int32] = []
		var observedIncomingEvents: [Int16] = []
		let result = pollLeaseBoundary(
			&descriptor,
			maximumEINTRRetries: 2,
			poller: { descriptor, timeoutMilliseconds in
				attempts += 1
				observedTimeouts.append(timeoutMilliseconds)
				observedIncomingEvents.append(descriptor.revents)
				if attempts > 3 { return 0 }
				// Model a kernel/injected poll that dirtied revents before EINTR.
				descriptor.revents = Int16(POLLHUP)
				errno = EINTR
				return -1
			}
		)

		XCTAssertEqual(result, -1)
		XCTAssertEqual(attempts, 3, "two retries means three bounded attempts")
		XCTAssertEqual(observedTimeouts, [0, 0, 0])
		XCTAssertEqual(
			observedIncomingEvents,
			[0, 0, 0],
			"each retry must discard event bits from the interrupted attempt"
		)

		var permanentFailureAttempts = 0
		let permanentFailure = pollLeaseBoundary(
			&descriptor,
			maximumEINTRRetries: 10,
			poller: { _, _ in
				permanentFailureAttempts += 1
				errno = EIO
				return -1
			}
		)
		XCTAssertEqual(permanentFailure, -1)
		XCTAssertEqual(
			permanentFailureAttempts,
			1,
			"non-EINTR failures must reach the fail-closed caller without retry"
		)
	}

	/// Proves private heartbeat commands and results preserve the public sequence.
	func testPrivateHeartbeatProtocolRequiresCanonicalSequence() {
		XCTAssertEqual(
			LeaseInnerCommand.parse(line: "HEARTBEAT 2 17"),
			.heartbeat(kLeaseModePaused, 17)
		)
		XCTAssertEqual(
			LeaseInnerAcknowledgement.parse(line: "HEARTBEAT 2 17"),
			.heartbeat(kLeaseModePaused, 17)
		)
		XCTAssertEqual(
			LeaseInnerAcknowledgement.parse(line: "HEARTBEAT_FAILED 17"),
			.heartbeatFailed(17)
		)
		for malformed in ["HEARTBEAT 1", "HEARTBEAT 1 0", "HEARTBEAT 1 01"] {
			XCTAssertNil(LeaseInnerCommand.parse(line: malformed))
		}
	}

	/// Proves a command readable exactly at expiry wins the final nonblocking drain.
	func testInnerSilenceDeadlineDrainsBoundaryCommandBeforeFencing() throws {
		var sockets = [Int32](repeating: -1, count: 2)
		let socketStatus = sockets.withUnsafeMutableBufferPointer { buffer in
			Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
		}
		XCTAssertEqual(socketStatus, 0)
		guard socketStatus == 0 else { return }
		defer {
			_ = Darwin.close(sockets[0])
			_ = Darwin.close(sockets[1])
		}
		XCTAssertTrue(writeLeaseLine("ACTIVATE 1", to: sockets[0]))
		let channel = SocketLeaseInnerChannel(
			descriptor: sockets[1],
			uptime: { 0 }
		)

		XCTAssertEqual(
			channel.nextEvent(timeout: 0),
			.command(.activate(kLeaseModeActive))
		)
	}

	/// Proves healthy heartbeat traffic repeatedly renews bounded inner waits.
	func testInnerSilenceDeadlineAcceptsHealthyHeartbeatCycles() throws {
		let writer = Process()
		let output = Pipe()
		writer.executableURL = URL(fileURLWithPath: "/bin/sh")
		writer.arguments = [
			"-c",
			"sleep 0.05; printf 'HEARTBEAT 1 1\\n'; "
				+ "sleep 0.05; printf 'HEARTBEAT 1 2\\n'; "
				+ "sleep 0.05; printf 'HEARTBEAT 1 3\\n'",
		]
		writer.standardOutput = output
		try writer.run()
		defer {
			if writer.isRunning { writer.terminate() }
			writer.waitUntilExit()
		}
		let channel = SocketLeaseInnerChannel(
			descriptor: output.fileHandleForReading.fileDescriptor
		)

		for sequence in UInt32(1)...UInt32(3) {
			XCTAssertEqual(
				channel.nextEvent(timeout: 0.5),
				.command(.heartbeat(kLeaseModeActive, sequence))
			)
		}
	}





	// ============================================
	// ============================================
	// ======= 3/ EOF and STOP Phase Matrix =======
	// ============================================
	// ============================================

	/// Proves EOF before activation still performs two exact final fence writes.
	func testEOFBeforeActivationFencesWithoutReady() {
		let result = runInner(events: [.peerClosed])
		let fence = LeasePayloads.fence(identity: makeIdentity())

		XCTAssertEqual(result.exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertEqual(result.acknowledgements, [])
		XCTAssertEqual(result.payloads, [fence, fence])
	}

	/// Proves EOF during an activation child preempts and reaps it before fencing.
	func testEOFDuringActivationFencesWithoutFalseReady() {
		let result = runInner(
			events: [.command(.activate(kLeaseModeActive)), .peerClosed],
			probeCalls: [1]
		)
		let fence = LeasePayloads.fence(identity: makeIdentity())

		XCTAssertEqual(result.exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertEqual(result.acknowledgements, [])
		XCTAssertEqual(result.payloads, [
			LeasePayloads.mode(identity: makeIdentity(), mode: kLeaseModeActive),
			fence,
			fence,
		])
	}

	/// Proves EOF while idle after READY cannot leave the active mode authorized.
	func testEOFAfterReadyFencesTheGeneration() {
		let result = runInner(events: [
			.command(.activate(kLeaseModeActive)),
			.peerClosed,
		])

		XCTAssertEqual(result.acknowledgements, [.ready(kLeaseModeActive)])
		XCTAssertEqual(Array(result.payloads.suffix(2)), [
			LeasePayloads.fence(identity: makeIdentity()),
			LeasePayloads.fence(identity: makeIdentity()),
		])
	}

	/// Proves a stopped outer cannot retain an active lease after upstream HS loss.
	func testStoppedOuterWithPendingHammerspoonEOFTriggersInnerSilenceFence() throws {
		var privateSockets = [Int32](repeating: -1, count: 2)
		let socketStatus = privateSockets.withUnsafeMutableBufferPointer { buffer in
			Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
		}
		XCTAssertEqual(socketStatus, 0)
		guard socketStatus == 0 else { return }
		var hammerspoonPipe = [Int32](repeating: -1, count: 2)
		let pipeStatus = hammerspoonPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(pipeStatus, 0)
		guard pipeStatus == 0 else {
			_ = Darwin.close(privateSockets[0])
			_ = Darwin.close(privateSockets[1])
			return
		}
		let stoppedOuterPID = try spawnStoppedOuterHarness(
			privateDescriptor: privateSockets[0],
			inheritedInnerDescriptor: privateSockets[1],
			parentInputDescriptor: hammerspoonPipe[0],
			inheritedParentWriteDescriptor: hammerspoonPipe[1]
		)
		_ = Darwin.close(privateSockets[0])
		_ = Darwin.close(hammerspoonPipe[0])
		defer {
			_ = Darwin.close(privateSockets[1])
			_ = Darwin.close(hammerspoonPipe[1])
			_ = Darwin.kill(stoppedOuterPID, SIGKILL)
			var status: Int32 = 0
			while waitpid(stoppedOuterPID, &status, 0) == -1 && errno == EINTR {}
		}

		_ = Darwin.close(hammerspoonPipe[1])
		hammerspoonPipe[1] = -1
		XCTAssertTrue(isAlive(stoppedOuterPID))
		let identity = LeaseIdentity(
			cliPath: "/tmp/fake-karabiner-cli",
			token: token,
			modeName: "ergopti_mode_\(token)",
			revokedName: "ergopti_revoked_\(token)",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 0.01
		)
		let executor = ScriptedLeaseCLIExecutor(results: [], probeCalls: [])
		let runtime = KarabinerLeaseInnerRuntime(
			identity: identity,
			channel: SocketLeaseInnerChannel(descriptor: privateSockets[1]),
			executor: executor,
			cliTimeout: 0.05
		)
		var acknowledgementDeadline = LeasePrivateCommandDeadline()
		acknowledgementDeadline.arm(for: .activate(kLeaseModeActive), now: 0)
		let expectedSilence = identity.heartbeatSeconds
			+ (acknowledgementDeadline.deadline ?? 0)

		let started = ProcessInfo.processInfo.systemUptime
		let exitCode = runtime.run()
		let elapsed = ProcessInfo.processInfo.systemUptime - started

		XCTAssertEqual(exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertGreaterThanOrEqual(elapsed, expectedSilence)
		XCTAssertLessThan(elapsed, expectedSilence + 1)
		XCTAssertEqual(executor.payloads, [
			LeasePayloads.mode(identity: identity, mode: kLeaseModeActive),
			LeasePayloads.fence(identity: identity),
			LeasePayloads.fence(identity: identity),
		])
		XCTAssertTrue(
			isAlive(stoppedOuterPID),
			"the fence must result from bounded silence, not accidental outer death"
		)
	}

	/// Proves private socket HUP discards buffered live commands before execution.
	func testPrivatePeerClosureOutranksBufferedSet() throws {
		var sockets = [Int32](repeating: -1, count: 2)
		let socketStatus = sockets.withUnsafeMutableBufferPointer { buffer in
			Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
		}
		XCTAssertEqual(socketStatus, 0)
		guard socketStatus == 0 else { return }
		defer {
			if sockets[0] >= 0 { _ = Darwin.close(sockets[0]) }
			if sockets[1] >= 0 { _ = Darwin.close(sockets[1]) }
		}

		XCTAssertTrue(writeLeaseLine("SET 2", to: sockets[0]))
		_ = Darwin.close(sockets[0])
		sockets[0] = -1
		let channel = SocketLeaseInnerChannel(descriptor: sockets[1])

		XCTAssertEqual(
			channel.nextEvent(timeout: 1),
			.peerClosed,
			"buffered mode bytes cannot outrank loss of their owning outer process"
		)
	}

	/// Proves EINTR between a private read and HUP cannot publish buffered SET.
	func testPrivateBoundaryEINTRStillLetsClosureOutrankBufferedSet() throws {
		var sockets = [Int32](repeating: -1, count: 2)
		let socketStatus = sockets.withUnsafeMutableBufferPointer { buffer in
			Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
		}
		XCTAssertEqual(socketStatus, 0)
		guard socketStatus == 0 else { return }
		defer {
			if sockets[0] >= 0 { _ = Darwin.close(sockets[0]) }
			if sockets[1] >= 0 { _ = Darwin.close(sockets[1]) }
		}

		XCTAssertTrue(writeLeaseLine("SET 2", to: sockets[0]))
		_ = Darwin.close(sockets[0])
		sockets[0] = -1
		var mainPollMasked = false
		var boundaryAttempts = 0
		let channel = SocketLeaseInnerChannel(
			descriptor: sockets[1],
			poller: { descriptor, timeoutMilliseconds in
				if timeoutMilliseconds > 0 {
					let result = pollLeaseDescriptor(&descriptor, timeoutMilliseconds)
					if result > 0 && !mainPollMasked {
						// Force the exact POSIX ordering under test: bytes first,
						// terminal closure visible only at the post-read boundary.
						descriptor.revents = Int16(POLLIN)
						mainPollMasked = true
					}
					return result
				}
				boundaryAttempts += 1
				if boundaryAttempts == 1 {
					errno = EINTR
					return -1
				}
				return pollLeaseDescriptor(&descriptor, timeoutMilliseconds)
			}
		)

		XCTAssertEqual(
			channel.nextEvent(timeout: 1),
			.peerClosed,
			"EINTR cannot let buffered mode bytes outrank loss of their outer owner"
		)
		XCTAssertTrue(mainPollMasked)
		XCTAssertGreaterThanOrEqual(boundaryAttempts, 2)
	}

	/// Proves STOP or parent HUP outranks every live line buffered in that read.
	func testPublicTerminalBatchNeverForwardsBufferedPause() throws {
		for closesAfterPause in [false, true] {
			let fixture = try makeExecutableFixture(
				body: "IFS= read -r command <&3 || exit 40\n"
					+ "printf '%s\\n' \"$command\" > \"$3\"\n"
					+ "[ \"$command\" = 'ACTIVATE 1' ] || exit 41\n"
					+ "printf 'READY 1\\n' >&3\n"
					+ "IFS= read -r command <&3 || exit 42\n"
					+ "printf '%s\\n' \"$command\" >> \"$3\"\n"
					+ "if [ \"$command\" != STOP ]; then\n"
					+ "  : > \"$4\"\n"
					+ "  IFS= read -r command <&3 || exit 43\n"
					+ "  printf '%s\\n' \"$command\" >> \"$3\"\n"
					+ "fi\n"
					+ "[ \"$command\" = STOP ] || exit 44\n"
					+ "printf 'FENCED\\n' >&3\nexit 0\n"
			)
			defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
			let traceFile = fixture.deletingLastPathComponent()
				.appendingPathComponent(closesAfterPause ? "hup.trace" : "stop.trace")
			let violationFile = fixture.deletingLastPathComponent()
				.appendingPathComponent(closesAfterPause ? "hup.violation" : "stop.violation")
			var parentPipe = [Int32](repeating: -1, count: 2)
			let pipeStatus = parentPipe.withUnsafeMutableBufferPointer { buffer in
				Darwin.pipe(buffer.baseAddress!)
			}
			XCTAssertEqual(pipeStatus, 0)
			guard pipeStatus == 0 else { continue }
			let nullDescriptor = Darwin.open("/dev/null", O_WRONLY)
			XCTAssertGreaterThanOrEqual(nullDescriptor, 0)
			guard nullDescriptor >= 0 else {
				_ = Darwin.close(parentPipe[0])
				_ = Darwin.close(parentPipe[1])
				continue
			}
			defer {
				_ = Darwin.close(parentPipe[0])
				if parentPipe[1] >= 0 { _ = Darwin.close(parentPipe[1]) }
				_ = Darwin.close(nullDescriptor)
			}
			let identity = LeaseIdentity(
				cliPath: "/unused/karabiner_cli",
				token: token,
				modeName: traceFile.path,
				revokedName: violationFile.path,
				initialMode: kLeaseModeActive,
				heartbeatSeconds: 5
			)
			var clockReads = 0
			let runtime = KarabinerLeaseOuterRuntime(
				identity: identity,
				detached: false,
				spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
				parentInputDescriptor: parentPipe[0],
				parentOutputDescriptor: nullDescriptor,
				uptime: {
					clockReads += 1
					if clockReads == 3 {
						XCTAssertTrue(writeLeaseLine("PAUSE", to: parentPipe[1]))
						if closesAfterPause {
							_ = Darwin.close(parentPipe[1])
							parentPipe[1] = -1
						} else {
							XCTAssertTrue(writeLeaseLine("STOP", to: parentPipe[1]))
						}
					}
					return 0
				}
			)

			XCTAssertEqual(runtime.run(), LeaseWorkerExit.success.rawValue)
			let trace = try String(contentsOf: traceFile, encoding: .utf8)
			XCTAssertTrue(trace.contains("ACTIVATE 1\n"))
			XCTAssertTrue(trace.contains("STOP\n"))
			XCTAssertFalse(trace.contains("SET "))
			XCTAssertFalse(trace.contains("HEARTBEAT "))
			XCTAssertFalse(
				FileManager.default.fileExists(atPath: violationFile.path),
				"terminal public ownership loss must be the next private command"
			)
		}
	}

	/// Proves a fast inner exit cannot publish its buffered READY as live state.
	func testInnerHUPOutranksBufferedReadyAcknowledgement() throws {
		let fixture = try makeExecutableFixture(
			body: "if [ ! -f \"$3\" ]; then\n"
				+ "  : > \"$3\"\n"
				+ "  IFS= read -r command <&3 || exit 40\n"
				+ "  [ \"$command\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "  printf 'READY 1\\n' >&3\n"
				+ "  exit 0\n"
				+ "fi\n"
				+ "IFS= read -r command <&3 || exit 42\n"
				+ "[ \"$command\" = STOP ] || exit 43\n"
				+ "printf 'FENCED\\n' >&3\nexit 0\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let firstInnerMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-ready-inner.marker")
		let publicOutput = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-ready-public.log")
		try Data().write(to: publicOutput)
		let outputDescriptor = Darwin.open(publicOutput.path, O_WRONLY | O_APPEND)
		XCTAssertGreaterThanOrEqual(outputDescriptor, 0)
		guard outputDescriptor >= 0 else { return }
		var parentPipe = [Int32](repeating: -1, count: 2)
		let pipeStatus = parentPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(pipeStatus, 0)
		guard pipeStatus == 0 else {
			_ = Darwin.close(outputDescriptor)
			return
		}
		defer {
			_ = Darwin.close(parentPipe[0])
			_ = Darwin.close(parentPipe[1])
			_ = Darwin.close(outputDescriptor)
		}
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: firstInnerMarker.path,
			revokedName: "unused",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: outputDescriptor
		)

		XCTAssertEqual(runtime.run(), LeaseWorkerExit.innerFailed.rawValue)
		let output = try String(contentsOf: publicOutput, encoding: .utf8)
		XCTAssertFalse(
			output.contains("READY"),
			"a live acknowledgement from a terminal private batch must be discarded"
		)
	}

	/// Preserves a stable failure when EINTR lands between its line and inner HUP.
	func testInnerBoundaryEINTRPreservesSingleBufferedFailureDiagnostic() throws {
		let fixture = try makeExecutableFixture(
			body: "if [ ! -f \"$3\" ]; then\n"
				+ "  : > \"$3\"\n"
				+ "  IFS= read -r command <&3 || exit 40\n"
				+ "  [ \"$command\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "  printf 'FAILED 70\\n' >&3\n"
				+ "  exit 70\n"
				+ "fi\n"
				+ "IFS= read -r command <&3 || exit 42\n"
				+ "[ \"$command\" = STOP ] || exit 43\n"
				+ ": > \"$4\"\n"
				+ "printf 'FENCED\\n' >&3\nexit 0\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let firstInnerMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-failed-inner.marker")
		let replacementFenceMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-failed-replacement-fence.marker")
		let publicOutput = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-failed-public.log")
		try Data().write(to: publicOutput)
		let outputDescriptor = Darwin.open(publicOutput.path, O_WRONLY | O_APPEND)
		XCTAssertGreaterThanOrEqual(outputDescriptor, 0)
		guard outputDescriptor >= 0 else { return }
		var parentPipe = [Int32](repeating: -1, count: 2)
		let pipeStatus = parentPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(pipeStatus, 0)
		guard pipeStatus == 0 else {
			_ = Darwin.close(outputDescriptor)
			return
		}
		defer {
			_ = Darwin.close(parentPipe[0])
			_ = Darwin.close(parentPipe[1])
			_ = Darwin.close(outputDescriptor)
		}
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: firstInnerMarker.path,
			revokedName: replacementFenceMarker.path,
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		var mainPollMasked = false
		var boundaryAttempts = 0
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: outputDescriptor,
			poller: { descriptors, timeoutMilliseconds in
				let result = descriptors.withUnsafeMutableBufferPointer { buffer in
					Darwin.poll(
						buffer.baseAddress!,
						nfds_t(buffer.count),
						timeoutMilliseconds
					)
				}
				if result > 0 && !mainPollMasked && descriptors.count > 1
					&& descriptors[1].revents != 0 {
					// Force read-before-HUP so the injected EINTR reaches the
					// post-read boundary instead of the terminal main-poll branch.
					descriptors[1].revents = Int16(POLLIN)
					mainPollMasked = true
				}
				return result
			},
			boundaryPoller: { descriptor, timeoutMilliseconds in
				XCTAssertEqual(timeoutMilliseconds, 0)
				boundaryAttempts += 1
				if boundaryAttempts == 1 {
					errno = EINTR
					return -1
				}
				return pollLeaseDescriptor(&descriptor, timeoutMilliseconds)
			}
		)

		XCTAssertEqual(runtime.run(), LeaseWorkerExit.activationFailed.rawValue)
		XCTAssertTrue(mainPollMasked)
		XCTAssertGreaterThanOrEqual(
			boundaryAttempts,
			2,
			"the FAILED diagnostic must survive one interrupted boundary poll"
		)
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: replacementFenceMarker.path),
			"preserving the diagnostic must not skip replacement exact-generation fencing"
		)
		let output = try String(contentsOf: publicOutput, encoding: .utf8)
		XCTAssertFalse(output.contains("READY"))
	}

	/// Proves EOF makes STOP final even when a public PING was already accepted.
	func testParentEOFAfterPublicPingOutranksItsLatePong() {
		var machine = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
		_ = machine.start()
		_ = machine.receiveInner(.ready(kLeaseModeActive))
		XCTAssertEqual(machine.receiveParent(line: "PING 1"), [
			.send(.heartbeat(kLeaseModeActive, 1)),
		])

		XCTAssertEqual(machine.receiveParentEOF(), [.send(.stop)])
		XCTAssertEqual(
			machine.receiveInner(.heartbeat(kLeaseModeActive, 1)),
			[],
			"a late clean heartbeat transport cannot publish PONG after parent EOF"
		)
		XCTAssertEqual(machine.receiveInner(.fenced), [
			.finish(LeaseWorkerExit.success.rawValue),
		])
	}

	/// Proves an explicit STOP makes a batched in-flight PING and late PONG inert.
	func testPublicStopAfterPingOutranksItsLatePong() {
		var machine = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
		_ = machine.start()
		_ = machine.receiveInner(.ready(kLeaseModeActive))
		XCTAssertEqual(machine.receiveParent(line: "PING 1"), [
			.send(.heartbeat(kLeaseModeActive, 1)),
		])

		XCTAssertEqual(machine.receiveParent(line: "STOP"), [.send(.stop)])
		XCTAssertEqual(machine.receiveInner(.heartbeat(kLeaseModeActive, 1)), [])
		XCTAssertEqual(machine.receiveInner(.fenced), [
			.publish("STOPPED"),
			.finish(LeaseWorkerExit.success.rawValue),
		])
	}

	/// Proves an ACK already pending in the kernel clears its expired command first.
	func testPendingInnerAcknowledgementOutranksCommandDeadline() throws {
		let fixture = try makeExecutableFixture(
			body: "IFS= read -r command <&3 || exit 40\n"
				+ "if [ \"$command\" = STOP ]; then\n"
				+ "  printf 'FENCED\\n' >&3\n  exit 0\nfi\n"
				+ "[ \"$command\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "printf 'READY 1\\n' >&3\n: > \"$3\"\n"
				+ "IFS= read -r command <&3 || exit 42\n"
				+ "[ \"$command\" = STOP ] || exit 43\nprintf 'FENCED\\n' >&3\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let acknowledgementMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("ready-in-kernel")
		var parentPipe = [Int32](repeating: -1, count: 2)
		let pipeStatus = parentPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(pipeStatus, 0)
		guard pipeStatus == 0 else { return }
		let nullDescriptor = Darwin.open("/dev/null", O_WRONLY)
		XCTAssertGreaterThanOrEqual(nullDescriptor, 0)
		guard nullDescriptor >= 0 else { return }
		defer {
			_ = Darwin.close(parentPipe[0])
			_ = Darwin.close(parentPipe[1])
			_ = Darwin.close(nullDescriptor)
		}
		var activationDeadline = LeasePrivateCommandDeadline()
		activationDeadline.arm(for: .activate(kLeaseModeActive), now: 0)
		let boundaryTime = try XCTUnwrap(activationDeadline.deadline)
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: acknowledgementMarker.path,
			revokedName: "unused",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		var clockReads = 0
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: nullDescriptor,
			uptime: {
				clockReads += 1
				if clockReads == 3 {
					_ = self.waitForFile(at: acknowledgementMarker, timeout: 2)
				}
				if clockReads >= 5, parentPipe[1] >= 0 {
					_ = Darwin.close(parentPipe[1])
					parentPipe[1] = -1
				}
				return clockReads >= 3 ? boundaryTime : 0
			}
		)

		let exitCode = runtime.run()

		XCTAssertEqual(exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertGreaterThanOrEqual(clockReads, 5)
	}

	/// Proves EOF preempts an in-flight pause before any PAUSED acknowledgement.
	func testEOFDuringPauseFencesWithoutFalsePausedAck() {
		let result = runInner(
			events: [
				.command(.activate(kLeaseModeActive)),
				.command(.setMode(kLeaseModePaused)),
				.peerClosed,
			],
			probeCalls: [2]
		)

		XCTAssertEqual(result.acknowledgements, [.ready(kLeaseModeActive)])
		XCTAssertFalse(result.acknowledgements.contains(.transported(kLeaseModePaused)))
		XCTAssertEqual(Array(result.payloads.suffix(2)), [
			LeasePayloads.fence(identity: makeIdentity()),
			LeasePayloads.fence(identity: makeIdentity()),
		])
	}

	/// Proves EOF preempts an in-flight heartbeat before exact revocation.
	func testEOFDuringHeartbeatFencesWithoutHeartbeatAck() {
		let result = runInner(
			events: [
				.command(.activate(kLeaseModeActive)),
				.command(.heartbeat(kLeaseModeActive, 1)),
				.peerClosed,
			],
			probeCalls: [2]
		)

		XCTAssertEqual(result.acknowledgements, [.ready(kLeaseModeActive)])
		XCTAssertFalse(result.acknowledgements.contains(.heartbeat(kLeaseModeActive, 1)))
		XCTAssertEqual(Array(result.payloads.suffix(2)), [
			LeasePayloads.fence(identity: makeIdentity()),
			LeasePayloads.fence(identity: makeIdentity()),
		])
	}

	/// Proves a cleanup failure resets both the success count and monotonic grace.
	func testEOFDuringFenceRetriesUntilTwoConsecutiveFinalWrites() {
		let result = runInner(
			events: [.peerClosed],
			results: [.success, .failed(90), .success, .success]
		)
		let fence = LeasePayloads.fence(identity: makeIdentity())

		XCTAssertEqual(result.exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertEqual(result.payloads, [fence, fence, fence, fence])
		XCTAssertGreaterThanOrEqual(
			result.executionTimes[3] - result.executionTimes[2],
			0.25,
			"the post-failure confirmation must start a fresh monotonic grace"
		)
	}

	/// Proves STOP outranks a blocked activation and publishes only FENCED.
	func testStopDuringActivationPreemptsBeforeFence() {
		let result = runInner(
			events: [.command(.activate(kLeaseModeActive)), .command(.stop)],
			probeCalls: [1]
		)

		XCTAssertEqual(result.exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertEqual(result.acknowledgements, [.fenced])
		XCTAssertFalse(result.acknowledgements.contains(.ready(kLeaseModeActive)))
		XCTAssertEqual(result.maximumConcurrentChildren, 1)
	}





	// =============================================
	// =============================================
	// ======= 4/ Serialization and Failures =======
	// =============================================
	// =============================================

	/// Proves rapid pause/resume commands remain serialized and latest-wins safe.
	func testRapidPauseResumeNeverOverlapsCLIChildren() {
		let result = runInner(events: [
			.command(.activate(kLeaseModeActive)),
			.command(.setMode(kLeaseModePaused)),
			.command(.setMode(kLeaseModeActive)),
			.command(.stop),
		])

		XCTAssertEqual(result.exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertEqual(result.maximumConcurrentChildren, 1)
		XCTAssertEqual(result.acknowledgements, [
			.ready(kLeaseModeActive),
			.transported(kLeaseModePaused),
			.transported(kLeaseModeActive),
			.fenced,
		])
		XCTAssertEqual(result.payloads, [
			LeasePayloads.mode(identity: makeIdentity(), mode: kLeaseModeActive),
			LeasePayloads.mode(identity: makeIdentity(), mode: kLeaseModePaused),
			LeasePayloads.mode(identity: makeIdentity(), mode: kLeaseModeActive),
			LeasePayloads.fence(identity: makeIdentity()),
			LeasePayloads.fence(identity: makeIdentity()),
		])
	}

	/// Proves a timed-out activation is joined before any failure ACK or fence.
	func testChildTimeoutFencesAndNeverPublishesReady() {
		let result = runInner(
			events: [.command(.activate(kLeaseModeActive))],
			results: [.timedOut, .success, .success]
		)

		XCTAssertEqual(result.exitCode, LeaseWorkerExit.activationFailed.rawValue)
		XCTAssertEqual(
			result.acknowledgements,
			[.failed(LeaseWorkerExit.activationFailed.rawValue)]
		)
		XCTAssertFalse(result.acknowledgements.contains(.ready(kLeaseModeActive)))
		XCTAssertEqual(result.maximumConcurrentChildren, 1)
	}

	/// Proves a live socket cannot suppress bounded command and fence deadlines.
	func testPrivateCommandDeadlinesExpireBeforePublicReadyBudget() {
		let now: TimeInterval = 100
		for command in [
			LeaseInnerCommand.activate(kLeaseModeActive),
			.setMode(kLeaseModePaused),
			.heartbeat(kLeaseModeActive, 1),
		] {
			var deadline = LeasePrivateCommandDeadline()
			deadline.arm(for: command, now: now)
			XCTAssertEqual(deadline.deadline, 101.75)
			XCTAssertFalse(deadline.isExpired(at: 101.749))
			XCTAssertTrue(deadline.isExpired(at: 101.75))
		}

		var fenceDeadline = LeasePrivateCommandDeadline()
		fenceDeadline.arm(for: .stop, now: now)
		XCTAssertEqual(fenceDeadline.deadline, 103.75)
		XCTAssertGreaterThanOrEqual((fenceDeadline.deadline ?? now) - now, 3)
		XCTAssertLessThan((fenceDeadline.deadline ?? now) - now, 4)
		XCTAssertTrue(fenceDeadline.isExpired(at: 103.75))
	}

	/// Proves the outer state machine requests a replacement fence on inner loss.
	func testInnerLossRequiresReplacementFenceBeforeFinish() {
		var machine = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
		XCTAssertEqual(machine.start(), [.send(.activate(kLeaseModeActive))])
		XCTAssertEqual(
			machine.receiveInner(.ready(kLeaseModeActive)),
			[.publish("READY")]
		)

		XCTAssertEqual(
			machine.innerLost(),
			[.fenceAndFinish(LeaseWorkerExit.innerFailed.rawValue, false)]
		)
	}

	/// Proves a replaced launcher path cannot strand a READY generation forever.
	func testAuthenticatedOuterFencesDirectlyWhenReplacementSpawnerStaysUnavailable() throws {
		let fixture = try makeExecutableFixture(
			body: "IFS= read -r activate <&3 || exit 40\n"
				+ "[ \"$activate\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "printf 'READY 1\\n' >&3\n"
				+ "IFS= read -r heartbeat <&3 || exit 42\n"
				+ "[ \"$heartbeat\" = 'HEARTBEAT 1 1' ] || exit 43\n"
				+ "exit 73\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		var parentPipe = [Int32](repeating: -1, count: 2)
		let parentPipeStatus = parentPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(parentPipeStatus, 0)
		guard parentPipeStatus == 0 else { return }
		var outputPipe = [Int32](repeating: -1, count: 2)
		let outputPipeStatus = outputPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(outputPipeStatus, 0)
		guard outputPipeStatus == 0 else {
			_ = Darwin.close(parentPipe[0])
			_ = Darwin.close(parentPipe[1])
			return
		}
		defer {
			_ = Darwin.close(parentPipe[0])
			_ = Darwin.close(parentPipe[1])
			_ = Darwin.close(outputPipe[0])
			_ = Darwin.close(outputPipe[1])
		}
		let identity = LeaseIdentity(
			cliPath: kCanonicalKarabinerCLIPath,
			token: token,
			modeName: "ergopti_mode_\(token)",
			revokedName: "ergopti_revoked_\(token)",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let unavailableSpawner = InitialThenUnavailableLeaseInnerSpawner(
			initialSpawner: PosixLeaseInnerSpawner(executablePath: fixture.path)
		)
		let recoveryExecutor = ScriptedLeaseCLIExecutor(results: [], probeCalls: [])
		let sibling = try startUnrelatedSibling()
		defer { stopTestOwnedSibling(sibling) }
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: unavailableSpawner,
			recoveryExecutor: recoveryExecutor,
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: outputPipe[1]
		)
		let finished = DispatchSemaphore(value: 0)
		var exitCode: Int32?
		DispatchQueue.global(qos: .userInitiated).async {
			exitCode = runtime.run()
			finished.signal()
		}

		var readyPoll = pollfd(
			fd: outputPipe[0],
			events: Int16(POLLIN | POLLHUP | POLLERR),
			revents: 0
		)
		let readyPollResult = Darwin.poll(&readyPoll, 1, 2_000)
		XCTAssertGreaterThan(
			readyPollResult,
			0,
			"the initial authenticated inner must publish READY"
		)
		guard readyPollResult > 0 else {
			_ = Darwin.close(parentPipe[1])
			parentPipe[1] = -1
			_ = finished.wait(timeout: .now() + 5)
			return
		}
		var outputDecoder = BoundedLeaseLineDecoder()
		switch readLeaseLines(from: outputPipe[0], decoder: &outputDecoder) {
		case .lines(let lines), .eof(let lines):
			XCTAssertEqual(lines, ["READY"])
		case .invalid, .retry:
			XCTFail("the initial authenticated inner must publish canonical READY")
		}
		XCTAssertTrue(writeLeaseLine("PING 1", to: parentPipe[1]))
		let finishResult = finished.wait(timeout: .now() + 5)
		XCTAssertEqual(
			finishResult,
			.success,
			"an unavailable replacement launcher must fall back instead of looping"
		)
		guard finishResult == .success else { return }

		let exactFence = LeasePayloads.fence(identity: identity)
		XCTAssertEqual(exitCode, LeaseWorkerExit.innerFailed.rawValue)
		XCTAssertEqual(
			unavailableSpawner.spawnAttempts,
			2,
			"one initial inner plus one unavailable replacement must be sufficient"
		)
		XCTAssertEqual(recoveryExecutor.payloads, [exactFence, exactFence])
		XCTAssertEqual(
			recoveryExecutor.cliPaths,
			[kCanonicalKarabinerCLIPath, kCanonicalKarabinerCLIPath],
			"outer recovery may execute only the canonical karabiner_cli"
		)
		assertSiblingStillExecuting(
			sibling,
			"the simulated stock Karabiner sibling must never be signalled"
		)
	}

	/// Proves an accepted STOP still reports success if the first inner is killed.
	func testInnerLossDuringStopJoinsReplacementFenceBeforeStoppedAck() {
		var machine = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
		_ = machine.start()
		_ = machine.receiveInner(.ready(kLeaseModeActive))
		XCTAssertEqual(machine.receiveParent(line: "STOP"), [.send(.stop)])

		XCTAssertEqual(
			machine.innerLost(),
			[.fenceAndFinish(LeaseWorkerExit.success.rawValue, true)]
		)
	}

	/// Proves rapid public mode changes never start a second inner command early.
	func testOuterCoalescesRapidPauseResumeBehindOneInFlightWrite() {
		var machine = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
		_ = machine.start()
		_ = machine.receiveInner(.ready(kLeaseModeActive))
		XCTAssertEqual(machine.receiveParent(line: "PAUSE"), [
			.send(.setMode(kLeaseModePaused)),
		])
		XCTAssertEqual(machine.receiveParent(line: "RESUME"), [])

		XCTAssertEqual(machine.receiveInner(.transported(kLeaseModePaused)), [
			.publish("PAUSED"),
			.send(.setMode(kLeaseModeActive)),
		])
	}

	/// Proves only an HS PING creates a heartbeat and its exact sequence gates PONG.
	func testOuterSerializesPublicPingAndQueuedModeByExactSequence() {
		var machine = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
		_ = machine.start()
		_ = machine.receiveInner(.ready(kLeaseModeActive))

		XCTAssertEqual(machine.receiveParent(line: "PING 7"), [
			.send(.heartbeat(kLeaseModeActive, 7)),
		])
		XCTAssertEqual(machine.receiveParent(line: "PAUSE"), [])
		XCTAssertEqual(machine.receiveInner(.heartbeat(kLeaseModeActive, 7)), [
			.publish("PONG 7"),
			.send(.setMode(kLeaseModePaused)),
		])
	}

	/// Proves a failed local transport is sequenced and never mislabeled PONG.
	func testOuterPublishesSequencedPingFailureWithoutInventingAcknowledgement() {
		var machine = LeaseOuterStateMachine(initialMode: kLeaseModePaused)
		_ = machine.start()
		_ = machine.receiveInner(.ready(kLeaseModePaused))
		_ = machine.receiveParent(line: "PING 9")

		XCTAssertEqual(machine.receiveInner(.heartbeatFailed(9)), [
			.publish("PING_FAILED 9"),
		])
	}

	/// Proves stale, duplicated, or noncanonical heartbeat sequences fail closed.
	func testOuterRejectsEveryNonExactPingSequence() {
		for line in ["PING 0", "PING 01", "PING -1", "PING 4294967296", "PING 1 2"] {
			var machine = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
			_ = machine.start()
			_ = machine.receiveInner(.ready(kLeaseModeActive))
			XCTAssertEqual(
				machine.receiveParent(line: line),
				[.send(.stop)],
				"\(line) must enter exact revocation instead of local heartbeat"
			)
		}

		var stale = LeaseOuterStateMachine(initialMode: kLeaseModeActive)
		_ = stale.start()
		_ = stale.receiveInner(.ready(kLeaseModeActive))
		_ = stale.receiveParent(line: "PING 3")
		XCTAssertEqual(
			stale.receiveInner(.heartbeat(kLeaseModeActive, 4)),
			[.fenceAndFinish(LeaseWorkerExit.innerFailed.rawValue, false)]
		)
	}





	// =======================================
	// =======================================
	// ======= 5/ Tombstone Absorption =======
	// =======================================
	// =======================================

	/// Proves an orphaned pre-fence writer cannot reactivate a revoked generation.
	func testLateOrphanModeWriteIsAbsorbedByMonotoneTombstone() {
		var state = KarabinerGenerationModel()
		state.apply(mode: kLeaseModeActive)
		XCTAssertTrue(state.isEffective)

		state.applyFence()
		state.apply(mode: kLeaseModeActive)

		XCTAssertEqual(state.mode, kLeaseModeActive)
		XCTAssertEqual(state.revoked, 1)
		XCTAssertFalse(
			state.isEffective,
			"a CLI orphaned by inner SIGKILL may write mode late but can never clear revoked=1"
		)
	}

	/// Proves group confinement, not a volatile tombstone alone, survives Core reset.
	func testOwnedGroupConfinementPreventsLateOrphanAfterCoreReset() {
		var unconfined = KarabinerGenerationModel()
		unconfined.stageOrphan(mode: kLeaseModeActive)
		unconfined.applyFence()
		unconfined.resetCoreVariables()
		unconfined.resumeOrphan()
		XCTAssertTrue(
			unconfined.isEffective,
			"the counterfactual proves a Core reset clears the tombstone before a late write"
		)

		var confined = KarabinerGenerationModel()
		confined.stageOrphan(mode: kLeaseModeActive)
		confined.terminateOwnedWriterGroup()
		confined.applyFence()
		confined.resetCoreVariables()
		confined.resumeOrphan()

		XCTAssertEqual(confined.mode, kLeaseModeOff)
		XCTAssertEqual(confined.revoked, 0)
		XCTAssertFalse(
			confined.isEffective,
			"group termination must remove the writer before replacement fence and reset"
		)
	}





	// ===========================================
	// ===========================================
	// ======= 6/ Real POSIX PID Isolation =======
	// ===========================================
	// ===========================================

	/// Proves the sibling witness rejects a PID that exists but executes nothing.
	func testSiblingProgressWitnessRejectsStoppedExistingProcess() throws {
		let sibling = try startUnrelatedSibling()
		defer { stopTestOwnedSibling(sibling) }
		let processID = sibling.process.processIdentifier

		XCTAssertEqual(Darwin.kill(processID, SIGSTOP), 0)
		XCTAssertTrue(waitUntilStopped(processID, timeout: 2))
		let stoppedSize = siblingProgressSize(sibling)
		XCTAssertTrue(
			isAlive(processID),
			"the counterfactual PID-existence probe must accept a stopped process"
		)
		XCTAssertFalse(
			waitForSiblingProgress(
				sibling,
				after: stoppedSize,
				timeout: kStoppedSiblingObservationSeconds
			),
			"a stopped or zombie sibling must not satisfy the execution witness"
		)
	}

	/// Proves the CLI cannot inherit inner's HUP ignore during group orphaning.
	func testCLIChildResetsInheritedHUPToDefault() throws {
		let fixture = try makeExecutableFixture(body: "kill -HUP $$\nexit 42\n")
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let previousDisposition = Darwin.signal(SIGHUP, SIG_IGN)
		defer { _ = Darwin.signal(SIGHUP, previousDisposition) }

		let result = PosixLeaseCLIExecutor().execute(
			cliPath: fixture.path,
			payload: "{}",
			timeout: 1,
			interruption: { .none }
		)

		XCTAssertEqual(result, .failed(128 + Int32(SIGHUP)))
	}

	/// Proves killed-inner recovery removes its orphan without touching siblings.
	func testKilledInnerGroupReapsOrphanAndPreservesSharedProcessSiblings() throws {
		let fixture = try makeExecutableFixture(
			body: "/bin/sh -c 'trap \"\" HUP TERM; : > \"$1\"; "
				+ "while :; do /bin/sleep 1; done' lease-child \"$4\" 3>&- &\n"
				+ "echo \"$!\" > \"$3\"\nwait\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let childPIDFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("orphan-child.pid")
		let childReadyFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("orphan-child.ready")
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: childPIDFile.path,
			revokedName: childReadyFile.path,
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let spawned = try XCTUnwrap(
			PosixLeaseInnerSpawner(executablePath: fixture.path).spawn(identity: identity)
		)
		var sharedSiblings: [(String, ProgressingTestSibling)] = []
		defer {
			spawned.closeSocket()
			spawned.terminateOwnedProcessGroupAndReap()
			for (_, sibling) in sharedSiblings { stopTestOwnedSibling(sibling) }
		}
		for family in [
			"Karabiner-Elements UI",
			"Karabiner-Core-Service",
			"karabiner_console_user_server",
			"VirtualHIDDevice",
		] {
			sharedSiblings.append((family, try startUnrelatedSibling()))
		}

		let orphanPID = try XCTUnwrap(waitForPID(in: childPIDFile, timeout: 2))
		XCTAssertTrue(
			waitForFile(at: childReadyFile, timeout: 2),
			"the descendant must install HUP/TERM ignores before orphaning"
		)
		XCTAssertEqual(Darwin.getpgid(spawned.processID), spawned.processGroupID)
		XCTAssertEqual(spawned.processGroupID, spawned.processID)
		XCTAssertEqual(Darwin.getpgid(orphanPID), spawned.processGroupID)
		XCTAssertEqual(Darwin.kill(orphanPID, SIGSTOP), 0)
		XCTAssertEqual(Darwin.kill(spawned.processID, SIGKILL), 0)
		XCTAssertTrue(isAlive(orphanPID))
		switch spawned.readLines() {
		case .eof(_):
			break
		default:
			XCTFail("inner loss must close the private socket before group recovery")
		}

		spawned.closeSocket()
		spawned.terminateOwnedProcessGroupAndReap()

		XCTAssertTrue(
			waitUntilGone(orphanPID, timeout: 2),
			"the private-group kill must remove the CLI orphan before replacement fence"
		)
		for (family, sibling) in sharedSiblings {
			assertSiblingStillExecuting(
				sibling,
				"the unrelated shared-family simulation \(family) must survive"
			)
		}
	}

	/// Proves FENCED cannot turn the following waitpid into an unbounded hang.
	func testFencedThenStoppedInnerIsKilledAndReapedWithinBound() throws {
		let fixture = try makeExecutableFixture(
			body: "IFS= read -r command <&3 || exit 40\n"
				+ "[ \"$command\" = STOP ] || exit 41\n"
				+ "/bin/sh -c 'trap \"\" HUP TERM; : > \"$1\"; "
				+ "while :; do /bin/sleep 1; done' lease-child \"$3\" 3>&- &\n"
				+ "echo \"$!\" > \"${3}.pid\"\n"
				+ "while [ ! -f \"$3\" ]; do /bin/sleep 0.01; done\n"
				+ "printf 'FENCED\\n' >&3\nkill -STOP $$\nwait\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let readyFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("fenced-inner.ready")
		let childPIDFile = URL(fileURLWithPath: readyFile.path + ".pid")
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: readyFile.path,
			revokedName: "unused",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let spawned = try XCTUnwrap(
			PosixLeaseInnerSpawner(executablePath: fixture.path).spawn(identity: identity)
		)
		let sibling = try startUnrelatedSibling()
		defer {
			spawned.closeSocket()
			spawned.terminateOwnedProcessGroupAndReap()
			stopTestOwnedSibling(sibling)
		}
		XCTAssertTrue(spawned.send(.stop))
		var socketPoll = pollfd(
			fd: spawned.descriptor,
			events: Int16(POLLIN | POLLHUP | POLLERR),
			revents: 0
		)
		XCTAssertGreaterThan(Darwin.poll(&socketPoll, 1, 2_000), 0)
		switch spawned.readLines() {
		case .lines(let lines), .eof(let lines):
			XCTAssertEqual(lines, ["FENCED"])
		case .invalid, .retry:
			XCTFail("the stopped fixture must publish FENCED before suspending")
		}
		let descendantPID = try XCTUnwrap(waitForPID(in: childPIDFile, timeout: 2))
		XCTAssertTrue(waitUntilStopped(spawned.processID, timeout: 2))
		let watchdog = DispatchSource.makeTimerSource(
			queue: DispatchQueue.global(qos: .userInitiated)
		)
		watchdog.schedule(deadline: .now() + 1)
		watchdog.setEventHandler {
			_ = Darwin.killpg(spawned.processGroupID, SIGKILL)
		}
		watchdog.resume()

		spawned.closeSocket()
		let started = ProcessInfo.processInfo.systemUptime
		spawned.reapAfterFenceOrTerminate()
		let elapsed = ProcessInfo.processInfo.systemUptime - started
		watchdog.cancel()

		XCTAssertLessThan(elapsed, 0.5)
		XCTAssertTrue(spawned.reaped)
		XCTAssertTrue(waitUntilGone(descendantPID, timeout: 2))
		assertSiblingStillExecuting(
			sibling,
			"the unrelated sibling must execute after fenced-group retirement"
		)
	}

	/// Proves a fast FENCED leader cannot be reaped ahead of its private descendant.
	func testFencedThenExitedInnerRetiresDescendantsBeforeReap() throws {
		let fixture = try makeExecutableFixture(
			body: "IFS= read -r command <&3 || exit 40\n"
				+ "[ \"$command\" = STOP ] || exit 41\n"
				+ "/bin/sh -c 'trap \"\" HUP TERM; : > \"$1\"; "
				+ "while :; do /bin/sleep 1; done' lease-child \"$4\" 3>&- &\n"
				+ "echo \"$!\" > \"$3\"\n"
				+ "while [ ! -f \"$4\" ]; do /bin/sleep 0.01; done\n"
				+ "printf 'FENCED\\n' >&3\nexit 0\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let childPIDFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-fenced-child.pid")
		let childReadyFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-fenced-child.ready")
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: childPIDFile.path,
			revokedName: childReadyFile.path,
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let spawned = try XCTUnwrap(
			PosixLeaseInnerSpawner(executablePath: fixture.path).spawn(identity: identity)
		)
		let sibling = try startUnrelatedSibling()
		defer {
			spawned.closeSocket()
			spawned.terminateOwnedProcessGroupAndReap()
			stopTestOwnedSibling(sibling)
		}

		XCTAssertTrue(spawned.send(.stop))
		var socketPoll = pollfd(
			fd: spawned.descriptor,
			events: Int16(POLLIN | POLLHUP | POLLERR),
			revents: 0
		)
		XCTAssertGreaterThan(Darwin.poll(&socketPoll, 1, 2_000), 0)
		switch spawned.readLines() {
		case .lines(let lines), .eof(let lines):
			XCTAssertEqual(lines, ["FENCED"])
		case .invalid, .retry:
			XCTFail("the fast-exiting fixture must publish FENCED")
		}
		let descendantPID = try XCTUnwrap(waitForPID(in: childPIDFile, timeout: 2))
		XCTAssertTrue(waitForFile(at: childReadyFile, timeout: 2))

		spawned.closeSocket()
		spawned.reapAfterFenceOrTerminate()

		XCTAssertTrue(spawned.reaped)
		XCTAssertTrue(
			waitUntilGone(descendantPID, timeout: 2),
			"a FENCED leader must retain its PID/PGID until every private descendant is gone"
		)
		assertSiblingStillExecuting(
			sibling,
			"fast fenced-group retirement must not signal an unrelated process"
		)
	}

	/// Proves the real outer deadline retires a stopped group before replacement fence.
	func testOuterRuntimeDeadlineKillsStoppedInnerGroupBeforeReplacementFence() throws {
		let fixture = try makeExecutableFixture(
			body: "if [ -f \"$3\" ]; then\n"
				+ "  IFS= read -r command <&3 || exit 40\n"
				+ "  [ \"$command\" = STOP ] || exit 41\n"
				+ "  if kill -0 \"$(cat \"$3\")\" 2>/dev/null; then\n"
				+ "    : > \"${4}.order-violation\"\n  fi\n"
				+ "  : > \"$4\"\n  printf 'FENCED\\n' >&3\n  exit 0\nfi\n"
				+ "/bin/sh -c 'trap \"\" HUP TERM; : > \"$1\"; "
				+ "while :; do /bin/sleep 1; done' lease-child \"${4}.ready\" 3>&- &\n"
				+ "echo \"$!\" > \"${3}.child\"\necho \"$$\" > \"$3\"\nwait\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let childPIDFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("stopped-inner.pid")
		let descendantPIDFile = URL(fileURLWithPath: childPIDFile.path + ".child")
		let replacementFenceFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("replacement-fenced")
		let childReadyFile = URL(fileURLWithPath: replacementFenceFile.path + ".ready")
		let orderViolationFile = URL(
			fileURLWithPath: replacementFenceFile.path + ".order-violation"
		)
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: childPIDFile.path,
			revokedName: replacementFenceFile.path,
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		var parentPipe = [Int32](repeating: -1, count: 2)
		let pipeStatus = parentPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		XCTAssertEqual(pipeStatus, 0)
		guard pipeStatus == 0 else { return }
		let nullDescriptor = Darwin.open("/dev/null", O_WRONLY)
		XCTAssertGreaterThanOrEqual(nullDescriptor, 0)
		guard nullDescriptor >= 0 else { return }
		let sibling = try startUnrelatedSibling()
		defer {
			_ = Darwin.close(parentPipe[0])
			_ = Darwin.close(parentPipe[1])
			_ = Darwin.close(nullDescriptor)
			stopTestOwnedSibling(sibling)
		}
		var clockReads = 0
		var stagedChildPID: pid_t?
		var groupStopStatus: Int32?
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: nullDescriptor,
			uptime: {
				clockReads += 1
				if clockReads <= 2 { return 0 }
				if stagedChildPID == nil {
					stagedChildPID = self.waitForPID(
						in: descendantPIDFile,
						timeout: 2
					)
					_ = self.waitForFile(at: childReadyFile, timeout: 2)
					if let stagedChildPID {
						let groupID = Darwin.getpgid(stagedChildPID)
						groupStopStatus = Darwin.killpg(groupID, SIGSTOP)
					}
				}
				return 2
			}
		)

		let result = runtime.run()
		let childPID = try XCTUnwrap(stagedChildPID)

		XCTAssertEqual(result, LeaseWorkerExit.innerFailed.rawValue)
		XCTAssertEqual(groupStopStatus, 0)
		XCTAssertTrue(waitUntilGone(childPID, timeout: 2))
		XCTAssertTrue(FileManager.default.fileExists(atPath: replacementFenceFile.path))
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: orderViolationFile.path),
			"replacement fencing must observe the old direct inner already reaped"
		)
		assertSiblingStillExecuting(
			sibling,
			"the unrelated sibling must execute after stopped-group recovery"
		)
	}

	/// Proves readable parent traffic cannot make the outer impersonate Hammerspoon.
	func testOuterNeverManufacturesHeartbeatDuringContinuouslyReadableParentInput() throws {
		let fixture = try makeExecutableFixture(
			body: "IFS= read -r activate <&3 || exit 40\n"
				+ "if [ \"$activate\" = STOP ]; then\n"
				+ "  printf 'FENCED\\n' >&3\n  exit 0\nfi\n"
				+ "[ \"$activate\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "printf 'READY 1\\n' >&3\n"
				+ "IFS= read -r command <&3 || exit 42\n"
				+ "case \"$command\" in HEARTBEAT*) : > \"$4\"; exit 43;; esac\n"
				+ "[ \"$command\" = STOP ] || exit 44\nprintf 'FENCED\\n' >&3\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let heartbeatMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("heartbeat-observed")
		var parentSockets = [Int32](repeating: -1, count: 2)
		let socketStatus = parentSockets.withUnsafeMutableBufferPointer { buffer in
			Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, buffer.baseAddress!)
		}
		XCTAssertEqual(socketStatus, 0)
		guard socketStatus == 0 else { return }
		let nullDescriptor = Darwin.open("/dev/null", O_WRONLY)
		XCTAssertGreaterThanOrEqual(nullDescriptor, 0)
		guard nullDescriptor >= 0 else {
			_ = Darwin.close(parentSockets[0])
			_ = Darwin.close(parentSockets[1])
			return
		}
		defer {
			_ = Darwin.close(parentSockets[0])
			_ = Darwin.close(parentSockets[1])
			_ = Darwin.close(nullDescriptor)
		}
		XCTAssertTrue(prepareInnerControlDescriptor(parentSockets[1]))
		let floodWriter = Process()
		floodWriter.executableURL = URL(fileURLWithPath: "/bin/sh")
		floodWriter.arguments = [
			"-c",
			"i=0; while [ \"$i\" -lt 100 ]; do printf 'RESUME\\n'; "
				+ "sleep 0.01; i=$((i + 1)); done; printf 'STOP\\n'",
		]
		floodWriter.standardOutput = FileHandle(
			fileDescriptor: parentSockets[1],
			closeOnDealloc: false
		)
		try floodWriter.run()
		defer {
			if floodWriter.isRunning { floodWriter.terminate() }
			floodWriter.waitUntilExit()
		}
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: "unused-mode",
			revokedName: heartbeatMarker.path,
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 0.1
		)
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			parentInputDescriptor: parentSockets[0],
			parentOutputDescriptor: nullDescriptor
		)

		let started = ProcessInfo.processInfo.systemUptime
		let exitCode = runtime.run()
		XCTAssertEqual(exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertFalse(FileManager.default.fileExists(atPath: heartbeatMarker.path))
		XCTAssertGreaterThanOrEqual(
			ProcessInfo.processInfo.systemUptime - started,
			0.8,
			"the outer must remain heartbeat-idle until Hammerspoon sends PING"
		)
	}

	/// Proves STOP, peer loss, malformed input, and timeout touch only direct children.
	func testUnrelatedSiblingSurvivesEveryDirectChildPreemption() throws {
		try assertUnrelatedSiblingSurvives(interruption: .stop)
		try assertUnrelatedSiblingSurvives(interruption: .peerClosed)
		try assertUnrelatedSiblingSurvives(interruption: .malformed)
		try assertUnrelatedSiblingSurvives(interruption: .none)
	}

	/// Proves replacement fencing after modeled inner loss never targets a sibling.
	func testUnrelatedSiblingSurvivesInnerLossReplacementFence() throws {
		let fixture = try makeExecutableFixture(body: "exit 0\n")
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let sibling = try startUnrelatedSibling()
		defer { stopTestOwnedSibling(sibling) }

		let result = PosixLeaseCLIExecutor().execute(
			cliPath: fixture.path,
			payload: LeasePayloads.fence(identity: makeIdentity()),
			timeout: 1,
			interruption: { .none }
		)

		XCTAssertEqual(result, .success)
		assertSiblingStillExecuting(
			sibling,
			"the unrelated sibling must execute after replacement fencing"
		)
	}

	/// Runs one direct child failure beside a process whose PID is never shared.
	/// - Parameter interruption: STOP, peer loss, malformed input, or none for timeout.
	private func assertUnrelatedSiblingSurvives(
		interruption: LeaseCLIInterruption
	) throws {
		let fixture = try makeExecutableFixture(
			body: "trap '' TERM\nwhile :; do :; done\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let sibling = try startUnrelatedSibling()
		defer { stopTestOwnedSibling(sibling) }
		var firstProbe = true

		let result = PosixLeaseCLIExecutor().execute(
			cliPath: fixture.path,
			payload: LeasePayloads.mode(identity: makeIdentity(), mode: kLeaseModeActive),
			timeout: 0.1,
			interruption: {
				defer { firstProbe = false }
				return firstProbe ? interruption : .none
			}
		)

		if interruption == .none {
			XCTAssertEqual(result, .timedOut)
		} else {
			XCTAssertEqual(result, .interrupted(interruption))
		}
		assertSiblingStillExecuting(
			sibling,
			"the production executor never receives or discovers the sibling PID"
		)
	}

	/// Creates an executable shell fixture accepted as a direct fake CLI.
	/// - Parameter body: Shell body after the strict shebang.
	/// - Returns: Executable fixture URL inside a unique temporary directory.
	private func makeExecutableFixture(body: String) throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ErgoptiLeaseTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		let script = directory.appendingPathComponent("fake-karabiner-cli")
		try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: script.path
		)
		return script
	}

	/// Spawns a test-owned outer that retains both EOF stdin and its private socket.
	/// - Parameters:
	///   - privateDescriptor: Outer endpoint mapped to fd 3.
	///   - inheritedInnerDescriptor: Inner endpoint explicitly excluded from outer.
	///   - parentInputDescriptor: Hammerspoon pipe read end mapped to stdin.
	///   - inheritedParentWriteDescriptor: Hammerspoon write end excluded from outer.
	/// - Returns: Exact stopped outer PID after its ACTIVATE command was written.
	private func spawnStoppedOuterHarness(
		privateDescriptor: Int32,
		inheritedInnerDescriptor: Int32,
		parentInputDescriptor: Int32,
		inheritedParentWriteDescriptor: Int32
	) throws -> pid_t {
		var fileActions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&fileActions) == 0 else {
			throw NSError(domain: "ErgoptiLeaseHarness", code: Int(errno), userInfo: nil)
		}
		defer { posix_spawn_file_actions_destroy(&fileActions) }
		guard posix_spawn_file_actions_adddup2(
			&fileActions,
			parentInputDescriptor,
			STDIN_FILENO
		) == 0,
		posix_spawn_file_actions_adddup2(
			&fileActions,
			privateDescriptor,
			kInnerControlDescriptor
		) == 0
		else {
			throw NSError(domain: "ErgoptiLeaseHarness", code: Int(errno), userInfo: nil)
		}
		for descriptor in [
			inheritedInnerDescriptor,
			inheritedParentWriteDescriptor,
		] {
			_ = posix_spawn_file_actions_addclose(&fileActions, descriptor)
		}
		if privateDescriptor != kInnerControlDescriptor {
			_ = posix_spawn_file_actions_addclose(&fileActions, privateDescriptor)
		}
		if parentInputDescriptor != STDIN_FILENO {
			_ = posix_spawn_file_actions_addclose(&fileActions, parentInputDescriptor)
		}

		guard let rawArguments = duplicateLeaseArguments([
			"/bin/sh",
			"-c",
			"printf 'ACTIVATE 1\\n' >&3\nkill -STOP $$\nIFS= read -r ignored\n",
		]) else {
			throw NSError(domain: "ErgoptiLeaseHarness", code: Int(ENOMEM), userInfo: nil)
		}
		defer {
			for case let pointer? in rawArguments { free(pointer) }
		}
		var mutableArguments = rawArguments
		var processID: pid_t = 0
		let spawnStatus = mutableArguments.withUnsafeMutableBufferPointer { buffer in
			posix_spawn(
				&processID,
				"/bin/sh",
				&fileActions,
				nil,
				buffer.baseAddress,
				_NSGetEnviron().pointee
			)
		}
		guard spawnStatus == 0 else {
			throw NSError(
				domain: "ErgoptiLeaseHarness",
				code: Int(spawnStatus),
				userInfo: nil
			)
		}
		var status: Int32 = 0
		var waited: pid_t
		repeat {
			waited = waitpid(processID, &status, WUNTRACED)
		} while waited == -1 && errno == EINTR
		guard waited == processID, status & 0x7F == 0x7F else {
			_ = Darwin.kill(processID, SIGKILL)
			while waitpid(processID, &status, 0) == -1 && errno == EINTR {}
			throw NSError(domain: "ErgoptiLeaseHarness", code: Int(status), userInfo: nil)
		}
		return processID
	}

	/// Starts an unrelated process that appends proof of continued execution.
	/// - Returns: Test-owned sibling plus its monotonic progress marker.
	private func startUnrelatedSibling() throws -> ProgressingTestSibling {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ErgoptiSibling-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		let progressFile = directory.appendingPathComponent("progress")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = [
			"-c",
			kSiblingProgressCommand,
			"lease-sibling",
			progressFile.path,
			kSiblingProgressIntervalArgument,
		]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			try? FileManager.default.removeItem(at: directory)
			throw error
		}
		let sibling = ProgressingTestSibling(
			process: process,
			directory: directory,
			progressFile: progressFile
		)
		let startingSize = siblingProgressSize(sibling)
		guard waitForSiblingProgress(
			sibling,
			after: startingSize,
			timeout: kSiblingProgressTimeoutSeconds
		) else {
			stopTestOwnedSibling(sibling)
			throw NSError(
				domain: "ErgoptiLeaseHarness",
				code: Int(ETIMEDOUT),
				userInfo: [
					NSLocalizedDescriptionKey:
						"unrelated sibling did not publish initial execution progress",
				]
			)
		}
		return sibling
	}

	/// Asserts that a sibling performs new work after the protected signal path.
	/// A zombie or stopped process still satisfies kill(pid, 0), but cannot append.
	/// - Parameters:
	///   - sibling: Test-owned process and its progress marker.
	///   - message: Isolation guarantee reported on failure.
	///   - file: XCTest caller source file.
	///   - line: XCTest caller source line.
	private func assertSiblingStillExecuting(
		_ sibling: ProgressingTestSibling,
		_ message: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let startingSize = siblingProgressSize(sibling)
		XCTAssertTrue(
			waitForSiblingProgress(
				sibling,
				after: startingSize,
				timeout: kSiblingProgressTimeoutSeconds
			),
			message,
			file: file,
			line: line
		)
	}

	/// Reads the append-only marker size without relying on the sibling PID.
	/// - Parameter sibling: Test-owned progress witness.
	/// - Returns: Current marker byte count, or zero before its first append.
	private func siblingProgressSize(_ sibling: ProgressingTestSibling) -> UInt64 {
		guard let attributes = try? FileManager.default.attributesOfItem(
			atPath: sibling.progressFile.path
		), let size = attributes[.size] as? NSNumber
		else { return 0 }
		return size.uint64Value
	}

	/// Waits for one post-check append, proving the sibling is executing code.
	/// - Parameters:
	///   - sibling: Test-owned progress witness.
	///   - startingSize: Marker size sampled after the protected operation.
	///   - timeout: Maximum monotonic observation interval.
	/// - Returns: Whether the marker grew after the supplied sample.
	private func waitForSiblingProgress(
		_ sibling: ProgressingTestSibling,
		after startingSize: UInt64,
		timeout: TimeInterval
	) -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		repeat {
			if siblingProgressSize(sibling) > startingSize { return true }
			usleep(kSiblingProgressPollMicroseconds)
		} while ProcessInfo.processInfo.systemUptime < deadline
		return siblingProgressSize(sibling) > startingSize
	}

	/// Checks one test-owned PID without transferring it to production code.
	/// - Parameter processID: Sibling process identifier.
	/// - Returns: Whether signal zero proves the process still exists.
	private func isAlive(_ processID: pid_t) -> Bool {
		return Darwin.kill(processID, 0) == 0 || errno == EPERM
	}

	/// Waits for one child PID published by the owned-group fixture.
	/// - Parameters:
	///   - url: File populated by the fixture after spawning its child.
	///   - timeout: Maximum observation interval.
	/// - Returns: Positive child PID, or nil on timeout or malformed content.
	private func waitForPID(in url: URL, timeout: TimeInterval) -> pid_t? {
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		repeat {
			if let raw = try? String(contentsOf: url, encoding: .utf8),
				let processID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
				processID > 0 {
				return processID
			}
			usleep(10_000)
		} while ProcessInfo.processInfo.systemUptime < deadline
		return nil
	}

	/// Waits until a fixture publishes one readiness or fence marker.
	/// - Parameters:
	///   - url: Marker created only after the protected transition.
	///   - timeout: Maximum observation interval.
	/// - Returns: Whether the marker became visible before the deadline.
	private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		repeat {
			if FileManager.default.fileExists(atPath: url.path) { return true }
			usleep(10_000)
		} while ProcessInfo.processInfo.systemUptime < deadline
		return FileManager.default.fileExists(atPath: url.path)
	}

	/// Waits for one direct child to publish a WUNTRACED stopped status.
	/// - Parameters:
	///   - processID: Test-owned direct child expected to stop itself.
	///   - timeout: Maximum observation interval.
	/// - Returns: Whether waitpid observed a stopped, still-unreaped child.
	private func waitUntilStopped(_ processID: pid_t, timeout: TimeInterval) -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		repeat {
			var status: Int32 = 0
			let waited = waitpid(processID, &status, WUNTRACED | WNOHANG)
			if waited == processID { return status & 0x7F == 0x7F }
			if waited == -1 && errno != EINTR { return false }
			usleep(10_000)
		} while ProcessInfo.processInfo.systemUptime < deadline
		return false
	}

	/// Waits until one observed orphan PID no longer names a live process.
	/// - Parameters:
	///   - processID: Former CLI descendant PID never passed to production code.
	///   - timeout: Maximum observation interval.
	/// - Returns: Whether the process disappeared before the deadline.
	private func waitUntilGone(_ processID: pid_t, timeout: TimeInterval) -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		repeat {
			if !isAlive(processID) { return true }
			usleep(10_000)
		} while ProcessInfo.processInfo.systemUptime < deadline
		return !isAlive(processID)
	}

	/// Cleans up only the sibling created by this XCTest, even if it was stopped.
	/// - Parameter sibling: Test-owned process and progress directory.
	private func stopTestOwnedSibling(_ sibling: ProgressingTestSibling) {
		let process = sibling.process
		if process.isRunning {
			_ = Darwin.kill(process.processIdentifier, SIGCONT)
			process.terminate()
			let deadline = ProcessInfo.processInfo.systemUptime
				+ kSiblingTerminationGraceSeconds
			while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
				usleep(kSiblingProgressPollMicroseconds)
			}
			if process.isRunning {
				_ = Darwin.kill(process.processIdentifier, SIGKILL)
			}
		}
		process.waitUntilExit()
		try? FileManager.default.removeItem(at: sibling.directory)
	}
}





// ==========================================
// ==========================================
// ======= 7/ Behavioral Test Doubles =======
// ==========================================
// ==========================================

/// Supplies deterministic commands and liveness events to the inner runtime.
private final class ScriptedLeaseInnerChannel: LeaseInnerChannel {
	private var events: [LeaseInnerChannelEvent]
	private(set) var acknowledgements: [LeaseInnerAcknowledgement] = []

	/// Creates a finite deterministic private-channel script.
	/// - Parameter events: Commands and loss events returned in order.
	init(events: [LeaseInnerChannelEvent]) {
		self.events = events
	}

	/// Returns the next scripted event, defaulting to peer loss at exhaustion.
	/// - Returns: Next deterministic event.
	func nextEvent(timeout: TimeInterval) -> LeaseInnerChannelEvent {
		_ = timeout
		guard !events.isEmpty else { return .peerClosed }
		return events.removeFirst()
	}

	/// Exposes only terminal events to an in-flight fake CLI child.
	/// - Returns: STOP, peer loss, malformed input, or no interruption.
	func pollInterruption() -> LeaseCLIInterruption {
		guard let event = events.first else { return .none }
		switch event {
		case .command(.stop):
			events.removeFirst()
			return .stop
		case .peerClosed, .outerSilent:
			events.removeFirst()
			return .peerClosed
		case .malformed:
			events.removeFirst()
			return .malformed
		case .command:
			return .none
		}
	}

	/// Records acknowledgements exactly as the outer role would receive them.
	/// - Parameter acknowledgement: Runtime result.
	/// - Returns: Always true for this connected test channel.
	func send(_ acknowledgement: LeaseInnerAcknowledgement) -> Bool {
		acknowledgements.append(acknowledgement)
		return true
	}
}

/// Records serialized payloads and returns deterministic direct-child results.
private final class ScriptedLeaseCLIExecutor: LeaseCLIExecuting {
	private var results: [LeaseCLIResult]
	private let probeCalls: Set<Int>
	private let timestamp: () -> TimeInterval
	private var callCount = 0
	private var activeChildren = 0
	private(set) var maximumConcurrentChildren = 0
	private(set) var cliPaths: [String] = []
	private(set) var payloads: [String] = []
	private(set) var executionTimes: [TimeInterval] = []

	/// Creates one deterministic exact-child result sequence.
	/// - Parameters:
	///   - results: Results returned by call index, defaulting to success.
	///   - probeCalls: Calls that must ask the channel about STOP or EOF.
	///   - timestamp: Monotonic call-time observer for grace assertions.
	init(
		results: [LeaseCLIResult],
		probeCalls: Set<Int>,
		timestamp: @escaping () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		}
	) {
		self.results = results
		self.probeCalls = probeCalls
		self.timestamp = timestamp
	}

	/// Simulates one serialized child and records overlap if it ever occurs.
	/// - Parameters:
	///   - cliPath: Exact path recorded for canonical-boundary assertions.
	///   - payload: Exact payload recorded for ordering assertions.
	///   - timeout: Unused deterministic timeout.
	///   - interruption: Real runtime interruption callback.
	/// - Returns: Scripted or interruption result.
	func execute(
		cliPath: String,
		payload: String,
		timeout: TimeInterval,
		interruption: () -> LeaseCLIInterruption
	) -> LeaseCLIResult {
		callCount += 1
		activeChildren += 1
		maximumConcurrentChildren = max(maximumConcurrentChildren, activeChildren)
		defer { activeChildren -= 1 }
		cliPaths.append(cliPath)
		payloads.append(payload)
		executionTimes.append(timestamp())

		if probeCalls.contains(callCount) {
			let requested = interruption()
			if requested != .none { return .interrupted(requested) }
		}
		if !results.isEmpty { return results.removeFirst() }
		return .success
	}
}

/// Permits one authenticated inner, then models a permanently unavailable path.
private final class InitialThenUnavailableLeaseInnerSpawner: LeaseInnerSpawning {
	private let initialSpawner: LeaseInnerSpawning
	private(set) var spawnAttempts = 0

	/// Retains only the production spawner used for the initial authenticated role.
	/// - Parameter initialSpawner: Real same-executable spawner for the first call.
	init(initialSpawner: LeaseInnerSpawning) {
		self.initialSpawner = initialSpawner
	}

	/// Returns the first inner, then nil for every replacement attempt forever.
	/// - Parameter identity: Exact lease identity forwarded only on the first call.
	/// - Returns: One initial inner or nil after simulated path loss.
	func spawn(identity: LeaseIdentity) -> SpawnedLeaseInner? {
		spawnAttempts += 1
		guard spawnAttempts == 1 else { return nil }
		return initialSpawner.spawn(identity: identity)
	}
}

/// Models only the two Karabiner variables that determine rule effectiveness.
private struct KarabinerGenerationModel {
	private(set) var mode = kLeaseModeOff
	private(set) var revoked = 0
	private var stagedOrphanMode: Int?

	/// Applies a live writer that is forbidden from mutating revoked.
	/// - Parameter newMode: Active or paused mode.
	mutating func apply(mode newMode: Int) {
		mode = newMode
	}

	/// Applies the exact two-variable fence batch.
	mutating func applyFence() {
		mode = kLeaseModeOff
		revoked = 1
	}

	/// Stages one CLI mode write that has not completed yet.
	/// - Parameter newMode: Mode the orphan would publish when resumed.
	mutating func stageOrphan(mode newMode: Int) {
		stagedOrphanMode = newMode
	}

	/// Models exact owned-group termination before the inner leader is reaped.
	mutating func terminateOwnedWriterGroup() {
		stagedOrphanMode = nil
	}

	/// Models the shared Core Service clearing all volatile variables on restart.
	mutating func resetCoreVariables() {
		mode = kLeaseModeOff
		revoked = 0
	}

	/// Resumes a staged orphan only when group confinement did not remove it.
	mutating func resumeOrphan() {
		guard let stagedOrphanMode else { return }
		mode = stagedOrphanMode
		self.stagedOrphanMode = nil
	}

	/// Reports whether generated rule gates would authorize any Ergopti action.
	var isEffective: Bool {
		return revoked == 0 && (mode == kLeaseModeActive || mode == kLeaseModePaused)
	}
}
