// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/AppClonerWizardLocaleTests.swift
//
// Executes the shipped AppleScript first-picker construction against AppKit.
// An observation before runModal inspects the real panel without opening it.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class AppClonerWizardLocaleTests: XCTestCase {
	private var fixtureCanRetire = true

	private static var payloadURL: URL {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { root.deleteLastPathComponent() }
		return root.appendingPathComponent("static/ergopti_plus")
	}

	private func observePicker(locale: String, oldFrenchMutant: Bool = false) throws -> [String: String] {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerLocale-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact App Cloner fixture directory did not retire") }
			}
		}
		let app = Self.payloadURL.appendingPathComponent("macos/apps/App Cloner.app")
		var source = try String(contentsOf: app.appendingPathComponent("Contents/Resources/ShortcutBuilder.applescript"), encoding: .utf8)
		if oldFrenchMutant {
			let binding = "panel's setPrompt:(btn_choose of u)"
			XCTAssertEqual(source.components(separatedBy: binding).count, 2, "Mutate the one actual picker prompt")
			guard source.components(separatedBy: binding).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
			source = source.replacingOccurrences(of: binding, with: "panel's setPrompt:\"Choisir\"")
		}
		let modal = "set rc to panel's runModal()"
		XCTAssertEqual(source.components(separatedBy: modal).count, 2, "Observe the one actual picker before its modal")
		guard source.components(separatedBy: modal).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
		// All locale resolution, catalogue reads and AppKit setters stay original.
		// Return from the actual on run handler before opening any modal or cloning.
		let observation = """
		set observation to current application's NSDictionary's dictionaryWithObjects:{panel's prompt(), panel's message(), panel's valueForKey:"cancelButtonTitle"} forKeys:{"prompt", "message", "cancel"}
		set observationData to current application's NSJSONSerialization's dataWithJSONObject:observation options:0 |error|:(missing value)
		return (current application's NSString's alloc()'s initWithData:observationData encoding:(current application's NSUTF8StringEncoding)) as text
		"""
		source = source.replacingOccurrences(of: modal, with: observation + "\n" + modal)
		let result = try execute(source, arguments: [app.path], locale: locale, root: root)
		XCTAssertEqual(result.status, 0, "The actual App Cloner construction must execute: \(result.stderr)")
		XCTAssertTrue(result.stderr.isEmpty, "The App Cloner observation must emit no errors: \(result.stderr)")
		return try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: String])
	}

	private struct NativeResult {
		let status: Int32
		let output: Data
		let stderr: String
	}

	private func execute(_ source: String, arguments: [String], locale: String, root: URL) throws -> NativeResult {
		let script = root.appendingPathComponent(UUID().uuidString + ".applescript")
		let outputURL = root.appendingPathComponent(UUID().uuidString + ".stdout")
		let errorURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
		try source.write(to: script, atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { try? output.close(); try? errors.close() }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = [script.path] + arguments
		var environment = NativeFixtureChildEnvironment.make()
		environment["ERGOPTI_LOCALE"] = locale
		environment["ERGOPTI_LOCALES_DIR"] = Self.payloadURL.appendingPathComponent("_shared/data/locales").path
		environment["ERGOPTI_APPCLONER_LOG"] = root.appendingPathComponent("appcloner.log").path
		process.environment = environment
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
				XCTFail("The exact App Cloner observation child did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		return NativeResult(status: process.terminationStatus, output: try Data(contentsOf: outputURL),
			stderr: try String(contentsOf: errorURL, encoding: .utf8))
	}

	private func catalogue(_ locale: String) throws -> [String: String] {
		let file = Self.payloadURL.appendingPathComponent("_shared/data/locales/\(locale).json")
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
	}

	func testActualEnglishPickerUsesTheSelectedCatalogue() throws {
		let actual = try observePicker(locale: "en")
		let expected = try catalogue("en")
		XCTAssertEqual(actual["prompt"], expected["apps.cloner.btn_choose"])
		XCTAssertEqual(actual["cancel"], expected["button.cancel"])
		XCTAssertEqual(actual["message"], "Application to clone")
	}

	func testActualFrenchPickerPreservesItsSelectedCatalogue() throws {
		let actual = try observePicker(locale: "fr")
		let expected = try catalogue("fr")
		XCTAssertEqual(actual["prompt"], expected["apps.cloner.btn_choose"])
		XCTAssertEqual(actual["cancel"], expected["button.cancel"])
		XCTAssertEqual(actual["message"], "Application à cloner")
	}

	func testActualEnglishPickerRejectsTheOldFrenchPromptMutant() throws {
		let actual = try observePicker(locale: "en", oldFrenchMutant: true)
		let expected = try catalogue("en")
		XCTAssertEqual(actual["prompt"], "Choisir", "The injected old prompt must execute in AppKit")
		XCTAssertNotEqual(actual["prompt"], expected["apps.cloner.btn_choose"], "The real-panel oracle must reject the old French prompt")
	}

	private func catalogueScript() throws -> String {
		let path = Self.payloadURL.appendingPathComponent("macos/apps/App Cloner.app/Contents/Resources/ShortcutBuilder.applescript")
		let actual = try String(contentsOf: path, encoding: .utf8)
		var handlers: [String] = []
		for name in ["load_catalogue", "ui_string"] {
			let expression = try NSRegularExpression(pattern: "(?ms)^on " + name + "\\([^\\n]*\\).*?^end " + name + "[ \\t]*$")
			let matches = expression.matches(in: actual, range: NSRange(actual.startIndex..., in: actual))
			XCTAssertEqual(matches.count, 1, "Execute the one actual production catalogue handler")
			guard matches.count == 1, let range = Range(matches[0].range, in: actual) else { throw CocoaError(.fileReadCorruptFile) }
			handlers.append(String(actual[range]))
		}
		return "use AppleScript version \"2.4\"\nuse framework \"Foundation\"\nuse scripting additions\n"
			+ handlers.joined(separator: "\n\n") + """

		on run argv
			set catalogue to my load_catalogue(item 1 of argv, item 2 of argv)
			set localized_value to my ui_string(catalogue, "ui.value")
			set receipt to current application's NSDictionary's dictionaryWithObject:localized_value forKey:"value"
			set {receipt_data, receipt_error} to current application's NSJSONSerialization's dataWithJSONObject:receipt options:0 |error|:(reference)
			if receipt_data is missing value then error "The native catalogue control could not encode its receipt."
			return (current application's NSString's alloc()'s initWithData:receipt_data encoding:(current application's NSUTF8StringEncoding)) as text
		end run
		"""
	}


	func testActualUIFormatterPreservesTheUserNameAsData() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerFormat-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact native formatter fixture directory did not retire") }
			}
		}
		let file = Self.payloadURL.appendingPathComponent("macos/apps/App Cloner.app/Contents/Resources/ShortcutBuilder.applescript")
		let actual = try String(contentsOf: file, encoding: .utf8)
		let expression = try NSRegularExpression(pattern: "(?ms)^on format_ui\\([^\\n]*\\).*?^end format_ui[ \\t]*$")
		let matches = expression.matches(in: actual, range: NSRange(actual.startIndex..., in: actual))
		XCTAssertEqual(matches.count, 1)
		guard matches.count == 1, let range = Range(matches[0].range, in: actual) else { throw CocoaError(.fileReadCorruptFile) }
		let script = "use framework \"Foundation\"\n" + String(actual[range]) + """

		on run argv
			set formatted_value to my format_ui(item 1 of argv, item 2 of argv)
			set receipt to current application's NSDictionary's dictionaryWithObject:formatted_value forKey:"value"
			set {receipt_data, receipt_error} to current application's NSJSONSerialization's dataWithJSONObject:receipt options:0 |error|:(reference)
			if receipt_data is missing value then error "The native formatter control could not encode its receipt."
			return (current application's NSString's alloc()'s initWithData:receipt_data encoding:(current application's NSUTF8StringEncoding)) as text
		end run
		"""
		let userName = "A \"quoted\" C:\\path {1} %s\n🌍"
		for locale in ["en", "fr"] {
			let template = try XCTUnwrap(catalogue(locale)["apps.cloner.default_clone_name"])
			let result = try execute(script, arguments: [template, userName], locale: locale, root: root)
			XCTAssertEqual(result.status, 0, "The actual formatter must execute: \(result.stderr)")
			XCTAssertTrue(result.stderr.isEmpty)
			let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: String])
			XCTAssertEqual(decoded["value"], userName + " — Clone", "A placeholder inside the user name must remain data")
		}
	}

	func testActualCatalogueHandlersDecodeAllJSONEscapes() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerDecode-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact native catalogue fixture directory did not retire") }
			}
		}
		let script = try catalogueScript()
		let cases = [
			("plain", #"{"ui.value":"Choose"}"#, "Choose"),
			("quoted", #"{"ui.value":"Click \"Open\""}"#, "Click \"Open\""),
			("newline", #"{"ui.value":"First line\nSecond line"}"#, "First line\nSecond line"),
			("backslash", #"{"ui.value":"C:\\folder\\file"}"#, "C:\\folder\\file"),
			("unicode", #"{"ui.value":"\u00c9 \ud83c\udf0d"}"#, "É 🌍")
		]
		for (name, document, expected) in cases {
			try document.write(to: root.appendingPathComponent(name + ".json"), atomically: true, encoding: .utf8)
			let result = try execute(script, arguments: [name, root.path], locale: "en", root: root)
			XCTAssertEqual(result.status, 0, "Valid native catalogue case: \(name), \(result.stderr)")
			XCTAssertTrue(result.stderr.isEmpty)
			let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: String])
			XCTAssertEqual(decoded["value"], expected, "The actual handler must decode \(name)")
		}
	}

	func testActualCatalogueHandlersRefuseInvalidFilesAndValues() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerRefusal-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact native catalogue fixture directory did not retire") }
			}
		}
		let script = try catalogueScript()
		let cases: [(String, String?, String)] = [
			("missing-key", "{}", "App Cloner locale key is missing."),
			("empty", #"{"ui.value":""}"#, "App Cloner locale string is empty."),
			("number", #"{"ui.value":7}"#, "App Cloner locale value must be a string."),
			("boolean", #"{"ui.value":true}"#, "App Cloner locale value must be a string."),
			("null", #"{"ui.value":null}"#, "App Cloner locale value must be a string."),
			("array-value", #"{"ui.value":[]}"#, "App Cloner locale value must be a string."),
			("object-value", #"{"ui.value":{}}"#, "App Cloner locale value must be a string."),
			("array-catalogue", "[]", "App Cloner locale catalogue must be a JSON object."),
			("invalid-json", #"{"ui.value":"#, "App Cloner locale catalogue is invalid JSON."),
			("absent-catalogue", nil, "App Cloner locale catalogue is unavailable.")
		]
		for (name, document, error) in cases {
			if let document { try document.write(to: root.appendingPathComponent(name + ".json"), atomically: true, encoding: .utf8) }
			let result = try execute(script, arguments: [name, root.path], locale: "en", root: root)
			XCTAssertNotEqual(result.status, 0, "The actual handler must refuse \(name)")
			XCTAssertTrue(result.stderr.contains(error), "Require the precise native refusal for \(name): \(result.stderr)")
		}
	}

}
