; tests/unit/ui/webview/test_layer_editor_ready_delivery.ahk

; ==============================================================================
; MODULE: Layer Editor Readiness Delivery Tests
; DESCRIPTION:
; Real public host and resume/menu owners run in an isolated native child. The
; SDK is passive but its registered callbacks and the SUT timers remain real.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRDT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_LRDT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_LRDT_ChildSource() {
	global _DriverDir, _SharedDir
	Support := _DriverDir . "\tests\support\feature_state_boot_smoke.ahk"
	Source := FSReadStrict(Support)
	Boundary := InStr(Source, "`ntry {`n    if (A_Args.Length", true)
	AssertTrue(Boundary > 0, "The delivered boot graph must have its actual pre-execution boundary")
	Prefix := SubStr(Source, 1, Boundary - 1)
	for Name, Expression in Map("_ConfigDir", 'A_Args[2] . "\config\"',
		"_DriverDir", _LRDT_Quote(_DriverDir), "_SharedDir", _LRDT_Quote(_SharedDir)) {
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
	Seen := Map()
	for Symbol in ["LayerEditor_Open", "KeymapLayers_LoadContext", "WebView_SharedEnvironment",
		"Ergopti_OnSuspendResume", "_TrayRootErrorIsSilent", "LLM_DisplayIndentValues", "LLM_Menu_ApplySharedDefaults",
		"Keylayout_Parse", "LayoutRegistry_Keycodes", "MagicEditorRecordLayoutFallback",
		"KeylayoutEmulation_LayerIsActive", "NumberRowEffectiveMode", "GetForegroundKeyboardLayout",
		"LayoutRowsPolicyEmulates", "MasterGateDesiredTapHold", "TapHoldHoldLayer", "NavLayer_BuildTable", "WMPresentWindow"] {
		OwnerRoot := (Symbol == "LLM_DisplayIndentValues" || Symbol == "LayoutRowsPolicyEmulates")
			? _DriverDir . "\..\_shared" : _DriverDir
		Owner := _DriverProductionFileForSymbol(Symbol, OwnerRoot)
		AssertTrue(Owner != "", "The readiness child requires its genuine whole owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Code .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(18, Seen.Count, "The whole host, resume/menu and real data-policy owners must be nonempty and distinct")
	PromiseOwner := _DriverDir . "\vendor\Promise.ahk"
	Fixture := _DriverDir . "\tests\fixtures\layer_editor_ready_delivery_body.ahk"
	AssertTrue(FileExist(PromiseOwner) && FileExist(Fixture))
	return Code . "#Include " . PromiseOwner . "`n#Include " . Fixture . "`n"
}

_LRDT_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier layer editor child must retire first")
	Directory := A_Temp . "\ergopti_layer_ready_delivery_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory . "\64bit")
		; Availability must take its genuine filesystem branch. This inert marker
		; is never loaded: the browser factory is explicitly passive in the child.
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "private availability marker") != 0)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _LRDT_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, _SharedDir], _LRDT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public layer editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact layer editor child did not settle within 15000 ms; calls at deadline: 0.")
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
			_TestPrint("# layer-ready-delivery terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# layer-ready-delivery combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# layer-ready-delivery completion_error " . Line)
			} else
				_TestPrint("# layer-ready-delivery combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact layer editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real layer editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS layer-ready-delivery " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _LRDT_Mode in ["current", "paused-dispatch", "retired-epoch"]
	Test("Layer editor readiness: " . _LRDT_Mode . " retains only its admitted initialization (layer-editor-ready-delivery-owner)",
		_LRDT_Case.Bind(_LRDT_Mode))
