// TEST ONLY: independent frozen journal projection controls; no native compilation.
import Foundation
import XCTest

final class HS274OwnedBoundaryConsoleTests: XCTestCase {

	private func row(_ sequence: Int, _ event: String, span: Int = 0, phase: String = "",
		elapsed: String = "0", code: String = "") -> String {
		let stage = span == 0 ? "compilation" : "native_dispatch"
		return "{\"schema\":1,\"seq\":\(sequence),\"event\":\"\(event)\",\"span\":\(span),\"parent\":0,\"stage\":\"\(stage)\",\"phase\":\"\(phase)\",\"mono_ns\":\(sequence * 1000),\"elapsed_ns\":\(elapsed),\"sync_ns\":\(sequence),\"code\":\"\(code)\"}\n"
	}

	private var closed: String {
		row(1, "writer_start") + row(2, "enter", span: 1, phase: "core_build")
			+ row(3, "complete", span: 1, phase: "core_build", elapsed: "100")
			+ row(4, "writer_end", elapsed: "400")
	}

	private var pending: String {
		row(1, "writer_start") + row(2, "enter", span: 1, phase: "core_build")
			+ row(3, "enter", span: 2, phase: "console_build")
			+ row(4, "enter", span: 3, phase: "cli_build")
	}

	private func projection(_ text: String?, status: Int32 = 124, ack: Bool = true) throws -> String {
		let result = try XCTUnwrap(HS274OwnedBoundaryConsole.project(text.map { Data($0.utf8) },
			workerStatus: status, guardianClosed: ack))
		XCTAssertLessThanOrEqual(result.count, 8192)
		return try XCTUnwrap(String(data: result, encoding: .utf8))
	}

	private func object(_ text: String) throws -> [String: Any] {
		let prefix = "OWNED-BOUNDARY-OBSERVATION "
		XCTAssertTrue(text.hasPrefix(prefix))
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.dropFirst(prefix.count).utf8))
			as? [String: Any])
	}

	func testClosedKnownSpanRetainsExactRecordedElapsedWithoutNativeAuthority() throws {
		let text = try projection(closed, status: 0), result = try object(text)
		XCTAssertEqual(result["journal_state"] as? String, "writer_end_observed")
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["escaped_sessions_managed"] as? Bool, false)
		XCTAssertEqual(result["worker_exit_status"] as? Int, 0)
		XCTAssertTrue(text.contains("\"elapsed_ns\":100"))
		XCTAssertTrue(text.contains("\"phase_exit_status\":null"))
	}

	func testInterruptedJournalRetainsThreePendingSiblingsWithUnknownElapsed() throws {
		let text = try projection(pending), result = try object(text)
		XCTAssertEqual(result["journal_state"] as? String, "partial")
		XCTAssertEqual(result["observed_native_spans"] as? Int, 3)
		XCTAssertEqual(result["worker_exit_status"] as? Int, 124)
		XCTAssertEqual(text.components(separatedBy: "\"elapsed_ns\":null").count - 1, 3)
		XCTAssertFalse(text.contains("\"code\":\"deadline\""))
	}

	func testParallelTokenCompletionDoesNotRequireLIFOOrInventSiblingCompletion() throws {
		let input = pending + row(5, "complete", span: 3, phase: "cli_build", elapsed: "50")
			+ row(6, "refused", span: 1, phase: "core_build", elapsed: "200", code: "phase_deadline")
		let text = try projection(input), result = try object(text)
		XCTAssertEqual(result["journal_state"] as? String, "partial")
		XCTAssertTrue(text.contains("\"elapsed_ns\":50"))
		XCTAssertTrue(text.contains("\"elapsed_ns\":200"))
		XCTAssertTrue(text.contains("\"code\":\"phase_deadline\""))
		XCTAssertEqual(text.components(separatedBy: "\"elapsed_ns\":null").count - 1, 1)
	}

	func testUnknownLabelsProduceUnsupportedWithoutRawPayload() throws {
		let text = try projection(closed.replacingOccurrences(of: "core_build",
			with: "SECRET /private/foreign https://example.invalid"))
		XCTAssertEqual(try object(text)["journal_state"] as? String, "unsupported")
		XCTAssertFalse(text.contains("SECRET"))
		XCTAssertFalse(text.contains("/private"))
		XCTAssertFalse(text.contains("https://"))
	}

	func testBooleanIsNotAnInteger() throws {
		XCTAssertEqual(try object(projection(closed.replacingOccurrences(of: "\"span\":1",
			with: "\"span\":true")))["journal_state"] as? String, "unsupported")
	}

	func testDuplicateKeysAreRefusedBeforeDictionaryCanCollapseThem() throws {
		XCTAssertEqual(try object(projection(closed.replacingOccurrences(of: "\"seq\":2",
			with: "\"seq\":99,\"seq\":2")))["journal_state"] as? String, "unsupported")
	}

	func testOverflowKeepsPendingFactsWithoutWriterEndClaim() throws {
		let result = try object(projection(pending + row(5, "overflow", code: "limit")))
		XCTAssertEqual(result["journal_state"] as? String, "overflow")
		XCTAssertEqual(result["writer_end_observed"] as? Bool, false)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 3)
	}

	func testMissingJournalPreservesOriginalWorkerStatusAndVerdict() throws {
		let result = try object(projection(nil))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["worker_exit_status"] as? Int, 124)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testLastThirtyTwoSpansDeclareEarlierOmission() throws {
		let input = row(1, "writer_start") + (1...33).map {
			row($0 + 1, "enter", span: $0, phase: "core_build")
		}.joined()
		let result = try object(projection(input))
		XCTAssertEqual(result["observed_native_spans"] as? Int, 33)
		XCTAssertEqual(result["omitted_native_spans"] as? Int, 1)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 32)
		XCTAssertEqual(spans.first?["span"] as? Int, 2)
		XCTAssertEqual(spans.last?["span"] as? Int, 33)
	}

	func testAbsentOriginalGuardianACKPreventsProjection() {
		XCTAssertNil(HS274OwnedBoundaryConsole.project(Data(closed.utf8),
			workerStatus: 124, guardianClosed: false))
	}

	func testUnrelatedVolatileProductIsNotAProjectionInput() throws {
		let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try Data("unrelated".utf8).write(to: temporary)
		defer { try? FileManager.default.removeItem(at: temporary) }
		let before = try projection(closed)
		try FileManager.default.removeItem(at: temporary)
		XCTAssertEqual(try projection(closed), before)
	}

	func testMissingFinalLFIsUnsupported() throws {
		XCTAssertEqual(try object(projection(String(closed.dropLast())))["journal_state"]
			as? String, "unsupported")
	}

	func testLegalTwentyDigitNumbersRemainExactBeyondDoubleAndUInt64() throws {
		for decimal in ["99999999999999999999", "18446744073709551616", "9007199254740993"] {
			let input = row(1, "writer_start") + row(2, "enter", span: 1, phase: "core_build")
				+ row(3, "complete", span: 1, phase: "core_build", elapsed: decimal)
			let text = try projection(input)
			XCTAssertEqual(try object(text)["journal_state"] as? String, "partial")
			XCTAssertTrue(text.contains("\"elapsed_ns\":\(decimal),"))
		}
	}

	func testNoncanonicalOrOutOfDomainIntegersAreUnsupported() throws {
		for decimal in ["100000000000000000000", "1e3", "-1", "1.0", "01"] {
			XCTAssertEqual(try object(projection(closed.replacingOccurrences(of: "\"elapsed_ns\":100",
				with: "\"elapsed_ns\":\(decimal)")))["journal_state"] as? String, "unsupported")
		}
	}

	func testOriginalRecordAndByteBoundsRemainWhole() throws {
		let maximum = row(1, "writer_start") + (1...511).map {
			row($0 + 1, "enter", span: $0, phase: "core_build")
		}.joined()
		XCTAssertEqual(try object(projection(maximum))["source_record_count"] as? Int, 512)
		XCTAssertEqual(try object(projection(maximum + row(513, "overflow", code: "limit")))["journal_state"]
			as? String, "unsupported")
		let padding = 131072 - closed.utf8.count
		let exact = String(repeating: " ", count: padding) + closed
		XCTAssertEqual(exact.utf8.count, 131072)
		XCTAssertEqual(try object(projection(exact))["journal_state"] as? String, "writer_end_observed")
		XCTAssertEqual(try object(projection(" " + exact))["journal_state"] as? String, "unsupported")
	}

	private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
			.appendingPathComponent("ErgoptiHS274NativePolicy-" + UUID().uuidString)
		let owner = root.appendingPathComponent("owned")
		try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700])
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
		defer { try? FileManager.default.removeItem(at: root) }
		let journal = owner.appendingPathComponent("owned-compilation-boundaries.jsonl")
		try Data(closed.utf8).write(to: journal)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
		try body(root, owner, journal)
	}

	func testPrivateRegularJournalHasOneContentRead() throws {
		try fixture { root, owner, _ in
			var cuts = 0
			let captured = HS274OwnedBoundaryConsole.capture(owner: owner, root: root,
				afterSingleRead: { cuts += 1 })
			XCTAssertEqual(captured, Data(closed.utf8))
			XCTAssertEqual(cuts, 1)
		}
	}

	func testSymlinkAndWrongPrivateModeAreRefused() throws {
		try fixture { root, owner, journal in
			try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.path)
			XCTAssertNil(HS274OwnedBoundaryConsole.capture(owner: owner, root: root))
			let original = owner.appendingPathComponent("foreign")
			try FileManager.default.moveItem(at: journal, to: original)
			try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: original)
			XCTAssertNil(HS274OwnedBoundaryConsole.capture(owner: owner, root: root))
		}
	}

	func testSameByteJournalReplacementAfterCaptureIsRefused() throws {
		try fixture { root, owner, journal in
			var mutation: Error?
			let captured = HS274OwnedBoundaryConsole.capture(owner: owner, root: root, afterSingleRead: {
				do {
					try FileManager.default.moveItem(at: journal, to: owner.appendingPathComponent("retained"))
					try Data(self.closed.utf8).write(to: journal)
					try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
				} catch { mutation = error }
			})
			XCTAssertNil(mutation)
			XCTAssertNil(captured)
		}
	}

	func testOwnerAncestorReplacementAfterCaptureIsRefused() throws {
		try fixture { root, owner, journal in
			var mutation: Error?
			let captured = HS274OwnedBoundaryConsole.capture(owner: owner, root: root, afterSingleRead: {
				do {
					try FileManager.default.moveItem(at: owner, to: root.appendingPathComponent("retained-owner"))
					try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: false,
						attributes: [.posixPermissions: 0o700])
					try Data(self.closed.utf8).write(to: journal)
					try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
				} catch { mutation = error }
			})
			XCTAssertNil(mutation)
			XCTAssertNil(captured)
		}
	}

	func testHookStaysAfterOriginalFinishAndInsideFailedReceiptBranch() throws {
		let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.appendingPathComponent("HS274NativePolicyQualificationTests.swift")
		let source = try String(contentsOf: path, encoding: .utf8)
		let start = try XCTUnwrap(source.range(of: "func runOwnedRuntimeCompilation("))
		let end = try XCTUnwrap(source.range(of: "func runCoreConstructorCompilation(", range: start.upperBound..<source.endIndex))
		let body = String(source[start.lowerBound..<end.lowerBound])
		let finish = try XCTUnwrap(body.range(of: "let receipt = try child.finish()"))
		let refused = try XCTUnwrap(body.range(of: "if receipt.status != 0 {"))
		let projection = try XCTUnwrap(body.range(of: "HS274OwnedBoundaryConsole.observe("))
		XCTAssertLessThan(finish.lowerBound, refused.lowerBound)
		XCTAssertLessThan(refused.lowerBound, projection.lowerBound)
		XCTAssertTrue(body.contains("return receipt"))
		XCTAssertEqual(body.components(separatedBy: "compilationMetadataToken: NativeFixtureChildEnvironment.compilationMetadataToken()").count - 1, 1)
	}
}

extension HS274OwnedBoundaryConsoleTests {

	func testIndependentWriterMixedNestedEmptyPhaseAndNonlifoNativeSiblings() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"inputs","sync_ns":10}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":3000,"parent":1,"phase":"","schema":1,"seq":3,"span":2,"stage":"staged_source","sync_ns":20}
		{"code":"","elapsed_ns":990,"event":"complete","mono_ns":4000,"parent":1,"phase":"","schema":1,"seq":4,"span":2,"stage":"staged_source","sync_ns":30}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":5000,"parent":1,"phase":"core_build","schema":1,"seq":5,"span":3,"stage":"native_dispatch","sync_ns":40}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":6000,"parent":1,"phase":"console_build","schema":1,"seq":6,"span":4,"stage":"native_dispatch","sync_ns":50}
		{"code":"","elapsed_ns":990,"event":"complete","mono_ns":7000,"parent":1,"phase":"console_build","schema":1,"seq":7,"span":4,"stage":"native_dispatch","sync_ns":60}
		{"code":"","elapsed_ns":2990,"event":"complete","mono_ns":8000,"parent":1,"phase":"core_build","schema":1,"seq":8,"span":3,"stage":"native_dispatch","sync_ns":70}
		{"code":"","elapsed_ns":6990,"event":"complete","mono_ns":9000,"parent":0,"phase":"","schema":1,"seq":9,"span":1,"stage":"inputs","sync_ns":80}
		{"code":"","elapsed_ns":9000,"event":"writer_end","mono_ns":10000,"parent":0,"phase":"","schema":1,"seq":10,"span":0,"stage":"compilation","sync_ns":90}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "writer_end_observed")
		XCTAssertEqual(result["writer_end_observed"] as? Bool, true)
		XCTAssertEqual(result["source_record_count"] as? Int, 10)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 2)
		XCTAssertEqual(result["omitted_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 2)
		XCTAssertEqual(spans[0]["span"] as? Int, 3)
		XCTAssertEqual(spans[0]["phase"] as? String, "core_build")
		XCTAssertEqual(spans[0]["event"] as? String, "complete")
		XCTAssertEqual(spans[0]["elapsed_ns"] as? Int, 2990)
		XCTAssertEqual(spans[0]["code"] as? String, "")
		XCTAssertTrue(spans[0]["phase_exit_status"] is NSNull)
		XCTAssertEqual(spans[1]["span"] as? Int, 4)
		XCTAssertEqual(spans[1]["phase"] as? String, "console_build")
		XCTAssertEqual(spans[1]["event"] as? String, "complete")
		XCTAssertEqual(spans[1]["elapsed_ns"] as? Int, 990)
		XCTAssertEqual(spans[1]["code"] as? String, "")
		XCTAssertTrue(spans[1]["phase_exit_status"] is NSNull)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
		XCTAssertEqual(result["escaped_sessions_managed"] as? Bool, false)
		XCTAssertEqual(result["worker_exit_status"] as? Int, 124)
	}

	func testIndependentWriterOriginalProductsSourceIdentityThenHeldProductChanged() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"inputs","sync_ns":10}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":3000,"parent":1,"phase":"","schema":1,"seq":3,"span":2,"stage":"products","sync_ns":20}
		{"code":"source_identity","elapsed_ns":990,"event":"refused","mono_ns":4000,"parent":1,"phase":"","schema":1,"seq":4,"span":2,"stage":"products","sync_ns":30}
		{"code":"held_product_changed","elapsed_ns":1990,"event":"refused","mono_ns":5000,"parent":1,"phase":"","schema":1,"seq":5,"span":2,"stage":"products","sync_ns":40}
		{"code":"source_identity","elapsed_ns":3990,"event":"refused","mono_ns":6000,"parent":0,"phase":"","schema":1,"seq":6,"span":1,"stage":"inputs","sync_ns":50}
		{"code":"","elapsed_ns":6000,"event":"writer_end","mono_ns":7000,"parent":0,"phase":"","schema":1,"seq":7,"span":0,"stage":"compilation","sync_ns":60}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "writer_end_observed")
		XCTAssertEqual(result["source_record_count"] as? Int, 7)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		XCTAssertEqual(result["omitted_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
		XCTAssertEqual(result["worker_exit_status"] as? Int, 124)
	}

	func testIndependentWriterOriginalProductsSourceIdentityThenOpenedIncarnation() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"inputs","sync_ns":10}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":3000,"parent":1,"phase":"","schema":1,"seq":3,"span":2,"stage":"products","sync_ns":20}
		{"code":"source_identity","elapsed_ns":990,"event":"refused","mono_ns":4000,"parent":1,"phase":"","schema":1,"seq":4,"span":2,"stage":"products","sync_ns":30}
		{"code":"opened_incarnation","elapsed_ns":1990,"event":"refused","mono_ns":5000,"parent":1,"phase":"","schema":1,"seq":5,"span":2,"stage":"products","sync_ns":40}
		{"code":"source_identity","elapsed_ns":3990,"event":"refused","mono_ns":6000,"parent":0,"phase":"","schema":1,"seq":6,"span":1,"stage":"inputs","sync_ns":50}
		{"code":"","elapsed_ns":6000,"event":"writer_end","mono_ns":7000,"parent":0,"phase":"","schema":1,"seq":7,"span":0,"stage":"compilation","sync_ns":60}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "writer_end_observed")
		XCTAssertEqual(result["source_record_count"] as? Int, 7)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		XCTAssertEqual(result["omitted_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
		XCTAssertEqual(result["worker_exit_status"] as? Int, 124)
	}

	func testIndependentWriterOriginalProductsSourceIdentityThenReadCurrentness() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"inputs","sync_ns":10}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":3000,"parent":1,"phase":"","schema":1,"seq":3,"span":2,"stage":"products","sync_ns":20}
		{"code":"source_identity","elapsed_ns":990,"event":"refused","mono_ns":4000,"parent":1,"phase":"","schema":1,"seq":4,"span":2,"stage":"products","sync_ns":30}
		{"code":"read_currentness","elapsed_ns":1990,"event":"refused","mono_ns":5000,"parent":1,"phase":"","schema":1,"seq":5,"span":2,"stage":"products","sync_ns":40}
		{"code":"source_identity","elapsed_ns":3990,"event":"refused","mono_ns":6000,"parent":0,"phase":"","schema":1,"seq":6,"span":1,"stage":"inputs","sync_ns":50}
		{"code":"","elapsed_ns":6000,"event":"writer_end","mono_ns":7000,"parent":0,"phase":"","schema":1,"seq":7,"span":0,"stage":"compilation","sync_ns":60}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "writer_end_observed")
		XCTAssertEqual(result["source_record_count"] as? Int, 7)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		XCTAssertEqual(result["omitted_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
		XCTAssertEqual(result["worker_exit_status"] as? Int, 124)
	}

	func testIndependentWriterDuplicateNativeFinish() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"core_build","schema":1,"seq":2,"span":1,"stage":"native_dispatch","sync_ns":10}
		{"code":"","elapsed_ns":990,"event":"complete","mono_ns":3000,"parent":0,"phase":"core_build","schema":1,"seq":3,"span":1,"stage":"native_dispatch","sync_ns":20}
		{"code":"source_identity","elapsed_ns":1990,"event":"refused","mono_ns":4000,"parent":0,"phase":"core_build","schema":1,"seq":4,"span":1,"stage":"native_dispatch","sync_ns":30}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testIndependentWriterProductsRepeatedRefusalWithoutSourceIdentity() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"products","sync_ns":10}
		{"code":"unexpected","elapsed_ns":990,"event":"refused","mono_ns":3000,"parent":0,"phase":"","schema":1,"seq":3,"span":1,"stage":"products","sync_ns":20}
		{"code":"held_product_changed","elapsed_ns":1990,"event":"refused","mono_ns":4000,"parent":0,"phase":"","schema":1,"seq":4,"span":1,"stage":"products","sync_ns":30}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testIndependentWriterThirdProductsRefusal() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"products","sync_ns":10}
		{"code":"source_identity","elapsed_ns":990,"event":"refused","mono_ns":3000,"parent":0,"phase":"","schema":1,"seq":3,"span":1,"stage":"products","sync_ns":20}
		{"code":"held_product_changed","elapsed_ns":1990,"event":"refused","mono_ns":4000,"parent":0,"phase":"","schema":1,"seq":4,"span":1,"stage":"products","sync_ns":30}
		{"code":"opened_incarnation","elapsed_ns":2990,"event":"refused","mono_ns":5000,"parent":0,"phase":"","schema":1,"seq":5,"span":1,"stage":"products","sync_ns":40}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testIndependentWriterNonNativeStageWithNativePhase() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"core_build","schema":1,"seq":2,"span":1,"stage":"inputs","sync_ns":10}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testIndependentWriterNativeStageWithEmptyPhase() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"native_dispatch","sync_ns":10}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testIndependentWriterOrphanParent() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":99,"phase":"core_build","schema":1,"seq":2,"span":1,"stage":"native_dispatch","sync_ns":10}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}
}

// Independent graph negatives frozen before LIVE-parent/direct-child guards.
extension HS274OwnedBoundaryConsoleTests {

	func testIndependentGraphEnterAfterParentFinished() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"core_build","schema":1,"seq":2,"span":1,"stage":"native_dispatch","sync_ns":10}
		{"code":"","elapsed_ns":990,"event":"complete","mono_ns":3000,"parent":0,"phase":"core_build","schema":1,"seq":3,"span":1,"stage":"native_dispatch","sync_ns":20}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":4000,"parent":1,"phase":"console_build","schema":1,"seq":4,"span":2,"stage":"native_dispatch","sync_ns":30}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testIndependentGraphFinishParentWithChildStillOpen() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"core_build","schema":1,"seq":2,"span":1,"stage":"native_dispatch","sync_ns":10}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":3000,"parent":1,"phase":"console_build","schema":1,"seq":3,"span":2,"stage":"native_dispatch","sync_ns":20}
		{"code":"","elapsed_ns":1990,"event":"complete","mono_ns":4000,"parent":0,"phase":"core_build","schema":1,"seq":4,"span":1,"stage":"native_dispatch","sync_ns":30}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}

	func testIndependentGraphProductsKnownAxisExtensionAfterParentFinished() throws {
		let input = #"""
		{"code":"","elapsed_ns":0,"event":"writer_start","mono_ns":1000,"parent":0,"phase":"","schema":1,"seq":1,"span":0,"stage":"compilation","sync_ns":0}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":2000,"parent":0,"phase":"","schema":1,"seq":2,"span":1,"stage":"inputs","sync_ns":10}
		{"code":"","elapsed_ns":0,"event":"enter","mono_ns":3000,"parent":1,"phase":"","schema":1,"seq":3,"span":2,"stage":"products","sync_ns":20}
		{"code":"source_identity","elapsed_ns":990,"event":"refused","mono_ns":4000,"parent":1,"phase":"","schema":1,"seq":4,"span":2,"stage":"products","sync_ns":30}
		{"code":"source_identity","elapsed_ns":2990,"event":"refused","mono_ns":5000,"parent":0,"phase":"","schema":1,"seq":5,"span":1,"stage":"inputs","sync_ns":40}
		{"code":"held_product_changed","elapsed_ns":2990,"event":"refused","mono_ns":6000,"parent":1,"phase":"","schema":1,"seq":6,"span":2,"stage":"products","sync_ns":50}
		"""# + "\n"
		let result = try object(projection(input))
		XCTAssertEqual(result["journal_state"] as? String, "unsupported")
		XCTAssertEqual(result["source_record_count"] as? Int, 0)
		XCTAssertEqual(result["observed_native_spans"] as? Int, 0)
		let spans = try XCTUnwrap(result["spans"] as? [[String: Any]])
		XCTAssertEqual(spans.count, 0)
		XCTAssertEqual(result["authority"] as? Bool, false)
		XCTAssertEqual(result["native_verdict"] as? String, "unchanged")
	}
}
