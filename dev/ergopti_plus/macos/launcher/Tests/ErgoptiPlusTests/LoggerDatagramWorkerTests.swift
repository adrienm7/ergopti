// Tests/ErgoptiPlusTests/LoggerDatagramWorkerTests.swift

// ==============================================================================
// MODULE: Native Logger Datagram Worker Tests
// DESCRIPTION:
// Exercises the real authenticated protocol and descriptor-relative file sink.
// These are behavioral tests: they assert exact ACK/order/dedup/file outcomes,
// not the presence of implementation strings.
//
// FEATURES & RATIONALE:
// 1. Exact fan-out: unified, errors-only, and topical sinks receive one record.
// 2. Retry idempotence: duplicate sequences ACK without duplicate bytes.
// 3. Ordering/session fences: gaps and stale reload sessions cannot mutate files.
// 4. Real UDP boundary: a loopback client reaches the pre-bound launcher worker.
// 5. Native retention: dated archives and stale topical views purge off Lua.
// ==============================================================================

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class LoggerDatagramWorkerTests: XCTestCase {





	// ============================================
	// ============================================
	// ======= 1/ Processor Semantics =============
	// ============================================
	// ============================================

	func testAcceptedRecordFansOutOnceAndDuplicateOnlyAcknowledges() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let sink = LoggerRecordSink(now: { now })
		let processor = LoggerDatagramProcessor(token: "secret", sink: sink)

		let configure = request([
			"v": 1,
			"token": "secret",
			"kind": "configure",
			"session": "session-a",
			"sequence": 0,
			"log_dir": directory.path,
			"retention_days": 14,
		])
		XCTAssertEqual(response(processor.handle(configure, sourceIsLoopback: true))["ack"] as? Int, 0)

		let record = request([
			"v": 1,
			"token": "secret",
			"kind": "record",
			"session": "session-a",
			"sequence": 1,
			"line": "14h00min00s000ms [WARN] [llm.api] failed once",
			"variant": "warn",
			"topics": ["ErgoptiPlus_llm.log"],
			"calendar_date": "2026-08-14",
		])
		let firstAck = response(processor.handle(record, sourceIsLoopback: true))
		let duplicateAck = response(processor.handle(record, sourceIsLoopback: true))
		XCTAssertEqual(firstAck["ack"] as? Int, 1)
		XCTAssertEqual(duplicateAck["ack"] as? Int, 1)
		XCTAssertEqual(firstAck["session"] as? String, "session-a")

		let expected = "14h00min00s000ms [WARN] [llm.api] failed once\n"
		for name in [
			"ErgoptiPlus_2026-08-14.log",
			"ErgoptiPlus_errors_2026-08-14.log",
			"ErgoptiPlus_llm.log",
		] {
			XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(name)), expected)
		}
	}

	func testBatchValidatesEveryRecordBeforeWritingAndAcknowledgesTheFinalSequence() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let processor = LoggerDatagramProcessor(
			token: "secret",
			sink: LoggerRecordSink(now: { now })
		)
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)

		var invalidSecond = recordBody(sequence: 2, line: "must-not-write")
		invalidSecond["calendar_date"] = "2026-08-14/escape"
		let rejected = response(processor.handle(
			batch(records: [
				recordBody(sequence: 1, line: "also-must-not-write"),
				invalidSecond,
			], session: "session-a"),
			sourceIsLoopback: true
		))
		XCTAssertEqual(rejected["kind"] as? String, "nack")
		XCTAssertEqual(rejected["reason"] as? String, "batch_rejected")
		XCTAssertEqual(rejected["expected"] as? Int, 1)
		let unified = directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log")
		XCTAssertFalse(FileManager.default.fileExists(atPath: unified.path),
			"a malformed suffix must reject the complete batch before its valid prefix writes")

		let accepted = response(processor.handle(
			batch(records: [
				recordBody(sequence: 1, line: "first"),
				recordBody(sequence: 2, line: "second"),
			], session: "session-a"),
			sourceIsLoopback: true
		))
		XCTAssertEqual(accepted["kind"] as? String, "ack")
		XCTAssertEqual(accepted["ack"] as? Int, 2)
		XCTAssertEqual(try String(contentsOf: unified), "first\nsecond\n")
	}

	func testBatchRetrySkipsTheDurablePrefixAndResumesAtExpectedSequence() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		var refuseSecondOnce = true
		let sink = LoggerRecordSink(
			now: { now },
			writeOperation: { descriptor, bytes, count in
				let payload = bytes.map { String(decoding: Data(bytes: $0, count: count), as: UTF8.self) }
				if refuseSecondOnce && payload?.contains("second") == true {
					refuseSecondOnce = false
					errno = EIO
					return -1
				}
				return Darwin.write(descriptor, bytes, count)
			}
		)
		let processor = LoggerDatagramProcessor(token: "secret", sink: sink)
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)
		let packet = batch(records: [
			recordBody(sequence: 1, line: "first"),
			recordBody(sequence: 2, line: "second"),
		], session: "session-a")

		let refused = response(processor.handle(packet, sourceIsLoopback: true))
		XCTAssertEqual(refused["kind"] as? String, "nack")
		XCTAssertEqual(refused["expected"] as? Int, 2)
		let unified = directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log")
		XCTAssertEqual(try String(contentsOf: unified), "first\n")

		let retried = response(processor.handle(packet, sourceIsLoopback: true))
		XCTAssertEqual(retried["kind"] as? String, "ack")
		XCTAssertEqual(retried["ack"] as? Int, 2)
		XCTAssertEqual(try String(contentsOf: unified), "first\nsecond\n",
			"a byte-identical retry must not duplicate the durable prefix")
	}

	func testBatchBoundsAndContiguityRejectBeforeAnyWrite() throws {
		let directory = try makeLogDirectory()
		let processor = LoggerDatagramProcessor(token: "secret")
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)
		let oversized = (1...65).map { recordBody(sequence: $0, line: "line-\($0)") }
		let malformedBatches = [
			batch(records: [], session: "session-a"),
			batch(records: oversized, session: "session-a"),
			batch(records: [
				recordBody(sequence: 1, line: "first"),
				recordBody(sequence: 3, line: "gap"),
			], session: "session-a"),
		]

		for packet in malformedBatches {
			let refusal = response(processor.handle(packet, sourceIsLoopback: true))
			XCTAssertEqual(refusal["reason"] as? String, "batch_rejected")
			XCTAssertEqual(refusal["expected"] as? Int, 1)
		}
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log").path
		))
	}

	func testGapAndStaleSessionCannotWriteWhileNewSessionRestartsAtOne() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let processor = LoggerDatagramProcessor(
			token: "secret",
			sink: LoggerRecordSink(now: { now })
		)
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)

		let gap = response(processor.handle(
			record(sequence: 2, line: "gap", session: "session-a"),
			sourceIsLoopback: true
		))
		XCTAssertEqual(gap["kind"] as? String, "nack")
		XCTAssertEqual(gap["reason"] as? String, "sequence_gap")
		XCTAssertEqual(gap["expected"] as? Int, 1)
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log").path
		))

		XCTAssertEqual(response(processor.handle(
			record(sequence: 1, line: "first", session: "session-a"),
			sourceIsLoopback: true
		))["ack"] as? Int, 1)
		XCTAssertEqual(response(processor.handle(
			record(sequence: 2, line: "second", session: "session-a"),
			sourceIsLoopback: true
		))["ack"] as? Int, 2)

		let reloadAck = response(processor.handle(
			configure(directory, session: "session-b", previousSession: "session-a"),
			sourceIsLoopback: true
		))
		XCTAssertEqual(reloadAck["ack"] as? Int, 0)
		XCTAssertEqual(reloadAck["session"] as? String, "session-b")
		XCTAssertEqual(response(processor.handle(
			record(sequence: 1, line: "after-reload", session: "session-b"),
			sourceIsLoopback: true
		))["ack"] as? Int, 1)

		let stale = response(processor.handle(
			record(sequence: 3, line: "stale", session: "session-a"),
			sourceIsLoopback: true
		))
		XCTAssertEqual(stale["reason"] as? String, "stale_session")
		let unified = try String(contentsOf: directory.appendingPathComponent(
			"ErgoptiPlus_2026-08-14.log"
		))
		XCTAssertEqual(unified, "first\nsecond\nafter-reload\n")
	}

	func testDelayedOldConfigureCannotRollBackTheActiveReloadSession() throws {
		let directory = try makeLogDirectory()
		let processor = LoggerDatagramProcessor(token: "secret")
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)
		let newConfigure = configure(
			directory,
			session: "session-b",
			previousSession: "session-a"
		)
		XCTAssertEqual(response(processor.handle(
			newConfigure,
			sourceIsLoopback: true
		))["ack"] as? Int, 0)

		let delayedOld = response(processor.handle(
			configure(directory, session: "session-a"),
			sourceIsLoopback: true
		))
		XCTAssertEqual(delayedOld["reason"] as? String, "session_transition_rejected")
		XCTAssertEqual(response(processor.handle(
			record(sequence: 1, line: "new-runtime", session: "session-b"),
			sourceIsLoopback: true
		))["ack"] as? Int, 1)
	}

	func testFreshLauncherAcceptsPersistedPreviousSessionFromPriorProcess() throws {
		let directory = try makeLogDirectory()
		let processor = LoggerDatagramProcessor(token: "secret")
		let firstConfigure = configure(
			directory,
			session: "fresh-process-session",
			previousSession: "dead-process-session"
		)

		let acknowledgement = response(processor.handle(
			firstConfigure,
			sourceIsLoopback: true
		))
		XCTAssertEqual(acknowledgement["ack"] as? Int, 0)
		XCTAssertEqual(acknowledgement["session"] as? String, "fresh-process-session")
	}

	func testWrongTokenAndNonLoopbackSourceReceiveNoProtocolOracle() throws {
		let directory = try makeLogDirectory()
		let processor = LoggerDatagramProcessor(token: "secret")
		let wrongToken = request([
			"v": 1,
			"token": "wrong",
			"kind": "configure",
			"session": "session-a",
			"sequence": 0,
			"log_dir": directory.path,
			"retention_days": 14,
		])

		XCTAssertNil(processor.handle(wrongToken, sourceIsLoopback: true))
		XCTAssertNil(processor.handle(
			configure(directory, session: "session-a"),
			sourceIsLoopback: false
		))
	}

	func testConfigureRefusalEchoesTheAuthenticatedRequestSession() {
		let processor = LoggerDatagramProcessor(token: "secret")
		let refusal = response(processor.handle(request([
			"v": 1,
			"token": "secret",
			"kind": "configure",
			"session": "request-session",
			"sequence": 0,
			"log_dir": "/",
			"retention_days": 14,
		]), sourceIsLoopback: true))

		XCTAssertEqual(refusal["kind"] as? String, "nack")
		XCTAssertEqual(refusal["reason"] as? String, "configure_failed")
		XCTAssertEqual(refusal["session"] as? String, "request-session")
	}

	func testMalformedDateAndTopicCannotEscapeOrMutateAnySink() throws {
		let directory = try makeLogDirectory()
		let processor = LoggerDatagramProcessor(token: "secret")
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)

		for malformed in [
			request([
				"v": 1,
				"token": "secret",
				"kind": "record",
				"session": "session-a",
				"sequence": 1,
				"line": "bad date",
				"variant": "info",
				"topics": [],
				"calendar_date": "2026-02-31",
			]),
			request([
				"v": 1,
				"token": "secret",
				"kind": "record",
				"session": "session-a",
				"sequence": 1,
				"line": "bad topic",
				"variant": "info",
				"topics": ["../escaped.log"],
				"calendar_date": "2026-08-14",
			]),
		] {
			let rejection = response(processor.handle(malformed, sourceIsLoopback: true))
			XCTAssertEqual(rejection["reason"] as? String, "record_rejected")
			XCTAssertEqual(rejection["expected"] as? Int, 1)
		}

		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
	}

	func testNULInDiagnosticIsEscapedWithoutBlockingTheSequenceQueue() throws {
		let directory = try makeLogDirectory()
		let processor = LoggerDatagramProcessor(token: "secret")
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)

		let nulAck = response(processor.handle(
			record(sequence: 1, line: "before\0after", session: "session-a"),
			sourceIsLoopback: true
		))
		let followingAck = response(processor.handle(
			record(sequence: 2, line: "following", session: "session-a"),
			sourceIsLoopback: true
		))

		XCTAssertEqual(nulAck["ack"] as? Int, 1)
		XCTAssertEqual(followingAck["ack"] as? Int, 2)
		XCTAssertEqual(
			try String(contentsOf: directory.appendingPathComponent(
				"ErgoptiPlus_2026-08-14.log"
			)),
			"before\\0after\nfollowing\n"
		)
	}

	func testRetryAfterPartialFanoutDoesNotDuplicateCompletedFiles() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let sink = LoggerRecordSink(now: { now })
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))
		sink.performDeferredMaintenance()

		let errorsPath = directory.appendingPathComponent("ErgoptiPlus_errors_2026-08-14.log")
		try FileManager.default.createSymbolicLink(
			at: errorsPath,
			withDestinationURL: directory.appendingPathComponent("redirected.log")
		)
		XCTAssertFalse(sink.append(
			line: "retry-me",
			variant: "warn",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-14",
			operationId: "session-a:1"
		))
		try FileManager.default.removeItem(at: errorsPath)
		XCTAssertTrue(sink.append(
			line: "retry-me",
			variant: "warn",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-14",
			operationId: "session-a:1"
		))

		for name in [
			"ErgoptiPlus_2026-08-14.log",
			"ErgoptiPlus_errors_2026-08-14.log",
			"ErgoptiPlus_llm.log",
		] {
			XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(name)), "retry-me\n")
		}
	}

	func testShortWriteRollbackLeavesOneRecordInEverySink() throws {
		let targetNames = [
			"ErgoptiPlus_2026-08-14.log",
			"ErgoptiPlus_errors_2026-08-14.log",
			"ErgoptiPlus_llm.log",
		]
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		for failureTarget in targetNames {
			let directory = try makeLogDirectory()
			var activeFileName = ""
			var partialWritten = false
			var injectedFailureCompleted = false
			var rollbackTruncations = 0
			var rollbackSynchronizations = 0
			let sink = LoggerRecordSink(
				now: { now },
				beforeLock: { _, fileName in activeFileName = fileName },
				writeOperation: { descriptor, bytes, count in
					if activeFileName == failureTarget && !injectedFailureCompleted {
						if !partialWritten {
							partialWritten = true
							return Darwin.write(descriptor, bytes, min(5, count))
						}
						injectedFailureCompleted = true
						errno = EIO
						return -1
					}
					return Darwin.write(descriptor, bytes, count)
				},
				truncateOperation: { descriptor, size in
					rollbackTruncations += 1
					return Darwin.ftruncate(descriptor, size)
				},
				synchronizeOperation: { descriptor in
					rollbackSynchronizations += 1
					return Darwin.fsync(descriptor)
				}
			)
			XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))

			XCTAssertFalse(sink.append(
				line: "short-write-retry",
				variant: "warn",
				topics: ["ErgoptiPlus_llm.log"],
				calendarDate: "2026-08-14",
				operationId: "session-a:1"
			))
			let failedPath = directory.appendingPathComponent(failureTarget)
			XCTAssertEqual(try String(contentsOf: failedPath), "",
				"a failed write must roll its partial prefix back before NACK")
			XCTAssertEqual(rollbackTruncations, 1)
			XCTAssertEqual(rollbackSynchronizations, 1,
				"the rollback must be durable before the retry is admitted")

			XCTAssertTrue(sink.append(
				line: "short-write-retry",
				variant: "warn",
				topics: ["ErgoptiPlus_llm.log"],
				calendarDate: "2026-08-14",
				operationId: "session-a:1"
			))
			for name in targetNames {
				XCTAssertEqual(
					try String(contentsOf: directory.appendingPathComponent(name)),
					"short-write-retry\n",
					"the shared sink owner must publish exactly once after \(failureTarget) retries"
				)
			}
			XCTAssertEqual(rollbackTruncations, 1)
			XCTAssertEqual(rollbackSynchronizations, 1)
		}
	}

	func testFailedShortWriteRollbackRetainsDebtBeforeRetry() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		var partialWritten = false
		var injectedFailureCompleted = false
		var rollbackAllowed = false
		var writeCalls = 0
		let sink = LoggerRecordSink(
			now: { now },
			writeOperation: { descriptor, bytes, count in
				writeCalls += 1
				if !injectedFailureCompleted {
					if !partialWritten {
						partialWritten = true
						return Darwin.write(descriptor, bytes, min(4, count))
					}
					injectedFailureCompleted = true
					errno = EIO
					return -1
				}
				return Darwin.write(descriptor, bytes, count)
			},
			truncateOperation: { descriptor, size in
				guard rollbackAllowed else {
					errno = EIO
					return -1
				}
				return Darwin.ftruncate(descriptor, size)
			}
		)
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))

		let append = {
			sink.append(
				line: "debt-retry",
				variant: "info",
				topics: [],
				calendarDate: "2026-08-14",
				operationId: "session-a:1"
			)
		}
		XCTAssertFalse(append())
		let writesAfterFailure = writeCalls
		let unified = directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log")
		let retainedPrefix = try String(contentsOf: unified)
		XCTAssertFalse(retainedPrefix.isEmpty)

		XCTAssertFalse(append(), "unsettled rollback debt must reject the exact retry")
		XCTAssertEqual(writeCalls, writesAfterFailure,
			"no new write may begin while the partial inode remains unsettled")
		XCTAssertEqual(try String(contentsOf: unified), retainedPrefix)

		rollbackAllowed = true
		XCTAssertTrue(append())
		XCTAssertEqual(try String(contentsOf: unified), "debt-retry\n")
	}

	func testFailedRollbackSynchronizationRetainsDebtBeforeRetry() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		var partialWritten = false
		var injectedWriteFailureCompleted = false
		var synchronizationAllowed = false
		var writeCalls = 0
		var synchronizationCalls = 0
		let sink = LoggerRecordSink(
			now: { now },
			writeOperation: { descriptor, bytes, count in
				writeCalls += 1
				if !injectedWriteFailureCompleted {
					if !partialWritten {
						partialWritten = true
						return Darwin.write(descriptor, bytes, min(4, count))
					}
					injectedWriteFailureCompleted = true
					errno = EIO
					return -1
				}
				return Darwin.write(descriptor, bytes, count)
			},
			synchronizeOperation: { descriptor in
				synchronizationCalls += 1
				guard synchronizationAllowed else {
					errno = EIO
					return -1
				}
				return Darwin.fsync(descriptor)
			}
		)
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))

		let append = {
			sink.append(
				line: "sync-debt-retry",
				variant: "info",
				topics: [],
				calendarDate: "2026-08-14",
				operationId: "session-a:1"
			)
		}
		XCTAssertFalse(append())
		let writesAfterFailure = writeCalls
		let unified = directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log")
		XCTAssertEqual(try String(contentsOf: unified), "",
			"ftruncate removed the prefix even though its durability barrier failed")

		XCTAssertFalse(append(), "unsynchronized rollback debt must reject the exact retry")
		XCTAssertEqual(writeCalls, writesAfterFailure,
			"no new write may begin before the retained rollback becomes durable")
		XCTAssertTrue(synchronizationCalls >= 2,
			"each debt settlement attempt must retry the exact fsync boundary")

		synchronizationAllowed = true
		XCTAssertTrue(append())
		XCTAssertEqual(try String(contentsOf: unified), "sync-debt-retry\n")
	}

	func testReloadSessionAppendsToTodaysTopicalViewInsteadOfTruncatingIt() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let processor = LoggerDatagramProcessor(
			token: "secret",
			sink: LoggerRecordSink(now: { now })
		)
		_ = processor.handle(configure(directory, session: "session-a"), sourceIsLoopback: true)
		_ = processor.handle(request([
			"v": 1,
			"token": "secret",
			"kind": "record",
			"session": "session-a",
			"sequence": 1,
			"line": "before-reload",
			"variant": "info",
			"topics": ["ErgoptiPlus_llm.log"],
			"calendar_date": "2026-08-14",
		]), sourceIsLoopback: true)
		_ = processor.handle(configure(
			directory,
			session: "session-b",
			previousSession: "session-a"
		), sourceIsLoopback: true)
		_ = processor.handle(request([
			"v": 1,
			"token": "secret",
			"kind": "record",
			"session": "session-b",
			"sequence": 1,
			"line": "after-reload",
			"variant": "info",
			"topics": ["ErgoptiPlus_llm.log"],
			"calendar_date": "2026-08-14",
		]), sourceIsLoopback: true)

		XCTAssertEqual(
			try String(contentsOf: directory.appendingPathComponent("ErgoptiPlus_llm.log")),
			"before-reload\nafter-reload\n"
		)
	}

	func testFreshLauncherPreservesAnExistingSameDayTopicalView() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let topical = directory.appendingPathComponent("ErgoptiPlus_llm.log")
		try Data("prior-process\n".utf8).write(to: topical)
		try FileManager.default.setAttributes(
			[.modificationDate: now],
			ofItemAtPath: topical.path
		)
		let freshSink = LoggerRecordSink(now: { now })
		XCTAssertTrue(freshSink.configure(directoryPath: directory.path, retentionDays: 14))

		XCTAssertTrue(freshSink.append(
			line: "new-process",
			variant: "info",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-14",
			operationId: "session-new:1"
		))
		XCTAssertEqual(try String(contentsOf: topical), "prior-process\nnew-process\n")
	}

	func testFirstRecordAfterMidnightReplacesThePriorDayTopicalView() throws {
		let directory = try makeLogDirectory()
		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let priorDay = try fixedDate(year: 2026, month: 8, day: 13)
		let topical = directory.appendingPathComponent("ErgoptiPlus_llm.log")
		try Data("prior-day\n".utf8).write(to: topical)
		try FileManager.default.setAttributes(
			[.modificationDate: priorDay],
			ofItemAtPath: topical.path
		)
		let sink = LoggerRecordSink(now: { now })
		// Configure's purge normally removes this old view. Recreate it after the
		// handshake to exercise a live worker crossing midnight without restart.
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))
		sink.performDeferredMaintenance()
		try Data("prior-day\n".utf8).write(to: topical)
		try FileManager.default.setAttributes(
			[.modificationDate: priorDay],
			ofItemAtPath: topical.path
		)

		XCTAssertTrue(sink.append(
			line: "new-day",
			variant: "info",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-14",
			operationId: "session-a:1"
		))
		XCTAssertEqual(try String(contentsOf: topical), "new-day\n")
	}

	func testObservedCalendarTransitionRotatesTopicalEvenWhenOldRecordHasNewDayMtime() throws {
		let directory = try makeLogDirectory()
		let newDay = try fixedDate(year: 2026, month: 8, day: 14)
		let topical = directory.appendingPathComponent("ErgoptiPlus_llm.log")
		let sink = LoggerRecordSink(now: { newDay })
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))

		XCTAssertTrue(sink.append(
			line: "queued-before-midnight",
			variant: "info",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-13",
			operationId: "session-a:1"
		))
		// The queued old-day record reached disk after midnight. Its kernel mtime
		// therefore claims the topical view already belongs to the new day.
		try FileManager.default.setAttributes(
			[.modificationDate: newDay],
			ofItemAtPath: topical.path
		)

		XCTAssertTrue(sink.append(
			line: "first-new-day-record",
			variant: "info",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-14",
			operationId: "session-a:2"
		))
		XCTAssertEqual(try String(contentsOf: topical), "first-new-day-record\n")
	}

	func testSameDirectoryReconfigureRetainsObservedTopicalCalendarTransition() throws {
		let directory = try makeLogDirectory()
		let newDay = try fixedDate(year: 2026, month: 8, day: 14)
		let topical = directory.appendingPathComponent("ErgoptiPlus_llm.log")
		let sink = LoggerRecordSink(now: { newDay })
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))
		XCTAssertTrue(sink.append(
			line: "queued-before-midnight",
			variant: "info",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-13",
			operationId: "session-a:1"
		))
		try FileManager.default.setAttributes(
			[.modificationDate: newDay],
			ofItemAtPath: topical.path
		)
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 30))

		XCTAssertTrue(sink.append(
			line: "first-new-day-record",
			variant: "info",
			topics: ["ErgoptiPlus_llm.log"],
			calendarDate: "2026-08-14",
			operationId: "session-b:1"
		))
		XCTAssertEqual(try String(contentsOf: topical), "first-new-day-record\n",
			"a retention-only reconfigure must not erase the observed date transition")
	}

	func testReplacedDirectoryAtSamePathDoesNotReuseTopicalInitializationState() throws {
		let directory = try makeLogDirectory()
		let replacedDirectory = directory.deletingLastPathComponent().appendingPathComponent(
			"ergopti-logger-replaced-\(UUID().uuidString)",
			isDirectory: true
		)
		addTeardownBlock { try? FileManager.default.removeItem(at: replacedDirectory) }
		let today = try fixedDate(year: 2026, month: 8, day: 14)
		let priorDay = try fixedDate(year: 2026, month: 8, day: 13)
		let topical = directory.appendingPathComponent("ErgoptiPlus_llm.log")
		let processor = LoggerDatagramProcessor(
			token: "secret",
			sink: LoggerRecordSink(now: { today })
		)
		XCTAssertEqual(response(processor.handle(
			configure(directory, session: "session-a"),
			sourceIsLoopback: true
		))["ack"] as? Int, 0)
		XCTAssertEqual(response(processor.handle(request([
			"v": 1,
			"token": "secret",
			"kind": "record",
			"session": "session-a",
			"sequence": 1,
			"line": "old-inode",
			"variant": "info",
			"topics": ["ErgoptiPlus_llm.log"],
			"calendar_date": "2026-08-14",
		]), sourceIsLoopback: true))["ack"] as? Int, 1)

		try FileManager.default.moveItem(at: directory, to: replacedDirectory)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		try Data("new-inode-prior-day\n".utf8).write(to: topical)
		try FileManager.default.setAttributes(
			[.modificationDate: priorDay],
			ofItemAtPath: topical.path
		)

		XCTAssertEqual(response(processor.handle(
			configure(directory, session: "session-a"),
			sourceIsLoopback: true
		))["ack"] as? Int, 0,
			"an idempotent configure must revalidate the pathname's exact directory inode")
		XCTAssertEqual(response(processor.handle(request([
			"v": 1,
			"token": "secret",
			"kind": "record",
			"session": "session-a",
			"sequence": 2,
			"line": "new-inode-today",
			"variant": "info",
			"topics": ["ErgoptiPlus_llm.log"],
			"calendar_date": "2026-08-14",
		]), sourceIsLoopback: true))["ack"] as? Int, 2)
		XCTAssertEqual(try String(contentsOf: topical), "new-inode-today\n",
			"topical state belongs to the exact directory inode, not its pathname")
		XCTAssertEqual(try String(contentsOf: replacedDirectory.appendingPathComponent(
			"ErgoptiPlus_llm.log"
		)), "old-inode\n", "new records must not follow the stale directory descriptor")
	}

	func testTopicalRotationUsesMetadataObservedAfterWaitingForTheWriteLock() throws {
		let directory = try makeLogDirectory()
		let priorDay = try fixedDate(year: 2026, month: 8, day: 13)
		let today = try fixedDate(year: 2026, month: 8, day: 14)
		let topicalName = "ErgoptiPlus_llm.log"
		let topical = directory.appendingPathComponent(topicalName)
		try Data("prior-day\n".utf8).write(to: topical)
		try FileManager.default.setAttributes(
			[.modificationDate: priorDay],
			ofItemAtPath: topical.path
		)
		var racedWriterDidRun = false
		let sink = LoggerRecordSink(
			now: { today },
			beforeLock: { _, fileName in
				guard fileName == topicalName, !racedWriterDidRun else { return }
				racedWriterDidRun = true
				let writer = Darwin.open(topical.path, O_WRONLY | O_APPEND | O_CLOEXEC)
				XCTAssertGreaterThanOrEqual(writer, 0)
				guard writer >= 0 else { return }
				XCTAssertEqual(ergoptiFlock(writer, LOCK_EX), 0)
				XCTAssertEqual(Darwin.ftruncate(writer, 0), 0)
				XCTAssertTrue(writeLauncherLogData(
					Data("same-day-writer\n".utf8),
					descriptor: writer
				))
				try! FileManager.default.setAttributes(
					[.modificationDate: today],
					ofItemAtPath: topical.path
				)
				XCTAssertEqual(ergoptiFlock(writer, LOCK_UN), 0)
				Darwin.close(writer)
			}
		)
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))

		XCTAssertTrue(sink.append(
			line: "native-writer",
			variant: "info",
			topics: [topicalName],
			calendarDate: "2026-08-14",
			operationId: "session-a:1"
		))
		XCTAssertTrue(racedWriterDidRun)
		XCTAssertEqual(
			try String(contentsOf: topical),
			"same-day-writer\nnative-writer\n"
		)
	}





	// ============================================
	// ============================================
	// ======= 2/ Real UDP Boundary ===============
	// ============================================
	// ============================================

	func testBoundLoopbackWorkerAcknowledgesPersistedRecord() throws {
		let directory = try makeLogDirectory()
		let worker = try XCTUnwrap(LoggerDatagramWorker())
		defer { worker.stop() }

		let configureAck = try roundTrip(
			request([
				"v": 1,
				"token": worker.endpoint.token,
				"kind": "configure",
				"session": "udp-session",
				"sequence": 0,
				"log_dir": directory.path,
				"retention_days": 14,
			]),
			port: worker.endpoint.port
		)
		XCTAssertEqual(response(configureAck)["ack"] as? Int, 0)

		let calendarDate = LoggerDatagramWorkerTests.calendarDate(Date())
		let recordAck = try roundTrip(
			record(
				sequence: 1,
				line: "udp-record",
				session: "udp-session",
				token: worker.endpoint.token,
				calendarDate: calendarDate
			),
			port: worker.endpoint.port
		)
		XCTAssertEqual(response(recordAck)["ack"] as? Int, 1)

		let unified = directory.appendingPathComponent("ErgoptiPlus_\(calendarDate).log")
		XCTAssertEqual(try String(contentsOf: unified), "udp-record\n")
	}





	// ============================================
	// ============================================
	// ======= 3/ Native Retention =================
	// ============================================
	// ============================================

	func testConfigurePurgesExpiredDailyAndStaleTopicalFiles() throws {
		let directory = try makeLogDirectory()
		let oldDaily = directory.appendingPathComponent("ErgoptiPlus_2026-07-01.log")
		let oldErrors = directory.appendingPathComponent("ErgoptiPlus_errors_2026-07-01.log")
		let currentDaily = directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log")
		let oldTopical = directory.appendingPathComponent("ErgoptiPlus_llm.log")
		for file in [oldDaily, oldErrors, currentDaily, oldTopical] {
			try Data("existing\n".utf8).write(to: file)
		}
		let oldDate = try fixedDate(year: 2026, month: 7, day: 1)
		try FileManager.default.setAttributes(
			[.modificationDate: oldDate],
			ofItemAtPath: oldTopical.path
		)

		let now = try fixedDate(year: 2026, month: 8, day: 14)
		let sink = LoggerRecordSink(now: { now })
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))
		sink.performDeferredMaintenance()

		XCTAssertFalse(FileManager.default.fileExists(atPath: oldDaily.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: oldErrors.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: oldTopical.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: currentDaily.path))
	}

	func testFirstRecordOnNewWallClockDayRearmsRetentionWithoutReconfigure() throws {
		let directory = try makeLogDirectory()
		let expiringDaily = directory.appendingPathComponent("ErgoptiPlus_2026-07-31.log")
		try Data("expires-tomorrow\n".utf8).write(to: expiringDaily)

		var currentNow = try fixedDate(year: 2026, month: 8, day: 14)
		let sink = LoggerRecordSink(now: { currentNow })
		XCTAssertTrue(sink.configure(directoryPath: directory.path, retentionDays: 14))
		sink.performDeferredMaintenance()
		XCTAssertTrue(FileManager.default.fileExists(atPath: expiringDaily.path),
			"the control archive must still be inside retention on the configure day")

		currentNow = try fixedDate(year: 2026, month: 8, day: 15)
		XCTAssertTrue(sink.append(
			line: "first-record-after-midnight",
			variant: "info",
			topics: [],
			calendarDate: "2026-08-15",
			operationId: "session-a:1"
		))
		XCTAssertTrue(FileManager.default.fileExists(atPath: expiringDaily.path),
			"retention must remain deferred until after the record ACK boundary")

		sink.performDeferredMaintenance()
		XCTAssertFalse(FileManager.default.fileExists(atPath: expiringDaily.path),
			"a long-lived launcher must re-run retention on the first record of a new wall-clock day")
	}





	// ============================================
	// ============================================
	// ======= 4/ Test Helpers =====================
	// ============================================
	// ============================================

	private func makeLogDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-logger-worker-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return directory
	}

	private func fixedDate(year: Int, month: Int, day: Int) throws -> Date {
		return try XCTUnwrap(Calendar.current.date(from: DateComponents(
			year: year,
			month: month,
			day: day,
			hour: 12
		)))
	}

	private func configure(
		_ directory: URL,
		session: String,
		previousSession: String? = nil
	) -> Data {
		var body: [String: Any] = [
			"v": 1,
			"token": "secret",
			"kind": "configure",
			"session": session,
			"sequence": 0,
			"log_dir": directory.path,
			"retention_days": 14,
		]
		if let previousSession { body["previous_session"] = previousSession }
		return request(body)
	}

	private func record(
		sequence: Int,
		line: String,
		session: String,
		token: String = "secret",
		calendarDate: String = "2026-08-14"
	) -> Data {
		var body = recordBody(
			sequence: sequence,
			line: line,
			calendarDate: calendarDate
		)
		body["v"] = 1
		body["token"] = token
		body["kind"] = "record"
		body["session"] = session
		return request(body)
	}

	private func recordBody(
		sequence: Int,
		line: String,
		calendarDate: String = "2026-08-14"
	) -> [String: Any] {
		return [
			"sequence": sequence,
			"line": line,
			"variant": "info",
			"topics": [],
			"calendar_date": calendarDate,
		]
	}

	private func batch(
		records: [[String: Any]],
		session: String,
		token: String = "secret"
	) -> Data {
		return request([
			"v": 1,
			"token": token,
			"kind": "batch",
			"session": session,
			"records": records,
		])
	}

	private func request(_ object: [String: Any]) -> Data {
		return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
	}

	private func response(_ data: Data?) -> [String: Any] {
		guard let data,
			let object = try? JSONSerialization.jsonObject(with: data),
			let dictionary = object as? [String: Any]
		else { return [:] }
		return dictionary
	}

	private func roundTrip(_ request: Data, port: UInt16) throws -> Data {
		let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
		defer { Darwin.close(descriptor) }
		var timeout = timeval(tv_sec: 2, tv_usec: 0)
		guard Darwin.setsockopt(
			descriptor,
			SOL_SOCKET,
			SO_RCVTIMEO,
			&timeout,
			socklen_t(MemoryLayout<timeval>.size)
		) == 0 else { throw POSIXError(.EINVAL) }

		var destination = sockaddr_in()
		destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		destination.sin_family = sa_family_t(AF_INET)
		destination.sin_port = port.bigEndian
		destination.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
		let sent = request.withUnsafeBytes { bytes in
			withUnsafePointer(to: &destination) { pointer in
				pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					Darwin.sendto(
						descriptor,
						bytes.baseAddress,
						bytes.count,
						0,
						$0,
						socklen_t(MemoryLayout<sockaddr_in>.size)
					)
				}
			}
		}
		guard sent == request.count else { throw POSIXError(.EIO) }

		var buffer = [UInt8](repeating: 0, count: 4_096)
		let count = buffer.withUnsafeMutableBytes { bytes in
			Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
		}
		guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
		return Data(buffer[0..<count])
	}

	private static func calendarDate(_ date: Date) -> String {
		let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
	}
}
