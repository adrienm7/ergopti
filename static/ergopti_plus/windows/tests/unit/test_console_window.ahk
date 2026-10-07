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

#Include ../support/console_capture_cohort.ahk

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
_ConsoleCapture_ParseChild(Source, Root, Mode, Ownership, RequestedReceipt := "") {
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
		; Only the independently owned sentinel request is inherited by this child.
		; Restore the parent's request immediately after native creation, including refusal.
		CnpPriorRequest := EnvGet("ERGOPTI_AHK_RESULTS_FILE")
		try {
			if RequestedReceipt != ""
				EnvSet("ERGOPTI_AHK_RESULTS_FILE", RequestedReceipt)
			AssertTrue(CnpHandle.start(), "the exactly owned native parse child must start")
		} finally {
			if RequestedReceipt != ""
				EnvSet("ERGOPTI_AHK_RESULTS_FILE", CnpPriorRequest)
		}
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

/** Parses the actual canonical desktop include graph with independently restored builtins. */
_DesktopCapture_ParseSource(DskMode, DskRoot) {
	DskSource := FileRead(A_ScriptDir . "\run_desktop.ahk", "UTF-8")
	DskSource := StrReplace(DskSource, "_DesktopRunnerArguments()`n", "", true, &DskParsers)
	AssertEqual(1, DskParsers, "parse-only controls do not execute runner argument admission")
	DskSource := StrReplace(DskSource, "_TestResultsBeginRun()`n", "", true, &DskInitializers)
	AssertEqual(1, DskInitializers, "parse-only controls remove exactly the standalone receipt initializer")
	DskSource := StrReplace(DskSource, 'RunTests()',
		'FileAppend("DESKTOP_PARSE_ACK_8364", "*", "UTF-8-RAW")`nExitApp(0)', true, &DskEntries)
	AssertEqual(1, DskEntries, "parse-only controls replace exactly the unchanged suite execution entry")
	DskShared := _ConsoleCapture_Canonical(A_ScriptDir . "\..\..\_shared")
	DskSource := StrReplace(DskSource, 'A_ScriptDir . "\..\..\_shared"',
		'"' . DskShared . '"', true, &DskPaths)
	AssertEqual(1, DskPaths, "the private parse child reads the actual unchanged shared defaults")
	DskOwners := Map()
	for DskOwner in [
		{Symbol: "_KeyCombinationRunTap", LocalName: "PairActionFn", Count: 2, Mode: "pair"},
		{Symbol: "_TOML_DocumentToken", LocalName: "QuoteRunLength", Count: 7, Mode: "toml"}
	] {
		DskPath := _ConsoleCapture_Canonical(_DriverProductionFileForSymbol(DskOwner.Symbol))
		DskOwnerSource := FileRead(DskPath, "UTF-8")
		DskRevert := DskMode == DskOwner.Mode || DskMode == "both"
		if DskRevert {
			DskOwnerSource := StrReplace(DskOwnerSource, DskOwner.LocalName, "Run", true, &DskChanges)
			AssertEqual(DskOwner.Count, DskChanges, "each causal control restores only its original local and all its uses")
		}
		DskPrivate := DskRoot . "\owner_" . DskMode . "_" . DskOwner.Mode . ".ahk"
		AssertFalse(FileExist(DskPrivate), "every native parse producer requires fresh owned source")
		FileAppend(DskOwnerSource, DskPrivate, "UTF-8")
		DskOwners[DskPath] := DskPrivate
	}
	; The span owner is an actual nested include of the TOML helper. Preserve that
	; authored owner and its operations, relocating only direct include targets.
	DskHelperPath := _ConsoleCapture_Canonical(_DriverProductionFileForSymbol("ParseTomlFile"))
	SplitPath(DskHelperPath, , &DskHelperDir)
	DskHelper := _DesktopCapture_AbsoluteIncludes(FileRead(DskHelperPath, "UTF-8"), DskHelperDir, DskOwners, 4)
	AssertEqual(1, DskHelper.Replaced, "only the real nested TOML span owner uses its private causal copy")
	DskPrivateHelper := DskRoot . "\helper_" . DskMode . ".ahk"
	AssertFalse(FileExist(DskPrivateHelper), "each actual helper graph requires fresh owned source")
	FileAppend(DskHelper.Source, DskPrivateHelper, "UTF-8")
	DskOwners[DskHelperPath] := DskPrivateHelper
	DskGraph := _DesktopCapture_AbsoluteIncludes(DskSource, A_ScriptDir, DskOwners, 16)
	AssertEqual(2, DskGraph.Replaced, "only the real pair owner and nested helper route use private copies")
	return DskGraph.Source
}


/** Relocates actual authored includes while preserving all non-include source bytes. */
_DesktopCapture_AbsoluteIncludes(DskSource, DskDir, DskOwners, DskExpectedIncludes) {
	DskCode := _DriverMaskNonCode(&DskSource)
	DskAt := 1
	DskIncludes := 0
	DskReplacements := 0
	DskOutput := ""
	while RegExMatch(DskCode, "m)^#Include ([^\r\n]+)$", &DskInclude, DskAt) {
		DskPath := _ConsoleCapture_Canonical(DskDir . "\" . DskInclude[1])
		AssertTrue(FileExist(DskPath) && !InStr(FileExist(DskPath), "D"), "every real canonical include must exist")
		if DskOwners.Has(DskPath) {
			DskPath := DskOwners[DskPath]
			DskReplacements += 1
		}
		DskOutput .= SubStr(DskSource, DskAt, DskInclude.Pos - DskAt) . "#Include " . DskPath
		DskAt := DskInclude.Pos + DskInclude.Len
		DskIncludes += 1
	}
	AssertEqual(DskExpectedIncludes, DskIncludes, "parse controls retain the complete actual include registration")
	return {Source: DskOutput . SubStr(DskSource, DskAt), Replaced: DskReplacements}
}

/** Actual native parser warnings must identify each restored original local precisely. */
_DesktopCapture_OriginalWarningsAreCausal() {
	DskRoot := _ConsoleCapture_PrivateDirectory(A_Temp . "\ergopti_desktop_parse_" . A_ScriptHwnd . "_" . A_TickCount)
	DskOwnership := {CanRetire: true}
	DskAck := "DESKTOP_PARSE_ACK_8364"
	try {
		for DskMode in ["clean", "pair", "toml", "both"] {
			DskSource := _DesktopCapture_ParseSource(DskMode, DskRoot)
			AssertTrue(InStr(DskSource, "#Warn All, StdOut", true) > 0, "actual canonical parse warnings remain enabled")
			DskReceiptPath := DskRoot . "\parent_receipt_" . DskMode . ".tap"
			AssertFalse(FileExist(DskReceiptPath), "each native parse inherits a fresh independently owned receipt")
			FileAppend("1..2`r`nok 1 - independent parent sentinel`r`nok 2 - preserved before child`r`n# parent receipt marker 7319`r`n",
				DskReceiptPath, "UTF-8-RAW")
			DskExpectedHash := "9f76654b66843ad8b1d13b7be80335a04a87e4e4b7d5e18310643368a6b1d186"
			AssertEqual(DskExpectedHash, CryptoSha256Bytes(FileRead(DskReceiptPath, "RAW")),
				"the independent authored sentinel exists before native child admission")
			DskPriorRequest := EnvGet("ERGOPTI_AHK_RESULTS_FILE")
			DskOutput := _ConsoleCapture_ParseChild(DskSource, DskRoot, "desktop_" . DskMode, DskOwnership, DskReceiptPath)
			AssertEqual(DskPriorRequest, EnvGet("ERGOPTI_AHK_RESULTS_FILE"), "the native child cannot replace its parent's request")
			AssertEqual(DskExpectedHash, CryptoSha256Bytes(FileRead(DskReceiptPath, "RAW")),
				"the actual parse-only child cannot reset its inherited parent receipt")
			StrReplace(DskOutput, DskAck, , true, &DskAcks)
			StrReplace(DskOutput, "Warning:", , true, &DskWarnings)
			AssertEqual(1, DskAcks, "each actual native parse must complete with exactly one fixed acknowledgment")
			AssertTrue(SubStr(DskOutput, -StrLen(DskAck)) == DskAck, "native diagnostics precede the sole parse acknowledgment")
			AssertEqual(DskMode == "both" ? 2 : DskMode == "clean" ? 0 : 1, DskWarnings,
				"only independently restored original builtin locals may warn" . _DesktopCapture_WarningFacts(DskOutput))
			AssertEqual(DskMode == "pair" || DskMode == "both",
				!!InStr(DskOutput, "Specifically: Run  (in function _KeyCombinationRunTap)", true),
				"the actual parser identifies the original pair-action local")
			AssertEqual(DskMode == "toml" || DskMode == "both",
				!!InStr(DskOutput, "Specifically: Run  (in function _TOML_DocumentToken)", true),
				"the actual parser identifies the original TOML span local")
			if DskMode == "clean"
				AssertTrue(DskOutput == DskAck, "canonical stdout closes exactly without filtering any warning")
		}
	} finally {
		if DskOwnership.CanRetire
			DirDelete(DskRoot, true)
	}
}
Test("Desktop capture: actual canonical parse isolates original builtin collisions (desktop-native-parse-warning)",
	_DesktopCapture_OriginalWarningsAreCausal)


/** Reports only bounded parser identity metadata; warning payloads remain private. */
_DesktopCapture_WarningFacts(DskOutput) {
	StrReplace(DskOutput, "Warning:", , true, &DskTotal)
	DskSample := SubStr(DskOutput, 1, 4096)
	DskFacts := " [parse warnings=" . DskTotal
	DskKinds := Map("This local variable has the same name as a global variable.", "local-global",
		"This variable appears to never be assigned a value.", "never-assigned", "This line will never execute.", "unreachable")
	DskFiles := Map()
	for DskFile in ["test_framework.ahk", "tick_count.ahk", "wall_clock.ahk", "logger.ahk", "toml_helpers.ahk",
		"number.ahk", "toml_inline_tables.ahk", "toml_document.ahk", "config_snapshot.ahk", "tap_hold_loader.ahk",
		"tap_hold_writer.ahk", "native_number.ahk", "key_state.ahk", "text_sender.ahk", "editor_replace.ahk",
		"shell_runner.ahk", "process_lifecycle.ahk", "constants.ahk", "altgr_criteria.ahk", "key_combinations.ahk",
		"console_capture_cohort.ahk", "altgr_suffix_cohort.ahk"]
		DskFiles[DskFile] := true
	DskPosition := 1
	DskSeen := 0
	while DskSeen < 4 && RegExMatch(DskSample,
		"m)^([^`r`n]+\.ahk) \(([0-9]{1,6})\) : ==> Warning: ([^`r`n]+)(?:`r?`n[ `t]+Specifically: [^`r`n]*?\(in function ([A-Za-z_][A-Za-z_0-9.]{0,95})\))?",
		&DskWarning, DskPosition) {
		DskPosition := DskWarning.Pos + DskWarning.Len
		DskSeen += 1
		SplitPath(DskWarning[1], &DskLeaf)
		DskOwned := DskFiles.Has(DskLeaf) || RegExMatch(DskLeaf,
			"i)^(?:parse_desktop_(?:clean|pair|toml|both)|owner_(?:clean|pair|toml|both)_(?:pair|toml)|helper_(?:clean|pair|toml|both))\.ahk$")
		DskKnown := DskOwned && DskKinds.Has(DskWarning[3])
		DskFunction := DskKnown && DskWarning[4] != "" ? DskWarning[4] : "unknown"
		DskFacts .= "; file=" . (DskKnown ? DskLeaf : "unknown") . ",line=" . (DskKnown ? Integer(DskWarning[2]) : 0)
			. ",kind=" . (DskKnown ? DskKinds[DskWarning[3]] : "unknown") . ",function=" . DskFunction
	}
	return DskFacts . "; identities=" . DskSeen . ",truncated=" . (StrLen(DskOutput) > 4096) . "]"
}

/** Independently authored warning metadata never permits arbitrary stream text. */
_DesktopCapture_WarningFactsAreClosed() {
	DskPublic := "C:\PRIVATE_PATH_9471\shell_runner.ahk (182) : ==> Warning: This local variable has the same name as a global variable.`r`n"
		. "     Specifically: PRIVATE_VARIABLE_9471  (in function _SR_ProgramName)`r`nPRIVATE_STREAM_9471"
	AssertEqual(" [parse warnings=1; file=shell_runner.ahk,line=182,kind=local-global,function=_SR_ProgramName; identities=1,truncated=0]",
		_DesktopCapture_WarningFacts(DskPublic), "only the fixed source filename, function, line and kind leave an actual warning")
	AssertFalse(InStr(_DesktopCapture_WarningFacts(DskPublic), "PRIVATE_"), "paths, variable names and trailing stream text stay private")
	AssertEqual(" [parse warnings=0; identities=0,truncated=0]", _DesktopCapture_WarningFacts("PRIVATE_STREAM_9471"),
		"ordinary stdout cannot become warning identity metadata")
	DskUnknown := StrReplace(DskPublic, "shell_runner.ahk", "PRIVATE_FILE_9471.ahk")
	AssertEqual(" [parse warnings=1; file=unknown,line=0,kind=unknown,function=unknown; identities=1,truncated=0]",
		_DesktopCapture_WarningFacts(DskUnknown), "a foreign source filename cannot authorize arbitrary identity fields")
	DskUnknown := StrReplace(DskPublic, "This local variable has the same name as a global variable.", "PRIVATE_MESSAGE_9471")
	AssertFalse(InStr(_DesktopCapture_WarningFacts(DskUnknown), "PRIVATE_"), "unrecognized warning text cannot become a kind")
	DskMany := ""
	Loop 5
		DskMany .= DskPublic . "`r`n"
	DskFacts := _DesktopCapture_WarningFacts(DskMany)
	AssertContains(DskFacts, "warnings=5")
	AssertContains(DskFacts, "identities=4")
	AssertTrue(StrLen(DskFacts) < 1024, "at most four bounded identities leave the native failure")
	DskLong := ""
	Loop 4097
		DskLong .= "x"
	AssertEqual(" [parse warnings=0; identities=0,truncated=1]", _DesktopCapture_WarningFacts(DskLong),
		"diagnostic identity parsing samples at most 4096 characters")
}
Test("Desktop capture: native warning identity diagnostics remain closed (desktop-parse-warning-facts)",
	_DesktopCapture_WarningFactsAreClosed)
