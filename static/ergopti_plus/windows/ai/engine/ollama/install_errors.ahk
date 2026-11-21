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

/**
 * The decoded data file, read once; a malformed one is a broken install.
 * @param {String} Path The data file, "" for the shared one.
 * @returns {Map} { messages, classes } admitted.
 */
LLM_OllamaInstallErrors(Path := "") {
	global _SharedDir
	static Loaded := 0
	if Path == "" && IsObject(Loaded)
		return Loaded
	Source := Path == "" ? _SharedDir . "\ai\data\ollama_install_errors.json" : Path
	Data := JsonParse(FSReadUtf8ExactBounded(Source, TimingsGet("limits", "ollama_install_errors_file_bytes")))
	if !(Data is Map) || Data.Get("schema_version", 0) != 1 || !(Data.Get("messages", 0) is Map)
			|| !(Data.Get("classes", 0) is Array) || Data["classes"].Length == 0
		throw ValueError("ollama_install_errors.json is malformed.")
	Messages := Data["messages"]
	; The class an install failure shows when no row matches.
	if !(Data.Get("unmatched", 0) is String) || !Messages.Has(Data["unmatched"])
		throw ValueError("ollama_install_errors.json names no message for its unmatched class.")
	for Class, Key in Messages {
		if !(Key is String) || !RegExMatch(Key, "^ollama\.install_error\.[a-z_]+$")
			throw ValueError("ollama_install_errors.json message of " . Class . " is malformed.")
	}
	; A full disk is one cause whether the runtime or a model fills it (OLL-14).
	if !(Data.Get("pull", 0) is Map) || !(Data.Get("pull_messages", 0) is Map)
		throw ValueError("ollama_install_errors.json names no pull classes.")
	for Class, Key in Data["pull_messages"] {
		if !Messages.Has(Class) || !(Key is String) || !RegExMatch(Key, "^ollama\.pull_error\.[a-z_]+$")
			throw ValueError("ollama_install_errors.json pull message of " . Class . " is malformed.")
	}
	for PullClass, Class in Data["pull"] {
		if PullClass == "" || !(Class is String) || !Data["pull_messages"].Has(Class)
			throw ValueError("ollama_install_errors.json pull class " . PullClass . " is malformed.")
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
 * @returns {String} A class of the data file, the unmatched one when no row matches.
 */
LLM_OllamaInstallErrorClass(Evidence, Data := 0) {
	if !(Evidence is String)
		throw TypeError("Install failure evidence must be a string.")
	Data := IsObject(Data) ? Data : LLM_OllamaInstallErrors()
	Rows := Data["classes"]
	Lowered := StrLower(Evidence)
	for Row in Rows {
		if InStr(Lowered, Row[1], true)
			return Row[2]
	}
	return Data["unmatched"]
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
 * The install class of a failed model pull whose pull class is one too (a full
 * disk, OLL-14); any other pull keeps its generic failure.
 * @param {String} PullClass A class of ollama_pull_errors.json, "" for none.
 * @param {Map} Data Optional decoded data file.
 * @returns {String} The install class, "" when the pull class is none.
 */
LLM_OllamaPullInstallClass(PullClass, Data := 0) {
	if !(PullClass is String)
		throw TypeError("A pull class must be a string.")
	Pulls := (IsObject(Data) ? Data : LLM_OllamaInstallErrors())["pull"]
	return Pulls.Has(PullClass) ? Pulls[PullClass] : ""
}

/**
 * The locale key a failed pull of an install class shows; its %s is the model.
 * @param {String} Class A class LLM_OllamaPullInstallClass returned.
 * @returns {String}
 */
LLM_OllamaPullInstallKey(Class) {
	Messages := LLM_OllamaInstallErrors()["pull_messages"]
	if !Messages.Has(Class)
		throw ValueError("No pull message for this Ollama install error class.", -1, Class)
	return Messages[Class]
}

/**
 * Whether the pinned archive may start downloading: the archive, the runtime it
 * unpacks to and the registry margin must be free on the install volume, since
 * the archive stays until its extraction ends (OLL-14).
 * @param {Integer} AssetBytes Pinned archive size.
 * @param {Integer} UnpackedBytes Pinned unpacked runtime size.
 * @param {Integer} MarginBytes [limits] ollama_install_free_space_margin_bytes.
 * @param {Integer} FreeBytes Bytes free for the user on the install volume.
 * @returns {Boolean}
 */
LLM_OllamaInstallFits(AssetBytes, UnpackedBytes, MarginBytes, FreeBytes) {
	for Value in [AssetBytes, UnpackedBytes, MarginBytes, FreeBytes] {
		if !(Value is Integer) || Value < 0
			throw ValueError("Free-space inputs must be non-negative integers.")
	}
	return FreeBytes >= AssetBytes + UnpackedBytes + MarginBytes
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
