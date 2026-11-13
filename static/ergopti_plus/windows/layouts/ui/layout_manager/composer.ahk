; layouts/ui/layout_manager/composer.ahk

; ==============================================================================
; MODULE: Layout Composer Host (Windows)
; DESCRIPTION:
; The Windows half of the per-layer layout composer (docs/design/layout-composer.md),
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
; 5. The layout editor's source form (docs/design/layout-editor.md « Windows
;    host »): composer_save with `source` stores the source, its .keylayout and
;    its emulation table in layout_composer\, stages the four DLL images the page
;    wrote and registers them through the elevated kbd_register.ahk (one UAC
;    prompt), then switches to the layout; composer_emulate stores the same
;    files and makes `composed` the emulated layout, with no admin right. One
;    composed layout exists at a time, so storing one form removes the other.
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
		Refuse("The composition has an unknown schema version.")
	Members := JsonObjectMemberSpans(DeclarationText)
	if Members["schema_version"]["kind"] != "number"
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

/**
 * A failure code the source form answers the page with (defaults.json [composer] failures).
 * @param {String} Name - install, elevation, foreign, profile, uninstall, emulate_not_saved or emulate.
 * @returns {String}
 * @throws {ValueError} For a name the shared defaults do not list.
 */
LayoutComposer_Failure(Name) {
	Failures := LayoutRegistry_Composer()["failures"]
	if !Failures.Has(Name)
		throw ValueError("Unknown layout composer failure.", -1, Name)
	return Failures[Name]
}

; A value of a decoded TOML document, Default when absent or of another type.
_LayoutComposer_TomlField(Document, Path, Default := "") {
	Read := _TOML_DocumentLookup(Document, StrSplit(Path, "."))
	if !Read["found"] || Type(Read["value"]) != Type(Default)
		return Default
	return Read["value"]
}

/**
 * Checks an Ergopti layout source and the .keylayout the page compiled from it:
 * the bounds, the format and version, the display name and that the layout is
 * the one the source names (composer.lua check_source). Every key of every
 * keyMap must resolve, as for a composition.
 * @param {String} SourceText - The TOML source as the page wrote it.
 * @param {String} Keylayout - The compiled (or, for a preserved import, the imported) .keylayout.
 * @returns {Map} name, keyboard_name, convention and document (the decoded source).
 * @throws {Error} With Extra "invalid" when the source cannot be used.
 */
LayoutComposer_CheckSource(SourceText, Keylayout) {
	global LAYOUT_COMPOSER_MAX_NAME_LENGTH, LAYOUT_COMPOSER_FAILURE_INVALID
	Refuse(Why) {
		throw Error(Why, -2, LAYOUT_COMPOSER_FAILURE_INVALID)
	}
	Composer := LayoutRegistry_Composer()
	if !(SourceText is String) || !(Keylayout is String)
		Refuse("The layout source must be sent as text.")
	if StrPut(SourceText, "UTF-8") - 1 > Composer["max_source_bytes"]
		Refuse("The layout source is larger than " . Composer["max_source_bytes"] . " bytes.")
	if StrPut(Keylayout, "UTF-8") - 1 > LayoutRegistry_Settings()["max_file_bytes"]
		Refuse("The compiled layout is larger than " . LayoutRegistry_Settings()["max_file_bytes"] . " bytes.")
	try Document := TOML_ParseDocument(SourceText)
	catch
		Refuse("The layout source is not valid TOML.")
	if _LayoutComposer_TomlField(Document, "format") != LayoutRegistry_Composer()["source_format"]
			|| _LayoutComposer_TomlField(Document, "version", 0) != LayoutRegistry_Composer()["source_version"]
		Refuse("The layout source has an unknown format or version.")
	Name := _LayoutComposer_TomlField(Document, "layout.name")
	if Trim(Name) == "" || StrLen(Name) > LAYOUT_COMPOSER_MAX_NAME_LENGTH || RegExMatch(Name, "[\x00-\x1F\x7F]")
		Refuse("The layout name is empty, too long or holds control characters.")
	if !LayoutRegistry_IsValidId(_LayoutComposer_TomlField(Document, "layout.id"))
		Refuse("The layout id is not a source identifier.")
	if !RegExMatch(Keylayout, "^<\?xml") || InStr(Keylayout, "<!ENTITY", true)
		Refuse("The compiled layout is not a plain .keylayout.")
	try Model := Keylayout_Parse(Keylayout)
	catch as Err
		Refuse("The compiled layout is not a readable .keylayout: " . Err.Message)
	; A preserved import is its own .keylayout; a structured source compiles to ISO
	; under its internal name (exports.macos.internal_name, else the layout id).
	Imported := _LayoutComposer_TomlField(Document, "imported_keylayout", Map())
	Convention := "iso", Expected := _LayoutComposer_TomlField(Document, "layout.id")
	if Imported.Count {
		if Imported.Get("text", "") !== Keylayout
			Refuse("The layout is not the source's imported .keylayout.")
		Convention := Imported.Get("convention", ""), Expected := Model["Name"]
	} else if _LayoutComposer_TomlField(Document, "exports.macos.internal_name") != "" {
		Expected := _LayoutComposer_TomlField(Document, "exports.macos.internal_name")
	}
	try KeyCodes := KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), Convention)
	catch
		Refuse("The keycode convention is neither iso nor ansi.")
	if Model["Name"] !== Expected
		Refuse("The compiled layout is not named after the source.")
	try {
		for Index in Model["KeyMapSets"][Model["MapSet"]]
			for , Code in KeyCodes
				Keylayout_Resolve(Model, Index, Code)
	} catch as Err {
		Refuse("The compiled layout cannot be read: " . Err.Message)
	}
	return Map("name", Name, "keyboard_name", Model["Name"], "convention", Convention, "document", Document)
}

/**
 * Checks the emulation table the page sends beside a source: the shared
 * compiler's table of that layout for Windows, which the engine compiles
 * (composer.lua check_emulation).
 * @param {String} EmulationText - The table's JSON.
 * @param {Map} Document - The decoded source (LayoutComposer_CheckSource).
 * @returns {Map} The decoded table.
 * @throws {Error} With Extra "invalid" when the table cannot be performed.
 */
LayoutComposer_CheckEmulation(EmulationText, Document) {
	global LAYOUT_COMPOSER_FAILURE_INVALID, LAYOUT_CATALOGUE_PLATFORM
	Refuse(Why) {
		throw Error(Why, -2, LAYOUT_COMPOSER_FAILURE_INVALID)
	}
	if !(EmulationText is String)
		Refuse("The emulation table must be sent as text.")
	Bound := LayoutRegistry_Composer()["max_emulation_bytes"]
	if StrPut(EmulationText, "UTF-8") - 1 > Bound
		Refuse("The emulation table is larger than " . Bound . " bytes.")
	try Table := JsonParse(EmulationText)
	catch
		Refuse("The emulation table is not valid JSON.")
	try SourceEmulation_Compile(Table)
	catch as Err
		Refuse("The emulation table cannot be performed: " . Err.Message)
	if Table.Get("layout", "") !== _LayoutComposer_TomlField(Document, "layout.id")
		Refuse("The emulation table is not the source's.")
	if Table.Get("platform", "") !== LAYOUT_CATALOGUE_PLATFORM
		Refuse("The emulation table is not compiled for " . LAYOUT_CATALOGUE_PLATFORM . ".")
	return Table
}

/**
 * Checks the Windows layout DLL images the page wrote for a source
 * (LayoutSourceIO.installPayload) before anything is elevated: the DLL name the
 * source's exports.windows names, and four images of at most 1 MiB each
 * starting with MZ.
 * @param {Map} Payload - The composer_save message.
 * @param {Map} Document - The decoded source.
 * @returns {Map} dll, text, lcid, company and images (arch -> Buffer).
 * @throws {Error} With Extra "invalid" when an image or a field is refused.
 */
LayoutComposer_CheckNative(Payload, Document) {
	global LAYOUT_COMPOSER_FAILURE_INVALID
	Refuse(Why) {
		throw Error(Why, -2, LAYOUT_COMPOSER_FAILURE_INVALID)
	}
	Dll := Payload.Get("dll_name", "")
	if !(Dll is String) || !RegExMatch(Dll, KbdRegister_Constant("dll_name"))
		Refuse("The DLL name is not a keyboard layout DLL name.")
	if Dll !== _LayoutComposer_TomlField(Document, "exports.windows.dll_name")
		Refuse("The DLL is not the one the source's exports.windows names.")
	LayoutId := _LayoutComposer_TomlField(Document, "exports.windows.layout_id")
	if !RegExMatch(LayoutId, "^[0-9A-Fa-f]{8}$")
		Refuse("The source's exports.windows.layout_id is not eight hexadecimal digits.")
	Company := _LayoutComposer_TomlField(Document, "exports.windows.company")
	if RegExMatch(Company, "[\x00-\x1F]")
		Refuse("The source's exports.windows.company is not one line of text.")
	Images := Map()
	Dlls := Payload.Get("dlls", 0)
	if !(Dlls is Map)
		Refuse("The message carries no DLL images.")
	for Arch in KbdRegister_Architectures() {
		if !(Dlls.Get(Arch, 0) is String) || Dlls[Arch] == ""
			Refuse("The " . Arch . " DLL image is missing.")
		Bytes := CryptoBase64Decode(Dlls[Arch])
		if Bytes.Size < 2 || Bytes.Size > KbdRegister_Constant("max_dll_bytes")
			Refuse("The " . Arch . " DLL image is empty or larger than 1 MiB.")
		if NumGet(Bytes, 0, "UChar") != 0x4D || NumGet(Bytes, 1, "UChar") != 0x5A
			Refuse("The " . Arch . " DLL image is not a Windows image.")
		Images[Arch] := Bytes
	}
	return Map("dll", Dll, "text", _LayoutComposer_TomlField(Document, "layout.name"),
		"lcid", StrLower(SubStr(LayoutId, 5)), "company", Company, "images", Images)
}

/**
 * The composed layout stored for the emulation alone: the stored source's
 * .keylayout copy, checked again as a save checks it (composer.lua read_composed),
 * since the files may have been edited by hand.
 * @param {String} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {Map|Integer} Text and Entry (keycode_convention, version, name), 0 when none is stored.
 * @throws {Error} When a stored copy cannot be read or is refused.
 */
LayoutComposer_ReadComposed(ConfigDir) {
	Composer := LayoutRegistry_Composer()
	Folder := LayoutRegistry_ComposerDir(ConfigDir)
	KeylayoutPath := Folder . Composer["keylayout_file"], SourcePath := Folder . Composer["source_file"]
	if !FileExist(KeylayoutPath)
		return 0
	Text := FSReadUtf8ExactBounded(KeylayoutPath, LayoutRegistry_Settings()["max_file_bytes"])
	Source := FileExist(SourcePath) ? FSReadUtf8ExactBounded(SourcePath, Composer["max_source_bytes"]) : false
	if !(Text is String) || !(Source is String)
		throw Error("The stored composed layout " . KeylayoutPath . " or its source is unreadable.")
	Checked := LayoutComposer_CheckSource(Source, Text)
	return Map("Text", Text, "Entry", Map("id", Composer["id"], "name", Checked["name"],
		"keycode_convention", Checked["convention"], "version", LAYOUT_COMPOSER_RECORD_VERSION))
}

/**
 * The emulation table stored beside the composed layout's source, decoded.
 * @param {String} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {Map|Integer} The table, 0 when none is stored.
 * @throws {Error} When a stored table is unreadable or not JSON.
 */
LayoutComposer_ReadEmulation(ConfigDir) {
	Composer := LayoutRegistry_Composer()
	Path := LayoutRegistry_ComposerDir(ConfigDir) . Composer["emulation_file"]
	if !FileExist(Path)
		return 0
	Text := FSReadUtf8ExactBounded(Path, Composer["max_emulation_bytes"])
	if !(Text is String)
		throw Error("The stored emulation table " . Path . " is unreadable or larger than its bound.")
	try Table := JsonParse(Text)
	catch
		throw Error("The stored emulation table " . Path . " is not JSON.")
	return Table
}





; ===============================
; ===============================
; ======= 4/ What it does =======
; ===============================
; ===============================

; Replaces a file atomically: the text lands under a partial name first.
_LayoutComposer_WriteText(Path, Text) {
	SplitPath(Path, , &Parent)
	DirCreate(Parent)
	_LayoutCatalogueWriteText(Path, Text)
}

; The result the page shows, and the refreshed list behind it.
_LayoutComposer_Report(Deps, Action, Ok, Code := "", Detail := "", Used := false) {
	Deps["push"].Call("composerResult", Map("action", Action, "ok", Ok ? 1 : 0, "code", Code,
		"detail", Detail, "used", Used ? 1 : 0))
	Deps["push"].Call("updateState", LayoutManager_PageState(Deps["local_dir"]))
}

/**
 * Handles one composer message of the page.
 * @param {string} Action - composer_open, composer_save, composer_emulate or composer_remove.
 * @param {Map} Payload - Decoded message.
 * @param {Map} Deps - "config_dir", "local_dir", "push", "selected",
 *   "select_settled", "after", "install_local", "uninstall", "write_text", "delete";
 *   for the source form "emulate_settled", "base_enabled", "staging_root",
 *   "write_bytes", "read_text", "registry" (the read-only ports of
 *   KbdRegister_Inspect), "self_env", "elevate" (Command) -> exit code and
 *   "activate" (Klid) -> Boolean; the production ones by default.
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
	; A save carries a composition (declaration) or a layout source, with its layout.
	Declaration := Payload.Get("declaration", 0) is String
	Source := Payload.Get("source", 0) is String
	if Declaration == Source || !(Payload.Get("keylayout", 0) is String) {
		LoggerWarn("LayoutComposer", "Refused a composer save without exactly one of a declaration or a source, and its layout.")
		return false
	}
	; A source may come with the emulation table the shared compiler built from it.
	if Payload.Has("emulation") && (!Source || !(Payload["emulation"] is String)) {
		LoggerWarn("LayoutComposer", "Refused a composer save whose emulation table is not text beside a source.")
		return false
	}
	if (Action == "composer_emulate") {
		if !Source {
			LoggerWarn("LayoutComposer", "Refused a layout emulation without its source.")
			return false
		}
		_LayoutComposer_Emulate(Deps, Payload)
		return true
	}
	if Source {
		_LayoutComposer_SaveSource(Deps, Payload, Payload.Get("use", 0) == 1)
		return true
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
		"select_settled", LayoutManager_SelectSettled,
		"after", _LayMgrWeb_After,
		"install_local", LayoutCatalogue_InstallLocal,
		"uninstall", LayoutCatalogue_Uninstall,
		"write_text", _LayoutComposer_WriteText,
		"delete", FSDelete,
		"emulate_settled", LayoutManager_EmulateSettled,
		"base_enabled", _LayoutComposer_BaseEnabled,
		"staging_root", AppFoldersRoot() . LayoutRegistry_Composer()["folder"] . "\" . LayoutRegistry_Composer()["dll_folder"] . "\",
		"write_bytes", LayoutInstallWriteStagedBytes,
		"read_text", (Path) => FSReadUtf8ExactBounded(Path, 65536),
		"registry", Map("reg_read", LayoutInstallRegRead64, "reg_subkeys", LayoutInstallRegSubkeys64),
		"self_env", KbdRegister_SelfEnv(),
		"elevate", LayoutInstallElevate,
		"activate", LayoutInstallActivate
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
	; The layout now comes from the composition: a stored source would reopen stale.
	Stale := _LayoutComposer_DeleteStale(Deps, ["source_file", "emulation_file", "keylayout_file"])
	if Stale != "" {
		_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_WRITE, "cannot delete " . Stale)
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
		; Launch acceptance is not use: the result is published once the
		; reload commits, or fails if the successor later refuses the handoff.
		Settled(SelectOk, SelectDetail := "") {
			_LayoutComposer_Report(Deps, Action, SelectOk, SelectOk ? "" : LAYOUT_COMPOSER_FAILURE_USE,
				SelectDetail, SelectOk)
		}
		try Deps["select_settled"].Call(Id, Settled)
		catch as Err {
			LoggerError("LayoutComposer", "Selecting the composed layout failed: {1}", Err.Message)
			Settled(false, "the layout could not be selected")
		}
		return
	}
	if Selected {
		; The layout in use changed: reload so the emulation reads the new file.
		; Prelaunch refusal completes the callback and returns false; both signals
		; must settle this save through the same terminal owner.
		Completed := false
		Reloaded(Accepted, FailureDetail := "") {
			if Completed
				return
			Completed := true
			_LayoutComposer_Report(Deps, Action, Accepted, Accepted ? "" : LAYOUT_COMPOSER_FAILURE_USE, FailureDetail, Accepted)
		}
		try Started := Deps["after"].Call(Id, "install", Reloaded)
		catch as Err {
			LoggerError("LayoutComposer", "Reloading the composed layout failed: {1}", Err.Message)
			Started := false
		}
		if !(Started is Integer) || Started != 1
			Reloaded(false, "the driver could not reload")
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
	; A source installed as a Windows layout is uninstalled first (one UAC prompt).
	Native := _LayoutComposer_UninstallNative(Deps)
	if Native["code"] != "" {
		_LayoutComposer_Report(Deps, Action, false, Native["code"], Native["detail"])
		return
	}
	if Installed.Has(Id) {
		Outcome := Deps["uninstall"].Call(Id, Deps["local_dir"])
		if !Outcome["ok"] {
			_LayoutComposer_Report(Deps, Action, false, Outcome.Get("code", ""), Outcome.Get("detail", ""))
			return
		}
	}
	Stale := _LayoutComposer_DeleteStale(Deps, ["declaration_file", "source_file", "emulation_file", "keylayout_file"])
	if Stale != "" {
		_LayoutComposer_Report(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_WRITE, "cannot delete " . Stale)
		return
	}
	if Deps["selected"].Call() == Id {
		; The choice is kept; reload without the composed layout (it is no longer emulated).
		Completed := false
		Reloaded(Accepted, FailureDetail := "") {
			if Completed
				return
			Completed := true
			if Accepted
				LoggerSuccess("LayoutComposer", "Removed the composed layout.")
			else
				LoggerError("LayoutComposer", "The driver could not reload after the removal.")
			_LayoutComposer_Report(Deps, Action, Accepted, Accepted ? "" : LAYOUT_COMPOSER_FAILURE_USE, FailureDetail)
		}
		try Started := Deps["after"].Call(Id, "uninstall", Reloaded)
		catch as Err {
			LoggerError("LayoutComposer", "Reloading after the removal failed: {1}", Err.Message)
			Started := false
		}
		if !(Started is Integer) || Started != 1
			Reloaded(false, "the driver could not reload")
		return
	}
	LoggerSuccess("LayoutComposer", "Removed the composed layout.")
	_LayoutComposer_Report(Deps, Action, true)
}





; ===================================
; ===================================
; ======= 5/ The source form ========
; ===================================
; ===================================

; Whether the base layer of the emulation is switched on ([layout] ergopti_base).
_LayoutComposer_BaseEnabled() {
	global Features
	if !IsSet(Features) || !Features.Has("layout")
		return false
	return Features["layout"].Get(ConfigLeaf.ERGOPTI_BASE, false) = true
}

; The result of the editor's source forms, with the JSON booleans the page reads.
_LayoutComposer_ReportSource(Deps, Action, Ok, Code := "", Detail := "", Used := false) {
	Deps["push"].Call("composerResult", Map("action", Action, "ok", LayMgrJsonBool_Of(Ok), "code", Code,
		"detail", Detail, "used", LayMgrJsonBool_Of(Used), "pending", LayMgrJsonBool_Of(false)))
	Deps["push"].Call("updateState", LayoutManager_PageState(Deps["local_dir"]))
}

; Deletes the composer files of the other form; returns the path that could not go.
_LayoutComposer_DeleteStale(Deps, Fields) {
	Composer := LayoutRegistry_Composer()
	for Field in Fields {
		Path := LayoutRegistry_ComposerDir(Deps["config_dir"]) . Composer[Field]
		if FileExist(Path) && !Deps["delete"].Call(Path) {
			LoggerError("LayoutComposer", "The replaced composition {1} could not be deleted.", Path)
			return Path
		}
	}
	return ""
}

; Stores a checked source with its .keylayout and emulation table, and removes
; the composition form: its declaration and its installed layout record.
_LayoutComposer_StoreSource(Deps, Payload) {
	global LAYOUT_COMPOSER_FAILURE_WRITE
	Composer := LayoutRegistry_Composer()
	Folder := LayoutRegistry_ComposerDir(Deps["config_dir"])
	Writes := [[Composer["source_file"], Payload["source"]], [Composer["keylayout_file"], Payload["keylayout"]]]
	if Payload.Has("emulation")
		Writes.Push([Composer["emulation_file"], Payload["emulation"]])
	for Write in Writes {
		try Deps["write_text"].Call(Folder . Write[1], Write[2])
		catch as Err
			throw Error(Err.Message, -1, LAYOUT_COMPOSER_FAILURE_WRITE)
	}
	Stale := _LayoutComposer_DeleteStale(Deps, Payload.Has("emulation") ? ["declaration_file"]
		: ["declaration_file", "emulation_file"])
	if Stale != ""
		throw Error("cannot delete " . Stale, -1, LAYOUT_COMPOSER_FAILURE_WRITE)
	; An installed composition would win over the stored source at the next boot.
	Installed := LayoutCatalogue_ReadInstalled(Deps["local_dir"])
	if Installed.Has(Composer["id"]) {
		Outcome := Deps["uninstall"].Call(Composer["id"], Deps["local_dir"])
		if !Outcome["ok"]
			throw Error(Outcome.Get("detail", "the replaced composition was not uninstalled"), -1,
				Outcome.Get("code", LAYOUT_COMPOSER_FAILURE_WRITE))
	}
}

/**
 * Runs one elevated registration and reads its result.json.
 * @param {Map} Deps - The composer's collaborators.
 * @param {Array} Words - "install" and the staging folder, or "uninstall", the DLL and the folder.
 * @param {String} Staging - The folder the helper writes result.json into.
 * @param {String} Failure - The code of a failure the helper reports without one.
 * @returns {Map} ok, code, detail and klid.
 */
_LayoutComposer_Register(Deps, Words, Staging, Failure) {
	ResultPath := Staging . "\result.json"
	if FileExist(ResultPath) && !Deps["delete"].Call(ResultPath)
		return Map("ok", false, "code", Failure, "detail", "cannot delete " . ResultPath, "klid", "")
	Command := KbdRegister_Command(Words, Deps["self_env"])
	LoggerInfo("LayoutComposer", "Asking Windows for the administrator right to {1} the keyboard layout…", Words[1])
	try ExitCode := Deps["elevate"].Call(Command)
	catch as Err {
		LoggerWarn("LayoutComposer", "The administrator prompt was refused: {1}", Err.Message)
		return Map("ok", false, "code", LayoutComposer_Failure("elevation"), "detail", Err.Message, "klid", "")
	}
	if ExitCode == KbdRegister_Constant("elevation_cancelled")
		return Map("ok", false, "code", LayoutComposer_Failure("elevation"), "detail", "the prompt was cancelled", "klid", "")
	Text := FileExist(ResultPath) ? Deps["read_text"].Call(ResultPath) : false
	try Result := (Text is String) ? JsonParse(Text) : 0
	catch
		Result := 0
	if !(Result is Map) || !Result.Has("ok")
		return Map("ok", false, "code", Failure, "detail", "the elevated helper exited with " . ExitCode . " and no result", "klid", "")
	Ok := Result["ok"] == 1 && ExitCode == 0
	Code := Result.Get("code", "")
	return Map("ok", Ok, "code", Ok ? Code : (Code != "" ? Code : Failure), "detail", Result.Get("detail", ""),
		"klid", Result.Get("klid", ""))
}

; Writes the four images and request.json; returns the staging folder.
_LayoutComposer_Stage(Deps, Native) {
	Staging := RTrim(Deps["staging_root"], "\") . "\" . Native["dll"]
	Digests := ""
	for Arch in KbdRegister_Architectures() {
		Bytes := Native["images"][Arch]
		Deps["write_bytes"].Call(Staging . "\" . Arch . "\" . Native["dll"] . ".dll", Bytes)
		Digests .= (A_Index > 1 ? "," : "") . JsonStringLiteral(Arch) . ":" . JsonStringLiteral(CryptoSha256Bytes(Bytes))
	}
	Deps["write_text"].Call(Staging . "\request.json", "{" . '"action":"install"'
		. ',"dll":' . JsonStringLiteral(Native["dll"]) . ',"text":' . JsonStringLiteral(Native["text"])
		. ',"lcid":' . JsonStringLiteral(Native["lcid"]) . ',"company":' . JsonStringLiteral(Native["company"])
		. ',"sha256":{' . Digests . "}}`n")
	return Staging
}

; « Install and use »: stores the source, registers its DLLs elevated, switches to it.
_LayoutComposer_SaveSource(Deps, Payload, Use) {
	global LAYOUT_COMPOSER_FAILURE_INVALID, LAYOUT_COMPOSER_FAILURE_WRITE
	global LAYOUT_COMPOSER_FAILURE_USE
	Action := "composer_save"
	LoggerStart("LayoutComposer", "Installing the layout source as a Windows keyboard layout…")
	try {
		Checked := LayoutComposer_CheckSource(Payload["source"], Payload["keylayout"])
		if Payload.Has("emulation")
			LayoutComposer_CheckEmulation(Payload["emulation"], Checked["document"])
		Native := LayoutComposer_CheckNative(Payload, Checked["document"])
	} catch as Err {
		LoggerError("LayoutComposer", "The layout source was refused: {1}", Err.Message)
		_LayoutComposer_ReportSource(Deps, Action, false, Err.Extra != "" ? Err.Extra : LAYOUT_COMPOSER_FAILURE_INVALID,
			Err.Message)
		return
	}
	try _LayoutComposer_StoreSource(Deps, Payload)
	catch as Err {
		LoggerError("LayoutComposer", "The layout source could not be stored: {1}", Err.Message)
		_LayoutComposer_ReportSource(Deps, Action, false, Err.Extra != "" ? Err.Extra : LAYOUT_COMPOSER_FAILURE_WRITE,
			Err.Message)
		return
	}
	; Someone else's layout already uses this DLL name: never ask to overwrite it.
	Seen := KbdRegister_Inspect(Native["dll"], Deps["registry"])
	if Seen["state"] == "foreign" {
		LoggerError("LayoutComposer", "The keyboard layout {1} already uses {2}.dll and is not Ergopti's.",
			Seen["klid"], Native["dll"])
		_LayoutComposer_ReportSource(Deps, Action, false, LayoutComposer_Failure("foreign"),
			"the keyboard layout " . Seen["klid"] . " already uses " . Native["dll"] . ".dll")
		return
	}
	try Staging := _LayoutComposer_Stage(Deps, Native)
	catch as Err {
		LoggerError("LayoutComposer", "The keyboard layout images could not be staged: {1}", Err.Message)
		_LayoutComposer_ReportSource(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_WRITE, Err.Message)
		return
	}
	Result := _LayoutComposer_Register(Deps, ["install", Staging], Staging, LayoutComposer_Failure("install"))
	if !Result["ok"] || Result["code"] == LayoutComposer_Failure("profile") {
		LoggerError("LayoutComposer", "The keyboard layout was not installed ({1}): {2}", Result["code"], Result["detail"])
		_LayoutComposer_ReportSource(Deps, Action, false, Result["code"], Result["detail"])
		return
	}
	LoggerSuccess("LayoutComposer", "Installed the keyboard layout {1} ({2}.dll).", Result["klid"], Native["dll"])
	if Use && !Deps["activate"].Call(Result["klid"]) {
		_LayoutComposer_ReportSource(Deps, Action, false, LAYOUT_COMPOSER_FAILURE_USE,
			"Windows did not load the keyboard layout " . Result["klid"])
		return
	}
	Id := LayoutRegistry_Composer()["id"]
	if Deps["selected"].Call() != Id {
		_LayoutComposer_ReportSource(Deps, Action, true, "", "", Use)
		return
	}
	; The emulated composed layout reads the files just stored at its next start.
	Completed := false
	Reloaded(Accepted, FailureDetail := "") {
		if Completed
			return
		Completed := true
		_LayoutComposer_ReportSource(Deps, Action, Accepted, Accepted ? "" : LAYOUT_COMPOSER_FAILURE_USE,
			FailureDetail, Accepted && Use)
	}
	try Started := Deps["after"].Call(Id, "install", Reloaded)
	catch as Err {
		LoggerError("LayoutComposer", "Reloading the composed layout failed: {1}", Err.Message)
		Started := false
	}
	if !(Started is Integer) || Started != 1
		Reloaded(false, "the driver could not reload")
}

; « Emulate without installing »: stores the source and makes `composed` the
; emulated layout ([layout] emulated_layout and ergopti_base), with no admin right.
_LayoutComposer_Emulate(Deps, Payload) {
	global LAYOUT_COMPOSER_FAILURE_INVALID, LAYOUT_COMPOSER_FAILURE_WRITE
	Action := "composer_emulate"
	LoggerStart("LayoutComposer", "Storing the layout source for the emulation…")
	try {
		Checked := LayoutComposer_CheckSource(Payload["source"], Payload["keylayout"])
		if Payload.Has("emulation")
			LayoutComposer_CheckEmulation(Payload["emulation"], Checked["document"])
	} catch as Err {
		LoggerError("LayoutComposer", "The layout source to emulate was refused: {1}", Err.Message)
		_LayoutComposer_ReportSource(Deps, Action, false, Err.Extra != "" ? Err.Extra : LAYOUT_COMPOSER_FAILURE_INVALID,
			Err.Message)
		return
	}
	try _LayoutComposer_StoreSource(Deps, Payload)
	catch as Err {
		LoggerError("LayoutComposer", "The layout source to emulate could not be stored: {1}", Err.Message)
		_LayoutComposer_ReportSource(Deps, Action, false, Err.Extra != "" ? Err.Extra : LAYOUT_COMPOSER_FAILURE_WRITE,
			Err.Message)
		return
	}
	Id := LayoutRegistry_Composer()["id"]
	Completed := false, Returned := false
	Settled(Ok, Detail := "") {
		if Completed
			return
		Completed := true
		if Ok
			LoggerSuccess("LayoutComposer", "Emulating the layout source.")
		; A refusal before the selection call returns never committed it; a later
		; one is the reload refusing the committed selection.
		Code := Ok ? "" : (Returned ? LayoutComposer_Failure("emulate") : LayoutComposer_Failure("emulate_not_saved"))
		_LayoutComposer_ReportSource(Deps, Action, Ok, Code, Detail, Ok)
	}
	if Deps["selected"].Call() == Id && Deps["base_enabled"].Call() {
		; Already the emulated layout: reload so the emulation reads the new files.
		Returned := true
		try Started := Deps["after"].Call(Id, "install", Settled)
		catch as Err {
			LoggerError("LayoutComposer", "Reloading the emulation failed: {1}", Err.Message)
			Started := false
		}
		if !(Started is Integer) || Started != 1
			Settled(false, "the driver could not reload")
		return
	}
	try Deps["emulate_settled"].Call(Id, Settled)
	catch as Err {
		LoggerError("LayoutComposer", "Selecting the emulated layout failed: {1}", Err.Message)
		Settled(false, "the layout emulation settings were not saved")
	}
	Returned := true
}

; The DLL name of the stored source's exports.windows, "" when none is stored.
_LayoutComposer_StoredDll(ConfigDir) {
	Composer := LayoutRegistry_Composer()
	Path := LayoutRegistry_ComposerDir(ConfigDir) . Composer["source_file"]
	if !FileExist(Path)
		return ""
	Text := FSReadUtf8ExactBounded(Path, Composer["max_source_bytes"])
	if !(Text is String)
		return ""
	try Document := TOML_ParseDocument(Text)
	catch
		return ""
	Dll := _LayoutComposer_TomlField(Document, "exports.windows.dll_name")
	return RegExMatch(Dll, KbdRegister_Constant("dll_name")) ? Dll : ""
}

; Uninstalls the Windows layout of the stored source when Ergopti installed it.
_LayoutComposer_UninstallNative(Deps) {
	Dll := _LayoutComposer_StoredDll(Deps["config_dir"])
	if Dll == "" || KbdRegister_Inspect(Dll, Deps["registry"])["state"] != "installed"
		return Map("code", "", "detail", "")
	Staging := RTrim(Deps["staging_root"], "\") . "\" . Dll
	try DirCreate(Staging)
	catch as Err
		return Map("code", LayoutComposer_Failure("uninstall"), "detail", Err.Message)
	Result := _LayoutComposer_Register(Deps, ["uninstall", Dll, Staging], Staging, LayoutComposer_Failure("uninstall"))
	if !Result["ok"] {
		LoggerError("LayoutComposer", "The keyboard layout {1}.dll was not uninstalled ({2}): {3}", Dll,
			Result["code"], Result["detail"])
		return Map("code", Result["code"], "detail", Result["detail"])
	}
	LoggerSuccess("LayoutComposer", "Uninstalled the keyboard layout {1} ({2}.dll).", Result["klid"], Dll)
	return Map("code", "", "detail", "")
}