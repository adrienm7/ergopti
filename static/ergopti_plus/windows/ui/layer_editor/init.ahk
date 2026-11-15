; ui/layer_editor/init.ahk

; ==============================================================================
; MODULE: Navigation Layer Editor (Windows host)
; DESCRIPTION:
; Shows the shared navigation layer editor (_shared/ui/layer_editor) in a
; WebView2 window through the manifest-driven WebViewHost factory, answers its
; "ready" with the user's layers.toml, the legends of the layout the user types
; with and the key whose hold enters the layer, and saves what it sends through
; the window-free platform/remap/nav_layer_save.ahk, which the layout editor's
; « Apply the navigation layer » calls too; this host only adds the page's
; exact opening source and its answers.
;
; FEATURES & RATIONALE:
; 1. The page offers only what exists on Windows; the save still refuses any
;    text one of the three OS loaders would reject or drop.
; 2. The layer is registered once per process (nav_layer_table.ahk), so a saved
;    layer applies through the pause-preserving reload every setting uses.
; 3. Legends: a key that types a character (the registry sends it by scan
;    code, ahk_send null) shows what the layout emulation types there
;    unshifted (a registry layout, the digit row, the Ergopti base layer read
;    from its .keylayout), else what the layout the user types with (the
;    driver's one resolver, KS_ResolveKeyboardLayout) types on its scan code,
;    read through ToUnicodeEx without touching the dead-key state. A key left
;    without a printable character shows its registry code on the page, and
;    the reason is logged once (_shared/tests/corpus/layer_editor/legends.json).
;    The page asks again when its window comes back to the front.
; 4. The layer key is the tap-hold key whose hold enters NAV_LAYER_ID in the
;    retained tap-hold configuration (MasterGateDesiredTapHold).
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk

; The shared page's id in _shared/ui/apps.manifest.json.
global LAYER_EDITOR_APP_ID := "layer_editor"
global LAYER_EDITOR_OS := "windows"
; Where the legends were read, the Lua hosts' LEGEND_SOURCE_* (pinned by the suite).
global LAYER_EDITOR_LEGEND_SOURCE_EMULATION := "emulation"
global LAYER_EDITOR_LEGEND_SOURCE_OS := "os"

; Tap-hold key id (the ahk column of [tap_hold.catalog]) -> the registry code of
; that physical key. The Windows remap files name their keys by literal scan
; codes, so this is the one table that ties the two vocabularies;
; tools/test/test-layer-editor-legends.cjs holds it to the catalogue and, through
; the Linux engine's evdev codes, to the registry.
global LAYER_EDITOR_TAP_HOLD_KEY_CODES := Map(
	"escape", "Escape", "tab", "Tab", "caps_lock", "CapsLock", "left_shift", "ShiftLeft",
	"left_ctrl", "ControlLeft", "win", "MetaLeft", "left_alt", "AltLeft", "space", "Space",
	"alt_gr", "AltRight", "right_ctrl", "ControlRight", "right_shift", "ShiftRight",
	"enter", "Enter", "backspace", "Backspace", "delete", "Delete"
)

; The OS calls a legend needs, all in platform/input/key_state.ahk: the layout the
; user types with now, a scan code's virtual key on it, and what that key types
; unshifted there, read without arming a dead key. The unit suite passes a fake.
global _LayerEditorOsProbe := {
	Hkl: KS_ResolveKeyboardLayout,
	ScToVk: KS_ScancodeToVk,
	ToUnicode: KS_KeyTextNoStateChange,
}

; The unresolved-legend reports already logged, by signature: the reason is said
; once, not at every window.
global _LayerEditorReported := Map()





; ==========================
; ==========================
; ======= 1/ Legends =======
; ==========================
; ==========================

/**
 * A layout's character as a key legend.
 * @param {Any} Text - What the layout types on a key.
 * @returns {string} Text itself; "" when it is not a string, is empty or blank,
 *   or holds a control character (C0, DEL or C1).
 */
LayerEditor_LegendText(Text) {
	if !(Text is String) || (Text == "")
		return ""
	if RegExMatch(Text, "[\x{00}-\x{1F}\x{7F}-\x{9F}]")
		return ""
	if (RegExReplace(Text, "[\s\x{A0}\x{202F}]") == "")
		return ""
	return Text
}

/**
 * The layout emulation in force now, as the legends read it.
 * @returns {Map} "active" (a base layer is emulated) and "character", a Func
 *   taking a scan code name ("SC010") and giving what the emulation types
 *   there unshifted, "" for a key it leaves to the OS layout.
 */
LayerEditor_CurrentEmulation() {
	global Features
	Layout := (IsSet(Features) && Features is Map && Features.Has("layout")) ? Features["layout"] : Map()
	Registry := KeylayoutEmulation_LayerIsActive(ConfigLeaf.ERGOPTI_BASE)
	Ergopti := !Registry && Layout.Get(ConfigLeaf.ERGOPTI_BASE, false) == true
	; The ordering in effect: a stored choice that is inert on this layout types
	; nothing. A registry layout types its own « symbols first » levels.
	Mode := NumberRowEffectiveMode()
	Ordering := Mode == "digits" ? true : Mode == "symbols" && !Registry ? "symbols" : false
	return Map("active", Registry || Ergopti || Ordering == "symbols",
		"character", _LayerEditor_EmulatedCharacter.Bind(Registry, Ergopti, Ordering))
}

; What the emulation types unshifted on scan code Sc, in the order its hotkeys
; win: the digit row (direct_access_digits, over any layout), a registry layout
; (keylayout_emulation.ahk), then the Ergopti base layer, whose characters and
; dead keys come from its .keylayout (layout_ergopti.ahk).
; Digits: true for « digits first », "symbols" for « symbols first » on a row
; no registry layout owns, false otherwise.
_LayerEditor_EmulatedCharacter(Registry, Ergopti, Digits, Sc) {
	global KLE_Model, KLE_LevelIndex, KLE_KeyCodes, KS_DIGIT_ROW_KEYS, ERGOPTI_NUMBER_ROW
	Code := Integer("0x" . SubStr(Sc, 3))
	; « Also reorder the three edge keys » types the other level.
	Edge := NumberRowEdgeText(Code, false, NumberRowForegroundLayout(), false)
	if Edge != ""
		return Edge
	if (Digits is String) && Digits == "symbols" {
		Text := NumberRowSymbolsFirstText(Code, false, NumberRowForegroundLayout(), false)
		if Text != ""
			return Text
	} else if Digits {
		for _, Key in KS_DIGIT_ROW_KEYS {
			if (Key[2] == Code)
				return Chr(Key[1])
		}
	}
	; A row switched off is the OS layout's (LayoutRowIsEmulated).
	if !LayoutRowIsEmulated(Sc)
		return ""
	if Registry {
		Shift := false
		if NumberRowEffectiveMode() == "symbols" && NumberRowSymbolsCapable(false) {
			Level := NumberRowSymbolsLevel(Code, false)
			if Level["supported"]
				Shift := Level["shift"]
		}
		return KLE_KeyCodes.Has(Sc) ? Keylayout_Resolve(KLE_Model,
			KLE_LevelIndex[_KLE_ComboKey(Shift, false, false)], KLE_KeyCodes[Sc])["Text"] : ""
	}
	if !Ergopti
		return ""
	Spec := ErgoptiLayout_Spec()
	Base := Spec["levels"]["base"]
	; The number row types the Ergopti row (RegisterBuiltinNumberRow).
	if !Base.Has(Sc) && ERGOPTI_NUMBER_ROW.Has(Sc)
		Base := Spec["number_row_base"]
	if !Base.Has(Sc)
		return ""
	Descriptor := Base[Sc]
	if Descriptor.Has("text")
		return Descriptor["text"]
	return Descriptor.Has("dead") ? Spec["terminators"][Descriptor["dead"]] : ""
}

/**
 * The legends of every key that types a character.
 * @param {Map} Ctx - The loader context.
 * @param {Map} Emulation - From LayerEditor_CurrentEmulation.
 * @param {Object} Probe - The OS calls; _LayerEditorOsProbe by default.
 * @returns {Map} "source", "keys" (registry code -> legend), "unresolved"
 *   (the codes left without one, in registry-code order) and "reason".
 */
LayerEditor_Legends(Ctx, Emulation, Probe := "") {
	global _LayerEditorOsProbe, LAYER_EDITOR_LEGEND_SOURCE_EMULATION, LAYER_EDITOR_LEGEND_SOURCE_OS
	if !IsObject(Probe)
		Probe := _LayerEditorOsProbe
	Hkl := Probe.Hkl.Call()
	Keys := Map()
	Unresolved := []
	for Code, Entry in Ctx["keys"] {
		; A named key's ahk_send is its Send name; a character key's is null.
		if (Entry["kind"] != "key") || (Entry["ahk_send"] is String)
			continue
		Sc := Entry["ahk"]
		Text := Emulation["character"].Call(Sc)
		if (Text == "") && (Hkl != 0) {
			ScCode := Integer("0x" . SubStr(Sc, 3))
			Vk := Probe.ScToVk.Call(ScCode, Hkl)
			if Vk
				Text := Probe.ToUnicode.Call(Vk, ScCode, Hkl).Text
		}
		Text := LayerEditor_LegendText(Text)
		if (Text == "")
			Unresolved.Push(Code)
		else
			Keys[Code] := Text
	}
	return Map(
		"source", Emulation["active"] ? LAYER_EDITOR_LEGEND_SOURCE_EMULATION : LAYER_EDITOR_LEGEND_SOURCE_OS,
		"keys", Keys,
		"unresolved", Unresolved,
		"reason", (Hkl == 0) ? "no keyboard layout could be read"
			: Format("the keyboard layout 0x{:08X} types nothing printable there", Hkl & 0xFFFFFFFF))
}

/**
 * Says once why keys show their registry code instead of a legend.
 * @param {Map} Legends - From LayerEditor_Legends.
 * @returns {Boolean} True when this call logged.
 */
LayerEditor_ReportUnresolved(Legends) {
	global _LayerEditorReported
	if (Legends["unresolved"].Length == 0)
		return false
	Codes := ""
	for Index, Code in Legends["unresolved"]
		Codes .= (Index == 1 ? "" : ", ") . Code
	Signature := Codes . "|" . Legends["reason"]
	if _LayerEditorReported.Has(Signature)
		return false
	_LayerEditorReported[Signature] := true
	LoggerWarn("LayerEditor", "{1} key(s) show their registry code, not a legend ({2}): {3}.",
		Legends["unresolved"].Length, Codes, Legends["reason"])
	return true
}

/**
 * The legends of the layout in force now, reported when some are missing.
 * @param {Map} Ctx - The loader context.
 * @returns {Map} From LayerEditor_Legends.
 */
LayerEditor_CurrentLegends(Ctx) {
	Legends := LayerEditor_Legends(Ctx, LayerEditor_CurrentEmulation())
	LayerEditor_ReportUnresolved(Legends)
	return Legends
}

/**
 * The registry codes of the keys whose hold enters the navigation layer.
 * @param {Map} TapHoldSource - A tap-hold configuration (LoadTapHoldToml's shape).
 * @returns {Array} Codes in tap-hold id order.
 */
LayerEditor_LayerKeys(TapHoldSource) {
	global LAYER_EDITOR_TAP_HOLD_KEY_CODES, NAV_LAYER_ID
	Codes := []
	for Id, Code in LAYER_EDITOR_TAP_HOLD_KEY_CODES {
		if (TapHoldHoldLayer(TapHoldSource, Id) == NAV_LAYER_ID)
			Codes.Push(Code)
	}
	return Codes
}

; The layer keys of the retained tap-hold configuration.
_LayerEditor_CurrentLayerKeys() {
	global TapHold
	return LayerEditor_LayerKeys(MasterGateDesiredTapHold(IsSet(TapHold) ? TapHold : Map("keys", Map())))
}





; =======================================
; =======================================
; ======= 2/ Messages to the page =======
; =======================================
; =======================================

; One error Map as a JSON object.
_LayerEditor_ErrorJson(Err) {
	Parts := []
	for Field in ["code", "layer", "section", "key", "detail", "reason_key"] {
		if Err.Has(Field) && Err[Field] != ""
			Parts.Push(JsonStringLiteral(Field) . ":" . JsonStringLiteral(String(Err[Field])))
	}
	Out := "{"
	for Index, Part in Parts
		Out .= (Index == 1 ? "" : ",") . Part
	return Out . "}"
}

_LayerEditor_ErrorsJson(Errors) {
	Out := "["
	for Index, Err in Errors
		Out .= (Index == 1 ? "" : ",") . _LayerEditor_ErrorJson(Err)
	return Out . "]"
}

; Legends as the page's `legends` object: {source, keys: {code: legend}}.
_LayerEditor_LegendsJson(Legends) {
	Out := '{"source":' . JsonStringLiteral(Legends["source"]) . ',"keys":{'
	First := true
	for Code, Text in Legends["keys"] {
		Out .= (First ? "" : ",") . JsonStringLiteral(Code) . ":" . JsonStringLiteral(Text)
		First := false
	}
	return Out . "}}"
}

; A list of strings as a JSON array.
_LayerEditor_StringsJson(Values) {
	Out := "["
	for Index, Value in Values
		Out .= (Index == 1 ? "" : ",") . JsonStringLiteral(Value)
	return Out . "]"
}

/**
 * The page's init() call: the OS, the file's path and text, every problem any
 * OS's loader finds in it, the legends and the layer keys.
 * @param {Map} Ctx - The loader context.
 * @param {string} ConfigDir - The configuration folder.
 * @param {Map} Legends - From LayerEditor_Legends; the layout in force by default.
 * @param {Array} LayerKeys - From LayerEditor_LayerKeys; the retained tap-holds' by default.
 * @param {Object|Integer} Opening - The captured GUI source, or zero to read the file directly.
 * @returns {string} JavaScript to evaluate in the page.
 */
LayerEditor_InitJs(Ctx, ConfigDir, Legends := "", LayerKeys := "", Opening := 0) {
	global LAYER_EDITOR_OS, NAV_LAYER_SAVE_FILE_UNREADABLE, FS_STATUS_OK, FS_STATUS_ABSENT
	if !IsObject(Legends)
		Legends := LayerEditor_CurrentLegends(Ctx)
	if !IsObject(LayerKeys)
		LayerKeys := _LayerEditor_CurrentLayerKeys()
	Path := Opening is Object ? Opening.Path : KeymapLayers_UserFilePath(Ctx, ConfigDir)
	TextJson := "null"
	Errors := []
	if Opening is Object {
		if Opening.Source["status"] == FS_STATUS_OK {
			Text := Opening.Source["content"]
			; The page sees the same BOM-free text the ordinary UTF-8 reader
			; offers; publication still compares the byte-faithful source.
			if SubStr(Text, 1, 1) == Chr(0xFEFF)
				Text := SubStr(Text, 2)
			TextJson := JsonStringLiteral(Text)
			Errors := NavLayerSave_ErrorsOnEveryOs(Text, Ctx)
		} else if Opening.Source["status"] != FS_STATUS_ABSENT
			Errors := [NavLayerSave_Error(NAV_LAYER_SAVE_FILE_UNREADABLE, Opening.Source["detail"])]
	} else if FileExist(Path) {
		try {
			Text := FSReadStrict(Path)
			TextJson := JsonStringLiteral(Text)
			Errors := NavLayerSave_ErrorsOnEveryOs(Text, Ctx)
		} catch as Err {
			Errors := [NavLayerSave_Error(NAV_LAYER_SAVE_FILE_UNREADABLE, Err.Message)]
		}
	}
	return "if(window.init)window.init({"
		. '"os":' . JsonStringLiteral(LAYER_EDITOR_OS)
		. ',"path":' . JsonStringLiteral(Path)
		. ',"text":' . TextJson
		. ',"errors":' . _LayerEditor_ErrorsJson(Errors)
		. ',"legends":' . _LayerEditor_LegendsJson(Legends)
		. ',"layer_keys":' . _LayerEditor_StringsJson(LayerKeys) . "})"
}

/**
 * The page's setLegends() call, the answer to its "legends" message.
 * @param {Map} Legends - From LayerEditor_Legends.
 * @returns {string} JavaScript to evaluate in the page.
 */
LayerEditor_SetLegendsJs(Legends) {
	return "if(window.setLegends)window.setLegends(" . _LayerEditor_LegendsJson(Legends) . ")"
}

/**
 * The page's saveResult() call.
 * @param {Map} Result - From NavLayerSave_Save, plus applied when it was saved.
 * @returns {string} JavaScript to evaluate in the page.
 */
LayerEditor_SaveResultJs(Result) {
	Applied := Result.Has("applied") ? (Result["applied"] ? "true" : "false") : "false"
	return "if(window.saveResult)window.saveResult({"
		. '"saved":' . (Result["saved"] ? "true" : "false")
		. ',"applied":' . Applied
		. ',"errors":' . _LayerEditor_ErrorsJson(Result["errors"]) . "})"
}





; =============================
; =============================
; ======= 3/ The window =======
; =============================
; =============================

/**
 * Opens the editor, or brings the open one to the front.
 * @returns {Boolean} Whether the window is shown.
 */
LayerEditor_Open(*) {
	global LAYER_EDITOR_APP_ID
	Host := WebViewHost.TryOpen(LAYER_EDITOR_APP_ID, Map(
		"Title", t("layer_editor.window_title"),
		"OnReady", _LayerEditor_OnReady,
		"OnMessage", _LayerEditor_OnMessage))
	if !Host {
		LoggerError("LayerEditor", "The layer editor could not open: WebView2 is unavailable.")
		return false
	}
	return true
}

_LayerEditor_PageCurrent(Host, Opening) {
	global LAYER_EDITOR_APP_ID
	return Host is WebViewHost && Opening is Object && Host.HasOwnProp("LayerOpening")
		&& Host.LayerOpening == Opening && Host.Epoch == Opening.Epoch
		&& !Host.ResetDone && !Host.CloseRequested
		&& WebViewHost._Instances.Get(LAYER_EDITOR_APP_ID, 0) == Host
}

_LayerEditor_OpeningCurrent(Host, Opening) {
	global _ConfigDir, _SharedDir
	return _LayerEditor_PageCurrent(Host, Opening)
		&& _ConfigWriteLeaseKey(_ConfigDir) == Opening.ConfigKey
		&& _ConfigWriteLeaseKey(_SharedDir) == Opening.SharedKey
}

; The successful save survives a retired page, but that page cannot admit a
; fresh apply after the completion logger has yielded to another GUI owner.
_LayerEditor_SavedSourceCurrent(Host, Opening, Path, Text) {
	global FS_STATUS_OK
	return _LayerEditor_OpeningCurrent(Host, Opening) && Opening.Offered
		&& _ConfigWriteLeaseKey(Path) == Opening.TargetKey
		&& _ConfigWriteLeaseKey(Opening.Path) == Opening.TargetKey
		&& Opening.Source["status"] == FS_STATUS_OK && Opening.Source["content"] == Text
}

_LayerEditor_OnReady(Host) {
	global _ConfigDir, _SharedDir
	try {
		if !Host.HasOwnProp("LayerOpening") {
			Dir := _ConfigDir, Shared := _SharedDir, Epoch := Host.Epoch
			Ctx := _LayerEditor_Context()
			Path := KeymapLayers_UserFilePath(Ctx, Dir)
			Source := FSReadWithStatus(Path)
			Candidate := {Epoch: Epoch, ConfigKey: _ConfigWriteLeaseKey(Dir),
				SharedKey: _ConfigWriteLeaseKey(Shared), Directory: Dir, Path: Path,
				TargetKey: _ConfigWriteLeaseKey(Path),
				Source: Source, Offered: false, Busy: false}
			PreviousCritical := Critical("On")
			try {
				if Host.ResetDone || Host.CloseRequested || Host.Epoch != Epoch
					return
				if !Host.HasOwnProp("LayerOpening")
					Host.LayerOpening := Candidate
			} finally Critical(PreviousCritical)
		}
		Opening := Host.LayerOpening
		if !_LayerEditor_OpeningCurrent(Host, Opening)
			return
		Js := LayerEditor_InitJs(_LayerEditor_Context(), Opening.Directory, , , Opening)
		if !_LayerEditor_OpeningCurrent(Host, Opening) || A_IsSuspended
			return
		Host.Eval(Js)
		PreviousCritical := Critical("On")
		try {
			if _LayerEditor_OpeningCurrent(Host, Opening) && !A_IsSuspended
				Opening.Offered := true
		} finally Critical(PreviousCritical)
	} catch as Err {
		LoggerError("LayerEditor", "The layer data could not be read: {1}.", Err.Message)
	}
}

; The loader context of the shipped registry and vocabulary, decoded once per
; _shared folder: the registry alone costs about 160 ms, and the page asks for
; the legends again each time its window comes back to the front.
_LayerEditor_Context() {
	global _SharedDir
	static Ctx := 0, Dir := ""
	if !IsObject(Ctx) || (Dir != _SharedDir) {
		Ctx := KeymapLayers_LoadContext(_SharedDir)
		Dir := _SharedDir
	}
	return Ctx
}

/**
 * Handles one message of the page.
 * @param {WebViewHost} Host - The window.
 * @param {Map} Payload - The parsed message.
 * @param {Func} ApplyFn - Applies a saved layer; the pause-preserving reload outside tests.
 */
_LayerEditor_OnMessage(Host, Payload, ApplyFn := ReloadPreservingSuspend) {
	global _SharedDir, _ConfigDir, JSON_NULL
	Action := Payload.Has("action") ? Payload["action"] : ""
	if (Action == "cancel") {
		Host.Close()
		return
	}
	if (Action == "legends") {
		try {
			Host.Eval(LayerEditor_SetLegendsJs(LayerEditor_CurrentLegends(_LayerEditor_Context())))
		} catch as Err {
			LoggerError("LayerEditor", "The legends could not be read again: {1}.", Err.Message)
		}
		return
	}
	if (Action != "save") {
		LoggerWarn("LayerEditor", "Ignored the unknown layer editor action '{1}'.",
			(Action is String) ? Action : Type(Action))
		return
	}
	Opening := Host.HasOwnProp("LayerOpening") ? Host.LayerOpening : 0
	PreviousCritical := Critical("On")
	try {
		if !_LayerEditor_PageCurrent(Host, Opening) || !Opening.Offered || Opening.Busy
			return
		Opening.Busy := true
	} finally Critical(PreviousCritical)
	try {
		Result := NavLayerSave_SaveAndApply(Payload.Has("text") ? Payload["text"] : JSON_NULL,
			_SharedDir, Opening.Directory, ApplyFn, Opening, () => _LayerEditor_OpeningCurrent(Host, Opening),
			(Path, Text) => _LayerEditor_SavedSourceCurrent(Host, Opening, Path, Text))
		if _LayerEditor_PageCurrent(Host, Opening)
			Host.Eval(LayerEditor_SaveResultJs(Result))
	} finally Opening.Busy := false
}
