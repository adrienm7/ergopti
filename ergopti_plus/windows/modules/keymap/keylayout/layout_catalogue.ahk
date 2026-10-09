; modules/keymap/keylayout/layout_catalogue.ahk

; ==============================================================================
; MODULE: Layout Catalogue (Windows client)
; DESCRIPTION:
; The Windows side of the layout manager: refreshes the registry catalogue,
; installs, updates and uninstalls registry layouts, and records what is
; installed. Windows emulates a registry layout from its verified .keylayout
; (keylayout_emulation.ahk), so installing a layout means keeping that verified
; copy in <configuration folder>/layouts/ with the index entry it matches.
;
; FEATURES & RATIONALE:
; 1. The decisions are the ones the macOS and Linux drivers take through
;    _shared/lua/layouts/catalogue.lua, pinned by the shared vectors of
;    _shared/tests/corpus/layouts/catalogue_vectors.json: conditional refresh
;    with the cached ETag, cache then shipped-index fallbacks with the exact
;    error, the installed record, and the offline installation of a layout
;    shipped with the driver.
; 2. The installed record (installed.json) keeps, per layout, the index entry
;    its local copy was verified against, so a later refresh of the catalogue
;    never invalidates an installed layout: it only shows that an update exists.
; 3. The record is written last: an interrupted installation leaves an
;    unrecorded file, never a record vouching for a file that is not there.
; 4. Transfers run in a curl child polled from a timer (LayoutRegistry_Request),
;    never on the keyboard thread; every collaborator is injectable.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Where the index the catalogue shows comes from.
global LAYOUT_CATALOGUE_SOURCE_NETWORK := "network"
global LAYOUT_CATALOGUE_SOURCE_CACHE := "cache"
global LAYOUT_CATALOGUE_SOURCE_BUNDLED := "bundled"
global LAYOUT_CATALOGUE_SOURCE_NONE := "none"

; Why the network index is missing; stable codes the layout manager translates.
global LAYOUT_CATALOGUE_ERROR_OFFLINE := "offline"
global LAYOUT_CATALOGUE_ERROR_HTTP := "http"
global LAYOUT_CATALOGUE_ERROR_INVALID_INDEX := "invalid_index"
global LAYOUT_CATALOGUE_ERROR_TOO_LARGE := "too_large"
global LAYOUT_CATALOGUE_ERROR_NOT_MODIFIED_WITHOUT_CACHE := "not_modified_without_cache"

; Why an operation failed; stable codes the layout manager translates.
global LAYOUT_CATALOGUE_FAILURE_BUSY := "busy"
global LAYOUT_CATALOGUE_FAILURE_UNKNOWN_LAYOUT := "unknown_layout"
global LAYOUT_CATALOGUE_FAILURE_NOT_INSTALLED := "not_installed"
global LAYOUT_CATALOGUE_FAILURE_UNSUPPORTED := "unsupported_platform"
global LAYOUT_CATALOGUE_FAILURE_DOWNLOAD := "download_failed"
global LAYOUT_CATALOGUE_FAILURE_WRITE := "write_failed"
global LAYOUT_CATALOGUE_FAILURE_RECORD := "record_failed"

; Version of the installed record this module reads and writes.
global LAYOUT_CATALOGUE_INSTALLED_SCHEMA := 1

; The platform name registry entries list when Windows can emulate them.
global LAYOUT_CATALOGUE_PLATFORM := "windows"

; The index-entry fields the installed record keeps: what verifies the local
; copy (file, size, sha256), what the emulation reads (keycode_convention) and
; what the layout manager shows.
global LAYOUT_CATALOGUE_RECORD_FIELDS := ["id", "name", "family", "keyboard_name", "version", "file",
	"sha256", "size", "keycode_convention", "licence", "author", "homepage"]





; ========================
; ========================
; ======= 2/ State =======
; ========================
; ========================

; Last refresh outcome (LayoutCatalogue_ResolveIndex), shown by the manager.
global _LayoutCatalogueLast := Map("index", 0, "source", "none", "error", 0)
; The one operation in flight, "" when idle: an installation and an
; uninstallation must never interleave their writes.
global _LayoutCatalogueBusyId := ""
global _LayoutCatalogueBusyAction := ""





; ========================
; ========================
; ======= 3/ Index =======
; ========================
; ========================

/**
 * Why a parsed value is not a usable registry index, "" when it is.
 * @param Index - Parsed index.json.
 * @returns {string}
 */
LayoutCatalogue_IndexProblem(Index) {
	if !(Index is Map) || !Index.Has("layouts") || !(Index["layouts"] is Array)
		return "the registry index has no layouts list"
	Seen := Map()
	for Entry in Index["layouts"] {
		if !(Entry is Map) || !Entry.Has("id") || !LayoutRegistry_IsValidId(Entry["id"])
			return "layout " . A_Index . " of the registry index has no valid id"
		if Seen.Has(Entry["id"])
			return "the registry index lists '" . Entry["id"] . "' twice"
		Seen[Entry["id"]] := true
		Usable := Entry.Has("size") && (Entry["size"] is Integer)
		for Field in ["file", "sha256", "version"]
			Usable := Usable && Entry.Has(Field) && (Entry[Field] is String)
		if !Usable
			return "the registry entry of '" . Entry["id"] . "' has no usable file, checksum, size or version"
		if Entry.Has("extension") && (Problem := LayoutExtension_Problem(Entry)) != ""
			return Problem
	}
	return ""
}

/**
 * Parses and validates an index text.
 * @param Text - Index text (anything else is refused).
 * @param {Integer} MaxBytes - Download bound of the registry.
 * @returns {Map} "index" on success, or "code" and "detail".
 */
LayoutCatalogue_DecodeIndex(Text, MaxBytes) {
	global LAYOUT_CATALOGUE_ERROR_TOO_LARGE, LAYOUT_CATALOGUE_ERROR_INVALID_INDEX
	if !(Text is String)
		return Map("code", LAYOUT_CATALOGUE_ERROR_INVALID_INDEX, "detail", "no index text")
	if (StrPut(Text, "UTF-8") - 1 > MaxBytes)
		return Map("code", LAYOUT_CATALOGUE_ERROR_TOO_LARGE, "detail", "the registry index exceeds the download bound")
	try Index := JsonParse(Text)
	catch
		return Map("code", LAYOUT_CATALOGUE_ERROR_INVALID_INDEX, "detail", "the registry index is not valid JSON")
	Problem := LayoutCatalogue_IndexProblem(Index)
	if (Problem != "")
		return Map("code", LAYOUT_CATALOGUE_ERROR_INVALID_INDEX, "detail", Problem)
	return Map("index", Index)
}

/**
 * Chooses the index the catalogue shows after one refresh response.
 * @param {Integer} Status - HTTP status, 0 when no response arrived.
 * @param {string} Body - Response body.
 * @param {string} Etag - Response ETag, "" when none.
 * @param {string} Err - Transport error, "" when none.
 * @param Cached - Map("index", Index, "etag", Etag) from the local cache, or 0.
 * @param Bundled - Index shipped with the driver, or 0.
 * @param {Integer} MaxBytes - Download bound of the registry.
 * @returns {Map} "index" (0 when none), "source", "etag", "store", "text", "error" (0 or Map code/detail).
 */
LayoutCatalogue_ResolveIndex(Status, Body, Etag, Err, Cached, Bundled, MaxBytes) {
	global LAYOUT_CATALOGUE_SOURCE_NETWORK, LAYOUT_CATALOGUE_SOURCE_CACHE, LAYOUT_CATALOGUE_SOURCE_BUNDLED
	global LAYOUT_CATALOGUE_SOURCE_NONE, LAYOUT_CATALOGUE_ERROR_NOT_MODIFIED_WITHOUT_CACHE
	global LAYOUT_CATALOGUE_ERROR_OFFLINE, LAYOUT_CATALOGUE_ERROR_HTTP
	if (Status == 200) {
		Decoded := LayoutCatalogue_DecodeIndex(Body, MaxBytes)
		if Decoded.Has("index")
			return Map("index", Decoded["index"], "source", LAYOUT_CATALOGUE_SOURCE_NETWORK, "etag", Etag,
				"store", true, "text", Body, "error", 0)
		Failure := Map("code", Decoded["code"], "detail", Decoded["detail"])
	} else if (Status == 304) {
		if (Cached is Map)
			return Map("index", Cached["index"], "source", LAYOUT_CATALOGUE_SOURCE_CACHE, "etag", Cached["etag"],
				"store", false, "text", "", "error", 0)
		Failure := Map("code", LAYOUT_CATALOGUE_ERROR_NOT_MODIFIED_WITHOUT_CACHE,
			"detail", "the registry answered 304 although no index is cached")
	} else if (Status == 0) {
		Failure := Map("code", LAYOUT_CATALOGUE_ERROR_OFFLINE,
			"detail", (Err != "") ? Err : "no HTTP response (network, proxy or timeout)")
	} else {
		Failure := Map("code", LAYOUT_CATALOGUE_ERROR_HTTP, "detail", "HTTP " . Status)
	}
	return LayoutCatalogue_Fallback(Failure, Cached, Bundled)
}

/**
 * The index to show when the network one is missing: the cached one, else
 * the one shipped with the driver, else none; the failure is kept.
 * @param {Map} Failure - Map("code", Code, "detail", Detail).
 * @param Cached - Map("index", Index, "etag", Etag), or 0.
 * @param Bundled - Index shipped with the driver, or 0.
 * @returns {Map} The outcome LayoutCatalogue_ResolveIndex returns.
 */
LayoutCatalogue_Fallback(Failure, Cached, Bundled) {
	global LAYOUT_CATALOGUE_SOURCE_CACHE, LAYOUT_CATALOGUE_SOURCE_BUNDLED, LAYOUT_CATALOGUE_SOURCE_NONE
	if (Cached is Map)
		return Map("index", Cached["index"], "source", LAYOUT_CATALOGUE_SOURCE_CACHE, "etag", Cached["etag"],
			"store", false, "text", "", "error", Failure)
	if (Bundled is Map)
		return Map("index", Bundled, "source", LAYOUT_CATALOGUE_SOURCE_BUNDLED, "etag", "",
			"store", false, "text", "", "error", Failure)
	return Map("index", 0, "source", LAYOUT_CATALOGUE_SOURCE_NONE, "etag", "", "store", false, "text", "",
		"error", Failure)
}

/**
 * The index entry of ``Id``, or 0.
 * @param Index - Parsed index (0 for none).
 * @param {string} Id
 * @returns {Map|Integer}
 */
LayoutCatalogue_Entry(Index, Id) {
	if !(Index is Map)
		return 0
	for Entry in Index["layouts"]
		if (Entry["id"] == Id)
			return Entry
	return 0
}

/**
 * Whether a registry entry is an Ergopti layout: its family is the one
 * _shared/modules/layouts/defaults.json names (catalogue.is_ergopti on macOS
 * and Linux). The Ergopti-only hotstrings are written for its key positions.
 * @param Entry - Index or installed-record entry (anything else is not Ergopti).
 * @returns {boolean}
 */
LayoutCatalogue_IsErgopti(Entry) {
	return (Entry is Map) && (Entry.Get("family", "") == LayoutRegistry_Settings()["ergopti_family"])
}





; ==============================
; ==============================
; ======= 4/ Local files =======
; ==============================
; ==============================

; Replaces a file atomically: the text lands under a partial name first.
_LayoutCatalogueWriteText(Path, Text) {
	global LAYOUT_REGISTRY_PARTIAL_SUFFIX
	Partial := Path . LAYOUT_REGISTRY_PARTIAL_SUFFIX
	if !FSWrite(Partial, Text)
		throw Error("Cannot write " . Partial)
	if !FSAtomicMoveReplace(Partial, Path)
		throw Error("Cannot publish " . Path)
}

; Minimal JSON writer for the installed record: Maps, Arrays, strings and
; integers, the only shapes the record holds.
_LayoutCatalogueJson(Value) {
	if (Value is Map) {
		Out := ""
		for Key, Item in Value
			Out .= (A_Index > 1 ? "," : "") . JsonStringLiteral(Key) . ":" . _LayoutCatalogueJson(Item)
		return "{" . Out . "}"
	}
	if (Value is Array) {
		Out := ""
		for Item in Value
			Out .= (A_Index > 1 ? "," : "") . _LayoutCatalogueJson(Item)
		return "[" . Out . "]"
	}
	if (Value is Integer)
		return String(Value)
	if (Value is String)
		return JsonStringLiteral(Value)
	throw TypeError("The installed-layouts record holds an unsupported value.", -1, Type(Value))
}

/**
 * The installed layouts: registry id -> the index entry its local copy was
 * verified against. A missing record is empty; a damaged one throws, so it can
 * never make installed layouts look absent. Outdated entries warn once and are
 * excluded from this Map; private source metadata retains their original JSON.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @returns {Map}
 */
LayoutCatalogue_ReadInstalled(LocalDir) {
	global LAYOUT_CATALOGUE_INSTALLED_SCHEMA
	Settings := LayoutRegistry_Settings()
	Path := LocalDir . Settings["installed_file"]
	if !FileExist(Path)
		return Map()
	Text := FSReadBounded(Path, Settings["max_file_bytes"])
	if !(Text is String)
		throw Error("Cannot read the installed-layouts record " . Path)
	try Record := JsonParse(Text)
	catch
		throw Error("The installed-layouts record is not valid JSON: " . Path)
	if !(Record is Map) || !Record.Has("schema_version")
			|| (Record["schema_version"] != LAYOUT_CATALOGUE_INSTALLED_SCHEMA)
		throw Error("The installed-layouts record has an unknown schema version: " . Path)
	if !Record.Has("layouts") || !(Record["layouts"] is Map)
		throw Error("The installed-layouts record has no layouts table: " . Path)
	Installed := Map()
	Source := { path: Path, text: Text, top_members: JsonObjectMemberSpans(Text),
		layout_members: JsonObjectMemberSpans(Text, ["layouts"]), original: Map() }
	for Id, Entry in Record["layouts"] {
		Problem := _LayoutCatalogueInstalledEntryProblem(Id, Entry)
		if Problem != "" {
			ConfigOutdatedReportInFile(Path, "layouts[" . JsonStringLiteral(Id) . "]", Problem,
				(Message, Args*) => LoggerWarn("LayoutCatalogue", Message, Args*))
			continue
		}
		Installed[Id] := Entry
		Source.original[Id] := JsonParse(Source.layout_members[Id]["text"])
	}
	; Object properties never enumerate as layouts and cannot reserve a user's id.
	Installed._LayoutCatalogueRecordSource := Source
	return Installed
}

/**
 * Writes the installed record.
 * @param {string} LocalDir
 * @param {Map} Installed - Registry id -> entry.
 */
LayoutCatalogue_WriteInstalled(LocalDir, Installed) {
	global LAYOUT_CATALOGUE_INSTALLED_SCHEMA
	Path := LocalDir . LayoutRegistry_Settings()["installed_file"]
	if !Installed.HasOwnProp("_LayoutCatalogueRecordSource") {
		Record := Map("schema_version", LAYOUT_CATALOGUE_INSTALLED_SCHEMA, "layouts", Installed)
		_LayoutCatalogueWriteText(Path, _LayoutCatalogueJson(Record))
		return
	}
	Source := Installed._LayoutCatalogueRecordSource
	if !(Path == Source.path) || FSReadBounded(Path, LayoutRegistry_Settings()["max_file_bytes"]) !== Source.text
		throw Error("The installed-layouts record changed before publication: " . Path)
	Layouts := ""
	for Id, Span in Source.layout_members {
		if Source.original.Has(Id)
			continue
		; An explicit installation of the same id replaces its obsolete entry.
		if !Installed.Has(Id)
			Layouts .= (Layouts != "" ? "," : "") . Span["member_text"]
	}
	for Id, Entry in Installed {
		if Source.original.Has(Id) && _LayoutCatalogueSameValue(Entry, Source.original[Id]) {
			Layouts .= (Layouts != "" ? "," : "") . Source.layout_members[Id]["member_text"]
			continue
		}
		Text := Source.original.Has(Id)
			? _LayoutCatalogueOverlayEntry(Entry, Source.original[Id], Source.layout_members[Id]["text"])
			: _LayoutCatalogueJson(Entry)
		Layouts .= (Layouts != "" ? "," : "") . JsonStringLiteral(Id) . ":" . Text
	}
	Text := '{"schema_version":' . LAYOUT_CATALOGUE_INSTALLED_SCHEMA . ',"layouts":{' . Layouts . "}"
	for Key, Span in Source.top_members {
		if Key !== "schema_version" && Key !== "layouts"
			Text .= "," . Span["member_text"]
	}
	_LayoutCatalogueWriteText(Path, Text . "}")
}

; Classify one entry without turning a stale row into a damaged whole document.
; Keep this driver's established membership validation separate from preservation.
_LayoutCatalogueInstalledEntryProblem(Id, Entry) {
	if !LayoutRegistry_IsValidId(Id)
		return "the key is not a layout id"
	if !(Entry is Map)
		return "the entry is not an object"
	if !Entry.Has("id") || Entry["id"] !== Id
		return "its id field does not name this entry"
	if !Entry.Has("sha256") || !Entry.Has("version") || !Entry.Has("size")
		return "it has no verified checksum, version or size"
	return ""
}

; Retain source tokens for unchanged values, including JSON Boolean/null/float
; identities that the existing minimal native record writer cannot re-encode.
_LayoutCatalogueSameValue(Left, Right) {
	if Type(Left) != Type(Right)
		return false
	if Left is Map {
		if Left.Count != Right.Count
			return false
		for Key, Value in Left
			if !Right.Has(Key) || !_LayoutCatalogueSameValue(Value, Right[Key])
				return false
		return true
	}
	if Left is Array {
		if Left.Length != Right.Length
			return false
		for Index, Value in Left
			if !_LayoutCatalogueSameValue(Value, Right[Index])
				return false
		return true
	}
	return Left == Right
}

; A catalogue update owns the current index fields; future members remain raw.
_LayoutCatalogueOverlayEntry(Entry, Original, OriginalText) {
	global LAYOUT_CATALOGUE_RECORD_FIELDS
	Members := JsonObjectMemberSpans(OriginalText)
	Owned := Map("extension", true)
	for Field in LAYOUT_CATALOGUE_RECORD_FIELDS
		Owned[Field] := true
	Text := ""
	for Field, Span in Members {
		if !Entry.Has(Field) {
			if !Owned.Has(Field)
				Text .= (Text != "" ? "," : "") . Span["member_text"]
			continue
		}
		Member := _LayoutCatalogueSameValue(Entry[Field], Original[Field])
			? Span["member_text"] : JsonStringLiteral(Field) . ":" . _LayoutCatalogueJson(Entry[Field])
		Text .= (Text != "" ? "," : "") . Member
	}
	for Field, Value in Entry {
		if !Members.Has(Field)
			Text .= (Text != "" ? "," : "") . JsonStringLiteral(Field) . ":" . _LayoutCatalogueJson(Value)
	}
	return "{" . Text . "}"
}

; The record keeps the fields LAYOUT_CATALOGUE_RECORD_FIELDS names.
_LayoutCatalogueRecordEntry(Entry) {
	global LAYOUT_CATALOGUE_RECORD_FIELDS
	Kept := Map()
	for Field in LAYOUT_CATALOGUE_RECORD_FIELDS
		if Entry.Has(Field) && ((Entry[Field] is String) || (Entry[Field] is Integer))
			Kept[Field] := Entry[Field]
	if Entry.Has("extension")
		Kept["extension"] := JsonParse(_LayoutCatalogueJson(Entry["extension"]))
	return Kept
}

/**
 * The index shipped with the driver, or 0 when it is unusable.
 * @returns {Map|Integer}
 */
LayoutCatalogue_BundledIndex() {
	Settings := LayoutRegistry_Settings()
	Path := LayoutRegistry_BundledDir() . Settings["index_file"]
	Text := FileExist(Path) ? FSReadBounded(Path, Settings["max_file_bytes"]) : false
	Decoded := LayoutCatalogue_DecodeIndex(Text, Settings["max_file_bytes"])
	if Decoded.Has("index")
		return Decoded["index"]
	LoggerError("LayoutCatalogue", "The layout index shipped with the driver is unusable: {1}", Decoded["detail"])
	return 0
}

; The cached index and its ETag, or 0 when nothing usable is cached.
_LayoutCatalogueReadCache(LocalDir) {
	Settings := LayoutRegistry_Settings()
	IndexPath := LocalDir . Settings["index_file"]
	if !FileExist(IndexPath)
		return 0
	Decoded := LayoutCatalogue_DecodeIndex(FSReadBounded(IndexPath, Settings["max_file_bytes"]),
		Settings["max_file_bytes"])
	if !Decoded.Has("index") {
		LoggerWarn("LayoutCatalogue", "The cached layout index is unusable ({1}); refreshing without it.",
			Decoded["detail"])
		return 0
	}
	EtagPath := LocalDir . Settings["etag_file"]
	Etag := FileExist(EtagPath) ? FSReadBounded(EtagPath, Settings["max_file_bytes"]) : ""
	return Map("index", Decoded["index"], "etag", (Etag is String) ? Trim(Etag) : "")
}





; ============================
; ============================
; ======= 5/ Refresh =========
; ============================
; ============================

/**
 * Refreshes the catalogue with a conditional request for the registry index.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @param {Func} OnDone - OnDone(Outcome), called exactly once (LayoutCatalogue_ResolveIndex).
 * @param {Map} Transport - See LayoutRegistry_Request; injectable for tests.
 * @param Bundled - Index shipped with the driver (0 for none); read from the
 *   shipped registry folder when omitted.
 * @param {Boolean} LocalSource - Use the checkout registry; defaults to the updater's source mode.
 */
LayoutCatalogue_Refresh(LocalDir, OnDone, Transport := 0, Bundled := unset, LocalSource := unset) {
	global LAYOUT_REGISTRY_PARTIAL_SUFFIX, LAYOUT_REGISTRY_USER_AGENT
	global LAYOUT_CATALOGUE_SOURCE_BUNDLED, LAYOUT_CATALOGUE_SOURCE_NONE, LAYOUT_CATALOGUE_ERROR_INVALID_INDEX
	Settings := LayoutRegistry_Settings()
	if !IsSet(Bundled)
		Bundled := LayoutCatalogue_BundledIndex()
	LoggerStart("LayoutCatalogue", "Refreshing the layout catalogue…")
	if !IsSet(LocalSource)
		LocalSource := Updater_IsLocalSource()
	if LocalSource {
		Problem := LayoutCatalogue_IndexProblem(Bundled)
		_LayoutCatalogueFinishRefresh(Map("index", Problem == "" ? Bundled : 0,
			"source", Problem == "" ? LAYOUT_CATALOGUE_SOURCE_BUNDLED : LAYOUT_CATALOGUE_SOURCE_NONE,
			"store", false, "etag", "", "error", Problem == "" ? 0
				: Map("code", LAYOUT_CATALOGUE_ERROR_INVALID_INDEX, "detail", Problem)), OnDone)
		return
	}
	try {
		if !DirExist(LocalDir)
			DirCreate(LocalDir)
		Cached := _LayoutCatalogueReadCache(LocalDir)
	} catch as Err {
		_LayoutCatalogueFinishRefresh(LayoutCatalogue_ResolveIndex(0, "", "",
			"cannot prepare " . LocalDir . ": " . Err.Message, 0, Bundled, Settings["max_file_bytes"]), OnDone)
		return
	}
	Headers := Map("User-Agent", LAYOUT_REGISTRY_USER_AGENT)
	if (Cached is Map) && (Cached["etag"] != "")
		Headers["If-None-Match"] := Cached["etag"]
	Partial := LocalDir . Settings["index_file"] . LAYOUT_REGISTRY_PARTIAL_SUFFIX
	LayoutRegistry_Request(LayoutRegistry_RawUrl(Settings["index_file"]), Partial, Headers,
		Settings["download_timeout_sec"] * 1000, Transport,
		_LayoutCatalogueOnIndex.Bind(LocalDir, Partial, Cached, Bundled, OnDone))
}

_LayoutCatalogueOnIndex(LocalDir, Partial, Cached, Bundled, OnDone, Status, Etag, Err) {
	global LAYOUT_CATALOGUE_ERROR_TOO_LARGE
	Settings := LayoutRegistry_Settings()
	Body := ""
	if (Status == 200)
		Body := FSReadBounded(Partial, Settings["max_file_bytes"])
	if (Body is String)
		Outcome := LayoutCatalogue_ResolveIndex(Status, Body, Etag, Err, Cached, Bundled, Settings["max_file_bytes"])
	else
		Outcome := LayoutCatalogue_Fallback(Map("code", LAYOUT_CATALOGUE_ERROR_TOO_LARGE,
			"detail", "the registry index exceeds the download bound or cannot be read"), Cached, Bundled)
	if Outcome["store"] {
		try {
			if !FSAtomicMoveReplace(Partial, LocalDir . Settings["index_file"])
				throw Error("cannot publish the downloaded index in " . LocalDir)
			EtagPath := LocalDir . Settings["etag_file"]
			if (Outcome["etag"] != "")
				_LayoutCatalogueWriteText(EtagPath, Outcome["etag"])
			else if !FSDelete(EtagPath)
				throw Error("cannot remove " . EtagPath)
		} catch as Err {
			LoggerError("LayoutCatalogue", "The refreshed layout index could not be cached: {1}", Err.Message)
		}
	}
	if !FSDelete(Partial)
		LoggerWarn("LayoutCatalogue", "Cannot remove the partial download {1}.", Partial)
	_LayoutCatalogueFinishRefresh(Outcome, OnDone)
}

_LayoutCatalogueFinishRefresh(Outcome, OnDone) {
	global _LayoutCatalogueLast
	_LayoutCatalogueLast := Outcome
	if (Outcome["error"] is Map)
		LoggerWarn("LayoutCatalogue", "The layout catalogue shows the {1} index: {2} ({3}).", Outcome["source"],
			Outcome["error"]["code"], Outcome["error"]["detail"])
	LoggerSuccess("LayoutCatalogue", "Layout catalogue refreshed from the {1} index.", Outcome["source"])
	OnDone.Call(Outcome)
}

/**
 * The last refresh outcome (index 0 and source "none" before any refresh).
 * @returns {Map}
 */
LayoutCatalogue_Last() {
	global _LayoutCatalogueLast
	return _LayoutCatalogueLast
}





; ======================================
; ======================================
; ======= 6/ Install / uninstall =======
; ======================================
; ======================================

/**
 * The operation in flight, Map("id", Id, "action", Action), or 0 when idle.
 * @returns {Map|Integer}
 */
LayoutCatalogue_Busy() {
	global _LayoutCatalogueBusyId, _LayoutCatalogueBusyAction
	return (_LayoutCatalogueBusyId == "") ? 0 : Map("id", _LayoutCatalogueBusyId, "action", _LayoutCatalogueBusyAction)
}

_LayoutCatalogueAcquire(Id, Action) {
	global _LayoutCatalogueBusyId, _LayoutCatalogueBusyAction
	if (_LayoutCatalogueBusyId != "") {
		LoggerWarn("LayoutCatalogue", "Refused to {1} '{2}': '{3}' is still being {4}ed.", Action, Id,
			_LayoutCatalogueBusyId, _LayoutCatalogueBusyAction)
		return false
	}
	_LayoutCatalogueBusyId := Id
	_LayoutCatalogueBusyAction := Action
	return true
}

_LayoutCatalogueRelease() {
	global _LayoutCatalogueBusyId, _LayoutCatalogueBusyAction
	_LayoutCatalogueBusyId := ""
	_LayoutCatalogueBusyAction := ""
}

/**
 * Installs (or updates) one registry layout: refreshes the catalogue, takes the
 * layout's bytes from the copy shipped with the driver when it is the file the
 * index describes or downloads them, verifies them, then publishes the local
 * copy and its record.
 * @param {string} Id - Registry id.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @param {Func} OnDone - OnDone(true, Map("entry", Entry, "source", Source)) or
 *   OnDone(false, FailureCode, Detail); called exactly once.
 * @param {Map} Transport - See LayoutRegistry_Request; injectable for tests.
 * @param Bundled - Index shipped with the driver (0 for none); read when omitted.
 * @param {string} BundledDir - Folder of the shipped registry; LayoutRegistry_BundledDir() when omitted.
 * @param {Boolean} LocalSource - Optional source mode passed to the catalogue refresh.
 */
LayoutCatalogue_Install(Id, LocalDir, OnDone, Transport := 0, Bundled := unset, BundledDir := unset,
	LocalSource := unset) {
	global LAYOUT_CATALOGUE_FAILURE_UNKNOWN_LAYOUT, LAYOUT_CATALOGUE_FAILURE_BUSY, LAYOUT_CATALOGUE_FAILURE_RECORD
	if !LayoutRegistry_IsValidId(Id) {
		OnDone.Call(false, LAYOUT_CATALOGUE_FAILURE_UNKNOWN_LAYOUT, "'" . Id . "' is not a registry layout id")
		return
	}
	if !_LayoutCatalogueAcquire(Id, "install") {
		OnDone.Call(false, LAYOUT_CATALOGUE_FAILURE_BUSY, "another layout operation is still running")
		return
	}
	if !IsSet(Bundled)
		Bundled := LayoutCatalogue_BundledIndex()
	if !IsSet(BundledDir)
		BundledDir := LayoutRegistry_BundledDir()
	LoggerStart("LayoutCatalogue", "Installing the '{1}' layout…", Id)
	Finish := _LayoutCatalogueFinishInstall.Bind(Id, OnDone)
	; The record is read before anything is written: a copy it cannot record
	; would sit in the local folder with nothing vouching for it.
	try LayoutCatalogue_ReadInstalled(LocalDir)
	catch as Err {
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_RECORD, Err.Message)
		return
	}
	LayoutCatalogue_Refresh(LocalDir, _LayoutCatalogueOnInstallIndex.Bind(Id, LocalDir, Transport, Bundled,
		BundledDir, Finish), Transport, Bundled, LocalSource?)
}

_LayoutCatalogueFinishInstall(Id, OnDone, Ok, CodeOrDetail, Detail := "") {
	_LayoutCatalogueRelease()
	if Ok {
		LoggerSuccess("LayoutCatalogue", "Installed the '{1}' layout, version {2}, from the {3} copy.", Id,
			CodeOrDetail["entry"]["version"], CodeOrDetail["source"])
		OnDone.Call(true, CodeOrDetail)
		return
	}
	LoggerError("LayoutCatalogue", "The '{1}' layout was not installed ({2}): {3}", Id, CodeOrDetail, Detail)
	OnDone.Call(false, CodeOrDetail, Detail)
}

_LayoutCatalogueOnInstallIndex(Id, LocalDir, Transport, Bundled, BundledDir, Finish, Outcome) {
	global LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, LAYOUT_CATALOGUE_FAILURE_UNKNOWN_LAYOUT
	global LAYOUT_CATALOGUE_FAILURE_UNSUPPORTED, LAYOUT_CATALOGUE_PLATFORM, LAYOUT_CATALOGUE_SOURCE_BUNDLED
	global LAYOUT_CATALOGUE_SOURCE_NETWORK, LAYOUT_REGISTRY_PARTIAL_SUFFIX, LAYOUT_REGISTRY_USER_AGENT
	if !(Outcome["index"] is Map) {
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_DOWNLOAD,
			(Outcome["error"] is Map) ? Outcome["error"]["detail"] : "no registry index")
		return
	}
	Entry := LayoutCatalogue_Entry(Outcome["index"], Id)
	if !(Entry is Map) {
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_UNKNOWN_LAYOUT, "the layout '" . Id . "' is not in the registry index")
		return
	}
	Supported := false
	if Entry.Has("platforms") && (Entry["platforms"] is Array)
		for Platform in Entry["platforms"]
			Supported := Supported || (Platform == LAYOUT_CATALOGUE_PLATFORM)
	if !Supported {
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_UNSUPPORTED, "the layout '" . Id . "' is not published for Windows")
		return
	}
	; The shipped copy is used only when it IS the file the index describes.
	Shipped := LayoutCatalogue_Entry(Bundled, Id)
	if (Shipped is Map) && (Shipped["file"] == Entry["file"]) && (Shipped["size"] == Entry["size"])
			&& (Shipped["sha256"] == Entry["sha256"]) {
		try {
			Text := _LayoutRegistryReadText(BundledDir . StrReplace(Entry["file"], "/", "\"))
			LayoutRegistry_Verify(Entry, Text)
		} catch as Err {
			Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, "the shipped copy is damaged: " . Err.Message)
			return
		}
		_LayoutCatalogueFinishPublish(Id, LocalDir, Entry, Text, LAYOUT_CATALOGUE_SOURCE_BUNDLED, Finish, Transport, BundledDir)
		return
	}
	Partial := LocalDir . Id . ".keylayout" . LAYOUT_REGISTRY_PARTIAL_SUFFIX
	Url := LayoutRegistry_RawUrl(Entry["file"])
	LayoutRegistry_Request(Url, Partial, Map("User-Agent", LAYOUT_REGISTRY_USER_AGENT),
		LayoutRegistry_Settings()["download_timeout_sec"] * 1000, Transport,
		_LayoutCatalogueOnLayout.Bind(Id, LocalDir, Entry, Url, Partial, Finish, Transport, BundledDir))
}

_LayoutCatalogueOnLayout(Id, LocalDir, Entry, Url, Partial, Finish, Transport, BundledDir, Status, Etag, Err) {
	global LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, LAYOUT_CATALOGUE_SOURCE_NETWORK
	try {
		if (Status != 200)
			throw Error((Status == 0) ? Err : "HTTP " . Status . " for " . Url)
		Text := _LayoutRegistryReadText(Partial)
		LayoutRegistry_Verify(Entry, Text)
	} catch as Failure {
		if !FSDelete(Partial)
			LoggerWarn("LayoutCatalogue", "Cannot remove the partial download {1}.", Partial)
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, Failure.Message)
		return
	}
	if !FSDelete(Partial)
		LoggerWarn("LayoutCatalogue", "Cannot remove the partial download {1}.", Partial)
	_LayoutCatalogueFinishPublish(Id, LocalDir, Entry, Text, LAYOUT_CATALOGUE_SOURCE_NETWORK, Finish, Transport, BundledDir)
}

; Publishes a verified layout: the local copy, then the record.
_LayoutCatalogueFinishPublish(Id, LocalDir, Entry, Text, Source, Finish, Transport := 0, BundledDir := "") {
	if !Entry.Has("extension") {
		_LayoutCataloguePublishVerified(Id, LocalDir, Entry, Text, Source, Finish)
		return
	}
	LayoutExtension_Acquire(Entry, LocalDir, BundledDir, Transport, Text,
		_LayoutCatalogueOnExtension.Bind(Id, LocalDir, Entry, Text, Source, Finish))
}

_LayoutCatalogueOnExtension(Id, LocalDir, Entry, Text, Source, Finish, Ok, Detail := "") {
	global LAYOUT_CATALOGUE_FAILURE_DOWNLOAD
	if !Ok {
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, Detail)
		return
	}
	_LayoutCataloguePublishVerified(Id, LocalDir, Entry, Text, Source, Finish)
}

_LayoutCataloguePublishVerified(Id, LocalDir, Entry, Text, Source, Finish) {
	global LAYOUT_CATALOGUE_FAILURE_WRITE, LAYOUT_CATALOGUE_FAILURE_RECORD
	try _LayoutCatalogueWriteText(LocalDir . Id . ".keylayout", Text)
	catch as Err {
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_WRITE, Err.Message)
		return
	}
	try {
		Installed := LayoutCatalogue_ReadInstalled(LocalDir)
		Installed[Id] := _LayoutCatalogueRecordEntry(Entry)
		LayoutCatalogue_WriteInstalled(LocalDir, Installed)
	} catch as Err {
		Finish.Call(false, LAYOUT_CATALOGUE_FAILURE_RECORD, Err.Message)
		return
	}
	Finish.Call(true, Map("entry", Installed[Id], "source", Source))
}

/**
 * Uninstalls one registry layout: deletes its local copy, then its record. The
 * caller clears the emulated layout when it was this one.
 * @param {string} Id
 * @param {string} LocalDir
 * @returns {Map} "ok", and "code" and "detail" on failure.
 */
LayoutCatalogue_Uninstall(Id, LocalDir) {
	global LAYOUT_CATALOGUE_FAILURE_NOT_INSTALLED, LAYOUT_CATALOGUE_FAILURE_BUSY
	global LAYOUT_CATALOGUE_FAILURE_WRITE, LAYOUT_CATALOGUE_FAILURE_RECORD
	try Installed := LayoutCatalogue_ReadInstalled(LocalDir)
	catch as Err
		return Map("ok", false, "code", LAYOUT_CATALOGUE_FAILURE_RECORD, "detail", Err.Message)
	if !LayoutRegistry_IsValidId(Id) || !Installed.Has(Id)
		return Map("ok", false, "code", LAYOUT_CATALOGUE_FAILURE_NOT_INSTALLED,
			"detail", "the layout '" . Id . "' was not installed here")
	if !_LayoutCatalogueAcquire(Id, "uninstall")
		return Map("ok", false, "code", LAYOUT_CATALOGUE_FAILURE_BUSY, "detail", "another layout operation is still running")
	LoggerStart("LayoutCatalogue", "Uninstalling the '{1}' layout…", Id)
	try {
		if !FSDelete(LocalDir . Id . ".keylayout") {
			_LayoutCatalogueRelease()
			LoggerError("LayoutCatalogue", "The '{1}' layout was not uninstalled: its local copy cannot be deleted.", Id)
			return Map("ok", false, "code", LAYOUT_CATALOGUE_FAILURE_WRITE, "detail", "cannot delete the local copy")
		}
		Installed.Delete(Id)
		LayoutCatalogue_WriteInstalled(LocalDir, Installed)
	} catch as Err {
		_LayoutCatalogueRelease()
		LoggerError("LayoutCatalogue", "The '{1}' layout copy is deleted but its record is not: {2}", Id, Err.Message)
		return Map("ok", false, "code", LAYOUT_CATALOGUE_FAILURE_RECORD, "detail", Err.Message)
	}
	_LayoutCatalogueRelease()
	LoggerSuccess("LayoutCatalogue", "Uninstalled the '{1}' layout.", Id)
	return Map("ok", true)
}
