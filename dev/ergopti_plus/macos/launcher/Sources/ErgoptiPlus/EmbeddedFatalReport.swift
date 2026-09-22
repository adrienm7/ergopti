// Sources/ErgoptiPlus/EmbeddedFatalReport.swift

/**
 ==============================================================================
 MODULE: Embedded fatal report
 DESCRIPTION:
 Carries a fatal Lua abort from the embedded Hammerspoon process to the
 launcher's modal alert.

 FEATURES & RATIONALE:
 1. Exit status is not evidence: Hammerspoon reports status 0 even after Lua
    calls os.exit(n), so once the logger handshake succeeded a fatal abort
    looked exactly like a deliberate Quit and the launcher terminated silently.
 2. Per-launch file: the launcher removes the report before every child start
    and exports its path; Lua writes `stage=`, `message=` and `detail=` lines
    before exiting. A report present after the child exits is therefore a
    fatal abort of that exact launch.
 3. Readable: the file lives beside launcher.log, where users are told to look.
 ==============================================================================
 */

import Foundation

/// Environment key naming the per-launch fatal report file.
let kFatalReportEnvironment = "ERGOPTI_FATAL_REPORT_FILE"
/// Environment key naming launcher.log so Lua can append its fatal line.
let kLauncherLogEnvironment = "ERGOPTI_LAUNCHER_LOG_FILE"
/// Longest cause shown in the alert; the complete text stays in the logs.
let kFatalReportAlertDetailLimit = 600

/// One fatal abort reported by the embedded Lua runtime.
struct EmbeddedFatalReport: Equatable {
	let stage: String
	let message: String
	let detail: String

	/// Parses the three single-line fields written by `adapters/boot_fatal.lua`.
	/// - Parameter text: Complete report file content.
	/// - Returns: The report, or nil when no stage was recorded.
	static func parse(_ text: String) -> EmbeddedFatalReport? {
		var fields: [String: String] = [:]
		for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
			guard let separator = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<separator])
			guard fields[key] == nil else { continue }
			fields[key] = String(line[line.index(after: separator)...])
		}
		guard let stage = fields["stage"], !stage.isEmpty else { return nil }
		return EmbeddedFatalReport(
			stage: stage,
			message: fields["message"] ?? "",
			detail: fields["detail"] ?? ""
		)
	}

	/// Developer diagnostic persisted in launcher.log and given to test observers.
	var diagnostic: String {
		return "Embedded Hammerspoon stopped at boot stage '\(stage)': \(detail)"
	}
}

/// Owns the report file of the current launch.
struct EmbeddedFatalReportStore {
	let path: String

	/// Removes any report left by an earlier launch so it cannot be misattributed.
	/// - Returns: False only when a stale report exists and could not be removed.
	@discardableResult
	func clear() -> Bool {
		guard FileManager.default.fileExists(atPath: path) else { return true }
		do {
			try FileManager.default.removeItem(atPath: path)
			return true
		} catch {
			return false
		}
	}

	/// Reads the report written by the child that just exited, if any.
	func read() -> EmbeddedFatalReport? {
		guard let data = FileManager.default.contents(atPath: path),
			let text = String(data: data, encoding: .utf8)
		else { return nil }
		return EmbeddedFatalReport.parse(text)
	}
}

/// Builds the user-facing alert body: the localized cause, then the stage, the
/// bounded developer detail and the log to read.
/// - Parameters:
///   - report: Parsed fatal report.
///   - logPath: launcher.log path shown to the user.
///   - localization: Bundled catalog, or nil when unreadable.
/// - Returns: Alert text; the English fallback is the pre-i18n exception.
func embeddedFatalAlertText(
	_ report: EmbeddedFatalReport,
	logPath: String,
	localization: LauncherLocalization?
) -> String {
	let detail = report.detail.count > kFatalReportAlertDetailLimit
		? String(report.detail.prefix(kFatalReportAlertDetailLimit)) + "…"
		: report.detail
	let summary = localization?.text("launcher.fatal.stage_detail", [report.stage, detail, logPath])
		?? "Step: \(report.stage)\nCause: \(detail)\nDetails are saved in \(logPath)."
	return report.message.isEmpty ? summary : report.message + "\n\n" + summary
}
