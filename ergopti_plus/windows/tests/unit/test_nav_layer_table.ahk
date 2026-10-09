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
; 6. Boot: NavLayer_Init registers the layers.toml of the configuration folder
;    it is given, nothing without one, and a file rejected as a whole closes
;    its START with an error and no SUCCESS. Without a layers.toml it never
;    decodes the physical-key registry.
; ==============================================================================

#Requires AutoHotkey v2.0

; Floor: the upstream layer registered 47 hotkeys. A fixture or a table that
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
	global _NavLayerRegistrationAttempted := false
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
	AssertEqual("*SC014 | layer", Changed[1], "the changed hotkey must be KeyT's")
	AssertEqual("send:{F3}", After["*SC014 | layer"])
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
	for Label in ["~SC01D & ~SC138", "*SC138"] {
		AssertTrue(Labels.Has(Label), "AltRight must keep its upstream physical " . Label . " spelling")
		AssertEqual(NAV_LAYER_CRITERION_LAYER, Labels[Label]["criterion"])
		AssertFalse(Labels[Label]["kana_guard"], "a physical identity has no virtual RAlt duplicate to defer")
	}
	AssertFalse(Labels.Has("RAlt"), "RAlt would duplicate the physical scan-code owner")
	AssertEqual(3, Rows.Length, "one mouse row and the two upstream AltGr rows")
}
Test("nav layer table: pointer and AltGr keep the upstream physical identities",
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
			Expected := _NavLayer_LayerActive
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

_NLT_FailSecondRegistration(State, Name, Callback, Options) {
	State["count"] += 1
	if (State["count"] == 2)
		throw Error("injected native registration refusal")
	State["first_criterion"] := State["criterion"]
}

_NLT_FailedRegistrationNeverAdmitsPartialRows() {
	global LayerEnabled
	SavedLayer := LayerEnabled
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Rows := _NLT_Rows(Ctx, _NLT_RecommendedText())
	State := Map("count", 0, "criterion", "")
	SelectCriterion := (Args*) => State["criterion"] := Args.Length ? Args[1] : "reset"
	_NLT_ResetRegistration()
	try {
		LayerEnabled := true
		AssertThrows(() => NavLayer_Register(Rows, _NLT_FailSecondRegistration.Bind(State), SelectCriterion))
		AssertEqual(2, State["count"], "the refusal occurs after one real row has been installed")
		AssertEqual("reset", State["criterion"], "a failure still resets the process-wide HotIf")
		AssertFalse(State["first_criterion"].Call(), "a partial table must never admit input")
		AssertThrows(() => NavLayer_Register([], (Args*) => 0, (Args*) => 0),
			"a failed native registration cannot be retried over partially owned variants")
	} finally {
		LayerEnabled := SavedLayer
		_NLT_ResetRegistration()
	}
}
Test("nav layer registration failure cannot activate a partial table (nav-layer-registration-atomic)",
	_NLT_FailedRegistrationNeverAdmitsPartialRows)

_NLT_CriteriaFollowTheLayerState() {
	global LayerEnabled, _ALTGR_KANA_FIXUP, _NavLayerRegistered
	SavedLayer := LayerEnabled, SavedKana := _ALTGR_KANA_FIXUP
	SavedRegistered := _NavLayerRegistered
	try {
		_NavLayerRegistered := true
		LayerEnabled := false, _ALTGR_KANA_FIXUP := true
		AssertFalse(_NavLayer_LayerActive(), "no binding fires outside the layer")
		LayerEnabled := true
		AssertTrue(_NavLayer_LayerActive())
		_ALTGR_KANA_FIXUP := false
		AssertTrue(_NavLayer_LayerActive(), "physical AltGr works on standard layouts too")
		LayerEnabled := false
		AssertFalse(_NavLayer_LayerActive(), "standard layouts also require the navigation gate")
	} finally {
		LayerEnabled := SavedLayer, _ALTGR_KANA_FIXUP := SavedKana
		_NavLayerRegistered := SavedRegistered
	}
}
Test("nav layer table: the criterion follows LayerEnabled on every layout", _NLT_CriteriaFollowTheLayerState)





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

	NavLayer_Callback(ByLabel["*SC01F | layer"], SendFn, SetCountFn, CountFn).Call("SC01F")
	AssertEqual("{Up 3}", Sent[Sent.Length], "a repeatable action sends its last chord the repeat count times")
	NavLayer_Callback(ByLabel["*SC02F | layer"], SendFn, SetCountFn, CountFn).Call("SC02F")
	AssertEqual("{End}{Enter 3}", Sent[Sent.Length], "the count applies to the last chord only")
	NavLayer_Callback(ByLabel["*SC010 | layer"], SendFn, SetCountFn, CountFn).Call("SC010")
	AssertEqual("^+{Home}", Sent[Sent.Length], "a non-repeatable action ignores the count")
	NavLayer_Callback(ByLabel["*SC004 | layer"], SendFn, SetCountFn, CountFn).Call("SC004")
	AssertEqual(3, Counts[Counts.Length], "Digit3 sets the repeat count to 3")
	AssertTrue(NavLayer_Callback(ByLabel["*SC031 | layer"]) == _NavLayer_MaximizeWindow,
		"KeyN runs the maximize handler")

	SavedKana := _ALTGR_KANA_FIXUP
	try {
		_ALTGR_KANA_FIXUP := false
		Before := Sent.Length
		NavLayer_Callback(ByLabel["*SC138 | layer"], SendFn, SetCountFn, CountFn).Call("*SC138")
		AssertEqual(Before + 1, Sent.Length, "without the Kana fix-up the physical AltGr still sends")
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





; =======================================
; =======================================
; ======= 5/ Boot: NavLayer_Init ========
; =======================================
; =======================================

; A fresh configuration folder of its own, so no other test's files are read.
_NLT_MakeConfigDir() {
	Dir := A_Temp . "\ergopti_nav_layer_init_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Dir)
	return Dir
}

; Resets the ring buffer and logs at DEBUG, so a test reads only its own lines.
_NLT_ResetLog() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
}

; The NavLayer lines of the ring buffer, at one level.
_NLT_LogLines(Level) {
	Found := []
	for _, Line in LoggerRingBufferSnapshot() {
		if InStr(Line, "[" . Level . "] [NavLayer]")
			Found.Push(Line)
	}
	return Found
}

; Runs NavLayer_Init on a configuration folder holding Text as layers.toml (none
; when Text is unset), against SharedDir (the shipped _shared by default), and
; returns what it registered and logged.
_NLT_Init(Text?, SharedDir?) {
	global LOGGER_MIN_LEVEL
	Dir := _NLT_MakeConfigDir()
	SavedLevel := LOGGER_MIN_LEVEL
	Names := []
	HotkeyFn := (Name, Callback, Options) => Names.Push(Name)
	HotIfFn := (Args*) => 0
	_NLT_ResetRegistration()
	try {
		if IsSet(Text)
			FileAppend(Text, Dir . "\layers.toml", "UTF-8-RAW")
		_NLT_ResetLog()
		Count := NavLayer_Init(IsSet(SharedDir) ? SharedDir : _NLT_SharedDir(), Dir . "\", HotkeyFn, HotIfFn)
		return Map("count", Count, "names", Names, "starts", _NLT_LogLines("START"),
			"successes", _NLT_LogLines("SUCCESS"), "errors", _NLT_LogLines("ERROR"))
	} finally {
		_NLT_ResetRegistration()
		LOGGER_MIN_LEVEL := SavedLevel
		_LoggerRefreshFastFlags()
		DirDelete(Dir, true)
	}
}

_NLT_InitRegistersTheConfigFolderLayer() {
	Golden := _NLT_GoldenRows()
	Run := _NLT_Init(_NLT_RecommendedText())
	AssertEqual(Golden.Length, Run["count"], "layers.toml in the configuration folder registers every hotkey of the preset")
	AssertEqual(Golden.Length, Run["names"].Length, "each row goes through the registrar")
	AssertEqual(1, Run["starts"].Length, "one START for the load")
	AssertEqual(1, Run["successes"].Length, "the load closes with one SUCCESS")
	AssertEqual(0, Run["errors"].Length, "a clean preset logs no error")
}
Test("nav layer boot: the layers.toml of the configuration folder is registered (nav-layer-generated)",
	_NLT_InitRegistersTheConfigFolderLayer)

_NLT_InitWithoutAFileRegistersNothing() {
	Run := _NLT_Init()
	AssertEqual(0, Run["count"], "no layers.toml, no hotkey")
	AssertEqual(0, Run["names"].Length, "no layers.toml, no registration")
	AssertEqual(1, Run["successes"].Length, "an absent file is no layer, not a failure")
	AssertEqual(0, Run["errors"].Length, "an absent file is not an error")
}
Test("nav layer boot: no layers.toml registers nothing (nav-layer-generated)", _NLT_InitWithoutAFileRegistersNothing)

_NLT_InitRejectedFileIsAnErrorNotASuccess() {
	Run := _NLT_Init("[_meta]`nschema_version = 99`n`n[layers.nav.all]`n" . '"KeyS" = "arrow_up"' . "`n")
	AssertEqual(0, Run["count"], "a file rejected as a whole binds no key")
	AssertEqual(0, Run["names"].Length, "a file rejected as a whole registers nothing")
	AssertEqual(1, Run["starts"].Length, "one START for the load")
	AssertEqual(1, Run["errors"].Length, "the rejected file is logged as an error")
	AssertEqual(0, Run["successes"].Length,
		"the load did not succeed: no SUCCESS may follow the error that closed its START")
}
Test("nav layer boot: a layers.toml rejected as a whole logs an error, never a success (nav-layer-generated)",
	_NLT_InitRejectedFileIsAnErrorNotASuccess)

; A _shared of its own holding the layer vocabulary and no physical-key
; registry, so any read of the registry fails.
_NLT_SharedWithoutRegistry() {
	Dir := A_Temp . "\ergopti_nav_layer_shared_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Dir . "\keymap")
	FileCopy(_NLT_SharedDir() . "\keymap\layer_actions.toml", Dir . "\keymap\layer_actions.toml")
	return Dir
}

; Decoding physical_keys.json costs AutoHotkey about 160 ms, and NavLayer_Init
; runs on every boot: without a layers.toml nothing is resolved against the
; registry, so the boot must not pay for it.
_NLT_InitWithoutAFileReadsNoRegistry() {
	Shared := _NLT_SharedWithoutRegistry()
	try {
		Run := _NLT_Init(, Shared)
		AssertEqual(0, Run["count"], "no layers.toml, no hotkey")
		AssertEqual(0, Run["errors"].Length, "without a layers.toml the registry must not be read")
		AssertEqual(1, Run["successes"].Length, "an absent file is no layer, not a failure")
		Run := _NLT_Init(_NLT_RecommendedText(), Shared)
		AssertEqual(0, Run["count"], "a layer cannot be registered without the registry")
		AssertEqual(1, Run["errors"].Length, "with a layers.toml the registry is required, and a missing one is an error")
	} finally {
		DirDelete(Shared, true)
	}
}
Test("nav layer boot: without a layers.toml the physical-key registry is not read (nav-layer-generated)",
	_NLT_InitWithoutAFileReadsNoRegistry)

; Navigation remains active under every held modifier, as the upstream static
; layer did. Plain scan-code hotkeys would stop matching Ctrl+layer+letter.
_NLT_PhysicalKeysKeepWildcards() {
	Ctx := KeymapLayers_LoadContext(_NLT_SharedDir())
	Rows := _NLT_Rows(Ctx, _NLT_RecommendedText())
	Checked := 0
	for Row in Rows {
		if (Row["code"] == "AltRight")
			continue
		AssertEqual("*", SubStr(Row["hotkey"], 1, 1), Row["code"] . " must match under held modifiers")
		Checked += 1
	}
	Assert(Checked >= NLT_MIN_GOLDEN_ROWS, "the wildcard check must cover the recommended physical layer")
}
Test("nav layer table: physical bindings retain upstream wildcards", _NLT_PhysicalKeysKeepWildcards)
