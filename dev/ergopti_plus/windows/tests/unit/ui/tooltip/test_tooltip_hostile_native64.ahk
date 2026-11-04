; tests/unit/ui/tooltip/test_tooltip_hostile_native64.ahk

; ==============================================================================
; MODULE: Tooltip Hostile Process Native64 Cache Tests
; DESCRIPTION:
; Public prewarm entry arms the actual native callback. Genuine worker transport
; failures publish the cache; only its clock domain is projected in this child.
; ==============================================================================

#Requires AutoHotkey v2.0

_HUHT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

; Balanced offsets refer to raw text, so comments cannot silently remove clocks.
_HUHT_Raw(Source, Name) {
	Code := _DriverMaskNonCode(&Source)
	Definition := _DriverFindFunctionDefinition(&Code, Name, 1, true)
	AssertTrue(IsObject(Definition), "The actual owner must define " . Name)
	AssertFalse(IsObject(_DriverFindFunctionDefinition(&Code, Name, Definition.Idx + 1, true)),
		"The actual declaration must be unique: " . Name)
	Depth := 0, Position := Definition.OpenPos
	while Position <= StrLen(Code) {
		Character := SubStr(Code, Position, 1)
		if Character == "{"
			Depth += 1
		else if Character == "}" {
			Depth -= 1
			if Depth == 0
				return SubStr(Source, Definition.Idx, Position - Definition.Idx + 1)
		}
		Position += 1
	}
	throw Error("The actual declaration must be balanced: " . Name)
}

_HUHT_Tokens(Body, Name, Replacement, Expected) {
	Masked := _DriverMaskNonCode(&Body), Positions := [], Position := 1
	while Position := RegExMatch(Masked, "\b" . Name . "\b", &Token, Position) {
		Positions.Push({Start: Position, Length: Token.Len[0]})
		Position += Token.Len[0]
	}
	AssertEqual(Expected, Positions.Length, "The projected code-token count must be exact: " . Name)
	loop Positions.Length {
		Token := Positions[Positions.Length - A_Index + 1]
		Body := SubStr(Body, 1, Token.Start - 1) . Replacement . SubStr(Body, Token.Start + Token.Length)
	}
	return Body
}

_HUHT_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Owners := Map()
	for Symbol in ["TickElapsed", "UIASW_RequestBounds", "UIASW_RequestMessage", "WIGetForegroundHwnd",
		"KS_GetPhysicalInputEpoch", "_TooltipReadPositionReceipt", "TooltipPositionWarmStart",
		"_TooltipMeasureNewGdiReceipt", "_TooltipBorderNewGdiReceipt"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The child requires its genuine whole owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Code .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(9, Owners.Count, "Every whole component owner must be present")
	Tick := FSReadStrict(_DriverProductionFileForSymbol("TickElapsed"))
	for Name in ["TickExpired", "TickExpired64", "TickElapsed64"] {
		Body := _HUHT_Raw(Tick, Name)
		Body := _HUHT_Tokens(Body, Name, "_HUCT_" . Name, 1)
		if Name == "TickExpired64"
			Body := _HUHT_Tokens(Body, "TickElapsed64", "_HUCT_TickElapsed64", 1)
		else
			Body := _HUHT_Tokens(Body, "A_TickCount", "_HUCT_Clock(" . Chr(34) . Name . Chr(34) . ")", 1)
		Code .= Body . "`n"
	}
	Helpers := FSReadStrict(_DriverProductionFileForSymbol("_TooltipUiaProcessIsHostile"))
	Original := _HUHT_Raw(Helpers, "_TooltipMarkUiaHostile")
	Projected := _HUHT_Tokens(Original, "A_TickCount", '_HUCT_Clock("mark")', 1)
	Helpers := StrReplace(Helpers, Original, Projected, true, &Changed)
	AssertEqual(1, Changed, "Only the actual marker definition may change")
	Original := _HUHT_Raw(Helpers, "_TooltipUiaProcessIsHostile")
	Masked := _DriverMaskNonCode(&Original)
	AssertTrue(RegExMatch(Masked, "\b(TickExpired64|TickExpired)\s*\(", &Call) > 0,
		"The real predicate must call the canonical expiry helper")
	Projected := _HUHT_Tokens(Original, Call[1], "_HUCT_" . Call[1], 1)
	ClockCount := 0, Position := 1
	while Position := RegExMatch(Masked, "\bA_TickCount\b", &Clock, Position) {
		ClockCount += 1, Position += Clock.Len[0]
	}
	AssertTrue(ClockCount <= 1, "A future explicit predicate clock remains a bounded actual source read")
	Projected := _HUHT_Tokens(Projected, "A_TickCount", '_HUCT_Clock("query")', ClockCount)
	Helpers := StrReplace(Helpers, Original, Projected, true, &Changed)
	AssertEqual(1, Changed, "Only the actual predicate declaration may route to the private real-body alias")
	Code .= Helpers . "`n"
	Core := FSReadStrict(_DriverProductionFileForSymbol("TooltipShow"))
	for Name in ["_TooltipPositionCache", "_TooltipUiaProbePending", "TOOLTIP_POSITION_CACHE_MS",
		"TOOLTIP_POSITION_WARM_PERIOD_MS", "TOOLTIP_UIA_IDLE_REQUIRED_MS", "TOOLTIP_UIA_HOSTILE_TTL_MS", "_TooltipUiaHostileCache"] {
		AssertTrue(RegExMatch(Core, "m)^global " . Name . " :=[^`n]+", &Declaration) > 0,
			"The actual component initializer must exist: " . Name)
		Code .= Declaration[0] . "`n"
	}
	Adapter := FSReadStrict(_DriverProductionFileForSymbol("TooltipRSetPositionWarm"))
	for Name in ["TooltipRHasNativeCaret", "TooltipRScheduleRefinement", "TooltipRSetPositionWarm"] {
		Body := _HUHT_Raw(Adapter, Name)
		if Name == "TooltipRSetPositionWarm"
			Body := _HUHT_Tokens(Body, "SetTimer", "_HUCT_Timer", 2)
		Code .= Body . "`n"
	}
	Fixture := _DriverDir . "\tests\fixtures\tooltip_hostile_native64_body.ahk"
	AssertTrue(FileExist(Fixture), "The delivered child fixture must exist")
	return Code . "#Include " . Fixture . "`n"
}

_HUHT_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier tooltip prewarm child must retire first")
	Directory := A_Temp . "\ergopti_tooltip_hostile_native64_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _HUHT_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _HUHT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public tooltip prewarm child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact tooltip prewarm child did not settle within 15000 ms; calls at deadline: 0.")
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
			_TestPrint("# tooltip-hostile-native64 terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# tooltip-hostile-native64 combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# tooltip-hostile-native64 completion_error " . Line)
			} else
				_TestPrint("# tooltip-hostile-native64 combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact tooltip prewarm child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real tooltip prewarm violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS tooltip-hostile-native64 " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _HUHT_Mode in ["before", "exact", "long-gap", "modern-fresh", "stale-reply"]
	Test("Tooltip hostile native64: " . _HUHT_Mode . " preserves the real re-probe boundary (tooltip-hostile-native64-owner)",
		_HUHT_Case.Bind(_HUHT_Mode))
