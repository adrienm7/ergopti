; tests/unit/test_console_window.ahk

; ==============================================================================
; MODULE: Native Debug Console Placement Tests
; DESCRIPTION:
; Debug actions must place their owned window from the shared geometry instead
; of moving whichever application happens to have foreground focus.
; ==============================================================================

#Requires AutoHotkey v2.0

class _ConsoleTestNative {
	static Calls := []
	static Rect := 0
	static RefuseMove := false
	static RefuseOpen := false
	static RefuseActivate := false
	static ThrowFrame := false
	static Reset() {
		this.Calls := []
		this.Rect := {x: 10, y: 20, w: 300, h: 200}
		this.RefuseMove := false
		this.RefuseOpen := false
		this.RefuseActivate := false
		this.ThrowFrame := false
	}
	static Open(Kind) {
		this.Calls.Push(Kind)
		return !this.RefuseOpen
	}
	static Frame(Hwnd) {
		AssertEqual(A_ScriptHwnd, Hwnd, "placement must target the script window")
		if this.ThrowFrame
			throw Error("Console is no longer available.")
		return this.Rect
	}
	static Screen() {
		return {x: 100, y: 50, w: 1000, h: 800}
	}
	static Move(Hwnd, Rect) {
		AssertEqual(A_ScriptHwnd, Hwnd, "moving another application is forbidden")
		this.Calls.Push("move")
		if this.RefuseMove
			return false
		this.Rect := Rect
		return true
	}
	static Activate(Hwnd) {
		AssertEqual(A_ScriptHwnd, Hwnd, "only the owned debug window may activate")
		this.Calls.Push("activate")
		return !this.RefuseActivate
	}
}

_ConsoleTest_OpensAndPlaces() {
	for Kind in ["list_vars", "key_history"] {
		_ConsoleTestNative.Reset()
		AssertTrue(ConsoleWindow_Open(Kind, _ConsoleTestNative), "accepted placement succeeds")
		AssertEqual(Kind, _ConsoleTestNative.Calls[1], "the requested view opens first")
		AssertEqual(700, _ConsoleTestNative.Rect.w, "width follows shared ratio")
		AssertEqual(600, _ConsoleTestNative.Rect.h, "height follows shared ratio")
		AssertEqual(250, _ConsoleTestNative.Rect.x, "centering includes screen origin")
		AssertEqual(150, _ConsoleTestNative.Rect.y, "centering includes screen origin")
		AssertEqual("activate", _ConsoleTestNative.Calls[3], "the placed view comes forward")
	}
}
Test("Console: both debug views use owned centered geometry (native-console)", _ConsoleTest_OpensAndPlaces)

_ConsoleTest_PreservesLargeWindow() {
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.Rect := {x: 12, y: 34, w: 900, h: 700}
	AssertTrue(ConsoleWindow_Open("list_vars", _ConsoleTestNative), "large console opens")
	AssertEqual(2, _ConsoleTestNative.Calls.Length, "large window is not moved")
	AssertEqual(12, _ConsoleTestNative.Rect.x, "user placement remains intact")
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.Rect.w := 900
	AssertTrue(ConsoleWindow_Open("key_history", _ConsoleTestNative), "short console grows")
	AssertEqual(900, _ConsoleTestNative.Rect.w, "larger dimension must not shrink")
	AssertEqual(600, _ConsoleTestNative.Rect.h, "short dimension reaches minimum")
}
Test("Console: large dimensions and placement survive (native-console)", _ConsoleTest_PreservesLargeWindow)

_ConsoleTest_RefusesFailedPlacement() {
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.RefuseMove := true
	AssertFalse(ConsoleWindow_Open("list_vars", _ConsoleTestNative), "refused move is not success")
	AssertEqual(2, _ConsoleTestNative.Calls.Length, "refused placement does not activate")
}
Test("Console: native refusal stays observable (native-console)", _ConsoleTest_RefusesFailedPlacement)

_ConsoleTest_RejectsIncompleteOpen() {
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.RefuseOpen := true
	AssertFalse(ConsoleWindow_Open("list_vars", _ConsoleTestNative), "opening refusal is not success")
	AssertEqual(1, _ConsoleTestNative.Calls.Length, "refused opening must not move or activate")
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.ThrowFrame := true
	AssertFalse(ConsoleWindow_Open("key_history", _ConsoleTestNative), "a disappeared window is not success")
	AssertEqual(1, _ConsoleTestNative.Calls.Length, "a disappeared window must not move or activate")
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.RefuseActivate := true
	AssertFalse(ConsoleWindow_Open("key_history", _ConsoleTestNative), "activation refusal is not success")
	AssertEqual(3, _ConsoleTestNative.Calls.Length, "activation was actually attempted")
	_ConsoleTestNative.Reset()
	AssertFalse(ConsoleWindow_Open("foreign_window", _ConsoleTestNative), "an unknown view must be refused")
	AssertEqual(0, _ConsoleTestNative.Calls.Length, "an unknown view never reaches the native boundary")
}
Test("Console: native failures and invalid views are refused (native-console)", _ConsoleTest_RejectsIncompleteOpen)

/**
 * Executes the real public console calls in an exactly owned native child.
 * @param {String} Kind - Variables or KeyHistory.
 * @param {String} Operation - Native acquisition or independently stale control.
 * @returns {Array} Fixed facts; no variable dump or key history leaves the child.
 */
_ConsoleCapture_Run(Kind, Operation, ProbePath := "", Ownership := 0) {
	PrivateRoot := ""
	TreeOwnership := IsObject(Ownership) ? Ownership : {CanRetire: true}
	Handle := 0
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	try {
		if ProbePath == "" {
			SourceRoot := A_Temp . "\ergopti_console_capture_" . A_ScriptHwnd . "_" . A_TickCount
			PrivateRoot := _ConsoleCapture_PrivateDirectory(SourceRoot)
			ProbePath := PrivateRoot . "\probe.ahk"
			FileAppend(_ConsoleCapture_Source(), ProbePath, "UTF-8")
		}
		AssertTrue(FileExist(ProbePath), "the native console capture fixture must exist")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", ProbePath, Kind, Operation], OnDone)
		AssertTrue(Handle.start(), "the exact native capture child must start")
		Started := A_TickCount
		while !Receipt.Calls && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipt.Calls, "the native capture child must complete exactly once")
		AssertEqual(0, Receipt.Code, "the actual native capture probe must parse and run: "
			. Receipt.Output . Receipt.Errors)
		AssertEqual("", Receipt.Errors, "the native capture probe must report no hidden errors")
		ShapeDiagnostic := ""
		if !RegExMatch(Receipt.Output, "^[01]\|[01]\|[01]\|\d+\|\d+\|[01]\|[01]\|[01]$")
			ShapeDiagnostic := _ConsoleCapture_ReceiptDiagnostic(Receipt.Output)
		AssertTrue(RegExMatch(Receipt.Output, "^[01]\|[01]\|[01]\|\d+\|\d+\|[01]\|[01]\|[01]$"),
			"the native capture receipt must contain only eight closed facts" . ShapeDiagnostic)
		Facts := StrSplit(Receipt.Output, "|")
		AssertEqual("1", Facts[6], "all capture operations must preserve native HWND, Edit, PID and title")
		AssertEqual("1", Facts[7], "all capture operations must retain the native read-only Edit")
		return Facts
	} finally {
		if IsObject(Handle)
			AssertTrue(_ConsoleCapture_Retire(Handle, TreeOwnership), "the exact native capture process tree must retire")
		if PrivateRoot != "" && TreeOwnership.CanRetire
			DirDelete(PrivateRoot, true)
	}
}

/** Publishes directory custody only after exclusive native creation succeeds. */
_ConsoleCapture_PrivateDirectory(Path) {
	AssertTrue(DllCall("CreateDirectoryW", "Str", Path, "Ptr", 0, "Int"),
		"each actual capture child requires an exclusively created source directory")
	return Path
}

/** Retains source custody before retirement can refuse or throw. */
_ConsoleCapture_Retire(Handle, Ownership) {
	PreviouslyClear := Ownership.CanRetire
	Ownership.CanRetire := false
	Settled := Handle.terminate()
	if Settled is Integer && Settled == true
		Ownership.CanRetire := PreviouslyClear
	return Settled is Integer && Settled == true
}

/** Canonicalizes paths before either source-scope or include-identity checks. */
_ConsoleCapture_Canonical(Path) {
	Storage := Buffer(65536)
	Length := DllCall("GetFullPathNameW", "Str", Path, "UInt", 32768,
		"Ptr", Storage, "Ptr", 0, "UInt")
	if !Length || Length >= 32768
		throw Error("The native console source path must canonicalize completely.")
	return StrGet(Storage, Length, "UTF-16")
}

/** Follows the unique console function owner's actual direct include registration. */
_ConsoleCapture_AdapterPath(Owner := "", ProductionRoot := "") {
	if Owner == ""
		Owner := _DriverProductionFileForSymbol("ConsoleWindow_Open")
	Owner := _ConsoleCapture_Canonical(Owner)
	SplitPath(Owner, , &OwnerDir)
	if ProductionRoot == ""
		SplitPath(A_ScriptDir, , &ProductionRoot)
	ProductionRoot := _ConsoleCapture_Canonical(ProductionRoot) . "\"
	if InStr(Owner, ProductionRoot, false) != 1 || !_DriverIsProductionSource(Owner)
		throw Error("The console function owner must remain inside authored production source.")
	OwnerSource := FileRead(Owner, "UTF-8")
	OwnerCode := _DriverMaskNonCode(&OwnerSource)
	Matches := []
	Position := 1
	while RegExMatch(OwnerCode, "im)^[ \t]*#Include[ \t]+([^\r\n]+)$", &Registration, Position) {
		Position := Registration.Pos + Registration.Len
		Relative := Trim(Registration[1])
		if Relative == "" || RegExMatch(Relative, '[<>"*%:]')
			throw Error("The console owner requires an explicit authored include registration.")
		Path := _ConsoleCapture_Canonical(OwnerDir . "\" . Relative)
		if InStr(Path, ProductionRoot, false) != 1 || !_DriverIsProductionSource(Path)
			throw Error("The console adapter include must remain inside authored production source.")
		if !RegExMatch(Path, "i)\.ahk$") || !FileExist(Path) || InStr(FileExist(Path), "D")
			throw Error("The console adapter include must identify an existing source file.")
		Source := FileRead(Path, "UTF-8")
		Code := _DriverMaskNonCode(&Source)
		Search := 1
		while RegExMatch(Code, "im)^[ \t]*class[ \t]+ConsoleWindowNative\b[^\r\n{]*\{", &Definition, Search) {
			Search := Definition.Pos + Definition.Len
			Prefix := SubStr(Code, 1, Definition.Pos - 1)
			StrReplace(Prefix, "{", , , &Opens)
			StrReplace(Prefix, "}", , , &Closes)
			if Opens == Closes
				Matches.Push(Path)
		}
	}
	AssertEqual(1, Matches.Length, "private controls retain exactly the actual production adapter")
	return Matches[1]
}

/** Generates an actual production include; no adapter location is pinned. */
_ConsoleCapture_Source() {
	Source := FileRead(A_ScriptDir . "\support\console_capture_native.ahk", "UTF-8")
	Source := StrReplace(Source, "; _CNP_PRODUCTION_INCLUDE",
		"#Include " . _ConsoleCapture_AdapterPath(), , &Includes)
	AssertEqual(1, Includes, "the native source template must have exactly one production include slot")
	return Source
}

/** Exercises the real retirement owner with independently refusing ports. */
_ConsoleCapture_RetirementControls() {
	for Mode in ["accepted", "refused", "throws", "malformed", "prior-debt"] {
		Ownership := {CanRetire: Mode != "prior-debt"}
		Handle := {terminate: _ConsoleCapture_TerminationPort.Bind(Mode)}
		Thrown := false, Settled := false
		try Settled := _ConsoleCapture_Retire(Handle, Ownership)
		catch as Failure {
			Thrown := true
			AssertEqual("controlled retirement exception", Failure.Message, "the real retirement exception remains observable")
		}
		AssertEqual(Mode == "throws", Thrown, "only the throwing retirement port throws")
		AssertEqual(Mode == "accepted" || Mode == "prior-debt", Settled, "only a typed actual acknowledgment settles")
		AssertEqual(Mode == "accepted", Ownership.CanRetire, "refusal, throw, malformed acknowledgment and prior debt retain source custody")
	}
}

/** Keeps each test port's selected outcome outside the loop capture scope. */
_ConsoleCapture_TerminationPort(Mode, *) {
	if Mode == "throws"
		throw Error("controlled retirement exception")
	return Mode == "malformed" ? "1" : Mode != "refused"
}

/** Tests authored include admission with real files; these are parser controls. */
_ConsoleCapture_SourceControls(Root) {
	Scope := Root . "\source_graph"
	DirCreate(Scope)
	FileAppend("retained collision sentinel", Scope . "\custody.txt", "UTF-8-RAW")
	PrivateRoot := ""
	Refused := false
	try PrivateRoot := _ConsoleCapture_PrivateDirectory(Scope)
	catch
		Refused := true
	AssertTrue(Refused, "an existing directory cannot acknowledge exclusive source custody")
	AssertEqual("", PrivateRoot, "a refused directory creation publishes no deletable source root")
	AssertEqual("retained collision sentinel", FileRead(Scope . "\custody.txt", "UTF-8-RAW"),
		"directory-collision refusal preserves existing evidence")
	Owner := Scope . "\owner.ahk"
	Native := Scope . "\first.ahk"
	FileAppend('#Include first.ahk`n', Owner, "UTF-8")
	FileAppend('class ConsoleWindowNative {`n}`n', Native, "UTF-8")
	FileAppend('class ConsoleWindowNative {`n}`n', Root . "\foreign.ahk", "UTF-8")
	AssertEqual(_ConsoleCapture_Canonical(Native), _ConsoleCapture_AdapterPath(Owner, Scope),
		"the class admission follows the actual authored include")
	FileMove(Native, Scope . "\relocated.ahk")
	FileDelete(Owner)
	FileAppend('#Include relocated.ahk`n', Owner, "UTF-8")
	AssertEqual(_ConsoleCapture_Canonical(Scope . "\relocated.ahk"), _ConsoleCapture_AdapterPath(Owner, Scope),
		"moving the class and its authored registration keeps the native owner resolvable")
	for Mode in ["data-decoy", "nested-decoy", "duplicate", "outside", "unknown", "missing"] {
		FileDelete(Owner)
		FileDelete(Scope . "\relocated.ahk")
		Registration := Mode == "outside" ? "..\foreign.ahk" : Mode == "unknown" ? "<foreign>" : "relocated.ahk"
		FileAppend('#Include ' . Registration . '`n', Owner, "UTF-8")
		Source := Mode == "data-decoy" ? '/*`nclass ConsoleWindowNative {`n}`n*/`nValue := "class ConsoleWindowNative {"`n'
			: Mode == "nested-decoy" ? 'class Container {`nclass ConsoleWindowNative {`n}`n}`n'
			: Mode == "duplicate" ? 'class ConsoleWindowNative {`n}`nclass ConsoleWindowNative {`n}`n'
			: 'class ConsoleWindowNative {`n}`n'
		if Mode != "missing"
			FileAppend(Source, Scope . "\relocated.ahk", "UTF-8")
		Refused := false
		try _ConsoleCapture_AdapterPath(Owner, Scope)
		catch
			Refused := true
		AssertTrue(Refused, "decoys, duplicates, foreign scope, unknown registration and missing files are refused: " . Mode)
	}
}

/** A real hidden Edit read is available, but it preserves stale native data. */
_ConsoleCapture_CachedCannotProveFreshness() {
	for Kind in ["list_vars", "key_history"] {
		Facts := _ConsoleCapture_Run(Kind, "cached")
		AssertEqual("0", Facts[1], "a cached Edit read must miss the independently changed sentinel")
		AssertEqual("0", Facts[2], "a cached Edit read keeps the source hidden")
		AssertEqual("0", Facts[3], "a cached Edit read does not take foreground")
		AssertEqual("0", Facts[4], "the whole cached read has no source show event")
		AssertEqual("0", Facts[5], "the whole cached read has no source foreground event")
		AssertEqual("1", Facts[8], "a cached Edit read preserves the exact witness child focus")
	}
}
Test("Console capture: real hidden Edit reads remain stale (native-console-capture)",
	_ConsoleCapture_CachedCannotProveFreshness, true)

/** Public calls refresh the sentinel and independently witness their disruption. */
_ConsoleCapture_PublicRefreshShowsRuntime() {
	for Kind in ["list_vars", "key_history"] {
		Facts := _ConsoleCapture_Run(Kind, "public")
		AssertEqual("1", Facts[1], "the real public call must capture the changed sentinel")
		AssertEqual("1", Facts[2], "the real public call shows the previously hidden runtime")
		AssertEqual("1", Facts[3], "the real public call takes foreground from the native witness")
		Assert(Integer(Facts[4]) > 0, "the native event witness must see the real runtime show")
		Assert(Integer(Facts[5]) > 0, "the native event witness must see the real foreground transition")
		AssertEqual("0", Facts[8], "the real public call displaces the exact witness child focus")
	}
}
Test("Console capture: public refresh exposes the real runtime (native-console-capture)",
	_ConsoleCapture_PublicRefreshShowsRuntime, true)

/** Restoring final visibility and focus cannot erase earlier real native events. */
_ConsoleCapture_FinalRestorationCannotProveInvisibility() {
	for Kind in ["list_vars", "key_history"] {
		Facts := _ConsoleCapture_Run(Kind, "restore")
		AssertEqual("1", Facts[1], "restoration retains genuinely fresh native data")
		AssertEqual("0", Facts[2], "the restored final runtime is hidden")
		AssertEqual("0", Facts[3], "the restored final runtime no longer owns foreground")
		Assert(Integer(Facts[4]) > 0, "final restoration cannot erase the native source show event")
		Assert(Integer(Facts[5]) > 0, "final restoration cannot erase the native foreground event")
		AssertEqual("1", Facts[8], "final restoration really restores the exact witness child focus")
	}
}
Test("Console capture: final-state restoration retains native disruption (native-console-capture)",
	_ConsoleCapture_FinalRestorationCannotProveInvisibility, true)

/** KeyHistory's sole optional argument configures capacity instead of capture. */
_ConsoleCapture_CapacityIsNotCapture() {
	Facts := _ConsoleCapture_Run("key_history", "capacity")
	AssertEqual("0", Facts[1], "KeyHistory(integer) must not refresh the changed foreground sentinel")
	AssertEqual("0", Facts[2], "capacity configuration keeps the runtime hidden")
	AssertEqual("0", Facts[3], "capacity configuration keeps the native witness in foreground")
	AssertEqual("0", Facts[4], "capacity configuration has no runtime show event")
	AssertEqual("0", Facts[5], "capacity configuration has no runtime foreground event")
	AssertEqual("1", Facts[8], "capacity configuration preserves the exact witness child focus")
}
Test("Console capture: KeyHistory capacity is not fresh capture (native-console-capture)",
	_ConsoleCapture_CapacityIsNotCapture, true)

/**
 * Changes one real native producer at a time; expected facts remain independent.
 * Removing refresh, suppressing its observation, and projecting cached text must
 * each break the corresponding positive public-acquisition proof above.
 */
_ConsoleCapture_NativeCausalControls() {
	Root := A_Temp . "\ergopti_console_capture_controls_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "causal capture fixtures require a private directory")
	Root := _ConsoleCapture_PrivateDirectory(Root)
	Ownership := {CanRetire: true}
	try {
		_ConsoleCapture_RetirementControls()
		_ConsoleCapture_SourceControls(Root)
		Source := _ConsoleCapture_Source()
		Mutations := [
			{From: '_CNP_Require(ConsoleWindowNative.Open(Kind) == true, "The real public acquisition must acknowledge.")',
				To: '_CNP_Require(true, "The real public acquisition must acknowledge.")', Fact: 1},
			{From: "_CNPShowEvents += 1", To: "_CNPShowEvents += 0", Fact: 4},
			{From: "Fresh := _CNP_HasMarker(ControlGetText(RuntimeEdit), Kind, NewMarker)",
				To: "Fresh := _CNP_HasMarker(Cached, Kind, NewMarker)", Fact: 1}
		]
		for Index, Mutation in Mutations {
			Mutant := StrReplace(Source, Mutation.From, Mutation.To, , &Changes)
			AssertEqual(1, Changes, "each causal control changes one exact native producer")
			ProbePath := Root . "\control_" . Index . ".ahk"
			FileAppend(Mutant, ProbePath, "UTF-8")
			Facts := _ConsoleCapture_Run("list_vars", "public", ProbePath, Ownership)
			AssertEqual("0", Facts[Mutation.Fact], "each native control breaks its independent positive proof")
			if Index == 1 {
				AssertEqual("0", Facts[2], "removing refresh really keeps the source hidden")
				AssertEqual("0", Facts[4], "removing refresh produces no native source show")
			} else {
				AssertEqual("1", Facts[2], "observation mutations do not suppress the actual native show")
				AssertEqual("1", Facts[3], "observation mutations do not suppress actual native foreground")
				Assert(Integer(Facts[5]) > 0, "observation mutations retain the other real native witness")
			}
		}
	} finally {
		if Ownership.CanRetire
			DirDelete(Root, true)
	}
}
Test("Console capture: three native causal controls break independent proofs (native-console-capture)",
	_ConsoleCapture_NativeCausalControls, true)

/** Returns fixed scalar shape facts from a bounded decoded sample, never its text. */
_ConsoleCapture_ReceiptDiagnostic(CnpReceiptText) {
	CnpLength := StrLen(CnpReceiptText)
	CnpSample := SubStr(CnpReceiptText, 1, 4096)
	StrReplace(CnpSample, "|", , , &CnpPipes)
	CnpFactLines := 0
	for CnpLine in StrSplit(CnpSample, "`n") {
		if SubStr(CnpLine, -1) == "`r"
			CnpLine := SubStr(CnpLine, 1, -1)
		if RegExMatch(CnpLine, "^[01]\|[01]\|[01]\|\d+\|\d+\|[01]\|[01]\|[01]$")
			CnpFactLines += 1
	}
	return Format(" [shape length={1}, sampled={2}, pipes={3}, bom={4}, cr={5}, lf={6}, nul={7}, other={8}, warning={9}, fact_lines={10}, truncated={11}]",
		CnpLength, StrLen(CnpSample), CnpPipes, !!InStr(CnpSample, Chr(0xFEFF), true),
		!!InStr(CnpSample, "`r", true), !!InStr(CnpSample, "`n", true),
		!!RegExMatch(CnpSample, "\x00"), !!RegExMatch(CnpSample, "[^0-9|\r\n]"),
		!!InStr(CnpSample, "Warning:", true), CnpFactLines, CnpLength > 4096)
}

/** Independent authored shapes prove diagnosis remains bounded and cannot echo content. */
_ConsoleCapture_ReceiptDiagnosticsStayScalar() {
	CnpVectors := [
		{Text: "0|0|0|0|0|1|1|1", Expected: " [shape length=15, sampled=15, pipes=7, bom=0, cr=0, lf=0, nul=0, other=0, warning=0, fact_lines=1, truncated=0]"},
		{Text: "Warning:`n0|0|0|0|0|1|1|1", Expected: " [shape length=24, sampled=24, pipes=7, bom=0, cr=0, lf=1, nul=0, other=1, warning=1, fact_lines=1, truncated=0]"},
		{Text: Chr(0xFEFF) . "0|0|0|0|0|1|1|1", Expected: " [shape length=16, sampled=16, pipes=7, bom=1, cr=0, lf=0, nul=0, other=1, warning=0, fact_lines=0, truncated=0]"},
		{Text: "0|0|0|0|0|1|1", Expected: " [shape length=13, sampled=13, pipes=6, bom=0, cr=0, lf=0, nul=0, other=0, warning=0, fact_lines=0, truncated=0]"},
		{Text: "PRIVATE_SECRET_8376`r`n", Expected: " [shape length=21, sampled=21, pipes=0, bom=0, cr=1, lf=1, nul=0, other=1, warning=0, fact_lines=0, truncated=0]"}
	]
	for CnpVector in CnpVectors {
		CnpDiagnostic := _ConsoleCapture_ReceiptDiagnostic(CnpVector.Text)
		AssertEqual(CnpVector.Expected, CnpDiagnostic, "authored shape controls retain only independent scalar facts")
		AssertFalse(InStr(CnpDiagnostic, "PRIVATE_SECRET_8376", true), "diagnosis cannot publish its source sample")
		AssertTrue(StrLen(CnpDiagnostic) < 256, "diagnosis has a finite scalar error footprint")
	}
	CnpLongText := ""
	Loop 4097
		CnpLongText .= "9"
	AssertEqual(" [shape length=4097, sampled=4096, pipes=0, bom=0, cr=0, lf=0, nul=0, other=0, warning=0, fact_lines=0, truncated=1]",
		_ConsoleCapture_ReceiptDiagnostic(CnpLongText), "an oversized malformed receipt samples at most 4096 decoded characters")
}
Test("Console receipt: malformed native observations retain only bounded scalar diagnostics (console-receipt-shape)",
	_ConsoleCapture_ReceiptDiagnosticsStayScalar)

/** Runs a real source parse without executing either public debug acquisition. */
_ConsoleCapture_ParseChild(Source, Root, Mode, Ownership) {
	CnpProbePath := Root . "\parse_" . Mode . ".ahk"
	AssertFalse(FileExist(CnpProbePath), "each native parse control requires fresh owned source")
	FileAppend(Source, CnpProbePath, "UTF-8")
	CnpHandle := 0
	CnpReceipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	CnpOnDone(Code, Output, Errors) {
		CnpReceipt.Calls += 1
		CnpReceipt.Code := Code
		CnpReceipt.Output := Output
		CnpReceipt.Errors := Errors
	}
	try {
		CnpHandle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", CnpProbePath, "list_vars", "cached"], CnpOnDone)
		AssertTrue(CnpHandle.start(), "the exactly owned native parse child must start")
		CnpStarted := A_TickCount
		while !CnpReceipt.Calls && TickElapsed(CnpStarted) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, CnpReceipt.Calls, "the native parse child must complete exactly once")
		AssertEqual(0, CnpReceipt.Code, "the actual native source parse must complete successfully")
		AssertTrue(CnpReceipt.Errors == "", "native parse controls must report no hidden errors")
		return CnpReceipt.Output
	} finally {
		if IsObject(CnpHandle)
			AssertTrue(_ConsoleCapture_Retire(CnpHandle, Ownership), "the exact native parse tree must retire")
	}
}

/** Reintroduces independent builtin collisions while retaining every warning. */
_ConsoleCapture_BuiltinWarningsAreCausal() {
	CnpRoot := A_Temp . "\ergopti_console_parse_" . A_ScriptHwnd . "_" . A_TickCount
	CnpRoot := _ConsoleCapture_PrivateDirectory(CnpRoot)
	CnpOwnership := {CanRetire: true}
	CnpAck := "CNP_PARSE_ACK_5719"
	try {
		CnpSource := _ConsoleCapture_Source()
		AssertTrue(InStr(CnpSource, "#Warn All, StdOut", true) > 0,
			"native parse controls retain the complete stdout warning policy")
		CnpSource := StrReplace(CnpSource, "_CNP_Run(A_Args[1], A_Args[2])",
			'FileAppend("CNP_PARSE_ACK_5719", "*", "UTF-8-RAW")', true, &CnpStarts)
		AssertEqual(1, CnpStarts, "only the native child acquisition entry becomes a fixed parse acknowledgment")
		for CnpMode in ["clean", "edit", "thread", "both"] {
			CnpMutant := CnpSource
			if CnpMode == "edit" || CnpMode == "both" {
				CnpMutant := StrReplace(CnpMutant, "RuntimeEdit", "Edit", true, &CnpEdits)
				Assert(CnpEdits >= 2, "the native Edit collision preserves both assignment and references")
			}
			if CnpMode == "thread" || CnpMode == "both" {
				CnpMutant := StrReplace(CnpMutant, "WitnessThread", "Thread", true, &CnpThreads)
				AssertEqual(2, CnpThreads, "the native Thread collision preserves assignment and its real witness criterion")
			}
			CnpOutput := _ConsoleCapture_ParseChild(CnpMutant, CnpRoot, CnpMode, CnpOwnership)
			StrReplace(CnpOutput, "Warning:", , true, &CnpWarnings)
			StrReplace(CnpOutput, CnpAck, , true, &CnpAcks)
			AssertEqual(1, CnpAcks, "every real parse child must issue its sole fixed acknowledgment")
			AssertTrue(SubStr(CnpOutput, -StrLen(CnpAck)) == CnpAck,
				"the acknowledgment follows native parse diagnostics without leaking their body")
			AssertEqual(CnpMode == "both" ? 2 : CnpMode == "clean" ? 0 : 1, CnpWarnings,
				"only the independently restored builtin collisions may warn")
			AssertEqual(CnpMode == "edit" || CnpMode == "both",
				!!InStr(CnpOutput, "Specifically: Edit  (in function _CNP_Run)", true),
				"the actual parser identifies the independently restored Edit local")
			AssertEqual(CnpMode == "thread" || CnpMode == "both",
				!!InStr(CnpOutput, "Specifically: Thread  (in function _CNP_RequireWitness)", true),
				"the actual parser identifies the independently restored Thread local")
			if CnpMode == "clean"
				AssertTrue(CnpOutput == CnpAck,
					"the repaired actual source must keep stdout exactly closed without filtering warnings")
		}
	} finally {
		if CnpOwnership.CanRetire
			DirDelete(CnpRoot, true)
	}
}
Test("Console capture: actual native parse isolates builtin warning collisions (console-native-parse-warning)",
	_ConsoleCapture_BuiltinWarningsAreCausal)
