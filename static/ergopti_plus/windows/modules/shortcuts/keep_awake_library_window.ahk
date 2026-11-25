; modules/shortcuts/keep_awake_library_window.ahk

; ==============================================================================
; MODULE: Anti-Sleep Library Window (Windows)
; DESCRIPTION:
; Hosts _shared/ui/keep_awake_library (bridge hsKeepAwake) on WebView2: the
; Windows twin of _shared/shortcuts/engine/keep_awake/library_host.lua. The
; page's first data, every edit of the presets document through the store
; (AutoClickEdit), « Ajouter un bouton… » through the region overlay and the
; screen vision worker, an image file converted by the worker, and the export
; and import of one preset with its images.
;
; FEATURES & RATIONALE:
; 1. The page strings, the edits it may ask for and the export format are
;    _shared/shortcuts/data/keep_awake_library.json, read by macOS and Linux
;    too, so the three windows answer the same protocol.
; 2. The switches are written as JSON booleans: a preset exported here
;    imports on macOS and Linux, whose store refuses 1 and 0.
; 3. A taken preset id or image name gets a fresh one, so an import never
;    overwrites a preset; a file that is not an exported preset is refused.
; ==============================================================================

#Requires AutoHotkey v2.0

class KeepAwakeLibraryOwner {
	static host := 0
	static data := 0
}

; The keys every presets document writes as JSON booleans.
KEEP_AWAKE_BOOLEAN_KEYS() {
	static Keys := Map("keep_awake", true, "auto_click", true, "enabled", true, "ok", true)
	return Keys
}




; ==================================
; ==================================
; ======= 1/ JSON ==================
; ==================================
; ==================================

; Encodes a presets value, the boolean keys as true and false.
KeepAwakeLibraryJson(Value, Key := "") {
	if Value is Map {
		Parts := ""
		for Name, Item in Value
			Parts .= (Parts == "" ? "" : ",") . JsonStringLiteral(String(Name)) . ":" . KeepAwakeLibraryJson(Item, Name)
		return "{" . Parts . "}"
	}
	if Value is Array {
		Parts := ""
		for Item in Value
			Parts .= (Parts == "" ? "" : ",") . KeepAwakeLibraryJson(Item)
		return "[" . Parts . "]"
	}
	if KEEP_AWAKE_BOOLEAN_KEYS().Has(Key) && (Value is Integer)
		return Value ? "true" : "false"
	if (Value is Integer) || (Value is Float)
		return String(Value)
	return JsonStringLiteral(String(Value))
}

_KALData() {
	if !IsObject(KeepAwakeLibraryOwner.data)
		KeepAwakeLibraryOwner.data := _AutoClickShared("shortcuts\data\keep_awake_library.json")
	return KeepAwakeLibraryOwner.data
}




; ==================================
; ==================================
; ======= 2/ Page ==================
; ==================================
; ==================================

; Opens the window, or focuses the open one (the « Anti-veille » menu row).
KeepAwakeLibraryOpen(*) {
	Host := WebViewHost.TryOpen("keep_awake_library", Map("RunsWhilePaused", true,
		"OnMessage", (H, Message) => _KALMessage(H, Message)))
	if !IsObject(Host) {
		LoggerWarn("KeepAwakeLibrary", "The anti-sleep library window could not be opened.")
		return false
	}
	KeepAwakeLibraryOwner.host := Host
	return true
}

_KALPush(Host, Name, Payload) {
	try Host.Eval("if(window." . Name . ") window." . Name . "(" . KeepAwakeLibraryJson(Payload) . ")")
}

; Every library image of the document as base64 PNG, for the thumbnails.
_KALThumbnails(Doc) {
	AutoClickLibraryPaths(&Folder, &Images, &Index)
	Out := Map()
	for Preset in Doc["presets"]
		for Image in Preset["images"] {
			Path := Images . "\" . Image["file"]
			if Out.Has(Image["file"]) || !FileExist(Path)
				continue
			try Out[Image["file"]] := CryptoBase64Encode(FSReadBytesStrict(Path))
		}
	return Out
}

_KALPushDoc(Host, Extra := 0) {
	Doc := AutoClickDocument()
	Payload := Map("doc", Doc, "thumbnails", _KALThumbnails(Doc))
	if IsObject(Extra)
		for Key, Value in Extra
			Payload[Key] := Value
	_KALPush(Host, "onDoc", Payload)
}

_KALReady(Host) {
	Strings := Map()
	for Name in _KALData()["page_keys"]
		Strings["keepawake.library." . Name] := t("keepawake.library." . Name)
	for Preset in _AutoClickShared("shortcuts\data\keep_awake_presets.json")["presets"]
		Strings[Preset["name_key"]] := t(Preset["name_key"])
	Doc := AutoClickDocument()
	_KALPush(Host, "initData", Map("strings", Strings, "os", "windows",
		"defaults", _AutoClickShared("shortcuts\data\auto_click_defaults.json"), "doc", Doc,
		"thumbnails", _KALThumbnails(Doc)))
}

; The store function of each edit the page may ask for.
_KALEditFn(Op) {
	static Fns := Map("set_active", KeepAwakePresetsSetActive, "set_switch", KeepAwakePresetsSetSwitch,
		"duplicate", KeepAwakePresetsDuplicate, "rename", KeepAwakePresetsRename, "remove", KeepAwakePresetsRemove,
		"set_apps", KeepAwakePresetsSetApps, "put_target", KeepAwakePresetsPutTarget,
		"remove_target", KeepAwakePresetsRemoveTarget, "add", KeepAwakePresetsAdd)
	return Fns.Has(Op) ? Fns[Op] : 0
}

_KALEdit(Host, Op, Args) {
	Edits := _KALData()["edits"]
	Fn := _KALEditFn(Op)
	if !Edits.Has(Op) || !IsObject(Fn) || !(Args is Array) || Args.Length != Edits[Op] {
		LoggerWarn("KeepAwakeLibrary", "The library window asked for an edit it may not make: {1}.", Op)
		return _KALPushDoc(Host, Map("ok", false, "reason", "invalid_request"))
	}
	Ok := AutoClickEdit(Fn, Args*)
	_KALPushDoc(Host, Map("ok", Ok ? true : false))
}




; ==================================
; ==================================
; ======= 3/ Images ================
; ==================================
; ==================================

; A fresh id from a base, unique among Taken (a Func answering true for a taken id).
KeepAwakeLibraryFreshId(Base, Taken) {
	Stem := SubStr(RegExReplace(String(Base), "[^A-Za-z0-9_\-]", "_"), 1, 48)
	if (Stem == "")
		Stem := "item"
	if !Taken.Call(Stem)
		return Stem
	N := 2
	while Taken.Call(Stem . "_" . N)
		N += 1
	return Stem . "_" . N
}

_KALIsPng(Bytes) {
	return IsObject(Bytes) && Bytes.Size >= 8 && NumGet(Bytes, 0, "UInt") == 0x474E5089
}

; Keeps a PNG as a new image target of a preset.
_KALKeepImage(Host, PresetId, Path, Base) {
	try Bytes := FSReadBytesStrict(Path)
	try FileDelete(Path)
	if !IsSet(Bytes) || !_KALIsPng(Bytes)
		return _KALPush(Host, "onImage", Map("ok", false, "reason", "import_failed"))
	Doc := AutoClickDocument()
	Used := Map()
	for Preset in Doc["presets"]
		for Kind in ["images", "texts"]
			for Target in Preset[Kind]
				Used[Target["id"]] := true
	Id := KeepAwakeLibraryFreshId(Base, (Candidate) => Used.Has(Candidate))
	AutoClickLibraryPaths(&Folder, &Images, &Index)
	try {
		DirCreate(Images)
		FSWriteBytesStrict(Images . "\" . Id . ".png", Bytes)
	} catch as Err {
		LoggerError("KeepAwakeLibrary", "The library image could not be written: {1}.", Err.Message)
		return _KALPush(Host, "onImage", Map("ok", false, "reason", "presets_write_failed"))
	}
	Ok := AutoClickEdit(KeepAwakePresetsPutTarget, PresetId, "images",
		Map("id", Id, "file", Id . ".png", "enabled", 1))
	LoggerInfo("KeepAwakeLibrary", "Library image {1} added to preset {2}.", Id, PresetId)
	_KALPush(Host, "onImage", Map("ok", Ok ? true : false, "id", Id))
	_KALPushDoc(Host)
}

_KALAddImage(Host, PresetId, Source) {
	AutoClickVision()
	if (Source == "capture") {
		Started := RegionSelect((Rect, Reason) => IsObject(Rect)
			? ScreenVisionCaptureRegion(Rect, (Image, Why) => IsObject(Image)
				? _KALKeepImage(Host, PresetId, Image["source"], "button")
				: _KALPush(Host, "onImage", Map("ok", false, "reason", Why)))
			: _KALPush(Host, "onImage", Map("ok", false, "reason", Reason)))
		if !Started
			_KALPush(Host, "onImage", Map("ok", false, "reason", "capture_unavailable"))
		return
	}
	Picked := Ui_FileSelect(1 + 2, "", t("keepawake.library.import_image"),
		"Images (*.png; *.jpg; *.jpeg; *.gif; *.bmp; *.tif; *.tiff; *.webp; *.heic)")
	if (Picked == "")
		return _KALPush(Host, "onImage", Map("ok", false, "reason", "cancelled"))
	Out := A_Temp . "\ergopti-import-" . A_TickCount . ".png"
	ScreenVisionImport(Picked, Out, (Answer, Reason := "") => IsObject(Answer)
		? _KALKeepImage(Host, PresetId, Out, "image")
		: _KALPush(Host, "onImage", Map("ok", false, "reason", Reason)))
}




; ==================================
; ==================================
; ======= 4/ Preset files ==========
; ==================================
; ==================================

_KALExport(Host, PresetId) {
	Preset := KeepAwakePresetsGet(AutoClickDocument(), PresetId)
	if !IsObject(Preset)
		return _KALPush(Host, "onExported", Map("ok", false, "reason", "preset_unknown"))
	AutoClickLibraryPaths(&Folder, &Images, &Index)
	Encoded := Map()
	for Image in Preset["images"]
		try Encoded[Image["file"]] := CryptoBase64Encode(FSReadBytesStrict(Images . "\" . Image["file"]))
	Path := Ui_FileSelect("S16", A_MyDocuments . "\" . Preset["id"] . ".json", t("keepawake.library.export"),
		"JSON (*.json)")
	if (Path == "")
		return
	Data := _KALData()
	Text := KeepAwakeLibraryJson(Map("format", Data["export_format"], "version", Data["export_version"],
		"preset", Preset, "images", Encoded))
	try {
		if FileExist(Path)
			FileDelete(Path)
		FileAppend(Text, Path, "UTF-8-RAW")
		Ok := true
	} catch as Err {
		LoggerError("KeepAwakeLibrary", "The preset export could not be written: {1}.", Err.Message)
		Ok := false
	}
	LoggerInfo("KeepAwakeLibrary", "Preset {1} exported with {2} image(s).", Preset["id"], Preset["images"].Length)
	_KALPush(Host, "onExported", Map("ok", Ok, "reason", Ok ? "" : "presets_write_failed"))
}

_KALImport(Host) {
	Path := Ui_FileSelect(1 + 2, "", t("keepawake.library.import"), "JSON (*.json)")
	if (Path == "")
		return
	Data := _KALData()
	try Imported := JsonParse(FileRead(Path, "UTF-8"))
	if !IsSet(Imported) || !(Imported is Map) || Imported.Get("format", "") != Data["export_format"]
		|| Imported.Get("version", 0) != Data["export_version"] || !(Imported.Get("preset", 0) is Map)
		|| !(Imported.Get("images", 0) is Map) {
		LoggerWarn("KeepAwakeLibrary", "The preset file is not an exported anti-sleep preset.")
		return _KALPush(Host, "onImported", Map("ok", false, "reason", "presets_document_invalid"))
	}
	Preset := Imported["preset"]
	Invalid := KeepAwakePresetInvalid(Preset)
	if (Invalid != "")
		return _KALPush(Host, "onImported", Map("ok", false, "reason", Invalid))
	Doc := AutoClickDocument()
	Preset["id"] := KeepAwakeLibraryFreshId(Preset["id"], (Id) => IsObject(KeepAwakePresetsGet(Doc, Id)))
	AutoClickLibraryPaths(&Folder, &Images, &Index)
	for Image in Preset["images"] {
		Encoded := Imported["images"].Get(Image["file"], "")
		Bytes := Encoded == "" ? 0 : CryptoBase64Decode(Encoded)
		if !_KALIsPng(Bytes)
			return _KALPush(Host, "onImported", Map("ok", false, "reason", "presets_document_invalid"))
		Stem := KeepAwakeLibraryFreshId(Preset["id"] . "_" . Image["id"],
			(Candidate) => FileExist(Images . "\" . Candidate . ".png") != "")
		try {
			DirCreate(Images)
			FSWriteBytesStrict(Images . "\" . Stem . ".png", Bytes)
		} catch
			return _KALPush(Host, "onImported", Map("ok", false, "reason", "presets_write_failed"))
		Image["file"] := Stem . ".png"
	}
	Added := AutoClickEdit(KeepAwakePresetsAdd, Preset)
	LoggerInfo("KeepAwakeLibrary", "Preset file imported as {1}.", Preset["id"])
	_KALPush(Host, "onImported", Map("ok", Added ? true : false, "id", Preset["id"]))
	_KALPushDoc(Host)
}




; ==================================
; ==================================
; ======= 5/ Messages ==============
; ==================================
; ==================================

_KALMessage(Host, Message) {
	Action := Message.Get("action", "")
	switch Action {
		case "ready": return _KALReady(Host)
		case "edit": return _KALEdit(Host, Message.Get("op", ""), Message.Get("args", 0))
		case "add_image": return _KALAddImage(Host, Message.Get("preset", ""), Message.Get("source", ""))
		case "export": return _KALExport(Host, Message.Get("preset", ""))
		case "import": return _KALImport(Host)
		case "close": return Host.Close()
	}
	LoggerWarn("KeepAwakeLibrary", "The library window sent an unknown action '{1}'.", Action)
}
