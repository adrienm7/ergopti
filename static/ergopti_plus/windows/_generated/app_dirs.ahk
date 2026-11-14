; _generated/app_dirs.ahk
; AUTO-GENERATED from _shared/core/fs/data/paths/app_dirs.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:app-dirs` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Application Folders and Log File Names (Windows)
; DESCRIPTION:
; The application folder name, the default logs folder and the log file-name
; prefixes. core/logger/engine/logger.ahk owns the one logs-folder resolver built on them;
; nothing else spells a prefix or a folder formula.
;
; Functions rather than global initialisers so include ORDER cannot matter:
; boot reads them before the logger include has run its own top level.
; ==============================================================================

; Folder named after the application on Windows (and macOS).
AppDirsFolderName() {
	return "Ergopti"
}

; Protected managed Windows runtime folder inside the Ergopti root.
AppDirsWindowsManagedOllamaFolderName() {
	return "ollama"
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

; Pre-configuration log, always in the default logs folder.
AppDirsLogBootstrapName() {
	return "bootstrap.log"
}

; Environment variable holding the default logs root.
AppDirsWindowsLogsBaseEnv() {
	return "LOCALAPPDATA"
}

; Default logs folder, relative to that root.
AppDirsWindowsLogsRelative() {
	return "Ergopti\logs"
}

; Environment variable holding the Ergopti root.
AppDirsWindowsSupportBaseEnv() {
	return "LOCALAPPDATA"
}

; The Ergopti root, relative to that variable.
AppDirsWindowsSupportRelative() {
	return "Ergopti"
}

; Environment variable holding the default configuration folder.
AppDirsWindowsConfigBaseEnv() {
	return "LOCALAPPDATA"
}

; Default configuration folder, relative to that variable.
AppDirsWindowsConfigRelative() {
	return "Ergopti\config"
}

; The installed paths.toml, relative to the configuration variable.
AppDirsWindowsPathsFileRelative() {
	return "Ergopti\paths.toml"
}

; Environment variable holding the cache folder.
AppDirsWindowsCacheBaseEnv() {
	return "LOCALAPPDATA"
}

; Cache folder, relative to that variable.
AppDirsWindowsCacheRelative() {
	return "Ergopti\cache"
}

; Suffix of the copy the legacy folder migration keeps of a rewritten paths.toml.
AppDirsMigrationBackupSuffix() {
	return ".before-folder-migration"
}

; Folder of the root that receives an old entry whose destination is taken.
AppDirsMigrationBackupFolder() {
	return "before-folder-migration"
}

; Environment variable holding the paths.toml of the builds before the single folder.
AppDirsMigrationWindowsLegacyPathsFileBaseEnv() {
	return "APPDATA"
}

; That legacy paths.toml, relative to its variable.
AppDirsMigrationWindowsLegacyPathsFileRelative() {
	return "Ergopti\paths.toml"
}

; Environment variable holding the legacy default configuration folder.
AppDirsMigrationWindowsLegacyConfigBaseEnv() {
	return "USERPROFILE"
}

; That legacy configuration folder, relative to its variable.
AppDirsMigrationWindowsLegacyConfigRelative() {
	return ".config\ergopti_plus"
}

; Legacy LocalApplicationData folder whose entries move into the root.
AppDirsMigrationWindowsLegacyLocalFolder() {
	return "ergopti_plus"
}

; Legacy managed Ollama folders, LocalApplicationData children moved in order
; into the managed runtime folder.
AppDirsMigrationWindowsLegacyOllamaFolders() {
	return ["ergopti_plus_ollama", "Ergopti-ollama"]
}
