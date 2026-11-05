; tests/unit/ui/webview/test_prompt_startup_owner.ahk

; ==============================================================================
; MODULE: Prompt Editor Startup Cancellation Tests
; DESCRIPTION:
; The public profile editor uses a genuinely boot-admitted private config in an
; owned child. Native GUI/WM_CLOSE and shipped Promise scheduling remain real;
; only browser construction, translation/theming and fallback input are passive.
; ==============================================================================

#Requires AutoHotkey v2.0

_PRST_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_PRST_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

; Reuse the delivered native boot graph before its actual execution switch.
; Only private root declarations and include resolution change; no READY map,
; migration step or production function is copied into this fixture.
_PRST_ChildSource() {
	global _DriverDir, _SharedDir
	Support := _DriverDir . "\tests\support\feature_state_boot_smoke.ahk"
	Source := FSReadStrict(Support)
	Boundary := InStr(Source, "`ntry {`n    if (A_Args.Length", true)
	AssertTrue(Boundary > 0, "The delivered boot support must expose its pre-execution graph")
	Prefix := SubStr(Source, 1, Boundary - 1)
	for Name, Expression in Map("_ConfigDir", 'A_Args[2] . "\config\"',
		"_DriverDir", _PRST_Quote(_DriverDir), "_SharedDir", _PRST_Quote(_SharedDir)) {
		Prefix := RegExReplace(Prefix, "m)^global " . Name . " :=[^`n]+", "global " . Name . " := " . Expression, &Count)
		AssertEqual(1, Count, "Only this private declaration may change: " . Name)
	}
	SplitPath(Support, , &SupportDir)
	Code := ""
	for Line in StrSplit(Prefix, "`n") {
		if RegExMatch(Line, "^#Include\s+(.+)$", &Include)
			Line := "#Include " . SupportDir . "\" . Include[1]
		Code .= Line . "`n"
	}
	Owners := Map()
	for Symbol in ["LLM_Menu_PromptEditProfile", "_PromptEdWeb_TryOpen", "_LLM_MenuApiJsonEscape", "Ui_InputBox"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The prompt child requires its whole genuine owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Code .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(4, Owners.Count, "The public profile, editor, serializer and default dialog owners must be distinct")
	; The opening receipt covers the full persisted LLM projection. Keep the
	; authored state initializer and genuine normalizers, not a three-field menu.
	for Spec in [["_LLM_Menu_SyncToFeatures", _DriverDir], ["LLM_Option_TryNormalize", _DriverDir],
		["ChordParse", _DriverDir], ["_LLM_RequestPlanRequireDelay", _DriverDir],
		["LLM_DisplayStreamingCapable", _SharedDir]] {
		Owner := _DriverProductionFileForSymbol(Spec[1], Spec[2])
		AssertTrue(Owner != "", "The projection component requires its genuine owner: " . Spec[1])
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Code .= "#Include " . Owner . "`n"
		}
	}
	for Symbol in ["LLM_BackendCapabilities", "LLM_EffectiveStreaming"]
		Code .= _DriverFuncBody(Symbol) . "`n"
	StateOwner := _DriverProductionFileForSymbol("LLM_Menu_ApplySharedDefaults")
	StateSource := FileRead(StateOwner, "UTF-8")
	AssertTrue(RegExMatch(StateSource, "ms)^global _LLM_Menu := Map\(.*?^\)", &StateDefinition) > 0,
		"The component must retain the complete unmodified authored menu initializer")
	Code .= StateDefinition[0] . "`n"
	Code .= "global Features := ManifestBuildFeaturesMap()`n"
	PromiseOwner := _DriverDir . "\vendor\Promise.ahk"
	Fixture := _DriverDir . "\tests\fixtures\prompt_startup_owner_body.ahk"
	AssertTrue(FileExist(PromiseOwner) && FileExist(Fixture))
	return Code . "#Include " . PromiseOwner . "`n#Include " . Fixture . "`n"
}

_PRST_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier prompt editor child must retire first")
	Directory := A_Temp . "\ergopti_prompt_startup_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	AssertEqual(1, FSCreateDirectoryExclusiveStrict(Directory), "The exact child root must be exclusively acquired before cleanup authority exists")
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertEqual(1, FSCreateDirectoryExclusiveStrict(Directory . "\64bit"), "The private browser marker directory must be exclusively acquired")
		; Availability must take its genuine filesystem branch. This inert marker
		; is never loaded: the browser factory is explicitly passive in the child.
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "private availability marker") != 0)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PRST_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _PRST_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public prompt editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact prompt editor child did not settle within 15000 ms; calls at deadline: 0.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := { Handle: Handle, Directory: Directory }
			Critical(PreviousCritical)
		}
	}
	; The native adapter merges its child's stdout/stderr into Output. ErrorText
	; is a completion diagnostic, not an independently measured stderr stream.
	try {
		if Retired {
			_TestPrint("# prompt-startup terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# prompt-startup combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# prompt-startup completion_error " . Line)
			} else
				_TestPrint("# prompt-startup combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact prompt editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real prompt editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS prompt-startup " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _PRST_Mode in ["current", "close-create", "reopen-create"]
	Test("Prompt editor startup: " . _PRST_Mode . " retains only its current owner (prompt-startup-owner)",
		_PRST_Case.Bind(_PRST_Mode))

#Include test_prompt_navigation_custody.ahk

for _PRST_SubscriptionMode in ["subscription-current", "subscription-close"]
	Test("Prompt editor add-event retirement: " . _PRST_SubscriptionMode . " owns the real HWND (prompt-native-subscription-retirement-owner)",
		_PRST_Case.Bind(_PRST_SubscriptionMode))

for _PRST_SdkMode in ["subscription-throw-current", "subscription-throw-retired"]
	Test("Prompt editor SDK refusal: " . _PRST_SdkMode . " preserves its original disposition (prompt-subscription-sdk-failure-owner)",
		_PRST_Case.Bind(_PRST_SdkMode))

for _PRST_RetryMode in ["retry-current", "retry-reentry"]
	Test("Prompt initial retirement: " . _PRST_RetryMode . " preserves intervening native cancellation (prompt-native-initial-retirement-reentry)",
		_PRST_Case.Bind(_PRST_RetryMode))
