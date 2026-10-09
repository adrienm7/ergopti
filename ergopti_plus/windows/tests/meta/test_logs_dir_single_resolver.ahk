; tests/meta/test_logs_dir_single_resolver.ahk

; ==============================================================================
; MODULE: Logs Folder Single Resolver Meta Test
; DESCRIPTION:
; Class guard for the whole Windows driver: nothing rebuilds the logs or the
; crash-reports folder from the configuration folder.
;
; ROOT CAUSE ENCODED (logs-dir-single-resolver):
; The logs folder formula <ConfigDir>\autohotkey\logs\ was copied four times
; (the logger and three menu openers, each with its own A_ScriptDir fallback)
; and the crash reports lived under <ConfigDir>\autohotkey\crash_reports\ in
; three more places, one of them a PowerShell string. Moving the logs meant
; finding every copy. LoggerLogsDir() and LoggerCrashReportsDir() are now the
; only resolvers; the log file-name prefixes are guarded separately by
; tools/test/test-log-file-names-single-source.cjs.
; ==============================================================================

#Requires AutoHotkey v2.0

_LDSR_NoSecondLogsFormula() {
	Src := _DriverSourceNoComments()
	Assert(StrLen(Src) > 500000, "the whole driver source must be scanned")
	for Resolver in ["LoggerLogsDir() {", "LoggerCrashReportsDir() {",
			"LoggerTodayLogPath() {", "LoggerTodayErrorsPath() {"] {
		Assert(InStr(Src, Resolver) > 0, Resolver . " must exist in infra/logger.ahk")
	}
	for Formula in ['_AhkSubDir . "logs', 'autohotkey\crash_reports', 'A_ScriptDir . "\logs']
		Assert(InStr(Src, Formula) == 0,
			"'" . Formula . "' is a second copy of the logs-folder resolver; ask the logger")
	; The pre-logger sink was written beside paths.toml in two places.
	First := InStr(Src, "bootstrap.log")
	Assert(First > 0 && InStr(Src, "bootstrap.log", , First + 1) == 0,
		"bootstrap.log must be named once, by LoggerAppendBootstrapLine")
}
Test("logs folder: one resolver, no copy of the old folder formulas (logs-dir-single-resolver)",
	_LDSR_NoSecondLogsFormula)
