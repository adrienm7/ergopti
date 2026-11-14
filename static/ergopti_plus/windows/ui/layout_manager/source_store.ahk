; ui/layout_manager/source_store.ahk

; ==============================================================================
; MODULE: Layout Source Store (Windows)
; DESCRIPTION:
; Keeps the files the unified layout editor saves from the layout manager
; window: the Ergopti layout source (TOML) and the exports the page produced
; from it (.keylayout, layers.toml), in one folder of the configuration folder.
; The Windows twin of _shared/layouts/engine/composer/source_store.lua (macOS and Linux):
; the same bounds, codes and last-source pointer, replayed by the same cases.
;
; FEATURES & RATIONALE:
; 1. No path from the page: a file name is one plain lowercase name of an
;    allowed extension, so the page cannot write outside the store's folder.
; 2. Fail fast: a refused or failed write reports a stable code and detail;
;    nothing is truncated or rewritten silently.
; 3. Saving never installs or activates anything: installing a generated
;    layout stays the composer's job (composer.ahk).
; 4. Every file operation is a port, so the tests replay the store over an
;    in-memory disk.
; 5. The downloads the page builds (XKB archive, KLC, DLL images, macOS bundle)
;    are bytes, sent as base64: SourceStore_Export writes them to the user's
;    Downloads folder under the name the page chose, or « name (2).ext » and so
;    on when it is taken, so nothing there is ever replaced.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; A plain lowercase name ending in one of the editor's file types.
global SOURCE_STORE_FILE_NAME := "^[a-z][a-z0-9_]*\.[a-z]+$"
global SOURCE_STORE_EXTENSIONS := Map("toml", true, "keylayout", true)
; A download's plain name: no folder, no leading dot.
global SOURCE_STORE_EXPORT_NAME := "^[A-Za-z0-9][A-Za-z0-9_.-]*\.([a-z]+)$"
; How many « name (n).ext » a download tries before it is refused.
global SOURCE_STORE_MAX_EXPORT_SUFFIX := 99





; ===========================
; ===========================
; ======= 2/ Settings =======
; ===========================
; ===========================

/**
 * Validates the [source] table of the shared layout defaults.
 * @param {Map} LayoutDefaults - Decoded _shared/layouts/data/defaults.json.
 * @returns {Map} folder, last_file, max_file_bytes, max_name_length, nav_file (the navigation export,
 *   never reopened as a source), export_extensions (a set of the downloads' file types) and
 *   failures (the codes of source_store.lua: invalid, write).
 * @throws {Error} When the table is missing or one of its fields is not valid.
 */
SourceStore_Settings(LayoutDefaults) {
	Source := (LayoutDefaults is Map) ? LayoutDefaults.Get("source", 0) : 0
	if !(Source is Map)
		throw Error("The layout defaults have no source table.")
	for Field in ["folder", "last_file", "nav_file"]
		if !(Source.Get(Field, 0) is String) || !RegExMatch(Source[Field], "^[A-Za-z0-9._-]+$")
			throw Error("The source " . Field . " is not a plain name.")
	for Field in ["max_file_bytes", "max_name_length"]
		if !(Source.Get(Field, 0) is Integer) || Source[Field] <= 0
			throw Error("The source " . Field . " is not a positive integer.")
	Extensions := Map()
	if !(Source.Get("export_extensions", 0) is Array) || Source["export_extensions"].Length == 0
		throw Error("The source export_extensions is not a list of extensions.")
	for Extension in Source["export_extensions"] {
		if !(Extension is String) || !RegExMatch(Extension, "^[a-z]+$")
			throw Error("The source export_extensions holds a value that is not a lowercase extension.")
		Extensions[Extension] := true
	}
	Failures := Source.Get("failures", 0)
	for Code in ["invalid", "write"]
		if !(Failures is Map) || !(Failures.Get(Code, 0) is String) || !RegExMatch(Failures[Code], "^[a-z_]+$")
			throw Error("The source failures name no " . Code . " code.")
	return Map("folder", Source["folder"], "last_file", Source["last_file"],
		"max_file_bytes", Source["max_file_bytes"], "max_name_length", Source["max_name_length"],
		"nav_file", Source["nav_file"], "export_extensions", Extensions, "failures", Map("invalid", Failures["invalid"], "write", Failures["write"]))
}

/**
 * The store's settings from the shipped layout defaults, read once.
 * @returns {Map}
 */
SourceStore_SharedSettings() {
	static Settings := 0
	if !(Settings is Map)
		Settings := SourceStore_Settings(_LayoutRegistryReadJson("layouts\data\defaults.json"))
	return Settings
}





; ===========================
; ===========================
; ======= 3/ Checking =======
; ===========================
; ===========================

/**
 * Whether bytes are well-formed UTF-8 (no overlong form, surrogate or value past U+10FFFF).
 * @param {Buffer} Bytes
 * @param {Integer} Length - Bytes to read; the whole buffer by default.
 * @returns {Boolean}
 */
SourceStore_IsUtf8(Bytes, Length := -1) {
	N := Length < 0 ? Bytes.Size : Length
	I := 0
	while I < N {
		C := NumGet(Bytes, I, "UChar")
		Low := 0x80, High := 0xBF
		if C < 0x80
			Size := 1
		else if C >= 0xC2 && C <= 0xDF
			Size := 2
		else if C == 0xE0
			Size := 3, Low := 0xA0
		else if C == 0xED
			Size := 3, High := 0x9F
		else if C >= 0xE1 && C <= 0xEF
			Size := 3
		else if C == 0xF0
			Size := 4, Low := 0x90
		else if C >= 0xF1 && C <= 0xF3
			Size := 4
		else if C == 0xF4
			Size := 4, High := 0x8F
		else
			return false
		loop Size - 1 {
			if I + A_Index >= N
				return false
			B := NumGet(Bytes, I + A_Index, "UChar")
			if B < (A_Index == 1 ? Low : 0x80) || B > (A_Index == 1 ? High : 0xBF)
				return false
		}
		I += Size
	}
	return true
}

/**
 * Whether a page string encodes to UTF-8 unchanged: an unpaired surrogate is
 * the only text a decoded JSON string can hold that UTF-8 cannot.
 * @param {String} Text
 * @returns {Boolean}
 */
SourceStore_TextIsUtf8(Text) {
	Bytes := Buffer(StrPut(Text, "UTF-8"))
	StrPut(Text, Bytes, "UTF-8")
	return StrGet(Bytes, "UTF-8") == Text
}

/**
 * Checks one file the page wants to save.
 * @param {Map} Settings - From SourceStore_Settings.
 * @param {Any} Payload - The page message: filename and text.
 * @returns {String} Why the file is refused, "" when it is accepted.
 */
SourceStore_Check(Settings, Payload) {
	global SOURCE_STORE_FILE_NAME, SOURCE_STORE_EXTENSIONS
	if !(Payload is Map)
		return "the save request is not a table"
	Name := Payload.Get("filename", 0), Text := Payload.Get("text", 0)
	if !(Name is String) || StrLen(Name) > Settings["max_name_length"]
			|| !RegExMatch(Name, SOURCE_STORE_FILE_NAME)
		return "the file name is not a plain lowercase name"
	RegExMatch(Name, "\.([a-z]+)$", &Extension)
	if !SOURCE_STORE_EXTENSIONS.Has(Extension[1])
		return "the file type is not one the editor saves"
	if !(Text is String) || Text == ""
		return "the file is empty"
	if StrPut(Text, "UTF-8") - 1 > Settings["max_file_bytes"]
		return "the file is larger than its bound"
	if !SourceStore_TextIsUtf8(Text)
		return "the file is not UTF-8 text"
	return ""
}

/**
 * Checks one download the page wants written and decodes its bytes.
 * @param {Map} Settings - From SourceStore_Settings.
 * @param {Any} Payload - The page message: filename and data (the bytes as base64).
 * @param {&Buffer} Bytes - The decoded bytes when the download is accepted.
 * @returns {String} Why the download is refused, "" when it is accepted.
 */
SourceStore_CheckExport(Settings, Payload, &Bytes) {
	global SOURCE_STORE_EXPORT_NAME
	Bytes := 0
	if !(Payload is Map)
		return "the download request is not a table"
	Name := Payload.Get("filename", 0), Data := Payload.Get("data", 0)
	if !(Name is String) || StrLen(Name) > Settings["max_name_length"]
			|| !RegExMatch(Name, SOURCE_STORE_EXPORT_NAME, &Extension) || InStr(Name, "..")
		return "the download name is not a plain file name"
	; RegExMatch is case-insensitive only with i); the pattern and the set are lowercase.
	if !Settings["export_extensions"].Has(Extension[1])
		return "the download type is not one the editor writes"
	; Bounded before decoding: base64 carries three bytes in four characters.
	if !(Data is String) || Data == "" || StrLen(Data) > Ceil(Settings["max_file_bytes"] / 3) * 4
		return "the download is empty or larger than its bound"
	; The canonical padded alphabet only, as the Lua store decodes it: Crypt32 also skips whitespace.
	if Mod(StrLen(Data), 4) != 0 || !RegExMatch(Data, "^[A-Za-z0-9+/]+={0,2}$")
		return "the download is not base64"
	Decoded := CryptoBase64Decode(Data)
	if Decoded.Size == 0
		return "the download is not base64"
	if Decoded.Size > Settings["max_file_bytes"]
		return "the download is larger than its bound"
	Bytes := Decoded
	return ""
}

/**
 * The first free path of a download in a folder: the name itself, then
 * « stem (2).ext » up to SOURCE_STORE_MAX_EXPORT_SUFFIX.
 * @param {String} Folder - With its trailing backslash.
 * @param {String} Name - A name SourceStore_CheckExport accepted.
 * @param {Func} Exists - Exists(Path) -> Boolean.
 * @returns {String} The path, "" when every name is taken.
 */
SourceStore_FreeExportPath(Folder, Name, Exists) {
	global SOURCE_STORE_MAX_EXPORT_SUFFIX
	if !Exists.Call(Folder . Name)
		return Folder . Name
	RegExMatch(Name, "^(.*)(\.[a-z]+)$", &Parts)
	loop SOURCE_STORE_MAX_EXPORT_SUFFIX - 1 {
		Candidate := Folder . Parts[1] . " (" . (A_Index + 1) . ")" . Parts[2]
		if !Exists.Call(Candidate)
			return Candidate
	}
	return ""
}

/**
 * Whether a saved file is a layout source the editor reopens.
 * @param {String} Name
 * @returns {Boolean}
 */
SourceStore_IsSource(Name, Settings := unset) {
	if !IsSet(Settings)
		Settings := SourceStore_SharedSettings()
	return Name != Settings["nav_file"] && RegExMatch(Name, "\.toml$") > 0
}





; =============================
; =============================
; ======= 4/ Operations =======
; =============================
; =============================

/**
 * The store's folder inside the configuration folder.
 * @param {Map} Settings - From SourceStore_Settings.
 * @param {String} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {String} Folder with a trailing backslash.
 */
SourceStore_Folder(Settings, ConfigDir) => ConfigDir . Settings["folder"] . "\"

; The production disk: atomic writes that create the folder, and an exact
; bounded UTF-8 read that refuses malformed bytes.
_SourceStore_DiskPorts() {
	return Map(
		"exists", (Path) => FileExist(Path) != "" && !InStr(FileExist(Path), "D"),
		"read", (Path, MaxBytes) => FSReadUtf8ExactBounded(Path, MaxBytes),
		"write", _SourceStore_Write
	)
}

; The production ports of a download: the Downloads known folder, which is
; never created, and a raw byte write.
_SourceStore_ExportPorts(Ports) {
	Defaults := Map(
		"downloads_dir", () => GetKnownFolderDownloads(),
		"dir_exists", (Path) => InStr(FileExist(Path), "D") > 0,
		"exists", (Path) => FileExist(Path) != "",
		"write_bytes", _SourceStore_WriteBytes
	)
	if Ports is Map
		for Name, Port in Ports
			Defaults[Name] := Port
	return Defaults
}

_SourceStore_WriteBytes(Path, Bytes) {
	Handle := FileOpen(Path, "w")
	if !Handle
		throw OSError(A_LastError, -1, "FileOpen " . Path)
	try {
		if Handle.RawWrite(Bytes, Bytes.Size) != Bytes.Size
			throw Error("Short write to " . Path)
	} finally Handle.Close()
}

_SourceStore_Write(Path, Text) {
	SplitPath(Path, , &Parent)
	DirCreate(Parent)
	_LayoutCatalogueWriteText(Path, Text)
}

_SourceStore_Ports(Ports) {
	Defaults := _SourceStore_DiskPorts()
	if Ports is Map
		for Name, Port in Ports
			Defaults[Name] := Port
	return Defaults
}

/**
 * The last saved source, for the page's sourceData.
 * @param {Map} Settings - From SourceStore_Settings.
 * @param {String} ConfigDir - Configuration folder, with its trailing backslash.
 * @param {Map} Ports - "exists", "read" (Path, MaxBytes) and "write"; the disk by default.
 * @returns {Map} folder, and text and filename when a source can be reopened.
 */
SourceStore_Open(Settings, ConfigDir, Ports := 0) {
	Ports := _SourceStore_Ports(Ports)
	Folder := SourceStore_Folder(Settings, ConfigDir)
	Data := Map("folder", Folder)
	Pointer := Folder . Settings["last_file"]
	if !Ports["exists"].Call(Pointer)
		return Data
	Name := Ports["read"].Call(Pointer, Settings["max_name_length"] + 2)
	Name := (Name is String) ? RTrim(Name, " `t`r`n") : ""
	Text := false
	if Name != "" && SourceStore_Check(Settings, Map("filename", Name, "text", "x")) == ""
			&& SourceStore_IsSource(Name, Settings) && Ports["exists"].Call(Folder . Name)
		Text := Ports["read"].Call(Folder . Name, Settings["max_file_bytes"])
	if Text is String {
		Data["text"] := Text
		Data["filename"] := Name
	} else {
		LoggerError("LayoutSource", "The last layout source named by {1} is unreadable.", Pointer)
	}
	return Data
}

/**
 * Stores one file of the editor.
 * @param {Map} Settings - From SourceStore_Settings.
 * @param {String} ConfigDir - Configuration folder, with its trailing backslash.
 * @param {Map} Payload - filename and text.
 * @param {Map} Ports - As SourceStore_Open.
 * @returns {Map} ok, code, detail and filename, the page's sourceResult.
 */
SourceStore_Save(Settings, ConfigDir, Payload, Ports := 0) {
	Ports := _SourceStore_Ports(Ports)
	Refusal := SourceStore_Check(Settings, Payload)
	if Refusal != "" {
		LoggerWarn("LayoutSource", "Refused a layout editor file: {1}.", Refusal)
		return Map("ok", false, "code", Settings["failures"]["invalid"], "detail", Refusal, "filename", "")
	}
	Name := Payload["filename"]
	Folder := SourceStore_Folder(Settings, ConfigDir)
	Path := Folder . Name
	try Ports["write"].Call(Path, Payload["text"])
	catch as Err {
		LoggerError("LayoutSource", "The layout editor file {1} could not be written: {2}.", Path, Err.Message)
		return Map("ok", false, "code", Settings["failures"]["write"], "detail", Err.Message, "filename", Name)
	}
	if SourceStore_IsSource(Name, Settings) {
		try Ports["write"].Call(Folder . Settings["last_file"], Name . "`n")
		catch as Err {
			LoggerError("LayoutSource", "The last layout source could not be recorded: {1}.", Err.Message)
			return Map("ok", false, "code", Settings["failures"]["write"], "detail", Err.Message, "filename", Name)
		}
	}
	LoggerInfo("LayoutSource", "Layout editor file saved: {1}.", Path)
	return Map("ok", true, "code", "", "detail", Path, "filename", Name)
}

/**
 * Writes one download of the editor to the user's Downloads folder, never over
 * a file there (the Windows twin of source_store.lua's export).
 * @param {Map} Settings - From SourceStore_Settings.
 * @param {Map} Payload - filename and data (the bytes as base64).
 * @param {Map} Ports - "downloads_dir", "dir_exists", "exists" and "write_bytes"; the disk by default.
 * @returns {Map} ok, code, detail and path, the page's exportResult.
 */
SourceStore_Export(Settings, Payload, Ports := 0) {
	Ports := _SourceStore_ExportPorts(Ports)
	Refusal := SourceStore_CheckExport(Settings, Payload, &Bytes)
	if Refusal != "" {
		LoggerWarn("LayoutSource", "Refused a layout editor download: {1}.", Refusal)
		return Map("ok", false, "code", Settings["failures"]["invalid"], "detail", Refusal, "path", "")
	}
	try Downloads := Ports["downloads_dir"].Call()
	catch as Err {
		LoggerError("LayoutSource", "The layout editor download has no destination: {1}.", Err.Message)
		return Map("ok", false, "code", Settings["failures"]["write"], "detail", Err.Message, "path", "")
	}
	if !Ports["dir_exists"].Call(Downloads) {
		Detail := Downloads . " does not exist"
		LoggerError("LayoutSource", "The layout editor download has no destination: {1}.", Detail)
		return Map("ok", false, "code", Settings["failures"]["write"], "detail", Detail, "path", "")
	}
	Path := SourceStore_FreeExportPath(RTrim(Downloads, "\") . "\", Payload["filename"], Ports["exists"])
	if Path == "" {
		Detail := "every name for " . Payload["filename"] . " is taken in " . Downloads
		LoggerError("LayoutSource", "The layout editor download was not written: {1}.", Detail)
		return Map("ok", false, "code", Settings["failures"]["write"], "detail", Detail, "path", "")
	}
	try Ports["write_bytes"].Call(Path, Bytes)
	catch as Err {
		LoggerError("LayoutSource", "The layout editor download {1} could not be written: {2}.", Path, Err.Message)
		return Map("ok", false, "code", Settings["failures"]["write"], "detail", Err.Message, "path", "")
	}
	LoggerInfo("LayoutSource", "Layout editor download written: {1}.", Path)
	return Map("ok", true, "code", "", "detail", "", "path", Path)
}
