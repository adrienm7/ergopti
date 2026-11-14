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
; 6. Ergopti Studio's personal layouts (StudioStore_*): the Windows twin of
;    _shared/layouts/engine/composer/studio_store.lua, one JSON file of the same
;    folder mapping each id to the page's JSON text, stored as given; an
;    unreadable store refuses every operation and is never replaced.
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





; ===========================
; ===========================
; ======= 2/ Settings =======
; ===========================
; ===========================

/**
 * Validates the [source] table of the shared layout defaults.
 * @param {Map} LayoutDefaults - Decoded _shared/layouts/data/defaults.json.
 * @returns {Map} folder, last_file, max_file_bytes, max_name_length, nav_file (the navigation export,
 *   never reopened as a source), export_extensions (a set of the downloads' file types),
 *   max_export_suffix (the last « name (n).ext » a download tries) and
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
	for Field in ["max_file_bytes", "max_name_length", "max_export_suffix"]
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
		"nav_file", Source["nav_file"], "export_extensions", Extensions,
		"max_export_suffix", Source["max_export_suffix"], "failures", Map("invalid", Failures["invalid"], "write", Failures["write"]))
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
 * « stem (2).ext » up to MaxSuffix.
 * @param {String} Folder - With its trailing backslash.
 * @param {String} Name - A name SourceStore_CheckExport accepted.
 * @param {Func} Exists - Exists(Path) -> Boolean.
 * @param {Integer} MaxSuffix - The settings' max_export_suffix.
 * @returns {String} The path, "" when every name is taken.
 */
SourceStore_FreeExportPath(Folder, Name, Exists, MaxSuffix) {
	if !Exists.Call(Folder . Name)
		return Folder . Name
	RegExMatch(Name, "^(.*)(\.[a-z]+)$", &Parts)
	loop MaxSuffix - 1 {
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
; never created, and the adapter's raw byte write.
_SourceStore_ExportPorts(Ports) {
	Defaults := Map(
		"downloads_dir", () => GetKnownFolderDownloads(),
		"dir_exists", (Path) => InStr(FileExist(Path), "D") > 0,
		"exists", FSExists,
		"write_bytes", FSWriteBytesStrict
	)
	if Ports is Map
		for Name, Port in Ports
			Defaults[Name] := Port
	return Defaults
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
	Path := SourceStore_FreeExportPath(RTrim(Downloads, "\") . "\", Payload["filename"], Ports["exists"],
		Settings["max_export_suffix"])
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





; ==========================================
; ==========================================
; ======= 5/ Ergopti Studio layouts ========
; ==========================================
; ==========================================

/**
 * Validates the studio table of the shared layout defaults.
 * @param {Map} LayoutDefaults - Decoded _shared/layouts/data/defaults.json.
 * @returns {Map} folder, file, id_pattern, id_max_length, max_layouts,
 *   max_layout_bytes, corpus_folder, corpus_prefix, corpus_id_pattern,
 *   max_corpus_bytes and failures (invalid, write, unreadable, corpus).
 * @throws {Error} When the table is missing or one of its fields is not valid.
 */
StudioStore_Settings(LayoutDefaults) {
	Source := (LayoutDefaults is Map) ? LayoutDefaults.Get("source", 0) : 0
	Studio := (LayoutDefaults is Map) ? LayoutDefaults.Get("studio", 0) : 0
	if !(Source is Map) || !(Studio is Map)
		throw Error("The layout defaults have no source or studio table.")
	for Value in [Source.Get("folder", 0), Studio.Get("file", 0)]
		if !(Value is String) || !RegExMatch(Value, "^[A-Za-z0-9._-]+$")
			throw Error("The studio folder or file is not a plain name.")
	for Field in ["id_pattern", "corpus_id_pattern"] {
		Pattern := Studio.Get(Field, 0)
		if !(Pattern is String) || SubStr(Pattern, 1, 1) != "^" || SubStr(Pattern, -1) != "$"
			throw Error("The studio " . Field . " is not an anchored pattern.")
	}
	Folder := Studio.Get("corpus_folder", 0)
	if !(Folder is String) || !RegExMatch(Folder, "^[a-z0-9_]+[a-z0-9_/]*[a-z0-9_]$") || InStr(Folder, "//")
		throw Error("The studio corpus_folder is not a plain relative folder.")
	if !(Studio.Get("corpus_prefix", 0) is String) || !RegExMatch(Studio["corpus_prefix"], "^[a-z0-9_]+$")
		throw Error("The studio corpus_prefix is not a plain name.")
	for Field in ["id_max_length", "max_layouts", "max_layout_bytes", "max_corpus_bytes"]
		if !(Studio.Get(Field, 0) is Integer) || Studio[Field] <= 0
			throw Error("The studio " . Field . " is not a positive integer.")
	Failures := Studio.Get("failures", 0)
	for Code in ["invalid", "write", "unreadable", "corpus"]
		if !(Failures is Map) || !(Failures.Get(Code, 0) is String) || !RegExMatch(Failures[Code], "^[a-z_]+$")
			throw Error("The studio failures name no " . Code . " code.")
	return Map("folder", Source["folder"], "file", Studio["file"], "id_pattern", Studio["id_pattern"],
		"id_max_length", Studio["id_max_length"], "max_layouts", Studio["max_layouts"],
		"max_layout_bytes", Studio["max_layout_bytes"], "corpus_folder", Folder,
		"corpus_prefix", Studio["corpus_prefix"], "corpus_id_pattern", Studio["corpus_id_pattern"],
		"max_corpus_bytes", Studio["max_corpus_bytes"],
		"failures", Map("invalid", Failures["invalid"], "write", Failures["write"], "unreadable", Failures["unreadable"],
			"corpus", Failures["corpus"]))
}

/**
 * The studio settings from the shipped layout defaults, read once.
 * @returns {Map}
 */
StudioStore_SharedSettings() {
	static Settings := 0
	if !(Settings is Map)
		Settings := StudioStore_Settings(_LayoutRegistryReadJson("layouts\data\defaults.json"))
	return Settings
}

/** Whether an id is one the store keeps. */
StudioStore_ValidId(Settings, Id) {
	return (Id is String) && StrLen(Id) <= Settings["id_max_length"] && RegExMatch(Id, Settings["id_pattern"]) > 0
}

/**
 * Checks one layout the page saves: its JSON text names the id it is saved under.
 * @returns {String} "" when it is accepted, else why it is refused.
 */
StudioStore_Check(Settings, Payload) {
	if !(Payload is Map)
		return "the save request is not a table"
	if !StudioStore_ValidId(Settings, Payload.Get("id", 0))
		return "the layout id is not a personal layout id"
	Text := Payload.Get("text", 0)
	if !(Text is String) || Text == ""
		return "the layout is empty"
	if StrPut(Text, "UTF-8") - 1 > Settings["max_layout_bytes"]
		return "the layout is larger than its bound"
	try Layout := JsonParse(Text)
	catch
		return "the layout is not a JSON object"
	if !(Layout is Map)
		return "the layout is not a JSON object"
	if !(Layout.Get("id", 0) is String) || Layout["id"] != Payload["id"]
		return "the layout names another id"
	return ""
}

StudioStore_Path(Settings, ConfigDir) => ConfigDir . Settings["folder"] . "\" . Settings["file"]

; The stored layouts (id -> JSON text), or the failure of an unreadable store.
; An absent store is an empty one.
_StudioStore_Load(Settings, ConfigDir, Ports, &Failure) {
	Failure := ""
	Path := StudioStore_Path(Settings, ConfigDir)
	if !Ports["exists"].Call(Path)
		return Map()
	Bound := Settings["max_layouts"] * (Settings["max_layout_bytes"] * 2 + Settings["id_max_length"] + 8) + 64
	Text := Ports["read"].Call(Path, Bound)
	if !(Text is String) {
		Failure := Path . " could not be read"
		return 0
	}
	try Data := JsonParse(Text)
	catch {
		Failure := Path . " is not a layout store"
		return 0
	}
	if !(Data is Map) || Data.Get("schema", 0) != 1 || !(Data.Get("layouts", 0) is Map) {
		Failure := Path . " is not a schema 1 layout store"
		return 0
	}
	Layouts := Map()
	for Id, LayoutText in Data["layouts"] {
		if !StudioStore_ValidId(Settings, Id) || !(LayoutText is String) {
			Failure := Path . " holds an entry that is not a personal layout"
			return 0
		}
		Layouts[Id] := LayoutText
	}
	if Layouts.Count > Settings["max_layouts"] {
		Failure := Path . " holds more layouts than its bound"
		return 0
	}
	return Layouts
}

; Writes the store file; "" or the write failure.
_StudioStore_Write(Settings, ConfigDir, Ports, Layouts) {
	try Ports["write"].Call(StudioStore_Path(Settings, ConfigDir),
		_LayMgrWeb_Json(Map("layouts", Layouts, "schema", 1)) . "`n")
	catch as Err
		return Err.Message
	return ""
}

/**
 * Every stored layout, sorted by id, for the page's studioLayouts.
 * @param {Map} Settings - From StudioStore_Settings.
 * @param {String} ConfigDir - Configuration folder, with its trailing backslash.
 * @param {Map} Ports - As SourceStore_Open.
 * @returns {Map} ok and layouts (JSON texts), or ok false, code and detail.
 */
StudioStore_List(Settings, ConfigDir, Ports := 0) {
	Ports := _SourceStore_Ports(Ports)
	Layouts := _StudioStore_Load(Settings, ConfigDir, Ports, &Failure)
	if !(Layouts is Map) {
		LoggerError("LayoutSource", "The Ergopti Studio layouts are unreadable: {1}.", Failure)
		return Map("ok", false, "code", Settings["failures"]["unreadable"], "detail", Failure)
	}
	Texts := []
	for Id, Text in Layouts
		Texts.Push(Text)
	return Map("ok", true, "layouts", Texts)
}

/**
 * Stores one layout, replacing the one with the same id.
 * @returns {Map} ok, code and detail, the page's studioLayoutResult.
 */
StudioStore_Save(Settings, ConfigDir, Payload, Ports := 0) {
	Ports := _SourceStore_Ports(Ports)
	Refusal := StudioStore_Check(Settings, Payload)
	if Refusal != "" {
		LoggerWarn("LayoutSource", "Refused an Ergopti Studio layout: {1}.", Refusal)
		return Map("ok", false, "code", Settings["failures"]["invalid"], "detail", Refusal)
	}
	Layouts := _StudioStore_Load(Settings, ConfigDir, Ports, &Failure)
	if !(Layouts is Map) {
		LoggerError("LayoutSource", "An Ergopti Studio layout was not saved over an unreadable store: {1}.", Failure)
		return Map("ok", false, "code", Settings["failures"]["unreadable"], "detail", Failure)
	}
	Others := Layouts.Count - (Layouts.Has(Payload["id"]) ? 1 : 0)
	if Others >= Settings["max_layouts"]
		return Map("ok", false, "code", Settings["failures"]["invalid"],
			"detail", "the store already holds its maximum number of layouts")
	Layouts[Payload["id"]] := Payload["text"]
	WriteFailure := _StudioStore_Write(Settings, ConfigDir, Ports, Layouts)
	if WriteFailure != "" {
		LoggerError("LayoutSource", "The Ergopti Studio layouts could not be written: {1}.", WriteFailure)
		return Map("ok", false, "code", Settings["failures"]["write"], "detail", WriteFailure)
	}
	LoggerInfo("LayoutSource", "Ergopti Studio layout saved: {1}.", Payload["id"])
	return Map("ok", true, "detail", Payload["id"])
}

/**
 * Removes one layout; an id the store does not hold is already removed.
 * @returns {Map} ok, code and detail, the page's studioLayoutResult.
 */
StudioStore_Remove(Settings, ConfigDir, Payload, Ports := 0) {
	Ports := _SourceStore_Ports(Ports)
	if !(Payload is Map) || !StudioStore_ValidId(Settings, Payload.Get("id", 0))
		return Map("ok", false, "code", Settings["failures"]["invalid"], "detail", "the layout id is not a personal layout id")
	Layouts := _StudioStore_Load(Settings, ConfigDir, Ports, &Failure)
	if !(Layouts is Map) {
		LoggerError("LayoutSource", "An Ergopti Studio layout was not removed from an unreadable store: {1}.", Failure)
		return Map("ok", false, "code", Settings["failures"]["unreadable"], "detail", Failure)
	}
	if !Layouts.Has(Payload["id"])
		return Map("ok", true, "detail", Payload["id"])
	Layouts.Delete(Payload["id"])
	WriteFailure := _StudioStore_Write(Settings, ConfigDir, Ports, Layouts)
	if WriteFailure != "" {
		LoggerError("LayoutSource", "The Ergopti Studio layouts could not be written: {1}.", WriteFailure)
		return Map("ok", false, "code", Settings["failures"]["write"], "detail", WriteFailure)
	}
	LoggerInfo("LayoutSource", "Ergopti Studio layout removed: {1}.", Payload["id"])
	return Map("ok", true, "detail", Payload["id"])
}

/**
 * The generated tables of one built-in corpus, as the JavaScript the Studio
 * page runs (the page's relative corpus URLs name the comparer's folder).
 * @param {Map} Settings - From StudioStore_Settings.
 * @param {String} SharedDir - The _shared folder, without a trailing backslash.
 * @param {Map} Payload - { id }.
 * @param {Map} Ports - As SourceStore_Open.
 * @returns {Map} ok and text, or ok false, code and detail.
 */
StudioStore_Corpus(Settings, SharedDir, Payload, Ports := 0) {
	Ports := _SourceStore_Ports(Ports)
	Id := (Payload is Map) ? Payload.Get("id", 0) : 0
	if !(Id is String) || StrLen(Id) > Settings["id_max_length"] || !RegExMatch(Id, Settings["corpus_id_pattern"]) {
		LoggerWarn("LayoutSource", "Refused an Ergopti Studio corpus request without a corpus id.")
		return Map("ok", false, "code", Settings["failures"]["corpus"], "detail", "the corpus id is not a built-in corpus id")
	}
	Path := SharedDir . "\" . StrReplace(Settings["corpus_folder"], "/", "\") . "\" . Settings["corpus_prefix"] . Id . ".js"
	if !Ports["exists"].Call(Path) {
		LoggerWarn("LayoutSource", "Ergopti Studio has no built-in corpus {1}.", Id)
		return Map("ok", false, "code", Settings["failures"]["corpus"], "detail", Path . " does not exist")
	}
	Text := Ports["read"].Call(Path, Settings["max_corpus_bytes"])
	if !(Text is String) {
		LoggerError("LayoutSource", "An Ergopti Studio corpus is unreadable: {1}.", Path)
		return Map("ok", false, "code", Settings["failures"]["corpus"], "detail", Path . " could not be read")
	}
	return Map("ok", true, "text", Text)
}
