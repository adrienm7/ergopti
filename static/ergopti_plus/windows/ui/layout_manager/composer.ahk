; ui/layout_manager/composer.ahk

; ==============================================================================
; MODULE: Layout Composer Host (Windows)
; DESCRIPTION:
; The Windows half of the per-layer layout composer (docs/layout-composer.md),
; hosted in the layout manager window: it sends the shared composer page the
; layouts it can compose from and the user's stored composition, and turns what
; the page saves into an installed layout of the reserved id `composed`, which
; the registry emulation then reads like any other installed layout.
;
; FEATURES & RATIONALE:
; 1. The page is never trusted: the declaration and the compiled .keylayout are
;    size-bounded, the declaration is checked field by field, and the layout is
;    read with the emulation's own reader (Keylayout_Parse) with every key of
;    every keyMap resolved, so a file the emulation would refuse never reaches
;    the installed record.
; 2. One installed-layout mechanism: the composition is recorded with an entry
;    built from the file (size, sha256, keycode convention), so the verified
;    local copy, the picker, the uninstall and the boot all work unchanged.
; 3. The declaration is stored first, then the layout installed: a failed
;    install leaves the composition editable, never a layout without its source.
; 4. Every collaborator is injectable, so tests replay an open, a save and a
;    removal without a window, a reload or the real configuration folder.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Version the composed layout's installed record carries. The composer rewrites
; the layout in place, so the record needs a version only for display.
global LAYOUT_COMPOSER_RECORD_VERSION := "1.0.0"

; The declaration's schema, the page's SCHEMA_VERSION (composer_model.js).
global LAYOUT_COMPOSER_SCHEMA_VERSION := 1

; The longest layout name the page accepts, in characters.
global LAYOUT_COMPOSER_MAX_NAME_LENGTH := 64

; Failure code of a composition this host refuses; the page words it.
global LAYOUT_COMPOSER_FAILURE_INVALID := "invalid"
global LAYOUT_COMPOSER_FAILURE_WRITE := "write_failed"
global LAYOUT_COMPOSER_FAILURE_USE := "use_failed"





; ================================
; ================================
; ======= 2/ What it reads =======
; ================================
; ================================

/**
 * Path of the stored declaration.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {string}
 */
LayoutComposer_DeclarationPath(ConfigDir) {
	return LayoutRegistry_ComposerDir(ConfigDir) . LayoutRegistry_Composer()["declaration_file"]
}

/**
 * The stored declaration's text, JSON_NULL when the user has none yet.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {string|Integer}
 * @throws {Error} When the file exists but cannot be read within its bound.
 */
LayoutComposer_ReadDeclaration(ConfigDir) {
	global JSON_NULL
	Path := LayoutComposer_DeclarationPath(ConfigDir)
	if !FileExist(Path)
		return JSON_NULL
	Text := FSReadBounded(Path, LayoutRegistry_Composer()["max_declaration_bytes"])
	if !(Text is String)
		throw Error("Cannot read the stored composition " . Path . " (unreadable or larger than its bound).")
	return Text
}

/**
 * The layouts the page can compose from: the registry layouts shipped with the
 * driver and those installed, each read through its checksum. A layout that
 * fails verification is logged and left out, never offered unverified.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @param {string} RegistryDir - Folder from LayoutRegistry_BundledDir.
 * @returns {Array} Maps with id, name, convention and text.
 */
LayoutComposer_Sources(LocalDir, RegistryDir := unset) {
	global LAYOUT_CATALOGUE_PLATFORM
	if !IsSet(RegistryDir)
		RegistryDir := LayoutRegistry_BundledDir()
	ComposedId := LayoutRegistry_Composer()["id"]
	Sources := []
	Seen := Map()
	Index := LayoutCatalogue_BundledIndex()
	if (Index is Map) && Index.Has("layouts") {
		for Entry in Index["layouts"] {
			Id := Entry["id"]
			if Id == ComposedId || !_LayoutComposer_Supports(Entry)
				continue
			try {
				Copy := LayoutRegistry_ReadBundled(Id, RegistryDir)
			} catch as Err {
				LoggerWarn("LayoutComposer", "The shipped '{1}' layout is not offered as a source: {2}", Id, Err.Message)
				continue
			}
			Sources.Push(_LayoutComposer_Source(Copy["Entry"], Copy["Text"]))
			Seen[Id] := true
		}
	}
	try Installed := LayoutCatalogue_ReadInstalled(LocalDir)
	catch as Err {
		LoggerWarn("LayoutComposer", "The installed layouts are not offered as sources: {1}", Err.Message)
		return Sources
	}
	for Id, Entry in Installed {
		if Id == ComposedId || Seen.Has(Id)
			continue
		try {
			Copy := LayoutRegistry_ReadLocal(Id, LocalDir)
		} catch as Err {
			LoggerWarn("LayoutComposer", "The installed '{1}' layout is not offered as a source: {2}", Id, Err.Message)
			continue
		}
		Sources.Push(_LayoutComposer_Source(Copy["Entry"], Copy["Text"]))
	}
	return Sources
}

_LayoutComposer_Supports(Entry) {
	global LAYOUT_CATALOGUE_PLATFORM
	if !Entry.Has("platforms") || !(Entry["platforms"] is Array)
		return false
	for Platform in Entry["platforms"]
		if Platform == LAYOUT_CATALOGUE_PLATFORM
			return true
	return false
}

_LayoutComposer_Source(Entry, Text) {
	Name := (Entry.Has("name") && Entry["name"] is String && Entry["name"] != "") ? Entry["name"] : Entry["id"]
	return Map("id", Entry["id"], "name", Name, "convention", Entry["keycode_convention"], "text", Text)
}

/**
 * The data the page opens the composer with.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @param {Func} SelectedFn - Returns the emulated layout's id.
 * @returns {Map}
 */
LayoutComposer_OpenData(ConfigDir, LocalDir, SelectedFn := KeylayoutEmulation_SelectedId) {
	global LAYOUT_CATALOGUE_PLATFORM
	return Map(
		"platform", LAYOUT_CATALOGUE_PLATFORM,
		"sources", LayoutComposer_Sources(LocalDir),
		"declaration", LayoutComposer_ReadDeclaration(ConfigDir),
		"active", SelectedFn.Call() == LayoutRegistry_Composer()["id"] ? 1 : 0,
		"shortcuts", "full"
	)
}





; =================================
; =================================
; ======= 3/ What it checks =======
; =================================
; =================================

/**
 * Checks what the page saves and builds the installed record's entry.
 * @param {string} DeclarationText - composition.json as the page wrote it.
 * @param {string} Keylayout - The compiled .keylayout.
 * @returns {Map} "declaration" (parsed) and "entry" (the record entry).
 * @throws {Error} With Extra "invalid" when the composition cannot be used.
 */
LayoutComposer_Check(DeclarationText, Keylayout) {
	global LAYOUT_COMPOSER_SCHEMA_VERSION, LAYOUT_COMPOSER_MAX_NAME_LENGTH, LAYOUT_COMPOSER_FAILURE_INVALID
	Refuse(Why) {
		throw Error(Why, -2, LAYOUT_COMPOSER_FAILURE_INVALID)
	}
	Composer := LayoutRegistry_Composer()
	if !(DeclarationText is String) || !(Keylayout is String)
		Refuse("The composition must be sent as text.")
	if StrPut(DeclarationText, "UTF-8") - 1 > Composer["max_declaration_bytes"]
		Refuse("The composition is larger than " . Composer["max_declaration_bytes"] . " bytes.")
	if StrPut(Keylayout, "UTF-8") - 1 > LayoutRegistry_Settings()["max_file_bytes"]
		Refuse("The compiled layout is larger than " . LayoutRegistry_Settings()["max_file_bytes"] . " bytes.")
	try Declaration := JsonParse(DeclarationText)
	catch
		Refuse("The composition is not valid JSON.")
	if !(Declaration is Map) || !Declaration.Has("schema_version")
			|| Declaration["schema_version"] != LAYOUT_COMPOSER_SCHEMA_VERSION
		Refuse("The composition has an unknown schema version.")
	Name := Declaration.Get("name", "")
	if !(Name is String) || Trim(Name) == "" || StrLen(Name) > LAYOUT_COMPOSER_MAX_NAME_LENGTH
			|| RegExMatch(Name, "[\x00-\x1F\x7F-\x9F]")
		Refuse("The layout name is empty, too long or holds control characters.")
	Convention := Declaration.Get("keycode_convention", "")
	try KeyCodes := KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), Convention)
	catch
		Refuse("The keycode convention is neither iso nor ansi.")
	try {
		Model := Keylayout_Parse(Keylayout)
		if Model["Name"] != Name
			Refuse("The compiled layout is not named after the composition.")
		if Model["MapSet"] != Composer["id"]
			Refuse("The compiled layout is not a composer product.")
		; Every key of every keyMap must resolve: an undefined action throws here
		; rather than at the first keystroke of the emulation.
		for Index in Model["KeyMapSets"][Model["MapSet"]]
			for , Code in KeyCodes
				Keylayout_Resolve(Model, Index, Code)
	} catch as Err {
		if Err.Extra == LAYOUT_COMPOSER_FAILURE_INVALID
			throw Err
		Refuse("The compiled layout cannot be read: " . Err.Message)
	}
	return Map("declaration", Declaration, "entry", LayoutComposer_Entry(Declaration, Keylayout))
}

/**
 * The installed record's entry of a composition.
 * @param {Map} Declaration - Parsed composition.
 * @param {string} Keylayout - The compiled .keylayout.
 * @returns {Map}
 */
LayoutComposer_Entry(Declaration, Keylayout) {
	global LAYOUT_COMPOSER_RECORD_VERSION
	Composer := LayoutRegistry_Composer()
	Id := Composer["id"]
	return Map(
		"id", Id,
		"name", Declaration["name"],
		"family", Composer["family"],
		"keyboard_name", Declaration["name"],
		"version", LAYOUT_COMPOSER_RECORD_VERSION,
		"file", Id . "/" . Id . ".keylayout",
		"sha256", CryptoSha256(Keylayout),
		"size", StrPut(Keylayout, "UTF-8") - 1,
		"keycode_convention", Declaration["keycode_convention"],
		"licence", "",
		"author", "",
		"homepage", ""
	)
}





; ===============================
; ===============================
; ======= 4/ What it does =======
; ===============================
; ===============================

; Replaces a file atomically: the text lands under a partial name first.
_LayoutComposer_WriteText(Path, Text) {
	global LAYOUT_REGISTRY_PARTIAL_SUFFIX
	Partial := Path . LAYOUT_REGISTRY_PARTIAL_SUFFIX
	SplitPath(Path, , &Parent)
	DirCreate(Parent)
	if !FSWrite(Partial, Text)
		throw Error("Cannot write " . Partial)
	if !FSAtomicMoveReplace(Partial, Path)
		throw Error("Cannot publish " . Path)
}

; The result the page shows, and the refreshed list behind it.
_LayoutComposer_Report(Deps, Action, Ok, Code := "", Detail := "", Used := false) {
	Deps["push"].Call("composerResult", Map("action", Action, "ok", Ok ? 1 : 0, "code", Code,
		"detail", Detail, "used", Used ? 1 : 0))
	Deps["push"].Call("updateState", LayoutManager_PageState(Deps["local_dir"]))
}

/**
 * Handles one composer message of the page.
 * @param {string} Action - composer_open, composer_save or composer_remove.
 * @param {Map} Payload - Decoded message.
 * @param {Map} Deps - "config_dir", "local_dir", "push", "selected", "select",
 *   "after", "install_local", "uninstall", "write_text", "delete"; the
 *   production ones by default.
 * @returns {boolean} Whether the message was accepted.
 */
LayoutComposer_Handle(Action, Payload, Deps) {
	global LAYOUT_COMPOSER_FAILURE_INVALID
	Deps := _LayoutComposer_Deps(Deps)
	if (Action == "composer_open") {
		try Data := LayoutComposer_OpenData(Deps["config_dir"], Deps["local_dir"], Deps["selected"])
		catch as Err {
			LoggerError("LayoutComposer", "The composer could not be opened: {1}", Err.Message)
			_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_INVALID, Err.Message)
			return true
		}
		Deps["push"].Call("composerData", Data)
		return true
	}
	if (Action == "composer_remove") {
		_LayoutComposer_Remove(Deps)
		return true
	}
	if !(Payload.Has("declaration") && Payload.Has("keylayout")) {
		LoggerWarn("LayoutComposer", "Refused a composer save without its declaration and layout.")
		return false
	}
	_LayoutComposer_Save(Deps, Payload["declaration"], Payload["keylayout"], Payload.Get("use", 0))
	return true
}

_LayoutComposer_Deps(Deps) {
	global _ConfigDir
	Defaults := Map(
		"config_dir", _ConfigDir,
		"local_dir", LayoutRegistry_LocalDir(_ConfigDir),
		"push", _LayMgrWeb_Push,
		"selected", KeylayoutEmulation_SelectedId,
		"select", LayoutManager_Select,
		"after", _LayMgrWeb_After,
		"install_local", LayoutCatalogue_InstallLocal,
		"uninstall", LayoutCatalogue_Uninstall,
		"write_text", _LayoutComposer_WriteText,
		"delete", FSDelete
	)
	if (Deps is Map)
		for Key, Value in Deps
			Defaults[Key] := Value
	return Defaults
}

_LayoutComposer_Save(Deps, DeclarationText, Keylayout, Use) {
	global LAYOUT_COMPOSER_FAILURE_INVALID, LAYOUT_COMPOSER_FAILURE_WRITE
	Action := "composer_save"
	LoggerStart("LayoutComposer", "Saving the composed layout…")
	try Checked := LayoutComposer_Check(DeclarationText, Keylayout)
	catch as Err {
		LoggerError("LayoutComposer", "The composition was refused: {1}", Err.Message)
		_LayoutComposer_Report(Deps, Action, false, Err.Extra != "" ? Err.Extra : LAYOUT_COMPOSER_FAILURE_INVALID,
			Err.Message)
		return
	}
	try Deps["write_text"].Call(LayoutComposer_DeclarationPath(Deps["config_dir"]), DeclarationText)
	catch as Err {
		LoggerError("LayoutComposer", "The composition could not be stored: {1}", Err.Message)
		_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_WRITE, Err.Message)
		return
	}
	try DirCreate(Deps["local_dir"])
	catch as Err {
		LoggerError("LayoutComposer", "The layouts folder could not be created: {1}", Err.Message)
		_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_WRITE, Err.Message)
		return
	}
	Deps["install_local"].Call(Checked["entry"], Deps["local_dir"], Keylayout,
		_LayoutComposer_OnInstalled.Bind(Deps, Use == 1 || Use == true))
}

_LayoutComposer_OnInstalled(Deps, Use, Ok, CodeOrDetail := "", Detail := "") {
	global LAYOUT_COMPOSER_FAILURE_USE
	Action := "composer_save"
	if !Ok {
		LoggerError("LayoutComposer", "The composed layout was not installed ({1}): {2}", CodeOrDetail, Detail)
		_LayoutComposer_Report(Deps, Action, false, String(CodeOrDetail), String(Detail))
		return
	}
	LoggerSuccess("LayoutComposer", "Saved the composed layout.")
	Id := LayoutRegistry_Composer()["id"]
	Selected := Deps["selected"].Call() == Id
	if Use && !Selected {
		; The selection writes the configuration and reloads: the emulation
		; registers its hotkeys at boot only.
		if !Deps["select"].Call(Id) {
			_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_USE, "the layout could not be selected")
			return
		}
		_LayoutComposer_Report(Deps, Action, true, "", "", true)
		return
	}
	if Selected {
		; The layout in use changed: reload so the emulation reads the new file.
		Reloaded(Accepted) {
			_LayoutComposer_Report(Deps, Action, Accepted, Accepted ? "" : LAYOUT_COMPOSER_FAILURE_USE, "", Accepted)
		}
		try Started := Deps["after"].Call(Id, "install", Reloaded)
		catch as Err {
			LoggerError("LayoutComposer", "Reloading the composed layout failed: {1}", Err.Message)
			Started := false
		}
		if !(Started is Integer) || Started != 1
			_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_USE, "the driver could not reload")
		return
	}
	_LayoutComposer_Report(Deps, Action, true)
}

_LayoutComposer_Remove(Deps) {
	global LAYOUT_COMPOSER_FAILURE_WRITE, LAYOUT_COMPOSER_FAILURE_USE
	Action := "composer_remove"
	Id := LayoutRegistry_Composer()["id"]
	LoggerStart("LayoutComposer", "Removing the composed layout…")
	try Installed := LayoutCatalogue_ReadInstalled(Deps["local_dir"])
	catch as Err {
		_LayoutComposer_Report(Deps, Action, false, "record_failed", Err.Message)
		return
	}
	if Installed.Has(Id) {
		Outcome := Deps["uninstall"].Call(Id, Deps["local_dir"])
		if !Outcome["ok"] {
			_LayoutComposer_Report(Deps, Action, false, Outcome.Get("code", ""), Outcome.Get("detail", ""))
			return
		}
	}
	Path := LayoutComposer_DeclarationPath(Deps["config_dir"])
	if FileExist(Path) && !Deps["delete"].Call(Path) {
		_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_WRITE, "cannot delete " . Path)
		return
	}
	if Deps["selected"].Call() == Id {
		; Back to the system layout, then reload without the composed layout.
		Reloaded(Accepted) {
			if Accepted
				LoggerSuccess("LayoutComposer", "Removed the composed layout.")
			else
				LoggerError("LayoutComposer", "The driver could not reload after the removal.")
			_LayoutComposer_Report(Deps, Action, Accepted, Accepted ? "" : LAYOUT_COMPOSER_FAILURE_USE)
		}
		try Started := Deps["after"].Call(Id, "uninstall", Reloaded)
		catch as Err {
			LoggerError("LayoutComposer", "Reloading after the removal failed: {1}", Err.Message)
			Started := false
		}
		if !(Started is Integer) || Started != 1
			_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_USE, "the driver could not reload")
		return
	}
	LoggerSuccess("LayoutComposer", "Removed the composed layout.")
	_LayoutComposer_Report(Deps, Action, true)
}
