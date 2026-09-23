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
    and exports its path; Lua writes `kind=`, `stage=`, `message=`, `detail=`
    and, for a runtime stop, one `log=` line per log file before exiting. A
    report present after the child exits is therefore a fatal abort of that
    exact launch.
 3. Boot or runtime: a component that fails after boot completed stopped a
    running app. Titling that "could not start" and naming a boot "step" sent
    users hunting for a startup problem, so a runtime report gets its own
    title, names the component and lists the day's logs beside launcher.log.
 4. Readable: the file lives beside launcher.log, where users are told to look.
 ==============================================================================
 */

import Foundation

/// Environment key naming the per-launch fatal report file.
let kFatalReportEnvironment = "ERGOPTI_FATAL_REPORT_FILE"
/// Environment key naming launcher.log so Lua can append its fatal line.
let kLauncherLogEnvironment = "ERGOPTI_LAUNCHER_LOG_FILE"
/// Longest cause shown in the alert; the complete text stays in the logs.
let kFatalReportAlertDetailLimit = 600
/// English alert titles, shown only when the bundled catalog is unreadable
/// (the documented pre-i18n fatal-modal exception).
let kFatalBootTitleFallback = "ErgoptiPlus could not start"
let kFatalRuntimeTitleFallback = "Ergopti+ stopped unexpectedly"

/// Whether the embedded runtime failed while starting or after it had started.
enum EmbeddedFatalReportKind: String, Equatable {
	case boot
	case runtime
}

/// One fatal abort reported by the embedded Lua runtime.
struct EmbeddedFatalReport: Equatable {
	let kind: EmbeddedFatalReportKind
	/// Boot stage for a boot failure, failing component for a runtime stop.
	let stage: String
	let message: String
	let detail: String
	/// Logs the runtime named for this failure, in the order it wrote them.
	let logPaths: [String]
	/// A `kind=` value this launcher does not know, kept for the diagnostic.
	let unrecognizedKind: String?

	init(
		kind: EmbeddedFatalReportKind = .boot,
		stage: String,
		message: String,
		detail: String,
		logPaths: [String] = [],
		unrecognizedKind: String? = nil
	) {
		self.kind = kind
		self.stage = stage
		self.message = message
		self.detail = detail
		self.logPaths = logPaths
		self.unrecognizedKind = unrecognizedKind
	}

	/// Parses the single-line fields written by `adapters/boot_fatal.lua`.
	/// Unknown keys are ignored. A report is shown whatever its kind says: an
	/// unrecognised kind is presented as a boot failure and named in the
	/// diagnostic, because hiding a fatal report is worse than mislabelling it.
	/// - Parameter text: Complete report file content.
	/// - Returns: The report, or nil when no stage was recorded.
	static func parse(_ text: String) -> EmbeddedFatalReport? {
		var fields: [String: String] = [:]
		var logPaths: [String] = []
		for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
			guard let separator = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<separator])
			let value = String(line[line.index(after: separator)...])
			if key == "log" {
				if !value.isEmpty && !logPaths.contains(value) { logPaths.append(value) }
				continue
			}
			guard fields[key] == nil else { continue }
			fields[key] = value
		}
		guard let stage = fields["stage"], !stage.isEmpty else { return nil }
		let rawKind = fields["kind"] ?? EmbeddedFatalReportKind.boot.rawValue
		let kind = EmbeddedFatalReportKind(rawValue: rawKind)
		return EmbeddedFatalReport(
			kind: kind ?? .boot,
			stage: stage,
			message: fields["message"] ?? "",
			detail: fields["detail"] ?? "",
			logPaths: logPaths,
			unrecognizedKind: kind == nil ? rawKind : nil
		)
	}

	/// Developer diagnostic persisted in launcher.log and given to test observers.
	var diagnostic: String {
		switch kind {
		case .boot:
			let suffix = unrecognizedKind.map { " (unrecognised report kind '\($0)')" } ?? ""
			return "Embedded Hammerspoon stopped at boot stage '\(stage)': \(detail)\(suffix)"
		case .runtime:
			return "Embedded Hammerspoon stopped at runtime in component '\(stage)': \(detail)"
		}
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

/// Chooses the alert title: a failed start and a runtime stop read differently.
/// - Parameters:
///   - report: Parsed fatal report.
///   - localization: Bundled catalog, or nil when unreadable.
/// - Returns: Alert title; the English fallback is the pre-i18n exception.
func embeddedFatalAlertTitle(
	_ report: EmbeddedFatalReport,
	localization: LauncherLocalization?
) -> String {
	switch report.kind {
	case .boot:
		return localization?.text("launcher.fatal.title") ?? kFatalBootTitleFallback
	case .runtime:
		return localization?.text("launcher.fatal.title_runtime") ?? kFatalRuntimeTitleFallback
	}
}

/// Builds the user-facing alert body: the localized cause, then the stage or
/// component, the bounded developer detail and the logs to read.
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
	let summary: String
	switch report.kind {
	case .boot:
		summary = localization?.text("launcher.fatal.stage_detail", [report.stage, detail, logPath])
			?? "Step: \(report.stage)\nCause: \(detail)\nDetails are saved in \(logPath)."
	case .runtime:
		let logs = (report.logPaths.filter { $0 != logPath } + [logPath]).joined(separator: "\n")
		summary = localization?.text("launcher.fatal.component_detail", [report.stage, detail, logs])
			?? "Component: \(report.stage)\nCause: \(detail)\nDetails are saved in:\n\(logs)"
	}
	return report.message.isEmpty ? summary : report.message + "\n\n" + summary
}
