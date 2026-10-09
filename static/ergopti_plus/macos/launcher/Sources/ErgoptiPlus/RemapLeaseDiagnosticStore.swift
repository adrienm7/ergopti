// Private retained technical records; no lease or input authority is established by this store.
import Darwin
import Foundation

enum LeaseDiagnosticObservationState: String, Codable { case observed, unobserved }

struct LeaseDiagnosticEnvelope: Encodable {
	let schema = 1
	let state: LeaseDiagnosticObservationState
	let retention = "historical"
	let currentness = "unknown"
	let records: [LeaseTerminalExport]

	func encodedEnvelope() -> Data? {
		guard records.count <= 2,
			Set(records.map { $0.role.rawValue }).count == records.count,
			records.map { $0.role } == [LeaseTerminalRole.inner, .outer].filter { role in records.contains { $0.role == role } },
			records.allSatisfy({ $0.encodedRecord() != nil }),
			(state == .observed) == !records.isEmpty
		else { return nil }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		guard let data = try? encoder.encode(self), data.count <= 2048 else { return nil }
		return data
	}
}

/// Reader never invokes the creating/chmod-capable writer directory resolver.
struct RemapLeaseDiagnosticStore {
	private let directoryPath: String
	private let afterSingleRead: ((LeaseTerminalRole) -> Void)?

	init() {
		directoryPath = NSHomeDirectory() + "/" + kMacOSLogsHomeRelativePath
		afterSingleRead = nil
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Private filesystem fixture injection; the release CLI has no path argument.
	init(testingDirectory: URL, afterSingleRead: ((LeaseTerminalRole) -> Void)? = nil) {
		directoryPath = testingDirectory.path
		self.afterSingleRead = afterSingleRead
	}
	#endif

	private func filename(_ role: LeaseTerminalRole) -> String {
		return role == .inner ? "remap-lease-diagnostic-inner.json" : "remap-lease-diagnostic-outer.json"
	}

	private func ownedDirectory(_ value: stat) -> Bool {
		return (value.st_mode & S_IFMT) == S_IFDIR && value.st_uid == geteuid()
			&& (value.st_mode & 0o7777) == 0o700
	}

	private func ownedRecord(_ value: stat) -> Bool {
		return (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == geteuid()
			&& (value.st_mode & 0o7777) == 0o600 && value.st_nlink == 1
			&& value.st_size > 0 && value.st_size <= 512
	}

	private func sameIdentity(_ left: stat, _ right: stat, includeContentMetadata: Bool) -> Bool {
		guard left.st_dev == right.st_dev, left.st_ino == right.st_ino,
			left.st_mode == right.st_mode, left.st_uid == right.st_uid,
			left.st_gid == right.st_gid, left.st_nlink == right.st_nlink
		else { return false }
		if !includeContentMetadata { return true }
		return left.st_size == right.st_size
			&& left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
			&& left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
			&& left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
			&& left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
	}

	/// A metadata-only namespace cut; O_NOFOLLOW_ANY also refuses changed ancestor aliases.
	private func directoryCurrent(_ path: String, descriptor: Int32, expected: stat, strict: Bool) -> Bool {
		var held = stat(), named = stat(), reopened = stat()
		guard Darwin.fstat(descriptor, &held) == 0, ownedDirectory(held),
			Darwin.lstat(path, &named) == 0, ownedDirectory(named),
			sameIdentity(expected, held, includeContentMetadata: strict),
			sameIdentity(held, named, includeContentMetadata: strict)
		else { return false }
		let cut = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
		guard cut >= 0 else { return false }
		defer { _ = Darwin.close(cut) }
		return Darwin.fstat(cut, &reopened) == 0 && ownedDirectory(reopened)
			&& sameIdentity(held, reopened, includeContentMetadata: strict)
	}

	/// Single bounded read from one retained private regular FD, followed by file/name/namespace cuts.
	private func read(_ role: LeaseTerminalRole, directory: Int32, identity: stat) -> LeaseTerminalExport? {
		let name = filename(role)
		var before = stat(), opened = stat()
		guard Darwin.fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0, ownedRecord(before)
		else { return nil }
		let descriptor = Darwin.openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { return nil }
		defer { _ = Darwin.close(descriptor) }
		guard Darwin.fstat(descriptor, &opened) == 0, ownedRecord(opened),
			sameIdentity(before, opened, includeContentMetadata: true)
		else { return nil }
		var bytes = [UInt8](repeating: 0, count: 513)
		let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
		afterSingleRead?(role)
		var held = stat(), named = stat()
		guard count == Int(opened.st_size), count > 0, count <= 512,
			Darwin.fstat(descriptor, &held) == 0, ownedRecord(held),
			Darwin.fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0, ownedRecord(named),
			sameIdentity(opened, held, includeContentMetadata: true),
			sameIdentity(held, named, includeContentMetadata: true),
			directoryCurrent(directoryPath, descriptor: directory, expected: identity, strict: true),
			let record = LeaseTerminalExport.decode(Data(bytes.prefix(count))), record.role == role
		else { return nil }
		return record
	}

	/// Missing/refused records yield unobserved; this method performs no mutation or lease bootstrap.
	func observe() -> LeaseDiagnosticEnvelope {
		let absent = LeaseDiagnosticEnvelope(state: .unobserved, records: [])
		let directory = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
		guard directory >= 0 else { return absent }
		defer { _ = Darwin.close(directory) }
		var identity = stat()
		guard Darwin.fstat(directory, &identity) == 0, ownedDirectory(identity),
			directoryCurrent(directoryPath, descriptor: directory, expected: identity, strict: true)
		else { return absent }
		let records = [LeaseTerminalRole.inner, .outer].compactMap { read($0, directory: directory, identity: identity) }
		guard directoryCurrent(directoryPath, descriptor: directory, expected: identity, strict: true)
		else { return absent }
		return LeaseDiagnosticEnvelope(state: records.isEmpty ? .unobserved : .observed, records: records)
	}

	/// Best-effort fixed-role atomic publication, called only after original terminal fence settlement.
	@discardableResult func retain(_ record: LeaseTerminalExport) -> Bool {
		guard let data = record.encodedRecord(),
			case .success(let opened) = OwnedLogDirectoryResolver.open(directoryPath)
		else { return false }
		let directory = opened.descriptor
		defer { _ = Darwin.close(directory) }
		var identity = stat()
		guard Darwin.fstat(directory, &identity) == 0, ownedDirectory(identity),
			directoryCurrent(opened.resolvedPath, descriptor: directory, expected: identity, strict: false)
		else { return false }
		let name = filename(record.role), temporary = name + ".tmp"
		var existing = stat()
		let namedStatus = Darwin.fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW)
		guard (namedStatus == 0 ? ownedRecord(existing) : errno == ENOENT) else { return false }
		let descriptor = Darwin.openat(directory, temporary,
			O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
		guard descriptor >= 0 else { return false }
		var published = false
		defer {
			if !published {
				var held = stat(), named = stat()
				if Darwin.fstat(descriptor, &held) == 0,
					Darwin.fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
					sameIdentity(held, named, includeContentMetadata: false) {
					_ = Darwin.unlinkat(directory, temporary, 0)
				}
			}
			_ = Darwin.close(descriptor)
		}
		guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { return false }
		let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
		var held = stat(), named = stat()
		guard written == data.count, Darwin.fsync(descriptor) == 0,
			Darwin.fstat(descriptor, &held) == 0, ownedRecord(held), held.st_size == off_t(data.count),
			Darwin.fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
			sameIdentity(held, named, includeContentMetadata: true),
			directoryCurrent(opened.resolvedPath, descriptor: directory, expected: identity, strict: false),
			Darwin.renameat(directory, temporary, directory, name) == 0
		else { return false }
		published = true
		return Darwin.fsync(directory) == 0
			&& directoryCurrent(opened.resolvedPath, descriptor: directory, expected: identity, strict: false)
	}

	/// Holding the original vnode prevents inode reuse from impersonating the baseline.
	private final class NextRecordWitness {
		let descriptor: Int32
		let identity: stat
		let record: LeaseTerminalExport

		init(descriptor: Int32, identity: stat, record: LeaseTerminalExport) {
			self.descriptor = descriptor
			self.identity = identity
			self.record = record
		}

		deinit { _ = Darwin.close(descriptor) }
	}

	/// Reads and pins the same private vnode whose closed bytes are returned.
	private func nextRecord(_ role: LeaseTerminalRole, directory: Int32, identity: stat) -> NextRecordWitness? {
		let name = filename(role)
		var before = stat(), opened = stat()
		guard Darwin.fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0, ownedRecord(before)
		else { return nil }
		let descriptor = Darwin.openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { return nil }
		var retained = false
		defer { if !retained { _ = Darwin.close(descriptor) } }
		guard Darwin.fstat(descriptor, &opened) == 0, ownedRecord(opened),
			sameIdentity(before, opened, includeContentMetadata: true)
		else { return nil }
		var bytes = [UInt8](repeating: 0, count: 513)
		let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
		afterSingleRead?(role)
		var held = stat(), named = stat()
		guard count == Int(opened.st_size), count > 0, count <= 512,
			Darwin.fstat(descriptor, &held) == 0, ownedRecord(held),
			Darwin.fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0, ownedRecord(named),
			sameIdentity(opened, held, includeContentMetadata: true),
			sameIdentity(held, named, includeContentMetadata: true),
			directoryCurrent(directoryPath, descriptor: directory, expected: identity, strict: true),
			let record = LeaseTerminalExport.decode(Data(bytes.prefix(count))), record.role == role
		else { return nil }
		retained = true
		return NextRecordWitness(descriptor: descriptor, identity: held, record: record)
	}

	/// Arms only a stable private namespace, then latches its first qualified new vnode.
	/// The fixed wait is bounded; synchronous filesystem/stdout latency is not a hard process deadline.
	func observeNext(
		emit: (LeaseDiagnosticNextFrame) -> Bool,
		uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
		sleep: (useconds_t) -> Void = { _ = Darwin.usleep($0) }
	) -> Bool {
		let absent = LeaseDiagnosticNextFrame(phase: .unobserved, records: [])
		let directory = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
		guard directory >= 0 else { return emit(absent) }
		defer { _ = Darwin.close(directory) }
		var identity = stat()
		guard Darwin.fstat(directory, &identity) == 0, ownedDirectory(identity),
			directoryCurrent(directoryPath, descriptor: directory, expected: identity, strict: true)
		else { return emit(absent) }
		let roles = [LeaseTerminalRole.inner, .outer]
		var baseline: [String: NextRecordWitness] = [:]
		defer { withExtendedLifetime(baseline) {} }
		for role in roles {
			var named = stat()
			if Darwin.fstatat(directory, filename(role), &named, AT_SYMLINK_NOFOLLOW) == 0 {
				guard let witness = nextRecord(role, directory: directory, identity: identity)
				else { return emit(absent) }
				baseline[role.rawValue] = witness
			} else if errno != ENOENT { return emit(absent) }
		}
		// All baseline cuts precede the armed callback; callbacks never grant native authority.
		for role in roles {
			var named = stat()
			let status = Darwin.fstatat(directory, filename(role), &named, AT_SYMLINK_NOFOLLOW)
			if let witness = baseline[role.rawValue] {
				var held = stat()
				guard status == 0, Darwin.fstat(witness.descriptor, &held) == 0,
					ownedRecord(held), ownedRecord(named),
					sameIdentity(witness.identity, held, includeContentMetadata: true),
					sameIdentity(held, named, includeContentMetadata: true)
				else { return emit(absent) }
			} else if status == 0 || errno != ENOENT { return emit(absent) }
		}
		guard directoryCurrent(directoryPath, descriptor: directory, expected: identity, strict: true)
		else { return emit(absent) }
		let start = uptime(), deadline = start + 30
		guard start.isFinite, start >= 0, deadline.isFinite, deadline > start else { return emit(absent) }
		guard emit(LeaseDiagnosticNextFrame(phase: .armed, records: [])) else { return false }
		var last = start
		for turn in 0..<600 {
			let now = uptime()
			guard now.isFinite, now >= last, now < deadline else { break }
			last = now
			guard directoryCurrent(directoryPath, descriptor: directory, expected: identity, strict: false)
			else { break }
			var cut = stat()
			guard Darwin.fstat(directory, &cut) == 0, ownedDirectory(cut) else { break }
			for role in roles {
				guard let candidate = nextRecord(role, directory: directory, identity: cut) else { continue }
				if let previous = baseline[role.rawValue],
					previous.identity.st_dev == candidate.identity.st_dev,
					previous.identity.st_ino == candidate.identity.st_ino { continue }
				let admitted = uptime()
				guard admitted.isFinite, admitted >= last, admitted < deadline else { return emit(absent) }
				// A later publication cannot overwrite this already captured typed value.
				return emit(LeaseDiagnosticNextFrame(phase: .observed, records: [candidate.record]))
			}
			let after = uptime()
			guard after.isFinite, after >= last, after < deadline, turn < 599 else { break }
			last = after
			let microseconds = useconds_t((min(0.05, deadline - after) * 1_000_000).rounded(.down))
			guard microseconds > 0 else { break }
			sleep(microseconds)
		}
		return emit(absent)
	}
}

/// Closed passive observations never identify an input generation or a writer.
enum LeaseDiagnosticNextPhase: String, Codable { case armed, observed, unobserved }

struct LeaseDiagnosticNextFrame: Encodable {
	let schema = 1
	let scope = "first-observed-new-record"
	let currentness = "unknown"
	let phase: LeaseDiagnosticNextPhase
	let records: [LeaseTerminalExport]

	func encodedFrame() -> Data? {
		guard records.count <= 1, (phase == .observed) == !records.isEmpty,
			records.allSatisfy({ $0.encodedRecord() != nil })
		else { return nil }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		guard let data = try? encoder.encode(self), data.count <= 2048 else { return nil }
		return data
	}
}
