// Tests/ErgoptiPlusTests/LoggerDatagramNumericTests.swift
//
// JSON numbers at the rounded Int.max boundary must be protocol refusals,
// never a trapping floating-point conversion in the launcher's logger queue.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class LoggerDatagramNumericTests: XCTestCase {
	private let invalidNumbers = [
		"9223372036854775807", "9223372036854775808", "18446744073709551615",
		"-9223372036854775809", "1e100", "-1e100", "1.5", "true"
	]
	private let numericMarker = "__logger_numeric_boundary__"

	/// Preserves the actual JSON number spelling instead of pre-rounding it in Swift.
	private func request(_ fields: [String: Any], number: String) throws -> Data {
		let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
		let text = String(decoding: bytes, as: UTF8.self)
		XCTAssertTrue(text.contains("\"\(numericMarker)\""))
		return Data(text.replacingOccurrences(of: "\"\(numericMarker)\"", with: number).utf8)
	}

	private func response(_ bytes: Data?) throws -> [String: Any] {
		let data = try XCTUnwrap(bytes, "An authenticated malformed number must receive a refusal")
		return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
	}

	private func envelope(kind: String = "record") -> [String: Any] {
		["v": 1, "token": "numeric-test", "session": "numeric-session", "kind": kind]
	}

	func testUnrepresentableEnvelopeNumbersRefuseWithoutCrashingOrConfiguring() throws {
		let processor = LoggerDatagramProcessor(token: "numeric-test")
		for number in invalidNumbers {
			var fields = envelope()
			fields["v"] = numericMarker
			let result = try response(processor.handle(try request(fields, number: number), sourceIsLoopback: true))
			XCTAssertEqual(result["kind"] as? String, "nack", number)
			XCTAssertEqual(result["reason"] as? String, "invalid_envelope", number)
			XCTAssertFalse(processor.hasConfiguredSession)
		}
	}

	func testUnrepresentableConfigureNumbersCannotCreateAConfiguredDirectory() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-numeric-config-" + UUID().uuidString, isDirectory: true)
		defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
		let processor = LoggerDatagramProcessor(token: "numeric-test")
		for field in ["sequence", "retention_days"] {
			for number in invalidNumbers {
				var fields = envelope(kind: "configure")
				fields["sequence"] = 0
				fields["retention_days"] = 14
				fields["log_dir"] = directory.path
				fields[field] = numericMarker
				let result = try response(processor.handle(try request(fields, number: number), sourceIsLoopback: true))
				XCTAssertEqual(result["kind"] as? String, "nack", "\(field): \(number)")
				XCTAssertFalse(processor.hasConfiguredSession)
				XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
					"A refused configure must not create its requested log directory")
			}
		}
	}

	func testUnrepresentableRecordAndBatchSequencesCannotWriteOrAdvance() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-numeric-record-" + UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		let processor = LoggerDatagramProcessor(token: "numeric-test")
		var configure = envelope(kind: "configure")
		configure["sequence"] = 0
		configure["retention_days"] = 14
		configure["log_dir"] = directory.path
		let configured = try response(processor.handle(
			try JSONSerialization.data(withJSONObject: configure), sourceIsLoopback: true))
		XCTAssertEqual(configured["ack"] as? Int, 0)
		let record: [String: Any] = ["sequence": 1, "line": "must-write-only-after-refusals",
			"variant": "info", "topics": [String](), "calendar_date": "2026-08-14"]
		for number in invalidNumbers {
			var malformed = record
			malformed["sequence"] = numericMarker
			var fields = envelope()
			fields.merge(malformed) { _, value in value }
			let refused = try response(processor.handle(try request(fields, number: number), sourceIsLoopback: true))
			XCTAssertEqual(refused["reason"] as? String, "invalid_sequence", number)
			var batch = envelope(kind: "batch")
			batch["records"] = [record, malformed]
			let batchRefused = try response(processor.handle(try request(batch, number: number), sourceIsLoopback: true))
			XCTAssertEqual(batchRefused["reason"] as? String, "batch_rejected", number)
			XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
				"Neither the malformed record nor a valid batch prefix may write")
		}
		var valid = envelope()
		valid.merge(record) { _, value in value }
		let accepted = try response(processor.handle(
			try JSONSerialization.data(withJSONObject: valid), sourceIsLoopback: true))
		XCTAssertEqual(accepted["ack"] as? Int, 1, "Malformed numbers must not advance sequence ownership")
		XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("ErgoptiPlus_2026-08-14.log")),
			"must-write-only-after-refusals\n")
	}
}
