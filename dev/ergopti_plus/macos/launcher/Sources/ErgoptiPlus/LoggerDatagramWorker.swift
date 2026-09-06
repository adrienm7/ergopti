// Sources/ErgoptiPlus/LoggerDatagramWorker.swift

// ==============================================================================
// MODULE: Native Logger Datagram Worker
// DESCRIPTION:
// Owns every blocking Hammerspoon log side effect in the native launcher. The
// Lua eventtap path only appends an in-memory record; a timer sends that record
// over authenticated loopback UDP, and this serial background worker persists
// it before acknowledging the exact session/sequence pair.
//
// FEATURES & RATIONALE:
// 1. Pre-bound authority: the socket exists before embedded Hammerspoon starts,
//    so a missing worker fails launch rather than degrading after taps are live.
// 2. Session + sequence idempotence: retries are ACKed without duplicate writes,
//    gaps are rejected, and hs.reload may restart sequence 1 safely.
// 3. Descriptor-relative sinks: configured directories and files are validated
//    without following their final path components; all writes happen off AppKit.
// 4. Native rotation/purge: daily and topical maintenance cannot block a Lua
//    timer or eventtap callback.
// ==============================================================================

import Darwin
import Dispatch
import CoreFoundation
import Foundation





// ============================================
// ============================================
// ======= 1/ Transport Identity ===============
// ============================================
// ============================================

let kLoggerDatagramPortEnvironment = "ERGOPTI_LOG_PORT"
let kLoggerDatagramTokenEnvironment = "ERGOPTI_LOG_TOKEN"

struct LoggerDatagramEndpoint: Equatable {
	let port: UInt16
	let token: String
}

protocol LoggerDatagramServing: AnyObject {
	var endpoint: LoggerDatagramEndpoint { get }
	func setBootstrapReadyHandler(_ handler: @escaping () -> Void)
	func stop()
}





// ============================================
// ============================================
// ======= 2/ Descriptor-Relative Sink =========
// ============================================
// ============================================

/// Serial file authority used only from LoggerDatagramProcessor's private queue.
final class LoggerRecordSink {
	private static let maximumLineBytes = 48 * 1_024
	private static let maximumTopicCount = 16
	private static let maximumTopicNameBytes = 96
	private static let lockTimeoutSeconds: TimeInterval = 0.25
	private static let lockRetryMicroseconds: useconds_t = 1_000

	private var directoryDescriptor: Int32 = -1
	private var directoryPath: String?
	private var retentionDays = 14
	private var topicalWriteDate: String?
	private var forceTopicalResetForObservedTransition = false
	private var initializedTopicalFiles: Set<String> = []
	private var pendingRecord: PendingRecord?
	private var pendingWriteRollback: PendingWriteRollback?
	private var purgePending = false
	private var lastMaintenanceDate: String?
	private let now: () -> Date
	private let beforeLock: (Int32, String) -> Void
	private let writeOperation: (Int32, UnsafeRawPointer?, Int) -> Int
	private let truncateOperation: (Int32, off_t) -> Int32
	private let synchronizeOperation: (Int32) -> Int32

	private struct PendingRecord: Equatable {
		let operationId: String
		let line: String
		let variant: String
		let topics: [String]
		let calendarDate: String
		var completedFiles: Set<String>
	}

	private struct PendingWriteRollback {
		let descriptor: Int32
		let originalSize: off_t
	}

	init(
		now: @escaping () -> Date = Date.init,
		beforeLock: @escaping (Int32, String) -> Void = { _, _ in },
		writeOperation: @escaping (Int32, UnsafeRawPointer?, Int) -> Int = {
			Darwin.write($0, $1, $2)
		},
		truncateOperation: @escaping (Int32, off_t) -> Int32 = {
			Darwin.ftruncate($0, $1)
		},
		synchronizeOperation: @escaping (Int32) -> Int32 = { Darwin.fsync($0) }
	) {
		self.now = now
		self.beforeLock = beforeLock
		self.writeOperation = writeOperation
		self.truncateOperation = truncateOperation
		self.synchronizeOperation = synchronizeOperation
	}

	deinit {
		if let rollback = pendingWriteRollback {
			_ = ergoptiFlock(rollback.descriptor, LOCK_UN)
			Darwin.close(rollback.descriptor)
		}
		if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) }
	}

	/// Installs one owned, no-follow log directory and performs retention there.
	func configure(directoryPath: String, retentionDays: Int) -> Bool {
		guard (1...3_650).contains(retentionDays),
			let normalizedPath = Self.normalizedAbsoluteDirectoryPath(directoryPath)
		else { return false }
		if let pendingRecord {
			guard append(
				line: pendingRecord.line,
				variant: pendingRecord.variant,
				topics: pendingRecord.topics,
				calendarDate: pendingRecord.calendarDate,
				operationId: pendingRecord.operationId
			) else { return false }
		}

		try? FileManager.default.createDirectory(
			atPath: normalizedPath,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let descriptor = Darwin.open(
			normalizedPath,
			O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
		)
		guard descriptor >= 0 else { return false }
		var attributes = stat()
		guard Darwin.fstat(descriptor, &attributes) == 0,
			(attributes.st_mode & S_IFMT) == S_IFDIR,
			attributes.st_uid == geteuid(),
			Darwin.fchmod(descriptor, S_IRWXU) == 0
		else {
			Darwin.close(descriptor)
			return false
		}
		var previousAttributes = stat()
		let preservesTopicalState = self.directoryPath == normalizedPath
			&& directoryDescriptor >= 0
			&& Darwin.fstat(directoryDescriptor, &previousAttributes) == 0
			&& previousAttributes.st_dev == attributes.st_dev
			&& previousAttributes.st_ino == attributes.st_ino

		if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) }
		directoryDescriptor = descriptor
		self.directoryPath = normalizedPath
		self.retentionDays = retentionDays
		if !preservesTopicalState {
			topicalWriteDate = nil
			forceTopicalResetForObservedTransition = false
			initializedTopicalFiles.removeAll()
		}
		pendingRecord = nil
		purgePending = true
		return true
	}

	/// Runs retention only after the transport has sent the configure ACK. This
	/// preserves the boot barrier without putting an unbounded directory walk on
	/// the critical path before Hammerspoon may arm its input callbacks.
	func performDeferredMaintenance() {
		guard purgePending else { return }
		purgePending = false
		purgeOldLogs()
		lastMaintenanceDate = Self.calendarDate(now())
	}

	/// Applies the sink's complete record policy without mutating filesystem state.
	func accepts(
		line: String,
		variant: String,
		topics: [String],
		calendarDate: String
	) -> Bool {
		return Self.persistedLine(line) != nil
			&& Self.isValidVariant(variant)
			&& Self.areValidTopics(topics)
			&& Self.isValidCalendarDate(calendarDate)
	}

	/// Writes one complete accepted record to every requested sink.
	func append(
		line: String,
		variant: String,
		topics: [String],
		calendarDate: String,
		operationId: String
	) -> Bool {
		guard settlePendingWriteRollback(),
			directoryDescriptor >= 0,
			let persistedLine = Self.persistedLine(line),
			accepts(line: line, variant: variant, topics: topics, calendarDate: calendarDate),
			!operationId.isEmpty
		else { return false }

		// A launcher can remain alive across any number of midnights. Configure
		// schedules the boot purge only once, so the first record observed on a
		// later wall-clock day must transfer retention ownership to the same
		// post-ACK maintenance boundary again. Use the worker clock rather than
		// the record's calendarDate: a queued pre-midnight record may arrive after
		// midnight and must still trigger today's retention pass.
		if lastMaintenanceDate != Self.calendarDate(now()) {
			purgePending = true
		}

		let requested = PendingRecord(
			operationId: operationId,
			line: line,
			variant: variant,
			topics: topics,
			calendarDate: calendarDate,
			completedFiles: []
		)
		if let pendingRecord {
			guard pendingRecord.operationId == requested.operationId,
				pendingRecord.line == requested.line,
				pendingRecord.variant == requested.variant,
				pendingRecord.topics == requested.topics,
				pendingRecord.calendarDate == requested.calendarDate
			else { return false }
		} else {
			pendingRecord = requested
		}

		if topicalWriteDate != calendarDate {
			forceTopicalResetForObservedTransition = topicalWriteDate != nil
			topicalWriteDate = calendarDate
			initializedTopicalFiles.removeAll()
		}
		guard let bytes = (persistedLine + "\n").data(using: .utf8) else { return false }
		let unifiedName = "ErgoptiPlus_\(calendarDate).log"
		var targets = [(name: unifiedName, topical: false)]
		if variant == "warn" || variant == "error" {
			let errorsName = "ErgoptiPlus_errors_\(calendarDate).log"
			targets.append((name: errorsName, topical: false))
		}
		for topic in topics {
			targets.append((name: topic, topical: true))
		}

		for target in targets {
			if pendingRecord?.completedFiles.contains(target.name) == true { continue }
			let firstTopicalWrite = target.topical
				&& !initializedTopicalFiles.contains(target.name)
			guard write(
				bytes,
				fileName: target.name,
				resetUnlessDate: firstTopicalWrite ? calendarDate : nil,
				forceReset: firstTopicalWrite && forceTopicalResetForObservedTransition
			) else {
				return false
			}
			pendingRecord?.completedFiles.insert(target.name)
			if target.topical { initializedTopicalFiles.insert(target.name) }
		}
		pendingRecord = nil
		return true
	}

	/// Normalizes one absolute directory without admitting a NUL or parent escape.
	private static func normalizedAbsoluteDirectoryPath(_ path: String) -> String? {
		guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < Int(PATH_MAX)
		else { return nil }
		let normalized = URL(fileURLWithPath: path, isDirectory: true)
			.standardizedFileURL.path
		guard normalized.hasPrefix("/"), normalized != "/" else { return nil }
		return normalized
	}

	/// Keeps native log files textual without rejecting an otherwise valid Lua
	/// diagnostic. JSON transports NUL losslessly; the sink renders it as `\0`.
	private static func persistedLine(_ line: String) -> String? {
		let size = line.utf8.count
		guard size > 0 && size <= maximumLineBytes else { return nil }
		return line.replacingOccurrences(of: "\0", with: "\\0")
	}

	private static func isValidVariant(_ variant: String) -> Bool {
		return [
			"debug", "trace", "done", "info",
			"start", "success", "warn", "error",
		].contains(variant)
	}

	private static func isValidCalendarDate(_ value: String) -> Bool {
		guard let date = datedLogDate("ErgoptiPlus_\(value).log") else { return false }
		return calendarDate(date) == value
	}

	private static func areValidTopics(_ topics: [String]) -> Bool {
		guard topics.count <= maximumTopicCount,
			Set(topics).count == topics.count
		else { return false }
		return topics.allSatisfy { name in
			guard name.utf8.count <= maximumTopicNameBytes,
				kLoggerTopicalFileNames.contains(name),
				name.hasPrefix("ErgoptiPlus_"),
				name.hasSuffix(".log"),
				datedLogDate(name) == nil,
				!name.hasPrefix("ErgoptiPlus_errors_")
			else { return false }
			let stem = name.dropFirst("ErgoptiPlus_".count).dropLast(".log".count)
			guard !stem.isEmpty else { return false }
			return stem.utf8.allSatisfy { byte in
				(byte >= 48 && byte <= 57)
					|| (byte >= 65 && byte <= 90)
					|| (byte >= 97 && byte <= 122)
					|| byte == 45
					|| byte == 95
			}
		}
	}

	/// Opens and validates one exact sink before performing a bounded append.
	private func write(
		_ data: Data,
		fileName: String,
		resetUnlessDate: String? = nil,
		forceReset: Bool = false
	) -> Bool {
		// Never put O_TRUNC on the pathname open: validation must happen before
		// any existing inode can be mutated (an owned hard link is still rejected).
		let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
		let descriptor = fileName.withCString { name in
			Darwin.openat(
				directoryDescriptor,
				name,
				flags,
				S_IRUSR | S_IWUSR
			)
		}
		guard descriptor >= 0 else { return false }
		var releaseDescriptor = true
		var locked = false
		defer {
			if releaseDescriptor {
				if locked { _ = ergoptiFlock(descriptor, LOCK_UN) }
				Darwin.close(descriptor)
			}
		}

		var prelockAttributes = stat()
		guard Darwin.fstat(descriptor, &prelockAttributes) == 0,
			(prelockAttributes.st_mode & S_IFMT) == S_IFREG,
			prelockAttributes.st_uid == geteuid(),
			prelockAttributes.st_nlink == 1
		else { return false }
		beforeLock(descriptor, fileName)
		guard acquireLock(descriptor) else { return false }
		locked = true

		// Rotation is decided from the inode metadata observed while holding the
		// same exclusive lock as the write. A snapshot taken before flock can be
		// stale after waiting behind a writer and must never authorize truncation.
		var lockedAttributes = stat()
		guard Darwin.fstat(descriptor, &lockedAttributes) == 0,
			(lockedAttributes.st_mode & S_IFMT) == S_IFREG,
			lockedAttributes.st_uid == geteuid(),
			lockedAttributes.st_nlink == 1,
			Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
		else { return false }
		if let resetUnlessDate {
			let inodeDate = Self.calendarDate(Date(
				timeIntervalSince1970: Double(lockedAttributes.st_mtimespec.tv_sec)
			))
			if (forceReset || inodeDate != resetUnlessDate)
				&& Darwin.ftruncate(descriptor, 0) != 0 {
				return false
			}
		}

		var appendAttributes = stat()
		guard Darwin.fstat(descriptor, &appendAttributes) == 0 else { return false }
		let originalSize = appendAttributes.st_size
		let complete = writeLauncherLogData(
			data,
			descriptor: descriptor,
			writeOperation: writeOperation
		)
		if complete { return true }
		if rollbackWrite(descriptor, originalSize: originalSize) { return false }

		// A failed rollback leaves a partially appended inode. Retain that exact
		// locked descriptor so a sequence retry cannot append a full duplicate
		// beside the prefix, nor accidentally repair a replacement pathname.
		pendingWriteRollback = PendingWriteRollback(
			descriptor: descriptor,
			originalSize: originalSize
		)
		releaseDescriptor = false
		return false
	}

	/// Retries one interrupted syscall while preserving a bounded operation.
	private func synchronize(_ descriptor: Int32) -> Bool {
		while true {
			if synchronizeOperation(descriptor) == 0 { return true }
			if errno != EINTR { return false }
		}
	}

	/// Restores the exact pre-append size and makes that rollback durable.
	private func rollbackWrite(_ descriptor: Int32, originalSize: off_t) -> Bool {
		while true {
			if truncateOperation(descriptor, originalSize) == 0 { break }
			if errno != EINTR { return false }
		}
		return synchronize(descriptor)
	}

	/// Settles a retained partial-write rollback before admitting another record.
	private func settlePendingWriteRollback() -> Bool {
		guard let rollback = pendingWriteRollback else { return true }
		guard rollbackWrite(rollback.descriptor, originalSize: rollback.originalSize)
		else { return false }
		guard ergoptiFlock(rollback.descriptor, LOCK_UN) == 0 else { return false }
		Darwin.close(rollback.descriptor)
		pendingWriteRollback = nil
		return true
	}

	/// Prevents an unrelated stalled writer from parking this serial worker forever.
	private func acquireLock(_ descriptor: Int32) -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + Self.lockTimeoutSeconds
		while true {
			if ergoptiFlock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
			let lockError = errno
			guard lockError == EINTR || lockError == EAGAIN || lockError == EWOULDBLOCK,
				ProcessInfo.processInfo.systemUptime < deadline
			else { return false }
			if lockError != EINTR { usleep(Self.lockRetryMicroseconds) }
		}
	}

	/// Purges dated archives by filename and undated topical views by mtime.
	private func purgeOldLogs() {
		guard directoryDescriptor >= 0 else { return }
		let scanDescriptor = ".".withCString { currentDirectory in
			Darwin.openat(
				directoryDescriptor,
				currentDirectory,
				O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
			)
		}
		guard scanDescriptor >= 0, let directory = Darwin.fdopendir(scanDescriptor) else {
			if scanDescriptor >= 0 { Darwin.close(scanDescriptor) }
			return
		}
		defer { Darwin.closedir(directory) }

		let currentDate = now()
		let today = Self.calendarDate(currentDate)
		let cutoff = currentDate.addingTimeInterval(-Double(retentionDays) * 86_400)
		while let entry = Darwin.readdir(directory) {
			let name = withUnsafePointer(to: &entry.pointee.d_name) { tuplePointer in
				tuplePointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
					String(cString: $0)
				}
			}
			guard name != ".", name != "..", shouldPurge(name, today: today, cutoff: cutoff)
			else { continue }

			var attributes = stat()
			let inspected = name.withCString { candidate in
				Darwin.fstatat(
					directoryDescriptor,
					candidate,
					&attributes,
					AT_SYMLINK_NOFOLLOW
				)
			}
			guard inspected == 0,
				(attributes.st_mode & S_IFMT) == S_IFREG,
				attributes.st_uid == geteuid(),
				attributes.st_nlink == 1
			else { continue }
			_ = name.withCString { candidate in
				Darwin.unlinkat(directoryDescriptor, candidate, 0)
			}
		}
	}

	private func shouldPurge(_ name: String, today: String, cutoff: Date) -> Bool {
		if let fileDate = Self.datedLogDate(name), fileDate < cutoff { return true }
		guard Self.isTopicalName(name) else { return false }
		var attributes = stat()
		let inspected = name.withCString { candidate in
			Darwin.fstatat(
				directoryDescriptor,
				candidate,
				&attributes,
				AT_SYMLINK_NOFOLLOW
			)
		}
		guard inspected == 0 else { return false }
		return Self.calendarDate(Date(
			timeIntervalSince1970: Double(attributes.st_mtimespec.tv_sec)
		))
			!= today
	}

	private static func datedLogDate(_ name: String) -> Date? {
		let prefix: String
		if name.hasPrefix("ErgoptiPlus_errors_") {
			prefix = "ErgoptiPlus_errors_"
		} else if name.hasPrefix("ErgoptiPlus_") {
			prefix = "ErgoptiPlus_"
		} else {
			return nil
		}
		guard name.hasSuffix(".log") else { return nil }
		let dateText = String(name.dropFirst(prefix.count).dropLast(4))
		guard dateText.count == 10 else { return nil }
		let pieces = dateText.split(separator: "-")
		guard pieces.count == 3,
			let year = Int(pieces[0]),
			let month = Int(pieces[1]),
			let day = Int(pieces[2])
		else { return nil }
		guard let date = gregorianCalendar().date(from: DateComponents(
			year: year,
			month: month,
			day: day,
			hour: 12
		)), calendarDate(date) == dateText else { return nil }
		return date
	}

	private static func isTopicalName(_ name: String) -> Bool {
		guard name.hasPrefix("ErgoptiPlus_"), name.hasSuffix(".log"),
			datedLogDate(name) == nil
		else { return false }
		return areValidTopics([name])
	}

	private static func calendarDate(_ date: Date) -> String {
		let parts = gregorianCalendar().dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
	}

	private static func gregorianCalendar() -> Calendar {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .current
		return calendar
	}
}





// ============================================
// ============================================
// ======= 3/ Authenticated Protocol ===========
// ============================================
// ============================================

/// Stateful decoder and exactly-once in-process sequencing authority.
final class LoggerDatagramProcessor {
	private static let protocolVersion = 1
	private static let maximumPacketBytes = 60 * 1_024
	private static let maximumBatchRecordCount = 64
	private static let maximumSafeSequence = 9_007_199_254_740_991
	private static let maximumSessionBytes = 128

	private struct DecodedRecord {
		let sequence: Int
		let line: String
		let variant: String
		let topics: [String]
		let calendarDate: String
	}

	private let token: String
	private let sink: LoggerRecordSink
	private var session: String?
	private var configuredDirectory: String?
	private var configuredRetention: Int?
	private var lastSequence = 0
	var hasConfiguredSession: Bool { session != nil }

	init(token: String, sink: LoggerRecordSink = LoggerRecordSink()) {
		self.token = token
		self.sink = sink
	}

	/// Runs native-only work deliberately ordered after the response datagram.
	func performDeferredMaintenance() {
		sink.performDeferredMaintenance()
	}

	/// Accepts one loopback packet and returns an authenticated ACK/NACK payload.
	func handle(_ data: Data, sourceIsLoopback: Bool) -> Data? {
		guard sourceIsLoopback,
			!data.isEmpty,
			data.count <= Self.maximumPacketBytes,
			let object = try? JSONSerialization.jsonObject(with: data),
			let request = object as? [String: Any],
			request["token"] as? String == token
		else { return nil }

		guard Self.integer(request["v"]) == Self.protocolVersion,
			let kind = request["kind"] as? String,
			let requestSession = request["session"] as? String,
			Self.isValidSession(requestSession)
		else { return response(kind: "nack", ack: nil, reason: "invalid_envelope") }

		switch kind {
		case "configure":
			return configure(request, session: requestSession)
		case "record":
			return append(request, session: requestSession)
		case "batch":
			return appendBatch(request, session: requestSession)
		default:
			return response(
				kind: "nack",
				ack: nil,
				reason: "invalid_kind",
				responseSession: requestSession
			)
		}
	}

	private func configure(_ request: [String: Any], session requestSession: String) -> Data? {
		guard Self.integer(request["sequence"]) == 0,
			let directory = request["log_dir"] as? String,
			let retention = Self.integer(request["retention_days"])
		else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "invalid_configure",
				responseSession: requestSession
			)
		}

		if session == requestSession {
			guard configuredDirectory == directory, configuredRetention == retention
			else {
				return response(
					kind: "nack",
					ack: nil,
					reason: "config_changed_in_session",
					responseSession: requestSession
				)
			}
			guard sink.configure(directoryPath: directory, retentionDays: retention) else {
				return response(
					kind: "nack",
					ack: nil,
					reason: "configure_failed",
					responseSession: requestSession
				)
			}
			return response(
				kind: "ack",
				ack: 0,
				reason: nil,
				responseSession: requestSession
			)
		}
		if let currentSession = session {
			guard request["previous_session"] as? String == currentSession else {
				return response(
					kind: "nack",
					ack: nil,
					reason: "session_transition_rejected",
					responseSession: requestSession
				)
			}
		}

		guard sink.configure(directoryPath: directory, retentionDays: retention) else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "configure_failed",
				responseSession: requestSession
			)
		}
		session = requestSession
		configuredDirectory = directory
		configuredRetention = retention
		lastSequence = 0
		return response(
			kind: "ack",
			ack: 0,
			reason: nil,
			responseSession: requestSession
		)
	}

	private func append(_ request: [String: Any], session requestSession: String) -> Data? {
		guard session == requestSession else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "stale_session",
				responseSession: requestSession
			)
		}
		guard let sequence = Self.integer(request["sequence"]),
			sequence > 0,
			sequence <= Self.maximumSafeSequence
		else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "invalid_sequence",
				responseSession: requestSession
			)
		}

		if sequence <= lastSequence {
			return response(
				kind: "ack",
				ack: sequence,
				reason: nil,
				responseSession: requestSession
			)
		}
		guard sequence == lastSequence + 1 else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "sequence_gap",
				expected: lastSequence + 1,
				responseSession: requestSession
			)
		}
		guard let record = decodeRecord(request),
			sink.append(
				line: record.line,
				variant: record.variant,
				topics: record.topics,
				calendarDate: record.calendarDate,
				operationId: "\(requestSession):\(sequence)"
			)
		else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "record_rejected",
				expected: lastSequence + 1,
				responseSession: requestSession
			)
		}

		lastSequence = sequence
		return response(
			kind: "ack",
			ack: sequence,
			reason: nil,
			responseSession: requestSession
		)
	}

	/// Validates the complete datagram before the first append, then advances the
	/// same exactly-once sequence authority as individual records. A retry may
	/// contain an already committed prefix; it is skipped and only the missing
	/// suffix is written. The sole success ACK owns the final sequence in the lot.
	private func appendBatch(_ request: [String: Any], session requestSession: String) -> Data? {
		guard session == requestSession else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "stale_session",
				responseSession: requestSession
			)
		}
		guard let requests = request["records"] as? [[String: Any]],
			!requests.isEmpty,
			requests.count <= Self.maximumBatchRecordCount
		else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "batch_rejected",
				expected: lastSequence + 1,
				responseSession: requestSession
			)
		}

		var records: [DecodedRecord] = []
		records.reserveCapacity(requests.count)
		var previousSequence: Int?
		for candidate in requests {
			guard let record = decodeRecord(candidate) else {
				return response(
					kind: "nack",
					ack: nil,
					reason: "batch_rejected",
					expected: lastSequence + 1,
					responseSession: requestSession
				)
			}
			if let previousSequence, record.sequence != previousSequence + 1 {
				return response(
					kind: "nack",
					ack: nil,
					reason: "batch_rejected",
					expected: lastSequence + 1,
					responseSession: requestSession
				)
			}
			records.append(record)
			previousSequence = record.sequence
		}

		guard let first = records.first, let final = records.last else { return nil }
		guard first.sequence <= lastSequence + 1 else {
			return response(
				kind: "nack",
				ack: nil,
				reason: "sequence_gap",
				expected: lastSequence + 1,
				responseSession: requestSession
			)
		}

		for record in records {
			if record.sequence <= lastSequence { continue }
			guard record.sequence == lastSequence + 1,
				sink.append(
					line: record.line,
					variant: record.variant,
					topics: record.topics,
					calendarDate: record.calendarDate,
					operationId: "\(requestSession):\(record.sequence)"
				)
			else {
				return response(
					kind: "nack",
					ack: nil,
					reason: "record_rejected",
					expected: lastSequence + 1,
					responseSession: requestSession
				)
			}
			lastSequence = record.sequence
		}

		return response(
			kind: "ack",
			ack: final.sequence,
			reason: nil,
			responseSession: requestSession
		)
	}

	private func decodeRecord(_ request: [String: Any]) -> DecodedRecord? {
		guard let sequence = Self.integer(request["sequence"]),
			sequence > 0,
			sequence <= Self.maximumSafeSequence,
			let topics = Self.decodeTopics(request["topics"]),
			let line = request["line"] as? String,
			let variant = request["variant"] as? String,
			let calendarDate = request["calendar_date"] as? String,
			sink.accepts(
				line: line,
				variant: variant,
				topics: topics,
				calendarDate: calendarDate
			)
		else { return nil }
		return DecodedRecord(
			sequence: sequence,
			line: line,
			variant: variant,
			topics: topics,
			calendarDate: calendarDate
		)
	}

	private static func decodeTopics(_ value: Any?) -> [String]? {
		if value == nil { return [] }
		if let topics = value as? [String] { return topics }
		if let emptyTable = value as? [String: Any], emptyTable.isEmpty {
			// hs.json cannot infer array intent from an empty Lua table, so `{}` is
			// its canonical wire form for a record with no topical destinations.
			return []
		}
		return nil
	}

	private func response(
		kind: String,
		ack: Int?,
		reason: String?,
		expected: Int? = nil,
		responseSession: String? = nil
	) -> Data? {
		var body: [String: Any] = [
			"v": Self.protocolVersion,
			"token": token,
			"kind": kind,
		]
		if let responseSession = responseSession ?? session {
			body["session"] = responseSession
		}
		if let ack { body["ack"] = ack }
		if let reason { body["reason"] = reason }
		if let expected { body["expected"] = expected }
		return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
	}

	private static func integer(_ value: Any?) -> Int? {
		guard let number = value as? NSNumber,
			CFGetTypeID(number) != CFBooleanGetTypeID()
		else { return nil }
		let double = number.doubleValue
		guard double.isFinite,
			double.rounded(.towardZero) == double,
			double >= Double(Int.min),
			double <= Double(Int.max)
		else { return nil }
		return Int(double)
	}

	private static func isValidSession(_ value: String) -> Bool {
		guard !value.isEmpty, value.utf8.count <= maximumSessionBytes else { return false }
		return value.utf8.allSatisfy { byte in
			(byte >= 48 && byte <= 57)
				|| (byte >= 65 && byte <= 90)
				|| (byte >= 97 && byte <= 122)
				|| byte == 45
				|| byte == 95
		}
	}
}





// ============================================
// ============================================
// ======= 4/ Loopback UDP Runtime =============
// ============================================
// ============================================

enum LoggerDatagramReadResult {
	case payload(Int)
	case empty
	case interrupted
	case drained
	case failed
}

final class LoggerDatagramWorker: LoggerDatagramServing {
	static let maximumReadsPerDrain = 256

	let endpoint: LoggerDatagramEndpoint

	private let descriptor: Int32
	private let processor: LoggerDatagramProcessor
	private let queue = DispatchQueue(
		label: "com.ergoptiplus.logger-datagram",
		qos: .utility
	)
	private var readSource: DispatchSourceRead?
	private var bootstrapReadyHandler: (() -> Void)?
	private var bootstrapReadyReported = false
	private var stopped = false

	init?() {
		let socketDescriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard socketDescriptor >= 0 else { return nil }
		guard Darwin.fcntl(socketDescriptor, F_SETFD, FD_CLOEXEC) == 0,
			Darwin.fcntl(socketDescriptor, F_SETFL, O_NONBLOCK) == 0
		else {
			Darwin.close(socketDescriptor)
			return nil
		}

		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = in_port_t(0).bigEndian
		address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
		let bound = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.bind(
					socketDescriptor,
					$0,
					socklen_t(MemoryLayout<sockaddr_in>.size)
				)
			}
		}
		guard bound == 0 else {
			Darwin.close(socketDescriptor)
			return nil
		}

		var liveAddress = sockaddr_in()
		var liveLength = socklen_t(MemoryLayout<sockaddr_in>.size)
		let resolved = withUnsafeMutablePointer(to: &liveAddress) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.getsockname(socketDescriptor, $0, &liveLength)
			}
		}
		guard resolved == 0 else {
			Darwin.close(socketDescriptor)
			return nil
		}

		let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
		descriptor = socketDescriptor
		endpoint = LoggerDatagramEndpoint(
			port: UInt16(bigEndian: liveAddress.sin_port),
			token: token
		)
		processor = LoggerDatagramProcessor(token: token)

		let source = DispatchSource.makeReadSource(fileDescriptor: socketDescriptor, queue: queue)
		readSource = source
		source.setEventHandler { [weak self] in self?.drainSocket() }
		source.setCancelHandler { Darwin.close(socketDescriptor) }
		source.resume()
	}

	deinit { stop() }

	func setBootstrapReadyHandler(_ handler: @escaping () -> Void) {
		queue.sync {
			bootstrapReadyHandler = handler
			if processor.hasConfiguredSession { reportBootstrapReadyIfNeeded() }
		}
	}

	func stop() {
		guard !stopped else { return }
		stopped = true
		readSource?.cancel()
		readSource = nil
	}

	/// Drains every currently queued datagram on the private serial queue.
	private func drainSocket() {
		var bytes = [UInt8](repeating: 0, count: 65_535)
		var sourceAddress = sockaddr_storage()
		var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
		Self.drainReceiveLoop(
			receive: {
				sourceAddress = sockaddr_storage()
				sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
				let count = bytes.withUnsafeMutableBytes { buffer -> Int in
					withUnsafeMutablePointer(to: &sourceAddress) { addressPointer in
						addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
							Darwin.recvfrom(
								descriptor,
								buffer.baseAddress,
								buffer.count,
								0,
								$0,
								&sourceLength
							)
						}
					}
				}
				let receiveError = errno
				if count < 0 {
					if receiveError == EINTR { return .interrupted }
					if receiveError == EAGAIN || receiveError == EWOULDBLOCK {
						return .drained
					}
					return .failed
				}
				if count == 0 { return .empty }
				return .payload(count)
			},
			consume: { count in
				let payload = Data(bytes[0..<count])
				guard let response = processor.handle(
					payload,
					sourceIsLoopback: Self.isLoopback(sourceAddress)
				) else { return }
				let sent = response.withUnsafeBytes { responseBytes in
					withUnsafePointer(to: &sourceAddress) { addressPointer in
						addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
							Darwin.sendto(
								descriptor,
								responseBytes.baseAddress,
								responseBytes.count,
								MSG_DONTWAIT,
								$0,
								sourceLength
							)
						}
					}
				}
				if sent == response.count, processor.hasConfiguredSession {
					reportBootstrapReadyIfNeeded()
				}
				processor.performDeferredMaintenance()
			}
		)
	}

	private func reportBootstrapReadyIfNeeded() {
		guard !bootstrapReadyReported, let bootstrapReadyHandler else { return }
		bootstrapReadyReported = true
		bootstrapReadyHandler()
	}

	/// Bounds one read-source pass so queued lifecycle work can run under sustained input.
	@discardableResult
	static func drainReceiveLoop(
		maximumReads: Int = maximumReadsPerDrain,
		receive: () -> LoggerDatagramReadResult,
		consume: (Int) -> Void
	) -> Int {
		precondition(maximumReads > 0)
		var reads = 0
		while reads < maximumReads {
			reads += 1
			switch receive() {
			case .payload(let count):
				consume(count)
			case .empty, .interrupted:
				continue
			case .drained, .failed:
				return reads
			}
		}
		return reads
	}

	private static func isLoopback(_ storage: sockaddr_storage) -> Bool {
		guard storage.ss_family == sa_family_t(AF_INET) else { return false }
		var copy = storage
		return withUnsafePointer(to: &copy) { pointer in
			pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
				$0.pointee.sin_addr.s_addr == INADDR_LOOPBACK.bigEndian
			}
		}
	}
}
