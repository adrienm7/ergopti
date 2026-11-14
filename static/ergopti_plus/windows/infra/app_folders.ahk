; infra/app_folders.ahk

; ==============================================================================
; MODULE: Application Folders (Windows)
; DESCRIPTION:
; The one resolver of the Ergopti root (%LOCALAPPDATA%\Ergopti) and of its
; purpose folders, built on the generated _generated/app_dirs.ahk. The logs
; folder keeps its own resolver in core/logger/engine/logger.ahk (LoggerDefaultLogsDir),
; which reads the same generated data.
;
; FEATURES & RATIONALE:
; 1. One Root: paths.toml, the configuration, the cache, the updater state and
;    the bundle and the managed Ollama runtime all live under one folder; the
;    runtime folder keeps its own protected ACL (app_dirs.toml
;    [runtime.windows], modules/llm/ollama_managed_files.ps1).
; 2. Fail Fast: an empty base variable raises instead of resolving a folder
;    relative to the working directory.
; 3. Functions, not globals: boot reads them before most includes have run.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================
; ===========================
; ======= 1/ Resolver =======
; ===========================
; ===========================

; The folder an environment variable of app_dirs.toml names. Read directly,
; as LoggerDefaultLogsDir reads the logs root, so this file depends on the
; generated data only and every test runner can include it.
; @param BaseEnv {String} Environment variable name.
; @returns {String} Absolute folder without a trailing backslash.
AppFoldersBase(BaseEnv) {
		Root := EnvGet(BaseEnv)
		if (Root == "")
				throw Error("%" . BaseEnv . "% is empty: the Ergopti folders cannot be resolved.")
		return RTrim(Root, "\/")
}

; The Ergopti root, %LOCALAPPDATA%\Ergopti\.
; @returns {String} Absolute folder with a trailing backslash.
AppFoldersRoot() {
		return AppFoldersBase(AppDirsWindowsSupportBaseEnv()) . "\" . AppDirsWindowsSupportRelative() . "\"
}

; The default configuration folder, %LOCALAPPDATA%\Ergopti\config\.
; @returns {String} Absolute folder with a trailing backslash.
AppFoldersDefaultConfigDir() {
		return AppFoldersBase(AppDirsWindowsConfigBaseEnv()) . "\" . AppDirsWindowsConfigRelative() . "\"
}

; The installed paths.toml, %LOCALAPPDATA%\Ergopti\paths.toml.
; @returns {String} Absolute file path.
AppFoldersPathsFile() {
		return AppFoldersBase(AppDirsWindowsConfigBaseEnv()) . "\" . AppDirsWindowsPathsFileRelative()
}

; The cache folder, %LOCALAPPDATA%\Ergopti\cache\.
; @returns {String} Absolute folder with a trailing backslash.
AppFoldersCacheDir() {
		return AppFoldersBase(AppDirsWindowsCacheBaseEnv()) . "\" . AppDirsWindowsCacheRelative() . "\"
}

; The protected managed Ollama root, %LOCALAPPDATA%\Ergopti\ollama.
; @returns {String} Absolute folder without a trailing backslash.
AppFoldersManagedOllamaRoot() {
		return AppFoldersRoot() . AppDirsWindowsManagedOllamaFolderName()
}
