// Tests/ErgoptiPlusTests/RemapLeaseWorkerTests.swift

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
import ServiceManagement
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

/// Owns one real launcher process used by cross-exec POSIX regression tests.
private struct POSIXTestHelperProcess {
	let process: Process
	let input: Pipe
	let output: Pipe
	let completion: DispatchSemaphore
}

/// Deterministic independent-guardian boundary for outer protocol tests.
private final class ScriptedLeaseGuardianRegistration: LeaseGuardianRegistering {
	let armResult: Bool
	var present = true
	var armCalls = 0
	var beginLiveTransportCalls = 0
	var endLiveTransportCalls = 0
	var liveTransportAllowed = true
	var loseGuardianAfterSuccessfulBegin = false
	var endLiveTransportHook: (() -> Void)?
	var retireCalls = 0
	var closeCalls = 0
	var childCloseDescriptors: [Int32] = []

	init(armResult: Bool) {
		self.armResult = armResult
	}

	func arm() -> Bool {
		armCalls += 1
		return armResult
	}

	func guardianStillPresent() -> Bool { return present }
	func beginLiveTransport() -> Bool {
		beginLiveTransportCalls += 1
		let allowed = present && liveTransportAllowed
		if allowed && loseGuardianAfterSuccessfulBegin { present = false }
		return allowed
	}
	func endLiveTransport() {
		endLiveTransportCalls += 1
		endLiveTransportHook?()
	}
	func cancelBeforeActivation() { retireCalls += 1 }
	func retireAfterFence() { retireCalls += 1 }
	func closePreservingAbandonment() { closeCalls += 1 }
}

/// Counts attempts without creating an inner process.
private final class CountingLeaseInnerSpawner: LeaseInnerSpawning {
	var spawnCalls = 0
	func spawn(identity: LeaseIdentity) -> SpawnedLeaseInner? {
		spawnCalls += 1
		return nil
	}
}

/// Records the exact repeated fence requested by an abandoned durable record.
private final class GuardianRecordingLeaseCLIExecutor:
	LeaseCLIExecuting,
	LeaseCLIExecutingWithDescriptorClosure {
	private let lock = NSLock()
	private let started = DispatchSemaphore(value: 0)
	private let completed = DispatchSemaphore(value: 0)
	private let blockedCallReached = DispatchSemaphore(value: 0)
	private let blockedCallMayReturn = DispatchSemaphore(value: 0)
	private let blockAfterCall: Int?
	private var results: [LeaseCLIResult]
	private(set) var cliPaths: [String] = []
	private(set) var payloads: [String] = []
	private(set) var closedDescriptors: [[Int32]] = []

	/// Creates a recorder with optional child results and one controllable call.
	init(results: [LeaseCLIResult] = [], blockAfterCall: Int? = nil) {
		self.results = results
		self.blockAfterCall = blockAfterCall
	}

	/// Records one ordinary executor call through the descriptor-aware boundary.
	func execute(
		cliPath: String,
		payload: String,
		timeout: TimeInterval,
		interruption: () -> LeaseCLIInterruption
	) -> LeaseCLIResult {
		return execute(
			cliPath: cliPath,
			payload: payload,
			timeout: timeout,
			interruption: interruption,
			closingDescriptors: []
		)
	}

	/// Records one hardened executor call and returns its scripted result.
	func execute(
		cliPath: String,
		payload: String,
		timeout: TimeInterval,
		interruption: () -> LeaseCLIInterruption,
		closingDescriptors: [Int32]
	) -> LeaseCLIResult {
		lock.lock()
		cliPaths.append(cliPath)
		payloads.append(payload)
		closedDescriptors.append(closingDescriptors)
		let callCount = payloads.count
		let shouldSignalStart = payloads.count == 1
		let shouldSignal = payloads.count == 2
		let result = results.isEmpty ? LeaseCLIResult.success : results.removeFirst()
		lock.unlock()
		if shouldSignalStart { started.signal() }
		if shouldSignal { completed.signal() }
		if let blockAfterCall, callCount == blockAfterCall {
			blockedCallReached.signal()
			blockedCallMayReturn.wait()
		}
		return result
	}

	/// Waits until the first exact fence transport begins.
	func waitForAnyFence(timeout: TimeInterval) -> Bool {
		return started.wait(timeout: .now() + timeout) == .success
	}

	/// Waits until at least two transport attempts have been observed.
	func waitForRepeatedFence(timeout: TimeInterval) -> Bool {
		return completed.wait(timeout: .now() + timeout) == .success
	}

	/// Waits until the configured call reaches its pre-return barrier.
	func waitForBlockedCall(timeout: TimeInterval) -> Bool {
		return blockedCallReached.wait(timeout: .now() + timeout) == .success
	}

	/// Releases the configured pre-return barrier without touching any process.
	func resumeBlockedCall() {
		blockedCallMayReturn.signal()
	}

	/// Returns one lock-protected copy of every recorded executor argument.
	func snapshot() -> (paths: [String], payloads: [String], descriptors: [[Int32]]) {
		lock.lock()
		defer { lock.unlock() }
		return (cliPaths, payloads, closedDescriptors)
	}
}

/// Thread-safe capture of the guardian's process-termination boundary.
private final class GuardianTerminationRecorder {
	private let lock = NSLock()
	private let completed = DispatchSemaphore(value: 0)
	private var status: Int32?

	func terminate(_ value: Int32) {
		lock.lock()
		status = value
		lock.unlock()
		completed.signal()
	}

	func wait(timeout: TimeInterval) -> Int32? {
		guard completed.wait(timeout: .now() + timeout) == .success else { return nil }
		lock.lock()
		defer { lock.unlock() }
		return status
	}
}

/// Converts an unexpected test-runtime exit into an XCTest failure.
private func failUnexpectedGuardianTermination(_ status: Int32) {
	XCTFail("a test-owned guardian runtime requested process exit status \(status)")
}

/// Thread-safe capture for a startup call executed beside a real flock holder.
private final class GuardianStartupRecorder {
	private let lock = NSLock()
	private var result: Bool?

	/// Stores one startup result under the recorder lock.
	func store(_ value: Bool) {
		lock.lock()
		result = value
		lock.unlock()
	}

	/// Returns the current startup result under the recorder lock.
	func snapshot() -> Bool? {
		lock.lock()
		defer { lock.unlock() }
		return result
	}
}

/// Signals immediately before delegating to the real blocking activation drain.
private final class ObservedActivationGateLocker {
	private let attempted = DispatchSemaphore(value: 0)

	/// Announces the attempt, then performs the production blocking flock.
	func callAsFunction(_ descriptor: Int32) -> LeaseGuardianGateLockResult {
		attempted.signal()
		return lockGuardianActivationGate(descriptor)
	}

	/// Waits a bounded interval until the guardian reaches activation drain.
	func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
		return attempted.wait(timeout: .now() + timeout)
	}
}

/// Deterministic launchctl boundary for legacy registration ordering tests.
private final class ScriptedGuardianLaunchctlRunner: GuardianLaunchctlRunning {
	private var results: [Bool]
	private(set) var calls: [[String]] = []

	init(results: [Bool]) {
		self.results = results
	}

	func run(arguments: [String]) -> Bool {
		calls.append(arguments)
		return results.isEmpty ? false : results.removeFirst()
	}
}

/// Models one modern Background Item service without touching system settings.
@available(macOS 13.0, *)
private final class ScriptedModernGuardianService: RemapGuardianModernService {
	var status: SMAppService.Status
	private let statusAfterRegister: SMAppService.Status
	private let registrationError: Error?
	private(set) var registerCalls = 0

	/// Creates one scripted status transition or registration error.
	init(
		status: SMAppService.Status = .notRegistered,
		statusAfterRegister: SMAppService.Status = .enabled,
		registrationError: Error? = nil
	) {
		self.status = status
		self.statusAfterRegister = statusAfterRegister
		self.registrationError = registrationError
	}

	/// Records registration and applies the configured result.
	func register() throws {
		registerCalls += 1
		if let registrationError { throw registrationError }
		status = statusAfterRegister
	}
}

/// Verifies the native lease guardian’s loss, ordering, and PID-isolation contracts.
final class KarabinerLeaseWorkerTests: XCTestCase {
	private let token = "00112233445566778899aabbccddeeff"
	private let guardianGeneration = "1234567890abcdef1234567890abcdef"

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

	/// Creates one unlocked durable record as if every private worker was killed.
	private func makeAbandonedGuardianRecord(
		token: String
	) throws -> (home: URL, paths: LeaseGuardianPaths, record: LeaseGuardianRecord) {
		let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("ergopti-guardian-\(UUID().uuidString)", isDirectory: true)
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		try FileManager.default.createDirectory(
			atPath: paths.records,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try FileManager.default.createDirectory(
			atPath: paths.acknowledgements,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let record = LeaseGuardianRecord(
			token: token,
			nonce: "ffeeddccbbaa99887766554433221100",
			ownerPID: getpid(),
			state: .live
		)
		try XCTUnwrap(record.encoded).write(
			to: URL(fileURLWithPath: paths.recordPath(token: token))
		)
		XCTAssertEqual(Darwin.chmod(paths.recordPath(token: token), 0o600), 0)
		return (home, paths, record)
	}

	/// Resolves the real SwiftPM executable beside the XCTest bundle.
	private func guardianTestExecutable() throws -> URL {
		let productsDirectory = Bundle(for: KarabinerLeaseWorkerTests.self)
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
			XCTFail("the real ErgoptiPlus SwiftPM product is required for the lifetime test")
			throw NSError(domain: "ErgoptiGuardianTests", code: Int(ENOENT))
		}
		return executable
	}

	/// Stops and observes only the exact Process created by the lifetime test.
	private func stopExactGuardianTestProcess(
		_ process: Process,
		completion: DispatchSemaphore
	) {
		if process.isRunning { process.terminate() }
		if completion.wait(timeout: .now() + 0.5) == .success { return }
		if process.isRunning {
			_ = Darwin.kill(process.processIdentifier, SIGKILL)
		}
		XCTAssertEqual(
			completion.wait(timeout: .now() + 0.5),
			.success,
			"the exact guardian lifetime-test child must terminate within its bound"
		)
	}

	/// Starts one debug-only role through Process, whose implementation uses posix_spawn.
	private func startPOSIXTestHelper(
		mode: String,
		path: String? = nil
	) throws -> POSIXTestHelperProcess {
		let process = Process()
		let input = Pipe()
		let output = Pipe()
		let completion = DispatchSemaphore(value: 0)
		process.executableURL = try guardianTestExecutable()
		process.arguments = [kPOSIXTestHelperFlag, mode] + (path.map { [$0] } ?? [])
		process.standardInput = input
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		process.terminationHandler = { _ in completion.signal() }
		try process.run()
		return POSIXTestHelperProcess(
			process: process,
			input: input,
			output: output,
			completion: completion
		)
	}

	/// Refuses every inner spawn when the independent survivor did not ACK ARM.
	func testGuardianRefusesActivationBeforeArmed() {
		let guardian = ScriptedLeaseGuardianRegistration(armResult: false)
		let spawner = CountingLeaseInnerSpawner()
		let runtime = KarabinerLeaseOuterRuntime(
			identity: makeIdentity(),
			detached: false,
			spawner: spawner,
			guardianRegistration: guardian
		)

		XCTAssertEqual(runtime.run(), LeaseWorkerExit.guardianUnavailable.rawValue)
		XCTAssertEqual(guardian.armCalls, 1)
		XCTAssertEqual(spawner.spawnCalls, 0,
			"no inner or active variable write may precede durable ARMED")
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Starts the real headless product and proves its singleton stays locked.
	func testGuardianProcessRemainsAliveAfterStartup() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-lifetime-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: home,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		XCTAssertEqual(Darwin.chmod(home.path, 0o700), 0)
		defer { try? FileManager.default.removeItem(at: home) }

		let process = Process()
		process.executableURL = try guardianTestExecutable()
		process.arguments = [kKarabinerLeaseGuardianLifetimeTestFlag, home.path]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		let completion = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completion.signal() }
		try process.run()
		var observedCleanSIGTERM = false
		defer {
			if !observedCleanSIGTERM {
				stopExactGuardianTestProcess(process, completion: completion)
			}
		}

		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let deadline = ProcessInfo.processInfo.systemUptime + 3
		var observedExclusiveLock = false
		while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
			let descriptor = Darwin.open(
				paths.singletonLock,
				O_RDWR | O_CLOEXEC | O_NOFOLLOW
			)
			if descriptor >= 0 {
				let result = ergoptiFlock(descriptor, LOCK_EX | LOCK_NB)
				observedExclusiveLock = result == -1 && errno == EWOULDBLOCK
				if result == 0 { _ = ergoptiFlock(descriptor, LOCK_UN) }
				Darwin.close(descriptor)
				if observedExclusiveLock { break }
			}
			usleep(kSiblingProgressPollMicroseconds)
		}
		XCTAssertTrue(observedExclusiveLock,
			"the real guardian process must own the singleton before the test proceeds")
		usleep(350_000)
		XCTAssertTrue(process.isRunning,
			"a guardian backed only by GCD sources must not fall out of an empty RunLoop")

		XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGTERM), 0)
		guard completion.wait(timeout: .now() + 3) == .success else {
			XCTFail("the real launchd role must drain and exit from SIGTERM without SIGKILL cleanup")
			return
		}
		observedCleanSIGTERM = true
		XCTAssertEqual(process.terminationReason, .exit)
		XCTAssertEqual(process.terminationStatus, LeaseWorkerExit.success.rawValue)
	}

	/// Replacing the durable namespace drains every known token before restart.
	func testGuardianDrainsReplacedRecordsDirectoryBeforeRestart() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-lifetime-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: home,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		XCTAssertEqual(Darwin.chmod(home.path, 0o700), 0)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let fixtureRecord = LeaseGuardianRecord(
			token: token,
			nonce: "ffeeddccbbaa99887766554433221100",
			ownerPID: getpid(),
			state: .live
		)
		try FileManager.default.createDirectory(
			atPath: paths.records,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try FileManager.default.createDirectory(
			atPath: paths.acknowledgements,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try XCTUnwrap(fixtureRecord.encoded).write(to: URL(
			fileURLWithPath: paths.recordPath(token: token)
		))
		let owner = Darwin.open(
			paths.recordPath(token: token),
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0)

		let executor = GuardianRecordingLeaseCLIExecutor()
		let termination = GuardianTerminationRecorder()
		var firstRuntime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: executor,
			terminateProcess: termination.terminate,
			generation: guardianGeneration
		)
		XCTAssertTrue(firstRuntime?.startObservingForTesting() == true)

		let displaced = paths.root + "/records.displaced"
		try FileManager.default.moveItem(atPath: paths.records, toPath: displaced)
		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))
		XCTAssertEqual(
			termination.wait(timeout: 2),
			LeaseWorkerExit.success.rawValue,
			"namespace loss must fence before the old guardian exits"
		)
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		XCTAssertEqual(executor.snapshot().payloads, [exactFence, exactFence])
		let retiredRecord = LeaseGuardianRecord(
			token: fixtureRecord.token,
			nonce: fixtureRecord.nonce,
			ownerPID: fixtureRecord.ownerPID,
			state: .retired
		)
		XCTAssertTrue(replaceGuardianData(
			try XCTUnwrap(retiredRecord.encoded),
			descriptor: owner
		))
		Darwin.close(owner)
		firstRuntime = nil

		let replacementGeneration = "abcdef1234567890abcdef1234567890"
		let replacementTermination = GuardianTerminationRecorder()
		var secondRuntime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: replacementTermination.terminate,
			generation: replacementGeneration
		)
		XCTAssertTrue(secondRuntime?.startObservingForTesting() == true)
		let freshIdentity = LeaseIdentity(
			cliPath: kCanonicalKarabinerCLIPath,
			token: "abcdefabcdefabcdefabcdefabcdefab",
			modeName: "ergopti_mode_abcdefabcdefabcdefabcdefabcdefab",
			revokedName: "ergopti_revoked_abcdefabcdefabcdefabcdefabcdefab",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let registration = LeaseGuardianRegistration(
			identity: freshIdentity,
			paths: paths,
			activationAuthorized: { true }
		)
		XCTAssertTrue(registration.arm(),
			"a launchd replacement must durably ACK a fresh exact generation")
		registration.cancelBeforeActivation()
		try FileManager.default.removeItem(at: home)
		XCTAssertEqual(
			replacementTermination.wait(timeout: 2),
			LeaseWorkerExit.success.rawValue,
			"fixture teardown must join the replacement guardian's expected exit"
		)
		secondRuntime = nil
	}
	#endif

	/// A shared probe held by another outer must not look like the exclusive agent.
	func testGuardianPresenceProbesDoNotImpersonateGuardian() throws {
		let fixture = try makeAbandonedGuardianRecord(
			token: "abcdefabcdefabcdefabcdefabcdefab"
		)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let holder = try startPOSIXTestHelper(
			mode: "hold-shared",
			path: fixture.paths.singletonLock
		)
		defer {
			stopExactGuardianTestProcess(holder.process, completion: holder.completion)
		}

		let readyDescriptor = holder.output.fileHandleForReading.fileDescriptor
		var readyPoll = pollfd(fd: readyDescriptor, events: Int16(POLLIN), revents: 0)
		guard Darwin.poll(&readyPoll, 1, 2_000) > 0 else {
			XCTFail("the exact shared-lock child did not become ready within its bound")
			return
		}
		var childLocked: UInt8 = 0
		XCTAssertEqual(Darwin.read(readyDescriptor, &childLocked, 1), 1)
		XCTAssertEqual(childLocked, 1)

		let probe = Darwin.open(
			fixture.paths.singletonLock,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(probe, 0)
		guard probe >= 0 else { return }
		defer { Darwin.close(probe) }
		XCTAssertFalse(
			guardianSingletonIsExclusivelyHeld(descriptor: probe),
			"another outer's compatible shared probe is not the exclusive guardian"
		)
	}

	/// A transient shared health probe cannot make the replacement guardian exit.
	func testGuardianStartupWaitsOutSharedPresenceProbe() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-start-probe-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		try FileManager.default.createDirectory(
			atPath: paths.root,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let holder = try startPOSIXTestHelper(
			mode: "hold-shared",
			path: paths.singletonLock
		)
		var holderReaped = false
		defer {
			if !holderReaped {
				stopExactGuardianTestProcess(holder.process, completion: holder.completion)
			}
		}
		let readyReadDescriptor = holder.output.fileHandleForReading.fileDescriptor
		var readyPoll = pollfd(fd: readyReadDescriptor, events: Int16(POLLIN), revents: 0)
		guard Darwin.poll(&readyPoll, 1, 2_000) > 0 else {
			XCTFail("the shared presence probe did not acquire its cross-process lock")
			return
		}
		var childLocked: UInt8 = 0
		XCTAssertEqual(Darwin.read(readyReadDescriptor, &childLocked, 1), 1)
		guard childLocked == 1 else {
			XCTFail("the cross-process presence probe failed to acquire LOCK_SH")
			return
		}

		let contentionObserved = DispatchSemaphore(value: 0)
		let runtime = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: failUnexpectedGuardianTermination,
			singletonContentionObserved: { contentionObserved.signal() },
			generation: guardianGeneration
		)
		let result = GuardianStartupRecorder()
		let completed = DispatchSemaphore(value: 0)
		DispatchQueue.global(qos: .userInitiated).async {
			result.store(runtime.startObservingForTesting())
			completed.signal()
		}
		XCTAssertEqual(
			contentionObserved.wait(timeout: .now() + 2),
			.success,
			"the startup call must reach and classify the compatible shared contention"
		)
		XCTAssertEqual(
			completed.wait(timeout: .now() + 0.1),
			.timedOut,
			"a compatible shared probe must make startup retry, not report a duplicate guardian"
		)
		var releaseByte: UInt8 = 1
		var releaseResult: Int
		repeat {
			releaseResult = Darwin.write(
				holder.input.fileHandleForWriting.fileDescriptor,
				&releaseByte,
				1
			)
		} while releaseResult == -1 && errno == EINTR
		guard releaseResult == 1 else {
			XCTFail("the shared-lock child release byte must be delivered exactly once")
			return
		}
		XCTAssertEqual(holder.completion.wait(timeout: .now() + 1), .success)
		holderReaped = true
		XCTAssertEqual(holder.process.terminationReason, .exit)
		XCTAssertEqual(holder.process.terminationStatus, 0)
		XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
		XCTAssertEqual(result.snapshot(), true)
	}

	/// A real exclusive owner still rejects a duplicate guardian immediately.
	func testGuardianStartupRejectsExclusiveGuardianOwner() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-start-owner-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		try FileManager.default.createDirectory(
			atPath: paths.root,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let owner = Darwin.open(
			paths.singletonLock,
			O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
			S_IRUSR | S_IWUSR
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		defer { Darwin.close(owner) }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX), 0)
		let runtime = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)

		XCTAssertFalse(runtime.startObservingForTesting())
	}

	/// A user denial on macOS 13+ must never fall through to manual launchctl.
	func testModernGuardianRegistrationNeverBypassesUserDenial() throws {
		guard #available(macOS 13.0, *) else { return }
		let denial = NSError(
			domain: kRemapGuardianServiceErrorDomain,
			code: kSMErrorLaunchDeniedByUser
		)
		let authorizationFailure = NSError(
			domain: kRemapGuardianServiceErrorDomain,
			code: kSMErrorAuthorizationFailure
		)
		XCTAssertFalse(shouldUseLegacyGuardianAfterModernRegistrationError(denial))
		XCTAssertFalse(shouldUseLegacyGuardianAfterModernRegistrationError(
			authorizationFailure
		))
		XCTAssertFalse(shouldUseLegacyGuardianAfterModernRegistrationError(NSError(
			domain: "UnexpectedDomain",
			code: kSMErrorInvalidSignature
		)))
		XCTAssertTrue(shouldUseLegacyGuardianAfterModernRegistrationError(NSError(
			domain: kRemapGuardianServiceErrorDomain,
			code: kSMErrorInvalidSignature
		)))

		for (error, expected) in [
			(denial, RemapGuardianRegistrationStatus.requiresApproval),
			(authorizationFailure, RemapGuardianRegistrationStatus.unavailable),
		] {
			let service = ScriptedModernGuardianService(registrationError: error)
			var healthCalls = 0
			var legacyCalls = 0
			let result = resolveModernRemapGuardianRegistration(
				service: service,
				guardianHealth: {
					healthCalls += 1
					return true
				},
				legacyInvalidSignatureFallback: {
					legacyCalls += 1
					return true
				}
			)
			XCTAssertEqual(result, expected)
			XCTAssertEqual(service.registerCalls, 1)
			XCTAssertEqual(healthCalls, 0)
			XCTAssertEqual(legacyCalls, 0,
				"denial and authorization failures must never bootstrap around Background Items")
		}

		let invalidSignatureService = ScriptedModernGuardianService(
			registrationError: NSError(
				domain: kRemapGuardianServiceErrorDomain,
				code: kSMErrorInvalidSignature
			)
		)
		var invalidSignatureFallbackCalls = 0
		XCTAssertEqual(resolveModernRemapGuardianRegistration(
			service: invalidSignatureService,
			guardianHealth: { true },
			legacyInvalidSignatureFallback: {
				invalidSignatureFallbackCalls += 1
				return true
			}
		), .ready)
		XCTAssertEqual(invalidSignatureFallbackCalls, 1)
	}

	/// Runtime observation is read-only and requires both eligibility and health.
	func testModernGuardianObservationNeverRegistersAndRequiresExactHealth() {
		guard #available(macOS 13.0, *) else { return }
		for (status, healthy, expected, expectedHealthCalls) in [
			(SMAppService.Status.enabled, true,
				RemapGuardianRegistrationStatus.ready, 1),
			(SMAppService.Status.enabled, false,
				RemapGuardianRegistrationStatus.unavailable, 1),
			(SMAppService.Status.requiresApproval, true,
				RemapGuardianRegistrationStatus.requiresApproval, 0),
			(SMAppService.Status.notRegistered, true,
				RemapGuardianRegistrationStatus.ready, 1),
			(SMAppService.Status.notRegistered, false,
				RemapGuardianRegistrationStatus.unavailable, 1),
			(SMAppService.Status.notFound, true,
				RemapGuardianRegistrationStatus.ready, 1),
			(SMAppService.Status.notFound, false,
				RemapGuardianRegistrationStatus.unavailable, 1),
		] {
			let service = ScriptedModernGuardianService(status: status)
			var healthCalls = 0
			let observed = observeModernRemapGuardianRegistration(
				service: service,
				guardianHealth: {
					healthCalls += 1
					return healthy
				}
			)
			XCTAssertEqual(observed, expected)
			XCTAssertEqual(healthCalls, expectedHealthCalls)
			XCTAssertEqual(service.registerCalls, 0,
				"a status probe must never mutate Background Items registration")
		}
	}

	/// A Background Items transition during filesystem health cannot publish ready.
	func testModernGuardianObservationRechecksAuthorizationAfterHealth() {
		guard #available(macOS 13.0, *) else { return }
		let service = ScriptedModernGuardianService(status: .enabled)
		let observed = observeModernRemapGuardianRegistration(
			service: service,
			guardianHealth: {
				service.status = .requiresApproval
				return true
			}
		)

		XCTAssertEqual(observed, .requiresApproval)
		XCTAssertEqual(service.registerCalls, 0)
	}

	/// Current approval state is checked independently of legacy guardian health.
	func testModernGuardianActivationAuthorizationFailsClosed() {
		guard #available(macOS 13.0, *) else { return }
		for (status, expected) in [
			(SMAppService.Status.enabled, true),
			(SMAppService.Status.notRegistered, true),
			(SMAppService.Status.notFound, true),
			(SMAppService.Status.requiresApproval, false),
		] {
			let service = ScriptedModernGuardianService(status: status)
			XCTAssertEqual(
				modernGuardianActivationIsAuthorized(service: service),
				expected
			)
			XCTAssertEqual(service.registerCalls, 0)
		}
	}

	/// ARM consults current authorization before publishing any durable record.
	func testGuardianRegistrationRefusesUnapprovedActivationBeforePublication() {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-denied-arm-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		var authorizationCalls = 0
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: {
				authorizationCalls += 1
				return false
			}
		)

		XCTAssertFalse(registration.arm())
		XCTAssertEqual(authorizationCalls, 1)
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: paths.recordPath(token: token)
		))
	}

	/// ARM rechecks approval after the guardian ACK and retires the pending record.
	func testGuardianRegistrationRefusesApprovalLostDuringArmHandshake() {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-revoked-arm-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.startObservingForTesting() == true)
		var authorizationCalls = 0
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: {
				authorizationCalls += 1
				return authorizationCalls == 1
			}
		)

		XCTAssertFalse(registration.arm())
		XCTAssertEqual(authorizationCalls, 2)
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: paths.recordPath(token: token)
		))
		runtime = nil
	}

	/// A live registration rechecks approval before reporting or transporting authority.
	func testGuardianRegistrationRevokesAuthorizationFromLiveTransport() {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-revoked-transport-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.startObservingForTesting() == true)
		var authorized = true
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { authorized }
		)
		XCTAssertTrue(registration.arm())

		authorized = false
		XCTAssertFalse(registration.guardianStillPresent())
		XCTAssertFalse(registration.beginLiveTransport())

		registration.cancelBeforeActivation()
		runtime = nil
	}

	/// Login Items opens only after an explicit request that still needs approval.
	func testModernGuardianSettingsOpenOnlyForCurrentApprovalRequirement() {
		guard #available(macOS 13.0, *) else { return }
		for (status, expected, expectedOpenCalls) in [
			(SMAppService.Status.requiresApproval,
				RemapGuardianSettingsResult.opened, 1),
			(SMAppService.Status.enabled,
				RemapGuardianSettingsResult.notRequired, 0),
			(SMAppService.Status.notRegistered,
				RemapGuardianSettingsResult.notRequired, 0),
			(SMAppService.Status.notFound,
				RemapGuardianSettingsResult.notRequired, 0),
		] {
			let service = ScriptedModernGuardianService(status: status)
			var openCalls = 0
			let result = openModernRemapGuardianSettingsIfRequired(
				service: service,
				openSettings: { openCalls += 1 }
			)
			XCTAssertEqual(result, expected)
			XCTAssertEqual(openCalls, expectedOpenCalls)
			XCTAssertEqual(service.registerCalls, 0,
				"opening settings must never mutate Background Items registration")
		}
	}

	/// The read-only status role accepts only the exact launcher vnode and argv.
	func testGuardianStatusInvocationRequiresExactLauncherIdentity() {
		let arguments = ["/Applications/ErgoptiPlus", kRemapGuardianStatusFlag]
		let environment = [
			"ERGOPTI_LAUNCHER_DEVICE": "11",
			"ERGOPTI_LAUNCHER_INODE": "22",
		]
		let matchingIdentity = LeaseExecutableIdentity(device: "11", inode: "22")
		XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: arguments))
		XCTAssertTrue(validatedGuardianStatusInvocation(
			arguments: arguments,
			executablePath: "/Applications/ErgoptiPlus",
			environment: environment,
			identityReader: { _ in matchingIdentity }
		))
		for invalidArguments in [
			["/Applications/ErgoptiPlus"],
			arguments + ["unexpected"],
			["/Applications/ErgoptiPlus", "--unknown"],
		] {
			XCTAssertFalse(validatedGuardianStatusInvocation(
				arguments: invalidArguments,
				executablePath: "/Applications/ErgoptiPlus",
				environment: environment,
				identityReader: { _ in matchingIdentity }
			))
		}
		XCTAssertFalse(validatedGuardianStatusInvocation(
			arguments: arguments,
			executablePath: "/Applications/ErgoptiPlus",
			environment: environment,
			identityReader: { _ in LeaseExecutableIdentity(device: "11", inode: "23") }
		))
		XCTAssertFalse(validatedGuardianStatusInvocation(
			arguments: arguments,
			executablePath: "/Applications/ErgoptiPlus",
			environment: [:],
			identityReader: { _ in matchingIdentity }
		))
	}

	/// The explicit settings role also rejects every non-exact launcher invocation.
	func testGuardianSettingsInvocationRequiresExactLauncherIdentity() {
		let arguments = ["/Applications/ErgoptiPlus", kOpenRemapGuardianSettingsFlag]
		let environment = [
			"ERGOPTI_LAUNCHER_DEVICE": "11",
			"ERGOPTI_LAUNCHER_INODE": "22",
		]
		let matchingIdentity = LeaseExecutableIdentity(device: "11", inode: "22")
		XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: arguments))
		XCTAssertTrue(validatedGuardianSettingsInvocation(
			arguments: arguments,
			executablePath: "/Applications/ErgoptiPlus",
			environment: environment,
			identityReader: { _ in matchingIdentity }
		))
		for invalidArguments in [
			["/Applications/ErgoptiPlus"],
			arguments + ["unexpected"],
			["/Applications/ErgoptiPlus", kRemapGuardianStatusFlag],
		] {
			XCTAssertFalse(validatedGuardianSettingsInvocation(
				arguments: invalidArguments,
				executablePath: "/Applications/ErgoptiPlus",
				environment: environment,
				identityReader: { _ in matchingIdentity }
			))
		}
		XCTAssertFalse(validatedGuardianSettingsInvocation(
			arguments: arguments,
			executablePath: "/Applications/ErgoptiPlus",
			environment: environment,
			identityReader: { _ in LeaseExecutableIdentity(device: "11", inode: "23") }
		))
		XCTAssertFalse(validatedGuardianSettingsInvocation(
			arguments: arguments,
			executablePath: "/Applications/ErgoptiPlus",
			environment: [:],
			identityReader: { _ in matchingIdentity }
		))
	}

	/// A healthy exact legacy job is reused without any destructive handoff.
	func testLegacyRegistrationPreservesAlreadyRunningGuardian() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-legacy-guardian-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: home,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
		try FileManager.default.createDirectory(
			at: launchAgents,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
		let expectedPlist = try XCTUnwrap(legacyGuardianPlist(
			executablePath: executable
		).data(using: .utf8))
		try assertLegacyGuardianPlistContract(expectedPlist, executablePath: executable)
		let plistURL = launchAgents.appendingPathComponent(kRemapGuardianPlistName)
		try expectedPlist.write(to: plistURL)
		let runner = ScriptedGuardianLaunchctlRunner(results: [true])

		XCTAssertTrue(ensureLegacyRemapGuardianRegistered(
			executablePath: executable,
			runner: runner,
			homeDirectory: home.path,
			guardianHealth: { _ in true }
		))
		let serviceTarget = "gui/\(getuid())/\(kRemapGuardianLabel)"
		XCTAssertEqual(runner.calls, [["print", serviceTarget]])
		XCTAssertEqual(try Data(contentsOf: plistURL), expectedPlist,
			"a healthy current guardian must not rewrite its registration")
	}

	/// A loaded legacy label with an obsolete app path is replaced, never trusted.
	func testLegacyRegistrationReplacesStaleExecutablePathBeforeReady() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-legacy-stale-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
		try FileManager.default.createDirectory(
			at: launchAgents,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let staleExecutable = "/Applications/ErgoptiPlus-old.app/Contents/MacOS/ErgoptiPlus"
		let currentExecutable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
		let plistURL = launchAgents.appendingPathComponent(kRemapGuardianPlistName)
		try XCTUnwrap(legacyGuardianPlist(
			executablePath: staleExecutable
		).data(using: .utf8)).write(to: plistURL)
		let runner = ScriptedGuardianLaunchctlRunner(
			results: [true, true, true, true]
		)

		XCTAssertTrue(ensureLegacyRemapGuardianRegistered(
			executablePath: currentExecutable,
			runner: runner,
			homeDirectory: home.path,
			guardianHealth: { _ in true }
		))
		let domain = "gui/\(getuid())"
		let serviceTarget = domain + "/" + kRemapGuardianLabel
		XCTAssertEqual(runner.calls, [
			["print", serviceTarget],
			["bootout", serviceTarget],
			["bootstrap", domain, plistURL.path],
			["print", serviceTarget],
		])
		let installedPlist = try Data(contentsOf: plistURL)
		try assertLegacyGuardianPlistContract(
			installedPlist,
			executablePath: currentExecutable
		)
		XCTAssertFalse(runner.calls.flatMap { $0 }.contains(where: {
			$0.localizedCaseInsensitiveContains("karabiner")
		}), "legacy replacement may target only the ErgoptiPlus LaunchAgent label")
	}

	/// Proves the real handshake publishes and locks the record before accepting ACK.
	func testGuardianRegistrationPublishesLockedDurableRecordBeforeArmed() throws {
		let fixture = try makeAbandonedGuardianRecord(
			token: "abcdefabcdefabcdefabcdefabcdefab"
		)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		// The fixture helper models abandonment; remove it so the registration can
		// publish the same unique token through its atomic locked-temp path.
		try FileManager.default.removeItem(
			atPath: fixture.paths.recordPath(token: fixture.record.token)
		)

		let singleton = Darwin.open(
			fixture.paths.singletonLock,
			O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
			S_IRUSR | S_IWUSR
		)
		XCTAssertGreaterThanOrEqual(singleton, 0)
		guard singleton >= 0 else { return }
		defer { Darwin.close(singleton) }
		XCTAssertEqual(ergoptiFlock(singleton, LOCK_EX | LOCK_NB), 0)
		let activationGate = Darwin.open(
			fixture.paths.activationGate,
			O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
			S_IRUSR | S_IWUSR
		)
		XCTAssertGreaterThanOrEqual(activationGate, 0)
		guard activationGate >= 0 else { return }
		defer { Darwin.close(activationGate) }
		var activationAttributes = stat()
		XCTAssertEqual(Darwin.fstat(activationGate, &activationAttributes), 0)
		XCTAssertTrue(replaceGuardianData(
			try XCTUnwrap(LeaseGuardianSingletonRecord(
				generation: guardianGeneration,
				state: .active,
				activationDevice: Int64(activationAttributes.st_dev),
				activationInode: UInt64(activationAttributes.st_ino)
			).encoded),
			descriptor: singleton
		))

		let identity = LeaseIdentity(
			cliPath: kCanonicalKarabinerCLIPath,
			token: fixture.record.token,
			modeName: "ergopti_mode_\(fixture.record.token)",
			revokedName: "ergopti_revoked_\(fixture.record.token)",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let registration = LeaseGuardianRegistration(
			identity: identity,
			paths: fixture.paths,
			activationAuthorized: { true }
		)
		let observerFinished = DispatchSemaphore(value: 0)
		DispatchQueue.global(qos: .userInitiated).async {
			defer { observerFinished.signal() }
			let recordURL = URL(fileURLWithPath: fixture.paths.recordPath(token: identity.token))
			let deadline = ProcessInfo.processInfo.systemUptime + 2
			while ProcessInfo.processInfo.systemUptime < deadline {
				guard let data = try? Data(contentsOf: recordURL),
					let observed = LeaseGuardianRecord.parse(data)
				else {
					usleep(5_000)
					continue
				}
				let descriptor = Darwin.open(recordURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
				guard descriptor >= 0 else { return }
				defer { Darwin.close(descriptor) }
				guard ergoptiFlock(descriptor, LOCK_EX | LOCK_NB) == -1,
					errno == EWOULDBLOCK,
					let acknowledgement = observed.acknowledgement(
						guardianGeneration: self.guardianGeneration
					)
				else { return }
				try? acknowledgement.write(
					to: URL(fileURLWithPath: fixture.paths.acknowledgementPath(token: identity.token)),
					options: .atomic
				)
				return
			}
		}

		XCTAssertTrue(registration.arm())
		XCTAssertEqual(observerFinished.wait(timeout: .now() + 2), .success)
		XCTAssertEqual(registration.childCloseDescriptors.count, 3)
		registration.cancelBeforeActivation()
	}

	/// A duplicate token cannot delete the first owner's record or exact ACK.
	func testGuardianRegistrationCollisionPreservesExistingRecordAndAcknowledgement() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let acknowledgement = try XCTUnwrap(fixture.record.acknowledgement(
			guardianGeneration: guardianGeneration
		))
		try acknowledgement.write(to: URL(
			fileURLWithPath: fixture.paths.acknowledgementPath(token: token)
		))
		var before = stat()
		XCTAssertEqual(fixture.paths.recordPath(token: token).withCString {
			Darwin.lstat($0, &before)
		}, 0)

		let collision = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: fixture.paths,
			activationAuthorized: { true }
		)
		XCTAssertFalse(collision.arm())

		var after = stat()
		XCTAssertEqual(fixture.paths.recordPath(token: token).withCString {
			Darwin.lstat($0, &after)
		}, 0)
		XCTAssertEqual(before.st_dev, after.st_dev)
		XCTAssertEqual(before.st_ino, after.st_ino)
		XCTAssertEqual(
			try Data(contentsOf: URL(fileURLWithPath: fixture.paths.recordPath(token: token))),
			try XCTUnwrap(fixture.record.encoded)
		)
		XCTAssertEqual(
			try Data(contentsOf: URL(
				fileURLWithPath: fixture.paths.acknowledgementPath(token: token)
			)),
			acknowledgement
		)
	}

	/// A visible ACK whose directory entry was not durably synced is removed again.
	func testGuardianAcknowledgementRollsBackAfterPostRenameDirectorySyncFailure() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-ack-rollback-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		defer { try? FileManager.default.removeItem(at: directory) }
		let acknowledgement = directory.appendingPathComponent("exact.armed")
		var directorySyncCalls = 0

		XCTAssertFalse(writeGuardianFileAtomically(
			data: Data("ack".utf8),
			path: acknowledgement.path,
			directory: directory.path,
			directorySync: { _ in
				directorySyncCalls += 1
				return directorySyncCalls > 1
			}
		))
		XCTAssertEqual(directorySyncCalls, 2,
			"publication failure must be followed by a best-effort unlink sync")
		XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgement.path),
			"a rejected but visible ACK would let ARM authorize an unsafe lease")
	}

	/// ARM cannot observe an ACK rejected after its rename became visible.
	func testRegistrationCannotArmFromPostRenameDirectorySyncFailure() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-ack-arm-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let acknowledgementVisible = DispatchSemaphore(value: 0)
		let rejectPublication = DispatchSemaphore(value: 0)
		defer { rejectPublication.signal() }
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			acknowledgementWriter: { data, path, directory in
				var syncCalls = 0
				return writeGuardianFileAtomically(
					data: data,
					path: path,
					directory: directory,
					directorySync: { _ in
						syncCalls += 1
						if syncCalls == 1 {
							acknowledgementVisible.signal()
							_ = rejectPublication.wait(timeout: .now() + 5)
						}
						return syncCalls > 1
					}
				)
			},
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.startObservingForTesting() == true)
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { true }
		)
		let armResult = GuardianStartupRecorder()
		let armFinished = DispatchSemaphore(value: 0)
		DispatchQueue.global(qos: .userInitiated).async {
			armResult.store(registration.arm())
			armFinished.signal()
		}

		XCTAssertEqual(acknowledgementVisible.wait(timeout: .now() + 2), .success)
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: paths.acknowledgementPath(token: token)
		), "the repro must pause after rename made the rejected ACK visible")
		XCTAssertEqual(armFinished.wait(timeout: .now() + 0.2), .timedOut,
			"ARM must not cross the gate while ACK durability is unresolved")
		rejectPublication.signal()
		XCTAssertEqual(armFinished.wait(timeout: .now() + 4), .success)
		XCTAssertEqual(armResult.snapshot(), false,
			"ARM must time out rather than consume a non-durable visible ACK")
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: paths.acknowledgementPath(token: token)
		))
		runtime = nil
	}

	/// One token's ACK fsync never blocks another armed token's live transport.
	func testGuardianAcknowledgementDurabilityLockIsTokenLocal() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-ack-token-local-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let tokenB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		let tokenBAcknowledgementVisible = DispatchSemaphore(value: 0)
		let syncTokenBAcknowledgement = DispatchSemaphore(value: 0)
		defer { syncTokenBAcknowledgement.signal() }
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			acknowledgementWriter: { data, path, directory in
				guard path == paths.acknowledgementPath(token: tokenB) else {
					return writeGuardianFileAtomically(
						data: data,
						path: path,
						directory: directory
					)
				}
				return writeGuardianFileAtomically(
					data: data,
					path: path,
					directory: directory,
					directorySync: { directoryPath in
						tokenBAcknowledgementVisible.signal()
						_ = syncTokenBAcknowledgement.wait(timeout: .now() + 5)
						let descriptor = Darwin.open(
							directoryPath,
							O_RDONLY | O_CLOEXEC | O_NOFOLLOW
						)
						guard descriptor >= 0 else { return false }
						defer { Darwin.close(descriptor) }
						return Darwin.fsync(descriptor) == 0
					}
				)
			},
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.startObservingForTesting() == true)
		let registrationA = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { true }
		)
		XCTAssertTrue(registrationA.arm())
		XCTAssertTrue(registrationA.beginLiveTransport())
		registrationA.endLiveTransport()
		let identityB = LeaseIdentity(
			cliPath: kCanonicalKarabinerCLIPath,
			token: tokenB,
			modeName: "ergopti_mode_\(tokenB)",
			revokedName: "ergopti_revoked_\(tokenB)",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let registrationB = LeaseGuardianRegistration(
			identity: identityB,
			paths: paths,
			activationAuthorized: { true }
		)
		let armBResult = GuardianStartupRecorder()
		let armBFinished = DispatchSemaphore(value: 0)
		DispatchQueue.global(qos: .userInitiated).async {
			armBResult.store(registrationB.arm())
			armBFinished.signal()
		}
		XCTAssertEqual(tokenBAcknowledgementVisible.wait(timeout: .now() + 2), .success)
		let liveAResult = GuardianStartupRecorder()
		let liveAFinished = DispatchSemaphore(value: 0)
		DispatchQueue.global(qos: .userInitiated).async {
			liveAResult.store(registrationA.beginLiveTransport())
			liveAFinished.signal()
		}

		XCTAssertEqual(liveAFinished.wait(timeout: .now() + 0.2), .success,
			"token B's visible-but-locked ACK must not serialize token A")
		XCTAssertEqual(liveAResult.snapshot(), true)
		registrationA.endLiveTransport()
		XCTAssertEqual(armBFinished.wait(timeout: .now() + 0.1), .timedOut)

		syncTokenBAcknowledgement.signal()
		XCTAssertEqual(armBFinished.wait(timeout: .now() + 2), .success)
		XCTAssertEqual(armBResult.snapshot(), true)
		registrationB.cancelBeforeActivation()
		registrationA.cancelBeforeActivation()
		runtime = nil
	}

	/// A crash-left ACK staging file for the same record nonce cannot block restart.
	func testGuardianRestartRecoversStaleAcknowledgementTemporary() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let staleTemporary = fixture.paths.acknowledgements
			+ "/." + fixture.record.nonce + ".tmp"
		try Data("partial".utf8).write(to: URL(fileURLWithPath: staleTemporary))
		let owner = Darwin.open(
			fixture.paths.recordPath(token: token),
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0)
		let executor = GuardianRecordingLeaseCLIExecutor()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		let acknowledgement = try Data(contentsOf: URL(
			fileURLWithPath: fixture.paths.acknowledgementPath(token: token)
		))
		XCTAssertEqual(
			acknowledgement,
			fixture.record.acknowledgement(
				guardianGeneration: guardianGeneration
			)
		)

		let retired = LeaseGuardianRecord(
			token: fixture.record.token,
			nonce: fixture.record.nonce,
			ownerPID: fixture.record.ownerPID,
			state: .retired
		)
		XCTAssertTrue(replaceGuardianData(
			try XCTUnwrap(retired.encoded),
			descriptor: owner
		))
		XCTAssertEqual(Darwin.unlink(fixture.paths.recordPath(token: token)), 0)
		Darwin.close(owner)
		runtime = nil
	}

	/// A lexically earlier unarmed record cannot consume an active lease's slot.
	func testGuardianRestartPrioritizesAcknowledgedRecordsBeyondUnarmedCap() throws {
		let unarmedToken = "00000000000000000000000000000000"
		let acknowledgedTokens = [
			"00000000000000000000000000000001",
			"00000000000000000000000000000002",
		]
		let fixture = try makeAbandonedGuardianRecord(token: unarmedToken)
		var owners: [String: Int32] = [:]
		var runtime: RemapLeaseGuardianRuntime?
		defer {
			for descriptor in owners.values { Darwin.close(descriptor) }
			runtime = nil
			try? FileManager.default.removeItem(at: fixture.home)
		}

		var records = [fixture.record]
		for (index, acknowledgedToken) in acknowledgedTokens.enumerated() {
			let record = LeaseGuardianRecord(
				token: acknowledgedToken,
				nonce: String(format: "%032x", index + 100),
				ownerPID: getpid(),
				state: .live
			)
			try XCTUnwrap(record.encoded).write(to: URL(
				fileURLWithPath: fixture.paths.recordPath(token: acknowledgedToken)
			))
			try XCTUnwrap(record.acknowledgement(
				guardianGeneration: guardianGeneration
			)).write(to: URL(
				fileURLWithPath: fixture.paths.acknowledgementPath(token: acknowledgedToken)
			))
			records.append(record)
		}
		for record in records {
			let descriptor = Darwin.open(
				fixture.paths.recordPath(token: record.token),
				O_RDWR | O_CLOEXEC | O_NOFOLLOW
			)
			XCTAssertGreaterThanOrEqual(descriptor, 0)
			guard descriptor >= 0 else { return }
			XCTAssertEqual(ergoptiFlock(descriptor, LOCK_EX | LOCK_NB), 0)
			owners[record.token] = descriptor
		}

		let executor = GuardianRecordingLeaseCLIExecutor()
		runtime = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			maximumUnacknowledgedRecords: 1,
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		let targetToken = try XCTUnwrap(acknowledgedTokens.last)
		let targetOwner = try XCTUnwrap(owners.removeValue(forKey: targetToken))
		Darwin.close(targetOwner)
		let expected = "{\"ergopti_mode_\(targetToken)\":0,"
			+ "\"ergopti_revoked_\(targetToken)\":1}"
		let fenceDeadline = ProcessInfo.processInfo.systemUptime + 2
		while executor.snapshot().payloads.filter({ $0 == expected }).count < 2
			&& ProcessInfo.processInfo.systemUptime < fenceDeadline {
			usleep(kSiblingProgressPollMicroseconds)
		}
		XCTAssertEqual(
			executor.snapshot().payloads.filter { $0 == expected }.count,
			2,
			"every already-ACKed lease must remain watched beyond the unarmed cap"
		)

		for record in records where record.token != targetToken {
			guard let descriptor = owners.removeValue(forKey: record.token) else { continue }
			let retired = LeaseGuardianRecord(
				token: record.token,
				nonce: record.nonce,
				ownerPID: record.ownerPID,
				state: .retired
			)
			if let encoded = retired.encoded {
				_ = replaceGuardianData(encoded, descriptor: descriptor)
			}
			_ = Darwin.unlink(fixture.paths.recordPath(token: record.token))
			Darwin.close(descriptor)
		}
		usleep(100_000)
		runtime = nil
	}

	/// Replays one unlocked durable record as two exact tombstone transports.
	func testGuardianFencesAbandonedRecord() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let executor = GuardianRecordingLeaseCLIExecutor()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: failUnexpectedGuardianTermination,
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))

		let snapshot = executor.snapshot()
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		XCTAssertEqual(snapshot.payloads, [exactFence, exactFence])
		XCTAssertEqual(snapshot.paths, [kCanonicalKarabinerCLIPath, kCanonicalKarabinerCLIPath])
		XCTAssertTrue(snapshot.descriptors.allSatisfy { !$0.isEmpty },
			"every guardian CLI child must explicitly close inherited lease locks")
		runtime = nil
	}

	/// Force Quit of the exact LIVE owner releases flock and triggers the fence.
	func testGuardianFencesLiveOwnerAfterSIGKILL() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let owner = try startPOSIXTestHelper(
			mode: "hold-exclusive",
			path: fixture.paths.recordPath(token: token)
		)
		var ownerStopped = false
		defer {
			if !ownerStopped {
				stopExactGuardianTestProcess(owner.process, completion: owner.completion)
			}
		}
		let readyDescriptor = owner.output.fileHandleForReading.fileDescriptor
		var readyPoll = pollfd(fd: readyDescriptor, events: Int16(POLLIN), revents: 0)
		guard Darwin.poll(&readyPoll, 1, 2_000) > 0 else {
			XCTFail("the exact LIVE owner did not acquire flock within its bound")
			return
		}
		var childArmed: UInt8 = 0
		XCTAssertEqual(Darwin.read(readyDescriptor, &childArmed, 1), 1)
		guard childArmed == 1 else {
			XCTFail("the exact LIVE owner failed to acquire its record descriptor")
			return
		}

		let executor = GuardianRecordingLeaseCLIExecutor()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: fixture.paths.acknowledgementPath(token: token)
		))
		XCTAssertEqual(Darwin.kill(owner.process.processIdentifier, SIGKILL), 0)
		XCTAssertEqual(owner.completion.wait(timeout: .now() + 1), .success)
		ownerStopped = true
		XCTAssertEqual(owner.process.terminationReason, .uncaughtSignal)
		XCTAssertEqual(owner.process.terminationStatus, SIGKILL)
		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		XCTAssertEqual(executor.snapshot().payloads, [exactFence, exactFence])
		runtime = nil
	}

	/// Deleting a live pathname cannot impersonate the owner's fenced retirement.
	func testGuardianFencesExternallyUnlinkedLiveRecord() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let owner = Darwin.open(
			fixture.paths.recordPath(token: token),
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0)
		let executor = GuardianRecordingLeaseCLIExecutor()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: failUnexpectedGuardianTermination,
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: fixture.paths.acknowledgementPath(token: token)
		))
		XCTAssertEqual(Darwin.unlink(fixture.paths.recordPath(token: token)), 0)
		Darwin.close(owner)
		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		XCTAssertEqual(executor.snapshot().payloads, [exactFence, exactFence])
		runtime = nil
	}

	/// A restart recovers a detached live token from its durable ARMED journal.
	func testGuardianRestartFencesOrphanedAcknowledgementAfterRecordLoss() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let oldGeneration = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		try XCTUnwrap(fixture.record.acknowledgement(
			guardianGeneration: oldGeneration
		)).write(to: URL(
			fileURLWithPath: fixture.paths.acknowledgementPath(token: token)
		))
		XCTAssertEqual(Darwin.unlink(fixture.paths.recordPath(token: token)), 0)

		let executor = GuardianRecordingLeaseCLIExecutor(
			results: [.success, .spawnFailed(EIO), .success, .success],
			blockAfterCall: 3
		)
		defer { executor.resumeBlockedCall() }
		var replacement: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(replacement?.processRecordsOnceForTesting() == true)
		XCTAssertTrue(executor.waitForBlockedCall(timeout: 2))
		let acknowledgementPath = fixture.paths.acknowledgementPath(token: token)
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: acknowledgementPath),
			"a failed intermediate fence must retain the orphan recovery journal"
		)
		executor.resumeBlockedCall()
		let transportDeadline = ProcessInfo.processInfo.systemUptime + 2
		while executor.snapshot().payloads.count < 4
			&& ProcessInfo.processInfo.systemUptime < transportDeadline {
			usleep(kSiblingProgressPollMicroseconds)
		}
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		XCTAssertEqual(executor.snapshot().payloads, [
			exactFence,
			exactFence,
			exactFence,
			exactFence,
		])
		let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2
		while FileManager.default.fileExists(atPath: acknowledgementPath)
			&& ProcessInfo.processInfo.systemUptime < cleanupDeadline {
			usleep(kSiblingProgressPollMicroseconds)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgementPath),
			"the exact orphan journal may be removed only after repeated fencing")
		replacement = nil
	}

	/// Only the durable marker written under the owner's lock suppresses refencing.
	func testGuardianSkipsExplicitlyRetiredRecord() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let owner = Darwin.open(
			fixture.paths.recordPath(token: token),
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0)
		let executor = GuardianRecordingLeaseCLIExecutor()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: failUnexpectedGuardianTermination,
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)

		let retired = LeaseGuardianRecord(
			token: fixture.record.token,
			nonce: fixture.record.nonce,
			ownerPID: fixture.record.ownerPID,
			state: .retired
		)
		XCTAssertTrue(replaceGuardianData(
			try XCTUnwrap(retired.encoded),
			descriptor: owner
		))
		XCTAssertEqual(Darwin.unlink(fixture.paths.recordPath(token: token)), 0)
		Darwin.close(owner)

		let acknowledgement = fixture.paths.acknowledgementPath(token: token)
		let deadline = ProcessInfo.processInfo.systemUptime + 2
		while FileManager.default.fileExists(atPath: acknowledgement)
			&& ProcessInfo.processInfo.systemUptime < deadline {
			usleep(kSiblingProgressPollMicroseconds)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgement))
		XCTAssertTrue(executor.snapshot().payloads.isEmpty,
			"a canonical RETIRED record was already fenced by its exact owner")
		runtime = nil
	}

	/// A canonical RETIRED payload from a different nonce cannot impersonate its owner.
	func testGuardianFencesRetirementFromDifferentRecordNonce() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let owner = Darwin.open(
			fixture.paths.recordPath(token: token),
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0)
		let executor = GuardianRecordingLeaseCLIExecutor()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: failUnexpectedGuardianTermination,
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		let forgedRetirement = LeaseGuardianRecord(
			token: fixture.record.token,
			nonce: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			ownerPID: fixture.record.ownerPID,
			state: .retired
		)
		XCTAssertTrue(replaceGuardianData(
			try XCTUnwrap(forgedRetirement.encoded),
			descriptor: owner
		))
		XCTAssertEqual(Darwin.unlink(fixture.paths.recordPath(token: token)), 0)
		Darwin.close(owner)

		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		XCTAssertEqual(executor.snapshot().payloads, [exactFence, exactFence])
		runtime = nil
	}

	/// Disabling the Background Item revokes live leases before its process exits.
	func testGuardianTerminationFencesLockedActiveRecordBeforeExit() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let owner = Darwin.open(
			fixture.paths.recordPath(token: token),
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0)
		let executor = GuardianRecordingLeaseCLIExecutor()
		let termination = GuardianTerminationRecorder()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: termination.terminate
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		runtime?.terminateForTesting()
		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))
		XCTAssertEqual(
			termination.wait(timeout: 2),
			LeaseWorkerExit.success.rawValue,
			"the guardian may exit only after every active token is tombstoned"
		)
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		XCTAssertEqual(executor.snapshot().payloads, [exactFence, exactFence])
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0,
			"termination fencing must not wait for or take the active owner's lock")

		let retired = LeaseGuardianRecord(
			token: fixture.record.token,
			nonce: fixture.record.nonce,
			ownerPID: fixture.record.ownerPID,
			state: .retired
		)
		XCTAssertTrue(replaceGuardianData(
			try XCTUnwrap(retired.encoded),
			descriptor: owner
		))
		XCTAssertEqual(Darwin.unlink(fixture.paths.recordPath(token: token)), 0)
		Darwin.close(owner)
		runtime = nil
	}

	/// A persistent drain-lock error fences repeatedly but cannot authorize exit.
	func testGuardianPermanentDrainErrorFencesUntilExactGateCanBeTaken() throws {
		let fixture = try makeAbandonedGuardianRecord(token: token)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let owner = Darwin.open(
			fixture.paths.recordPath(token: token),
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(owner, 0)
		guard owner >= 0 else { return }
		XCTAssertEqual(ergoptiFlock(owner, LOCK_EX | LOCK_NB), 0)
		let executor = GuardianRecordingLeaseCLIExecutor()
		let termination = GuardianTerminationRecorder()
		var gateCalls = 0
		var simulatedUptime: TimeInterval = 0
		var retryDelays: [useconds_t] = []
		let firstGateFailurePaused = DispatchSemaphore(value: 0)
		let continueGateFailures = DispatchSemaphore(value: 0)
		defer { continueGateFailures.signal() }
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: executor,
			terminateProcess: termination.terminate,
			activationGateLocker: { descriptor in
				gateCalls += 1
				if gateCalls <= 13 { return .failed(EINVAL) }
				return lockGuardianActivationGate(descriptor)
			},
			activationGateRetrySleep: { delay in
				retryDelays.append(delay)
				simulatedUptime += Double(delay) / 1_000_000
				if retryDelays.count == 1 {
					firstGateFailurePaused.signal()
					_ = continueGateFailures.wait(timeout: .now() + 5)
				}
			},
			terminationUptime: { simulatedUptime }
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		runtime?.terminateForTesting()
		XCTAssertEqual(firstGateFailurePaused.wait(timeout: .now() + 2), .success)
		let singletonProbe = Darwin.open(
			fixture.paths.singletonLock,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(singletonProbe, 0)
		if singletonProbe >= 0 {
			XCTAssertFalse(guardianSingletonIsExclusivelyHeld(descriptor: singletonProbe),
				"a broken drain primitive must immediately invalidate singleton authority")
			Darwin.close(singletonProbe)
		}
		let staleData = try Data(contentsOf: URL(fileURLWithPath: fixture.paths.singletonLock))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(staleData)?.state, .active,
			"stale ACTIVE bytes are safe only while no process owns their singleton lock")
		continueGateFailures.signal()
		XCTAssertEqual(
			termination.wait(timeout: 3),
			LeaseWorkerExit.success.rawValue
		)
		let exactFence = "{\"ergopti_mode_\(token)\":0,\"ergopti_revoked_\(token)\":1}"
		let payloads = executor.snapshot().payloads
		XCTAssertEqual(gateCalls, 14)
		XCTAssertEqual(retryDelays.count, 13)
		XCTAssertEqual(Array(retryDelays.prefix(2)), [10_000, 10_000])
		XCTAssertTrue(retryDelays.dropFirst(2).allSatisfy { $0 == 100_000 })
		XCTAssertEqual(payloads.count, 6,
			"only two one-second-spaced emergency pairs plus the final pair are allowed")
		XCTAssertTrue(payloads.allSatisfy { $0 == exactFence })
		let finalSingletonProbe = Darwin.open(
			fixture.paths.singletonLock,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		XCTAssertGreaterThanOrEqual(finalSingletonProbe, 0)
		if finalSingletonProbe >= 0 {
			XCTAssertTrue(guardianSingletonIsExclusivelyHeld(
				descriptor: finalSingletonProbe
			), "successful drain recovery must reacquire singleton authority")
			Darwin.close(finalSingletonProbe)
		}
		let drainingData = try Data(contentsOf: URL(
			fileURLWithPath: fixture.paths.singletonLock
		))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(drainingData)?.state, .draining)

		let retired = LeaseGuardianRecord(
			token: fixture.record.token,
			nonce: fixture.record.nonce,
			ownerPID: fixture.record.ownerPID,
			state: .retired
		)
		XCTAssertTrue(replaceGuardianData(
			try XCTUnwrap(retired.encoded),
			descriptor: owner
		))
		XCTAssertEqual(Darwin.unlink(fixture.paths.recordPath(token: token)), 0)
		Darwin.close(owner)
		runtime = nil
	}

	/// A completed live transport releases ordering without severing identity.
	func testRegistrationStillRecognizesHealthyGuardianAfterActivationCompletes() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-presence-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: failUnexpectedGuardianTermination,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.startObservingForTesting() == true)
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { true }
		)
		XCTAssertTrue(registration.arm())
		XCTAssertTrue(registration.guardianStillPresent())
		XCTAssertTrue(registration.beginLiveTransport())

		registration.endLiveTransport()

		XCTAssertTrue(
			registration.guardianStillPresent(),
			"unlocking the activation gate must retain its exact-generation identity descriptor"
		)
		runtime = nil
		XCTAssertFalse(
			registration.guardianStillPresent(),
			"the retained descriptor must still detect loss of the exact singleton owner"
		)
		registration.retireAfterFence()
	}

	/// A replacement guardian drains an old live transport before publishing ACTIVE.
	func testReplacementGuardianWaitsForPriorGenerationTransportGate() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-replacement-gate-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let priorGeneration = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		var priorRuntime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: failUnexpectedGuardianTermination,
			generation: priorGeneration
		)
		XCTAssertTrue(priorRuntime?.startObservingForTesting() == true)
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { true }
		)
		XCTAssertTrue(registration.arm())
		XCTAssertTrue(registration.beginLiveTransport())
		priorRuntime = nil

		let singletonProbeEntered = DispatchSemaphore(value: 0)
		let releaseSingletonProbe = DispatchSemaphore(value: 0)
		defer { releaseSingletonProbe.signal() }
		let replacement = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: GuardianRecordingLeaseCLIExecutor(),
			terminateProcess: failUnexpectedGuardianTermination,
			singletonProbeObserved: {
				singletonProbeEntered.signal()
				_ = releaseSingletonProbe.wait(timeout: .now() + 5)
			},
			generation: guardianGeneration
		)
		let startupFinished = DispatchSemaphore(value: 0)
		let startupResult = GuardianStartupRecorder()
		DispatchQueue.global(qos: .userInitiated).async {
			startupResult.store(replacement.startObservingForTesting())
			startupFinished.signal()
		}

		XCTAssertEqual(singletonProbeEntered.wait(timeout: .now() + 2), .success)
		let staleData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		let staleState = LeaseGuardianSingletonRecord.parse(staleData)
		XCTAssertEqual(staleState?.state, .active,
			"the repro must retain prior-generation ACTIVE bytes during replacement")
		XCTAssertEqual(staleState?.generation, priorGeneration)
		XCTAssertFalse(registration.guardianStillPresent(),
			"a replacement's preflight probe must never impersonate the dead generation")
		XCTAssertEqual(startupFinished.wait(timeout: .now() + 0.2), .timedOut)

		releaseSingletonProbe.signal()
		XCTAssertEqual(startupFinished.wait(timeout: .now() + 0.2), .timedOut,
			"replacement ACTIVE must not overtake the prior generation's live write")
		XCTAssertFalse(registration.guardianStillPresent())
		registration.endLiveTransport()
		XCTAssertEqual(startupFinished.wait(timeout: .now() + 2), .success)
		XCTAssertEqual(startupResult.snapshot(), true)
		let activeData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		let activeState = LeaseGuardianSingletonRecord.parse(activeData)
		XCTAssertEqual(activeState?.state, .active)
		XCTAssertEqual(activeState?.generation, guardianGeneration)
		registration.cancelBeforeActivation()
	}

	/// Drain publication must wait for an already-authorized activation boundary.
	func testGuardianTerminationCannotFenceBeforeArmedActivationCompletes() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-gate-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let executor = GuardianRecordingLeaseCLIExecutor()
		let termination = GuardianTerminationRecorder()
		let gateLocker = ObservedActivationGateLocker()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: executor,
			terminateProcess: termination.terminate,
			activationGateLocker: gateLocker.callAsFunction,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.startObservingForTesting() == true)
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { true }
		)
		XCTAssertTrue(registration.arm())
		XCTAssertTrue(registration.beginLiveTransport())

		runtime?.terminateForTesting()
		XCTAssertEqual(gateLocker.wait(timeout: 2), .success)
		let blockedData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(blockedData)?.state, .active,
			"DRAINING cannot cross an already-authorized activation transport")
		XCTAssertTrue(registration.guardianStillPresent())
		XCTAssertFalse(
			executor.waitForAnyFence(timeout: 0.2),
			"the guardian cannot fence past an accepted activation"
		)

		registration.endLiveTransport()
		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))
		XCTAssertEqual(
			termination.wait(timeout: 2),
			LeaseWorkerExit.success.rawValue
		)
		let drainingData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(drainingData)?.state, .draining)
		XCTAssertFalse(registration.guardianStillPresent())
		registration.retireAfterFence()
		runtime = nil
	}

	/// Every post-READY live transport remains ahead of the guardian's final fence.
	func testGuardianTerminationWaitsForPostReadyLiveTransportAcknowledgement() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-live-gate-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let executor = GuardianRecordingLeaseCLIExecutor()
		let termination = GuardianTerminationRecorder()
		let gateLocker = ObservedActivationGateLocker()
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: executor,
			terminateProcess: termination.terminate,
			activationGateLocker: gateLocker.callAsFunction,
			generation: guardianGeneration
		)
		XCTAssertTrue(runtime?.startObservingForTesting() == true)
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { true }
		)
		XCTAssertTrue(registration.arm())
		XCTAssertTrue(registration.beginLiveTransport())
		registration.endLiveTransport()
		XCTAssertTrue(registration.beginLiveTransport(),
			"a post-READY PING/PAUSE/RESUME must take the same drain gate")

		runtime?.terminateForTesting()
		XCTAssertEqual(gateLocker.wait(timeout: 2), .success)
		let blockedData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(blockedData)?.state, .active,
			"DRAINING cannot cross a post-READY live transport awaiting acknowledgement")
		XCTAssertTrue(registration.guardianStillPresent())
		XCTAssertFalse(executor.waitForAnyFence(timeout: 0.2),
			"the guardian cannot overtake an already-authorized live CLI write")
		XCTAssertNil(termination.wait(timeout: 0.1))

		registration.endLiveTransport()
		XCTAssertTrue(executor.waitForRepeatedFence(timeout: 2))
		XCTAssertEqual(
			termination.wait(timeout: 2),
			LeaseWorkerExit.success.rawValue
		)
		let drainingData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(drainingData)?.state, .draining)
		registration.retireAfterFence()
		runtime = nil
	}

	/// DRAINING cannot linearize between a live ACK's final check and public write.
	func testGuardianCannotPublishDrainingBetweenRevalidationAndLiveAcknowledgement() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-guardian-ack-linearization-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: home) }
		let paths = LeaseGuardianPaths(homeDirectory: home.path)
		let guardianExecutor = GuardianRecordingLeaseCLIExecutor()
		let guardianTermination = GuardianTerminationRecorder()
		let gateLocker = ObservedActivationGateLocker()
		var guardian: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: paths,
			executor: guardianExecutor,
			terminateProcess: guardianTermination.terminate,
			activationGateLocker: gateLocker.callAsFunction,
			generation: guardianGeneration
		)
		XCTAssertTrue(guardian?.startObservingForTesting() == true)
		let registration = LeaseGuardianRegistration(
			identity: makeIdentity(),
			paths: paths,
			activationAuthorized: { true }
		)
		let fixture = try makeExecutableFixture(
			body: "IFS= read -r command <&3 || exit 40\n"
				+ "[ \"$command\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "printf 'READY 1\\n' >&3\n"
				+ "IFS= read -r command <&3 || exit 42\n"
				+ "[ \"$command\" = STOP ] || exit 43\n"
				+ "printf 'FENCED\\n' >&3\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		var parentPipe = [Int32](repeating: -1, count: 2)
		XCTAssertEqual(parentPipe.withUnsafeMutableBufferPointer {
			Darwin.pipe($0.baseAddress!)
		}, 0)
		guard parentPipe[0] >= 0, parentPipe[1] >= 0 else { return }
		// The spawned inner must not retain the writer that this test closes to
		// publish parent EOF; otherwise it waits for STOP while the outer waits
		// forever for an EOF that the inherited descriptor keeps suppressed.
		for descriptor in parentPipe {
			let flags = fcntl(descriptor, F_GETFD)
			XCTAssertGreaterThanOrEqual(flags, 0)
			if flags >= 0 {
				XCTAssertEqual(fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC), 0)
			}
		}
		defer {
			for descriptor in parentPipe where descriptor >= 0 { Darwin.close(descriptor) }
		}
		let publicOutput = fixture.deletingLastPathComponent()
			.appendingPathComponent("public-output")
		let outputDescriptor = Darwin.open(
			publicOutput.path,
			O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
			S_IRUSR | S_IWUSR
		)
		XCTAssertGreaterThanOrEqual(outputDescriptor, 0)
		guard outputDescriptor >= 0 else { return }
		defer { Darwin.close(outputDescriptor) }
		let acknowledgementChecked = DispatchSemaphore(value: 0)
		let publishAcknowledgement = DispatchSemaphore(value: 0)
		defer { publishAcknowledgement.signal() }
		let outerResult = GuardianTerminationRecorder()
		let outer = KarabinerLeaseOuterRuntime(
			identity: makeIdentity(),
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			guardianRegistration: registration,
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: outputDescriptor,
			beforeLiveAcknowledgementPublish: {
				acknowledgementChecked.signal()
				_ = publishAcknowledgement.wait(timeout: .now() + 5)
			}
		)
		DispatchQueue.global(qos: .userInitiated).async {
			outerResult.terminate(outer.run())
		}

		XCTAssertEqual(acknowledgementChecked.wait(timeout: .now() + 2), .success)
		guardian?.terminateForTesting()
		XCTAssertEqual(gateLocker.wait(timeout: 2), .success)
		let blockedData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(blockedData)?.state, .active)
		XCTAssertEqual(try Data(contentsOf: publicOutput), Data(),
			"the test must pause after revalidation but before public READY")
		XCTAssertFalse(guardianExecutor.waitForAnyFence(timeout: 0.2))

		publishAcknowledgement.signal()
		XCTAssertEqual(
			guardianTermination.wait(timeout: 2),
			LeaseWorkerExit.success.rawValue
		)
		XCTAssertEqual(
			try String(contentsOf: publicOutput, encoding: .utf8),
			"READY\n",
			"the accepted live ACK must linearize before DRAINING and its fence"
		)
		let drainingData = try Data(contentsOf: URL(fileURLWithPath: paths.singletonLock))
		XCTAssertEqual(LeaseGuardianSingletonRecord.parse(drainingData)?.state, .draining)
		Darwin.close(parentPipe[1])
		parentPipe[1] = -1
		XCTAssertEqual(outerResult.wait(timeout: 6), LeaseWorkerExit.success.rawValue)
		guardian = nil
	}

	/// The exact-token fence never enumerates or signals unrelated Karabiner peers.
	func testGuardianLeavesPersonalKarabinerProcesses() throws {
		let stockFamilies = [
			"Karabiner-Core-Service",
			"karabiner_grabber",
			"karabiner_console_user_server",
			"Karabiner-Menu",
			"karabiner_observer",
			"VirtualHIDDevice-Daemon",
		]
		var siblings: [ProgressingTestSibling] = []
		do {
			for family in stockFamilies {
				siblings.append(try startUnrelatedSibling(executableName: family))
			}
		} catch {
			siblings.forEach(stopTestOwnedSibling)
			throw error
		}
		defer { siblings.forEach(stopTestOwnedSibling) }
		for (family, sibling) in zip(stockFamilies, siblings) {
			let observedCommand = try observedProcessCommand(processID: sibling.process.processIdentifier)
			XCTAssertEqual(
				URL(fileURLWithPath: observedCommand).lastPathComponent,
				family,
				"the OS process table must expose the stock Karabiner family used by the isolation repro"
			)
		}
		let otherToken = "ffeeddccbbaa99887766554433221100"
		let fixture = try makeAbandonedGuardianRecord(token: otherToken)
		defer { try? FileManager.default.removeItem(at: fixture.home) }
		let cli = try makeExecutableFixture(
			body: "printf '%s\\n' \"$2\" >> \"$0.calls\"\n"
		)
		defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
		let calls = URL(fileURLWithPath: cli.path + ".calls")
		var runtime: RemapLeaseGuardianRuntime? = RemapLeaseGuardianRuntime(
			paths: fixture.paths,
			executor: PosixLeaseCLIExecutor(),
			cliPath: cli.path,
			terminateProcess: failUnexpectedGuardianTermination,
		)
		XCTAssertTrue(runtime?.processRecordsOnceForTesting() == true)
		let fenceDeadline = ProcessInfo.processInfo.systemUptime + 2
		var payloads: [String] = []
		repeat {
			if let text = try? String(contentsOf: calls, encoding: .utf8) {
				payloads = text.split(separator: "\n").map(String.init)
			}
			if payloads.count >= 2 { break }
			usleep(kSiblingProgressPollMicroseconds)
		} while ProcessInfo.processInfo.systemUptime < fenceDeadline
		let exactFence = "{\"ergopti_mode_\(otherToken)\":0,\"ergopti_revoked_\(otherToken)\":1}"
		XCTAssertEqual(payloads, [exactFence, exactFence],
			"the real POSIX executor must invoke only the exact token fence twice")
		for sibling in siblings {
			assertSiblingStillExecuting(
				sibling,
				"personal Karabiner UI, daemons, watchers, and peers must remain user-managed"
			)
		}
		runtime = nil
	}

	/// Reads the command path published by the kernel process table for one child.
	private func observedProcessCommand(processID: pid_t) throws -> String {
		let process = Process()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: "/bin/ps")
		process.arguments = ["-p", String(processID), "-o", "command="]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		try process.run()
		process.waitUntilExit()
		guard process.terminationStatus == 0,
			let commandLine = String(
				data: output.fileHandleForReading.readDataToEndOfFile(),
				encoding: .utf8
			)?.trimmingCharacters(in: .whitespacesAndNewlines),
			let command = commandLine.split(whereSeparator: { $0.isWhitespace }).first,
			!command.isEmpty
		else {
			throw NSError(domain: "ErgoptiLeaseHarness", code: Int(ESRCH))
		}
		return String(command)
	}

	/// Parses legacy XML independently and pins every launchd capability and target.
	private func assertLegacyGuardianPlistContract(
		_ data: Data,
		executablePath: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws {
		let object = try PropertyListSerialization.propertyList(
			from: data,
			options: [],
			format: nil
		)
		let dictionary = try XCTUnwrap(
			object as? [String: Any],
			"legacy guardian plist must be one dictionary",
			file: file,
			line: line
		)
		XCTAssertEqual(Set(dictionary.keys), Set([
			"Label",
			"ProgramArguments",
			"RunAtLoad",
			"KeepAlive",
			"ProcessType",
			"ThrottleInterval",
			"AssociatedBundleIdentifiers",
		]), file: file, line: line)
		XCTAssertEqual(dictionary["Label"] as? String, kRemapGuardianLabel,
			file: file, line: line)
		XCTAssertEqual(dictionary["ProgramArguments"] as? [String], [
			executablePath,
			kKarabinerLeaseGuardianFlag,
		], file: file, line: line)
		XCTAssertEqual(dictionary["RunAtLoad"] as? Bool, true, file: file, line: line)
		XCTAssertEqual(dictionary["KeepAlive"] as? Bool, true, file: file, line: line)
		XCTAssertEqual(dictionary["ProcessType"] as? String, "Background",
			file: file, line: line)
		XCTAssertEqual(dictionary["ThrottleInterval"] as? Int,
			kGuardianThrottleIntervalSeconds, file: file, line: line)
		XCTAssertEqual(dictionary["AssociatedBundleIdentifiers"] as? [String],
			[kErgoptiBundleId], file: file, line: line)
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
			kKarabinerLeaseGuardianFlag,
			kRemapGuardianStatusFlag,
			kOpenRemapGuardianSettingsFlag,
		] {
			XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: ["ErgoptiPlus", flag]))
		}
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: [
			"ErgoptiPlus",
			kKarabinerLeaseGuardianLifetimeTestFlag,
		]))
		XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: [
			"ErgoptiPlus",
			kLauncherLogAppendTestFlag,
		]))
		XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: [
			"ErgoptiPlus",
			kPOSIXTestHelperFlag,
		]))
		#endif
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
			source.range(of: "applicationLauncher(applicationURL, configuration)")?.lowerBound
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
	func testReservedSocketsStayAboveFD3WhenLowDescriptorsAreClosed() throws {
		let helper = try startPOSIXTestHelper(mode: "reserved-sockets")
		guard helper.completion.wait(timeout: .now() + 5) == .success else {
			stopExactGuardianTestProcess(helper.process, completion: helper.completion)
			XCTFail("the closed-descriptor subprocess exceeded its bounded deadline")
			return
		}
		XCTAssertEqual(helper.process.terminationReason, .exit)
		XCTAssertEqual(helper.process.terminationStatus, 0)
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
		guard let rawEnvironment = duplicateProcessEnvironment() else {
			XCTFail("the child-reaping harness must allocate envp")
			return
		}
		defer { for case let pointer? in rawEnvironment { free(pointer) } }
		var mutableArguments = rawArguments
		var mutableEnvironment = rawEnvironment
		var processID: pid_t = 0
		let spawnStatus = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				posix_spawn(
					&processID,
					"/usr/bin/true",
					nil,
					nil,
					arguments.baseAddress,
					environment.baseAddress
				)
			}
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
			.appendingPathComponent("Sources/ErgoptiPlus/RemapLeaseWorker.swift")
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
		let writerFinished = DispatchSemaphore(value: 0)
		let writerDescriptor = sockets[0]
		DispatchQueue.global(qos: .userInitiated).async {
			for sequence in UInt32(1)...UInt32(3) {
				usleep(50_000)
				guard writeLeaseLine(
					"HEARTBEAT 1 \(sequence)",
					to: writerDescriptor
				) else { break }
			}
			writerFinished.signal()
		}
		let channel = SocketLeaseInnerChannel(
			descriptor: sockets[1]
		)

		for sequence in UInt32(1)...UInt32(3) {
			XCTAssertEqual(
				channel.nextEvent(timeout: 0.5),
				.command(.heartbeat(kLeaseModeActive, sequence))
			)
		}
		XCTAssertEqual(writerFinished.wait(timeout: .now() + 1), .success)
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
			let guardianRegistration = ScriptedLeaseGuardianRegistration(armResult: true)
			guardianRegistration.childCloseDescriptors = [parentPipe[1]]
			var clockReads = 0
			let runtime = KarabinerLeaseOuterRuntime(
				identity: identity,
				detached: false,
				spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
				guardianRegistration: guardianRegistration,
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
				+ "  exec 3>&-\n"
				+ "  : > \"$4\"\n"
				+ "  sleep 0.1\n"
				+ "  exit 0\n"
				+ "fi\n"
				+ "IFS= read -r command <&3 || exit 42\n"
				+ "[ \"$command\" = STOP ] || exit 43\n"
				+ "printf 'FENCED\\n' >&3\nexit 0\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let firstInnerMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-ready-inner.marker")
		let closedInnerMarker = fixture.deletingLastPathComponent()
			.appendingPathComponent("fast-ready-inner-closed.marker")
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
			revokedName: closedInnerMarker.path,
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			guardianRegistration: ScriptedLeaseGuardianRegistration(armResult: true),
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: outputDescriptor,
			beforeLiveAcknowledgementPublish: {
				_ = self.waitForFile(at: closedInnerMarker, timeout: 2)
			}
		)

		XCTAssertEqual(runtime.run(), LeaseWorkerExit.innerFailed.rawValue)
		let output = try String(contentsOf: publicOutput, encoding: .utf8)
		XCTAssertFalse(
			output.contains("READY"),
			"a live acknowledgement from a terminal private batch must be discarded"
		)
	}

	/// An idempotent mode ACK still requires a live private transport boundary.
	func testOuterIdempotentModeAckCannotOutrankSameBatchInnerHUP() throws {
		let cases: [(initialMode: Int, command: String, acknowledgement: String)] = [
			(kLeaseModeActive, "RESUME", "RESUMED"),
			(kLeaseModePaused, "PAUSE", "PAUSED"),
		]
		for testCase in cases {
			for losesInner in [true, false] {
				let fixture = try makeExecutableFixture(
					body: "IFS= read -r command <&3 || exit 40\n"
						+ "[ \"$command\" = 'ACTIVATE \(testCase.initialMode)' ] || exit 41\n"
						+ "printf 'READY \(testCase.initialMode)\\n' >&3\n"
						+ (losesInner
							? "while [ ! -f \"$3\" ]; do /bin/sleep 0.01; done\nexit 0\n"
							: "IFS= read -r command <&3 || exit 42\n"
								+ "[ \"$command\" = STOP ] || exit 43\n"
								+ "printf 'FENCED\\n' >&3\nexit 0\n")
				)
				defer {
					try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
				}
				let directory = fixture.deletingLastPathComponent()
				let innerExitMarker = directory.appendingPathComponent("close-inner")
				let publicOutput = directory.appendingPathComponent("public-output")
				let outputDescriptor = Darwin.open(
					publicOutput.path,
					O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
					S_IRUSR | S_IWUSR
				)
				XCTAssertGreaterThanOrEqual(outputDescriptor, 0)
				guard outputDescriptor >= 0 else { continue }
				var parentPipe = [Int32](repeating: -1, count: 2)
				let pipeStatus = parentPipe.withUnsafeMutableBufferPointer { buffer in
					Darwin.pipe(buffer.baseAddress!)
				}
				XCTAssertEqual(pipeStatus, 0)
				guard pipeStatus == 0 else {
					_ = Darwin.close(outputDescriptor)
					continue
				}
				defer {
					_ = Darwin.close(parentPipe[0])
					_ = Darwin.close(parentPipe[1])
					_ = Darwin.close(outputDescriptor)
				}
				let identity = LeaseIdentity(
					cliPath: "/unused/karabiner_cli",
					token: token,
					modeName: innerExitMarker.path,
					revokedName: "ergopti_revoked_\(token)",
					initialMode: testCase.initialMode,
					heartbeatSeconds: 5
				)
				let registration = ScriptedLeaseGuardianRegistration(armResult: true)
				let spawner = InitialThenUnavailableLeaseInnerSpawner(
					initialSpawner: PosixLeaseInnerSpawner(executablePath: fixture.path)
				)
				let recovery = ScriptedLeaseCLIExecutor(results: [], probeCalls: [])
				var publicCommandQueued = false
				var terminalBatchInjected = false
				var livePublicationChecks = 0
				let runtime = KarabinerLeaseOuterRuntime(
					identity: identity,
					detached: false,
					spawner: spawner,
					guardianRegistration: registration,
					recoveryExecutor: recovery,
					parentInputDescriptor: parentPipe[0],
					parentOutputDescriptor: outputDescriptor,
					poller: { descriptors, timeoutMilliseconds in
						if losesInner && publicCommandQueued && !terminalBatchInjected {
							XCTAssertTrue(FileManager.default.createFile(
								atPath: innerExitMarker.path,
								contents: Data()
							))
							var privateDescriptor = pollfd(
								fd: descriptors[1].fd,
								events: Int16(POLLIN | POLLHUP | POLLERR),
								revents: 0
							)
							var terminalResult: Int32
							repeat {
								terminalResult = Darwin.poll(&privateDescriptor, 1, 2_000)
							} while terminalResult == -1 && errno == EINTR
							guard terminalResult > 0,
								leasePollReportsTerminal(privateDescriptor.revents)
							else {
								XCTFail("the inner must close before the combined poll batch")
								errno = EIO
								return -1
							}
							descriptors[0].revents = Int16(POLLIN)
							descriptors[1].revents = Int16(POLLHUP | POLLERR)
							terminalBatchInjected = true
							return 2
						}
						return descriptors.withUnsafeMutableBufferPointer { buffer in
							Darwin.poll(
								buffer.baseAddress!,
								nfds_t(buffer.count),
								timeoutMilliseconds
							)
						}
					},
					beforeLiveAcknowledgementPublish: {
						livePublicationChecks += 1
						if livePublicationChecks == 1 {
							XCTAssertTrue(writeLeaseLine(
								testCase.command,
								to: parentPipe[1]
							))
							publicCommandQueued = true
						} else if !losesInner && livePublicationChecks == 2 {
							XCTAssertTrue(writeLeaseLine("STOP", to: parentPipe[1]))
						}
					}
				)

				let exitCode = runtime.run()
				let output = try String(contentsOf: publicOutput, encoding: .utf8)
				let publicLines = output.split(separator: "\n").map { String($0) }
				let exactFence = LeasePayloads.fence(identity: identity)
				if losesInner {
					XCTAssertTrue(terminalBatchInjected)
					XCTAssertEqual(exitCode, LeaseWorkerExit.innerFailed.rawValue)
					XCTAssertEqual(publicLines, ["READY"])
					XCTAssertEqual(spawner.spawnAttempts, 2)
					XCTAssertEqual(recovery.payloads, [exactFence, exactFence])
				} else {
					XCTAssertFalse(terminalBatchInjected)
					XCTAssertEqual(exitCode, LeaseWorkerExit.success.rawValue)
					XCTAssertEqual(publicLines, ["READY", testCase.acknowledgement, "STOPPED"])
					XCTAssertEqual(
						publicLines.filter { $0 == testCase.acknowledgement }.count,
						1
					)
					XCTAssertEqual(spawner.spawnAttempts, 1)
					XCTAssertEqual(recovery.payloads, [])
				}
				XCTAssertEqual(livePublicationChecks, 2)
				XCTAssertEqual(registration.beginLiveTransportCalls, 2)
				XCTAssertEqual(registration.endLiveTransportCalls, 2)
				XCTAssertEqual(registration.retireCalls, 1)
				XCTAssertEqual(registration.closeCalls, 1)
			}
		}
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
			guardianRegistration: ScriptedLeaseGuardianRegistration(armResult: true),
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

	/// A buffered live line cannot turn same-read STOP into guardian-loss failure.
	func testGuardianLossDoesNotOutrankStopSameParentBatch() {
		var presenceProbeCalls = 0
		let disposition = classifyLeaseParentBatch(
			["PING 41", "STOP"],
			guardianPresent: {
				presenceProbeCalls += 1
				return false
			}
		)
		XCTAssertEqual(disposition, .stop)
		XCTAssertEqual(presenceProbeCalls, 0,
			"terminal STOP must be classified before probing guardian liveness")
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
		let acknowledgementBoundaryRead = 3
		let identity = LeaseIdentity(
			cliPath: "/unused/karabiner_cli",
			token: token,
			modeName: acknowledgementMarker.path,
			revokedName: "unused",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		let guardianRegistration = ScriptedLeaseGuardianRegistration(armResult: true)
		guardianRegistration.childCloseDescriptors = [parentPipe[1]]
		var clockReads = 0
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: PosixLeaseInnerSpawner(executablePath: fixture.path),
			guardianRegistration: guardianRegistration,
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: nullDescriptor,
			uptime: {
				clockReads += 1
				if clockReads == acknowledgementBoundaryRead {
					XCTAssertTrue(self.waitForFile(at: acknowledgementMarker, timeout: 2))
					if parentPipe[1] >= 0 {
						_ = Darwin.close(parentPipe[1])
						parentPipe[1] = -1
					}
				}
				return clockReads >= acknowledgementBoundaryRead ? boundaryTime : 0
			}
		)

		let exitCode = runtime.run()

		XCTAssertEqual(exitCode, LeaseWorkerExit.success.rawValue)
		XCTAssertGreaterThanOrEqual(clockReads, acknowledgementBoundaryRead)
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

	/// A guardian lost after authorization suppresses the stale live ACK and fences.
	func testOuterRevalidatesGuardianAfterLiveTransportBeforePublishingReady() throws {
		let fixture = try makeExecutableFixture(
			body: "IFS= read -r command <&3 || exit 40\n"
				+ "[ \"$command\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "printf 'READY 1\\n' >&3\n"
				+ "while :; do /bin/sleep 1; done\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let publicOutput = fixture.deletingLastPathComponent()
			.appendingPathComponent("public-output")
		let outputDescriptor = Darwin.open(
			publicOutput.path,
			O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
			S_IRUSR | S_IWUSR
		)
		XCTAssertGreaterThanOrEqual(outputDescriptor, 0)
		guard outputDescriptor >= 0 else { return }
		defer { Darwin.close(outputDescriptor) }
		var parentPipe = [Int32](repeating: -1, count: 2)
		XCTAssertEqual(parentPipe.withUnsafeMutableBufferPointer {
			Darwin.pipe($0.baseAddress!)
		}, 0)
		guard parentPipe[0] >= 0, parentPipe[1] >= 0 else { return }
		defer {
			Darwin.close(parentPipe[0])
			Darwin.close(parentPipe[1])
		}
		let registration = ScriptedLeaseGuardianRegistration(armResult: true)
		registration.loseGuardianAfterSuccessfulBegin = true
		let spawner = InitialThenUnavailableLeaseInnerSpawner(
			initialSpawner: PosixLeaseInnerSpawner(executablePath: fixture.path)
		)
		let recovery = ScriptedLeaseCLIExecutor(results: [], probeCalls: [])
		let identity = makeIdentity()
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: spawner,
			guardianRegistration: registration,
			recoveryExecutor: recovery,
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: outputDescriptor
		)

		XCTAssertEqual(runtime.run(), LeaseWorkerExit.innerFailed.rawValue)
		XCTAssertEqual(registration.beginLiveTransportCalls, 1)
		XCTAssertEqual(registration.endLiveTransportCalls, 1)
		XCTAssertEqual(try Data(contentsOf: publicOutput), Data(),
			"READY must not outlive the exact guardian generation that authorized its write")
		let exactFence = LeasePayloads.fence(identity: identity)
		XCTAssertEqual(recovery.payloads, [exactFence, exactFence])
	}

	/// Recovery confines the exact writer group before releasing the guardian gate.
	func testOuterRetiresLiveWriterBeforeReleasingGuardianDrainGate() throws {
		let fixture = try makeExecutableFixture(
			body: "echo $$ > \"$3\"\n"
				+ "IFS= read -r command <&3 || exit 40\n"
				+ "[ \"$command\" = 'ACTIVATE 1' ] || exit 41\n"
				+ "printf 'MALFORMED\\n' >&3\n"
				+ "trap '' TERM\nwhile :; do /bin/sleep 1; done\n"
		)
		defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
		let writerPIDFile = fixture.deletingLastPathComponent()
			.appendingPathComponent("live-writer.pid")
		let identity = LeaseIdentity(
			cliPath: kCanonicalKarabinerCLIPath,
			token: token,
			modeName: writerPIDFile.path,
			revokedName: "ergopti_revoked_\(token)",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: 5
		)
		var parentPipe = [Int32](repeating: -1, count: 2)
		XCTAssertEqual(parentPipe.withUnsafeMutableBufferPointer {
			Darwin.pipe($0.baseAddress!)
		}, 0)
		guard parentPipe[0] >= 0, parentPipe[1] >= 0 else { return }
		defer {
			Darwin.close(parentPipe[0])
			Darwin.close(parentPipe[1])
		}
		let nullDescriptor = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
		XCTAssertGreaterThanOrEqual(nullDescriptor, 0)
		guard nullDescriptor >= 0 else { return }
		defer { Darwin.close(nullDescriptor) }
		let registration = ScriptedLeaseGuardianRegistration(armResult: true)
		var writerWasGoneAtGateRelease = false
		registration.endLiveTransportHook = {
			guard let rawPID = try? String(contentsOf: writerPIDFile, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines),
				let writerPID = pid_t(rawPID)
			else { return }
			writerWasGoneAtGateRelease = Darwin.kill(writerPID, 0) == -1 && errno == ESRCH
		}
		let spawner = InitialThenUnavailableLeaseInnerSpawner(
			initialSpawner: PosixLeaseInnerSpawner(executablePath: fixture.path)
		)
		let recovery = ScriptedLeaseCLIExecutor(results: [], probeCalls: [])
		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: false,
			spawner: spawner,
			guardianRegistration: registration,
			recoveryExecutor: recovery,
			parentInputDescriptor: parentPipe[0],
			parentOutputDescriptor: nullDescriptor
		)

		XCTAssertEqual(runtime.run(), LeaseWorkerExit.innerFailed.rawValue)
		XCTAssertTrue(writerWasGoneAtGateRelease,
			"DRAINING must not overtake a stopped or late exact live writer")
		XCTAssertEqual(registration.endLiveTransportCalls, 1)
		let exactFence = LeasePayloads.fence(identity: identity)
		XCTAssertEqual(recovery.payloads, [exactFence, exactFence])
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
			guardianRegistration: ScriptedLeaseGuardianRegistration(armResult: true),
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
			guardianRegistration: ScriptedLeaseGuardianRegistration(armResult: true),
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
			guardianRegistration: ScriptedLeaseGuardianRegistration(armResult: true),
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
		guard let rawEnvironment = duplicateProcessEnvironment() else {
			throw NSError(domain: "ErgoptiLeaseHarness", code: Int(ENOMEM), userInfo: nil)
		}
		defer { for case let pointer? in rawEnvironment { free(pointer) } }
		var mutableArguments = rawArguments
		var mutableEnvironment = rawEnvironment
		var processID: pid_t = 0
		let spawnStatus = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				posix_spawn(
					&processID,
					"/bin/sh",
					&fileActions,
					nil,
					arguments.baseAddress,
					environment.baseAddress
				)
			}
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
	private func startUnrelatedSibling(
		executableName: String? = nil
	) throws -> ProgressingTestSibling {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ErgoptiSibling-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		let progressFile = directory.appendingPathComponent("progress")
		let executableURL: URL
		if let executableName {
			executableURL = directory.appendingPathComponent(executableName)
			try FileManager.default.copyItem(
				at: URL(fileURLWithPath: "/bin/sh"),
				to: executableURL
			)
			XCTAssertEqual(Darwin.chmod(executableURL.path, 0o700), 0)
		} else {
			executableURL = URL(fileURLWithPath: "/bin/sh")
		}
		let process = Process()
		process.executableURL = executableURL
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
