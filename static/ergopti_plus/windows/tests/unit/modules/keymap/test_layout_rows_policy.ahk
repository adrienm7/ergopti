; tests/unit/modules/keymap/test_layout_rows_policy.ahk

; ==============================================================================
; MODULE: Layout Rows Policy
; DESCRIPTION:
; The four row switches of the layout emulation (layout.emulate_<row>). The
; shared policy reads each row's keys from the physical-key registry and
; decides each row from its own switch; the hand-written corpus
; (tests/corpus/layouts/layout_rows.json) is replayed here and by the macOS and
; Linux contract tests. The Windows rows are the corpus scan codes, and a
; registry layout whose number row is switched off leaves the number-row
; ordering to the OS layout's row, « symbols first » included
; (layout-row-scopes).
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\..\fixtures\layout_row_host_character.ahk
#Include %A_LineFile%\..\..\..\..\fixtures\host_capability_probes.ahk




_LRP_Corpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\layout_rows.json"))
}

/** Replays the corpus rows and switches through the shared AHK policy. */
_LRP_SharedCorpus() {
	global _SharedDir, LAYOUT_ROWS_POLICY_IDS
	Corpus := _LRP_Corpus()
	Registry := JsonParse(FSReadUtf8Exact(_SharedDir . "\data\keycodes\physical_keys.json"))
	Rows := LayoutRowsPolicyKeys(Registry)
	AssertEqual(4, LAYOUT_ROWS_POLICY_IDS.Length, "four row switches")
	for Row in LAYOUT_ROWS_POLICY_IDS {
		Expected := Corpus["rows"][Row]
		AssertEqual(Expected.Length, Rows[Row].Length, Row . ": key count")
		for Index, Code in Expected
			AssertEqual(Code, Rows[Row][Index], Row . " key " . Index)
	}
	AssertThrows(() => LayoutRowsPolicyKeys(Map()), "a registry without keys is refused")
	AssertEqual(4, Corpus["switches"].Length, "every switch case is represented")
	for Vec in Corpus["switches"] {
		for Row in LAYOUT_ROWS_POLICY_IDS
			AssertEqual(Vec["emulated"][Row] ? true : false,
				LayoutRowsPolicyEmulates(Vec["layout"], Row), Vec["id"] . ": " . Row)
		AssertEqual(Vec["number_row_source"]["active"], LayoutRowsPolicyNumberRowSource(true, Vec["layout"]),
			Vec["id"] . ": the ordering's row under an active emulation")
		AssertEqual(Vec["number_row_source"]["inactive"], LayoutRowsPolicyNumberRowSource(false, Vec["layout"]),
			Vec["id"] . ": the ordering's row without an emulation")
	}
	for Invalid in Corpus["invalid"]
		AssertThrows(LayoutRowsPolicyEmulates.Bind(Invalid["layout"], Invalid["row"]), Invalid["id"] . " is refused")
}
Test("layout rows: the shared policy replays the corpus rows and switches (layout-row-scopes)", _LRP_SharedCorpus)

/** The Windows emulation's rows are the corpus scan codes, read from the registry. */
_LRP_WindowsRows() {
	global LAYOUT_ROWS_POLICY_IDS
	Corpus := _LRP_Corpus()
	Rows := LayoutEmulationRows()
	for Row in LAYOUT_ROWS_POLICY_IDS {
		Expected := Corpus["windows_scan_codes"][Row]
		AssertEqual(Expected.Length, Rows[Row].Length, Row . ": scan code count")
		for Index, Name in Expected {
			AssertEqual(Name, Rows[Row][Index], Row . " scan code " . Index)
			AssertEqual(Row, LayoutRowOf(Name), Name . " belongs to " . Row)
		}
	}
	AssertEqual("", LayoutRowOf("SC039"), "the space bar belongs to no row")
	AssertEqual("", LayoutRowOf("SC00F"), "Tab belongs to no row")
	; No driver source lists the rows' scan codes any more.
	Source := _DriverSourceNoComments()
	AssertEqual(0, InStr(Source, '"SC010", "SC011", "SC012"'), "no hand-written row table remains")
}
Test("layout rows: the Windows rows are read from the shared registry (layout-row-scopes)", _LRP_WindowsRows)

/**
 * A registry layout with its number row switched off: the ordering, its
 * availability and « symbols first » are the OS layout's row, typed by the
 * driver's own hotkeys, since the registry layout's action machine stands down
 * on that row.
 */
_LRP_RegistryNumberRowOff() {
	global Features, CategoryEnabled, LayerEnabled, _NumberRowAvailabilityCache
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), _NumberRowAvailabilityCache]
	try {
		Layout := Map("emulated_layout", "ergol", "ergopti_base", true, "ergopti_alt_gr", false,
			"ergopti_variant", "none", "direct_access_digits", "symbols", "emulate_number_row", true,
			"emulate_top_row", true, "emulate_home_row", true, "emulate_bottom_row", true)
		_NRP_UseLayout(Layout)
		_KLT_Load("ergol")
		_NumberRowAvailabilityCache := Map()
		_NRP_WithQwertyShapedForeground((Hkl) => (
			AssertTrue(NumberRowRegistryOwnsRow(), "Ergo-L types its own number row"),
			AssertEqual("emulated", _DigitRowEffectiveKey(0x02, Hkl, false)["source"]),
			Features["layout"]["emulate_number_row"] := false,
			AssertFalse(NumberRowRegistryOwnsRow(), "its number row switched off, the OS layout types it"),
			AssertEqual("native", _DigitRowEffectiveKey(0x02, Hkl, false)["source"], "the ordering reads the OS row"),
			AssertEqual("", NumberRowAvailability(Hkl, false)["symbols"], "symbols first can reorder the QWERTY row"),
			AssertTrue(NumberRowSymbolsCapable(false), "and the driver's own hotkeys type it"),
			AssertEqual("symbols", NumberRowEffectiveMode(), "the stored choice applies on the OS row"),
			AssertEqual("!", NumberRowSymbolsFirstText(0x02, false, Hkl, false), "the 1 key types its Shift symbol"),
			AssertFalse(_KLE_BaseCriterion("SC002", false), "the registry layout leaves the key")))
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		_NumberRowAvailabilityCache := Saved[5]
	}
}

Test("layout rows: a registry layout's number row switched off is reordered on the OS row (layout-row-scopes)",
	_KLT_WithEmulation.Bind(_LRP_RegistryNumberRowOff))

; Exercise the actual registration -> criterion -> callback -> emission path.
; The child shadows SendEvent, so no user window can receive a fixture key.
_LRPS_ChildSource(BodyName := "layout_row_passthrough_body.ahk", ExtraSource := "") {
	global _DriverDir, _SharedDir
	; Other entry points in the included module name services this narrow child
	; never calls. Runtime unset reads still throw; only load-time warnings stop.
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Code .= "#Include " . _DriverDir . "\infra\json.ahk`n"
	Code .= "#Include " . _DriverDir . "\adapters\file_system.ahk`n"
	Code .= "#Include " . _SharedDir . "\modules\features\layout_rows_policy.ahk`n"
	Owner := _DriverProductionFileForSymbol("_LayoutRowPassthrough")
	AssertTrue(Owner != "", "the genuine row sender must have one production owner")
	Code .= "#Include " . Owner . "`n"
	for Name in ["LayoutEmulationRows", "LayoutRowOf", "LayoutRowSwitches",
		"LayoutRowsAllEmulated", "LayoutRowIsEmulated"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the real row policy helper must exist: " . Name)
		Code .= Definition . "`n"
	}
	if BodyName == "layout_row_native_flags_body.ahk" || BodyName == "layout_row_external_flags_body.ahk"
		Code .= "#Include " . _DriverDir . "\tests\fixtures\layout_row_host_character.ahk`n"
	Code .= ExtraSource . "`n"
	Code .= FileRead(_DriverDir . "\tests\fixtures\" . BodyName, "UTF-8")
	return Code
}

_LRPS_Completion(State, Code, Output, ErrorText) {
	State.Code := Code
	State.Output := Output
	State.ErrorText := ErrorText
	State.Calls += 1
}

_LRPS_LevelCustody(CallerLevel, Throws, SourceFn := _LRPS_ChildSource, ExtraArgs := unset,
		Receipt := "PASS row-passthrough-level-custody") {
	global _SharedDir
	Stem := A_Temp . "\ergopti_row_passthrough_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Script := Stem . ".ahk"
	AssertFalse(FileExist(Script), "the isolated row sender requires a fresh owned path")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . SourceFn.Call()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }
	Handle := 0, Primary := 0
	PreviousCritical := Critical("Off")
	try {
		Observer := InputHook(HookDispatcherConst.INPUT_HOOK_OPTS)
		Args := ["/ErrorStdOut=UTF-8", Script, String(CallerLevel), Throws ? "throw" : "success", _SharedDir, String(Observer.MinSendLevel)]
		if IsSet(ExtraArgs) {
			for Arg in ExtraArgs
				Args.Push(Arg)
		}
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, Args,
			_LRPS_Completion.Bind(State))
		AssertTrue(Handle.start(), "the exact production row sender child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the row sender child must settle once")
		AssertEqual(0, State.Code, "the row sender refused: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "no native child error may be hidden")
		if Receipt == "PASS layout-row-native-flags" {
			AssertTrue(IsSet(ExtraArgs) && ExtraArgs.Length >= 1)
			Observation := "OBSERVATION row-native-feed mode=" . ExtraArgs[1]
				. " observer_level=1 keydowns=1 char_units=1 expected_units=1"
			AssertEqual(Observation . "`n" . Receipt, State.Output,
				"the exact I1 observation and terminal native receipt must both be received")
			_TestPrint("# " . Observation)
		} else
			AssertEqual(Receipt, State.Output)
	} catch as Err {
		Primary := Err
	}
	Retired := false
	try Retired := !IsObject(Handle) || ((Result := Handle.terminate()) is Integer && Result == 1)
	catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if Retired && !IsObject(Primary)
			FileDelete(Script)
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the exact child must retire before its source is removed")
}

for _LRPS_CallerLevel in [0, 2, 3]
	for _LRPS_Throws in [false, true]
		Test("layout row native callback: caller level " . _LRPS_CallerLevel . " ignores a " . (_LRPS_Throws ? "refusing" : "recording") . " sender trap"
			. " without synthetic replay (layout-row-send-level)", _LRPS_LevelCustody.Bind(_LRPS_CallerLevel, _LRPS_Throws))


_LRPW_ChildSource() {
	global _DriverDir
	Definition := _DriverFuncBody("RemapKey")
	AssertTrue(Definition != "", "the real built-in registrar must be exercised")
	return _LRPS_ChildSource("layout_row_win_fallback_body.ahk",
		"#Include " . _DriverDir . "\infra\magic_editor.ahk`n" . Definition . "`n"
		. _DriverFuncBody("_RemapChordEmit") . "`nKeyboardShortcutRunLayoutChord(*) => false`n")
}

for _LRPW_Row in ["number", "top", "home", "bottom"]
	for _LRPW_Mode in ["off", "on", "magic-source", "magic-other", "ordinary", "legacy"]
		Test("layout Win fallback: " . _LRPW_Row . " row " . _LRPW_Mode . " (layout-row-win-fallback)",
			_LRPS_LevelCustody.Bind(0, false, _LRPW_ChildSource, [_LRPW_Row, _LRPW_Mode], "PASS row-win-fallback"))


; The existing real registration test supplies its captured Win broker rows.
; Unlike native HotIf, the broker invokes these predicates with no arguments.
_LRPR_AssertBrokerRows(Rows) {
	_KLT_WithEmulation(_LRPR_AssertBrokerRowsLoaded.Bind(Rows))
}

_LRPR_AssertBrokerRowsLoaded(Rows) {
	global Features, CategoryEnabled, LayerEnabled
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone()]
	try {
		_NRP_UseLayout(Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", false, "ergopti_variant", "none", "direct_access_digits", "symbols",
			"emulate_number_row", true, "emulate_top_row", true, "emulate_home_row", true, "emulate_bottom_row", true))
		_KLT_Load("ergol")
		Corpus := _LRP_Corpus()
		for DisabledRow in ["number_row", "top_row", "home_row", "bottom_row"] {
			NativeScans := Map()
			for Scan in Corpus["windows_scan_codes"][DisabledRow]
				NativeScans[Scan] := true
			Features["layout"]["emulate_" . DisabledRow] := false
			SeenNative := 0
			for Row in Rows {
				Native := NativeScans.Has(Row["scan"])
				SeenNative += Native ? 1 : 0
				AssertEqual(!Native, Row["criterion"].Call(),
					"zero-argument Win admission must retain " . Row["scan"] . " physical identity with " . DisabledRow . " native")
			}
			AssertEqual(NativeScans.Count, SeenNative, "the real Win cohort must include the whole independent corpus row")
			Features["layout"]["emulate_" . DisabledRow] := true
		}
		for Row in Rows
			AssertTrue(Row["criterion"].Call(), "reenabling the rows restores every registered Win fallback")
		LayerEnabled := true
		for Row in Rows
			AssertFalse(Row["criterion"].Call(), "physical binding must retain the original navigation-layer gate")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
	}
}


_LRPE_ChildSource() {
	global _DriverDir, _SharedDir
	Source := _NRP_LayoutSource()
	Pattern := "m)^#HotIf ([^`r`n]*NumberRowEdgesEffective\(\)[^`r`n]*)$"
	At := RegExMatch(Source, Pattern, &Criterion)
	AssertTrue(At > 0, "the actual static edge criterion must be found")
	AssertEqual(0, RegExMatch(Source, Pattern, , At + Criterion.Len), "the edge cohort must have one real static criterion")
	Extra := "#Include " . _DriverDir . "\adapters\key_state.ahk`n"
	Extra .= "#Include " . _SharedDir . "\modules\features\number_row_policy.ahk`n"
	for Name in ["KeylayoutEmulation_IsActive", "KeylayoutEmulation_LayerIsActive",
		"KeylayoutEmulation_NumberRowLevels", "TapHoldKanaAltGrHeld"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the real edge dependency must exist: " . Name)
		Extra .= Definition . "`n"
	}
	; Evaluate the production expression with AHK's real short-circuit semantics,
	; without arming a host hotkey or inventing a second admission implementation.
	Extra .= "_LRPE_EdgeCriterion() => " . Criterion[1] . "`n"
	return _LRPS_ChildSource("number_row_edges_boot_body.ahk", Extra)
}

for _LRPE_Mode in ["features-unpublished", "category-unpublished", "category-masked", "native-policy",
	"published-on", "published-off", "kana-held", "inert-ordering"]
	Test("number row edges: " . _LRPE_Mode . " keeps actual static admission safe (number-row-edges-boot-admission)",
		_LRPS_LevelCustody.Bind(0, false, _LRPE_ChildSource, [_LRPE_Mode], "PASS number-row-edges-admission"))


_LRPCM_ChildSource(BodyName := "layout_row_chosen_magic_body.ahk", AdditionalSource := "") {
	global _DriverDir
	Source := _NRP_LayoutSource()
	Start := InStr(Source, "_MagicKeyHotkeys := LayoutRegistry_MagicKeyHotkeys(")
	Finish := InStr(Source, "`nRegisterShiftLayer()", , Start)
	AssertTrue(Start > 0 && Finish > Start, "the genuine magic producer must be bounded before Shift registration")
	Extra := "#Include " . _DriverDir . "\infra\magic_editor.ahk`n"
	for Name in ["RemapKey", "_RemapChordEmit", "LayoutRegistry_MagicKeyHotkeys"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the genuine magic dependency must exist: " . Name)
		Extra .= Definition . "`n"
	}
	Extra .= "KeyboardShortcutRunLayoutChord(*) => false`n"
	Extra .= "_LRPCM_RegisterMagic() {`n global ScriptInformation, Features`n"
		. SubStr(Source, Start, Finish - Start) . "`n}`n"
	return _LRPS_ChildSource(BodyName, Extra . AdditionalSource)
}

for _LRPCM_Row in ["number", "top", "home", "bottom"]
	Test("layout rows: chosen magic on " . _LRPCM_Row . " keeps only its plain press (layout-row-chosen-magic-scope)",
		_LRPS_LevelCustody.Bind(0, false, _LRPCM_ChildSource, [_LRPCM_Row], "PASS layout-row-chosen-magic"))


_LRPN_ChildSource() {
	global _DriverDir, _SharedDir
	static Includes := ""
	if Includes == "" {
		Resolved := "", Seen := Map()
		; Resolve whole owners, preserving their real globals and private helpers
		; without pinning their current paths or rereading the catalogue per child.
		for Name in ["KS_IsDown", "Keylayout_Parse", "KeylayoutTables_Build", "ErgoptiLayout_BuildSpec",
			"AccentedShortcutTargetLetter", "_DigitRowDown"] {
			Owner := _DriverProductionFileForSymbol(Name)
			AssertTrue(Owner != "" && FileExist(Owner), "the actual dependency owner must exist: " . Name)
			if !Seen.Has(Owner) {
				Seen[Owner] := true
				Resolved .= "#Include " . Owner . "`n"
			}
		}
		Includes := Resolved
	}
	Extra := Includes
	Extra .= "#Include " . _SharedDir . "\modules\features\number_row_policy.ahk`n"
	; The extracted digit emitters share their real native/recorder selector.
	; Only its final SendEvent boundary is the child's passive output port.
	for Name in ["KeylayoutEmulation_KeyCodes", "KeylayoutEmulation_IsActive", "KeylayoutEmulation_LayerIsActive",
		"KeylayoutEmulation_NumberRowLevels", "_KLE_MagicKeyOwnsKey", "GetCapsLockCondition",
		"NumberRowSendEvent", "_DigitShiftSend"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the actual built-in row dependency must exist: " . Name)
		Extra .= Definition . "`n"
	}
	return _LRPCM_ChildSource("builtin_number_row_magic_body.ahk", Extra)
}

for _LRPN_Scan in ["SC002", "SC029", "SC00C", "SC00D"]
	for _LRPN_Emulated in [false, true]
		for _LRPN_Caps in [false, true]
			Test("built-in number row: " . _LRPN_Scan . " " . (_LRPN_Emulated ? "emulated" : "native")
				. " row caps " . (_LRPN_Caps ? "on" : "off") . " retains chosen magic and releases (builtin-number-row-magic-owner)",
				_LRPS_LevelCustody.Bind(0, false, _LRPN_ChildSource,
					[_LRPN_Scan, _LRPN_Emulated ? "on" : "off", _LRPN_Caps ? "on" : "off", _StaticDir, _DriverDir],
					"PASS builtin-number-row-magic-owner"))


_LRCC_ChildSource(BodyName := "layout_row_control_body.ahk", AdditionalSource := "") {
	Source := FileRead(_DriverProductionFileForSymbol("RemapKey"), "UTF-8")
	Start := InStr(Source, "; ======= 7/ CONTROL LAYER")
	AssertTrue(Start > 0, "the actual control layer must be found")
	Extra := "", Plan := [], Gates := 0
	for Line in StrSplit(SubStr(Source, Start), "`n") {
		if RegExMatch(Line, "^#HotIf (.+)$", &Match) {
			Gates += 1
			; A_ThisHotkey is AHK's read-only evaluation input. Port only that
			; token, leaving the complete production expression unchanged.
			Expression := StrReplace(Match[1], "A_ThisHotkey", "Name")
			Extra .= "_LRCC_Gate" . Gates . "(Name) => " . Expression . "`n"
		} else if RegExMatch(Line, "^([^;\s]+):: (.+?)(?:\x20;.*)?$", &Match) {
			Index := Plan.Length + 1
			Extra .= "_LRCC_Callback" . Index . "(*) {`n" . Match[2] . "`n}`n"
			Plan.Push('Map("name", "' . Match[1] . '", "criterion", _LRCC_Gate' . Gates
				. ', "callback", _LRCC_Callback' . Index . ')')
		}
	}
	AssertEqual(3, Gates, "all three actual control-layer contexts must be exercised")
	AssertEqual(5, Plan.Length, "all five actual control-layer callbacks must be exercised")
	Items := ""
	for Item in Plan
		Items .= (Items == "" ? "" : ",") . Item
	Extra .= "_LRCC_Plan() => [" . Items . "]`n"
	for Name in ["_RemapEmit", "LayoutRowIsEmulatedHotkey"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the actual control-layer dependency must exist: " . Name)
		Extra .= Definition . "`n"
	}
	return _LRPS_ChildSource(BodyName, Extra . AdditionalSource)
}

for _LRCC_Entry in [1, 2, 3, 4, 5]
	for _LRCC_Enabled in [false, true]
		Test("layout controls: cohort " . _LRCC_Entry . " row " . (_LRCC_Enabled ? "on" : "off")
			. " preserves native shortcuts and live admission (layout-row-control-admission)",
			_LRPS_LevelCustody.Bind(0, false, _LRCC_ChildSource,
				[String(_LRCC_Entry), _LRCC_Enabled ? "on" : "off"], "PASS layout-row-control-admission"))


_LRCZ_ChildSource() {
	Owner := _DriverProductionFileForSymbol("MicrosoftApps")
	Source := FileRead(Owner, "UTF-8")
	AssertTrue(RegExMatch(Source, "ms)^global MICROSOFT_OFFICE_EXES := Map\(.*?^\)", &Declaration) > 0,
		"the genuine Microsoft host catalogue must exist")
	Definition := _DriverFuncBody("MicrosoftApps")
	AssertTrue(Definition != "", "the genuine Microsoft classifier must exist")
	return _LRCC_ChildSource("layout_control_zoom_host_body.ahk", Declaration[0] . "`n" . Definition . "`n")
}

for _LRCZ_Sc in ["SC00C", "SC00D"]
	for _LRCZ_Host in ["word", "excel", "other", "invalid", "failure"]
		Test("layout zoom: " . _LRCZ_Sc . " chooses its actual " . _LRCZ_Host . " host owner (layout-zoom-host-precedence)",
			_LRPS_LevelCustody.Bind(0, false, _LRCZ_ChildSource,
				[_LRCZ_Sc, _LRCZ_Host], "PASS layout-zoom-host-precedence"))

_LRNF_ChildSource() {
	return _LRPS_ChildSource("layout_row_native_flags_body.ahk")
}

; The virtual key this thread's active layout gives SC010, the physical key
; both native row probes inject and expect to type a letter.
_LRN_TopRowVk() => DllCall("MapVirtualKeyW", "UInt", 0x10, "UInt", 3, "UInt")

; Probed before the child opens its window, so a layout without a top-row
; letter neither activates a window nor injects a key.
_LRNF_Case(Mode) {
	TestRequireHostCapability(TestTopRowLetterReceipt.Bind(_LRN_TopRowVk()))
	_LRPS_LevelCustody(0, false, _LRNF_ChildSource,
		[Mode, "--allow-explicit-owned-edit-row-flags"], "PASS layout-row-native-flags")
}
for _LRNF_Mode in ["plain", "held", "released"]
	Test("layout row native modifier flags: " . _LRNF_Mode . " (layout-row-native-flags)", _LRNF_Case.Bind(_LRNF_Mode))

_LRNX_Receiver(Record, WParam, LParam, Message, Hwnd) {
	if Hwnd != Record["edit"].Hwnd || WParam != Record["vk"]
		return
	Record["received"] += 1
	if Record["received"] == 1 {
		Shift := !!(DllCall("GetKeyState", "Int", 0x10, "Short") & 0x8000)
		; What this keydown types under the Shift state it arrived with. The
		; receiver's own TranslateMessage was seen to run under the later state
		; (receipt Shift=1, Edit "q"), which proves nothing about the sender.
		Record["typed"] := _LRN_HostCharacter(WParam, Shift, DllCall("GetKeyboardLayout", "UInt", 0, "Ptr"))
		Extra := DllCall("GetMessageExtraInfo", "UPtr")
		Payload := Shift . "|" . Extra . "|" . WParam . "|" . Hwnd . "|" . DllCall("GetCurrentProcessId", "UInt")
		try {
			if !FSWriteCreateDurable(Record["receipt"], Payload)
				throw Error("the owned external receiver receipt could not be created")
		} catch as Err
			Record["failure"] := Err
	}
	return
}

_LRNX_Case(Mode) {
	global _DriverDir, _SharedDir
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("A prior external receiver probe retains its owned process/window retirement debt.")
	TopRowVk := _LRN_TopRowVk()
	TestRequireHostCapability(TestTopRowLetterReceipt.Bind(TopRowVk))
	Root := A_Temp . "\ergopti_external_row_flags_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Record := Map("window", 0, "edit", 0, "vk", 0, "receipt", Root . "\received.txt", "received", 0, "typed", "", "failure", 0)
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	Created := false, Handle := 0, Primary := 0, Receiver := _LRNX_Receiver.Bind(Record)
	PreviousCritical := Critical("Off")
	try {
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created)
		Script := Root . "\sender.ahk"
		Code := _LRPS_ChildSource("layout_row_external_flags_body.ahk")
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . Code) != 0)
		Record["window"] := Gui(, "Ergopti external native row receiver")
		Record["edit"] := Record["window"].AddEdit("w320 r3")
		Record["window"].Show()
		WinActivate("ahk_id " . Record["window"].Hwnd)
		AssertTrue(WinWaitActive("ahk_id " . Record["window"].Hwnd, , 2), "the parent-owned external receiver must acquire focus")
		Record["edit"].Focus()
		for Name in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			AssertTrue(!GetKeyState(Name, "P") && !GetKeyState(Name), "release modifiers before native external row input")
		Record["vk"] := TopRowVk
		AssertTrue(Record["vk"] >= 0x41 && Record["vk"] <= 0x5A)
		ExpectedHost := _LRN_HostCharacter(Record["vk"], Mode != "plain", DllCall("GetKeyboardLayout", "UInt", 0, "Ptr"))
		OnMessage(0x100, Receiver)
		Args := ["/ErrorStdOut=UTF-8", Script, "--allow-explicit-family-edit-row-flags", Mode,
			String(Record["window"].Hwnd), String(Record["edit"].Hwnd), String(DllCall("GetCurrentProcessId", "UInt")),
			String(Record["vk"]), Record["receipt"], _SharedDir]
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, Args, _LRPS_Completion.Bind(State))
		AssertTrue(Handle.start(), "the exact owned sender process must start separately from its receiving parent")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; Through the results file: the runner does not forward a test's raw stdout,
		; and this line is what tells a test-side translation race from a lost flag.
		ReceiverReceipt := ""
		try ReceiverReceipt := FileRead(Record["receipt"], "UTF-8")
		_TestPrint("# external-row-flags " . Mode . " code=" . State.Code . " received=" . Record["received"]
			. " receipt=" . ReceiverReceipt . " typed=" . Record["typed"] . " edit=" . Record["edit"].Value
			. " stdout=" . StrReplace(State.Output, "`n", " | ") . " stderr=" . StrReplace(State.ErrorText, "`n", " | "))
		AssertEqual(1, State.Calls, "the external sender must settle exactly once")
		AssertEqual(1, Record["received"], "the parent-owned receiver must actually observe exactly one keydown")
		AssertEqual(ExpectedHost, Record["typed"], "the keydown the separate process receives must carry the host character's modifiers")
		AssertEqual(1, StrLen(Record["edit"].Value), "the separate receiving process must obtain one character")
		AssertTrue(Record["edit"].Value = ExpectedHost, "the separate receiving process must obtain the host letter")
		if IsObject(Record["failure"])
			throw Record["failure"]
		AssertEqual(0, State.Code, "the native external row sender refused: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertTrue(InStr(State.Output, "PASS layout-row-external-native-flags") > 0)
	} catch as Err {
		Primary := Err
	}
	Retired := false
	try Retired := !IsObject(Handle) || ((Result := Handle.terminate()) is Integer && Result == 1)
	catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	if Retired {
		try {
			OnMessage(0x100, Receiver, 0)
			if IsObject(Record["window"])
				Record["window"].Destroy()
			if Created
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
	} else
		RetirementDebt := {Handle: Handle, Record: Record, Receiver: Receiver, Root: Root}
	Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the owned sender must retire before its external receiver is destroyed")
}

for _LRNX_Mode in ["plain", "held", "released"]
	Test("layout row external native modifier flags: " . _LRNX_Mode . " (layout-row-external-native-flags)", _LRNX_Case.Bind(_LRNX_Mode))
