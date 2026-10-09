; platform/remap/nav_layer_table.ahk
; Requires: platform/remap/layers_loader.ahk, adapters/hotkey_registrar.ahk (modifier symbols),
;           infra/nav_layer_helpers.ahk (ActionLayer, repeat count)

; ==============================================================================
; MODULE: Navigation Layer — Hotkey Table
; DESCRIPTION:
; Turns the navigation layer's bindings — the user's layers.toml, resolved for
; Windows by platform/remap/layers_loader.ahk — into the hotkeys the layer
; registers under the LayerEnabled gate, and registers them. The table is data
; first: NavLayer_BuildTable returns plain rows and registers nothing, so the
; suite compares the rows of Ergopti's recommended layer with the hand-written
; layer they replace (tests/fixtures/nav_layer_golden.json) key for key.
;
; FEATURES & RATIONALE:
; 1. One row per hotkey: the physical key, the hotkey label, the criterion it
;    lives under and one action — a Send template in which N stands for the
;    repeat count, repeat_count:<N>, call:<handler> or none.
; 2. The repeat count stays Windows' own: repeat_count:<N> sets it, and a
;    repeatable action applies it to its last chord, exactly as the
;    hand-written "{Up " . Count . "}" did; any sent action then resets it.
; 3. AltGr has one physical scan-code owner on every layout. Its LCtrl
;    combination preserves Ctrl; no virtual RAlt alias competes with SC138.
; 4. Every physical input is a wildcard, preserving the upstream layer while
;    modifiers are held, including keyboard keys, mouse buttons and wheels.
; 5. Registered once per process, before the table can be half-registered by a
;    second caller; a key the file does not bind keeps its normal behaviour.
; ==============================================================================

#Requires AutoHotkey v2.0

; The layer LayerEnabled carries: the id a tap-hold key's hold_layer names
; (_shared/tap_hold/defaults.toml [tap_hold.hold_picker].layers).
global NAV_LAYER_ID := "nav"
; Stands for the repeat count in a Send template ("{Up N}").
global NAV_LAYER_COUNT_PLACEHOLDER := "N"
; The input level the layer's hotkeys had as static hotkeys below
; ErgoptiPlus.ahk's #InputLevel 2: the driver's own lower-level sends never
; trigger them. Hotkey() does not inherit #InputLevel, so it is explicit.
global NAV_LAYER_HOTKEY_OPTIONS := "I2"
; Row criteria, and the HotIf callbacks they stand for (section 3).
global NAV_LAYER_CRITERION_LAYER := "layer"
; Both AltGr forms share the navigation criterion on every keyboard layout.
global NAV_LAYER_ALTGR_CODE := "AltRight"
global NAV_LAYER_ALTGR_LABELS := ["~SC01D & ~SC138", "*SC138"]
; Layer-vocabulary modifier -> the chord notation's name, whose AutoHotkey
; symbol adapters/hotkey_registrar.ahk owns (HOTKEY_MOD_PREFIXES).
global NAV_LAYER_MODIFIER_CHORD_NAMES := Map("ctrl", "ctrl", "alt", "alt", "shift", "shift", "meta", "cmd")
; The driver-native handlers a call:<handler> resolution may name on Windows;
; must cover [call_handlers].windows in _shared/keymap/layer_actions.toml.
global NAV_LAYER_CALL_HANDLERS := Map("maximize_window", _NavLayer_MaximizeWindow,
	"brightness_up", (*) => ScreenBrightnessRequest("brightness_up"),
	"brightness_down", (*) => ScreenBrightnessRequest("brightness_down"))

global _NavLayerRegistered := false
global _NavLayerRegistrationAttempted := false





; ==============================
; ==============================
; ======= 1/ The table =========
; ==============================
; ==============================

/**
 * Builds the hotkey rows of one resolved layer.
 * @param {Map} Bindings - Key code -> resolution, as KeymapLayers_Load resolves them for Windows.
 * @param {Map} Ctx - The loader context (physical-key registry).
 * @returns {Array} Rows: Maps of code, hotkey, criterion, action, send_open,
 *          counted, count, handler and kana_guard.
 */
NavLayer_BuildTable(Bindings, Ctx) {
	global NAV_LAYER_ALTGR_CODE, NAV_LAYER_ALTGR_LABELS, NAV_LAYER_CRITERION_LAYER
	if !(Bindings is Map)
		throw ValueError("NavLayer_BuildTable needs the layer's bindings as a Map.", -1)
	Rows := []
	for KeyCode, Resolution in Bindings {
		if !Ctx["keys"].Has(KeyCode)
			throw ValueError("The layer binds '" . KeyCode . "', which is not in the physical-key registry.", -1)
		KeyEntry := Ctx["keys"][KeyCode]
		if (KeyCode == NAV_LAYER_ALTGR_CODE) {
			for Label in NAV_LAYER_ALTGR_LABELS
				Rows.Push(_NavLayer_Row(KeyCode, Label, NAV_LAYER_CRITERION_LAYER, Resolution, Ctx, false))
			continue
		}
		Label := "*" . KeyEntry["ahk"]
		Rows.Push(_NavLayer_Row(KeyCode, Label, NAV_LAYER_CRITERION_LAYER, Resolution, Ctx, false))
	}
	return Rows
}

; One row: what a hotkey label does under one criterion.
_NavLayer_Row(Code, Label, Criterion, Resolution, Ctx, KanaGuard) {
	global NAV_LAYER_CALL_HANDLERS, NAV_LAYER_COUNT_PLACEHOLDER
	Row := Map("code", Code, "hotkey", Label, "criterion", Criterion, "kana_guard", KanaGuard,
		"send_open", "", "counted", false, "count", 0, "handler", "")
	ResolutionKind := Resolution["kind"]
	if (ResolutionKind == "keystroke") {
		Row["send_open"] := _NavLayer_SendOpen(Resolution["chords"], Ctx)
		Row["counted"] := Resolution["repeatable"] ? true : false
		Row["action"] := "send:" . Row["send_open"]
			. (Row["counted"] ? " " . NAV_LAYER_COUNT_PLACEHOLDER : "") . "}"
	} else if (ResolutionKind == "repeat_count") {
		Row["count"] := Resolution["count"]
		Row["action"] := "repeat_count:" . Resolution["count"]
	} else if (ResolutionKind == "call") {
		if !NAV_LAYER_CALL_HANDLERS.Has(Resolution["handler"])
			throw ValueError("No Windows handler implements call:" . Resolution["handler"] . ".", -1)
		Row["handler"] := Resolution["handler"]
		Row["action"] := "call:" . Resolution["handler"]
	} else if (ResolutionKind == "none") {
		Row["action"] := "none"
	} else {
		throw ValueError("Unknown layer resolution kind '" . ResolutionKind . "'.", -1)
	}
	return Row
}

; The Send text of a chord sequence, up to (not including) the closing brace of
; its last key, so a repeat count can still be slotted in: "^+{Up".
_NavLayer_SendOpen(Chords, Ctx) {
	if !(Chords is Array) || Chords.Length == 0
		throw ValueError("A keystroke resolution needs at least one chord.", -1)
	Text := ""
	for ChordIndex, Chord in Chords {
		KeyEntry := Ctx["keys"][Chord["key"]]
		; A character key is sent by scan code so the active layout cannot change
		; which key is pressed; a named key by its layout-independent Send name.
		SendName := (KeyEntry["ahk_send"] is String) ? KeyEntry["ahk_send"] : KeyEntry["ahk"]
		Text .= (ChordIndex == 1 ? "" : "}") . _NavLayer_ModifierPrefix(Chord["mods"]) . "{" . SendName
	}
	return Text
}

; AutoHotkey modifier symbols for a chord, in the order the hotkey registrar
; emits them.
_NavLayer_ModifierPrefix(Mods) {
	global NAV_LAYER_MODIFIER_CHORD_NAMES, HOTKEY_NATIVE_MOD_ORDER, HOTKEY_MOD_PREFIXES
	Present := Map()
	for Modifier in Mods {
		if !NAV_LAYER_MODIFIER_CHORD_NAMES.Has(Modifier)
			throw ValueError("Windows cannot send the modifier '" . Modifier . "'.", -1)
		Present[NAV_LAYER_MODIFIER_CHORD_NAMES[Modifier]] := true
	}
	Prefix := ""
	for ChordName in HOTKEY_NATIVE_MOD_ORDER {
		if Present.Has(ChordName)
			Prefix .= HOTKEY_MOD_PREFIXES[ChordName]
	}
	return Prefix
}





; ===================================
; ===================================
; ======= 2/ Row callbacks ==========
; ===================================
; ===================================

/**
 * The function a row's hotkey runs.
 * @param {Map} Row - A row from NavLayer_BuildTable.
 * @param {Func} SendFn - Sends one Send string; ActionLayer outside tests.
 * @param {Func} SetCountFn - Sets the repeat count; SetNumberOfRepetitions outside tests.
 * @param {Func} CountFn - Reads the repeat count; AppState_GetNumberOfRepetitions outside tests.
 * @returns {Func} The hotkey callback.
 */
NavLayer_Callback(Row, SendFn := ActionLayer, SetCountFn := SetNumberOfRepetitions,
		CountFn := AppState_GetNumberOfRepetitions) {
	global NAV_LAYER_CALL_HANDLERS
	RowAction := Row["action"]
	if (SubStr(RowAction, 1, 5) == "send:")
		Callback := Row["counted"]
			? _NavLayer_SendCounted.Bind(Row["send_open"], SendFn, CountFn)
			: _NavLayer_SendOnce.Bind(Row["send_open"] . "}", SendFn)
	else if (SubStr(RowAction, 1, 13) == "repeat_count:")
		Callback := _NavLayer_SetCount.Bind(Row["count"], SetCountFn)
	else if (SubStr(RowAction, 1, 5) == "call:")
		Callback := NAV_LAYER_CALL_HANDLERS[Row["handler"]]
	else if (RowAction == "none")
		Callback := _NavLayer_Swallow
	else
		throw ValueError("Unknown navigation-layer action '" . RowAction . "'.", -1)
	return Callback
}

_NavLayer_SendOnce(Text, SendFn, *) {
	SendFn.Call(Text)
}

_NavLayer_SendCounted(Open, SendFn, CountFn, *) {
	SendFn.Call(Open . " " . CountFn.Call() . "}")
}

_NavLayer_SetCount(Count, SetCountFn, *) {
	SetCountFn.Call(Count)
}

; `none`: the key does nothing while the layer is held.
_NavLayer_Swallow(*) {
}

; WinMaximize throws TargetError when no window is active (tray-only desktop,
; or the foreground window closing mid-press); that is not a fault to report.
_NavLayer_MaximizeWindow(*) {
	try WinMaximize("A")
	catch
		try LoggerDebug("NavLayer", "WinMaximize skipped — no active window.")
}





; ===================================
; ===================================
; ======= 3/ Registration ===========
; ===================================
; ===================================

; Where a layer-file error sits: layer.section.key, or the file as a whole.
_NavLayer_ErrorWhere(Err) {
	Where := ""
	for Field in ["layer", "section", "key"] {
		if (Err[Field] != "")
			Where .= (Where == "" ? "" : ".") . Err[Field]
	}
	return (Where == "") ? "the whole file" : Where
}

_NavLayer_LayerActive(*) {
	global LayerEnabled, _NavLayerRegistered
	return _NavLayerRegistered && LayerEnabled
}

/**
 * Registers the rows as hotkeys under their criteria. Once per process.
 * @param {Array} Rows - From NavLayer_BuildTable.
 * @param {Func} HotkeyFn - Hotkey registrar; injectable for tests.
 * @param {Func} HotIfFn - HotIf selector; injectable for tests.
 * @returns {Integer} The number of hotkeys registered.
 */
NavLayer_Register(Rows, HotkeyFn := Hotkey, HotIfFn := HotIf) {
	global _NavLayerRegistered, _NavLayerRegistrationAttempted, NAV_LAYER_HOTKEY_OPTIONS
	global NAV_LAYER_CRITERION_LAYER
	if _NavLayerRegistrationAttempted
		throw Error("The navigation layer registration was already attempted; restart before retrying.", -1)
	Criteria := Map(NAV_LAYER_CRITERION_LAYER, _NavLayer_LayerActive)
	; Build every callback before the first registration, so a bad row fails
	; before any hotkey exists rather than halfway through the table.
	Callbacks := []
	for Row in Rows {
		if !Criteria.Has(Row["criterion"])
			throw ValueError("Unknown navigation-layer criterion '" . Row["criterion"] . "'.", -1)
		Callbacks.Push(NavLayer_Callback(Row))
	}
	; Partially installed native variants must stay dormant after a refusal.
	; A second attempt cannot publish them accidentally alongside a new table.
	_NavLayerRegistrationAttempted := true
	; HotIf is process-wide: reset it even when a registration throws.
	try {
		for RowIndex, Row in Rows {
			HotIfFn.Call(Criteria[Row["criterion"]])
			HotkeyFn.Call(Row["hotkey"], Callbacks[RowIndex], NAV_LAYER_HOTKEY_OPTIONS)
		}
	} finally HotIfFn.Call()
	_NavLayerRegistered := true
	return Rows.Length
}

/**
 * Loads the user's layers.toml and registers the navigation layer. Called once
 * at boot; an absent file registers nothing.
 * @param {string} SharedDir - The _shared folder.
 * @param {string} ConfigDir - The configuration folder holding layers.toml.
 * @param {Func} HotkeyFn - Hotkey registrar; injectable for tests.
 * @param {Func} HotIfFn - HotIf selector; injectable for tests.
 * @returns {Integer} The number of hotkeys registered, 0 when none could be.
 */
NavLayer_Init(SharedDir, ConfigDir, HotkeyFn := Hotkey, HotIfFn := HotIf) {
	global NAV_LAYER_ID
	LoggerStart("NavLayer", "Loading the navigation layer from '{1}'…", ConfigDir)
	try {
		; This runs on every boot, and decoding the physical-key registry is the
		; costly part: without a layers.toml nothing is bound, so it is skipped.
		UserFile := KeymapLayers_UserFilePathFromVocabulary(SharedDir, ConfigDir)
		if !FileExist(UserFile) {
			LoggerSuccess("NavLayer", "No '{1}': the navigation layer binds no key.", UserFile)
			return 0
		}
		Ctx := KeymapLayers_LoadContext(SharedDir)
		Result := KeymapLayers_LoadUserFile(Ctx, ConfigDir, "windows")
		for Err in Result["errors"]
			LoggerWarn("NavLayer", "{1}: {2} ({3}) — {4}.", Result["path"], Err["code"],
				_NavLayer_ErrorWhere(Err), Err["detail"])
		; A file rejected as a whole is this load's failure: the error closes the
		; START, and no SUCCESS may follow it for a layer that binds nothing.
		if !Result["ok"] && Result["layers"].Count == 0 {
			LoggerError("NavLayer", "'{1}' could not be used as a whole: the navigation layer binds no key.",
				Result["path"])
			return 0
		}
		for LayerId in Result["layers"] {
			if (LayerId != NAV_LAYER_ID)
				LoggerWarn("NavLayer", "Layer '{1}' in '{2}' has no hold key to activate it on Windows; only '{3}' does.",
					LayerId, Result["path"], NAV_LAYER_ID)
		}
		Bindings := Result["layers"].Has(NAV_LAYER_ID) ? Result["layers"][NAV_LAYER_ID] : Map()
		Registered := NavLayer_Register(NavLayer_BuildTable(Bindings, Ctx), HotkeyFn, HotIfFn)
	} catch as Err {
		LoggerError("NavLayer", "The navigation layer could not be registered: {1}.", Err.Message)
		return 0
	}
	LoggerSuccess("NavLayer", "Navigation layer registered: {1} hotkey(s) for {2} key(s).", Registered, Bindings.Count)
	return Registered
}
