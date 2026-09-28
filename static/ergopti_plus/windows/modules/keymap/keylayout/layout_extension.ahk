; modules/keymap/keylayout/layout_extension.ahk

; ==============================================================================
; MODULE: Layout Extension Content
; DESCRIPTION:
; Acquires and stages existing-format extension files before the installed record
; publishes their immutable generation. Discovery never scans unfinished stages,
; and installation never writes hotstring or shortcut activation preferences.
; ==============================================================================

/**
 * Validates an extension inventory before filesystem or network effects.
 * @param {Map} Entry - Registry layout entry.
 * @returns {String} Empty when valid, otherwise a diagnostic.
 */
LayoutExtension_Problem(Entry) {
	if !(Entry is Map) || !LayoutRegistry_IsValidId(Entry.Get("id", ""))
		return "invalid layout id"
	Extension := Entry.Get("extension", 0)
	if !(Extension is Map) || !RegExMatch(Extension.Get("id", ""), "^[a-z][a-z0-9_-]*$")
			|| !RegExMatch(Extension.Get("sha256", ""), "^[0-9a-f]{64}$") || !(Extension.Get("files", 0) is Array)
		return "invalid layout extension inventory"
	Seen := Map(), Total := 0
	for Item in Extension["files"] {
		if !(Item is Map)
			return "invalid layout extension file"
		Path := Item.Get("path", "")
		Allowed := (Path == "manifest.toml") || (Path == Entry["id"] . ".keylayout")
			|| RegExMatch(Path, "^hotstrings/[a-z][a-z0-9_-]*\.toml$")
			|| RegExMatch(Path, "^shortcuts/menu\.(ahk|lua)$") || RegExMatch(Path, "^[A-Z][A-Z0-9_-]*(\.txt)?$")
		if !Allowed || Seen.Has(Path) || !(Item.Get("size", "") is Integer) || Item["size"] < 0
				|| !RegExMatch(Item.Get("sha256", ""), "^[0-9a-f]{64}$")
			return "invalid or duplicate layout extension file"
		if (Item.Get("file", "") != Entry["id"] . "/" . Path)
				&& (Item.Get("file", "") != Extension["id"] . "/" . Path)
			return "extension file is outside its registry folder"
		Seen[Path] := true
		Total += Item["size"]
	}
	if !Seen.Has("manifest.toml") || !Seen.Has(Entry["id"] . ".keylayout")
		return "layout extension is missing its manifest or keylayout"
	return Total > LayoutRegistry_Settings()["max_file_bytes"] ? "layout extension exceeds the download bound" : ""
}

/**
 * Roots consumed by the existing extension scanner; only committed records count.
 * @param {String} LocalDir - Layout state folder with a trailing separator.
 * @returns {Array} Generation roots with trailing separators.
 */
LayoutExtension_Roots(LocalDir) {
	Roots := []
	for Id, Entry in LayoutCatalogue_ReadInstalled(LocalDir) {
		if !Entry.Has("extension")
			continue
		Problem := LayoutExtension_Problem(Entry)
		if Problem != ""
			throw Error(Problem)
		Roots.Push(LocalDir . "extensions\" . Id . "\" . Entry["extension"]["sha256"] . "\")
	}
	return Roots
}

/**
 * Acquires every verified file and stages it without publishing an installed record.
 * @param {Map} Entry - Registry entry.
 * @param {String} LocalDir - Layout state folder.
 * @param {String} BundledDir - Shipped registry folder, or empty.
 * @param {Map|Integer} Transport - Existing registry transport collaborator.
 * @param {String} LayoutText - Already verified layout bytes.
 * @param {Func} OnDone - Receives success and an optional error diagnostic.
 */
LayoutExtension_Acquire(Entry, LocalDir, BundledDir, Transport, LayoutText, OnDone) {
	Problem := LayoutExtension_Problem(Entry)
	if Problem != "" {
		OnDone.Call(false, Problem)
		return
	}
	State := Map("entry", Entry, "local", LocalDir, "bundled", BundledDir, "transport", Transport,
		"content", Map(Entry["id"] . ".keylayout", LayoutText), "position", 0, "done", OnDone, "finished", false)
	_LayoutExtensionNext(State)
}

_LayoutExtensionFinish(State, Ok, Detail := "") {
	if State["finished"]
		return
	State["finished"] := true
	State["done"].Call(Ok, Detail)
}

_LayoutExtensionMatches(Item, Text) {
	return (Text is String) && (StrPut(Text, "UTF-8") - 1 == Item["size"]) && (CryptoSha256(Text) == Item["sha256"])
}

_LayoutExtensionNext(State) {
	global LAYOUT_REGISTRY_USER_AGENT
	if State["finished"]
		return
	State["position"] += 1
	Files := State["entry"]["extension"]["files"]
	if State["position"] > Files.Length {
		try _LayoutExtensionStage(State)
		catch as Err {
			_LayoutExtensionFinish(State, false, Err.Message)
			return
		}
		_LayoutExtensionFinish(State, true)
		return
	}
	Item := Files[State["position"]]
	if State["content"].Has(Item["path"]) {
		if !_LayoutExtensionMatches(Item, State["content"][Item["path"]]) {
			_LayoutExtensionFinish(State, false, "extension keylayout does not match its inventory")
			return
		}
		_LayoutExtensionNext(State)
		return
	}
	Bundled := State["bundled"] . StrReplace(Item["file"], "/", "\")
	Text := State["bundled"] != "" && FileExist(Bundled)
		? FSReadBounded(Bundled, LayoutRegistry_Settings()["max_file_bytes"]) : false
	if _LayoutExtensionMatches(Item, Text) {
		State["content"][Item["path"]] := Text
		_LayoutExtensionNext(State)
		return
	}
	Partial := State["local"] . State["entry"]["id"] . ".extension.download"
	LayoutRegistry_Request(LayoutRegistry_RawUrl(Item["file"]), Partial, Map("User-Agent", LAYOUT_REGISTRY_USER_AGENT),
		LayoutRegistry_Settings()["download_timeout_sec"] * 1000, State["transport"],
		_LayoutExtensionDownloaded.Bind(State, Item, Partial, State["position"]))
}

_LayoutExtensionDownloaded(State, Item, Partial, Position, Status, Etag, Err) {
	if State["finished"] || State["position"] != Position
		return
	try {
		if Status != 200
			throw Error("Extension download failed: " . Status . " " . Err)
		Text := _LayoutRegistryReadText(Partial)
		if !_LayoutExtensionMatches(Item, Text)
			throw Error("Extension checksum or size mismatch: " . Item["path"])
		State["content"][Item["path"]] := Text
	} catch as Failure {
		if FileExist(Partial) && !FSDelete(Partial)
			LoggerWarn("LayoutCatalogue", "Cannot remove the partial extension download {1}.", Partial)
		_LayoutExtensionFinish(State, false, Failure.Message)
		return
	}
	if !FSDelete(Partial)
		LoggerWarn("LayoutCatalogue", "Cannot remove the partial extension download {1}.", Partial)
	_LayoutExtensionNext(State)
}

_LayoutExtensionStage(State) {
	Entry := State["entry"], Extension := Entry["extension"]
	Root := State["local"] . "extensions\" . Entry["id"] . "\" . Extension["sha256"] . "\" . Extension["id"] . "\"
	for Item in Extension["files"] {
		Path := Root . StrReplace(Item["path"], "/", "\")
		Text := State["content"][Item["path"]]
		if FileExist(Path) {
			if _LayoutRegistryReadText(Path) !== Text
				throw Error("Immutable extension content changed: " . Item["path"])
			continue
		}
		SplitPath(Path,, &Parent)
		DirCreate(Parent)
		_LayoutCatalogueWriteText(Path, Text)
	}
}
