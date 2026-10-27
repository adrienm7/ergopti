// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/AppClonerWizardLocaleTests.swift
//
// Executes the shipped AppleScript first-picker construction against AppKit.
// A bounded owned timer observes the visible panel and cancels only that panel.

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
		source = try observingActualPicker(source)
		let result = try execute(source, arguments: [app.path], locale: locale, root: root)
		XCTAssertEqual(result.status, 0, "The actual App Cloner construction must execute: \(result.stderr)")
		XCTAssertTrue(result.stderr.isEmpty, "The App Cloner observation must emit no errors: \(result.stderr)")
		let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: String])
		XCTAssertEqual(actual["visible"], "true", "Observe a genuinely visible native picker")
		XCTAssertEqual(actual["cancel_role"], "AXButton", "Observe the public Cancel button itself")
		print("APPCLONER_PICKER_PUBLIC locale=\(locale) setter=\(actual["setter_selector"] ?? "<missing>") getter=\(actual["getter_selector"] ?? "<missing>") setter_error=\(String(reflecting: actual["setter_error"] ?? "<missing>")) cancel=\(String(reflecting: actual["cancel"] ?? "<missing>"))")
		return actual
	}

	private static let pickerObservationInterval: TimeInterval = 0.05
	private static let pickerObservationDeadline: TimeInterval = 5

	/// Keeps the real picker modal and setters, then inspects its public Cancel control.
	private func observingActualPicker(_ production: String) throws -> String {
		let modal = "set rc to panel's runModal()"
		XCTAssertEqual(production.components(separatedBy: modal).count, 2, "Instrument the one actual picker modal")
		guard production.components(separatedBy: modal).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
		let setter = "panel's setValue:(btn_cancel of u) forKey:\"cancelButtonTitle\""
		XCTAssertEqual(production.components(separatedBy: setter).count, 2, "Retain the one actual Cancel setter")
		guard production.components(separatedBy: setter).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
		// The original try already catches setter errors. Record that same outcome
		// without changing the setter or deciding whether it has a readable getter.
		let capturedSetter = setter + """

		on error pickerSetterMessage number pickerSetterNumber
			set my fixturePickerSetterError to (pickerSetterNumber as text) & ": " & pickerSetterMessage
		"""
		var source = production.replacingOccurrences(of: setter, with: capturedSetter)
		let modalObservation = """
		if (my fixturePickerPanel) is not missing value or (my fixturePickerTimer) is not missing value then error "The native picker observer was already armed."
		set my fixturePickerPanel to panel
		set pickerObserverProcess to current application's NSProcessInfo's processInfo()
		set my fixturePickerDeadline to ((pickerObserverProcess's systemUptime()) as real) + \(Self.pickerObservationDeadline)
		set my fixturePickerTimer to current application's NSTimer's timerWithTimeInterval:\(Self.pickerObservationInterval) target:me selector:"fixtureObservePicker:" userInfo:(missing value) repeats:true
		set pickerObserverLoop to current application's NSRunLoop's mainRunLoop()
		pickerObserverLoop's addTimer:(my fixturePickerTimer) forMode:(current application's NSModalPanelRunLoopMode)
		pickerObserverLoop's addTimer:(my fixturePickerTimer) forMode:(current application's NSRunLoopCommonModes)
		try
			\(modal)
		on error pickerModalMessage number pickerModalNumber
			my fixtureRetirePicker()
			error pickerModalMessage number pickerModalNumber
		end try
		my fixtureRetirePicker()
		-- Materialize callback-owned properties before commands can receive an
		-- object specifier instead of its current text value.
		set pickerFailureSnapshot to (get my fixturePickerError) as text
		set pickerReadinessSnapshot to (get my fixturePickerReadiness) as text
		set pickerSetterSnapshot to (get my fixturePickerSetterError) as text
		set pickerReceiptSnapshot to (get my fixturePickerReceipt) as text
		if pickerFailureSnapshot is not "" then error (pickerFailureSnapshot & " [readiness=" & pickerReadinessSnapshot & "; setter_error=" & pickerSetterSnapshot & "]")
		if rc is not (current application's NSModalResponseCancel) then error "The owned native picker was not cancelled."
		if pickerReceiptSnapshot is "" then error "The native picker observer produced no receipt."
		return pickerReceiptSnapshot
		"""
		source = source.replacingOccurrences(of: modal, with: modalObservation)
		// Declare the observer's properties before the run handler that reads
		// them. Appended after it, the run failed with the bare specifier
		// "fixturePickerError of «script» (-2700)" rather than any message the
		// observer sets: `my fixturePickerError` was not read as the property's
		// value there, so it never equalled "" and was raised as a reference.
		let runHandler = "\non run argv\n"
		XCTAssertEqual(source.components(separatedBy: runHandler).count, 2, "Declare the observer before the one actual run handler")
		guard source.components(separatedBy: runHandler).count == 2 else { throw CocoaError(.fileReadCorruptFile) }
		source = source.replacingOccurrences(of: runHandler, with: """

		property fixturePickerPanel : missing value
		property fixturePickerTimer : missing value
		property fixturePickerDeadline : 0.0
		property fixturePickerReceipt : ""
		property fixturePickerError : ""
		property fixturePickerSetterError : ""
		property fixturePickerFinished : false
		property fixturePickerReadiness : "panel visibility"

		""" + runHandler)
		return source + """

		on fixtureRetirePicker()
			if (my fixturePickerTimer) is not missing value then
				(my fixturePickerTimer)'s invalidate()
				set my fixturePickerTimer to missing value
			end if
			if (my fixturePickerPanel) is not missing value then
				(my fixturePickerPanel)'s orderOut:(missing value)
				set my fixturePickerPanel to missing value
			end if
		end fixtureRetirePicker

		on fixtureObservePicker:theTimer
			if my fixturePickerFinished then return
			set ownedPicker to my fixturePickerPanel
			try
				set observerProcess to current application's NSProcessInfo's processInfo()
				set observerNow to (observerProcess's systemUptime()) as real
				set pickerReadinessSnapshot to (get my fixturePickerReadiness) as text
				if observerNow ≥ (my fixturePickerDeadline) then error ("The actual native picker did not expose " & pickerReadinessSnapshot & " before its deadline.")
				if not ((ownedPicker's isVisible()) as boolean) then return
				set my fixturePickerReadiness to "a public Cancel button"
				set cancelControl to ownedPicker's accessibilityCancelButton()
				if cancelControl is missing value then return
				set cancelRole to (cancelControl's accessibilityRole()) as text
				if cancelRole is not ((current application's NSAccessibilityButtonRole) as text) then error "The native Cancel control is not an accessibility button."
				set my fixturePickerReadiness to "the public Cancel button visible title"
				set cancelTitle to cancelControl's accessibilityTitle()
				if cancelTitle is missing value then return
				set cancelTitle to cancelTitle as text
				if cancelTitle is "" then return
				set pickerSetterSnapshot to (get my fixturePickerSetterError) as text
				set observation to current application's NSDictionary's dictionaryWithObjects:{ownedPicker's prompt(), ownedPicker's message(), cancelTitle, cancelRole, (((ownedPicker's isVisible()) as boolean) as text), (((ownedPicker's respondsToSelector:"setCancelButtonTitle:") as boolean) as text), (((ownedPicker's respondsToSelector:"cancelButtonTitle") as boolean) as text), pickerSetterSnapshot} forKeys:{"prompt", "message", "cancel", "cancel_role", "visible", "setter_selector", "getter_selector", "setter_error"}
				set {observationData, observationError} to current application's NSJSONSerialization's dataWithJSONObject:observation options:0 |error|:(reference)
				if observationData is missing value then error "The native picker observer could not encode its receipt."
				set my fixturePickerReceipt to (current application's NSString's alloc()'s initWithData:observationData encoding:(current application's NSUTF8StringEncoding)) as text
			on error observerMessage number observerNumber
				set my fixturePickerError to "The native picker observer refused: " & (observerNumber as text) & ": " & observerMessage
			end try
			set my fixturePickerFinished to true
			theTimer's invalidate()
			try
				ownedPicker's cancel:(missing value)
			on error cancelMessage number cancelNumber
				set pickerFailureSnapshot to (get my fixturePickerError) as text
				set my fixturePickerError to pickerFailureSnapshot & " Native picker cancellation failed: " & (cancelNumber as text) & ": " & cancelMessage
				-- Failed cancellation never becomes success. Only stop this script's
				-- exact owned modal so its original observer failure can be reported.
				set observerApp to current application's NSApplication's sharedApplication()
				set ownedModal to observerApp's modalWindow()
				if ownedModal is not missing value then
					if ((ownedModal's isEqual:ownedPicker) as boolean) then observerApp's stopModalWithCode:(current application's NSModalResponseCancel)
				end if
			end try
		end fixtureObservePicker:
		"""
	}

	func testPickerObserverMaterializesCallbackDiagnosticsAndReceipt() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerObserver-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact observer diagnostic fixture did not retire") }
			}
		}
		let production = try String(contentsOf: Self.payloadURL.appendingPathComponent("macos/apps/App Cloner.app/Contents/Resources/ShortcutBuilder.applescript"), encoding: .utf8)
		let instrumented = try observingActualPicker(production)
		// Reuse the actual generated post-modal branch, including its error and
		// return commands. A mirrored test-only implementation could hide a bug.
		let parts = instrumented.components(separatedBy: "\nmy fixtureRetirePicker()\n")
		XCTAssertEqual(parts.count, 2, "Admit exactly one real post-modal observer branch")
		guard parts.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
		let lines = parts[1].components(separatedBy: "\n")
		let returnIndex = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("return ") })
		let tail = lines[...returnIndex].joined(separator: "\n")
		let probe = """
		use framework "AppKit"
		use scripting additions
		property fixturePickerError : ""
		property fixturePickerReadiness : ""
		property fixturePickerSetterError : ""
		property fixturePickerReceipt : ""
		on run argv
			set my fixturePickerReadiness to "owned readiness marker"
			set my fixturePickerSetterError to "owned setter marker"
			if item 1 of argv is "failure" then
				set my fixturePickerError to "owned callback failure"
			else if item 1 of argv is "receipt" then
				set my fixturePickerReceipt to "owned callback receipt"
			end if
			set rc to current application's NSModalResponseCancel
			\(tail)
		end run
		"""
		let failed = try execute(probe, arguments: ["failure"], locale: "en", root: root)
		XCTAssertNotEqual(failed.status, 0)
		XCTAssertTrue(failed.output.isEmpty)
		for marker in ["owned callback failure", "owned readiness marker", "owned setter marker"] {
			XCTAssertTrue(failed.stderr.contains(marker), "The real observer error must expose stored callback values")
		}
		XCTAssertFalse(failed.stderr.contains("fixturePickerError of"), "A property specifier is not the callback error text")
		let receipt = try execute(probe, arguments: ["receipt"], locale: "en", root: root)
		XCTAssertEqual(receipt.status, 0, receipt.stderr)
		XCTAssertTrue(receipt.stderr.isEmpty)
		XCTAssertEqual(String(decoding: receipt.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "owned callback receipt")
		let missing = try execute(probe, arguments: ["missing"], locale: "en", root: root)
		XCTAssertNotEqual(missing.status, 0)
		XCTAssertTrue(missing.output.isEmpty)
		XCTAssertTrue(missing.stderr.contains("The native picker observer produced no receipt."))
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
		XCTAssertEqual(actual["cancel"], expected["button.cancel"])
		XCTAssertEqual(actual["message"], "Application to clone")
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
