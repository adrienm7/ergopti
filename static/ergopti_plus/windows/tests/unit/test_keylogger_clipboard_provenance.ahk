; tests/unit/test_keylogger_clipboard_provenance.ahk

; ==============================================================================
; MODULE: Keylogger Clipboard Provenance Regression Tests
; DESCRIPTION:
; Drives the real clipboard observer state machine against the shared adapter
; ownership registry. The tests never touch the OS clipboard: they reserve the
; same notification records which CB_Write/CB_RestoreAll reserve around a real
; assignment, then deliver the corresponding OnClipboardChange callback.
; ==============================================================================

#Requires AutoHotkey v2.0

_KCP_WithCleanState(Body) {
	global _KL_CLIP_FILTER_PROBE, _Stub_AppendLogRows
	PreviousInit := Keylogger.initialized
	PreviousApp := Keylogger.session_app
	PreviousProbe := _KL_CLIP_FILTER_PROBE
	PreviousRows := _Stub_AppendLogRows
	PreviousTick := KLClip.last_copy_tick
	PreviousLen := KLClip.last_copy_len
	PreviousSourceApp := KLClip.last_copy_app
	PreviousPasteTicks := KLClip.paste_ticks
	CB_DiscardOwnedNotifications()
	Keylogger.initialized := true
	Keylogger.session_app := "public.exe"
	_KL_CLIP_FILTER_PROBE := (*) => false
	_Stub_AppendLogRows := []
	_KL_Clip_InvalidateProvenance()
	KLClip.paste_ticks := []
	try {
		Body()
	} finally {
		CB_DiscardOwnedNotifications()
		Keylogger.initialized := PreviousInit
		Keylogger.session_app := PreviousApp
		_KL_CLIP_FILTER_PROBE := PreviousProbe
		_Stub_AppendLogRows := PreviousRows
		KLClip.last_copy_tick := PreviousTick
		KLClip.last_copy_len := PreviousLen
		KLClip.last_copy_app := PreviousSourceApp
		KLClip.paste_ticks := PreviousPasteTicks
	}
}

_KCP_AssertUnknownPaste(Row, Context) {
	AssertEqual("clipboard_paste", Row["type"], Context . ": a physical paste must still be recorded")
	AssertEqual(0, Row["char_count"], Context . ": stale clipboard length must be retired")
	AssertEqual(-1, Row["copy_lag_ms"], Context . ": stale copy age must be retired")
	AssertEqual("", Row["source_app"], Context . ": stale source application must be retired")
}

_KCP_DriverTransactionIsInvisible() {
	_KCP_WithCleanState(_KCP_DriveOwnedTransaction)
}

_KCP_DriveOwnedTransaction() {
	global _Stub_AppendLogRows
	OwnerToken := CB_BeginOwnedTransaction("regression_test", true)
	try {
		; The adapter reserves this before its temporary write. Synthetic Ctrl+V
		; is delivered while the owner survives the deferred restore window.
		CB_ExpectOwnedChange()
		KL_Clip_OnPaste()
		AssertEqual(0, _Stub_AppendLogRows.Length,
			"driver Ctrl+V must emit no clipboard_paste or paste_burst row")
	} finally {
		CB_EndOwnedTransaction(OwnerToken)
	}

	; Deliver the delayed clipboard notification after the transaction ended.
	; The FIFO mutation generation must still identify it as driver traffic.
	KL_Clip_OnChange(2)
	AssertEqual(0, _Stub_AppendLogRows.Length,
		"a delayed driver write callback must emit no clipboard_copy row")
}
Test("keylogger clipboard: a deferred driver write/paste transaction emits zero events", _KCP_DriverTransactionIsInvisible)

_KCP_UserCopyPastePairIsPreserved() {
	_KCP_WithCleanState(_KCP_DriveUserCopyPaste)
}

_KCP_DriveUserCopyPaste() {
	global _Stub_AppendLogRows
	KL_Clip_OnChange(2)
	KL_Clip_OnPaste()
	AssertEqual(2, _Stub_AppendLogRows.Length,
		"one genuine copy and one genuine paste must reach the sink exactly once each")
	AssertEqual("clipboard_copy", _Stub_AppendLogRows[1]["type"], "the first row must be the user copy")
	AssertEqual("clipboard_paste", _Stub_AppendLogRows[2]["type"], "the second row must be the user paste")
	AssertEqual("public.exe", _Stub_AppendLogRows[2]["source_app"],
		"the paste must retain provenance from the genuine user copy")
	Assert(_Stub_AppendLogRows[2]["copy_lag_ms"] >= 0,
		"the genuine copy/paste pair must carry a non-negative wrap-safe lag")
}
Test("keylogger clipboard: a user copy/paste remains one exact provenance pair", _KCP_UserCopyPastePairIsPreserved)

_KCP_ClearInvalidatesPublicProvenance() {
	_KCP_WithCleanState(_KCP_DriveClearInvalidation)
}

_KCP_DriveClearInvalidation() {
	global _Stub_AppendLogRows
	KL_Clip_OnChange(2)
	; Give the public generation distinctive metadata so a stale attribution
	; cannot accidentally satisfy the unknown defaults.
	KLClip.last_copy_tick := A_TickCount
	KLClip.last_copy_len := 73
	KLClip.last_copy_app := "public-source.exe"
	KL_Clip_OnChange(0)
	KL_Clip_OnPaste()
	AssertEqual(2, _Stub_AppendLogRows.Length,
		"clipboard clear is state-only: it logs neither content nor a fake copy")
	_KCP_AssertUnknownPaste(_Stub_AppendLogRows[2], "public -> clear -> paste")
}
Test("keylogger clipboard: clear atomically invalidates prior public provenance", _KCP_ClearInvalidatesPublicProvenance)

_KCP_PrivateChangeInvalidatesPublicProvenance() {
	_KCP_WithCleanState(_KCP_DrivePrivateInvalidation)
}

_KCP_DrivePrivateInvalidation() {
	global _KL_CLIP_FILTER_PROBE, _Stub_AppendLogRows
	KLClip.last_copy_tick := A_TickCount
	KLClip.last_copy_len := 41
	KLClip.last_copy_app := "public-source.exe"
	_KL_CLIP_FILTER_PROBE := (*) => true
	KL_Clip_OnChange(2)
	_KL_CLIP_FILTER_PROBE := (*) => false
	KL_Clip_OnPaste()
	AssertEqual(1, _Stub_AppendLogRows.Length,
		"a filtered copy logs no row, while the later public physical paste still logs once")
	_KCP_AssertUnknownPaste(_Stub_AppendLogRows[1], "public -> private -> paste")
}
Test("keylogger clipboard: filtered change atomically invalidates prior public provenance", _KCP_PrivateChangeInvalidatesPublicProvenance)

_KCP_PersistentDriverWriteInvalidatesWithoutLogging() {
	_KCP_WithCleanState(_KCP_DrivePersistentDriverWrite)
}

_KCP_DrivePersistentDriverWrite() {
	global _Stub_AppendLogRows
	KLClip.last_copy_tick := A_TickCount
	KLClip.last_copy_len := 29
	KLClip.last_copy_app := "old-user-copy.exe"
	; No surrounding temporary transaction: this is the ownership class used
	; by persistent CB_Write callers such as copy-path and health-report actions.
	CB_ExpectOwnedChange()
	KL_Clip_OnChange(2)
	KL_Clip_OnPaste()
	AssertEqual(1, _Stub_AppendLogRows.Length,
		"persistent driver replacement logs no fake copy and leaves one physical paste")
	_KCP_AssertUnknownPaste(_Stub_AppendLogRows[1], "public -> persistent driver write -> paste")
}
Test("keylogger clipboard: persistent driver replacement is silent and retires provenance", _KCP_PersistentDriverWriteInvalidatesWithoutLogging)

_KCP_AllDriverAssignmentsUseOwnedAdapter() {
	SplitPath(A_ScriptDir, , &WindowsRoot)
	Violations := []
	Loop Files, WindowsRoot . "\*.ahk", "FR" {
		Normalized := StrReplace(A_LoopFileFullPath, "\", "/")
		if InStr(Normalized, "/tests/") || InStr(Normalized, "/vendor/")
				|| InStr(Normalized, "/_generated/") || InStr(Normalized, "/adapters/clipboard.ahk")
			continue
		Source := FileRead(A_LoopFileFullPath)
		; Strip full-line comments so documentation examples do not satisfy or
		; violate the guard. Executable inline lambdas remain visible.
		Executable := RegExReplace(Source, "m)^[ \t]*;[^\r\n]*$", "")
		if RegExMatch(Executable, "A_Clipboard\s*:=")
			Violations.Push(Normalized)
	}
	AssertEqual(0, Violations.Length,
		"every production clipboard assignment outside the adapter must be owned; raw writers: "
		. _DescribeValue(Violations))
}
Test("keylogger clipboard: all production assignments funnel through ownership", _KCP_AllDriverAssignmentsUseOwnedAdapter)

_KCP_EveryDeferredPastePairsOwnership() {
	Pairs := [
		["_TextSenderStartClipboard", "_TextSenderFinishClipboard"],
		["SendInstant", "_SendInstant_RestoreClipboard"],
		["PasteWithoutFormatting", "_PasteWithoutFormattingRestore"],
		["GesturePastePlain", "_GesturePastePlainRestore"],
		["GetSelectionAsync", "_SelectionCaptureFinish"],
		["GestureScreenshotRegion", "GestureRegionCaptureFinish"]
	]
	for _, Pair in Pairs {
		StartBody := _DriverFuncBody(Pair[1])
		FinishBody := _DriverFuncBody(Pair[2])
		Assert(StartBody != "" && FinishBody != "",
			"ownership pair must remain reachable: " . Pair[1] . " -> " . Pair[2])
		Assert(InStr(StartBody, "CB_BeginOwnedTransaction") > 0
			or InStr(StartBody, "CB_TryBeginPasteTransaction") > 0,
			Pair[1] . " must acquire shared clipboard ownership before its asynchronous mutation")
		Assert(InStr(FinishBody, "CB_EndOwnedTransaction") > 0,
			Pair[2] . " must release shared clipboard ownership on the deferred terminal path")
	}
}
Test("keylogger clipboard: every deferred producer pairs shared ownership", _KCP_EveryDeferredPastePairsOwnership)
