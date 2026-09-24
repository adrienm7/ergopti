; static/ergopti_plus/windows/tests/unit/test_nav_layer_table.ahk

; ==============================================================================
; MODULE: Navigation Layer Hotkey Table Tests
; DESCRIPTION:
; The Windows navigation layer is registered from layers.toml by
; platform/remap/nav_layer_table.ahk instead of being written by hand. These
; tests hold the generated table to the hand-written layer it replaced
; (tests/fixtures/nav_layer_golden.json, frozen from nav_layer.ahk), prove that
; editing one key of a layer file changes that key's hotkey and no other, and
; check the registration and the callbacks the rows run.
;
; COVERAGE:
; 1. Golden (nav-layer-generated): Ergopti's recommended layer resolved for
;    Windows builds exactly the hand-written hotkeys — label, criterion, Send
;    string with its repeat count, the repeat-count keys, maximize, the three
;    AltGr spellings and the Kana guard of the two RAlt ones.
; 2. One key: changing KeyT in a copy of the preset changes SC014 and no other row.
; 3. No layers.toml: nothing to register.
; 4. Registration: every row under its own criterion with the explicit input
;    level, HotIf reset afterwards, and a second registration refused.
; 5. Callbacks: a counted Send carries the live repeat count, a plain one does
;    not, repeat_count sets the count, and every call handler the vocabulary
;    declares for Windows is implemented.
; ==============================================================================

#Requires AutoHotkey v2.0

; Floor: the hand-written layer registered 48 hotkeys. A fixture or a table that
; stopped being read would otherwise compare nothing.
global NLT_MIN_GOLDEN_ROWS := 40





; ===================================
; ===================================
; ======= 1/ Data and helpers =======
; ===================================
; ===================================

; Two levels up from tests/ (windows/tests/ -> windows/ -> ergopti_plus/) where _shared/ lives.
_NLT_SharedDir() => A_ScriptDir . "\..\..\_shared"

; THROWS when the fixture is missing: a golden that can be deleted without the
; suite noticing guards nothing.
_NLT_GoldenRows() {
	Path := A_ScriptDir . "\fixtures\nav_layer_golden.json"
	if !FileExist(Path)
		throw Error("nav_layer_golden.json not found at '" . Path . "' — a missing golden must fail this suite")
	Doc := JsonParse(FileRead(Path, "UTF-8"))
	if !(Doc is Map) || !Doc.Has("rows") || !(Doc["rows"] is Array)
		throw Error("nav_layer_golden.json did not parse into a rows list")
	return Doc["rows"]
}

_NLT_RecommendedText() => FileRead(_NLT_SharedDir() . "\keymap\layers.recommended.toml", "UTF-8")

; The Windows rows of a layer file's navigation layer; the file must load cleanly.
_NLT_Rows(Ctx, Text) {
	Result := KeymapLayers_Load("windows", Ctx, Text)
	AssertTrue(Result["ok"], "the layer file must resolve for Windows without an error")
	AssertTrue(Result["layers"].Has(NAV_LAYER_ID), "the layer file must define the '" . NAV_LAYER_ID . "' layer")
	return NavLayer_BuildTable(Result["layers"][NAV_LAYER_ID], Ctx)
}

; Modifier symbols in a Send prefix can be written in any order and send the
; same chord ("#+{Left}" and "+#{Left}"); the hand-written layer did not follow
; one order, so both sides are compared with the prefix in a fixed order.
_NLT_NormaliseSend(Text) {
	Out := ""
	Pos := 1
	while (Found := RegExMatch(Text, "([#^!+]*)\{", &M, Pos)) {
		Out .= SubStr(Text, Pos, Found - Pos)
		for Symbol in ["^", "!", "+", "#"] {
			if InStr(M[1], Symbol)
				Out .= Symbol
		}
		Out .= "{"
		Pos := Found + M.Len
	}
	return Out . SubStr(Text, Pos)
}

; Row identity -> behaviour, comparable across the golden and the table.
_NLT_Behaviours(Rows) {
	Out := Map()
	for Row in Rows {
		Identity := Row["hotkey"] . " | " . Row["criterion"]
		AssertFalse(Out.Has(Identity), "hotkey " . Identity . " must appear once")
		Guard := Row.Has("kana_guard") && Row["kana_guard"] ? " [kana_guard]" : ""
		Out[Identity] := _NLT_NormaliseSend(Row["action"]) . Guard
	}
	return Out
}

_NLT_ResetRegistration() {
	global _NavLayerRegistered := false
}





; =============================================
; =============================================
; ======= 2/ Golden and one-key edits =========
; =============================================
; =============================================

_NLT_RecommendedEqualsTheHandWrittenLayer() {
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Golden := _NLT_Behaviours(_NLT_GoldenRows())
	Actual := _NLT_Behaviours(_NLT_Rows(Ctx, _NLT_RecommendedText()))
	AssertTrue(Golden.Count >= NLT_MIN_GOLDEN_ROWS,
		"the golden holds only " . Golden.Count . " hotkeys (floor " . NLT_MIN_GOLDEN_ROWS . ")")
	Problems := ""
	for Identity, Behaviour in Golden {
		if !Actual.Has(Identity)
			Problems .= "`n  " . Identity . ": the hand-written layer did " . Behaviour . ", the table registers nothing"
		else if (Actual[Identity] !== Behaviour)
			Problems .= "`n  " . Identity . ": the hand-written layer did " . Behaviour . ", the table does " . Actual[Identity]
	}
	for Identity, Behaviour in Actual {
		if !Golden.Has(Identity)
			Problems .= "`n  " . Identity . ": the table registers " . Behaviour . ", the hand-written layer did not"
	}
	AssertEqual("", Problems, "the recommended layer must register exactly the hand-written Windows layer")
}
Test("nav layer table: the recommended layer registers the hand-written Windows layer (nav-layer-generated)",
	_NLT_RecommendedEqualsTheHandWrittenLayer)

_NLT_OneKeyEditChangesOnlyThatKey() {
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Original := _NLT_RecommendedText()
	Edited := StrReplace(Original, '"KeyT" = "keystroke:F2"', '"KeyT" = "keystroke:F3"', true, &Replaced)
	AssertEqual(1, Replaced, "the preset must bind KeyT to F2 exactly once for this edit to mean anything")
	Before := _NLT_Behaviours(_NLT_Rows(Ctx, Original))
	After := _NLT_Behaviours(_NLT_Rows(Ctx, Edited))
	AssertEqual(Before.Count, After.Count, "a one-key edit must not add or drop a hotkey")
	Changed := []
	for Identity, Behaviour in Before {
		AssertTrue(After.Has(Identity), Identity . " must still be registered after the edit")
		if (After[Identity] !== Behaviour)
			Changed.Push(Identity)
	}
	AssertEqual(1, Changed.Length, "exactly one hotkey must change")
	AssertEqual("SC014 | layer", Changed[1], "the changed hotkey must be KeyT's")
	AssertEqual("send:{F3}", After["SC014 | layer"])
}
Test("nav layer table: editing one key of layers.toml changes that key's hotkey only (nav-layer-generated)",
	_NLT_OneKeyEditChangesOnlyThatKey)

_NLT_NoFileRegistersNothing() {
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Result := KeymapLayers_Load("windows", Ctx)
	AssertEqual(0, Result["layers"].Count, "an absent layers.toml is no layer")
	AssertEqual(0, NavLayer_BuildTable(Map(), Ctx).Length, "no binding is no hotkey")
}
Test("nav layer table: no layers.toml, no hotkey (nav-layer-generated)", _NLT_NoFileRegistersNothing)

_NLT_PointerAndAltGrLabels() {
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Rows := _NLT_Rows(Ctx, '[_meta]`nschema_version = 1`n`n[layers.nav.all]`n"MouseBack" = "keystroke:alt+ArrowLeft"`n"AltRight" = "escape"`n')
	Labels := Map()
	for Row in Rows
		Labels[Row["hotkey"]] := Row
	AssertTrue(Labels.Has("*XButton1"), "a mouse button fires whatever modifier is held")
	for Label in ["SC01D & ~SC138", "RAlt"] {
		AssertTrue(Labels.Has(Label), "AltRight must register its " . Label . " spelling")
		AssertEqual(NAV_LAYER_CRITERION_LAYER, Labels[Label]["criterion"])
		AssertTrue(Labels[Label]["kana_guard"], Label . " must step aside while the Kana key is down")
	}
	AssertTrue(Labels.Has("SC138"), "AltRight must register the Kana SC138 spelling")
	AssertEqual(NAV_LAYER_CRITERION_KANA, Labels["SC138"]["criterion"])
	AssertFalse(Labels["SC138"]["kana_guard"], "the Kana spelling is the one the guard defers to")
	AssertEqual(4, Rows.Length, "one mouse row and three AltGr rows")
}
Test("nav layer table: pointer inputs are wildcards and AltRight registers its three AltGr spellings",
	_NLT_PointerAndAltGrLabels)





; =======================================
; =======================================
; ======= 3/ Registration ===============
; =======================================
; =======================================

_NLT_RegistersEveryRowUnderItsCriterion() {
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Rows := _NLT_Rows(Ctx, _NLT_RecommendedText())
	Registered := []
	HotIfCalls := []
	HotkeyFn := (Name, Callback, Options) => Registered.Push(Map("name", Name, "callback", Callback,
		"options", Options, "criterion", HotIfCalls.Length ? HotIfCalls[HotIfCalls.Length] : ""))
	HotIfFn := (Args*) => HotIfCalls.Push(Args.Length ? Args[1] : "reset")
	_NLT_ResetRegistration()
	try {
		RegisteredCount := NavLayer_Register(Rows, HotkeyFn, HotIfFn)
		AssertEqual(Rows.Length, RegisteredCount, "every row must be registered")
		AssertEqual(Rows.Length, Registered.Length)
		for RowIndex, Row in Rows {
			AssertEqual(Row["hotkey"], Registered[RowIndex]["name"])
			AssertEqual(NAV_LAYER_HOTKEY_OPTIONS, Registered[RowIndex]["options"],
				Row["hotkey"] . " must carry the layer's input level")
			Expected := (Row["criterion"] == NAV_LAYER_CRITERION_KANA) ? _NavLayer_KanaLayerActive : _NavLayer_LayerActive
			AssertTrue(Registered[RowIndex]["criterion"] == Expected, Row["hotkey"] . " must live under its own criterion")
		}
		AssertEqual("reset", HotIfCalls[HotIfCalls.Length], "HotIf is process-wide and must be reset afterwards")
		AssertThrows(() => NavLayer_Register(Rows, HotkeyFn, HotIfFn), "a second registration must be refused")
	} finally {
		_NLT_ResetRegistration()
	}
}
Test("nav layer table: registration puts each row under its criterion, once (nav-layer-generated)",
	_NLT_RegistersEveryRowUnderItsCriterion)

_NLT_CriteriaFollowTheLayerState() {
	global LayerEnabled, _ALTGR_KANA_FIXUP
	SavedLayer := LayerEnabled, SavedKana := _ALTGR_KANA_FIXUP
	try {
		LayerEnabled := false, _ALTGR_KANA_FIXUP := true
		AssertFalse(_NavLayer_LayerActive(), "no binding fires outside the layer")
		AssertFalse(_NavLayer_KanaLayerActive(), "no Kana binding fires outside the layer")
		LayerEnabled := true
		AssertTrue(_NavLayer_LayerActive())
		AssertTrue(_NavLayer_KanaLayerActive())
		_ALTGR_KANA_FIXUP := false
		AssertFalse(_NavLayer_KanaLayerActive(), "the Kana spelling is registered only for Kana layouts")
	} finally {
		LayerEnabled := SavedLayer, _ALTGR_KANA_FIXUP := SavedKana
	}
}
Test("nav layer table: the criteria follow LayerEnabled and the Kana fix-up", _NLT_CriteriaFollowTheLayerState)





; ====================================
; ====================================
; ======= 4/ Row callbacks ===========
; ====================================
; ====================================

_NLT_CallbacksSendWhatTheRowSays() {
	global _ALTGR_KANA_FIXUP
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	ByLabel := Map()
	for Row in _NLT_Rows(Ctx, _NLT_RecommendedText())
		ByLabel[Row["hotkey"] . " | " . Row["criterion"]] := Row
	Sent := []
	Counts := []
	SendFn := (Text) => Sent.Push(Text)
	SetCountFn := (N) => Counts.Push(N)
	CountFn := () => 3

	NavLayer_Callback(ByLabel["SC01F | layer"], SendFn, SetCountFn, CountFn).Call("SC01F")
	AssertEqual("{Up 3}", Sent[Sent.Length], "a repeatable action sends its last chord the repeat count times")
	NavLayer_Callback(ByLabel["SC02F | layer"], SendFn, SetCountFn, CountFn).Call("SC02F")
	AssertEqual("{End}{Enter 3}", Sent[Sent.Length], "the count applies to the last chord only")
	NavLayer_Callback(ByLabel["SC010 | layer"], SendFn, SetCountFn, CountFn).Call("SC010")
	AssertEqual("^+{Home}", Sent[Sent.Length], "a non-repeatable action ignores the count")
	NavLayer_Callback(ByLabel["SC004 | layer"], SendFn, SetCountFn, CountFn).Call("SC004")
	AssertEqual(3, Counts[Counts.Length], "Digit3 sets the repeat count to 3")
	AssertTrue(NavLayer_Callback(ByLabel["SC031 | layer"]) == _NavLayer_MaximizeWindow,
		"KeyN runs the maximize handler")

	SavedKana := _ALTGR_KANA_FIXUP
	try {
		_ALTGR_KANA_FIXUP := false
		Before := Sent.Length
		NavLayer_Callback(ByLabel["RAlt | layer"], SendFn, SetCountFn, CountFn).Call("RAlt")
		AssertEqual(Before + 1, Sent.Length, "without the Kana fix-up the RAlt spelling sends")
		AssertEqual("{Escape 3}", Sent[Sent.Length])
	} finally {
		_ALTGR_KANA_FIXUP := SavedKana
	}
}
Test("nav layer table: callbacks send the row's keys with the live repeat count (nav-layer-generated)",
	_NLT_CallbacksSendWhatTheRowSays)

_NLT_EveryWindowsCallHandlerExists() {
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Handlers := Ctx["call_handlers"]["windows"]
	AssertTrue(Handlers.Length >= 1, "the vocabulary declares Windows call handlers")
	for Handler in Handlers
		AssertTrue(NAV_LAYER_CALL_HANDLERS.Has(Handler), "call:" . Handler . " has no Windows implementation")
}
Test("nav layer table: every Windows call handler of the vocabulary is implemented", _NLT_EveryWindowsCallHandlerExists)

_NLT_ErrorsSayWhereTheyAre() {
	AssertEqual("nav.all.KeyQ", _NavLayer_ErrorWhere(Map("layer", "nav", "section", "all", "key", "KeyQ")))
	AssertEqual("the whole file", _NavLayer_ErrorWhere(Map("layer", "", "section", "", "key", "")),
		"a file-level error names no key")
}
Test("nav layer table: a layer-file error in the log says where it sits", _NLT_ErrorsSayWhereTheyAre)
