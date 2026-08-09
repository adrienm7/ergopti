// Sources/ErgoptiPlus/RemapLeaseGuardian.swift

// ==============================================================================
// MODULE: Independent Remap Lease Guardian
// DESCRIPTION:
// Provides the launchd-owned survivor for exact ErgoptiPlus Karabiner leases.
// The ordinary outer worker holds one durable, generation-specific record under
// an exclusive kernel flock. The LaunchAgent waits for that exact lock to be
// released and then writes only the token-derived OFF+tombstone payload through
// a canonical karabiner_cli child. No stock Karabiner process is discovered,
// signalled, stopped, restarted, or claimed by this module.
//
// FEATURES & RATIONALE:
// 1. Durable-before-active: a locked, fsynced record is published and the agent
//    returns ARMED before the outer may spawn an inner or activate a generation.
// 2. PID-free authority: blocking flock acquisition is level-triggered and tied
//    to the exact open-file description, so PID reuse cannot manufacture life.
// 3. Crash restart: launchd restarts the singleton and every surviving record is
//    either re-watched or fenced before it can be forgotten.
// 4. Exact isolation: filenames are canonical 32-hex tokens; variable names and
//    the CLI endpoint are derived locally and never accepted from a record.
// 5. Legacy support: macOS 13+ uses SMAppService; macOS 11/12 installs only the
//    exact per-user ErgoptiPlus LaunchAgent label through direct launchctl argv.
// ==============================================================================

import Darwin
import Dispatch
import Foundation
import ServiceManagement





// ======================================
// ======================================
// ======= 1/ Immutable Contract ========
// ======================================
// ======================================

let kKarabinerLeaseGuardianFlag = "--karabiner-lease-guardian"
let kRemapGuardianLabel = "com.ergoptiplus.remap-guardian"
let kRemapGuardianPlistName = "com.ergoptiplus.remap-guardian.plist"
let kRemapGuardianServiceErrorDomain = "SMAppServiceErrorDomain"
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
let kKarabinerLeaseGuardianLifetimeTestFlag =
	"--karabiner-lease-guardian-lifetime-test"
#endif

private let kGuardianRecordHeader = "ERGOPTI_REMAP_LEASE_V1"
private let kGuardianSingletonHeader = "ERGOPTI_REMAP_GUARDIAN_V1"
private let kGuardianArmedHeader = "ARMED"
private let kGuardianRecordSuffix = ".lease"
private let kGuardianAckSuffix = ".armed"
private let kGuardianArmTimeoutSeconds: TimeInterval = 3
private let kGuardianArmPollMicroseconds: useconds_t = 10_000
private let kGuardianSingletonRetryMicroseconds: useconds_t = 10_000
private let kGuardianMaximumRecordBytes = 256
let kGuardianMaximumUnacknowledgedRecords = 64
private let kGuardianSafetyScanSeconds: TimeInterval = 10
private let kLegacyLaunchctlTimeoutSeconds: TimeInterval = 3
private let kGuardianGateFailuresBeforeEmergencyFence = 3
private let kGuardianEmergencyFenceIntervalSeconds: TimeInterval = 1
private let kGuardianDrainFailureRetryMicroseconds: useconds_t = 100_000
let kGuardianThrottleIntervalSeconds = 10

/// Result of one exact exclusive activation-gate acquisition attempt.
enum LeaseGuardianGateLockResult: Equatable {
	case acquired
	case failed(Int32)
}

/// Publishes one durable generation acknowledgement for an exact record.
typealias LeaseGuardianAcknowledgementWriting = (Data, String, String) -> Bool

/// Takes the exact activation gate, preserving errno for fail-closed retries.
func lockGuardianActivationGate(_ descriptor: Int32) -> LeaseGuardianGateLockResult {
	if Darwin.flock(descriptor, LOCK_EX) == 0 { return .acquired }
	return .failed(errno)
}

/// Serializes persistent guardian diagnostics from state, waiter, and fence
/// queues while rate-limiting retry loops by stable failure key.
enum RemapGuardianLog {
	private static let queue = DispatchQueue(label: "com.ergoptiplus.remap-guardian.log")
	private static var lastWrite: [String: TimeInterval] = [:]

	/// Persists one rate-limited guardian diagnostic through the launcher log.
	static func write(
		key: String,
		message: String,
		minimumInterval: TimeInterval = 10
	) {
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
			return
		}
		#endif
		queue.sync {
			let now = ProcessInfo.processInfo.systemUptime
			if let last = lastWrite[key], now - last < minimumInterval { return }
			lastWrite[key] = now
			LauncherLog.write("remap guardian: " + message)
		}
	}
}

/// Fixed private paths shared by the GUI, outer workers, and the LaunchAgent.
struct LeaseGuardianPaths {
	let root: String
	let records: String
	let acknowledgements: String
	let singletonLock: String
	let activationGate: String

	/// Derives paths without accepting an environment-controlled directory.
	/// - Parameter homeDirectory: Current user's Foundation home directory.
	init(homeDirectory: String = NSHomeDirectory()) {
		root = homeDirectory
			+ "/Library/Application Support/ErgoptiPlus/LeaseGuardian/v1"
		records = root + "/records"
		acknowledgements = root + "/acknowledgements"
		singletonLock = root + "/guardian.lock"
		activationGate = root + "/activation.lock"
	}

	/// Derives one exact durable record path from a canonical token.
	func recordPath(token: String) -> String {
		return records + "/" + token + kGuardianRecordSuffix
	}

	/// Derives one exact durable acknowledgement path from a canonical token.
	func acknowledgementPath(token: String) -> String {
		return acknowledgements + "/" + token + kGuardianAckSuffix
	}
}

#if ERGOPTI_GUARDIAN_TEST_SUPPORT
/// Accepts a private temporary home only for the SwiftPM lifetime subprocess.
/// Release builds contain no path override for the production LaunchAgent.
func validatedGuardianLifetimeTestPaths(_ value: String) -> LeaseGuardianPaths? {
	guard value.hasPrefix("/") else { return nil }
	let temporaryRoot = FileManager.default.temporaryDirectory
		.standardizedFileURL
		.resolvingSymlinksInPath()
	let candidate = URL(fileURLWithPath: value, isDirectory: true)
		.standardizedFileURL
		.resolvingSymlinksInPath()
	let descendantPrefix = temporaryRoot.path.hasSuffix("/")
		? temporaryRoot.path
		: temporaryRoot.path + "/"
	guard candidate.path.hasPrefix(descendantPrefix),
		candidate.lastPathComponent.hasPrefix("ergopti-guardian-lifetime-")
	else { return nil }

	var attributes = stat()
	guard candidate.path.withCString({ Darwin.lstat($0, &attributes) }) == 0,
		(attributes.st_mode & S_IFMT) == S_IFDIR,
		(attributes.st_mode & 0o777) == 0o700,
		attributes.st_uid == geteuid()
	else { return nil }
	return LeaseGuardianPaths(homeDirectory: candidate.path)
}
#endif

/// Durable data supplied by an exact outer worker. Names and executable paths
/// are deliberately absent so a corrupted record cannot target personal state.
enum LeaseGuardianRecordState: String {
	case live = "LIVE"
	case retired = "RETIRED"
}

enum LeaseGuardianSingletonState: String {
	case starting = "STARTING"
	case active = "ACTIVE"
	case draining = "DRAINING"
}

/// Generation-bound singleton state prevents an ACK left by an old launchd
/// process from authorizing activation under a replacement process that has not
/// watched the record yet.
struct LeaseGuardianSingletonRecord: Equatable {
	let generation: String
	let state: LeaseGuardianSingletonState
	let activationDevice: Int64
	let activationInode: UInt64

	var encoded: Data? {
		guard LeaseGuardianRecord.isCanonicalToken(generation) else { return nil }
		return [
			kGuardianSingletonHeader,
			generation,
			state.rawValue,
			String(activationDevice),
			String(activationInode),
			"",
		].joined(separator: "\n").data(using: .utf8)
	}

	/// Parses one canonical singleton generation record without normalization.
	static func parse(_ data: Data) -> LeaseGuardianSingletonRecord? {
		guard data.count <= kGuardianMaximumRecordBytes,
			let text = String(data: data, encoding: .utf8)
		else { return nil }
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.count == 6,
			lines[0] == Substring(kGuardianSingletonHeader),
			lines[5].isEmpty,
			let state = LeaseGuardianSingletonState(rawValue: String(lines[2])),
			let activationDevice = Int64(lines[3]),
			let activationInode = UInt64(lines[4])
		else { return nil }
		let record = LeaseGuardianSingletonRecord(
			generation: String(lines[1]),
			state: state,
			activationDevice: activationDevice,
			activationInode: activationInode
		)
		return record.encoded == data ? record : nil
	}
}

struct LeaseGuardianRecord: Equatable {
	let token: String
	let nonce: String
	let ownerPID: Int32
	let state: LeaseGuardianRecordState

	var encoded: Data? {
		guard LeaseGuardianRecord.isCanonicalToken(token),
			LeaseGuardianRecord.isCanonicalToken(nonce),
			ownerPID > 0
		else { return nil }
		return [
			kGuardianRecordHeader,
			token,
			nonce,
			String(ownerPID),
			state.rawValue,
			"",
		].joined(separator: "\n").data(using: .utf8)
	}

	/// Encodes the exact-generation ARMED acknowledgement for this record.
	func acknowledgement(guardianGeneration: String) -> Data? {
		return LeaseGuardianAcknowledgement(
			token: token,
			nonce: nonce,
			guardianGeneration: guardianGeneration
		).encoded
	}

	/// Parses one canonical outer-owner record without accepting extra fields.
	static func parse(_ data: Data) -> LeaseGuardianRecord? {
		guard data.count <= kGuardianMaximumRecordBytes,
			let text = String(data: data, encoding: .utf8)
		else { return nil }
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.count == 6,
			lines[0] == Substring(kGuardianRecordHeader),
			lines[5].isEmpty,
			let ownerPID = Int32(lines[3]),
			ownerPID > 0,
			let state = LeaseGuardianRecordState(rawValue: String(lines[4]))
		else { return nil }
		let record = LeaseGuardianRecord(
			token: String(lines[1]),
			nonce: String(lines[2]),
			ownerPID: ownerPID,
			state: state
		)
		return record.encoded == data ? record : nil
	}

	/// Validates the fixed lower-case 128-bit token representation.
	static func isCanonicalToken(_ token: String) -> Bool {
		return token.count == 32 && token.utf8.allSatisfy { byte in
			(48...57).contains(byte) || (97...102).contains(byte)
		}
	}
}

private struct LeaseGuardianAcknowledgement: Equatable {
	let token: String
	let nonce: String
	let guardianGeneration: String

	var encoded: Data? {
		guard LeaseGuardianRecord.isCanonicalToken(token),
			LeaseGuardianRecord.isCanonicalToken(nonce),
			LeaseGuardianRecord.isCanonicalToken(guardianGeneration)
		else { return nil }
		return [
			kGuardianArmedHeader,
			token,
			nonce,
			guardianGeneration,
			"",
		].joined(separator: "\n").data(using: .utf8)
	}

	/// Parses one canonical token, nonce, and guardian-generation acknowledgement.
	static func parse(_ data: Data) -> LeaseGuardianAcknowledgement? {
		guard data.count <= kGuardianMaximumRecordBytes,
			let text = String(data: data, encoding: .utf8)
		else { return nil }
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.count == 5,
			lines[0] == Substring(kGuardianArmedHeader),
			lines[4].isEmpty
		else { return nil }
		let acknowledgement = LeaseGuardianAcknowledgement(
			token: String(lines[1]),
			nonce: String(lines[2]),
			guardianGeneration: String(lines[3])
		)
		return acknowledgement.encoded == data ? acknowledgement : nil
	}
}

/// Immutable vnode identity prevents cleanup from unlinking a replacement path.
private struct LeaseGuardianFileIdentity: Equatable {
	let device: dev_t
	let inode: ino_t
}





// ==========================================
// ==========================================
// ======= 2/ Exact Filesystem Primitives ====
// ==========================================
// ==========================================

/// Creates or validates one user-owned guardian directory with mode 0700.
private func secureGuardianDirectory(_ path: String) -> Bool {
	do {
		try FileManager.default.createDirectory(
			atPath: path,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
	} catch {
		return false
	}
	var attributes = stat()
	guard path.withCString({ Darwin.lstat($0, &attributes) }) == 0,
		(attributes.st_mode & S_IFMT) == S_IFDIR,
		attributes.st_uid == geteuid(),
		Darwin.chmod(path, 0o700) == 0
	else { return false }
	return true
}

/// Prepares the complete fixed guardian namespace before any record publication.
private func prepareGuardianDirectories(_ paths: LeaseGuardianPaths) -> Bool {
	return secureGuardianDirectory(paths.root)
		&& secureGuardianDirectory(paths.records)
		&& secureGuardianDirectory(paths.acknowledgements)
}

/// Tests whether an exclusive singleton owner exists without letting concurrent
/// shared probes impersonate that owner after it dies.
func guardianSingletonIsExclusivelyHeld(descriptor: Int32) -> Bool {
	guard descriptor >= 0 else { return false }
	if Darwin.flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
		_ = Darwin.flock(descriptor, LOCK_UN)
		return false
	}
	return errno == EWOULDBLOCK
}

/// Reads a user-owned regular file identity from an already-open descriptor.
private func guardianFileIdentity(descriptor: Int32) -> LeaseGuardianFileIdentity? {
	var attributes = stat()
	guard Darwin.fstat(descriptor, &attributes) == 0,
		(attributes.st_mode & S_IFMT) == S_IFREG,
		attributes.st_uid == geteuid()
	else { return nil }
	return LeaseGuardianFileIdentity(
		device: attributes.st_dev,
		inode: attributes.st_ino
	)
}

/// Reads a user-owned regular file identity without following its final component.
private func guardianPathIdentity(_ path: String) -> LeaseGuardianFileIdentity? {
	var attributes = stat()
	guard path.withCString({ Darwin.lstat($0, &attributes) }) == 0,
		(attributes.st_mode & S_IFMT) == S_IFREG,
		attributes.st_uid == geteuid()
	else { return nil }
	return LeaseGuardianFileIdentity(
		device: attributes.st_dev,
		inode: attributes.st_ino
	)
}

/// Reads a user-owned directory identity from an already-open descriptor.
private func guardianDirectoryIdentity(descriptor: Int32) -> LeaseGuardianFileIdentity? {
	var attributes = stat()
	guard Darwin.fstat(descriptor, &attributes) == 0,
		(attributes.st_mode & S_IFMT) == S_IFDIR,
		attributes.st_uid == geteuid()
	else { return nil }
	return LeaseGuardianFileIdentity(
		device: attributes.st_dev,
		inode: attributes.st_ino
	)
}

/// Reads a user-owned directory path identity without following its final component.
private func guardianDirectoryPathIdentity(_ path: String) -> LeaseGuardianFileIdentity? {
	var attributes = stat()
	guard path.withCString({ Darwin.lstat($0, &attributes) }) == 0,
		(attributes.st_mode & S_IFMT) == S_IFDIR,
		attributes.st_uid == geteuid()
	else { return nil }
	return LeaseGuardianFileIdentity(
		device: attributes.st_dev,
		inode: attributes.st_ino
	)
}

/// Opens or creates one no-follow user-owned regular file with close-on-exec.
private func openGuardianRegularFile(_ path: String) -> Int32 {
	let descriptor = Darwin.open(
		path,
		O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
		S_IRUSR | S_IWUSR
	)
	guard descriptor >= 0,
		guardianFileIdentity(descriptor: descriptor) != nil,
		Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
	else {
		if descriptor >= 0 { Darwin.close(descriptor) }
		return -1
	}
	return descriptor
}

/// Writes and fsyncs every byte to an already-positioned guardian descriptor.
private func writeGuardianData(_ data: Data, descriptor: Int32) -> Bool {
	var offset = 0
	while offset < data.count {
		let written = data.withUnsafeBytes { bytes -> Int in
			guard let base = bytes.baseAddress else { return -1 }
			return Darwin.write(
				descriptor,
				base.advanced(by: offset),
				data.count - offset
			)
		}
		if written > 0 {
			offset += written
			continue
		}
		if written == -1 && errno == EINTR { continue }
		return false
	}
	return Darwin.fsync(descriptor) == 0
}

/// Replaces a locked record in place. A crash at any intermediate byte leaves
/// a non-canonical record, which the guardian treats as abandoned and fences.
func replaceGuardianData(_ data: Data, descriptor: Int32) -> Bool {
	guard Darwin.ftruncate(descriptor, 0) == 0,
		Darwin.lseek(descriptor, 0, SEEK_SET) == 0
	else { return false }
	return writeGuardianData(data, descriptor: descriptor)
}

/// Reads one bounded guardian record from offset zero without changing file offset.
private func readGuardianData(
	descriptor: Int32,
	maximumBytes: Int = kGuardianMaximumRecordBytes
) -> Data? {
	guard maximumBytes > 0 else { return nil }
	var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
	let count = bytes.withUnsafeMutableBytes { buffer in
		Darwin.pread(descriptor, buffer.baseAddress!, buffer.count, 0)
	}
	guard count >= 0, count <= maximumBytes else { return nil }
	return Data(bytes.prefix(count))
}

@discardableResult
/// Persists one directory entry update before an acknowledgement is trusted.
private func fsyncGuardianDirectory(_ path: String) -> Bool {
	let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
	guard descriptor >= 0 else { return false }
	defer { Darwin.close(descriptor) }
	return Darwin.fsync(descriptor) == 0
}

/// Unlinks only the path that still names the expected immutable file identity.
private func unlinkGuardianPath(
	_ path: String,
	expectedIdentity: LeaseGuardianFileIdentity?
) -> Bool {
	if let expectedIdentity,
		guardianPathIdentity(path) != expectedIdentity {
		return false
	}
	if Darwin.unlink(path) == 0 { return true }
	return errno == ENOENT
}

/// Replaces one fixed guardian file through a same-directory durable rename.
/// A post-rename durability failure rolls back only the inode just published, so
/// an outer can never accept a visible acknowledgement that the guardian rejected.
func writeGuardianFileAtomically(
	data: Data,
	path: String,
	directory: String,
	directorySync: ((String) -> Bool)? = nil
) -> Bool {
	let syncDirectory = directorySync ?? fsyncGuardianDirectory
	let temporary = directory + "/." + UUID().uuidString + ".tmp"
	let descriptor = Darwin.open(
		temporary,
		O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
		S_IRUSR | S_IWUSR
	)
	guard descriptor >= 0 else { return false }
	defer {
		Darwin.close(descriptor)
		_ = Darwin.unlink(temporary)
	}
	guard Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0,
		writeGuardianData(data, descriptor: descriptor),
		let publishedIdentity = guardianFileIdentity(descriptor: descriptor),
		Darwin.rename(temporary, path) == 0
	else { return false }
	guard syncDirectory(directory) else {
		if unlinkGuardianPath(path, expectedIdentity: publishedIdentity) {
			_ = syncDirectory(directory)
		}
		return false
	}
	return true
}

/// Tests whether the durable acknowledgement names one exact record generation.
private func guardianAcknowledgementMatches(
	record: LeaseGuardianRecord,
	guardianGeneration: String,
	paths: LeaseGuardianPaths
) -> Bool {
	guard let observed = readGuardianAcknowledgement(
		token: record.token,
		paths: paths
	)?.acknowledgement else { return false }
	return observed == LeaseGuardianAcknowledgement(
		token: record.token,
		nonce: record.nonce,
		guardianGeneration: guardianGeneration
	)
}

/// Reads one acknowledgement together with the identity required for safe cleanup.
private func readGuardianAcknowledgement(
	token: String,
	paths: LeaseGuardianPaths
) -> (acknowledgement: LeaseGuardianAcknowledgement, identity: LeaseGuardianFileIdentity)? {
	let descriptor = Darwin.open(
		paths.acknowledgementPath(token: token),
		O_RDONLY | O_CLOEXEC | O_NOFOLLOW
	)
	guard descriptor >= 0 else { return nil }
	defer { Darwin.close(descriptor) }
	guard Darwin.flock(descriptor, LOCK_SH | LOCK_NB) == 0,
		let identity = guardianFileIdentity(descriptor: descriptor),
		let acknowledgement = readGuardianData(descriptor: descriptor)
			.flatMap(LeaseGuardianAcknowledgement.parse),
		acknowledgement.token == token
	else { return nil }
	return (acknowledgement, identity)
}

/// Removes only an acknowledgement whose content and optional identity still match.
private func removeGuardianAcknowledgement(
	_ expected: LeaseGuardianAcknowledgement,
	expectedIdentity: LeaseGuardianFileIdentity? = nil,
	paths: LeaseGuardianPaths
) {
	let path = paths.acknowledgementPath(token: expected.token)
	let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
	guard descriptor >= 0 else { return }
	defer { Darwin.close(descriptor) }
	guard let identity = guardianFileIdentity(descriptor: descriptor),
		expectedIdentity == nil || expectedIdentity == identity,
		let acknowledgement = readGuardianData(descriptor: descriptor)
			.flatMap(LeaseGuardianAcknowledgement.parse),
		acknowledgement == expected
	else { return }
	if unlinkGuardianPath(path, expectedIdentity: identity) {
		_ = fsyncGuardianDirectory(paths.acknowledgements)
	}
}

/// Returns the exclusively held ACTIVE generation bound to the exact gate inode.
private func activeGuardianGeneration(
	descriptor: Int32,
	activationGateDescriptor: Int32
) -> String? {
	guard guardianSingletonIsExclusivelyHeld(descriptor: descriptor),
		let state = readGuardianData(descriptor: descriptor)
			.flatMap(LeaseGuardianSingletonRecord.parse),
		state.state == .active,
		let activationIdentity = guardianFileIdentity(
			descriptor: activationGateDescriptor
		),
		state.activationDevice == Int64(activationIdentity.device),
		state.activationInode == UInt64(activationIdentity.inode)
	else { return nil }
	return state.generation
}





// ==============================================
// ==============================================
// ======= 3/ Outer Registration Handshake ======
// ==============================================
// ==============================================

/// Boundary injected into the outer runtime so activation ordering is testable.
protocol LeaseGuardianRegistering: AnyObject {
	var childCloseDescriptors: [Int32] { get }
	/// Publishes the locked record and waits for an exact-generation ARMED ACK.
	func arm() -> Bool
	/// Revalidates the same exclusive guardian generation and activation inode.
	func guardianStillPresent() -> Bool
	/// Serializes one live CLI write and its ACK against guardian termination.
	func beginLiveTransport() -> Bool
	/// Releases live-write ordering only after its exact ACK has been published.
	func endLiveTransport()
	/// Retires a record when activation never acquired any remap authority.
	func cancelBeforeActivation()
	/// Retires a record only after exact fencing has completed.
	func retireAfterFence()
	/// Closes inherited capabilities while leaving a crashed LIVE record observable.
	func closePreservingAbandonment()
}

/// Holds the exact record lock for one outer process lifetime.
final class LeaseGuardianRegistration: LeaseGuardianRegistering {
	private let record: LeaseGuardianRecord
	private let paths: LeaseGuardianPaths
	private var recordDescriptor: Int32 = -1
	private var guardianLockDescriptor: Int32 = -1
	private var activationGateDescriptor: Int32 = -1
	private var activationGateLocked = false
	private var liveTransportActive = false
	private var recordIdentity: LeaseGuardianFileIdentity?
	private var guardianGeneration: String?
	private var recordPublished = false
	private var armed = false

	var childCloseDescriptors: [Int32] {
		return [
			recordDescriptor,
			guardianLockDescriptor,
			activationGateDescriptor,
		].filter { $0 >= 0 }
	}

	/// Creates one unarmed registration with a fresh nonce for the supplied token.
	init(identity: LeaseIdentity, paths: LeaseGuardianPaths = LeaseGuardianPaths()) {
		record = LeaseGuardianRecord(
			token: identity.token,
			nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
			ownerPID: getpid(),
			state: .live
		)
		self.paths = paths
	}

	/// Publishes, locks, and obtains a generation-bound acknowledgement before return.
	func arm() -> Bool {
		guard !armed,
			prepareGuardianDirectories(paths),
			let encoded = record.encoded
		else { return false }

		let temporaryPath = paths.records + "/." + record.token + "." + record.nonce + ".pending"
		let descriptor = Darwin.open(
			temporaryPath,
			O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
			S_IRUSR | S_IWUSR
		)
		guard descriptor >= 0 else { return false }
		recordDescriptor = descriptor
		guard Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0,
			writeGuardianData(encoded, descriptor: descriptor),
			let identity = guardianFileIdentity(descriptor: descriptor)
		else {
			cancelBeforeActivation()
			_ = Darwin.unlink(temporaryPath)
			return false
		}
		recordIdentity = identity
		guard Darwin.link(temporaryPath, paths.recordPath(token: record.token)) == 0 else {
			cancelBeforeActivation()
			_ = Darwin.unlink(temporaryPath)
			return false
		}
		recordPublished = true
		guard Darwin.unlink(temporaryPath) == 0,
			fsyncGuardianDirectory(paths.records)
		else {
			cancelBeforeActivation()
			_ = Darwin.unlink(temporaryPath)
			return false
		}

		let deadline = ProcessInfo.processInfo.systemUptime + kGuardianArmTimeoutSeconds
		while ProcessInfo.processInfo.systemUptime < deadline {
			if guardianLockDescriptor < 0 {
				guardianLockDescriptor = Darwin.open(
					paths.singletonLock,
					O_RDWR | O_CLOEXEC | O_NOFOLLOW
				)
			}
			if activationGateDescriptor < 0 {
				activationGateDescriptor = openGuardianRegularFile(paths.activationGate)
			}
			guard guardianLockDescriptor >= 0,
				activationGateDescriptor >= 0,
				let generation = activeGuardianGeneration(
					descriptor: guardianLockDescriptor,
					activationGateDescriptor: activationGateDescriptor
				)
			else {
				usleep(kGuardianArmPollMicroseconds)
				continue
			}
			if acknowledgementMatches(guardianGeneration: generation) {
				let gateResult = Darwin.flock(
					activationGateDescriptor,
					LOCK_SH | LOCK_NB
				)
				guard gateResult == 0 else {
					usleep(kGuardianArmPollMicroseconds)
					continue
				}
				activationGateLocked = true
				guard activeGuardianGeneration(
					descriptor: guardianLockDescriptor,
					activationGateDescriptor: activationGateDescriptor
				)
					== generation,
					acknowledgementMatches(guardianGeneration: generation)
				else {
					unlockActivationGate()
					continue
				}
				guardianGeneration = generation
				armed = true
				return true
			}
			usleep(kGuardianArmPollMicroseconds)
		}
		cancelBeforeActivation()
		return false
	}

	/// Revalidates live ownership by the exact guardian generation accepted at ARM.
	func guardianStillPresent() -> Bool {
		guard let guardianGeneration else { return false }
		return activeGuardianGeneration(
			descriptor: guardianLockDescriptor,
			activationGateDescriptor: activationGateDescriptor
		)
			== guardianGeneration
	}

	/// Locks the generation-bound gate before any live write can cross privately.
	func beginLiveTransport() -> Bool {
		guard armed, !liveTransportActive, let guardianGeneration else { return false }
		if !activationGateLocked {
			guard Darwin.flock(
				activationGateDescriptor,
				LOCK_SH | LOCK_NB
			) == 0 else { return false }
			activationGateLocked = true
		}
		guard activeGuardianGeneration(
			descriptor: guardianLockDescriptor,
			activationGateDescriptor: activationGateDescriptor
		) == guardianGeneration,
			acknowledgementMatches(guardianGeneration: guardianGeneration)
		else {
			unlockActivationGate()
			return false
		}
		liveTransportActive = true
		return true
	}

	/// Unlocks the live transport barrier while retaining its identity descriptor.
	func endLiveTransport() {
		guard liveTransportActive else { return }
		liveTransportActive = false
		unlockActivationGate()
	}

	/// Removes an inert record whose activation path never started.
	func cancelBeforeActivation() {
		retireRecord()
	}

	/// Removes a record after its exact generation has been fenced.
	func retireAfterFence() {
		retireRecord()
	}

	/// Drops process capabilities without disguising a crash as retirement.
	func closePreservingAbandonment() {
		closeActivationGate()
		if guardianLockDescriptor >= 0 {
			Darwin.close(guardianLockDescriptor)
			guardianLockDescriptor = -1
		}
		if recordDescriptor >= 0 {
			Darwin.close(recordDescriptor)
			recordDescriptor = -1
		}
		armed = false
	}

	/// Compares the durable ACK against this record and one singleton generation.
	private func acknowledgementMatches(guardianGeneration: String) -> Bool {
		return guardianAcknowledgementMatches(
			record: record,
			guardianGeneration: guardianGeneration,
			paths: paths
		)
	}

	/// Releases only the shared ordering lock while preserving inode validation.
	private func unlockActivationGate() {
		guard activationGateDescriptor >= 0, activationGateLocked else { return }
		_ = Darwin.flock(activationGateDescriptor, LOCK_UN)
		activationGateLocked = false
	}

	/// Releases and closes the activation-gate capability during final teardown.
	private func closeActivationGate() {
		liveTransportActive = false
		unlockActivationGate()
		guard activationGateDescriptor >= 0 else { return }
		Darwin.close(activationGateDescriptor)
		activationGateDescriptor = -1
	}

	/// Writes RETIRED under the owner lock, unlinks safely, and closes capabilities.
	private func retireRecord() {
		if recordDescriptor >= 0, recordPublished {
			let retired = LeaseGuardianRecord(
				token: record.token,
				nonce: record.nonce,
				ownerPID: record.ownerPID,
				state: .retired
			)
			if let encoded = retired.encoded {
				_ = replaceGuardianData(encoded, descriptor: recordDescriptor)
			}
			_ = unlinkGuardianPath(
				paths.recordPath(token: record.token),
				expectedIdentity: recordIdentity
			)
			_ = fsyncGuardianDirectory(paths.records)
			if let guardianGeneration {
				removeGuardianAcknowledgement(
					LeaseGuardianAcknowledgement(
						token: record.token,
						nonce: record.nonce,
						guardianGeneration: guardianGeneration
					),
					paths: paths
				)
			}
			recordPublished = false
		}
		closePreservingAbandonment()
	}
}





// ==========================================
// ==========================================
// ======= 4/ LaunchAgent Runtime ===========
// ==========================================
// ==========================================

private final class LeaseGuardianWatch {
	let token: String
	let record: LeaseGuardianRecord?
	let descriptor: Int32
	let identity: LeaseGuardianFileIdentity
	let queue: DispatchQueue
	var acknowledged: Bool

	/// Retains one exact record descriptor and its dedicated blocking-wait queue.
	init(
		token: String,
		record: LeaseGuardianRecord?,
		descriptor: Int32,
		identity: LeaseGuardianFileIdentity,
		acknowledged: Bool
	) {
		self.token = token
		self.record = record
		self.descriptor = descriptor
		self.identity = identity
		self.acknowledged = acknowledged
		queue = DispatchQueue(label: "com.ergoptiplus.remap-guardian." + token)
	}
}

/// launchd-owned process that waits on exact record locks and fences abandonment.
final class RemapLeaseGuardianRuntime {
	private let paths: LeaseGuardianPaths
	private let executor: LeaseCLIExecuting
	private let cliPath: String
	private let acknowledgementWriter: LeaseGuardianAcknowledgementWriting
	private let maximumUnacknowledgedRecords: Int
	private let terminateProcess: (Int32) -> Void
	private let activationGateLocker: (Int32) -> LeaseGuardianGateLockResult
	private let activationGateRetrySleep: (useconds_t) -> Void
	private let terminationUptime: () -> TimeInterval
	private let singletonProbeObserved: () -> Void
	private let singletonContentionObserved: () -> Void
	private let generation: String
	private let stateQueue = DispatchQueue(label: "com.ergoptiplus.remap-guardian.state")
	private var recoveringAcknowledgements = Set<String>()
	private var watches: [String: LeaseGuardianWatch] = [:]
	private var isTerminating = false
	private var singletonDescriptor: Int32 = -1
	private var activationGateDescriptor: Int32 = -1
	private var recordsDirectoryDescriptor: Int32 = -1
	private var recordsDirectoryIdentity: LeaseGuardianFileIdentity?
	private var directorySource: DispatchSourceFileSystemObject?
	private var safetyTimer: DispatchSourceTimer?
	private var terminationSource: DispatchSourceSignal?

	/// Creates a singleton runtime with production-safe defaults and test seams.
	init(
		paths: LeaseGuardianPaths = LeaseGuardianPaths(),
		executor: LeaseCLIExecuting = PosixLeaseCLIExecutor(),
		cliPath: String = kCanonicalKarabinerCLIPath,
		acknowledgementWriter: @escaping LeaseGuardianAcknowledgementWriting = {
			data, path, directory in
			writeGuardianFileAtomically(data: data, path: path, directory: directory)
		},
		maximumUnacknowledgedRecords: Int = kGuardianMaximumUnacknowledgedRecords,
		terminateProcess: @escaping (Int32) -> Void = { Darwin.exit($0) },
		activationGateLocker: @escaping (Int32) -> LeaseGuardianGateLockResult =
			lockGuardianActivationGate,
		activationGateRetrySleep: @escaping (useconds_t) -> Void = { usleep($0) },
		terminationUptime: @escaping () -> TimeInterval = {
			ProcessInfo.processInfo.systemUptime
		},
		singletonProbeObserved: @escaping () -> Void = {},
		singletonContentionObserved: @escaping () -> Void = {},
		generation: String = UUID().uuidString.replacingOccurrences(
			of: "-",
			with: ""
		).lowercased()
	) {
		self.paths = paths
		self.executor = executor
		self.cliPath = cliPath
		self.acknowledgementWriter = acknowledgementWriter
		self.maximumUnacknowledgedRecords = max(0, maximumUnacknowledgedRecords)
		self.terminateProcess = terminateProcess
		self.activationGateLocker = activationGateLocker
		self.activationGateRetrySleep = activationGateRetrySleep
		self.terminationUptime = terminationUptime
		self.singletonProbeObserved = singletonProbeObserved
		self.singletonContentionObserved = singletonContentionObserved
		self.generation = generation
	}

	/// Releases nonblocking observation resources when a test-owned runtime ends.
	deinit {
		cancelDirectoryObservation()
		safetyTimer?.cancel()
		terminationSource?.cancel()
		if singletonDescriptor >= 0 {
			Darwin.close(singletonDescriptor)
		}
		if activationGateDescriptor >= 0 {
			Darwin.close(activationGateDescriptor)
		}
	}

	/// Starts the singleton and never returns during a healthy launchd lifetime.
	func run() -> Int32 {
		guard prepareGuardianDirectories(paths) else {
			RemapGuardianLog.write(
				key: "startup-directories",
				message: "secure directory preparation failed"
			)
			return LeaseWorkerExit.guardianUnavailable.rawValue
		}
		guard acquireSingletonLock() else {
			RemapGuardianLog.write(
				key: "startup-singleton",
				message: "exclusive singleton acquisition failed (errno=\(errno))"
			)
			return LeaseWorkerExit.guardianUnavailable.rawValue
		}
		guard armTerminationObservation(), armDirectoryObservation() else {
			RemapGuardianLog.write(
				key: "startup-observation",
				message: "signal or records-directory observation failed (errno=\(errno))"
			)
			return LeaseWorkerExit.guardianUnavailable.rawValue
		}
		stateQueue.sync { scanRecords() }
		RemapGuardianLog.write(
			key: "started",
			message: "singleton armed and durable records scanned",
			minimumInterval: 0
		)
		dispatchMain()
	}

	/// Arms the singleton and processes the current durable set without entering
	/// a run loop. Used by process-level XCTest to exercise real flock semantics.
	func processRecordsOnceForTesting() -> Bool {
		guard prepareGuardianDirectories(paths), acquireSingletonLock() else { return false }
		stateQueue.sync { scanRecords() }
		return true
	}

	/// Starts vnode observation without entering dispatchMain for behavioral XCTest.
	func startObservingForTesting() -> Bool {
		guard prepareGuardianDirectories(paths),
			acquireSingletonLock(),
			armDirectoryObservation()
		else { return false }
		stateQueue.sync { scanRecords() }
		return true
	}

	/// Exercises the same SIGTERM drain without terminating the XCTest process.
	func terminateForTesting() {
		stateQueue.async { [weak self] in
			self?.beginTermination(reason: "test termination requested")
		}
	}

	/// Acquires singleton ownership without mistaking transient shared probes for it.
	private func acquireSingletonLock() -> Bool {
		singletonDescriptor = openGuardianRegularFile(paths.singletonLock)
		guard singletonDescriptor >= 0,
			probeSingletonWithoutOwnership()
		else { return false }

		// Drain the old generation before owning the singleton. Otherwise a new
		// exclusive owner could make stale on-disk ACTIVE data impersonate the dead
		// generation while an old shared-gate live write is awaiting its ACK.
		activationGateDescriptor = openGuardianRegularFile(paths.activationGate)
		guard activationGateDescriptor >= 0 else { return false }
		while Darwin.flock(activationGateDescriptor, LOCK_EX) != 0 {
			if errno == EINTR { continue }
			return false
		}
		defer { _ = Darwin.flock(activationGateDescriptor, LOCK_UN) }
		guard acquireSingletonExclusive() else { return false }
		guard let activationIdentity = guardianFileIdentity(
				descriptor: activationGateDescriptor
			),
			let startingState = LeaseGuardianSingletonRecord(
				generation: generation,
				state: .starting,
				activationDevice: Int64(activationIdentity.device),
				activationInode: UInt64(activationIdentity.inode)
			).encoded,
			replaceGuardianData(startingState, descriptor: singletonDescriptor),
			let activeState = LeaseGuardianSingletonRecord(
				generation: generation,
				state: .active,
				activationDevice: Int64(activationIdentity.device),
				activationInode: UInt64(activationIdentity.inode)
			).encoded,
			replaceGuardianData(activeState, descriptor: singletonDescriptor)
		else {
			_ = Darwin.flock(singletonDescriptor, LOCK_UN)
			return false
		}
		return true
	}

	/// Checks for an existing guardian while holding only a compatible shared probe.
	private func probeSingletonWithoutOwnership() -> Bool {
		guard Darwin.flock(singletonDescriptor, LOCK_SH | LOCK_NB) == 0 else {
			return false
		}
		singletonProbeObserved()
		_ = Darwin.flock(singletonDescriptor, LOCK_UN)
		return true
	}

	/// Takes the singleton after activation-gate drain, tolerating shared probes.
	private func acquireSingletonExclusive() -> Bool {
		while Darwin.flock(singletonDescriptor, LOCK_EX | LOCK_NB) != 0 {
			guard errno == EWOULDBLOCK else { return false }
			// A transient shared presence probe is compatible with another shared
			// probe, while a real guardian's exclusive lock is not. Do not let the
			// former make launchd discard its only replacement generation.
			guard Darwin.flock(singletonDescriptor, LOCK_SH | LOCK_NB) == 0 else {
				return false
			}
			_ = Darwin.flock(singletonDescriptor, LOCK_UN)
			singletonContentionObserved()
			usleep(kGuardianSingletonRetryMicroseconds)
		}
		return true
	}

	/// Converts SIGTERM into a serialized exact-token drain request.
	private func armTerminationObservation() -> Bool {
		_ = Darwin.signal(SIGTERM, SIG_IGN)
		let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: stateQueue)
		source.setEventHandler { [weak self] in
			self?.beginTermination(reason: "SIGTERM received")
		}
		terminationSource = source
		source.resume()
		return true
	}

	/// Publishes DRAINING, proves activation order, fences all tokens, and exits.
	private func beginTermination(reason: String) {
		guard !isTerminating else { return }
		isTerminating = true
		var tokens = terminationTokenSnapshot()
		var consecutiveGateFailures = 0
		var lastEmergencyFenceTime: TimeInterval?
		var singletonOwned = true
		drainActivationGate: while true {
			switch activationGateLocker(activationGateDescriptor) {
			case .acquired:
				break drainActivationGate
			case .failed(let lockError):
				if lockError != EINTR {
					consecutiveGateFailures += 1
					if singletonOwned {
						// A broken ordering primitive must not leave stale ACTIVE bytes
						// looking live merely because this process still owns the lock.
						_ = Darwin.flock(singletonDescriptor, LOCK_UN)
						singletonOwned = false
					}
					RemapGuardianLog.write(
						key: "termination-gate",
						message: "activation drain gate failed errno=\(lockError); retrying fail-closed"
					)
					let now = terminationUptime()
					let emergencyFenceIsDue = lastEmergencyFenceTime.map {
						now - $0 >= kGuardianEmergencyFenceIntervalSeconds
					} ?? true
					if consecutiveGateFailures
						>= kGuardianGateFailuresBeforeEmergencyFence,
						emergencyFenceIsDue {
						lastEmergencyFenceTime = now
						fenceTokensSynchronously(tokens)
					}
					let retryDelay = consecutiveGateFailures
						>= kGuardianGateFailuresBeforeEmergencyFence
						? kGuardianDrainFailureRetryMicroseconds
						: kGuardianArmPollMicroseconds
					activationGateRetrySleep(retryDelay)
				}
				continue drainActivationGate
			}
		}
		if !singletonOwned {
			singletonOwned = acquireSingletonExclusive()
		}
		let activationIdentity = guardianFileIdentity(
			descriptor: activationGateDescriptor
		)
		let drainingPublished = singletonOwned && (activationIdentity.flatMap { identity in
			LeaseGuardianSingletonRecord(
				generation: generation,
				state: .draining,
				activationDevice: Int64(identity.device),
				activationInode: UInt64(identity.inode)
			).encoded
		}.map {
			replaceGuardianData($0, descriptor: singletonDescriptor)
		} ?? false)
		if !drainingPublished, singletonOwned {
			// An unchanged ACTIVE payload must never survive a failed transition.
			_ = Darwin.flock(singletonDescriptor, LOCK_UN)
			singletonOwned = false
		}
		RemapGuardianLog.write(
			key: "termination",
			message: "\(reason); fencing every published exact token",
			minimumInterval: 0
		)
		cancelDirectoryObservation()
		safetyTimer?.cancel()
		safetyTimer = nil
		tokens.formUnion(terminationTokenSnapshot())

		guard !tokens.isEmpty else {
			terminateProcess(LeaseWorkerExit.success.rawValue)
			return
		}

		let completion = DispatchGroup()
		for token in tokens.sorted() {
			completion.enter()
			let descriptors = guardianOwnedDescriptors(token: token)
			let executor = self.executor
			let cliPath = self.cliPath
			DispatchQueue.global(qos: .userInitiated).async {
				transportLeaseFenceUntilRepeatedSuccess(
					identity: self.identity(token: token),
					cliPath: cliPath,
					executor: executor,
					cliTimeout: kCLITimeoutSeconds,
					fenceConfirmationGrace: kFenceConfirmationGraceSeconds,
					uptime: { ProcessInfo.processInfo.systemUptime },
					sleep: { usleep($0) },
					closingDescriptors: descriptors
				)
				completion.leave()
			}
		}
		completion.notify(queue: stateQueue) { [weak self] in
			RemapGuardianLog.write(
				key: "termination-complete",
				message: "all published exact tokens fenced before exit",
				minimumInterval: 0
			)
			self?.terminateProcess(LeaseWorkerExit.success.rawValue)
		}
	}

	/// Captures every canonical token named by a watch, record, or durable ACK.
	private func terminationTokenSnapshot() -> Set<String> {
		var tokens = Set(watches.keys)
		if let names = try? FileManager.default.contentsOfDirectory(atPath: paths.records) {
			for name in names where name.hasSuffix(kGuardianRecordSuffix) {
				let token = String(name.dropLast(kGuardianRecordSuffix.count))
				if LeaseGuardianRecord.isCanonicalToken(token) { tokens.insert(token) }
			}
		}
		if let names = try? FileManager.default.contentsOfDirectory(
			atPath: paths.acknowledgements
		) {
			for name in names where name.hasSuffix(kGuardianAckSuffix) {
				let token = String(name.dropLast(kGuardianAckSuffix.count))
				if LeaseGuardianRecord.isCanonicalToken(token) { tokens.insert(token) }
			}
		}
		return tokens
	}

	/// Repeats exact-token tombstones while activation-gate ordering is uncertain.
	private func fenceTokensSynchronously(_ tokens: Set<String>) {
		for token in tokens.sorted() {
			let descriptors = guardianOwnedDescriptors(token: token)
			transportLeaseFenceUntilRepeatedSuccess(
				identity: identity(token: token),
				cliPath: cliPath,
				executor: executor,
				cliTimeout: kCLITimeoutSeconds,
				fenceConfirmationGrace: kFenceConfirmationGraceSeconds,
				uptime: { ProcessInfo.processInfo.systemUptime },
				sleep: { usleep($0) },
				closingDescriptors: descriptors
			)
		}
	}

	/// Arms vnode observation plus a bounded-interval reconciliation scan.
	private func armDirectoryObservation() -> Bool {
		guard installRecordsDirectorySource() else { return false }
		let timer = DispatchSource.makeTimerSource(queue: stateQueue)
		timer.schedule(
			deadline: .now() + kGuardianSafetyScanSeconds,
			repeating: kGuardianSafetyScanSeconds
		)
		timer.setEventHandler { [weak self] in self?.scanRecords() }
		safetyTimer = timer
		timer.resume()
		return true
	}

	/// Binds a vnode source to the exact current records-directory inode.
	private func installRecordsDirectorySource() -> Bool {
		let descriptor = Darwin.open(
			paths.records,
			O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
		)
		guard descriptor >= 0,
			let identity = guardianDirectoryIdentity(descriptor: descriptor)
		else {
			if descriptor >= 0 { Darwin.close(descriptor) }
			return false
		}
		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: descriptor,
			eventMask: [.write, .rename, .delete],
			queue: stateQueue
		)
		source.setEventHandler { [weak self] in self?.handleRecordsDirectoryEvent() }
		source.setCancelHandler { Darwin.close(descriptor) }
		recordsDirectoryDescriptor = descriptor
		recordsDirectoryIdentity = identity
		directorySource = source
		source.resume()
		return true
	}

	/// Cancels the exact directory source before termination token enumeration.
	private func cancelDirectoryObservation() {
		let source = directorySource
		directorySource = nil
		recordsDirectoryDescriptor = -1
		recordsDirectoryIdentity = nil
		source?.cancel()
	}

	/// Drains on namespace replacement and otherwise reconciles record changes.
	private func handleRecordsDirectoryEvent() {
		let event = directorySource?.data ?? []
		if event.contains(.rename) || event.contains(.delete) {
			RemapGuardianLog.write(
				key: "records-invalidated",
				message: "records directory inode changed; draining exact leases",
				minimumInterval: 0
			)
			beginTermination(reason: "records directory identity was invalidated")
			return
		}
		scanRecords()
	}

	/// Reconciles identities, installs bounded watches, and recovers orphan ACKs.
	private func scanRecords() {
		guard !isTerminating else { return }
		if let observed = recordsDirectoryIdentity,
			guardianDirectoryPathIdentity(paths.records) != observed {
			beginTermination(reason: "records directory path no longer names the watched inode")
			return
		}
		for watch in watches.values where
			guardianPathIdentity(paths.recordPath(token: watch.token)) != watch.identity {
			let transferred = readGuardianData(descriptor: watch.descriptor)
				.flatMap(LeaseGuardianRecord.parse)
			if !wasRetiredByExactOwner(watch, transferred: transferred) {
				beginTermination(reason: "live record path identity changed token=\(watch.token)")
				return
			}
		}
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.records)
		else {
			RemapGuardianLog.write(
				key: "records-scan",
				message: "records directory scan failed"
			)
			if recordsDirectoryIdentity != nil {
				beginTermination(reason: "records directory scan failed")
			}
			return
		}
		let candidates = names.compactMap { name -> (String, Bool)? in
			guard name.hasSuffix(kGuardianRecordSuffix) else { return nil }
			let token = String(name.dropLast(kGuardianRecordSuffix.count))
			guard LeaseGuardianRecord.isCanonicalToken(token), watches[token] == nil
			else { return nil }
			return (token, recordHasMatchingAcknowledgement(token: token))
		}.sorted { left, right in
			if left.1 != right.1 { return left.1 && !right.1 }
			return left.0 < right.0
		}
		for (token, _) in candidates {
			installWatch(token: token)
		}
		scanOrphanedAcknowledgements()
	}

	/// Fences journals that no exact LIVE record can still justify.
	private func scanOrphanedAcknowledgements() {
		guard !isTerminating,
			let names = try? FileManager.default.contentsOfDirectory(
				atPath: paths.acknowledgements
			)
		else { return }
		for name in names where name.hasSuffix(kGuardianAckSuffix) {
			let token = String(name.dropLast(kGuardianAckSuffix.count))
			guard LeaseGuardianRecord.isCanonicalToken(token),
				watches[token] == nil,
				let observation = readGuardianAcknowledgement(
					token: token,
					paths: paths
				),
				!guardianRecordMatches(
					observation.acknowledgement,
					paths: paths
				)
			else { continue }
			let key = [
				observation.acknowledgement.token,
				observation.acknowledgement.nonce,
				observation.acknowledgement.guardianGeneration,
			].joined(separator: ":")
			guard recoveringAcknowledgements.insert(key).inserted else { continue }
			let executor = self.executor
			let descriptors = guardianOwnedDescriptors(token: token)
			DispatchQueue.global(qos: .userInitiated).async { [weak self] in
				guard let self else { return }
				transportLeaseFenceUntilRepeatedSuccess(
					identity: self.identity(token: token),
					cliPath: self.cliPath,
					executor: executor,
					cliTimeout: kCLITimeoutSeconds,
					fenceConfirmationGrace: kFenceConfirmationGraceSeconds,
					uptime: { ProcessInfo.processInfo.systemUptime },
					sleep: { usleep($0) },
					closingDescriptors: descriptors
				)
				self.stateQueue.async { [weak self] in
					guard let self else { return }
					removeGuardianAcknowledgement(
						observation.acknowledgement,
						expectedIdentity: observation.identity,
						paths: self.paths
					)
					self.recoveringAcknowledgements.remove(key)
				}
			}
		}
	}

	/// Tests whether one acknowledgement still has the exact LIVE source record.
	private func guardianRecordMatches(
		_ acknowledgement: LeaseGuardianAcknowledgement,
		paths: LeaseGuardianPaths
	) -> Bool {
		let descriptor = Darwin.open(
			paths.recordPath(token: acknowledgement.token),
			O_RDONLY | O_CLOEXEC | O_NOFOLLOW
		)
		guard descriptor >= 0 else { return false }
		defer { Darwin.close(descriptor) }
		guard guardianFileIdentity(descriptor: descriptor) != nil,
			let record = readGuardianData(descriptor: descriptor)
				.flatMap(LeaseGuardianRecord.parse)
		else { return false }
		return record.token == acknowledgement.token
			&& record.nonce == acknowledgement.nonce
			&& record.state == .live
	}

	/// Recognizes a prior-generation ACK so active records outrank the unarmed cap.
	private func recordHasMatchingAcknowledgement(token: String) -> Bool {
		let descriptor = Darwin.open(
			paths.recordPath(token: token),
			O_RDONLY | O_CLOEXEC | O_NOFOLLOW
		)
		guard descriptor >= 0 else { return false }
		defer { Darwin.close(descriptor) }
		guard guardianFileIdentity(descriptor: descriptor) != nil,
			let record = readGuardianData(descriptor: descriptor)
				.flatMap(LeaseGuardianRecord.parse),
			record.token == token,
			record.state == .live,
			let acknowledgement = readGuardianAcknowledgement(
				token: token,
				paths: paths
			)?.acknowledgement,
			acknowledgement.token == token,
			acknowledgement.nonce == record.nonce
		else { return false }
		return true
	}

	/// Opens, validates, ACKs, and waits on one canonical record without polling.
	private func installWatch(token: String) {
		guard !isTerminating else { return }
		let path = paths.recordPath(token: token)
		let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
		guard descriptor >= 0,
			let identity = guardianFileIdentity(descriptor: descriptor)
		else {
			RemapGuardianLog.write(
				key: "record-open-\(token)",
				message: "record open or identity validation failed token=\(token) errno=\(errno)"
			)
			if descriptor >= 0 { Darwin.close(descriptor) }
			return
		}
		let parsed = readGuardianData(descriptor: descriptor).flatMap(LeaseGuardianRecord.parse)
		let record = parsed?.token == token && parsed?.state == .live ? parsed : nil
		let acknowledged = record.map {
			guardianAcknowledgementMatches(
				record: $0,
				guardianGeneration: generation,
				paths: paths
			)
		} ?? false
		let previouslyAcknowledged = record.map {
			recordHasMatchingAcknowledgement(token: $0.token)
		} ?? false
		let unacknowledgedCount = watches.values.reduce(into: 0) { count, watch in
			if !watch.acknowledged { count += 1 }
		}
		guard previouslyAcknowledged
			|| acknowledged
			|| unacknowledgedCount < maximumUnacknowledgedRecords
		else {
			RemapGuardianLog.write(
				key: "record-cap",
				message: "unacknowledged record cap reached; refusing token=\(token)"
			)
			Darwin.close(descriptor)
			return
		}
		let watch = LeaseGuardianWatch(
			token: token,
			record: record,
			descriptor: descriptor,
			identity: identity,
			acknowledged: acknowledged
		)
		watches[token] = watch

		if Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
			watch.queue.async { [weak self] in self?.fenceIfAbandoned(watch) }
			return
		}
		guard errno == EWOULDBLOCK else {
			finishWatch(watch)
			return
		}

		watch.queue.async { [weak self] in
			while Darwin.flock(descriptor, LOCK_EX) != 0 {
				if errno == EINTR { continue }
				let waitError = errno
				self?.stateQueue.async { [weak self] in
					self?.beginTermination(
						reason: "record lock wait failed token=\(token) errno=\(waitError)"
					)
				}
				return
			}
			self?.fenceIfAbandoned(watch)
		}
		if let acknowledgement = record?.acknowledgement(
			guardianGeneration: generation
		) {
			watch.acknowledged = acknowledgementWriter(
				acknowledgement,
				paths.acknowledgementPath(token: token),
				paths.acknowledgements
			)
			if !watch.acknowledged {
				RemapGuardianLog.write(
					key: "ack-write-\(token)",
					message: "durable ARMED acknowledgement failed token=\(token) errno=\(errno)"
				)
			}
		}
	}

	/// Fences an acquired record unless its exact owner wrote canonical RETIRED.
	private func fenceIfAbandoned(_ watch: LeaseGuardianWatch) {
		let transferredRecord = readGuardianData(descriptor: watch.descriptor)
			.flatMap(LeaseGuardianRecord.parse)
		let retiredGracefully = wasRetiredByExactOwner(
			watch,
			transferred: transferredRecord
		)
		// Link count is not an ownership proof: an external cleanup can unlink a
		// live record before its owner dies. Only the locked RETIRED marker written
		// after a successful exact fence may suppress the guardian's own fence.
		if !retiredGracefully {
			RemapGuardianLog.write(
				key: "fence-start-\(watch.token)",
				message: "abandoned exact token detected; fencing token=\(watch.token)",
				minimumInterval: 0
			)
			transportLeaseFenceUntilRepeatedSuccess(
				identity: identity(token: watch.token),
				cliPath: cliPath,
				executor: executor,
				cliTimeout: kCLITimeoutSeconds,
				fenceConfirmationGrace: kFenceConfirmationGraceSeconds,
				uptime: { ProcessInfo.processInfo.systemUptime },
				sleep: { usleep($0) },
				closingDescriptors: guardianOwnedDescriptors(watch)
			)
			RemapGuardianLog.write(
				key: "fence-complete-\(watch.token)",
				message: "exact token fenced twice token=\(watch.token)",
				minimumInterval: 0
			)
		}

		stateQueue.async { [weak self] in self?.completeWatchCleanup(watch) }
	}

	/// Accepts retirement only from the exact nonce and PID observed while LIVE.
	private func wasRetiredByExactOwner(
		_ watch: LeaseGuardianWatch,
		transferred: LeaseGuardianRecord?
	) -> Bool {
		guard let original = watch.record, let transferred else { return false }
		return original.token == transferred.token
			&& original.nonce == transferred.nonce
			&& original.ownerPID == transferred.ownerPID
			&& original.state == .live
			&& transferred.state == .retired
	}

	/// Lists every guardian capability that one CLI child must close explicitly.
	private func guardianOwnedDescriptors(_ watch: LeaseGuardianWatch) -> [Int32] {
		return [
			singletonDescriptor,
			activationGateDescriptor,
			recordsDirectoryDescriptor,
			watch.descriptor,
		].filter { $0 >= 0 }
	}

	/// Lists guardian capabilities for a token that may not have a live watch.
	private func guardianOwnedDescriptors(token: String) -> [Int32] {
		var descriptors = [
			singletonDescriptor,
			activationGateDescriptor,
			recordsDirectoryDescriptor,
		]
		if let watch = watches[token] { descriptors.append(watch.descriptor) }
		return descriptors.filter { $0 >= 0 }
	}

	/// Derives the only two mutable Karabiner variable names from an exact token.
	private func identity(token: String) -> LeaseIdentity {
		return LeaseIdentity(
			cliPath: cliPath,
			token: token,
			modeName: "ergopti_mode_\(token)",
			revokedName: "ergopti_revoked_\(token)",
			initialMode: kLeaseModeActive,
			heartbeatSeconds: kDefaultHeartbeatSeconds
		)
	}

	/// Removes and closes a watch that could not establish reliable lock waiting.
	private func finishWatch(_ watch: LeaseGuardianWatch) {
		guard watches[watch.token] === watch else { return }
		watches.removeValue(forKey: watch.token)
		Darwin.close(watch.descriptor)
	}

	/// Removes only exact record and ACK identities after repeated fencing or retirement.
	private func completeWatchCleanup(_ watch: LeaseGuardianWatch) {
		guard watches[watch.token] === watch else { return }
		watches.removeValue(forKey: watch.token)
		_ = unlinkGuardianPath(
			paths.recordPath(token: watch.token),
			expectedIdentity: watch.identity
		)
		_ = fsyncGuardianDirectory(paths.records)
		if let record = watch.record {
			removeGuardianAcknowledgement(
				LeaseGuardianAcknowledgement(
					token: record.token,
					nonce: record.nonce,
					guardianGeneration: generation
				),
				paths: paths
			)
		}
		Darwin.close(watch.descriptor)
	}
}





// ==============================================
// ==============================================
// ======= 5/ Per-User Service Registration =====
// ==============================================
// ==============================================

/// Escapes one absolute executable path for the legacy XML property list.
private func xmlEscapedGuardianValue(_ value: String) -> String {
	return value
		.replacingOccurrences(of: "&", with: "&amp;")
		.replacingOccurrences(of: "<", with: "&lt;")
		.replacingOccurrences(of: ">", with: "&gt;")
		.replacingOccurrences(of: "\"", with: "&quot;")
		.replacingOccurrences(of: "'", with: "&apos;")
}

/// Builds the exact own-label legacy LaunchAgent property list.
func legacyGuardianPlist(executablePath: String) -> String {
	let executable = xmlEscapedGuardianValue(executablePath)
	return """
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
		<key>Label</key>
		<string>\(kRemapGuardianLabel)</string>
		<key>ProgramArguments</key>
		<array>
			<string>\(executable)</string>
			<string>\(kKarabinerLeaseGuardianFlag)</string>
		</array>
		<key>RunAtLoad</key>
		<true/>
		<key>KeepAlive</key>
		<true/>
		<key>ProcessType</key>
		<string>Background</string>
		<key>ThrottleInterval</key>
		<integer>\(kGuardianThrottleIntervalSeconds)</integer>
		<key>AssociatedBundleIdentifiers</key>
		<array><string>\(kErgoptiBundleId)</string></array>
	</dict>
	</plist>
	"""
}

/// Compares the installed legacy plist bytes without following replacement links.
private func legacyGuardianPlistMatches(
	_ expected: Data,
	path: String
) -> Bool {
	let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
	guard descriptor >= 0 else { return false }
	defer { Darwin.close(descriptor) }
	guard guardianFileIdentity(descriptor: descriptor) != nil,
		let observed = readGuardianData(descriptor: descriptor, maximumBytes: 16_384)
	else { return false }
	return observed == expected
}

/// Waits a bounded interval for an exclusively held ACTIVE singleton generation.
func waitForLegacyGuardianHealth(_ paths: LeaseGuardianPaths) -> Bool {
	let deadline = ProcessInfo.processInfo.systemUptime + kLegacyLaunchctlTimeoutSeconds
	repeat {
		let singleton = Darwin.open(
			paths.singletonLock,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		let activationGate = Darwin.open(
			paths.activationGate,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW
		)
		if singleton >= 0, activationGate >= 0,
			activeGuardianGeneration(
				descriptor: singleton,
				activationGateDescriptor: activationGate
			) != nil {
			Darwin.close(singleton)
			Darwin.close(activationGate)
			return true
		}
		if singleton >= 0 { Darwin.close(singleton) }
		if activationGate >= 0 { Darwin.close(activationGate) }
		usleep(kGuardianArmPollMicroseconds)
	} while ProcessInfo.processInfo.systemUptime < deadline
	return false
}

protocol GuardianLaunchctlRunning {
	/// Runs one exact launchctl argv vector and returns its reaped success status.
	func run(arguments: [String]) -> Bool
}

/// Runs one exact launchctl child whose unreaped PID remains owned until every
/// timeout signal is complete, so PID reuse cannot redirect termination.
final class PosixGuardianLaunchctlRunner: GuardianLaunchctlRunning {
	/// Spawns and reaps only the exact launchctl child, with bounded owned-PID signals.
	func run(arguments: [String]) -> Bool {
		prepareLeaseChildReaping()
		let openedNull = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
		guard openedNull >= 0 else { return false }
		let nullDescriptor: Int32
		if openedNull <= STDERR_FILENO {
			nullDescriptor = fcntl(openedNull, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
			Darwin.close(openedNull)
		} else {
			nullDescriptor = openedNull
		}
		guard nullDescriptor > STDERR_FILENO else { return false }
		defer { Darwin.close(nullDescriptor) }

		var fileActions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&fileActions) == 0 else { return false }
		defer { posix_spawn_file_actions_destroy(&fileActions) }
		for target in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
			guard posix_spawn_file_actions_adddup2(
				&fileActions,
				nullDescriptor,
				target
			) == 0 else { return false }
		}
		if nullDescriptor > STDERR_FILENO {
			guard posix_spawn_file_actions_addclose(&fileActions, nullDescriptor) == 0
			else { return false }
		}

		let launchctlPath = "/bin/launchctl"
		guard let rawArguments = duplicateLeaseArguments([launchctlPath] + arguments)
		else { return false }
		defer { for case let pointer? in rawArguments { free(pointer) } }
		var mutableArguments = rawArguments
		var childPID: pid_t = 0
		let spawnStatus = mutableArguments.withUnsafeMutableBufferPointer { buffer in
			posix_spawn(
				&childPID,
				launchctlPath,
				&fileActions,
				nil,
				buffer.baseAddress,
				_NSGetEnviron().pointee
			)
		}
		guard spawnStatus == 0 else { return false }

		let deadline = ProcessInfo.processInfo.systemUptime
			+ kLegacyLaunchctlTimeoutSeconds
		var status: Int32 = 0
		while ProcessInfo.processInfo.systemUptime < deadline {
			let waited = Darwin.waitpid(childPID, &status, WNOHANG)
			if waited == childPID { return childExitedSuccessfully(status) }
			if waited == -1 && errno != EINTR { return false }
			usleep(kGuardianArmPollMicroseconds)
		}

		_ = Darwin.kill(childPID, SIGTERM)
		let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.25
		while ProcessInfo.processInfo.systemUptime < terminationDeadline {
			let waited = Darwin.waitpid(childPID, &status, WNOHANG)
			if waited == childPID { return false }
			if waited == -1 && errno != EINTR { return false }
			usleep(kGuardianArmPollMicroseconds)
		}
		_ = Darwin.kill(childPID, SIGKILL)
		while Darwin.waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
		return false
	}

	/// Decodes a waitpid status without trusting a signalled child as success.
	private func childExitedSuccessfully(_ status: Int32) -> Bool {
		return status & 0x7F == 0 && ((status >> 8) & 0xFF) == 0
	}
}

/// Reuses or atomically replaces only ErgoptiPlus's exact per-user legacy job.
func ensureLegacyRemapGuardianRegistered(
	executablePath: String,
	runner: GuardianLaunchctlRunning = PosixGuardianLaunchctlRunner(),
	homeDirectory: String = NSHomeDirectory(),
	guardianHealth: (LeaseGuardianPaths) -> Bool = waitForLegacyGuardianHealth
) -> Bool {
	let launchAgents = homeDirectory + "/Library/LaunchAgents"
	let domain = "gui/\(getuid())"
	let serviceTarget = domain + "/" + kRemapGuardianLabel
	let plistPath = launchAgents + "/" + kRemapGuardianPlistName
	let paths = LeaseGuardianPaths(homeDirectory: homeDirectory)
	guard let data = legacyGuardianPlist(
		executablePath: executablePath
	).data(using: .utf8) else { return false }
	let jobIsLoaded = runner.run(arguments: ["print", serviceTarget])
	if jobIsLoaded,
		legacyGuardianPlistMatches(data, path: plistPath),
		guardianHealth(paths) {
		return true
	}
	if jobIsLoaded,
		!runner.run(arguments: ["bootout", serviceTarget]) {
		return false
	}

	guard secureGuardianDirectory(launchAgents),
		writeGuardianFileAtomically(
			data: data,
			path: plistPath,
			directory: launchAgents
		)
	else { return false }
	_ = Darwin.chmod(plistPath, 0o600)

	if !runner.run(arguments: ["bootstrap", domain, plistPath]),
		!runner.run(arguments: ["print", serviceTarget]) {
		return false
	}
	return runner.run(arguments: ["print", serviceTarget])
		&& guardianHealth(paths)
}

/// Legacy bootstrap is a development-signature compatibility path, never a
/// bypass for a user-disabled or unapproved modern Background Item.
@available(macOS 13.0, *)
func shouldUseLegacyGuardianAfterModernRegistrationError(_ error: Error) -> Bool {
	let registrationError = error as NSError
	return registrationError.domain == kRemapGuardianServiceErrorDomain
		&& registrationError.code == kSMErrorInvalidSignature
}

enum RemapGuardianRegistrationStatus: String, Equatable {
	case ready
	case requiresApproval = "requires_approval"
	case unavailable
}

@available(macOS 13.0, *)
/// Recognizes only the ServiceManagement error representing user approval state.
private func modernGuardianErrorRequiresApproval(_ error: Error) -> Bool {
	let registrationError = error as NSError
	return registrationError.domain == kRemapGuardianServiceErrorDomain
		&& registrationError.code == kSMErrorLaunchDeniedByUser
}

@available(macOS 13.0, *)
protocol RemapGuardianModernService: AnyObject {
	var status: SMAppService.Status { get }
	/// Requests registration through Apple's Background Items authority.
	func register() throws
}

@available(macOS 13.0, *)
extension SMAppService: RemapGuardianModernService {}

/// Resolves the complete modern registration state with injectable boundaries.
/// User denial and approval never reach the legacy launchctl compatibility path.
@available(macOS 13.0, *)
func resolveModernRemapGuardianRegistration(
	service: RemapGuardianModernService,
	guardianHealth: () -> Bool,
	legacyInvalidSignatureFallback: () -> Bool
) -> RemapGuardianRegistrationStatus {
	switch service.status {
	case .enabled:
		return guardianHealth() ? .ready : .unavailable
	case .notRegistered:
		do {
			try service.register()
			switch service.status {
			case .enabled:
				return guardianHealth() ? .ready : .unavailable
			case .requiresApproval:
				return .requiresApproval
			case .notRegistered, .notFound:
				return .unavailable
			@unknown default:
				return .unavailable
			}
		} catch {
			if service.status == .enabled {
				return guardianHealth() ? .ready : .unavailable
			}
			if service.status == .requiresApproval
				|| modernGuardianErrorRequiresApproval(error) {
				return .requiresApproval
			}
			guard shouldUseLegacyGuardianAfterModernRegistrationError(error)
			else { return .unavailable }
			// Current ZIP releases are ad-hoc signed. Only an exact invalid-
			// signature result may use the legacy per-user bootstrap; denial,
			// approval, authorization, and unknown failures stay fail-closed.
			return legacyInvalidSignatureFallback() ? .ready : .unavailable
		}
	case .requiresApproval:
		return .requiresApproval
	case .notFound:
		return .unavailable
	@unknown default:
		return .unavailable
	}
}

/// Registers only ErgoptiPlus's own user LaunchAgent before Hammerspoon starts.
/// A denied/disabled background item leaves the remap lease unable to ARM; the
/// application itself may still launch so the user can recover from its menu.
func remapGuardianRegistrationStatus(
	executablePath: String
) -> RemapGuardianRegistrationStatus {
	guard !executablePath.isEmpty else { return .unavailable }
	if #available(macOS 13.0, *) {
		let service = SMAppService.agent(plistName: kRemapGuardianPlistName)
		return resolveModernRemapGuardianRegistration(
			service: service,
			guardianHealth: {
				waitForLegacyGuardianHealth(LeaseGuardianPaths())
			},
			legacyInvalidSignatureFallback: {
				ensureLegacyRemapGuardianRegistered(executablePath: executablePath)
			}
		)
	}
	return ensureLegacyRemapGuardianRegistered(executablePath: executablePath)
		? .ready
		: .unavailable
}

/// Returns whether the independent guardian is registered and currently healthy.
func ensureRemapGuardianRegistered(executablePath: String) -> Bool {
	return remapGuardianRegistrationStatus(executablePath: executablePath) == .ready
}
