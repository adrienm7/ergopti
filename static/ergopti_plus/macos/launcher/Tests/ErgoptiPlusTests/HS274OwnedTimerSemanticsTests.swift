// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedTimerSemanticsTests.swift
// Actual vendor dispatcher/software-clock subset; no native manipulator engine.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {
	func testActualPinnedDispatcherCancellationUsesGenuineOfflineLibrary() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_timer_semantics_test.py")
			let repository = script.deletingLastPathComponent().deletingLastPathComponent()
				.deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", script.path, "--owner", root.path,
					"--repository", repository.path, "--compiler", "/usr/bin/clang++"], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable pinned dispatcher cases=7 failures=0 errors=0 skipped=0 native_engine=unexecuted\n")
			// Require the whole ordinary unittest receipt, not a borrowed suffix
			// or seven discovered cases with skipped/unexecuted bodies.
			let pattern = "\\A\\.{7}\\n-{70}\\nRan 7 tests in ([0-9]+(?:\\.[0-9]+)?)s\\n\\nOK\\n\\z"
			let expression = try NSRegularExpression(pattern: pattern)
			let text = receipt.stderr
			let whole = NSRange(text.startIndex..<text.endIndex, in: text)
			let matches = expression.matches(in: text, range: whole)
			XCTAssertEqual(matches.count, 1)
			let match = try XCTUnwrap(matches.first)
			let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
			let elapsed = try XCTUnwrap(Double(text[range]))
			XCTAssertTrue(elapsed.isFinite && elapsed >= 0)
		}
	}
}
