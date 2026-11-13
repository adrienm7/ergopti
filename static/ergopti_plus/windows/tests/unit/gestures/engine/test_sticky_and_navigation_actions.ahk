; tests/unit/gestures/engine/test_sticky_and_navigation_actions.ahk

; ==============================================================================
; MODULE: Sticky and Navigation Actions
; DESCRIPTION:
; The catalogue rows Windows gained: Home, End, Page Up and Down, Alt+Escape and
; the fourteen sticky combinations. Catalogue checks stay pure; native capture
; probes confine synthetic keyboard delivery to a child-owned verified Edit.
; ==============================================================================

#Requires AutoHotkey v2.0

_SNA_Names(ActionId) {
	Joined := ""
	for Name in StickyModifierNames(ActionId)
		Joined .= (Joined == "" ? "" : "+") . Name
	return Joined
}

_SNA_Sticky() {
	global GESTURE_ACTIONS, GESTURE_ACTION_CATALOGUE
	Expected := Map("sticky_ctrl", "Ctrl", "sticky_cmd", "Win", "sticky_option", "Alt",
		"sticky_cmd_shift", "Win+Shift", "sticky_cmd_option", "Win+Alt", "sticky_cmd_ctrl", "Win+Ctrl",
		"sticky_option_shift", "Alt+Shift", "sticky_option_ctrl", "Alt+Ctrl", "sticky_ctrl_shift", "Ctrl+Shift",
		"sticky_cmd_option_shift", "Win+Alt+Shift", "sticky_cmd_option_ctrl", "Win+Alt+Ctrl",
		"sticky_cmd_shift_ctrl", "Win+Shift+Ctrl", "sticky_option_shift_ctrl", "Alt+Shift+Ctrl",
		"sticky_hyper", "Ctrl+Alt+Shift+Win")
	AssertEqual(14, Expected.Count)
	for Id, Names in Expected {
		AssertEqual(Names, _SNA_Names(Id), Id . " holds its modifiers")
		AssertTrue(GESTURE_ACTIONS.Has(Id), Id . " has a handler")
		AssertTrue(GESTURE_ACTION_CATALOGUE.Actions.Has(Id), Id . " is offered on Windows")
		Label := _GestureActionLabel(Id)
		AssertFalse(InStr(Label, "Cmd", true) || InStr(Label, "Option", true), Id . " names Windows's keys: " . Label)
		; The label is a template its modifiers fill from the key name table: it
		; used to spell macOS's English names and swap two of them (2026-11-03).
		AssertFalse(InStr(Label, "{1}"), Id . " fills its template: " . Label)
		if (Id != "sticky_hyper") {
			Named := ""
			for Name in StrSplit(Names, "+")
				Named .= (Named == "" ? "" : " + ") . KeyNameLabel(Name)
			AssertTrue(InStr(Label, Named, true) > 0, Id . " names " . Named . ": " . Label)
		}
	}
	Refused := false
	try StickyModifierNames("sticky_fn")
	catch ValueError
		Refused := true
	AssertTrue(Refused, "an unknown modifier is refused, never dropped")
}
Test("sticky actions: the fourteen combinations hold their modifiers (sticky-actions)", _SNA_Sticky)

_SNA_Navigation() {
	global GESTURE_ACTIONS, GESTURE_ACTION_CATALOGUE
	for Id in ["home", "end", "page_up", "page_down", "app_window_previous"] {
		AssertTrue(GESTURE_ACTIONS.Has(Id), Id . " has a handler")
		AssertTrue(GESTURE_ACTION_CATALOGUE.Actions.Has(Id), Id . " is offered on Windows")
	}
}
Test("navigation actions: the emitted rows are offered on Windows (sticky-actions)", _SNA_Navigation)

_SNA_NativeChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Owner := _DriverProductionFileForSymbol("SIHO_StartOwned")
	AssertTrue(Owner != "", "The actual SIHO registry must have a canonical owner.")
	Code .= "#Include " . Owner . "`n"
	for Name in ["StickyModifierNames", "StickyModifierConfigureHook", "StickyModifier", "KS_AltGrKeyName", "KS_AltGrSendKey"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "The complete actual sticky owner must exist: " . Name)
		Code .= Body . "`n"
	}
	Code .= 'global _ALTGR_KANA_FIXUP := false, _ALTGR_LAYOUT_PROBE := Map("altgr_vk", 0)' . "`n"
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\sticky_nontext_probe_body.ahk")
}
_SNA_NativeCase(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired native probe prevents another keyboard sender.")
	Root := A_Temp . "\ergopti_sticky_native_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Script := Root . "\subject.ahk"
	Created := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}, Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The native sticky fixture must exclusively acquire its source directory before writing or cleanup.")
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SNA_NativeChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-edit-sendevent", Mode], _SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine sticky child must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "The owned sticky child must settle once.")
		_TestPrint("# sticky-native " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(0, State.Code, "Native sticky capture failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "Native diagnostics may not be hidden.")
		AssertContains(State.Output, "PASS sticky-nontext " . Mode)
	} catch as Err {
		Primary := Err
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Accepted := Handle.terminate()
				Retired := Accepted is Integer && Accepted == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if Created && !Retired
			RetirementDebt := {Handle: Handle, Directory: Root}
		else if Created && !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The sender and actual InputHook must physically retire.")
}
for _SNA_NativeMode in ["letter", "enter", "backspace"]
	Test("Sticky native capture: " . _SNA_NativeMode . " suppresses the original before replay (sticky-native-nontext)",
		_SNA_NativeCase.Bind(_SNA_NativeMode))

_SSM_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Code .= "#Include " . _DriverDir . "\_generated\config_keys.ahk`n"
	for Symbol in ["SIHO_StartOwned", "HS_RunSyntheticInputTransaction", "_TextCompleteTailScalar"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The real transaction dependency must exist: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["StickyModifierNames", "StickyModifierConfigureHook", "StickyModifier", "KS_AltGrKeyName", "KS_AltGrSendKey", "TextPressKey", "_TextSenderNormalizeModifierKey",
		"_TextSenderModifierPrefix", "_TextSenderKeystroke", "_TextSenderModifierWords", "_TextSenderSustainedKey",
		"_TextSenderSendInput", "_TextSenderAtSendLevel", "_SendVerdictSucceeded", "HSE_WordResetFlagCurrent",
		"_PrefixHasIncompleteFragment", "TapHoldOwnsShortcut", "TapHoldTapInDispatch",
		"_TH_SyntheticKeyList", "_TH_HoldMakesShortcuts"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "The complete unchanged native producer must exist: " . Name)
		Code .= Body . "`n"
	}
	Code .= 'global _ALTGR_KANA_FIXUP := false, _ALTGR_LAYOUT_PROBE := Map("altgr_vk", 0)' . "`n"
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\sticky_modifier_flags_body.ahk")
}
_SSM_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired native sender prevents another probe.")
	Root := A_Temp . "\ergopti_sticky_flags_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Script := Root . "\subject.ahk"
	Created := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}, Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The native modifier fixture requires an exclusively acquired source directory before publication or cleanup.")
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SSM_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-edit-native-modifiers", Mode], _SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native flags child must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "The exact native flags child must settle.")
		_TestPrint("# sticky-native-flags " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(0, State.Code, "Native sticky flag preservation failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS sticky-native-flags " . Mode)
	} catch as Err {
		Primary := Err
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Accepted := Handle.terminate()
				Retired := Accepted is Integer && Accepted == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if Created && !Retired
			RetirementDebt := {Handle: Handle, Directory: Root}
		else if Created && !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The native sender and capture must physically retire.")
}
for _SSM_Mode in ["plain", "shift"]
	Test("Sticky native modifier flags: " . _SSM_Mode . " preserves captured modifiers through the real synthetic transaction (sticky-native-modifier-flags)",
		_SSM_Case.Bind(_SSM_Mode))

; The configuration trace exercises the genuine layout helpers without an
; installed Kana layout or native injection. Native receivers test delivery.
class _SKC_HookTrace {
	__New() {
		this.VisibleNonText := true
		this.Options := []
	}
	KeyOpt(Keys, Options) {
		this.Options.Push({Keys: Keys, Options: Options})
	}
}
_SKC_Configure() {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	SavedKana := _ALTGR_KANA_FIXUP, SavedProbe := _ALTGR_LAYOUT_PROBE
	PreviousCritical := Critical("On")
	try {
		for Row in [{Kana: false, Vk: 0, Keys: []}, {Kana: false, Vk: 0xDF, Keys: []},
			{Kana: true, Vk: 0xDF, Keys: ["{SC138}", "{vkDF}"]},
			{Kana: true, Vk: 0x15, Keys: ["{SC138}", "{vk15}"]},
			{Kana: true, Vk: 0, Keys: ["{SC138}"]}] {
			_ALTGR_KANA_FIXUP := Row.Kana
			_ALTGR_LAYOUT_PROBE := Map("altgr_vk", Row.Vk)
			Hook := _SKC_HookTrace()
			StickyModifierConfigureHook(Hook)
			AssertFalse(Hook.VisibleNonText, "ordinary endpoints must suppress their original key")
			AssertEqual(2 + Row.Keys.Length, Hook.Options.Length)
			AssertEqual("{All}", Hook.Options[1].Keys)
			AssertEqual("E", Hook.Options[1].Options)
			AssertEqual("{LCtrl}{RCtrl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}", Hook.Options[2].Keys)
			AssertEqual("-E+V", Hook.Options[2].Options, "every standard modifier stays visible and does not end capture")
			for Index, Key in Row.Keys {
				AssertEqual(Key, Hook.Options[Index + 2].Keys, "both native Kana option tables must be updated")
				AssertEqual("-E+V", Hook.Options[Index + 2].Options, "Kana must pass through and leave the following key to consume sticky state")
			}
		}
	} finally {
		_ALTGR_KANA_FIXUP := SavedKana, _ALTGR_LAYOUT_PROBE := SavedProbe
		Critical(PreviousCritical)
	}
}
Test("Sticky Kana configuration: both native identities pass without consuming capture (sticky-kana-capture-options)", _SKC_Configure)

; These are state-machine units using actual InputHook callback registrations;
; they do not claim native event delivery (the owned Edit cases cover that).
_SKER_Case(Mode) {
	Hook := InputHook("L0"), Other := InputHook("L0"), Receipt := 0
	try {
		if Mode == "invalid-send" {
			AssertFalse(_SIHO_CustomModifierCapture(Hook, "SC138", ""))
			AssertEqual("", Hook.OnKeyDown)
			AssertEqual("", Hook.OnKeyUp)
			AssertEqual("", Hook.OnEnd)
			return
		}
		Receipt := _SIHO_CustomModifierCapture(Hook, "SC138", "vkDF")
		AssertTrue(IsObject(Receipt) && Receipt.hook == Hook)
		AssertTrue(HasMethod(Hook.OnKeyDown, "Call") && HasMethod(Hook.OnKeyUp, "Call") && HasMethod(Hook.OnEnd, "Call"))
		if Mode == "foreign-hook" {
			Before := Receipt.down
			_SIHO_CustomModifierKey(Receipt, !Before, Other, 0xDF, 0x138)
			_SIHO_CustomModifierEnd(Receipt, Other)
			AssertEqual(Before, Receipt.down)
			AssertFalse(Receipt.ended, "A different native object cannot settle this private capture")
		} else {
			Hook.OnKeyDown.Call(Hook, 0xDF, 0x138)
			if Mode == "up-before-end"
				Hook.OnKeyUp.Call(Hook, 0xDF, 0x138)
			Hook.OnEnd.Call(Hook)
			Expected := Mode != "up-before-end"
			AssertTrue(Receipt.ended)
			AssertEqual(Expected, Receipt.held)
			; Neither a late Up nor a late Down may change endpoint evidence.
			Hook.OnKeyUp.Call(Hook, 0xDF, 0x138)
			Hook.OnKeyDown.Call(Hook, 0xDF, 0x138)
			AssertEqual(Expected, Receipt.held)
			if Mode == "retired-ack"
				AssertFalse(_SIHO_CustomModifierSettle(Receipt, Hook, 0),
					"Callback completion alone cannot admit replay without the exact SIHO owner")
		}
	} finally {
		if IsObject(Receipt) {
			_SIHO_CustomModifierRelease(Receipt, Hook)
			AssertFalse(Receipt.active)
			AssertEqual(0, Receipt.hook)
			AssertEqual("", Hook.OnKeyDown)
			AssertEqual("", Hook.OnKeyUp)
			AssertEqual("", Hook.OnEnd)
		}
	}
}
for _SKER_Mode in ["held-end", "up-before-end", "foreign-hook", "retired-ack", "invalid-send"]
	Test("Sticky custom endpoint receipt: " . _SKER_Mode . " retains exact callback ownership (sticky-custom-endpoint-receipt)",
		_SKER_Case.Bind(_SKER_Mode))
