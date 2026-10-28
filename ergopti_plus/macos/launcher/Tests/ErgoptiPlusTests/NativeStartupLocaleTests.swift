// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeStartupLocaleTests.swift
//
// Compiles the actual startup dialog program and observes argument transport.
// The observation returns before display dialog, without presenting a modal.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeStartupLocaleTests: XCTestCase {
	private var fixtureCanRetire = true

	private static var payloadURL: URL {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { root.deleteLastPathComponent() }
		return root.appendingPathComponent("static/ergopti_plus")
	}

	private struct NativeResult {
		let status: Int32
		let output: Data
		let stderr: String
	}

	private func execute(_ source: String, arguments: [String], root: URL) throws -> NativeResult {
		let outputURL = root.appendingPathComponent(UUID().uuidString + ".stdout")
		let errorURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { try? output.close(); try? errors.close() }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", source, "--"] + arguments
		process.environment = NativeFixtureChildEnvironment.make()
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + 15) == .success else {
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + 5) != .success {
				fixtureCanRetire = false
				XCTFail("The exact App Cloner startup observation child did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		return NativeResult(status: process.terminationStatus, output: try Data(contentsOf: outputURL),
			stderr: try String(contentsOf: errorURL, encoding: .utf8))
	}


	func testActualStartupProgramPreservesArgumentsAsData() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerStartup-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact startup dialog fixture directory did not retire") }
			}
		}
		let launcher = Self.payloadURL.appendingPathComponent("macos/apps/App Cloner.app/Contents/MacOS/AppCloner")
		let actual = try String(contentsOf: launcher, encoding: .utf8)
		let expression = try NSRegularExpression(pattern: "(?s)ERROR_DIALOG_SCRIPT = \"\"\"(.*?)\"\"\"")
		let matches = expression.matches(in: actual, range: NSRange(actual.startIndex..., in: actual))
		XCTAssertEqual(matches.count, 1, "Observe the one actual startup dialog program")
		guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: actual) else { throw CocoaError(.fileReadCorruptFile) }
		let production = String(actual[range])
		let display = "display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv} default button 1"
		XCTAssertEqual(production.components(separatedBy: display).count, 2, "Observe the exact dialog without opening it")
		guard production.components(separatedBy: display).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
		let observation = """
		set receipt to current application's NSDictionary's dictionaryWithObject:argv forKey:"arguments"
		set {receipt_data, receipt_error} to current application's NSJSONSerialization's dataWithJSONObject:receipt options:0 |error|:(reference)
		if receipt_data is missing value then error "The native startup observer could not encode its receipt."
		return (current application's NSString's alloc()'s initWithData:receipt_data encoding:(current application's NSUTF8StringEncoding)) as text
		"""
		// Keep the actual display statement so the native parser still checks it.
		let source = "use framework \"Foundation\"\nuse scripting additions\n" + production.replacingOccurrences(of: display, with: observation + "\n" + display)
		let cases = [
			["--leading-dash \"quote\" C:\\path {1}\n\n🌍", "App Cloner — Startup error", "OK"],
			["Erreur inconnue.\n\nLe diagnostic complet est dans /tmp/a \"quoted\" path", "App Cloner — Erreur de démarrage", "Valider"]
		]
		for arguments in cases {
			let result = try execute(source, arguments: arguments, root: root)
			XCTAssertEqual(result.status, 0, "The actual startup program must compile and run: \(result.stderr)")
			XCTAssertTrue(result.stderr.isEmpty)
			let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: [String]])
			XCTAssertEqual(receipt["arguments"], arguments, "Argument data must survive the actual osascript option boundary")
		}
	}
}
