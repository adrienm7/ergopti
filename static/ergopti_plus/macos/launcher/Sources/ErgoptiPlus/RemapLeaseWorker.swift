// Sources/ErgoptiPlus/RemapLeaseWorker.swift

// ==============================================================================
// MODULE: Karabiner Lease Worker
// DESCRIPTION:
// Provides the headless modes inside the signed ErgoptiPlus launcher: outer
// worker, inner writer, detached revoker, and launchd-owned guardian. The outer
// mode owns Hammerspoon’s stdin/stdout protocol and waitpid-supervises one inner
// over a private socketpair.
// The inner exclusively creates, signals, and reaps direct karabiner_cli children.
//
// FEATURES & RATIONALE:
// 1. Shared-Process Isolation: no stock Karabiner UI, Core Service, console
//    server, watcher, or VirtualHID process is enumerated or controlled.
// 2. Independent Liveness: Hammerspoon loss is observed by the outer role,
//    outer loss is observed by the inner socket peer, and inner loss is observed
//    by the outer role’s exact waitpid ownership.
// 3. Monotone Tombstone: within one Core Service variable epoch, live writes
//    change only mode while cleanup repeats mode=0 plus revoked=1 unchanged.
// 4. Exact Child Ownership: a CLI PID remains an unreaped direct child until
//    every possible signal is complete, preventing PID-reuse collateral damage.
// 5. Event-Driven Idle: Hammerspoon is the sole heartbeat authority; the outer
//    sleeps in poll until public input while inner silence triggers revocation.
// 6. Canonical CLI Boundary: argv validation accepts only the stable PKG
//    karabiner_cli path, never a shared UI, service, agent, or helper binary.
// 7. Orphan Confinement: every inner leads a private process group inherited by
//    its CLI children; inner/supervision loss kills that exact group before reap.
// 8. Descriptor Reservation: socket endpoints are duplicated above stdio/fd 3
//    before file actions, so closed inherited streams cannot corrupt liveness.
// 9. Progress Deadlines: every private command and replacement fence is bounded;
//    an open but stopped inner is retired through the same exact-group path.
// 10. Bidirectional Liveness: an inner fences when a stopped outer retains its
//     socket beyond the advertised heartbeat interval plus acknowledgement slack.
// 11. Bounded Reap: FENCED follows two clean local CLI transports separated by
//     a monotonic grace; it is deliberately not described as a receiver-side
//     Karabiner ACK. A separate exit grace bounds waitpid completion.
// 12. EINTR Boundary Priority: post-read zero-delay polls retry interruptions
//     within one fixed budget before deciding whether buffered progress is live.
// 13. Executable Revalidation: each inner spawn starts suspended before user
//     space, then compares the path vnode with the GUI-exported device/inode.
//     The resumed inner independently repeats that identity check before fd 3.
// 14. Authenticated Outer Fallback: if executable revalidation correctly blocks
//     a replacement inner, the already-running outer fences only its exact
//     token through a canonical karabiner_cli child and then terminates.
// ==============================================================================

import Darwin
import Foundation

let kKarabinerLeaseWorkerFlag = "--karabiner-lease-worker"
let kKarabinerLeaseRevokeFlag = "--karabiner-lease-revoke"
let kKarabinerLeaseInnerFlag = "--karabiner-lease-inner"
let kLauncherDeviceEnvironment = "ERGOPTI_LAUNCHER_DEVICE"
let kLauncherInodeEnvironment = "ERGOPTI_LAUNCHER_INODE"

let kLeaseModeOff = 0
let kLeaseModeActive = 1
let kLeaseModePaused = 2

/// The sole PKG-installed executable this guardian may create as a CLI child.
let kCanonicalKarabinerCLIPath =
	"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

let kInnerControlDescriptor: Int32 = 3
private let kFirstReservedSocketDescriptor: Int32 = 4
private let kMaximumHeartbeatSeconds: TimeInterval = 86_400
let kDefaultHeartbeatSeconds: TimeInterval = 5
let kCLITimeoutSeconds: TimeInterval = 1.5
private let kPrivateCommandAckTimeoutSeconds: TimeInterval = 1.75
private let kPrivateFenceAckTimeoutSeconds: TimeInterval = 3.75
let kFenceConfirmationGraceSeconds: TimeInterval = 0.25
private let kRequiredFenceTransportCount = 2
private let kMaximumProtocolLineBytes = 128
let kMaximumProtocolLinesPerRead = 32
private let kProtocolReadBytes = 4_096
let kCLIDiagnosticReadBytes = 4_096
let kMaximumCLIDiagnosticChunksPerDrain = 16
private let kBoundaryPollMaximumEINTRRetries = 3
private let kChildPollMicroseconds: useconds_t = 50_000
private let kProcessTerminationGraceSeconds: TimeInterval = 0.05
private let kFenceRetryDelays: [useconds_t] = [50_000, 100_000, 250_000, 1_000_000]
/// Lower inclusive byte bound for canonical ASCII decimal identity text.
private let kASCIIDigitZero: UInt8 = 48
/// Upper inclusive byte bound for canonical ASCII decimal identity text.
private let kASCIIDigitNine: UInt8 = 57





// ========================================
// ========================================
// ======= 1/ Invocation Validation =======
// ========================================
// ========================================

/// Defines stable process exit codes consumed by the Lua lifecycle controller.
enum LeaseWorkerExit: Int32 {
	case success = 0
	case invalidArguments = 64
	case innerSpawnFailed = 69
	case activationFailed = 70
	case pauseFailed = 71
	case resumeFailed = 72
	case innerFailed = 73
	case malformedProtocol = 74
	case guardianUnavailable = 75
}

/// Distinguishes public worker, detached fence, and private inner argv shapes.
enum LeaseInvocationRole: Equatable {
	case worker
	case revoke
	case inner
}

/// Identifies the exact launcher vnode authorized by the parent GUI process.
struct LeaseExecutableIdentity: Equatable {
	let device: String
	let inode: String

	/// Parses the immutable identity exported to embedded Hammerspoon at launch.
	/// - Parameter environment: Inherited process environment.
	/// - Returns: Canonical expected device/inode, or nil on ambiguity.
	static func parse(environment: [String: String]) -> LeaseExecutableIdentity? {
		return parse(
			device: environment[kLauncherDeviceEnvironment],
			inode: environment[kLauncherInodeEnvironment]
		)
	}

	/// Parses canonical decimal vnode components supplied over a private argv.
	/// - Parameters:
	///   - device: Decimal st_dev text.
	///   - inode: Decimal st_ino text.
	/// - Returns: Canonical identity, or nil for aliases and malformed text.
	static func parse(device: String?, inode: String?) -> LeaseExecutableIdentity? {
		guard let device = canonicalComponent(device),
			let inode = canonicalComponent(inode)
		else { return nil }
		return LeaseExecutableIdentity(device: device, inode: inode)
	}

	/// Observes one path without following a final symlink.
	/// - Parameter path: Exact bundle-derived launcher executable path.
	/// - Returns: Current device/inode pair, or nil when lstat fails.
	static func capture(at path: String) -> LeaseExecutableIdentity? {
		guard !path.isEmpty else { return nil }
		var attributes = stat()
		guard path.withCString({ Darwin.lstat($0, &attributes) }) == 0 else { return nil }
		return LeaseExecutableIdentity(
			device: String(attributes.st_dev),
			inode: String(attributes.st_ino)
		)
	}

	/// Accepts only the decimal form emitted by String(stat field).
	/// - Parameter value: Inherited identity component.
	/// - Returns: Canonical component, or nil for aliases and malformed text.
	private static func canonicalComponent(_ value: String?) -> String? {
		guard let value, !value.isEmpty,
			value.utf8.allSatisfy({ (kASCIIDigitZero...kASCIIDigitNine).contains($0) }),
			value == "0" || value.utf8.first != kASCIIDigitZero
		else { return nil }
		return value
	}
}

/// Captures one fully validated generation capability and CLI endpoint.
struct LeaseIdentity: Equatable {
	let cliPath: String
	let token: String
	let modeName: String
	let revokedName: String
	let initialMode: Int
	let heartbeatSeconds: TimeInterval

	/// Parses one public worker, detached revoker, or private inner invocation.
	/// - Parameters:
	///   - arguments: Complete process argv including the executable at index zero.
	///   - role: Role whose exact argv shape must be accepted.
	/// - Returns: A canonical exact-generation identity, or nil before any write.
	static func parse(arguments: [String], role: LeaseInvocationRole) -> LeaseIdentity? {
		let expectedCount: Int
		let expectedFlag: String
		switch role {
		case .worker:
			expectedCount = 7
			expectedFlag = kKarabinerLeaseWorkerFlag
		case .revoke:
			expectedCount = 5
			expectedFlag = kKarabinerLeaseRevokeFlag
		case .inner:
			expectedCount = 8
			expectedFlag = kKarabinerLeaseInnerFlag
		}

		guard arguments.count == expectedCount,
			arguments[1] == expectedFlag
		else { return nil }

		let cliPath = arguments[2]
		let modeName = arguments[3]
		let revokedName = arguments[4]
		let modePrefix = "ergopti_mode_"
		guard cliPath == kCanonicalKarabinerCLIPath, !cliPath.utf8.contains(0),
			modeName.hasPrefix(modePrefix)
		else { return nil }

		let token = String(modeName.dropFirst(modePrefix.count))
		guard token.count == 32,
			token.unicodeScalars.allSatisfy({ scalar in
				(48...57).contains(scalar.value) || (97...102).contains(scalar.value)
			}),
			revokedName == "ergopti_revoked_\(token)"
		else { return nil }

		var initialMode = kLeaseModeActive
		var heartbeatSeconds = kDefaultHeartbeatSeconds
		if role == .worker {
			guard arguments[5] == String(kLeaseModeActive)
				|| arguments[5] == String(kLeaseModePaused),
				let heartbeat = Double(arguments[6]),
				heartbeat.isFinite,
				heartbeat > 0,
				heartbeat <= kMaximumHeartbeatSeconds
			else { return nil }
			initialMode = Int(arguments[5]) ?? kLeaseModeOff
			heartbeatSeconds = heartbeat
		} else if role == .inner {
			guard let heartbeat = Double(arguments[5]),
				heartbeat.isFinite,
				heartbeat > 0,
				heartbeat <= kMaximumHeartbeatSeconds,
				LeaseExecutableIdentity.parse(
					device: arguments[6],
					inode: arguments[7]
				) != nil
			else { return nil }
			heartbeatSeconds = heartbeat
		}

		return LeaseIdentity(
			cliPath: cliPath,
			token: token,
			modeName: modeName,
			revokedName: revokedName,
			initialMode: initialMode,
			heartbeatSeconds: heartbeatSeconds
		)
	}
}

/// Validates that a private inner is the exact launcher image generation whose
/// vnode identity was serialized by its already-authenticated outer.
/// - Parameters:
///   - arguments: Complete private inner argv.
///   - executablePath: Running inner's bundle-derived executable path.
///   - identityReader: Exact vnode observation, injectable for tests.
/// - Returns: Exact lease identity only before any fd or Karabiner side effect.
func validatedInnerLeaseIdentity(
	arguments: [String],
	executablePath: String?,
	identityReader: (String) -> LeaseExecutableIdentity? = {
		LeaseExecutableIdentity.capture(at: $0)
	}
) -> LeaseIdentity? {
	guard let executablePath, executablePath.hasPrefix("/"),
		let identity = LeaseIdentity.parse(arguments: arguments, role: .inner),
		let expectedExecutableIdentity = LeaseExecutableIdentity.parse(
			device: arguments[6],
			inode: arguments[7]
		),
		identityReader(executablePath) == expectedExecutableIdentity
	else { return nil }
	return identity
}

/// Builds the only JSON payload shapes the native guardian may emit.
enum LeasePayloads {
	/// Builds the only live-generation write shape.
	/// - Parameters:
	///   - identity: Exact generation receiving the mode.
	///   - mode: Active or paused mode.
	/// - Returns: Deterministic JSON accepted by karabiner_cli.
	static func mode(identity: LeaseIdentity, mode: Int) -> String {
		return "{\"\(identity.modeName)\":\(mode)}"
	}

	/// Builds the exact-generation tombstone batch for one variable epoch.
	/// - Parameter identity: Exact generation being retired.
	/// - Returns: One deterministic batch repeated unchanged during cleanup.
	static func fence(identity: LeaseIdentity) -> String {
		return "{\"\(identity.modeName)\":0,\"\(identity.revokedName)\":1}"
	}
}





// =====================================
// =====================================
// ======= 2/ Bounded Line Codec =======
// =====================================
// =====================================

/// Represents one bounded decoder result.
enum LeaseLineFeed: Equatable {
	case lines([String])
	case invalid
}

/// Decodes strict line protocols without unbounded partial-line allocation.
struct BoundedLeaseLineDecoder {
	private var pending: [UInt8] = []

	/// Appends bytes while enforcing strict per-line and per-read bounds.
	/// - Parameters:
	///   - bytes: Newly read protocol bytes.
	///   - eof: Whether the descriptor reached EOF after these bytes.
	/// - Returns: Complete strict-UTF-8 lines or an invalid-protocol marker.
	mutating func append(_ bytes: ArraySlice<UInt8>, eof: Bool = false) -> LeaseLineFeed {
		var lines: [String] = []
		for byte in bytes {
			if byte == 0x0A {
				guard let line = decodePendingLine() else { return .invalid }
				lines.append(line)
				if lines.count > kMaximumProtocolLinesPerRead { return .invalid }
				pending.removeAll(keepingCapacity: true)
				continue
			}
			pending.append(byte)
			if pending.count > kMaximumProtocolLineBytes { return .invalid }
		}

		if eof, !pending.isEmpty {
			guard let line = decodePendingLine() else { return .invalid }
			lines.append(line)
			if lines.count > kMaximumProtocolLinesPerRead { return .invalid }
			pending.removeAll(keepingCapacity: false)
		}
		return .lines(lines)
	}

	/// Decodes the current line without accepting replacement characters.
	/// - Returns: A non-empty UTF-8 line with one optional CR removed.
	private func decodePendingLine() -> String? {
		var lineBytes = pending
		if lineBytes.last == 0x0D { lineBytes.removeLast() }
		guard !lineBytes.isEmpty,
			!lineBytes.contains(0),
			let line = String(bytes: lineBytes, encoding: .utf8)
		else { return nil }
		return line
	}
}

/// Represents one descriptor read including clean EOF and retry states.
enum DescriptorLineRead {
	case lines([String])
	case eof([String])
	case invalid
	case retry
}

/// Reports poll states that prove a protocol peer is gone or unusable.
/// Terminal bits outrank POLLIN because a closed descriptor can still expose
/// buffered live bytes whose effects must be discarded after owner loss.
/// - Parameter revents: poll(2) result flags.
/// - Returns: Whether liveness has ended for this descriptor.
func leasePollReportsTerminal(_ revents: Int16) -> Bool {
	return revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
}

/// Synchronous single-descriptor poll seam used at post-read liveness boundaries.
typealias LeaseDescriptorPolling = (
	_ descriptor: inout pollfd,
	_ timeoutMilliseconds: Int32
) -> Int32

/// Invokes poll(2) for one descriptor without changing its timeout contract.
/// - Parameters:
///   - descriptor: Descriptor state populated by poll(2).
///   - timeoutMilliseconds: Exact timeout forwarded to poll(2).
/// - Returns: Native poll result.
func pollLeaseDescriptor(
	_ descriptor: inout pollfd,
	_ timeoutMilliseconds: Int32
) -> Int32 {
	return Darwin.poll(&descriptor, 1, timeoutMilliseconds)
}

/// Re-samples one post-read descriptor boundary without blocking.
///
/// A signal can interrupt the zero-delay poll after protocol bytes were copied
/// but before terminal HUP/ERR is observed. Treating that interruption as live
/// publishes stale progress; treating it immediately as loss erases a buffered
/// FAILED diagnostic. Retry only EINTR, retain a fixed bound, and leave every
/// other error to the caller's fail-closed path.
/// - Parameters:
///   - descriptor: Descriptor whose peer liveness must be re-sampled.
///   - maximumEINTRRetries: Maximum retries after the first interrupted attempt.
///   - poller: Injectable poll operation; every invocation receives timeout zero.
/// - Returns: Native poll result, or -1 after the bounded retry budget is spent.
func pollLeaseBoundary(
	_ descriptor: inout pollfd,
	maximumEINTRRetries: Int = kBoundaryPollMaximumEINTRRetries,
	poller: LeaseDescriptorPolling = pollLeaseDescriptor
) -> Int32 {
	let retryLimit = max(0, maximumEINTRRetries)
	var interruptedRetries = 0
	while true {
		// A failed injected/native attempt may leave stale event bits behind.
		descriptor.revents = 0
		let result = poller(&descriptor, 0)
		if result != -1 || errno != EINTR { return result }
		if interruptedRetries >= retryLimit { return result }
		interruptedRetries += 1
	}
}

/// Reads one bounded descriptor chunk after poll has reported readiness.
/// - Parameters:
///   - descriptor: Pipe or socket descriptor.
///   - decoder: Stateful bounded line decoder for that descriptor.
/// - Returns: Complete lines, EOF, invalid input, or an interrupted retry.
func readLeaseLines(
	from descriptor: Int32,
	decoder: inout BoundedLeaseLineDecoder
) -> DescriptorLineRead {
	var bytes = [UInt8](repeating: 0, count: kProtocolReadBytes)
	let count = bytes.withUnsafeMutableBytes { buffer in
		Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
	}
	if count > 0 {
		switch decoder.append(bytes[0..<count]) {
		case .lines(let lines): return .lines(lines)
		case .invalid: return .invalid
		}
	}
	if count == 0 {
		switch decoder.append([], eof: true) {
		case .lines(let lines): return .eof(lines)
		case .invalid: return .invalid
		}
	}
	if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .retry }
	return .invalid
}

/// Writes one small protocol line without allowing SIGPIPE to bypass cleanup.
/// - Parameters:
///   - line: ASCII protocol line without a newline.
///   - descriptor: Connected pipe or socket descriptor.
/// - Returns: Whether every byte reached the kernel buffer.
@discardableResult
func writeLeaseLine(_ line: String, to descriptor: Int32) -> Bool {
	let bytes = Array((line + "\n").utf8)
	return bytes.withUnsafeBytes { rawBuffer in
		guard let base = rawBuffer.baseAddress else { return false }
		var written = 0
		while written < rawBuffer.count {
			let count = Darwin.write(
				descriptor,
				base.advanced(by: written),
				rawBuffer.count - written
			)
			if count > 0 {
				written += count
				continue
			}
			if count == -1 && errno == EINTR { continue }
			return false
		}
		return true
	}
}

/// Duplicates argv strings while failing before spawn on allocation failure.
/// - Parameter arguments: Non-optional argv entries without the terminator.
/// - Returns: Owned C pointers followed by one nil terminator, or nil.
func duplicateLeaseArguments(
	_ arguments: [String]
) -> [UnsafeMutablePointer<CChar>?]? {
	var duplicated: [UnsafeMutablePointer<CChar>?] = []
	for argument in arguments {
		guard let pointer = strdup(argument) else {
			for case let existing? in duplicated { free(existing) }
			return nil
		}
		duplicated.append(pointer)
	}
	duplicated.append(nil)
	return duplicated
}

/// Restores zombie-producing child semantics required by exact waitpid ownership.
func prepareLeaseChildReaping() {
	_ = Darwin.signal(SIGCHLD, SIG_DFL)
}

/// Marks the private inner socket close-on-exec before any CLI child is spawned.
/// - Parameter descriptor: Validated inner-control descriptor.
/// - Returns: Whether the descriptor exists and now carries FD_CLOEXEC.
func prepareInnerControlDescriptor(_ descriptor: Int32) -> Bool {
	let flags = fcntl(descriptor, F_GETFD)
	guard flags >= 0 else { return false }
	return fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
}





// ==========================================
// ==========================================
// ======= 3/ Private Socket Protocol =======
// ==========================================
// ==========================================

/// Parses one canonical non-zero heartbeat sequence.
/// - Parameter raw: Decimal sequence without signs or leading zeroes.
/// - Returns: Exact bounded sequence, or nil for malformed public input.
func parseLeasePingSequence(_ raw: String) -> UInt32? {
	guard let sequence = UInt32(raw), sequence > 0,
		String(sequence) == raw
	else { return nil }
	return sequence
}

/// Reports whether one public line is a nonterminal command with exact syntax.
/// STOP and malformed input are handled as batch-level terminal events before
/// any live command from the same read is allowed to cross the private socket.
/// - Parameter line: Public Hammerspoon protocol line.
/// - Returns: Whether the line is PAUSE, RESUME, or one canonical PING.
func isLeaseParentLiveLine(_ line: String) -> Bool {
	if line == "PAUSE" || line == "RESUME" { return true }
	let parts = line.split(separator: " ", omittingEmptySubsequences: false)
	return parts.count == 2
		&& parts[0] == "PING"
		&& parseLeasePingSequence(String(parts[1])) != nil
}

/// Batch-level decisions ordered so explicit user shutdown always wins.
enum LeaseParentBatchDisposition: Equatable {
	case stop
	case malformed
	case guardianLost
	case live
}

/// Classifies one atomic public read before any live line crosses privately.
func classifyLeaseParentBatch(
	_ lines: [String],
	guardianPresent: () -> Bool
) -> LeaseParentBatchDisposition {
	if lines.contains("STOP") { return .stop }
	if lines.contains(where: { !isLeaseParentLiveLine($0) }) { return .malformed }
	if !lines.isEmpty && !guardianPresent() { return .guardianLost }
	return .live
}

/// Defines the complete private outer-to-inner command protocol.
enum LeaseInnerCommand: Equatable {
	case activate(Int)
	case setMode(Int)
	case heartbeat(Int, UInt32)
	case stop

	/// Parses one exact outer-to-inner line.
	/// - Parameter line: Private socket protocol line.
	/// - Returns: A validated command, or nil for fail-closed handling.
	static func parse(line: String) -> LeaseInnerCommand? {
		if line == "STOP" { return .stop }
		let parts = line.split(separator: " ", omittingEmptySubsequences: false)
		guard let verb = parts.first else { return nil }
		switch verb {
		case "ACTIVATE", "SET":
			guard parts.count == 2,
				parts[1] == String(kLeaseModeActive)
					|| parts[1] == String(kLeaseModePaused),
				let mode = Int(String(parts[1]))
			else { return nil }
			return parts[0] == "ACTIVATE" ? .activate(mode) : .setMode(mode)
		case "HEARTBEAT":
			guard parts.count == 3,
				parts[1] == String(kLeaseModeActive)
					|| parts[1] == String(kLeaseModePaused),
				let mode = Int(String(parts[1])),
				let sequence = parseLeasePingSequence(String(parts[2]))
			else { return nil }
			return .heartbeat(mode, sequence)
		default:
			return nil
		}
	}

	/// Serializes a validated private command.
	/// - Returns: Exact line accepted by the inner parser.
	var line: String {
		switch self {
		case .activate(let mode): return "ACTIVATE \(mode)"
		case .setMode(let mode): return "SET \(mode)"
		case .heartbeat(let mode, let sequence): return "HEARTBEAT \(mode) \(sequence)"
		case .stop: return "STOP"
		}
	}
}

/// Defines the complete private inner-to-outer acknowledgement protocol.
enum LeaseInnerAcknowledgement: Equatable {
	case ready(Int)
	case transported(Int)
	case heartbeat(Int, UInt32)
	case heartbeatFailed(UInt32)
	case fenced
	case failed(Int32)

	/// Parses one exact inner-to-outer line.
	/// - Parameter line: Private socket protocol line.
	/// - Returns: A validated acknowledgement, or nil.
	static func parse(line: String) -> LeaseInnerAcknowledgement? {
		if line == "FENCED" { return .fenced }
		let parts = line.split(separator: " ", omittingEmptySubsequences: false)
		guard let verb = parts.first else { return nil }
		switch verb {
		case "READY", "TRANSPORTED":
			guard parts.count == 2,
				parts[1] == String(kLeaseModeActive)
					|| parts[1] == String(kLeaseModePaused),
				let mode = Int(String(parts[1]))
			else { return nil }
			return parts[0] == "READY" ? .ready(mode) : .transported(mode)
		case "HEARTBEAT":
			guard parts.count == 3,
				parts[1] == String(kLeaseModeActive)
					|| parts[1] == String(kLeaseModePaused),
				let mode = Int(String(parts[1])),
				let sequence = parseLeasePingSequence(String(parts[2]))
			else { return nil }
			return .heartbeat(mode, sequence)
		case "HEARTBEAT_FAILED":
			guard parts.count == 2,
				let sequence = parseLeasePingSequence(String(parts[1]))
			else { return nil }
			return .heartbeatFailed(sequence)
		case "FAILED":
			guard parts.count == 2,
				let code = Int32(String(parts[1])), code > 0
			else { return nil }
			return .failed(code)
		default:
			return nil
		}
	}

	/// Serializes a validated private acknowledgement.
	/// - Returns: Exact line accepted by the outer parser.
	var line: String {
		switch self {
		case .ready(let mode): return "READY \(mode)"
		case .transported(let mode): return "TRANSPORTED \(mode)"
		case .heartbeat(let mode, let sequence): return "HEARTBEAT \(mode) \(sequence)"
		case .heartbeatFailed(let sequence): return "HEARTBEAT_FAILED \(sequence)"
		case .fenced: return "FENCED"
		case .failed(let code): return "FAILED \(code)"
		}
	}
}

/// Identifies terminal liveness events that may preempt one direct CLI child.
enum LeaseCLIInterruption: Equatable {
	case none
	case stop
	case peerClosed
	case malformed
}

/// Combines private commands with socket liveness failures.
enum LeaseInnerChannelEvent: Equatable {
	case command(LeaseInnerCommand)
	case peerClosed
	case outerSilent
	case malformed
}

/// Abstracts the private socket so async loss behavior is testable without I/O.
protocol LeaseInnerChannel: AnyObject {
	/// Returns the next command or terminal liveness event.
	func nextEvent(timeout: TimeInterval) -> LeaseInnerChannelEvent
	/// Checks whether an active CLI child must be preempted.
	func pollInterruption() -> LeaseCLIInterruption
	/// Publishes one private acknowledgement.
	func send(_ acknowledgement: LeaseInnerAcknowledgement) -> Bool
}

/// Owns the inner endpoint of the private outer/inner socketpair.
final class SocketLeaseInnerChannel: LeaseInnerChannel {
	private let descriptor: Int32
	private let uptime: () -> TimeInterval
	private let poller: LeaseDescriptorPolling
	private var decoder = BoundedLeaseLineDecoder()
	private var queuedCommands: [LeaseInnerCommand] = []
	private var closed = false
	private var invalid = false

	/// Creates a channel around the descriptor inherited only by the inner role.
	/// - Parameters:
	///   - descriptor: Private socketpair endpoint.
	///   - uptime: Monotonic clock used to bound outer silence.
	///   - poller: Single-descriptor wait primitive, injectable for boundary races.
	init(
		descriptor: Int32,
		uptime: @escaping () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		poller: @escaping LeaseDescriptorPolling = pollLeaseDescriptor
	) {
		self.descriptor = descriptor
		self.uptime = uptime
		self.poller = poller
	}

	/// Returns the next command or bounded outer-liveness failure.
	/// - Parameter timeout: Maximum silence after the preceding private event.
	/// - Returns: One ordered command, peer loss, silence expiry, or malformed input.
	func nextEvent(timeout: TimeInterval) -> LeaseInnerChannelEvent {
		let deadline = uptime() + timeout
		while true {
			if invalid { return .malformed }
			if closed { return .peerClosed }
			if !queuedCommands.isEmpty { return .command(queuedCommands.removeFirst()) }
			let remaining = deadline - uptime()
			if remaining <= 0 {
				// Drain once at the boundary so a command that became readable as
				// the timed poll returned cannot lose to the silence decision.
				pump(timeoutMilliseconds: 0)
				if invalid { return .malformed }
				if closed { return .peerClosed }
				if !queuedCommands.isEmpty {
					return .command(queuedCommands.removeFirst())
				}
				return .outerSilent
			}
			let timeoutMilliseconds = Int32(min(
				remaining * 1_000,
				Double(Int32.max)
			).rounded(.up))
			pump(timeoutMilliseconds: timeoutMilliseconds)
		}
	}

	/// Pumps commands during one active CLI child so STOP or peer loss preempts it.
	/// - Returns: Highest-priority interruption observed on the socket.
	func pollInterruption() -> LeaseCLIInterruption {
		if invalid { return .malformed }
		if closed { return .peerClosed }
		pump(timeoutMilliseconds: 0)
		if invalid { return .malformed }
		if closed { return .peerClosed }
		if queuedCommands.contains(.stop) { return .stop }
		return .none
	}

	/// Sends one private acknowledgement to the supervising outer role.
	/// - Parameter acknowledgement: Validated state transition result.
	/// - Returns: Whether the outer socket remained writable.
	func send(_ acknowledgement: LeaseInnerAcknowledgement) -> Bool {
		return writeLeaseLine(acknowledgement.line, to: descriptor)
	}

	/// Reads and coalesces a bounded batch from the private socket.
	/// - Parameter timeoutMilliseconds: poll timeout.
	private func pump(timeoutMilliseconds: Int32) {
		var pollDescriptor = pollfd(
			fd: descriptor,
			events: Int16(POLLIN | POLLHUP | POLLERR),
			revents: 0
		)
		let result = poller(&pollDescriptor, timeoutMilliseconds)
		if result == -1 {
			if errno != EINTR { invalid = true }
			return
		}
		guard result > 0 else { return }
		let terminalEvents = Int16(POLLHUP | POLLERR | POLLNVAL)
		if pollDescriptor.revents & terminalEvents != 0 {
			queuedCommands.removeAll(keepingCapacity: false)
			closed = true
			return
		}

		switch readLeaseLines(from: descriptor, decoder: &decoder) {
		case .lines(let lines):
			// Re-sample once after the read: the peer may have closed while bytes
			// were copied, in which case POSIX returns data now and EOF only later.
			var boundary = pollfd(
				fd: descriptor,
				events: Int16(POLLIN | POLLHUP | POLLERR),
				revents: 0
			)
			let boundaryResult = pollLeaseBoundary(&boundary, poller: poller)
			if boundaryResult == -1 {
				invalid = true
				return
			}
			if boundaryResult > 0 && boundary.revents & terminalEvents != 0 {
				queuedCommands.removeAll(keepingCapacity: false)
				closed = true
				return
			}
			consume(lines)
		case .eof(_):
			queuedCommands.removeAll(keepingCapacity: false)
			closed = true
		case .invalid:
			invalid = true
		case .retry:
			break
		}
	}

	/// Preserves activation ordering while coalescing subsequent desired modes.
	/// - Parameter lines: Complete private protocol lines.
	private func consume(_ lines: [String]) {
		for line in lines {
			guard let command = LeaseInnerCommand.parse(line: line) else {
				invalid = true
				return
			}
			if command == .stop {
				queuedCommands = [.stop]
				return
			}
			if let last = queuedCommands.last {
				switch last {
				case .setMode(_), .heartbeat(_, _):
					queuedCommands[queuedCommands.count - 1] = command
					continue
				default:
					break
				}
			}
			queuedCommands.append(command)
			if queuedCommands.count > kMaximumProtocolLinesPerRead {
				invalid = true
				return
			}
		}
	}
}





// ============================================
// ============================================
// ======= 4/ Exact CLI Child Ownership =======
// ============================================
// ============================================

/// Reports a fully reaped direct-child result or pre-spawn failure.
enum LeaseCLIResult: Equatable {
	case success
	case failed(Int32)
	case timedOut
	case interrupted(LeaseCLIInterruption)
	case spawnFailed(Int32)
	case diagnosticOutput
	case diagnosticReadFailed(Int32)
}

/// Reports one nonblocking diagnostic-pipe drain operation.
enum LeaseDiagnosticDrain {
	case progressed(Int)
	case eof(Int)
	case wouldBlock
	case failed(Int32)
}

/// Reads one bounded turn of currently available combined stdout/stderr bytes.
/// - Parameters:
///   - descriptor: Nonblocking parent read endpoint.
///   - readOperation: Injectable POSIX read seam for deterministic starvation tests.
/// - Returns: Byte progress, clean EOF, would-block, or a concrete read failure.
func drainLeaseDiagnostics(
	from descriptor: Int32,
	readOperation: (Int32, UnsafeMutableRawBufferPointer) -> Int = { descriptor, buffer in
		Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
	}
) -> LeaseDiagnosticDrain {
	var totalBytes = 0
	var chunksRead = 0
	var bytes = [UInt8](repeating: 0, count: kCLIDiagnosticReadBytes)
	while chunksRead < kMaximumCLIDiagnosticChunksPerDrain {
		let count = bytes.withUnsafeMutableBytes { buffer in
			readOperation(descriptor, buffer)
		}
		if count > 0 {
			totalBytes += count
			chunksRead += 1
			continue
		}
		if count == 0 { return .eof(totalBytes) }
		if errno == EINTR { continue }
		if errno == EAGAIN || errno == EWOULDBLOCK {
			return totalBytes > 0 ? .progressed(totalBytes) : .wouldBlock
		}
		return .failed(Int32(errno))
	}
	return .progressed(totalBytes)
}

/// Marks one descriptor close-on-exec before any child is created.
/// - Parameter descriptor: Parent-owned descriptor.
/// - Returns: Zero on success or a concrete errno value.
private func makeLeaseDescriptorCloseOnExec(_ descriptor: Int32) -> Int32 {
	let flags = fcntl(descriptor, F_GETFD)
	guard flags >= 0 else { return Int32(errno) }
	guard fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
		return Int32(errno)
	}
	return 0
}

/// Marks the diagnostic read endpoint nonblocking for concurrent draining.
/// - Parameter descriptor: Parent-owned diagnostic read endpoint.
/// - Returns: Zero on success or a concrete errno value.
private func makeLeaseDescriptorNonblocking(_ descriptor: Int32) -> Int32 {
	let flags = fcntl(descriptor, F_GETFL)
	guard flags >= 0 else { return Int32(errno) }
	guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
		return Int32(errno)
	}
	return 0
}

/// Injects the fallible close-action registration used by every spawn owner.
typealias LeaseSpawnCloseAction = (
	_ fileActions: inout posix_spawn_file_actions_t?,
	_ descriptor: Int32
) -> Int32

/// Injects the fallible file-action initializer so its returned error is testable.
typealias LeaseSpawnFileActionsInitializer = (
	_ fileActions: inout posix_spawn_file_actions_t?
) -> Int32

/// Initializes one spawn file-action collection and preserves its POSIX status.
/// - Parameter fileActions: Collection to initialize.
/// - Returns: Zero on success, or the exact returned error code.
func initializeLeaseSpawnFileActions(
	_ fileActions: inout posix_spawn_file_actions_t?
) -> Int32 {
	return posix_spawn_file_actions_init(&fileActions)
}

/// Registers one child-side descriptor close and returns the POSIX status.
/// - Parameters:
///   - fileActions: Spawn file-action collection being prepared.
///   - descriptor: Exact inherited descriptor the child must close.
/// - Returns: Zero on success, or the POSIX error code before any spawn.
func addLeaseSpawnCloseAction(
	fileActions: inout posix_spawn_file_actions_t?,
	descriptor: Int32
) -> Int32 {
	return posix_spawn_file_actions_addclose(&fileActions, descriptor)
}

/// Abstracts serialized exact CLI child ownership for behavioral tests.
protocol LeaseCLIExecuting {
	/// Executes one payload while observing terminal guardian events.
	func execute(
		cliPath: String,
		payload: String,
		timeout: TimeInterval,
		interruption: () -> LeaseCLIInterruption
	) -> LeaseCLIResult
}

/// Production-only hardening seam for parent descriptors that no CLI exec may
/// inherit. Test doubles can keep the narrower LeaseCLIExecuting contract.
protocol LeaseCLIExecutingWithDescriptorClosure {
	func execute(
		cliPath: String,
		payload: String,
		timeout: TimeInterval,
		interruption: () -> LeaseCLIInterruption,
		closingDescriptors: [Int32]
	) -> LeaseCLIResult
}

/// Spawns, optionally signals, and reaps only its exact direct CLI child.
final class PosixLeaseCLIExecutor:
	LeaseCLIExecuting,
	LeaseCLIExecutingWithDescriptorClosure {
	private let initializeFileActions: LeaseSpawnFileActionsInitializer
	private let addCloseAction: LeaseSpawnCloseAction

	/// Creates an executor whose spawn preparation fails on close-action errors.
	/// - Parameter addCloseAction: Injectable POSIX close-action registration.
	init(
		initializeFileActions: @escaping LeaseSpawnFileActionsInitializer =
			initializeLeaseSpawnFileActions,
		addCloseAction: @escaping LeaseSpawnCloseAction = addLeaseSpawnCloseAction
	) {
		self.initializeFileActions = initializeFileActions
		self.addCloseAction = addCloseAction
	}

	/// Runs one exact direct CLI child and reaps it before returning.
	/// - Parameters:
	///   - cliPath: Exact karabiner_cli executable path.
	///   - payload: Validated exact-generation JSON.
	///   - timeout: Maximum child runtime before owned-child termination.
	///   - interruption: STOP and outer-loss probe while the child is active.
	/// - Returns: Reaped-child result or spawn failure.
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

	/// Runs one exact CLI child while explicitly closing every private lease fd.
	func execute(
		cliPath: String,
		payload: String,
		timeout: TimeInterval,
		interruption: () -> LeaseCLIInterruption,
		closingDescriptors: [Int32]
	) -> LeaseCLIResult {
		let initialInterruption = interruption()
		if initialInterruption != .none {
			return .interrupted(initialInterruption)
		}
		var spawnAttributes: posix_spawnattr_t?
		let attributeStatus = posix_spawnattr_init(&spawnAttributes)
		guard attributeStatus == 0 else { return .spawnFailed(attributeStatus) }
		defer { posix_spawnattr_destroy(&spawnAttributes) }
		var defaultSignals = sigset_t()
		guard sigemptyset(&defaultSignals) == 0,
			sigaddset(&defaultSignals, SIGHUP) == 0
		else { return .spawnFailed(errno) }
		let defaultStatus = posix_spawnattr_setsigdefault(
			&spawnAttributes,
			&defaultSignals
		)
		guard defaultStatus == 0 else { return .spawnFailed(defaultStatus) }
		let flagStatus = posix_spawnattr_setflags(
			&spawnAttributes,
			Int16(POSIX_SPAWN_SETSIGDEF)
		)
		guard flagStatus == 0 else { return .spawnFailed(flagStatus) }

		var fileActions: posix_spawn_file_actions_t?
		let fileActionsStatus = initializeFileActions(&fileActions)
		guard fileActionsStatus == 0 else {
			return .spawnFailed(fileActionsStatus)
		}
		defer { posix_spawn_file_actions_destroy(&fileActions) }

		let nullDescriptor = Darwin.open("/dev/null", O_RDWR)
		guard nullDescriptor >= 0 else { return .spawnFailed(errno) }
		defer { Darwin.close(nullDescriptor) }

		var diagnosticPipe = [Int32](repeating: -1, count: 2)
		let pipeStatus = diagnosticPipe.withUnsafeMutableBufferPointer { buffer in
			Darwin.pipe(buffer.baseAddress!)
		}
		guard pipeStatus == 0 else { return .spawnFailed(errno) }
		var diagnosticReadDescriptor = diagnosticPipe[0]
		var diagnosticWriteDescriptor = diagnosticPipe[1]
		defer {
			if diagnosticReadDescriptor >= 0 { Darwin.close(diagnosticReadDescriptor) }
			if diagnosticWriteDescriptor >= 0 { Darwin.close(diagnosticWriteDescriptor) }
		}
		let readCloseStatus = makeLeaseDescriptorCloseOnExec(diagnosticReadDescriptor)
		guard readCloseStatus == 0 else { return .spawnFailed(readCloseStatus) }
		let writeCloseStatus = makeLeaseDescriptorCloseOnExec(diagnosticWriteDescriptor)
		guard writeCloseStatus == 0 else { return .spawnFailed(writeCloseStatus) }
		let nonblockingStatus = makeLeaseDescriptorNonblocking(diagnosticReadDescriptor)
		guard nonblockingStatus == 0 else { return .spawnFailed(nonblockingStatus) }

		let stdinStatus = posix_spawn_file_actions_adddup2(
			&fileActions,
			nullDescriptor,
			STDIN_FILENO
		)
		guard stdinStatus == 0 else { return .spawnFailed(stdinStatus) }
		for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
			let outputStatus = posix_spawn_file_actions_adddup2(
				&fileActions,
				diagnosticWriteDescriptor,
				descriptor
			)
			guard outputStatus == 0 else { return .spawnFailed(outputStatus) }
		}
		let standardChildCloseDescriptors = [
			nullDescriptor,
			diagnosticReadDescriptor,
			diagnosticWriteDescriptor,
		]
		let childCloseDescriptors = Set(
			standardChildCloseDescriptors + closingDescriptors
		).filter { $0 > STDERR_FILENO }.sorted()
		for descriptor in childCloseDescriptors {
			let closeStatus = addCloseAction(&fileActions, descriptor)
			guard closeStatus == 0 else { return .spawnFailed(closeStatus) }
		}

		guard let rawArguments = duplicateLeaseArguments([
			cliPath,
			"--set-variables",
			payload,
		]) else { return .spawnFailed(ENOMEM) }
		defer {
			for case let pointer? in rawArguments { free(pointer) }
		}
		var mutableArguments = rawArguments
		var childPID: pid_t = 0
		let spawnStatus = mutableArguments.withUnsafeMutableBufferPointer { buffer in
			posix_spawn(
				&childPID,
				cliPath,
				&fileActions,
				&spawnAttributes,
				buffer.baseAddress,
				_NSGetEnviron().pointee
			)
		}
		guard spawnStatus == 0 else { return .spawnFailed(spawnStatus) }
		let parentCloseStatus = Darwin.close(diagnosticWriteDescriptor)
		diagnosticWriteDescriptor = -1
		if parentCloseStatus != 0 {
			let closeError = Int32(errno)
			terminateAndReap(childPID: childPID)
			return .diagnosticReadFailed(closeError)
		}

		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		var status: Int32 = 0
		var sawDiagnosticOutput = false
		var reachedDiagnosticEOF = false
		while true {
			var madeDiagnosticProgress = false
			if !reachedDiagnosticEOF {
				switch drainLeaseDiagnostics(from: diagnosticReadDescriptor) {
				case .progressed(let count):
					sawDiagnosticOutput = sawDiagnosticOutput || count > 0
					madeDiagnosticProgress = count > 0
				case .eof(let count):
					sawDiagnosticOutput = sawDiagnosticOutput || count > 0
					reachedDiagnosticEOF = true
				case .wouldBlock:
					break
				case .failed(let errorCode):
					terminateAndReap(childPID: childPID)
					return .diagnosticReadFailed(errorCode)
				}
			}
			let waited = waitpid(childPID, &status, WNOHANG)
			if waited == childPID {
				if !reachedDiagnosticEOF {
					switch drainLeaseDiagnostics(from: diagnosticReadDescriptor) {
					case .progressed(let count):
						sawDiagnosticOutput = sawDiagnosticOutput || count > 0
					case .eof(let count):
						sawDiagnosticOutput = sawDiagnosticOutput || count > 0
						reachedDiagnosticEOF = true
					case .wouldBlock:
						break
					case .failed(let errorCode):
						return .diagnosticReadFailed(errorCode)
					}
				}
				if sawDiagnosticOutput { return .diagnosticOutput }
				guard reachedDiagnosticEOF else {
					return .diagnosticReadFailed(Int32(EAGAIN))
				}
				let terminalInterruption = interruption()
				if terminalInterruption != .none {
					return .interrupted(terminalInterruption)
				}
				return decode(status: status)
			}
			if waited == -1 {
				if errno == EINTR { continue }
				if errno == ECHILD { return .failed(Int32(ECHILD)) }
				let waitError = Int32(errno)
				terminateAndReap(childPID: childPID)
				return .failed(waitError)
			}

			let requested = interruption()
			if requested != .none {
				terminateAndReap(childPID: childPID)
				return .interrupted(requested)
			}
			if ProcessInfo.processInfo.systemUptime >= deadline {
				terminateAndReap(childPID: childPID)
				return .timedOut
			}
			if !madeDiagnosticProgress { usleep(kChildPollMicroseconds) }
		}
	}

	/// Signals only an exact unreaped direct child, then performs the sole reap.
	/// - Parameter childPID: Direct CLI child still owned by this process.
	private func terminateAndReap(childPID: pid_t) {
		_ = Darwin.kill(childPID, SIGTERM)
		let deadline = ProcessInfo.processInfo.systemUptime
			+ kProcessTerminationGraceSeconds
		var status: Int32 = 0
		while ProcessInfo.processInfo.systemUptime < deadline {
			let waited = waitpid(childPID, &status, WNOHANG)
			if waited == childPID || (waited == -1 && errno == ECHILD) { return }
			if waited == -1 && errno != EINTR { break }
			usleep(kChildPollMicroseconds)
		}
		_ = Darwin.kill(childPID, SIGKILL)
		while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
	}

	/// Decodes one waitpid status without probing the now-reusable PID.
	/// - Parameter status: Status returned while reaping the direct child.
	/// - Returns: Stable child result.
	private func decode(status: Int32) -> LeaseCLIResult {
		let terminatingSignal = status & 0x7F
		if terminatingSignal == 0 {
			let exitCode = (status >> 8) & 0xFF
			return exitCode == 0 ? .success : .failed(exitCode)
		}
		return .failed(128 + terminatingSignal)
	}
}

/// Retries one exact tombstone until the required clean transports span a grace.
/// - Parameters:
///   - identity: Exact token-scoped generation being revoked.
///   - cliPath: Validated CLI endpoint used for every transport.
///   - executor: Exact direct-child executor serializing the transports.
///   - cliTimeout: Per-child completion deadline.
///   - fenceConfirmationGrace: Minimum separation after the first success.
///   - uptime: Monotonic clock used to prove that separation.
///   - sleep: Retry and confirmation delay primitive.
func transportLeaseFenceUntilRepeatedSuccess(
	identity: LeaseIdentity,
	cliPath: String,
	executor: LeaseCLIExecuting,
	cliTimeout: TimeInterval,
	fenceConfirmationGrace: TimeInterval,
	uptime: () -> TimeInterval,
	sleep: (useconds_t) -> Void,
	closingDescriptors: [Int32] = []
) {
	let payload = LeasePayloads.fence(identity: identity)
	var consecutiveSuccesses = 0
	var firstSuccessTime: TimeInterval?
	var failedAttempts = 0
	while consecutiveSuccesses < kRequiredFenceTransportCount {
		if consecutiveSuccesses == 1, let firstSuccessTime {
			let remaining = firstSuccessTime + fenceConfirmationGrace - uptime()
			if remaining > 0 {
				let microseconds = useconds_t(min(
					remaining * 1_000_000,
					Double(useconds_t.max)
				).rounded(.up))
				sleep(max(1, microseconds))
				continue
			}
		}
		let result: LeaseCLIResult
		if closingDescriptors.isEmpty {
			result = executor.execute(
				cliPath: cliPath,
				payload: payload,
				timeout: cliTimeout,
				interruption: { .none }
			)
		} else if let hardened = executor as? LeaseCLIExecutingWithDescriptorClosure {
			result = hardened.execute(
				cliPath: cliPath,
				payload: payload,
				timeout: cliTimeout,
				interruption: { .none },
				closingDescriptors: closingDescriptors
			)
		} else {
			result = .spawnFailed(ENOTSUP)
		}
		if result == .success {
			consecutiveSuccesses += 1
			if consecutiveSuccesses == 1 { firstSuccessTime = uptime() }
			failedAttempts = 0
			continue
		}
		consecutiveSuccesses = 0
		firstSuccessTime = nil
		let delayIndex = min(failedAttempts, kFenceRetryDelays.count - 1)
		failedAttempts += 1
		sleep(kFenceRetryDelays[delayIndex])
	}
}





// ======================================
// ======================================
// ======= 5/ Inner Lease Runtime =======
// ======================================
// ======================================

/// Serializes all generation writes and fences after outer liveness loss.
final class KarabinerLeaseInnerRuntime {
	private let identity: LeaseIdentity
	private let channel: LeaseInnerChannel
	private let executor: LeaseCLIExecuting
	private let cliTimeout: TimeInterval
	private let fenceConfirmationGrace: TimeInterval
	private let uptime: () -> TimeInterval
	private let sleep: (useconds_t) -> Void

	/// Creates the role that exclusively owns CLI process lifecycle.
	/// - Parameters:
	///   - identity: Exact generation capability.
	///   - channel: Private outer socket or a behavioral test double.
	///   - executor: Exact direct-child executor.
	///   - cliTimeout: Per-child timeout.
	///   - fenceConfirmationGrace: Minimum monotonic separation between clean transports.
	///   - uptime: Monotonic clock used for confirmation separation.
	///   - sleep: Retry delay primitive injectable for deterministic tests.
	init(
		identity: LeaseIdentity,
		channel: LeaseInnerChannel,
		executor: LeaseCLIExecuting,
		cliTimeout: TimeInterval = kCLITimeoutSeconds,
		fenceConfirmationGrace: TimeInterval = kFenceConfirmationGraceSeconds,
		uptime: @escaping () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		sleep: @escaping (useconds_t) -> Void = { usleep($0) }
	) {
		self.identity = identity
		self.channel = channel
		self.executor = executor
		self.cliTimeout = cliTimeout
		self.fenceConfirmationGrace = fenceConfirmationGrace
		self.uptime = uptime
		self.sleep = sleep
	}

	/// Runs serialized mode writes until STOP or outer loss initiates a fence.
	/// - Returns: Process exit code for outer supervision.
	func run() -> Int32 {
		while true {
			// ACTIVATE is the Hammerspoon-originated bootstrap liveness pulse. The
			// recurring Lua timer first fires at heartbeatSeconds, while this inner
			// permits the additional private-command slack before declaring silence.
			let event = channel.nextEvent(
				timeout: identity.heartbeatSeconds + kPrivateCommandAckTimeoutSeconds
			)
			switch event {
			case .peerClosed, .outerSilent:
				fenceUntilRepeatedSuccess()
				return LeaseWorkerExit.success.rawValue
			case .malformed:
				fenceUntilRepeatedSuccess()
				_ = channel.send(.failed(LeaseWorkerExit.malformedProtocol.rawValue))
				return LeaseWorkerExit.malformedProtocol.rawValue
			case .command(.stop):
				fenceUntilRepeatedSuccess()
				_ = channel.send(.fenced)
				return LeaseWorkerExit.success.rawValue
			case .command(let command):
				if let exitCode = execute(command) { return exitCode }
			}
		}
	}

	/// Executes one live write and converts interruptions into exact revocation.
	/// - Parameter command: Validated serialized command.
	/// - Returns: Terminal exit code, or nil to continue.
	private func execute(_ command: LeaseInnerCommand) -> Int32? {
		let mode: Int
		let successAcknowledgement: LeaseInnerAcknowledgement
		let failureExit: Int32
		switch command {
		case .activate(let requestedMode):
			mode = requestedMode
			successAcknowledgement = .ready(requestedMode)
			failureExit = LeaseWorkerExit.activationFailed.rawValue
		case .setMode(let requestedMode):
			mode = requestedMode
			successAcknowledgement = .transported(requestedMode)
			failureExit = requestedMode == kLeaseModePaused
				? LeaseWorkerExit.pauseFailed.rawValue
				: LeaseWorkerExit.resumeFailed.rawValue
		case .heartbeat(let requestedMode, let sequence):
			mode = requestedMode
			successAcknowledgement = .heartbeat(requestedMode, sequence)
			failureExit = LeaseWorkerExit.innerFailed.rawValue
		case .stop:
			return nil
		}

		let result = executor.execute(
			cliPath: identity.cliPath,
			payload: LeasePayloads.mode(identity: identity, mode: mode),
			timeout: cliTimeout,
			interruption: { [channel] in channel.pollInterruption() }
		)
		switch result {
		case .success:
			if !channel.send(successAcknowledgement) {
				fenceUntilRepeatedSuccess()
				return LeaseWorkerExit.success.rawValue
			}
			return nil
		case .interrupted(.stop):
			fenceUntilRepeatedSuccess()
			_ = channel.send(.fenced)
			return LeaseWorkerExit.success.rawValue
		case .interrupted(.peerClosed):
			fenceUntilRepeatedSuccess()
			return LeaseWorkerExit.success.rawValue
		case .interrupted(.malformed):
			fenceUntilRepeatedSuccess()
			_ = channel.send(.failed(LeaseWorkerExit.malformedProtocol.rawValue))
			return LeaseWorkerExit.malformedProtocol.rawValue
		case .interrupted(.none):
			return nil
		case .failed(_), .timedOut, .spawnFailed(_),
			.diagnosticOutput, .diagnosticReadFailed(_):
			if case .heartbeat(_, let sequence) = command {
				if !channel.send(.heartbeatFailed(sequence)) {
					fenceUntilRepeatedSuccess()
					return LeaseWorkerExit.success.rawValue
				}
				return nil
			}
			fenceUntilRepeatedSuccess()
			_ = channel.send(.failed(failureExit))
			return failureExit
		}
	}

	/// Retries one tombstone until two clean transports span a monotonic grace.
	private func fenceUntilRepeatedSuccess() {
		transportLeaseFenceUntilRepeatedSuccess(
			identity: identity,
			cliPath: identity.cliPath,
			executor: executor,
			cliTimeout: cliTimeout,
			fenceConfirmationGrace: fenceConfirmationGrace,
			uptime: uptime,
			sleep: sleep
		)
	}
}





// ===============================================
// ===============================================
// ======= 6/ Outer Protocol State Machine =======
// ===============================================
// ===============================================

/// Bounds every private command independently of socket liveness.
struct LeasePrivateCommandDeadline {
	private(set) var deadline: TimeInterval?

	/// Arms the live-write or repeated-fence budget for one command.
	/// - Parameters:
	///   - command: Private command successfully written to the inner socket.
	///   - now: Monotonic start time.
	mutating func arm(for command: LeaseInnerCommand, now: TimeInterval) {
		let interval: TimeInterval
		if command == .stop {
			interval = kPrivateFenceAckTimeoutSeconds
		} else {
			interval = kPrivateCommandAckTimeoutSeconds
		}
		deadline = now + interval
	}

	/// Clears a command whose exact acknowledgement was consumed.
	mutating func clear() {
		deadline = nil
	}

	/// Reports whether one in-flight command exhausted its monotonic budget.
	/// - Parameter now: Current monotonic time.
	/// - Returns: True only after an armed deadline expires.
	func isExpired(at now: TimeInterval) -> Bool {
		guard let deadline else { return false }
		return now >= deadline
	}
}

/// Describes side effects selected by the pure outer protocol machine.
enum LeaseOuterAction: Equatable {
	case send(LeaseInnerCommand)
	case publish(String)
	case fenceAndFinish(Int32, Bool)
	case finish(Int32)
}

/// Coalesces public mode intent while preserving serialized acknowledgements.
struct LeaseOuterStateMachine {
	private(set) var desiredMode: Int
	private(set) var transportedMode: Int?
	private(set) var inFlight: LeaseInnerCommand?
	private(set) var stopping = false
	private(set) var parentClosed = false
	private var terminalExit = LeaseWorkerExit.success.rawValue
	private var publicStopRequested = false

	/// Creates an inert outer state machine before the inner activation command.
	/// - Parameter initialMode: Active or paused initial state.
	init(initialMode: Int) {
		desiredMode = initialMode
	}

	/// Starts activation only after the private inner child exists.
	/// - Returns: Initial private activation action.
	mutating func start() -> [LeaseOuterAction] {
		let command = LeaseInnerCommand.activate(desiredMode)
		inFlight = command
		return [.send(command)]
	}

	/// Applies one exact Hammerspoon command with latest-wins mode coalescing.
	/// - Parameter line: Public line from Hammerspoon stdin.
	/// - Returns: Private writes or immediate public acknowledgements.
	mutating func receiveParent(line: String) -> [LeaseOuterAction] {
		if line.hasPrefix("PING ") {
			let parts = line.split(separator: " ", omittingEmptySubsequences: false)
			guard parts.count == 2,
				let sequence = parseLeasePingSequence(String(parts[1]))
			else {
				return requestStop(exitCode: LeaseWorkerExit.malformedProtocol.rawValue)
			}
			return requestHeartbeat(sequence)
		}
		switch line {
		case "PAUSE":
			return requestMode(kLeaseModePaused)
		case "RESUME":
			return requestMode(kLeaseModeActive)
		case "STOP":
			publicStopRequested = true
			return requestStop(exitCode: LeaseWorkerExit.success.rawValue)
		default:
			return requestStop(exitCode: LeaseWorkerExit.malformedProtocol.rawValue)
		}
	}

	/// Treats Hammerspoon pipe EOF as mandatory revocation without a public ACK.
	/// - Returns: Private STOP action when this is the first terminal event.
	mutating func receiveParentEOF() -> [LeaseOuterAction] {
		parentClosed = true
		return requestStop(exitCode: LeaseWorkerExit.success.rawValue)
	}

	/// Validates one inner protocol response against the serialized in-flight work.
	/// - Parameter acknowledgement: Strict private response; never a receiver ACK.
	/// - Returns: Public ACK, next coalesced command, or recovery fence.
	mutating func receiveInner(
		_ acknowledgement: LeaseInnerAcknowledgement
	) -> [LeaseOuterAction] {
		if stopping {
			if acknowledgement == .fenced {
				var actions: [LeaseOuterAction] = []
				if publicStopRequested && !parentClosed { actions.append(.publish("STOPPED")) }
				actions.append(.finish(terminalExit))
				return actions
			}
			return []
		}

		switch (inFlight, acknowledgement) {
		case (.some(.activate(let expected)), .ready(let actual)) where expected == actual:
			transportedMode = actual
			inFlight = nil
			return [.publish("READY")] + scheduleDesiredModeIfNeeded()
		case (.some(.setMode(let expected)), .transported(let actual)) where expected == actual:
			transportedMode = actual
			inFlight = nil
			let acknowledgementLine = actual == kLeaseModePaused ? "PAUSED" : "RESUMED"
			return [.publish(acknowledgementLine)] + scheduleDesiredModeIfNeeded()
		case (
			.some(.heartbeat(let expectedMode, let expectedSequence)),
			.heartbeat(let actualMode, let actualSequence)
		) where expectedMode == actualMode && expectedSequence == actualSequence:
			transportedMode = actualMode
			inFlight = nil
			return [.publish("PONG \(actualSequence)")] + scheduleDesiredModeIfNeeded()
		case (
			.some(.heartbeat(_, let expectedSequence)),
			.heartbeatFailed(let actualSequence)
		) where expectedSequence == actualSequence:
			inFlight = nil
			return [.publish("PING_FAILED \(actualSequence)")] + scheduleDesiredModeIfNeeded()
		case (_, .failed(let exitCode)):
			stopping = true
			terminalExit = exitCode
			return [.fenceAndFinish(exitCode, false)]
		default:
			stopping = true
			terminalExit = LeaseWorkerExit.innerFailed.rawValue
			return [.fenceAndFinish(terminalExit, false)]
		}
	}

	/// Converts any unexpected inner loss into a replacement-inner fence.
	/// - Returns: Terminal recovery action preserving an accepted STOP result.
	mutating func innerLost() -> [LeaseOuterAction] {
		stopping = true
		if terminalExit == LeaseWorkerExit.success.rawValue && !publicStopRequested && !parentClosed {
			terminalExit = LeaseWorkerExit.innerFailed.rawValue
		}
		return [.fenceAndFinish(
			terminalExit,
			publicStopRequested && !parentClosed
		)]
	}

	/// Records the latest requested mode and starts it only when serialization allows.
	/// - Parameter mode: Active or paused mode.
	/// - Returns: Immediate ACK, one private SET, or no action while work is pending.
	private mutating func requestMode(_ mode: Int) -> [LeaseOuterAction] {
		guard !stopping else { return [] }
		desiredMode = mode
		guard inFlight == nil else { return [] }
		if transportedMode == mode {
			return [.publish(mode == kLeaseModePaused ? "PAUSED" : "RESUMED")]
		}
		let command = LeaseInnerCommand.setMode(mode)
		inFlight = command
		return [.send(command)]
	}

	/// Forwards one Hammerspoon-originated heartbeat using the last cleanly transported mode.
	/// - Parameter sequence: Exact public sequence to echo only after clean transport.
	/// - Returns: One private heartbeat or a fail-closed protocol stop.
	private mutating func requestHeartbeat(_ sequence: UInt32) -> [LeaseOuterAction] {
		guard !stopping, inFlight == nil, let transportedMode else {
			return requestStop(exitCode: LeaseWorkerExit.malformedProtocol.rawValue)
		}
		let command = LeaseInnerCommand.heartbeat(transportedMode, sequence)
		inFlight = command
		return [.send(command)]
	}

	/// Makes STOP outrank any activation, mode, or heartbeat still in flight.
	/// - Parameter exitCode: Terminal public protocol result.
	/// - Returns: Exactly one private STOP action.
	private mutating func requestStop(exitCode: Int32) -> [LeaseOuterAction] {
		if stopping { return [] }
		stopping = true
		terminalExit = exitCode
		inFlight = .stop
		return [.send(.stop)]
	}

	/// Starts the latest coalesced mode after the preceding write is acknowledged.
	/// - Returns: One serialized SET action when the desired mode changed.
	private mutating func scheduleDesiredModeIfNeeded() -> [LeaseOuterAction] {
		guard !stopping, inFlight == nil, transportedMode != desiredMode else { return [] }
		let command = LeaseInnerCommand.setMode(desiredMode)
		inFlight = command
		return [.send(command)]
	}
}





// ============================================
// ============================================
// ======= 7/ Inner Process Supervision =======
// ============================================
// ============================================

/// Owns the exact direct inner child and its outer socket endpoint.
final class SpawnedLeaseInner {
	let processID: pid_t
	let processGroupID: pid_t
	private(set) var descriptor: Int32
	private var decoder = BoundedLeaseLineDecoder()
	private(set) var reaped = false

	/// Wraps the outer-owned exact inner child and its socket endpoint.
	/// - Parameters:
	///   - processID: Unreaped direct inner child PID.
	///   - descriptor: Outer socketpair endpoint.
	fileprivate init(processID: pid_t, descriptor: Int32) {
		self.processID = processID
		processGroupID = processID
		self.descriptor = descriptor
	}

	/// Sends one command over the private socket.
	/// - Parameter command: Validated private command.
	/// - Returns: Whether the socket remained writable.
	func send(_ command: LeaseInnerCommand) -> Bool {
		return descriptor >= 0 && writeLeaseLine(command.line, to: descriptor)
	}

	/// Reads one ready private acknowledgement batch.
	/// - Returns: Lines, EOF, or invalid transport state.
	func readLines() -> DescriptorLineRead {
		guard descriptor >= 0 else { return .eof([]) }
		return readLeaseLines(from: descriptor, decoder: &decoder)
	}

	/// Closes only the private liveness socket, never a process by PID.
	func closeSocket() {
		if descriptor >= 0 {
			_ = Darwin.close(descriptor)
			descriptor = -1
		}
	}

	/// Blocks only after FENCED or owned-group termination makes reap mandatory.
	func reapBlocking() {
		if reaped { return }
		var status: Int32 = 0
		while true {
			let waited = waitpid(processID, &status, 0)
			if waited == processID || (waited == -1 && errno == ECHILD) {
				reaped = true
				return
			}
			if waited == -1 && errno == EINTR { continue }
			return
		}
	}

	/// Gives a fenced inner one bounded exit grace, then retires its exact group.
	func reapAfterFenceOrTerminate() {
		// Never probe with waitpid(WNOHANG) here. Reaping a fast-exiting leader
		// would release its PID/PGID before a TERM-immune CLI descendant is gone,
		// making any later group signal both incomplete and unsafe under PID reuse.
		// FENCED proves the transport sequence, not that the private group is empty.
		terminateOwnedProcessGroupAndReap()
	}

	/// Terminates only this unreaped leader's private process group before reaping.
	func terminateOwnedProcessGroupAndReap() {
		if reaped { return }
		_ = Darwin.killpg(processGroupID, SIGTERM)
		usleep(useconds_t(kProcessTerminationGraceSeconds * 1_000_000))
		_ = Darwin.killpg(processGroupID, SIGKILL)
		reapBlocking()
	}
}

/// Holds two collision-proof socket endpoints reserved above stdio and fd 3.
struct ReservedLeaseSocketEndpoints {
	let outerDescriptor: Int32
	let innerDescriptor: Int32
}

/// Creates CLOEXEC socket duplicates that cannot alias stdio or inner control.
/// - Returns: Two distinct descriptors greater than fd 3, or nil after cleanup.
func makeReservedLeaseSocketEndpoints() -> ReservedLeaseSocketEndpoints? {
	var sockets: (Int32, Int32) = (-1, -1)
	let socketStatus = withUnsafeMutableBytes(of: &sockets) { bytes in
		let descriptors = bytes.bindMemory(to: Int32.self)
		return Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.baseAddress!)
	}
	guard socketStatus == 0 else { return nil }
	let rawOuterDescriptor = sockets.0
	let rawInnerDescriptor = sockets.1
	let outerDescriptor = fcntl(
		rawOuterDescriptor,
		F_DUPFD_CLOEXEC,
		kFirstReservedSocketDescriptor
	)
	guard outerDescriptor >= kFirstReservedSocketDescriptor else {
		_ = Darwin.close(rawOuterDescriptor)
		_ = Darwin.close(rawInnerDescriptor)
		return nil
	}
	let innerDescriptor = fcntl(
		rawInnerDescriptor,
		F_DUPFD_CLOEXEC,
		kFirstReservedSocketDescriptor
	)
	guard innerDescriptor >= kFirstReservedSocketDescriptor else {
		_ = Darwin.close(rawOuterDescriptor)
		_ = Darwin.close(rawInnerDescriptor)
		_ = Darwin.close(outerDescriptor)
		return nil
	}
	_ = Darwin.close(rawOuterDescriptor)
	_ = Darwin.close(rawInnerDescriptor)
	return ReservedLeaseSocketEndpoints(
		outerDescriptor: outerDescriptor,
		innerDescriptor: innerDescriptor
	)
}

/// Abstracts same-executable inner role creation.
protocol LeaseInnerSpawning {
	/// Creates one exact direct inner child.
	func spawn(identity: LeaseIdentity) -> SpawnedLeaseInner?
}

/// Production hardening seam that explicitly closes outer-owned lease records
/// in the inner's spawn file actions in addition to FD_CLOEXEC.
protocol LeaseInnerSpawningWithDescriptorClosure {
	func spawn(
		identity: LeaseIdentity,
		closingDescriptors: [Int32]
	) -> SpawnedLeaseInner?
}

/// Creates private inner roles without inheriting Hammerspoon standard streams.
final class PosixLeaseInnerSpawner:
	LeaseInnerSpawning,
	LeaseInnerSpawningWithDescriptorClosure {
	private let executablePath: String
	private let expectedExecutableIdentity: LeaseExecutableIdentity?
	private let executableIdentityReader: (String) -> LeaseExecutableIdentity?
	private let addCloseAction: LeaseSpawnCloseAction

	/// Creates a test or local spawner bound to the path identity seen now.
	/// - Parameters:
	///   - executablePath: Exact signed launcher executable path.
	///   - addCloseAction: Injectable POSIX close-action registration.
	///   - executableIdentityReader: Injectable lstat observation.
	init(
		executablePath: String,
		addCloseAction: @escaping LeaseSpawnCloseAction = addLeaseSpawnCloseAction,
		executableIdentityReader: @escaping (String) -> LeaseExecutableIdentity? = {
			LeaseExecutableIdentity.capture(at: $0)
		}
	) {
		self.executablePath = executablePath
		expectedExecutableIdentity = executableIdentityReader(executablePath)
		self.executableIdentityReader = executableIdentityReader
		self.addCloseAction = addCloseAction
	}

	/// Creates a production spawner bound to the GUI launcher's exported vnode.
	/// - Parameters:
	///   - executablePath: Exact signed launcher executable path.
	///   - expectedExecutableIdentity: Device/inode exported before Hammerspoon launch.
	///   - addCloseAction: Injectable POSIX close-action registration.
	///   - executableIdentityReader: Injectable lstat observation.
	init(
		executablePath: String,
		expectedExecutableIdentity: LeaseExecutableIdentity,
		addCloseAction: @escaping LeaseSpawnCloseAction = addLeaseSpawnCloseAction,
		executableIdentityReader: @escaping (String) -> LeaseExecutableIdentity? = {
			LeaseExecutableIdentity.capture(at: $0)
		}
	) {
		self.executablePath = executablePath
		self.expectedExecutableIdentity = expectedExecutableIdentity
		self.executableIdentityReader = executableIdentityReader
		self.addCloseAction = addCloseAction
	}

	/// Spawns one inner with only its private socket and null standard streams.
	/// - Parameter identity: Exact generation passed to the inner parser.
	/// - Returns: Outer-owned direct child, or nil before activation.
	func spawn(identity: LeaseIdentity) -> SpawnedLeaseInner? {
		return spawn(identity: identity, closingDescriptors: [])
	}

	/// Spawns one inner and explicitly closes every inherited lease capability.
	func spawn(
		identity: LeaseIdentity,
		closingDescriptors: [Int32]
	) -> SpawnedLeaseInner? {
		guard let sockets = makeReservedLeaseSocketEndpoints() else { return nil }
		let outerDescriptor = sockets.outerDescriptor
		let innerDescriptor = sockets.innerDescriptor

		var spawnAttributes: posix_spawnattr_t?
		guard posix_spawnattr_init(&spawnAttributes) == 0 else {
			_ = Darwin.close(outerDescriptor)
			_ = Darwin.close(innerDescriptor)
			return nil
		}
		defer { posix_spawnattr_destroy(&spawnAttributes) }
		// START_SUSPENDED is an Apple extension that stops the child before it
		// begins execution in user space. This lets the parent close the otherwise
		// unavoidable lstat-to-posix_spawn path race with a post-spawn vnode check.
		let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED)
		guard posix_spawnattr_setflags(&spawnAttributes, spawnFlags) == 0,
			posix_spawnattr_setpgroup(&spawnAttributes, 0) == 0
		else {
			_ = Darwin.close(outerDescriptor)
			_ = Darwin.close(innerDescriptor)
			return nil
		}

		var fileActions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&fileActions) == 0 else {
			_ = Darwin.close(outerDescriptor)
			_ = Darwin.close(innerDescriptor)
			return nil
		}
		defer { posix_spawn_file_actions_destroy(&fileActions) }

		let nullDescriptor = Darwin.open("/dev/null", O_RDWR)
		guard nullDescriptor >= 0 else {
			_ = Darwin.close(outerDescriptor)
			_ = Darwin.close(innerDescriptor)
			return nil
		}
		defer { Darwin.close(nullDescriptor) }
		for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
			guard posix_spawn_file_actions_adddup2(
				&fileActions,
				nullDescriptor,
				descriptor
			) == 0 else {
				_ = Darwin.close(outerDescriptor)
				_ = Darwin.close(innerDescriptor)
				return nil
			}
		}
		guard posix_spawn_file_actions_adddup2(
			&fileActions,
			innerDescriptor,
			kInnerControlDescriptor
		) == 0 else {
			_ = Darwin.close(outerDescriptor)
			_ = Darwin.close(innerDescriptor)
			return nil
		}
		var childCloseDescriptors: [Int32] = closingDescriptors.filter {
			$0 > STDERR_FILENO && $0 != kInnerControlDescriptor
		}
		if outerDescriptor != kInnerControlDescriptor {
			childCloseDescriptors.append(outerDescriptor)
		}
		if innerDescriptor != kInnerControlDescriptor {
			childCloseDescriptors.append(innerDescriptor)
		}
		if nullDescriptor > STDERR_FILENO
			&& nullDescriptor != kInnerControlDescriptor {
			childCloseDescriptors.append(nullDescriptor)
		}
		for descriptor in Set(childCloseDescriptors).sorted() {
			let closeStatus = addCloseAction(&fileActions, descriptor)
			guard closeStatus == 0 else {
				_ = Darwin.close(outerDescriptor)
				_ = Darwin.close(innerDescriptor)
				return nil
			}
		}

		// Reject replacements already visible before argument publication and
		// spawn. A second check below handles a one-way replacement that lands
		// after this observation.
		guard let expectedExecutableIdentity,
			executableIdentityReader(executablePath) == expectedExecutableIdentity
		else {
			_ = Darwin.close(outerDescriptor)
			_ = Darwin.close(innerDescriptor)
			return nil
		}
		guard let rawArguments = duplicateLeaseArguments([
			executablePath,
			kKarabinerLeaseInnerFlag,
			identity.cliPath,
			identity.modeName,
			identity.revokedName,
			String(identity.heartbeatSeconds),
			expectedExecutableIdentity.device,
			expectedExecutableIdentity.inode,
		]) else {
			_ = Darwin.close(outerDescriptor)
			_ = Darwin.close(innerDescriptor)
			return nil
		}
		defer {
			for case let pointer? in rawArguments { free(pointer) }
		}
		var mutableArguments = rawArguments
		var childPID: pid_t = 0
		let spawnStatus = mutableArguments.withUnsafeMutableBufferPointer { buffer in
			posix_spawn(
				&childPID,
				executablePath,
				&fileActions,
				&spawnAttributes,
				buffer.baseAddress,
				_NSGetEnviron().pointee
			)
		}
		_ = Darwin.close(innerDescriptor)
		guard spawnStatus == 0 else {
			_ = Darwin.close(outerDescriptor)
			return nil
		}

		// The child cannot have executed user code yet. If the pathname resolved to
		// a replacement vnode during posix_spawn, kill and reap that exact unreaped
		// direct child before it can parse a token or create any CLI descendant.
		guard LeaseExecutableIdentity.capture(at: executablePath) == expectedExecutableIdentity else {
			_ = Darwin.kill(childPID, SIGKILL)
			var status: Int32 = 0
			while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
			_ = Darwin.close(outerDescriptor)
			return nil
		}
		guard Darwin.kill(childPID, SIGCONT) == 0 else {
			_ = Darwin.kill(childPID, SIGKILL)
			var status: Int32 = 0
			while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
			_ = Darwin.close(outerDescriptor)
			return nil
		}
		return SpawnedLeaseInner(processID: childPID, descriptor: outerDescriptor)
	}
}





// ======================================
// ======================================
// ======= 8/ Outer Lease Runtime =======
// ======================================
// ======================================

/// Synchronous descriptor wait seam used to reproduce deadline-boundary races.
typealias LeasePolling = (_ descriptors: inout [pollfd], _ timeoutMilliseconds: Int32) -> Int32

/// Owns Hammerspoon protocol pipes and waitpid-supervises each inner role.
final class KarabinerLeaseOuterRuntime {
	private let identity: LeaseIdentity
	private let detached: Bool
	private let spawner: LeaseInnerSpawning
	private let guardianRegistration: LeaseGuardianRegistering?
	private let recoveryExecutor: LeaseCLIExecuting
	private let parentInputDescriptor: Int32
	private let parentOutputDescriptor: Int32
	private let uptime: () -> TimeInterval
	private let poller: LeasePolling
	private let boundaryPoller: LeaseDescriptorPolling
	private let beforeLiveAcknowledgementPublish: () -> Void
	private var inner: SpawnedLeaseInner?
	private var parentDecoder = BoundedLeaseLineDecoder()
	private var machine: LeaseOuterStateMachine
	private var commandDeadline = LeasePrivateCommandDeadline()
	private var liveTransportGateHeld = false

	/// Creates the only role allowed to retain Hammerspoon stdin/stdout.
	/// - Parameters:
	///   - identity: Exact generation capability.
	///   - detached: Whether this invocation is a fallback fence only.
	///   - spawner: Same-executable inner process factory.
	///   - guardianRegistration: Required durable LaunchAgent handshake for workers;
	///     nil is valid only for a detached tombstone-only invocation.
	///   - recoveryExecutor: Exact-child CLI executor retained by the authenticated outer.
	///   - parentInputDescriptor: Public command stream owned by Hammerspoon.
	///   - parentOutputDescriptor: Public acknowledgement stream to Hammerspoon.
	///   - uptime: Monotonic clock used for command and recovery deadlines.
	///   - poller: Descriptor wait primitive, injectable for boundary-race tests.
	///   - boundaryPoller: Zero-delay single-descriptor poll seam after private reads.
	///   - beforeLiveAcknowledgementPublish: Test seam inside the shared transport gate.
	init(
		identity: LeaseIdentity,
		detached: Bool,
		spawner: LeaseInnerSpawning,
		guardianRegistration: LeaseGuardianRegistering?,
		recoveryExecutor: LeaseCLIExecuting = PosixLeaseCLIExecutor(),
		parentInputDescriptor: Int32 = STDIN_FILENO,
		parentOutputDescriptor: Int32 = STDOUT_FILENO,
		uptime: @escaping () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		poller: @escaping LeasePolling = { descriptors, timeout in
			descriptors.withUnsafeMutableBufferPointer { buffer in
				Darwin.poll(buffer.baseAddress!, nfds_t(buffer.count), timeout)
			}
		},
		boundaryPoller: @escaping LeaseDescriptorPolling = pollLeaseDescriptor,
		beforeLiveAcknowledgementPublish: @escaping () -> Void = {}
	) {
		self.identity = identity
		self.detached = detached
		self.spawner = spawner
		self.guardianRegistration = guardianRegistration
		self.recoveryExecutor = recoveryExecutor
		self.parentInputDescriptor = parentInputDescriptor
		self.parentOutputDescriptor = parentOutputDescriptor
		self.uptime = uptime
		self.poller = poller
		self.boundaryPoller = boundaryPoller
		self.beforeLiveAcknowledgementPublish = beforeLiveAcknowledgementPublish
		machine = LeaseOuterStateMachine(initialMode: identity.initialMode)
	}

	/// Runs the public worker protocol or detached exact-generation revoker.
	/// - Returns: Stable outer process exit status.
	func run() -> Int32 {
		if detached {
			recoverFenceUntilSuccess()
			return LeaseWorkerExit.success.rawValue
		}

		guard let guardianRegistration,
			guardianRegistration.arm()
		else { return LeaseWorkerExit.guardianUnavailable.rawValue }
		defer { guardianRegistration.closePreservingAbandonment() }

		guard let spawned = spawnInnerWithGuardianDescriptors() else {
			guardianRegistration.cancelBeforeActivation()
			return LeaseWorkerExit.innerSpawnFailed.rawValue
		}
		inner = spawned
		if let terminal = perform(machine.start()) { return terminal }

		while true {
			guard let current = inner else {
				return finishAfterRecovery(machine.innerLost())
			}
			var descriptors = [
				pollfd(
					fd: parentInputDescriptor,
					events: Int16(POLLIN | POLLHUP | POLLERR),
					revents: 0
				),
				pollfd(
					fd: current.descriptor,
					events: Int16(POLLIN | POLLHUP | POLLERR),
					revents: 0
				),
			]
			let timeout = pollTimeoutMilliseconds()
			let pollResult = poller(&descriptors, timeout)
			if pollResult == -1 {
				if errno == EINTR { continue }
				return finishAfterRecovery(machine.innerLost())
			}
			if pollResult > 0 {
				// Parent STOP/EOF has priority over any stale live-mode ACK in the
				// same bounded batch, then inner ACKs can clear an expired command.
				if descriptors[0].revents != 0 {
					if leasePollReportsTerminal(descriptors[0].revents) {
						if let terminal = perform(machine.receiveParentEOF()) { return terminal }
					} else if let terminal = consumeParentInput() {
						return terminal
					}
				}
				if descriptors[1].revents != 0 {
					if leasePollReportsTerminal(descriptors[1].revents) {
						if let terminal = consumeTerminalInnerOutput(current) { return terminal }
					} else if let terminal = consumeInnerOutput(current) {
						return terminal
					}
				}
			}

			// A parent EOF or inner ACK can become ready as the timed poll returns.
			// Re-sample both descriptors once before any deadline action so that a
			// kernel-visible shutdown always outranks stale private progress. This is
			// deliberately one bounded poll, not an unbounded drain loop.
			descriptors[0].revents = 0
			descriptors[1].revents = 0
			let boundaryPollResult = poller(&descriptors, 0)
			if boundaryPollResult == -1 {
				if errno == EINTR { continue }
				return finishAfterRecovery(machine.innerLost())
			}
			if boundaryPollResult > 0 {
				if descriptors[0].revents != 0 {
					if leasePollReportsTerminal(descriptors[0].revents) {
						if let terminal = perform(machine.receiveParentEOF()) { return terminal }
					} else if let terminal = consumeParentInput() {
						return terminal
					}
				}
				if descriptors[1].revents != 0 {
					if leasePollReportsTerminal(descriptors[1].revents) {
						if let terminal = consumeTerminalInnerOutput(current) { return terminal }
					} else if let terminal = consumeInnerOutput(current) {
						return terminal
					}
				}
			}

			let now = uptime()
			if commandDeadline.isExpired(at: now) {
				commandDeadline.clear()
				return finishAfterRecovery(machine.innerLost())
			}
		}
	}

	/// Creates the inner only through a spawner that can explicitly close the
	/// durable record and guardian-lock descriptors before exec.
	private func spawnInnerWithGuardianDescriptors() -> SpawnedLeaseInner? {
		guard let guardianRegistration else { return spawner.spawn(identity: identity) }
		let descriptors = guardianRegistration.childCloseDescriptors
		guard let hardened = spawner as? LeaseInnerSpawningWithDescriptorClosure else {
			return descriptors.isEmpty ? spawner.spawn(identity: identity) : nil
		}
		return hardened.spawn(
			identity: identity,
			closingDescriptors: descriptors
		)
	}

	/// Reads every complete Hammerspoon command from one bounded chunk.
	/// - Returns: Terminal result when the event initiates cleanup.
	private func consumeParentInput() -> Int32? {
		switch readLeaseLines(from: parentInputDescriptor, decoder: &parentDecoder) {
		case .lines(let lines):
			return consumeParentBatch(lines)
		case .eof(_):
			return perform(machine.receiveParentEOF())
		case .invalid:
			return perform(machine.receiveParent(line: "MALFORMED"))
		case .retry:
			break
		}
		return nil
	}

	/// Applies one public read atomically with terminal intent taking priority.
	/// - Parameter lines: Complete lines returned by one descriptor read.
	/// - Returns: Terminal process result when cleanup completes.
	private func consumeParentBatch(_ lines: [String]) -> Int32? {
		switch classifyLeaseParentBatch(lines, guardianPresent: {
			guardianRegistration?.guardianStillPresent() == true
		}) {
		case .stop:
			return perform(machine.receiveParent(line: "STOP"))
		case .malformed:
			return perform(machine.receiveParent(line: "MALFORMED"))
		case .guardianLost:
			return finishAfterRecovery(machine.innerLost())
		case .live:
			break
		}
		for line in lines {
			if let terminal = perform(machine.receiveParent(line: line)) { return terminal }
		}
		return nil
	}

	/// Reads strict inner ACKs and treats socket EOF as a supervised loss.
	/// - Parameter current: Exact outer-owned inner child.
	/// - Returns: Terminal result when cleanup completes.
	private func consumeInnerOutput(_ current: SpawnedLeaseInner) -> Int32? {
		switch current.readLines() {
		case .lines(let lines):
			var boundary = pollfd(
				fd: current.descriptor,
				events: Int16(POLLIN | POLLHUP | POLLERR),
				revents: 0
			)
			let boundaryResult = pollLeaseBoundary(&boundary, poller: boundaryPoller)
			if boundaryResult == -1 {
				return finishAfterRecovery(machine.innerLost())
			}
			if boundaryResult > 0 && leasePollReportsTerminal(boundary.revents) {
				return consumeTerminalInnerLines(lines)
			}
			return consumeInnerLines(lines)
		case .eof(let lines):
			return consumeTerminalInnerLines(lines)
		case .invalid:
			return finishAfterRecovery(machine.innerLost())
		case .retry:
			break
		}
		return nil
	}

	/// Reads one HUP/ERR-marked private batch without publishing stale live ACKs.
	/// A sole valid FENCED in an already-stopping state remains terminal proof. A
	/// sole FAILED outside stop preserves the inner's stable diagnostic while still
	/// forcing a replacement fence. Live ACKs are discarded; contradictory terminal
	/// lines are recovered generically.
	/// - Parameter current: Exact outer-owned inner child.
	/// - Returns: Terminal result after normal fence completion or recovery.
	private func consumeTerminalInnerOutput(_ current: SpawnedLeaseInner) -> Int32? {
		switch current.readLines() {
		case .lines(let lines), .eof(let lines):
			return consumeTerminalInnerLines(lines)
		case .invalid, .retry:
			return finishAfterRecovery(machine.innerLost())
		}
	}

	/// Applies a healthy private acknowledgement batch in order.
	/// - Parameter lines: Strict protocol lines from a live inner socket.
	/// - Returns: Terminal result when an action completes cleanup.
	private func consumeInnerLines(_ lines: [String]) -> Int32? {
		for line in lines {
			guard let acknowledgement = LeaseInnerAcknowledgement.parse(line: line) else {
				return finishAfterRecovery(machine.innerLost())
			}
			let previousCommand = machine.inFlight
			let actions = machine.receiveInner(acknowledgement)
			if machine.inFlight != previousCommand { commandDeadline.clear() }
			if let terminal = perform(actions) { return terminal }
		}
		return nil
	}

	/// Accepts only one unambiguous terminal proof after private socket loss.
	/// - Parameter lines: Final buffered private lines.
	/// - Returns: Terminal result after fence completion or replacement recovery.
	private func consumeTerminalInnerLines(_ lines: [String]) -> Int32 {
		var fenceCount = 0
		var failureCode: Int32?
		var failureCount = 0
		for line in lines {
			guard let acknowledgement = LeaseInnerAcknowledgement.parse(line: line) else {
				return finishAfterRecovery(machine.innerLost())
			}
			switch acknowledgement {
			case .fenced:
				fenceCount += 1
			case .failed(let code):
				failureCount += 1
				failureCode = code
			default:
				break
			}
		}
		if machine.stopping && fenceCount == 1 && failureCount == 0 {
			commandDeadline.clear()
			return perform(machine.receiveInner(.fenced))
				?? LeaseWorkerExit.innerFailed.rawValue
		}
		if !machine.stopping, fenceCount == 0, failureCount == 1,
			let failureCode {
			commandDeadline.clear()
			return perform(machine.receiveInner(.failed(failureCode)))
				?? LeaseWorkerExit.innerFailed.rawValue
		}
		return finishAfterRecovery(machine.innerLost())
	}

	/// Performs state-machine actions while converting channel loss into a fence.
	/// - Parameter actions: Ordered pure state-machine actions.
	/// - Returns: Terminal process result, or nil to keep polling.
	private func perform(_ actions: [LeaseOuterAction]) -> Int32? {
		for action in actions {
			switch action {
			case .send(let command):
				if command != .stop {
					guard !liveTransportGateHeld,
						guardianRegistration?.beginLiveTransport() == true
					else {
						return finishAfterRecovery(machine.innerLost())
					}
					liveTransportGateHeld = true
				}
				guard inner?.send(command) == true else {
					return finishAfterRecovery(machine.innerLost())
				}
				commandDeadline.arm(
					for: command,
					now: uptime()
				)
			case .publish(let line):
				if liveTransportGateHeld, isLeaseLiveAcknowledgementLine(line) {
					guard guardianRegistration?.guardianStillPresent() == true else {
						return finishAfterRecovery(machine.innerLost())
					}
					beforeLiveAcknowledgementPublish()
				}
				if !writeLeaseLine(line, to: parentOutputDescriptor) {
					if let terminal = perform(machine.receiveParentEOF()) { return terminal }
					return nil
				}
				endLiveTransportIfNeeded()
			case .fenceAndFinish(let exitCode, let publishStopped):
				commandDeadline.clear()
				retireCurrentAfterSupervisionLoss()
				endLiveTransportIfNeeded()
				recoverFenceUntilSuccess()
				if publishStopped {
					_ = writeLeaseLine("STOPPED", to: parentOutputDescriptor)
				}
				guardianRegistration?.retireAfterFence()
				return exitCode
			case .finish(let exitCode):
				commandDeadline.clear()
				retireCurrentAfterFence()
				endLiveTransportIfNeeded()
				guardianRegistration?.retireAfterFence()
				return exitCode
			}
		}
		return nil
	}

	/// Recognizes public ACKs that prove one live Karabiner CLI transport completed.
	private func isLeaseLiveAcknowledgementLine(_ line: String) -> Bool {
		return line == "READY"
			|| line == "PAUSED"
			|| line == "RESUMED"
			|| line.hasPrefix("PONG ")
			|| line.hasPrefix("PING_FAILED ")
	}

	/// Releases a live-write gate exactly once on ACK, failure, or teardown.
	private func endLiveTransportIfNeeded() {
		guard liveTransportGateHeld else { return }
		liveTransportGateHeld = false
		guardianRegistration?.endLiveTransport()
	}

	/// Completes a recovery action produced outside the normal action executor.
	/// - Parameter actions: Terminal recovery action list.
	/// - Returns: Final exit code.
	private func finishAfterRecovery(_ actions: [LeaseOuterAction]) -> Int32 {
		return perform(actions) ?? LeaseWorkerExit.innerFailed.rawValue
	}

	/// Kills the failed inner's exact private group before its leader can be reused.
	private func retireCurrentAfterSupervisionLoss() {
		guard let current = inner else { return }
		current.closeSocket()
		current.terminateOwnedProcessGroupAndReap()
		inner = nil
	}

	/// Reaps the inner only after FENCED reports that its run loop is returning.
	private func retireCurrentAfterFence() {
		guard let current = inner else { return }
		current.closeSocket()
		current.reapAfterFenceOrTerminate()
		inner = nil
	}

	/// Uses replacement inners until one completes repeated exact-fence transports.
	/// If the launcher's current vnode can no longer be authenticated, the outer
	/// must not weaken the spawner's path check. This already-authenticated process
	/// instead transports the same exact tombstone through its own canonical CLI
	/// children, whose direct-child ownership cannot reach a stock Karabiner peer.
	private func recoverFenceUntilSuccess() {
		while true {
			guard let replacement = spawnInnerWithGuardianDescriptors() else {
				fenceDirectlyUntilRepeatedSuccess()
				return
			}
			inner = replacement
			guard replacement.send(.stop) else {
				retireCurrentAfterSupervisionLoss()
				continue
			}
			if waitForReplacementFence(replacement) {
				retireCurrentAfterFence()
				return
			}
			retireCurrentAfterSupervisionLoss()
		}
	}

	/// Retries the exact two-variable tombstone through canonical CLI children.
	///
	/// This fallback is intentionally narrower than inner recovery: it cannot
	/// execute the replaced launcher path, enumerate shared processes, or signal
	/// anything except a direct karabiner_cli child it created and still owns.
	private func fenceDirectlyUntilRepeatedSuccess() {
		transportLeaseFenceUntilRepeatedSuccess(
			identity: identity,
			cliPath: kCanonicalKarabinerCLIPath,
			executor: recoveryExecutor,
			cliTimeout: kCLITimeoutSeconds,
			fenceConfirmationGrace: kFenceConfirmationGraceSeconds,
			uptime: uptime,
			sleep: { usleep($0) },
			closingDescriptors: guardianRegistration?.childCloseDescriptors ?? []
		)
	}

	/// Waits event-driven for a replacement FENCED ACK or exact child loss.
	/// - Parameter replacement: Current replacement inner.
	/// - Returns: Whether two grace-separated clean transports preceded FENCED.
	private func waitForReplacementFence(_ replacement: SpawnedLeaseInner) -> Bool {
		let deadline = uptime() + kPrivateFenceAckTimeoutSeconds
		while true {
			if uptime() >= deadline { return false }
			var descriptor = pollfd(
				fd: replacement.descriptor,
				events: Int16(POLLIN | POLLHUP | POLLERR),
				revents: 0
			)
			let remaining = max(0, deadline - uptime())
			let timeout = Int32(min(
				remaining * 1_000,
				Double(Int32.max)
			).rounded(.up))
			let result = Darwin.poll(&descriptor, 1, timeout)
			if result == -1 {
				if errno == EINTR { continue }
				return false
			}
			if result == 0 { return false }
			switch replacement.readLines() {
			case .lines(let lines):
				for line in lines {
					if LeaseInnerAcknowledgement.parse(line: line) == .fenced { return true }
				}
			case .eof(let lines):
				for line in lines {
					if LeaseInnerAcknowledgement.parse(line: line) == .fenced { return true }
				}
				return false
			case .invalid:
				return false
			case .retry:
				break
			}
		}
	}

	/// Converts the current private command deadline to a poll timeout.
	/// - Returns: Milliseconds until required work, or -1 with no deadline.
	private func pollTimeoutMilliseconds() -> Int32 {
		guard let deadline = commandDeadline.deadline else { return -1 }
		let remaining = max(0, deadline - uptime())
		let milliseconds = min(remaining * 1_000, Double(Int32.max))
		return Int32(milliseconds.rounded(.up))
	}
}





// ====================================
// ====================================
// ======= 9/ Headless Dispatch =======
// ====================================
// ====================================

/// Dispatches validated headless roles from the signed launcher executable.
enum KarabinerLeaseWorker {
	/// Detects every headless role before any NSApplication side effect.
	/// - Parameter arguments: Complete process argv.
	/// - Returns: Whether the launcher must remain headless.
	static func handles(arguments: [String]) -> Bool {
		guard arguments.count > 1 else { return false }
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if arguments[1] == kKarabinerLeaseGuardianLifetimeTestFlag { return true }
		#endif
		return arguments[1] == kKarabinerLeaseWorkerFlag
			|| arguments[1] == kKarabinerLeaseRevokeFlag
			|| arguments[1] == kKarabinerLeaseInnerFlag
			|| arguments[1] == kKarabinerLeaseGuardianFlag
	}

	/// Runs one validated outer, revoker, private inner, or independent guardian role.
	/// - Parameter arguments: Complete process argv.
	/// - Returns: Stable process exit status.
	static func run(arguments: [String]) -> Int32 {
		guard arguments.count > 1 else { return LeaseWorkerExit.invalidArguments.rawValue }
		// Ignored SIGCHLD and SA_NOCLDWAIT survive exec and would auto-reap the
		// exact child whose unreaped PID proves private-group ownership
		prepareLeaseChildReaping()
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if arguments[1] == kKarabinerLeaseGuardianLifetimeTestFlag {
			guard arguments.count == 3,
				let paths = validatedGuardianLifetimeTestPaths(arguments[2])
			else { return LeaseWorkerExit.invalidArguments.rawValue }
			_ = Darwin.signal(SIGHUP, SIG_IGN)
			_ = Darwin.signal(SIGINT, SIG_DFL)
			_ = Darwin.signal(SIGTERM, SIG_DFL)
			return RemapLeaseGuardianRuntime(paths: paths).run()
		}
		#endif
		if arguments[1] == kKarabinerLeaseGuardianFlag {
			guard arguments.count == 2 else {
				return LeaseWorkerExit.invalidArguments.rawValue
			}
			_ = Darwin.signal(SIGHUP, SIG_IGN)
			_ = Darwin.signal(SIGINT, SIG_DFL)
			_ = Darwin.signal(SIGTERM, SIG_DFL)
			return RemapLeaseGuardianRuntime().run()
		}

		if arguments[1] == kKarabinerLeaseInnerFlag {
			// A private group containing a stopped CLI receives HUP+CONT when
			// outer loss orphans it; the socket EOF remains the liveness authority
			_ = Darwin.signal(SIGHUP, SIG_IGN)
			_ = Darwin.signal(SIGINT, SIG_DFL)
			_ = Darwin.signal(SIGTERM, SIG_DFL)
			// No CLI child may inherit the liveness socket; otherwise an inner
			// SIGKILL would remain invisible until that unrelated exec exits.
			guard let identity = validatedInnerLeaseIdentity(
				arguments: arguments,
				executablePath: Bundle.main.executablePath
			),
				prepareInnerControlDescriptor(kInnerControlDescriptor)
			else { return LeaseWorkerExit.invalidArguments.rawValue }
			let runtime = KarabinerLeaseInnerRuntime(
				identity: identity,
				channel: SocketLeaseInnerChannel(descriptor: kInnerControlDescriptor),
				executor: PosixLeaseCLIExecutor()
			)
			return runtime.run()
		}

		let detached = arguments[1] == kKarabinerLeaseRevokeFlag
		let role: LeaseInvocationRole = detached ? .revoke : .worker
		guard handles(arguments: arguments),
			let identity = LeaseIdentity.parse(arguments: arguments, role: role),
			let executablePath = Bundle.main.executablePath,
			executablePath.hasPrefix("/"),
			let expectedExecutableIdentity = LeaseExecutableIdentity.parse(
				environment: ProcessInfo.processInfo.environment
			),
			LeaseExecutableIdentity.capture(at: executablePath) == expectedExecutableIdentity
		else { return LeaseWorkerExit.invalidArguments.rawValue }
		// Graceful parent teardown must close stdin and use the same fenced path;
		// only uncatchable loss is delegated exclusively to the surviving inner
		_ = Darwin.signal(SIGHUP, SIG_IGN)
		_ = Darwin.signal(SIGINT, SIG_IGN)
		_ = Darwin.signal(SIGTERM, SIG_IGN)

		let runtime = KarabinerLeaseOuterRuntime(
			identity: identity,
			detached: detached,
			spawner: PosixLeaseInnerSpawner(
				executablePath: executablePath,
				expectedExecutableIdentity: expectedExecutableIdentity
			),
			guardianRegistration: detached
				? nil
				: LeaseGuardianRegistration(identity: identity)
		)
		return runtime.run()
	}
}
