; ui/layer_editor/init.ahk

; ==============================================================================
; MODULE: Navigation Layer Editor (Windows host)
; DESCRIPTION:
; Shows the shared navigation layer editor (_shared/ui/layer_editor) in a
; WebView2 window through the manifest-driven WebViewHost factory, answers its
; "ready" with the user's layers.toml, the legends of the layout the user types
; with and the key whose hold enters the layer, and saves what it sends: the
; text must load without an error on every OS
; (platform/remap/layers_loader.ahk), is published atomically, and the driver
; reloads so NavLayer_Init registers the edited layer. The macOS and Linux
; hosts implement the same contract through _shared/lua/keymap/layer_editor.lua.
;
; FEATURES & RATIONALE:
; 1. The page offers only what exists on Windows; the host still refuses any
;    text one of the three OS loaders would reject or drop, so the editor can
;    never write a layers.toml another machine reads differently.
; 2. Atomic write: the text is staged beside layers.toml, flushed, then moved
;    over it in one write-through rename; a refused save leaves it untouched.
; 3. The layer is registered once per process (nav_layer_table.ahk), so a saved
;    layer applies through the pause-preserving reload every setting uses.
; 4. Legends: a key that types a character (the registry sends it by scan
;    code, ahk_send null) shows what the layout emulation types there
;    unshifted (a registry layout, the digit row, the Ergopti base layer read
;    from its .keylayout), else what the layout the user types with (the
;    driver's one resolver, KS_ResolveKeyboardLayout) types on its scan code,
;    read through ToUnicodeEx without touching the dead-key state. A key left
;    without a printable character shows its registry code on the page, and
;    the reason is logged once (_shared/tests/corpus/layer_editor/legends.json).
;    The page asks again when its window comes back to the front.
; 5. The layer key is the tap-hold key whose hold enters NAV_LAYER_ID in the
;    retained tap-hold configuration (MasterGateDesiredTapHold).
; ==============================================================================

#Requires AutoHotkey v2.0

; The shared page's id in _shared/ui/apps.manifest.json.
global LAYER_EDITOR_APP_ID := "layer_editor"
global LAYER_EDITOR_OS := "windows"
; The largest layers.toml the editor accepts, in UTF-8 bytes; the Lua hosts'
; MAX_TEXT_BYTES (_shared/lua/keymap/layer_editor.lua), pinned by the suite.
global LAYER_EDITOR_MAX_TEXT_BYTES := 65536
; The error codes this host adds to the loader's.
global LAYER_EDITOR_INVALID_PAYLOAD := "invalid_payload"
global LAYER_EDITOR_WRITE_FAILED := "write_failed"
global LAYER_EDITOR_FILE_UNREADABLE := "file_unreadable"
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

; The OS calls a legend needs, all in adapters/key_state.ahk: the layout the
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





; =============================
; =============================
; ======= 1/ Validation =======
; =============================
; =============================

; Loads a text on every OS and returns each distinct error once.
_LayerEditor_ErrorsOnEveryOs(Text, Ctx) {
	Errors := []
	Seen := Map()
	for Os in Ctx["platforms"] {
		for Err in KeymapLayers_Load(Os, Ctx, Text)["errors"] {
			Signature := KeymapLayers_ErrorSignature(Err)
			if Seen.Has(Signature)
				continue
			Seen[Signature] := true
			Errors.Push(Err)
		}
	}
	return Errors
}

_LayerEditor_Error(Code, Detail) {
	return Map("code", Code, "layer", "", "section", "", "key", "", "detail", Detail, "reason_key", "")
}

/**
 * Validates the text of a layer file the page asks to save.
 * @param {Any} Text - The payload's text.
 * @param {Map} Ctx - The loader context.
 * @returns {Array} What is wrong; empty when every OS loads it cleanly.
 */
LayerEditor_Validate(Text, Ctx) {
	global LAYER_EDITOR_MAX_TEXT_BYTES, LAYER_EDITOR_INVALID_PAYLOAD
	if !(Text is String)
		return [_LayerEditor_Error(LAYER_EDITOR_INVALID_PAYLOAD, "the save carries no layer file text")]
	Bytes := StrPut(Text, "UTF-8") - 1
	if (Bytes > LAYER_EDITOR_MAX_TEXT_BYTES)
		return [_LayerEditor_Error(LAYER_EDITOR_INVALID_PAYLOAD,
			"the layer file is " . Bytes . " bytes, more than " . LAYER_EDITOR_MAX_TEXT_BYTES)]
	return _LayerEditor_ErrorsOnEveryOs(Text, Ctx)
}

/**
 * Validates then atomically publishes the user's layers.toml.
 * @param {Any} Text - The payload's text.
 * @param {Map} Ctx - The loader context.
 * @param {string} ConfigDir - The configuration folder.
 * @returns {Map} saved (Boolean), path, errors (Array).
 */
LayerEditor_Save(Text, Ctx, ConfigDir) {
	global LAYER_EDITOR_WRITE_FAILED
	Path := KeymapLayers_UserFilePath(Ctx, ConfigDir)
	Errors := LayerEditor_Validate(Text, Ctx)
	if (Errors.Length > 0)
		return Map("saved", false, "path", Path, "errors", Errors)
	Stage := Path . ".tmp"
	if !FSWriteDurable(Stage, Text) {
		try FSDeleteStrict(Stage)
		return Map("saved", false, "path", Path, "errors",
			[_LayerEditor_Error(LAYER_EDITOR_WRITE_FAILED, "'" . Stage . "' could not be written")])
	}
	if !FSAtomicMoveReplace(Stage, Path) {
		try FSDeleteStrict(Stage)
		return Map("saved", false, "path", Path, "errors",
			[_LayerEditor_Error(LAYER_EDITOR_WRITE_FAILED, "'" . Path . "' could not be replaced")])
	}
	return Map("saved", true, "path", Path, "errors", [])
}





; ==========================
; ==========================
; ======= 2/ Legends =======
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
	Registry := KeylayoutEmulation_LayerIsActive("ergopti_base")
	Ergopti := !Registry && Layout.Get("ergopti_base", false) == true
	Digits := NumberRowPolicyMode(Layout.Get("direct_access_digits", "")) == "digits"
	return Map("active", Registry || Ergopti,
		"character", _LayerEditor_EmulatedCharacter.Bind(Registry, Ergopti, Digits))
}

; What the emulation types unshifted on scan code Sc, in the order its hotkeys
; win: the digit row (direct_access_digits, over any layout), a registry layout
; (keylayout_emulation.ahk), then the Ergopti base layer, whose characters and
; dead keys come from its .keylayout (layout_ergopti.ahk).
_LayerEditor_EmulatedCharacter(Registry, Ergopti, Digits, Sc) {
	global KLE_Model, KLE_LevelIndex, KLE_KeyCodes, KS_DIGIT_ROW_KEYS
	Code := Integer("0x" . SubStr(Sc, 3))
	if Digits {
		for _, Key in KS_DIGIT_ROW_KEYS {
			if (Key[2] == Code)
				return Chr(Key[1])
		}
		Edges := ErgoptiNumberRowEdgeMapping()
		if Edges.Has(Code)
			return Edges[Code]
	}
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
; ======= 3/ Messages to the page =======
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
 * @returns {string} JavaScript to evaluate in the page.
 */
LayerEditor_InitJs(Ctx, ConfigDir, Legends := "", LayerKeys := "") {
	global LAYER_EDITOR_OS, LAYER_EDITOR_FILE_UNREADABLE
	if !IsObject(Legends)
		Legends := LayerEditor_CurrentLegends(Ctx)
	if !IsObject(LayerKeys)
		LayerKeys := _LayerEditor_CurrentLayerKeys()
	Path := KeymapLayers_UserFilePath(Ctx, ConfigDir)
	TextJson := "null"
	Errors := []
	if FileExist(Path) {
		try {
			Text := FSReadStrict(Path)
			TextJson := JsonStringLiteral(Text)
			Errors := _LayerEditor_ErrorsOnEveryOs(Text, Ctx)
		} catch as Err {
			Errors := [_LayerEditor_Error(LAYER_EDITOR_FILE_UNREADABLE, Err.Message)]
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
 * @param {Map} Result - From LayerEditor_Save, plus applied when it was saved.
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
; ======= 4/ The window =======
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

_LayerEditor_OnReady(Host) {
	global _ConfigDir
	try {
		Host.Eval(LayerEditor_InitJs(_LayerEditor_Context(), _ConfigDir))
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
	Host.Eval(LayerEditor_SaveResultJs(LayerEditor_SaveAndApply(
		Payload.Has("text") ? Payload["text"] : JSON_NULL, _SharedDir, _ConfigDir, ApplyFn)))
}

/**
 * Saves a layer file the page sent, then applies it.
 * @param {Any} Text - The payload's text.
 * @param {string} SharedDir - The _shared folder.
 * @param {string} ConfigDir - The configuration folder.
 * @param {Func} ApplyFn - Applies the saved layer; returns false when refused.
 * @returns {Map} saved, path, errors and, once saved, applied.
 */
LayerEditor_SaveAndApply(Text, SharedDir, ConfigDir, ApplyFn) {
	global LAYER_EDITOR_WRITE_FAILED
	LoggerStart("LayerEditor", "Saving the navigation layer…")
	try {
		Ctx := KeymapLayers_LoadContext(SharedDir)
	} catch as Err {
		LoggerError("LayerEditor", "The navigation layer was not saved: {1}.", Err.Message)
		return Map("saved", false, "errors", [_LayerEditor_Error(LAYER_EDITOR_WRITE_FAILED, Err.Message)])
	}
	Result := LayerEditor_Save(Text, Ctx, ConfigDir)
	if !Result["saved"] {
		for Err in Result["errors"]
			LoggerWarn("LayerEditor", "Refused: {1} ({2}.{3}.{4}) — {5}.", Err["code"], Err["layer"],
				Err["section"], Err["key"], Err["detail"])
		LoggerError("LayerEditor", "The navigation layer was not saved to '{1}'.", Result["path"])
		return Result
	}
	LoggerSuccess("LayerEditor", "Navigation layer saved to '{1}'; reloading to apply it.", Result["path"])
	; A reload that goes through never returns here; a refused one says why in
	; its own log and leaves the saved file for the next start.
	Result["applied"] := ApplyFn.Call() ? true : false
	if !Result["applied"]
		LoggerError("LayerEditor", "The saved navigation layer is not applied: the reload was refused.")
	return Result
}
