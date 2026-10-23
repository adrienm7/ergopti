; tests/unit/modules/shortcuts/test_keepawake_timer_owner.ahk

; ==============================================================================
; MODULE: Keep-Awake Deferred Cancellation Ownership Tests
; DESCRIPTION:
; Real session Start/Stop and native InputHooks surround a retained native timer.
; Mouse position is passive. The timer port observes delivery and delegates the
; actual callback; it never replaces the cancellation implementation.
; ==============================================================================

#Requires AutoHotkey v2.0

_KATO_Quote(Text) {
	return JsonStringLiteral(Text)
}

_KATO_Owner() {
	SplitPath(A_ScriptDir, , &Root)
	Owners := []
	Loop Files, Root . "\*.ahk", "FR" {
		Path := A_LoopFileFullPath
		if !_DriverIsProductionSource(Path)
			continue
		Text := FSReadStrict(Path)
		Definition := _DriverFindFunctionDefinition(&Text, "AwakeCheckMouseMoved")
		if !IsObject(Definition)
			continue
		AssertFalse(IsObject(_DriverFindFunctionDefinition(&Text,
			"AwakeCheckMouseMoved", Definition.OpenPos + 1)))
		Owners.Push(Path)
	}
	AssertEqual(1, Owners.Length, "the conditional movement callback must have one authored owner")
	return Owners[1]
}

; Keep the exact source span, including comments and strings, while balancing
; the genuine code mask. Rewriting only named bodies leaves sibling sites intact.
_KATO_Bind(&Source, Name, Needle, Replacement, Expected) {
	Code := _DriverMaskNonCode(&Source)
	Definition := _DriverFindFunctionDefinition(&Code, Name, 1, true)
	AssertTrue(IsObject(Definition), "the real subject function must exist: " . Name)
	Depth := 1, End := Definition.OpenPos
	while Depth && End < StrLen(Code) {
		End += 1
		Char := SubStr(Code, End, 1)
		Depth += Char == "{" ? 1 : Char == "}" ? -1 : 0
	}
	AssertEqual(0, Depth, "the real subject body must close")
	Block := SubStr(Source, Definition.Idx, End - Definition.Idx + 1)
	MaskedBlock := SubStr(Code, Definition.Idx, End - Definition.Idx + 1)
	StrReplace(MaskedBlock, Needle, "", true, &Sites)
	AssertEqual(Expected, Sites, "the exact native boundary cardinality must remain explicit: " . Name)
	Bound := StrReplace(Block, Needle, Replacement, true, &Bindings)
	AssertEqual(Sites, Bindings, "no comment or string may add an unowned substitution")
	Source := SubStr(Source, 1, Definition.Idx - 1) . Bound . SubStr(Source, End + 1)
	return Bindings
}

_KATO_Source(Receipt) {
	global _DriverDir
	Owner := _KATO_Owner(), Original := FSReadStrict(Owner)
	for Name in ["StartActivitySimulation", "StopActivitySimulation", "AwakeStopCancellationHook",
		"AwakeCreateCancellationHook", "AwakeCheckMouseMoved", "SimulateActivity"]
		AssertTrue(_DriverExtractFunctionBody(&Original, Name) != "", "the authentic subject must be nonempty: " . Name)
	Start := _DriverFindFunctionDefinition(&Original, "StartActivitySimulation")
	DeclarationsStart := InStr(Original, "global AWAKE_TICK_MIN_MS", true)
	AssertTrue(DeclarationsStart > 0 && DeclarationsStart < Start.Idx)
	Declarations := SubStr(Original, DeclarationsStart, Start.Idx - DeclarationsStart)
	DeclarationsCode := _DriverMaskNonCode(&Declarations)
	AssertFalse(InStr(DeclarationsCode, "(", true), "only the real inactive state declarations may be replayed")
	RegExReplace(DeclarationsCode, "m)^\s*global\b", "", &DeclarationCount)
	AssertTrue(DeclarationCount >= 6, "all original session defaults must be present")
	Bound := Original
	MouseBindings := _KATO_Bind(&Bound, "StartActivitySimulation", "MouseGetPos(", "_KATO_MouseGetPos(", 1)
	MouseBindings += _KATO_Bind(&Bound, "AwakeCheckMouseMoved", "MouseGetPos(", "_KATO_MouseGetPos(", 1)
	; Every SetTimer call in this whole subject owner uses one identity-preserving
	; arm/cancel proxy. A future cancel-only repair must cancel the same wrapper.
	BoundCode := _DriverMaskNonCode(&Bound)
	RegExReplace(BoundCode, "(?<![\w])SetTimer\(", "", &TimerSites)
	AssertTrue(TimerSites > 0, "the actual timer boundary must be nonempty")
	TimerCensus := Map(), SearchFrom := 1, CensusSites := 0
	while RegExMatch(BoundCode, "im)^\s*([A-Za-z_][A-Za-z0-9_]*)\(", &Candidate, SearchFrom) {
		Name := Candidate[1], SearchFrom := Candidate.Pos + Candidate.Len
		if Name == "if" || Name == "while" || Name == "switch" || TimerCensus.Has(Name)
			continue
		Body := _DriverExtractFunctionBody(&Bound, Name)
		if Body == ""
			continue
		BodyCode := _DriverMaskNonCode(&Body)
		RegExReplace(BodyCode, "(?<![\w])SetTimer\(", "", &Count)
		if Count {
			TimerCensus[Name] := Count
			CensusSites += Count
		}
	}
	AssertTrue(TimerCensus.Count > 0, "the real source scan must find a function that actually arms timers")
	AssertEqual(TimerSites, CensusSites, "every timer binding must belong to one censused genuine function body")
	Receipt["timer_body_census"] := TimerCensus
	Bound := RegExReplace(Bound, "(?<![\w])SetTimer\(", "_KATO_Timer(", &TimerBindings)
	AssertEqual(TimerSites, TimerBindings, "no comments or strings may add timer substitutions")
	Receipt["owner"] := Owner
	Receipt["owner_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(Owner))
	Receipt["bound_owner_sha256"] := CryptoSha256(Bound)
	Receipt["mouse_bindings"] := MouseBindings, Receipt["timer_bindings"] := TimerBindings
	Receipt["declaration_count"] := DeclarationCount
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Source .= 'global _KATO_ActualOwnerHash := ' . _KATO_Quote(Receipt["owner_sha256"]) . "`n"
	Source .= 'global Features := Map("shortcuts", Map())' . "`n"
	Source .= 'Features["shortcuts"].Default := false' . "`n"
	for Nested in ["gpt", "take_note", "search"]
		Source .= 'Features["shortcuts"]["' . Nested . '"] := Map("enabled", false)' . "`n"
	Seen := Map()
	for Symbol in ["LoggerInfo", "WallClockTimestamp", "KS_AltGrKeyName", "CryptoSha256Bytes",
		"KL_JsonEncode", "JsonStringLiteral", "t"] {
		Path := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Path != "" && _DriverFuncBody(Symbol) != "", "the real child dependency must resolve: " . Symbol)
		if !Seen.Has(Path) {
			Source .= "#Include " . Path . "`n"
			Seen[Path] := true
		}
	}
	BodyPath := _DriverDir . "\tests\fixtures\keepawake_timer_owner_body.ahk"
	Body := FSReadStrict(BodyPath)
	AssertTrue(Body != "")
	Receipt["fixture_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(BodyPath))
	return Chr(0xFEFF) . Source . Bound . "`n" . Declarations . "`n" . Body
}

_KATO_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_KATO_Case(Mode) {
	static Serial := 0, RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "an unretired native observer child forbids another launch")
	Root := A_Temp . "\ergopti_awake_timer_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	Script := Root . "\subject.ahk", Owners := Map()
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		AssertEqual(1, FSWriteCreateDurable(Script, _KATO_Source(Owners)))
		Hash := CryptoSha256Bytes(FSReadBytesStrict(Script))
		RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
		_TestPrint("# keepawake-timer-source-built " . KL_JsonEncode(Map("mode", Mode,
			"source_sha256", Hash, "runtime_sha256", RuntimeHash, "owners", Owners)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Owners["owner_sha256"], Hash, RuntimeHash], _KATO_Done.Bind(State))
		AssertEqual(1, Handle.start(), "the exact native timer child must start")
		Pid := Handle.processId(), Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "native Start or callback settlement prerequisite failed: " . State.Output . State.ErrorText)
		Receipt := 0
		for Line in StrSplit(State.Output, "`n", "`r") {
			if InStr(Line, "OBSERVATION ") == 1
				_TestPrint("# keepawake-timer " . Line)
			else if InStr(Line, "RECEIPT ") == 1 {
				AssertFalse(IsObject(Receipt))
				Receipt := JsonParse(SubStr(Line, 9))
				_TestPrint("# keepawake-timer " . Line)
			}
		}
		AssertEqual(0, State.Code, "the authentic session cancellation failed: " . State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertTrue(Receipt is Map)
		for Pair in [["pid", Pid], ["mode", Mode], ["source_sha256", Hash], ["runtime_sha256", RuntimeHash],
			["owner_sha256", Owners["owner_sha256"]], ["subject_arms", 1],
			["hooks_retired", 1], ["mouse_injected", 0], ["suspended", 0]]
			AssertEqual(Pair[2], Receipt[Pair[1]], "the terminal receipt must bind actual native cleanup: " . Pair[1])
	} catch Any as Failure {
		Primary := Failure
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Ack := Handle.terminate()
				Retired := Ack is Integer && Ack == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	; Physical ownership debt is published before any diagnostic writer can fail.
	if !Retired
		RetirementDebt := Handle
	ExportFailure := 0
	try {
		if IsObject(Primary)
			_TestPrint("# keepawake-timer-final-capture " . KL_JsonEncode(Map("mode", Mode, "retired", Retired,
				"capture_delivered", State.Calls == 1, "capture_state", State.Calls == 1 ? "DELIVERED" : "UNKNOWN",
				"calls", State.Calls, "exit_code", State.Code, "combined_native_capture", SubStr(State.Output, 1, 16000),
				"completion_error", SubStr(State.ErrorText, 1, 8000))))
	} catch Any as Failure {
		ExportFailure := Failure
	}
	try {
		if Retired && !IsObject(Primary) && !IsObject(ExportFailure)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the exact native hook child must physically retire")
	if IsObject(ExportFailure)
		throw ExportFailure

}

for _KATO_Mode in ["retired-session", "current-session"]
	Test("Keep-awake timer ownership: " . _KATO_Mode . " preserves exact session cancellation (keepawake-timer-owner)",
		_KATO_Case.Bind(_KATO_Mode))
