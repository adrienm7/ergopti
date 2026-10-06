; tests/meta/test_kl_refresh_context_blocks_on_keystroke.ahk

; ==============================================================================
; MODULE: Keylogger Canonical Focus Projection Guard
; DESCRIPTION:
; Repairs the false-green test that called a SetTimer context refresh
; "off-thread". Every AHK timer runs on the same cooperative script thread as
; keyboard dispatch. A dedicated timer only becomes safe when its callback is
; memory-only, not merely because the WinGetTitle call moved there.
;
; KL_Hook_RefreshContext now consumes MetricsFocusCache’s canonical bounded
; snapshot. It retains the app/window transition ordering and suspend watermark
; logic, but contains no WinGet, DllCall or second acquisition path. Invalid
; snapshots are refused before any session or transition state mutates.
; FIFO classification starts from a private arrival receipt, logs failures and
; cannot clear them during preparation. The callback and receipt owner graph
; must exclude a second context refresh; classified private content returns
; after physical accounting and before shortcut or token publication.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Keystrokes avoid context refresh =======
; ===================================================
; ===================================================

_KRCB_KeystrokeCallbacksDoNotRefreshContext() {
	Capture := _DriverFuncBody("_KL_Hook_CaptureInput")
	Prepare := _DriverFuncBody("_KL_Hook_PrepareInput")
	Commit := _DriverFuncBody("_KL_Hook_CommitInput")
	Assert(Capture != "" && Prepare != "" && Commit != "", "actual receipt privacy owners must exist")
	for FunctionName in ["KL_Hook_OnChar", "KL_Hook_OnKeyDown"] {
		Callback := _DriverFuncBody(FunctionName)
		Assert(Callback != "", FunctionName . " must exist")
		_KRCB_ReceiptPrivacyPolicy(Callback, Capture, Prepare, Commit)
	}
}

Test("keylogger focus: keystroke callbacks never refresh context (focus-refresh-bounded-resident)",
	_KRCB_KeystrokeCallbacksDoNotRefreshContext)





; ==========================================================
; ==========================================================
; ======= 2/ Resident projection performs no OS work =======
; ==========================================================
; ==========================================================

_KRCB_ContextProjectionReadsCanonicalMemoryOnly() {
	Body := _StripFullLineComments(_DriverFuncBody("KL_Hook_RefreshContext"))
	Assert(Body != "", "KL_Hook_RefreshContext must exist")
	Assert(InStr(Body, "MF_GetFocusSnapshot()") > 0,
		"KL_Hook_RefreshContext must read the metrics module's canonical focus snapshot")
	for Forbidden in ["WinGetTitle(", "WinGetProcessName(", "WinGetClass(",
		"WinGetID(", "DllCall(", "WICaptureBoundedFocusSnapshot("] {
		Assert(InStr(Body, Forbidden) = 0,
			"the resident keylogger projection must be memory-only; found " . Forbidden)
	}
	ValidPos := InStr(Body, "Snapshot.valid")
	SessionPos := InStr(Body, "Keylogger.session_title := NewTitle")
	Assert(ValidPos > 0 && SessionPos > ValidPos,
		"an invalid canonical snapshot must be rejected before keylogger session context mutates")
}

Test("keylogger focus: resident context timer reads canonical memory only (focus-refresh-bounded-resident)",
	_KRCB_ContextProjectionReadsCanonicalMemoryOnly)





; ===========================================================
; ===========================================================
; ======= 3/ Timer owns projection, never acquisition =======
; ===========================================================
; ===========================================================

_KRCB_ProjectionTimerLifecycleIsPaired() {
	StartBody := _StripFullLineComments(_DriverFuncBody("KL_Hook_Start"))
	StopBody := _StripFullLineComments(_DriverFuncBody("KL_Hook_Stop"))
	Assert(StartBody != "" && StopBody != "",
		"keylogger hook start/stop lifecycle functions must exist")
	Assert(InStr(StartBody, "KL_Hook_RefreshContext.Bind()") > 0
		&& InStr(StartBody, "SetTimer(KLHook.context_timer") > 0,
		"KL_Hook_Start must arm the memory-only context projection timer")
	Assert(InStr(StopBody, "SetTimer(KLHook.context_timer, 0)") > 0,
		"KL_Hook_Stop must cancel the resident projection timer")
	Assert(InStr(StartBody, "WICaptureBoundedFocusSnapshot") = 0,
		"the keylogger lifecycle must not create a second focus acquisition owner")

	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "static CONTEXT_REFRESH_MS :=") > 0,
		"the resident memory-only projection cadence must remain a named constant")
}

Test("keylogger focus: resident projection timer has paired lifecycle (focus-refresh-bounded-resident)",
	_KRCB_ProjectionTimerLifecycleIsPaired)

_KRCB_CodeCount(Code, Pattern) {
	RegExReplace(Code, Pattern, "", &Count)
	return Count
}

_KRCB_ReceiptPrivacyPolicy(Callback, Capture, Prepare, Commit) {
	Assert(Callback != "" && Capture != "" && Prepare != "" && Commit != "",
		"privacy policy requires nonempty actual callback and receipt owners")
	Callback := _DriverMaskNonCode(&Callback)
	Capture := _DriverMaskNonCode(&Capture)
	Prepare := _DriverMaskNonCode(&Prepare)
	Commit := _DriverMaskNonCode(&Commit)
	for Subject in [Callback, Capture, Prepare, Commit]
		Assert(!RegExMatch(Subject, "(?i)\bKL_Hook_RefreshContext\s*\("),
			"the actual callback and receipt owner graph must not start a second context refresh")
	ObjectPattern := "(?im)^\s*(\w+)\s*:=\s*\{"
	AssertEqual(1, _KRCB_CodeCount(Capture, ObjectPattern), "the arrival receipt allocation must be unique")
	RegExMatch(Capture, ObjectPattern, &Allocation)
	Open := Allocation.Pos + InStr(Allocation[0], "{") - 1
	Initial := _DriverExtractDefinedBody(&Capture, {Idx: Allocation.Pos, OpenPos: Open})
	Assert(Initial != "", "the actual receipt initializer must be available")
	AssertEqual(1, _KRCB_CodeCount(Initial, "(?i)\bfiltered\s*:\s*true\b"),
		"privacy defaults to filtered before a throwing classification can leave its assignment unfinished")
	AssertEqual(1, _KRCB_CodeCount(Capture, "(?i)\breturn\s+" . Allocation[1] . "\b"),
		"the callback must receive that initialized receipt")
	CapturePattern := "(?im)^\s*(\w+)\s*:=\s*_KL_Hook_CaptureInput\s*\("
	AssertEqual(1, _KRCB_CodeCount(Callback, CapturePattern), "the callback must acquire one actual receipt")
	RegExMatch(Callback, CapturePattern, &Binding)
	Name := Binding[1]
	Classify := "(?is)\btry\s+" . Name . "\.filtered\s*:=([\s\S]*?)\bcatch\s+as\s+(\w+)"
	Assert(RegExMatch(Callback, Classify, &Failure), "classification assignment must retain its explicit catch")
	Assert(_KRCB_CodeCount(Failure[1], "(?i)\bMF_ShouldFilter\s*\(") = 1,
		"the ordinary call-time classifier must remain connected")
	PreparePos := InStr(Callback, "_KL_Hook_PrepareInput(" . Name . ")")
	Assert(PreparePos > Failure.Pos + Failure.Len,
		"classification failure handling must finish before privacy preparation")
	FailureBody := SubStr(Callback, Failure.Pos + Failure.Len, PreparePos - Failure.Pos - Failure.Len)
	Assert(RegExMatch(FailureBody, "(?is)\btry\s+LoggerWarn\s*\([\s\S]*?\b" . Failure[2] . "\.Message\s*\)"),
		"classification failure must attempt the central diagnostic with its actual error")
	Assert(RegExMatch(Prepare, "(?im)^\s*\w+\s*:=\s*(\w+)\.entry_privacy\b", &PreparedReceipt),
		"privacy preparation must consume the acquired entry identity")
	AssertEqual(1, _KRCB_CodeCount(Prepare, "(?i)\b" . PreparedReceipt[1] . "\.filtered\s*:=\s*true\b"),
		"changed classification identity must force private admission")
	AssertEqual(0, _KRCB_CodeCount(Prepare, "(?i)\b" . PreparedReceipt[1] . "\.filtered\s*:=\s*(?!true\b)\S+"),
		"preparation cannot clear a failed classification")
	Assert(RegExMatch(Commit, "(?im)^\s*if\s+(\w+)\.cancelled\b", &CommittedReceipt),
		"ordered commit must expose its receipt admission")
	Name := CommittedReceipt[1]
	NotePattern := "(?i)\bKL_Hook_NoteActivity\s*\(\s*false\s*,\s*!" . Name . "\.filtered\s*,"
	AssertEqual(1, _KRCB_CodeCount(Commit, NotePattern),
		"physical accounting must receive the captured privacy verdict exactly once")
	RegExMatch(Commit, NotePattern, &Note)
	NotePos := Note.Pos
	PrivatePattern := "(?i)\bif\s+" . Name . "\.filtered\s*\{"
	AssertEqual(1, _KRCB_CodeCount(Commit, PrivatePattern), "the private-content exclusion must be unique")
	RegExMatch(Commit, PrivatePattern, &Private)
	Open := Private.Pos + InStr(Private[0], "{") - 1
	PrivateBody := _DriverExtractDefinedBody(&Commit, {Idx: Private.Pos, OpenPos: Open})
	Assert(Private.Pos > NotePos && RegExMatch(PrivateBody, "(?i)\breturn\s+true\b"),
		"private physical accounting must return before publishing content")
	for Effect in ["KL_LogShortcut(", "KL_Hook_RecordedChar("]
		Assert(InStr(Commit, Effect) > Private.Pos + StrLen(PrivateBody) - 1,
			"private exclusion must precede actual shortcut and token publication")
}

_KRCB_PrivacyNegativeControls(FunctionName) {
	Callback := _DriverFuncBody(FunctionName)
	Capture := _DriverFuncBody("_KL_Hook_CaptureInput")
	Prepare := _DriverFuncBody("_KL_Hook_PrepareInput")
	Commit := _DriverFuncBody("_KL_Hook_CommitInput")
	Assert(Callback != "" && Capture != "" && Prepare != "" && Commit != "",
		"negative controls require actual callback and receipt subjects")
	_KRCB_ReceiptPrivacyPolicy(Callback, Capture, Prepare, Commit)
	Code := _DriverMaskNonCode(&Callback)
	RegExMatch(Code, "(?im)^\s*(\w+)\s*:=\s*_KL_Hook_CaptureInput\s*\(", &Binding)
	RegExMatch(Code, "(?is)\btry\s+" . Binding[1]
		. "\.filtered\s*:=([\s\S]*?)\bcatch\s+as\s+(\w+)", &Failure)
	PrepareCode := _DriverMaskNonCode(&Prepare)
	RegExMatch(PrepareCode, "(?im)^\s*\w+\s*:=\s*(\w+)\.entry_privacy\b", &PreparedReceipt)
	CommitCode := _DriverMaskNonCode(&Commit)
	RegExMatch(CommitCode, "(?im)^\s*if\s+(\w+)\.cancelled\b", &CommittedReceipt)
	Changed := StrReplace(Capture, "filtered: true", "filtered: false", true, &Count)
	AssertEqual(1, Count, "the rejected-default mutation must change exactly the actual initializer")
	_KRCB_PrivacyRejected(Callback, Changed, Prepare, Commit, "privacy defaults to filtered")
	for Token in ["MF_ShouldFilter()", "catch as " . Failure[2], "LoggerWarn("] {
		StrReplace(Callback, Token, "", true, &Count)
		AssertEqual(1, Count, "the mutated executable subject must be unique")
		; Removing the inner catch lets the classifier pattern reach the outer catch,
		; which follows preparation. The existing order guard refuses that substitution.
		Expected := Token = "MF_ShouldFilter()" ? "the ordinary call-time classifier must remain connected"
			: (Token = "LoggerWarn(" ? "classification failure must attempt the central diagnostic"
			: "classification failure handling must finish before privacy preparation")
		for Spoof in ["'" . Token . "'", "; " . Token] {
			Changed := StrReplace(Callback, Token, Spoof, true)
			_KRCB_PrivacyRejected(Changed, Capture, Prepare, Commit, Expected)
		}
	}
	Changed := StrReplace(Prepare, PreparedReceipt[1] . ".filtered := true",
		PreparedReceipt[1] . ".filtered := false", false, &Count)
	AssertEqual(1, Count, "the identity-refusal mutation must change the real preparation write")
	_KRCB_PrivacyRejected(Callback, Capture, Changed, Commit, "changed classification identity must force private admission")
	Changed := StrReplace(Commit, "if " . CommittedReceipt[1] . ".filtered", "if false", false, &Count)
	AssertEqual(1, Count, "the private-return bypass must mutate the real exclusion")
	_KRCB_PrivacyRejected(Callback, Capture, Prepare, Changed, "the private-content exclusion must be unique")
	Changed := StrReplace(Commit, "!" . CommittedReceipt[1] . ".filtered,",
		"true,", false, &Count)
	AssertEqual(1, Count, "the public-accounting bypass must mutate the actual verdict argument")
	_KRCB_PrivacyRejected(Callback, Capture, Prepare, Changed,
		"physical accounting must receive the captured privacy verdict exactly once")
	for Index, Subject in [Callback, Capture, Prepare, Commit] {
		Changed := RegExReplace(Subject, "\}\s*$", "`n`tKL_Hook_RefreshContext()`n}", &Count)
		AssertEqual(1, Count, "the refresh injection must change one actual owner body")
		_KRCB_PrivacyRejected(Index = 1 ? Changed : Callback, Index = 2 ? Changed : Capture,
			Index = 3 ? Changed : Prepare, Index = 4 ? Changed : Commit,
			"the actual callback and receipt owner graph must not start a second context refresh")
	}
	for Unexpected in [UnsetError("unexpected source-policy failure"), Error("wrong assertion provenance")] {
		Propagated := false
		try _KRCB_PrivacyRejected(Callback, Capture, Prepare, Commit, "privacy defaults to filtered",
			_KRCB_ThrowUnexpected.Bind(Unexpected))
		catch as Actual {
			Assert(Actual = Unexpected, "unexpected refusal must preserve its exact error identity")
			Propagated := true
		}
		AssertTrue(Propagated, "wrong type or assertion provenance cannot become a successful policy refusal")
	}
	_KRCB_ReceiptPrivacyPolicy("; filtered := true catch as FilterErr LoggerWarn(`n" . Callback,
		"; filtered: true`n" . Capture, Prepare, Commit)
}

_KRCB_PrivacyRejected(Callback, Capture, Prepare, Commit, ExpectedMessage, PolicyFn := _KRCB_ReceiptPrivacyPolicy) {
	Refused := false
	try PolicyFn.Call(Callback, Capture, Prepare, Commit)
	catch as Err {
		if Type(Err) != "Error" || InStr(Err.Message, ExpectedMessage, true) != 1
			throw Err
		Refused := true
	}
	AssertTrue(Refused, "the actual privacy policy must reject the mutation")
}

for _KRCB_Name in ["KL_Hook_OnChar", "KL_Hook_OnKeyDown"]
	Test("keylogger classification source policy rejects bypasses: " . _KRCB_Name,
		_KRCB_PrivacyNegativeControls.Bind(_KRCB_Name))

_KRCB_ThrowUnexpected(Err, *) {
	throw Err
}
