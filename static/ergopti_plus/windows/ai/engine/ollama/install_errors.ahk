; ai/engine/ollama/install_errors.ahk

; ==============================================================================
; MODULE: Managed Ollama Install Error Classes (Windows)
; DESCRIPTION:
; Names why a managed Ollama runtime install failed, from the evidence line its
; PowerShell helpers return (ollama_managed_files.ps1 Get-OllamaFailureEvidence),
; with the closed classes of _shared/ai/data/ollama_install_errors.json, and
; holds the free-space rule checked before the download. macOS and Linux apply
; the same file (_shared/ai/engine/ollama/install_errors.lua); the three suites
; replay _shared/tests/corpus/llm/ollama_install_error_vectors.json (OLL-04, OLL-05).
; ==============================================================================

#Requires AutoHotkey v2.0

; The class an install failure shows when no row of the data file matches.
global LLM_OLLAMA_INSTALL_ERROR_UNKNOWN := "unknown"
; Largest data file read: a few dozen rows.
global LLM_OLLAMA_INSTALL_ERRORS_MAX_BYTES := 65536

/**
 * The decoded data file, read once; a malformed one is a broken install.
 * @param {String} Path The data file, "" for the shared one.
 * @returns {Map} { messages, classes } admitted.
 */
LLM_OllamaInstallErrors(Path := "") {
	global _SharedDir, LLM_OLLAMA_INSTALL_ERROR_UNKNOWN, LLM_OLLAMA_INSTALL_ERRORS_MAX_BYTES
	static Loaded := 0
	if Path == "" && IsObject(Loaded)
		return Loaded
	Source := Path == "" ? _SharedDir . "\ai\data\ollama_install_errors.json" : Path
	Data := JsonParse(FSReadUtf8ExactBounded(Source, LLM_OLLAMA_INSTALL_ERRORS_MAX_BYTES))
	if !(Data is Map) || Data.Get("schema_version", 0) != 1 || !(Data.Get("messages", 0) is Map)
			|| !(Data.Get("classes", 0) is Array) || Data["classes"].Length == 0
		throw ValueError("ollama_install_errors.json is malformed.")
	Messages := Data["messages"]
	if !Messages.Has(LLM_OLLAMA_INSTALL_ERROR_UNKNOWN)
		throw ValueError("ollama_install_errors.json names no message for its unknown class.")
	for Class, Key in Messages {
		if !(Key is String) || !RegExMatch(Key, "^ollama\.install_error\.[a-z_]+$")
			throw ValueError("ollama_install_errors.json message of " . Class . " is malformed.")
	}
	for Index, Row in Data["classes"] {
		if !(Row is Array) || Row.Length != 2 || !(Row[1] is String) || Row[1] == ""
				|| !(Row[1] == StrLower(Row[1])) || !(Row[2] is String) || !Messages.Has(Row[2])
			throw ValueError("ollama_install_errors.json class row " . Index . " is malformed.")
	}
	if Path == ""
		Loaded := Data
	return Data
}

/**
 * The class of one install failure, first matching row wins.
 * @param {String} Evidence The helper's evidence line.
 * @param {Map} Data Optional decoded data file.
 * @returns {String} A class of the data file, "unknown" when no row matches.
 */
LLM_OllamaInstallErrorClass(Evidence, Data := 0) {
	global LLM_OLLAMA_INSTALL_ERROR_UNKNOWN
	if !(Evidence is String)
		throw TypeError("Install failure evidence must be a string.")
	Rows := (IsObject(Data) ? Data : LLM_OllamaInstallErrors())["classes"]
	Lowered := StrLower(Evidence)
	for Row in Rows {
		if InStr(Lowered, Row[1], true)
			return Row[2]
	}
	return LLM_OLLAMA_INSTALL_ERROR_UNKNOWN
}

/**
 * The locale key a class shows.
 * @param {String} Class A class LLM_OllamaInstallErrorClass returned.
 * @returns {String}
 */
LLM_OllamaInstallErrorKey(Class) {
	Messages := LLM_OllamaInstallErrors()["messages"]
	if !Messages.Has(Class)
		throw ValueError("Unknown Ollama install error class.", -1, Class)
	return Messages[Class]
}

/**
 * Whether the pinned archive may start downloading: its bytes and the registry
 * margin must be free on the install volume.
 * @param {Integer} AssetBytes Pinned archive size.
 * @param {Integer} MarginBytes [limits] ollama_install_free_space_margin_bytes.
 * @param {Integer} FreeBytes Bytes free for the user on the install volume.
 * @returns {Boolean}
 */
LLM_OllamaInstallFits(AssetBytes, MarginBytes, FreeBytes) {
	for Value in [AssetBytes, MarginBytes, FreeBytes] {
		if !(Value is Integer) || Value < 0
			throw ValueError("Free-space inputs must be non-negative integers.")
	}
	return FreeBytes >= AssetBytes + MarginBytes
}

/**
 * The bytes free for the user on the volume that will hold Path, read from its
 * nearest existing folder: the managed root may not exist before the install.
 * @param {String} Path Absolute managed root.
 * @returns {Integer}
 */
LLM_OllamaInstallFreeBytes(Path) {
	if !(Path is String) || !RegExMatch(Path, "^[A-Za-z]:\\")
		throw ValueError("Free space needs an absolute local path.")
	Current := RTrim(Path, "\")
	while !InStr(FileExist(Current), "D") {
		SplitPath(Current, , &Parent)
		if Parent == "" || Parent == Current
			throw OSError("No existing folder holds the managed root.")
		Current := Parent
	}
	Free := Buffer(8, 0)
	if !DllCall("Kernel32\GetDiskFreeSpaceExW", "Str", Current . "\", "Ptr", Free.Ptr, "Ptr", 0, "Ptr", 0, "Int")
		throw OSError(A_LastError, -1, "GetDiskFreeSpaceExW")
	return NumGet(Free, 0, "Int64")
}
