// Tests/ErgoptiPlusTests/LoggerRetentionParityTests.swift

// ==============================================================================
// MODULE: Native Logger Retention Parity Tests
// DESCRIPTION:
// Replays the retention sections of the shared logger parity corpus
// (_shared/tests/corpus/logger/parity_vectors.json) through the real native
// record sink, as the Windows, macOS Lua and Linux suites replay the same file.
//
// FEATURES & RATIONALE:
// 1. Own suite: LoggerDatagramWorkerTests is the unchanged original suite that
//    native_logger_regression_xctest_evidence.cjs qualifies method by method;
//    a parity case added there would refuse that qualification.
// 2. Real purge: each vector configures a sink at the corpus instant and runs
//    its deferred maintenance on a private directory.
// ==============================================================================

import Foundation
import XCTest
@testable import ErgoptiPlus

final class LoggerRetentionParityTests: XCTestCase {





	// ============================================
	// ============================================
	// ======= 1/ Shared Retention Corpus =========
	// ============================================
	// ============================================

	/// Replays the dated_retention cases of the shared parity corpus through a
	/// real purge (the topical views were retired on 2026-11-25). The purge compared the archive's noon
	/// with now minus N x 86,400 s, so the N-days-old archive vanished after noon
	/// while Windows and Linux keep it all day (logger parity audit LOG-03).
	func testRetentionReplaysTheSharedParityCorpus() throws {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<5 { root.deleteLastPathComponent() }
		let corpusURL = root.appendingPathComponent("_shared/tests/corpus/logger/parity_vectors.json")
		let corpus = try XCTUnwrap(
			JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as? [String: Any])
		let dated = try XCTUnwrap((corpus["dated_retention"] as? [String: Any])?["cases"] as? [[String: Any]])
		XCTAssertFalse(dated.isEmpty)
		XCTAssertNil(corpus["topical_retention"], "the topical sub-files are retired")

		for vector in dated {
			let id = try XCTUnwrap(vector["id"] as? String)
			let directory = try makeLogDirectory()
			let archive = directory.appendingPathComponent(
				"ErgoptiPlus_\(try XCTUnwrap(vector["file_date"] as? String)).log")
			try Data("archive\n".utf8).write(to: archive)
			let now = try corpusInstant(try XCTUnwrap(vector["now"] as? String))
			let sink = LoggerRecordSink(now: { now })
			XCTAssertTrue(sink.configure(
				directoryPath: directory.path,
				retentionDays: try XCTUnwrap(vector["retention_days"] as? Int)))
			sink.performDeferredMaintenance()
			let purged = try XCTUnwrap(vector["purged"] as? Bool)
			XCTAssertEqual(!FileManager.default.fileExists(atPath: archive.path), purged, id)
		}
	}





	// ============================================
	// ============================================
	// ======= 2/ Test Helpers ====================
	// ============================================
	// ============================================

	private func makeLogDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-logger-parity-\(UUID().uuidString)",
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

	/// Local instant of a corpus "YYYY-MM-DD HH:MM:SS".
	private func corpusInstant(_ text: String) throws -> Date {
		let fields = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
		XCTAssertEqual(fields.count, 6, "malformed corpus instant \(text)")
		return try XCTUnwrap(Calendar.current.date(from: DateComponents(
			year: fields[0],
			month: fields[1],
			day: fields[2],
			hour: fields[3],
			minute: fields[4],
			second: fields[5]
		)))
	}
}
