; tests/unit/modules/keymap/test_number_row_native_hkl.ahk

; ==============================================================================
; MODULE: Number Row Native HKL and Direct Digits
; DESCRIPTION:
; The native HKL number-row adapter keeps French and US descriptors,
; CapsLock and dead-key status as native observations and refuses
; malformed inputs, and the direct-digit source and producer issue nothing
; before genuine registration.
; ==============================================================================

#Requires AutoHotkey v2.0





; Native-HKL observations are deliberately separate from the qualified KLE
; output owner. The frozen ten-key corpus remains the independent native oracle.
_NHKL_RealNumberRowDescriptors() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\number_row_levels.json", "UTF-8"))
	Checked := 0
	for Native in Corpus["native"] {
		Hkl := _LDRP_Layout(Native["klid"])
		if Hkl == 0
			continue
		Observed := KS_NativeNumberRowLevels(Hkl, false)
		AssertTrue(Observed is Map, "the actual native source must supply a complete observation")
		AssertEqual(Hkl, Observed["hkl"])
		AssertEqual(false, Observed["caps"])
		AssertEqual(10, Observed["rows"].Count)
		for Index, Name in Corpus["scancodes"] {
			Scancode := Integer("0x" . SubStr(Name, 3))
			Row := Observed["rows"][Scancode]
			for Level in ["plain", "shift"] {
				AssertEqual("text", Row[Level]["Kind"], "the independent French/US vectors are genuine text")
				AssertEqual(Native[Level][Index], Row[Level]["Text"], "native probe must match the frozen independent level")
				AssertEqual(1, Row[Level]["Count"])
			}
			; Existing shared selection receives only native text previews, without
			; claiming their observation is the physical-delivery/source receipt.
			Selection := NumberRowPolicySymbolsShift(Corpus["digits"][Index], Row["plain"], Row["shift"])
			AssertTrue(Selection["supported"])
			AssertEqual(!Native["swapped"], Selection["shift"])
		}
		Checked += 1
	}
	AssertTrue(Checked > 0, "one real native layout is required")
	if EnvGet("GITHUB_ACTIONS") == "true"
		AssertEqual(2, Checked, "both independently specified HKLs must execute in native CI")
}
Test("native HKL number row: actual French/US descriptors match the frozen ten-key corpus", _NHKL_RealNumberRowDescriptors)

_NHKL_RealCapsAndDeadDescriptors() {
	global _SharedDir
	Qwerty := _LDRP_Layout("00000409")
	if Qwerty != 0 {
		Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\number_row_levels.json", "UTF-8"))
		Expected := Corpus["native"][2]
		Observed := KS_NativeNumberRowLevels(Qwerty, true)
		AssertTrue(Observed is Map)
		AssertEqual(true, Observed["caps"])
		for Index, Name in Corpus["scancodes"] {
			Row := Observed["rows"][Integer("0x" . SubStr(Name, 3))]
			AssertEqual(Expected["plain"][Index], Row["plain"]["Text"], "US CapsLock must preserve real digit output")
			AssertEqual(Expected["shift"][Index], Row["shift"]["Text"], "US CapsLock must preserve real Shift symbols")
		}
	}
	French := _LDRP_Layout("0000040C")
	if French != 0 {
		Dead := KS_NativeKeyLevel(KS_ScancodeToVk(0x1A, French), 0x1A, French, false, false)
		AssertTrue(Dead is Map)
		AssertEqual("dead", Dead["Kind"], "the real French circumflex key must retain negative native status")
		AssertEqual(-1, Dead["Count"])
		AssertEqual("^", Dead["Text"])
		AssertFalse(Dead.Has("Action"), "native preview must not invent a KLE state-machine action")
		AssertFalse(Dead.Has("State"), "native preview cannot impersonate a KLE dead state")
		AssertFalse(NumberRowPolicySymbolsShift("1", Map("Kind", "text", "Text", "1"), Dead)["supported"],
			"a native dead preview is not permission to flatten or deliver the dead key")
	}
	if EnvGet("GITHUB_ACTIONS") == "true"
		AssertTrue(Qwerty != 0 && French != 0, "CI must execute CapsLock and native dead-key controls")
}
Test("native HKL number row: actual CapsLock and dead-key status remain native observations", _NHKL_RealCapsAndDeadDescriptors)

_NHKL_RecordRead(Seen, Vk, Scancode, Hkl, Shift, Caps) {
	Seen.Push([Vk, Scancode, Hkl, Shift, Caps])
	return {Count: 1, Text: Shift ? "!" : "1"}
}
_NHKL_RecordMap(Seen, Scancode, Hkl) {
	Seen.Push([Scancode, Hkl])
	return 0x31
}
_NHKL_ExplicitInputs() {
	global KS_DIGIT_ROW_KEYS
	for Caps in [false, true] {
		Reads := [], Mappings := []
		Observed := KS_NativeNumberRowLevels(-268435447, Caps,
			_NHKL_RecordRead.Bind(Reads), _NHKL_RecordMap.Bind(Mappings))
		AssertTrue(Observed is Map)
		AssertEqual(20, Reads.Length, "all ten positions need both original native levels")
		AssertEqual(10, Mappings.Length)
		for Index, Key in KS_DIGIT_ROW_KEYS {
			AssertEqual(Key[2], Mappings[Index][1], "mapping must use the actual physical scan code")
			AssertEqual(-268435447, Mappings[Index][2], "mapping must use the explicitly selected HKL")
			for Offset, Shift in [false, true] {
				Read := Reads[(Index - 1) * 2 + Offset]
				AssertEqual(0x31, Read[1], "observation must use that HKL's mapped VK")
				AssertEqual(Key[2], Read[2])
				AssertEqual(-268435447, Read[3])
				AssertEqual(Shift, Read[4])
				AssertEqual(Caps, Read[5], "CapsLock is explicit for each level, not read from a later physical state")
			}
		}
		AssertFalse(Observed.Has("owner"), "an observation cannot fabricate a source or native-output owner")
		AssertFalse(NumberRowPolicyReady(Observed, "symbols"))
	}
}
Test("native HKL number row: explicit source scan codes and CapsLock cross the actual adapter boundary", _NHKL_ExplicitInputs)

_NHKL_ThrowRead(*) {
	throw Error("private native observation detail must not leave the boundary")
}
_NHKL_ClosedRefusals() {
	Reads := []
	for Hkl in [0, "1", 1.0] {
		AssertEqual(0, KS_NativeNumberRowLevels(Hkl, false, _NHKL_RecordRead.Bind(Reads), (*) => 0x31))
	}
	for Caps in ["0", "false", 2, 0.0] {
		AssertEqual(0, KS_NativeNumberRowLevels(1, Caps, _NHKL_RecordRead.Bind(Reads), (*) => 0x31))
	}
	for Shift in ["0", "false", 2, 0.0] {
		AssertEqual(0, KS_NativeKeyLevel(0x31, 0x02, 1, Shift, false, _NHKL_RecordRead.Bind(Reads)))
	}
	for Vk in [0, 0x100, "49", 49.0] {
		AssertEqual(0, KS_NativeKeyLevel(Vk, 0x02, 1, false, false, _NHKL_RecordRead.Bind(Reads)))
	}
	for Scancode in [0, 0x200, "2", 2.0] {
		AssertEqual(0, KS_NativeKeyLevel(0x31, Scancode, 1, false, false, _NHKL_RecordRead.Bind(Reads)))
	}
	AssertEqual(0, Reads.Length, "invalid source or toggle must refuse before observation")
	AssertEqual(0, KS_NativeNumberRowLevels(1, false, "0", (*) => 0x31))
	AssertEqual(0, KS_NativeNumberRowLevels(1, false, _NHKL_RecordRead.Bind(Reads), "0"))
	AssertEqual(0, KS_NativeNumberRowLevels(1, false, _NHKL_RecordRead.Bind(Reads), (*) => 0))
	AssertEqual(0, KS_NativeNumberRowLevels(1, false, _NHKL_ThrowRead, (*) => 0x31))
	AssertEqual(0, KS_NativeNumberRowLevels(1, false, _NHKL_RecordRead.Bind(Reads), _NHKL_ThrowRead))
	for Result in [{Count: "1", Text: "1"}, {Count: 1.0, Text: "1"}, {Count: 1, Text: ""},
		{Count: 0, Text: "private"}, {Count: 17, Text: "1"}, {Count: 2, Text: "1"}, Map(), 0] {
		AssertEqual(0, KS_NativeNumberRowLevels(1, false, _NHKL_ObservedResult.Bind(Result), (*) => 0x31),
			"an incomplete or malformed level cannot publish a partial source observation")
	}
}
Test("native HKL number row: malformed inputs and native port refusals never publish partial observations", _NHKL_ClosedRefusals)

_NHKL_DescriptorStatusAndDetachment() {
	for Result in [{Count: -1, Text: "^"}, {Count: 0, Text: ""}, {Count: 2, Text: "ab"}] {
		ExpectedText := Result.Text
		Observed := KS_NativeKeyLevel(0x31, 0x02, 1, false, false, _NHKL_ObservedResult.Bind(Result))
		AssertTrue(Observed is Map)
		AssertEqual(Result.Count, Observed["Count"])
		AssertEqual(Result.Count < 0 ? "dead" : (Result.Count > 0 ? "text" : "none"), Observed["Kind"])
		Result.Text := "private later mutation"
		AssertEqual(ExpectedText, Observed["Text"], "only detached native scalars leave the observation")
	}
}
Test("native HKL number row: negative, unmapped and multi-unit results stay typed and detached", _NHKL_DescriptorStatusAndDetachment)


_NHKL_ChangingCount(Seen, *) {
	Seen.Count += 1
	return Seen.Count <= 7 ? 1 : 999
}
_NHKL_ChangingText(Seen, *) {
	Seen.Text += 1
	return Seen.Text <= 2 ? "1" : "private unchecked descriptor text"
}
_NHKL_ExternalGetterSnapshot() {
	Seen := {Count: 0, Text: 0}
	Source := {}
	Source.DefineProp("Count", {Get: _NHKL_ChangingCount.Bind(Seen)})
	Source.DefineProp("Text", {Get: _NHKL_ChangingText.Bind(Seen)})
	Observed := KS_NativeKeyLevel(0x31, 0x02, 1, false, false, (*) => Source)
	AssertTrue(Observed is Map)
	AssertEqual(1, Observed["Count"], "the validated count must be the exact published scalar")
	AssertEqual("1", Observed["Text"], "a later getter result must never replace the validated text")
	AssertEqual("text", Observed["Kind"])
	AssertEqual(1, Seen.Count, "capture the external count getter exactly once")
	AssertEqual(1, Seen.Text, "capture the external text getter exactly once")
	for Name in ["Count", "Text"] {
		Refused := {Count: 1, Text: "1"}
		Refused.DefineProp(Name, {Get: _NHKL_ThrowRead})
		AssertEqual(0, KS_NativeKeyLevel(0x31, 0x02, 1, false, false, (*) => Refused),
			"a throwing getter must remain a closed observation refusal")
	}
	for Value in ["private non-Error descriptor refusal", 71] {
		Throwing := _NHKL_ThrowValue.Bind(Value)
		AssertEqual(0, _NHKL_NoEscapingValue(() => KS_NativeKeyLevel(0x31, 0x02, 1, false, false, Throwing)),
			"a non-Error read-port throw must not escape the native preview")
		AssertEqual(0, _NHKL_NoEscapingValue(() => KS_NativeNumberRowLevels(1, false, Throwing, (*) => 0x31)),
			"a non-Error level throw must not publish a partial native row")
		AssertEqual(0, _NHKL_NoEscapingValue(() => KS_NativeNumberRowLevels(1, false, (*) => {Count: 1, Text: "1"}, Throwing)),
			"a non-Error mapping throw must remain a closed row refusal")
		for Name in ["Count", "Text"] {
			Refused := {Count: 1, Text: "1"}
			Refused.DefineProp(Name, {Get: Throwing})
			AssertEqual(0, _NHKL_NoEscapingValue(() => KS_NativeKeyLevel(0x31, 0x02, 1, false, false, (*) => Refused)),
				"a non-Error own-getter throw must remain a closed scalar refusal")
			AssertEqual(0, _NHKL_NoEscapingValue(() => KS_NativeNumberRowLevels(1, false, (*) => Refused, (*) => 0x31)),
				"a non-Error own-getter throw must not escape the whole row boundary")
		}
	}
}
Test("native HKL number row: external descriptor getters are captured once before validation", _NHKL_ExternalGetterSnapshot)

_NHKL_ThrowValue(Value, *) {
	throw Value
}
_NHKL_NoEscapingValue(Callback) {
	try return Callback.Call()
	catch Any {
		; A fixed nonzero sentinel makes an escaped throw fail the assertion,
		; without copying its private value into the native test framework.
		return "escaped native observation boundary"
	}
}

_NHKL_ObservedResult(Result, *) {
	return Result
}

; Closed-source cases only. Genuine twenty-slot updates, ready factories,
; callback priority and partial native registration require the idle fixture.
_DDB_UnregisteredSource() {
	AssertEqual(0, DigitRow_BindingSource(), "unregistered bindings cannot publish a factory")
}

_DDB_ForbiddenFactory(*) {
	throw Error("A foreign digit source must never be invoked.")
}

_DDB_UnregisteredForeignFactories() {
	for Source in [0, Map("complete", true, "bindings", 20), {}, _DDB_ForbiddenFactory.Bind()]
		AssertEqual(0, DigitRow_CaptureBinding(Source, 0x02),
			"caller descriptions cannot create a source before native registration")
}

_DDB_UnregisteredScans() {
	Source := _DDB_ForbiddenFactory.Bind()
	for Scan in [-1, 0, 1, 0x0C, 1.5, "SC002", {}, Map()]
		AssertEqual(0, DigitRow_CaptureBinding(Source, Scan),
			"an unissued source cannot resolve any supplied scan")
}

_DDB_NoSuppliedRegistrar() {
	for Authority in [Map("hotkey", _DDB_ForbiddenFactory), _DDB_ForbiddenFactory, {}]
		AssertThrows(_DigitRowBindingOwner.Bind("register", Authority),
			"a supplied registrar or receipt must be rejected before native registration")
	AssertEqual(0, DigitRow_BindingSource())
}

_DDB_NoIssuerOperation() {
	for Request in ["issue", "ready", "reset", "complete", Map("operation", "register")]
		AssertThrows(_DigitRowBindingOwner.Bind(Request),
			"private completion cannot be obtained through a public operation")
	AssertEqual(0, DigitRow_BindingSource())
}

_DDB_WithdrawnPrimitive() {
	Before := A_IsCritical
	HadCall := Object.Prototype.HasOwnProp.Call(Hotkey, "Call")
	if HadCall
		SavedCall := Hotkey.GetOwnPropDesc("Call")
	try {
		Hotkey.DefineProp("Call", {Value: _DDB_ForbiddenFactory})
		AssertThrows(DigitRow_RegisterBindings,
			"withdrawn registration must refuse before selecting HotIf or installing anything")
		AssertEqual(0, DigitRow_BindingSource())
		AssertEqual(Before, A_IsCritical, "preflight refusal must preserve critical state")
	} finally {
		if HadCall
			Hotkey.DefineProp("Call", SavedCall)
		else
			Hotkey.DeleteProp("Call")
	}
	AssertThrows(DigitRow_RegisterBindings, "a failed registration cannot retry into a new issuer")
	AssertEqual(0, DigitRow_BindingSource())
}

Test("direct-digit-source: no factory before genuine registration", _DDB_UnregisteredSource)
Test("direct-digit-source: caller factories stay closed before registration", _DDB_UnregisteredForeignFactories)
Test("direct-digit-source: scans cannot manufacture an unissued source", _DDB_UnregisteredScans)
Test("direct-digit-source: registration accepts no supplied authority", _DDB_NoSuppliedRegistrar)
Test("direct-digit-source: no public completion or reset operation", _DDB_NoIssuerOperation)
Test("direct-digit-source: withdrawn primitive refuses and permanently withholds issuance", _DDB_WithdrawnPrimitive)

/** Quotes an absolute owned fixture path for the child AHK source. */
_DDP_Literal(Value) {
	return Chr(34) . StrReplace(StrReplace(Value, Chr(96), Chr(96) . Chr(96)),
		Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

/** Resolves fixture roots before the original owners retain their exact paths. */
_DDP_Path(Value) {
	Length := DllCall("Kernel32\GetFullPathNameW", "Str", Value, "UInt", 0, "Ptr", 0, "Ptr", 0, "UInt")
	if !Length
		throw OSError()
	BufferPath := Buffer(Length * 2, 0)
	Written := DllCall("Kernel32\GetFullPathNameW", "Str", Value, "UInt", Length,
		"Ptr", BufferPath, "Ptr", 0, "UInt")
	if !Written || Written >= Length
		throw Error("The digit producer fixture root cannot be resolved.")
	return StrGet(BufferPath, "UTF-16")
}

/** Reuses the original graph and original static slots without running its tests. */
_DDP_ChildSource(Scenario, ResultsPath) {
	global _DriverDir, _StaticDir, _SharedDir, _ExtensionsDir
	TestsDir := _DDP_Path(_DriverDir . "\tests")
	Source := FileRead(TestsDir . "\run_all.ahk", "UTF-8")
	Lines := []
	for Line in StrSplit(Source, "`n") {
		if InStr(Line, "#Include") == 1 && !RegExMatch(Line, "^#Include ([^\r\n]+)$")
			throw Error("The original digit producer include directive changed.")
		if RegExMatch(Line, "^#Include ([^\r\n]+)$", &Match) {
			if RegExMatch(Match[1], '["%*]')
				throw Error("The original digit producer include syntax changed.")
			Resolved := _DDP_Path(TestsDir . "\" . Match[1])
			if !FileExist(Resolved)
				throw Error("An original digit producer include is missing.")
			Line := "#Include " . Resolved
		}
		Lines.Push(Line)
	}
	Source := ArrayJoin(Lines, "`n")
	Source := StrReplace(Source, "#SingleInstance Force", "#SingleInstance Off`n#NoTrayIcon", , &InstanceCount)
	Source := StrReplace(Source, "SetWorkingDir(A_ScriptDir)",
		"SetWorkingDir(" . _DDP_Literal(TestsDir) . ")`nSuspend(true)", , &WorkingCount)
	Framework := "#Include " . TestsDir . "\test_framework.ahk"
	Source := StrReplace(Source, Framework,
		'EnvSet("ERGOPTI_AHK_RESULTS_FILE", ' . _DDP_Literal(ResultsPath) . ")`n"
		. 'OnExit(_DDP_TraceExit)' . "`n" . Framework, , &ResultsCount)
	Source := StrReplace(Source, "global _VendorDir := A_ScriptDir . " . Chr(34) . "\..\vendor" . Chr(34),
		"global _VendorDir := " . _DDP_Literal(_DDP_Path(_DriverDir . "\vendor")), , &VendorCount)
	Stub := "#Include " . TestsDir . "\test_stubs.ahk"
	Roots := ""
	for Name, Value in Map("_StaticDir", _StaticDir, "_SharedDir", _SharedDir,
		"_DriverDir", _DriverDir, "_ExtensionsDir", _ExtensionsDir)
		Roots .= "`nglobal " . Name . " := " . _DDP_Literal(_DDP_Path(Value))
	Source := StrReplace(Source, Stub, Stub . Roots, , &RootCount)
	if InstanceCount != 1 || WorkingCount != 1 || ResultsCount != 1 || VendorCount != 1 || RootCount != 1
		throw Error("The original digit producer bootstrap boundaries changed.")
	Slots := []
	DriverSource := _DriverSourceConcat()
	if DriverSource == ""
		throw Error("The original digit binding source is unreadable.")
	; Whole-source matching retains the authored slots after their module moves.
	for Line in StrSplit(DriverSource, "`n")
		if RegExMatch(Line, '^SC[0-9A-F]{3}(?: Up)?:: _DigitRow(?:Down|Up)\("[0-9]"\)$')
			Slots.Push(Line)
	if Slots.Length != 20
		throw Error("The original twenty digit binding slots changed.")
	Body := FileRead(TestsDir . "\fixtures\terminal_digit_producer_body.ahk", "UTF-8")
	Body := 'FileAppend("DIGIT_CHILD entry" . Chr(10), "*")' . "`n" . Body
		. "`n_DDP_TraceExit(Reason, Code) {`n"
		. 'FileAppend("DIGIT_CHILD exit=" . Reason . " code=" . Code . Chr(10), "*")' . "`n}`n"
	Body := StrReplace(Body, 'Scenario := EnvGet("ERGOPTI_DIGIT_RECEIVING_SCENARIO")',
		"Scenario := " . _DDP_Literal(Scenario), , &ScenarioCount)
	if ScenarioCount != 1
		throw Error("The closed digit producer scenario boundary changed.")
	Body .= '`n#InputLevel 2`n#HotIf NumberRowEffectiveMode() == "digits" && !TapHoldKanaAltGrHeld()`n'
		. ArrayJoin(Slots, "`n") . "`n#HotIf`n"
	Source := StrReplace(Source, "`nRunTests()", "`n" . Body, , &EntryCount)
	if EntryCount != 1
		throw Error("The original digit producer runner boundary changed.")
	return Source
}

/** Receives one suspended child; its original private loader owns every scope. */
_DDP_Run(Scenario) {
	global _DriverDir
	Root := A_Temp . "\ergopti_digit_producer_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Scenario
	if DirExist(Root)
		throw Error("Preserve an existing digit producer fixture.")
	DirCreate(Root)
	; Some canonical registration modules resolve corpus roots from A_ScriptDir.
	; Keep that original directory; the temporary extension excludes this child
	; from source enumeration. Archive its exact image after actual retirement.
	Child := _DDP_Path(_DriverDir . "\tests") . "\.digit_producer_" . A_ScriptHwnd . "_" . A_TickCount . ".tmp"
	Results := Root . "\run.tap"
	if FileExist(Child)
		throw Error("Preserve an existing digit producer child image.")
	FileAppend(_DDP_ChildSource(Scenario, Results), Child, "UTF-8")
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Child], OnDone)
	AssertTrue(Handle.start(), "the exact suspended digit producer child starts")
	; Keep the canonical watchdog. No outer observation timeout kills this child.
	while !Receipt.Calls {
		_SR_TreePoll()
		Sleep(10)
	}
	FileAppend(Receipt.Output, Root . "\stdout.log", "UTF-8")
	FileAppend(Receipt.Errors, Root . "\stderr.log", "UTF-8")
	AssertEqual(1, Receipt.Calls, "the exact digit producer child completes once")
	AssertTrue(Handle.terminate(), "the completed digit producer tree has no retained process")
	FileAppend(Child, Root . "\source-location.txt", "UTF-8")
	FileMove(Child, Root . "\child.ahk")
	AssertEqual(0, Receipt.Code, "actual digit producer refusal retained in " . Root . ": " . SubStr(Receipt.Errors . Receipt.Output, -8192))
	AssertEqual("", Receipt.Errors, "the actual digit producer has no hidden error")
	AssertContains(Receipt.Output, "PASS scenario=" . Scenario . " source_only=true physical_qualified=false")
	AssertFalse(InStr(Receipt.Output, "[WATCHDOG]"), "watchdog retirement never qualifies a child")
	; Delete only these exact successful fixture files; preserve unexpected entries.
	for Name in ["child.ahk", "run.tap", "stdout.log", "stderr.log", "source-location.txt"]
		FileDelete(Root . "\" . Name)
	DirDelete(Root)
}

for Scenario in ["production-inactive", "production-caps", "production-composition", "production-kle",
	"production-held-withdrawal", "production-capacity", "source-clean", "source-row-replacement",
	"source-mode-case", "source-callback-call", "source-factory-call", "source-policy-observer",
	"candidate-clean", "candidate-route", "candidate-route-clone", "candidate-admission",
	"candidate-binding", "candidate-recipe", "candidate-reason-case", "scope-policy-legacy",
	"scope-pending-binding", "scope-pending-route", "scope-pending-admission", "scope-pending-recipe", "bind-own-call"]
	Test("direct-digit-producer: " . Scenario, _DDP_Run.Bind(Scenario))
