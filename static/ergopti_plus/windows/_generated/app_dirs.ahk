; _generated/app_dirs.ahk
; AUTO-GENERATED from _shared/modules/paths/app_dirs.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Application Folders and Log File Names (Windows)
; DESCRIPTION:
; The application folder name, the default logs folder and the log file-name
; prefixes. infra/logger.ahk owns the one logs-folder resolver built on them;
; nothing else spells a prefix or a folder formula.
;
; Functions rather than global initialisers so include ORDER cannot matter:
; boot reads them before the logger include has run its own top level.
; ==============================================================================

; Folder named after the application, on every OS.
AppDirsFolderName() {
	return "ergopti_plus"
}

; Separate direct LocalApplicationData child for the managed Windows runtime.
AppDirsWindowsManagedOllamaFolderName() {
	return "ergopti_plus_ollama"
}

; paths.toml key of the optional logs-folder override.
AppDirsLogsOverrideKey() {
	return "LogsDirPath"
}

; Subfolder of the logs folder receiving crash reports.
AppDirsCrashReportsDir() {
	return "crash_reports"
}

; Daily unified log: <prefix>yyyy-MM-dd<extension>.
AppDirsLogUnifiedPrefix() {
	return "ErgoptiPlus_"
}

; Daily WARNING and ERROR mirror: <prefix>yyyy-MM-dd<extension>.
AppDirsLogErrorsPrefix() {
	return "ErgoptiPlus_errors_"
}

; Topical sub-files: <prefix><name><extension>.
AppDirsLogTopicalPrefix() {
	return "ErgoptiPlus_"
}

; Extension of every log file.
AppDirsLogExtension() {
	return ".log"
}

; Environment variable holding the default logs root.
AppDirsWindowsLogsBaseEnv() {
	return "LOCALAPPDATA"
}

; Default logs folder, relative to that root.
AppDirsWindowsLogsRelative() {
	return "ergopti_plus\logs"
}
