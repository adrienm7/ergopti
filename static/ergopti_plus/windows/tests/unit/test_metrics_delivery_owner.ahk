; tests/unit/test_metrics_delivery_owner.ahk

; ==============================================================================
; MODULE: Metrics Delivery Ownership Tests
; DESCRIPTION:
; A yielding metrics push must not complete or schedule work for a successor
; window. The push seam replaces or removes the owner before reporting success.
; ==============================================================================

#Requires AutoHotkey v2.0

_MDO_ReplaceDuringPush(Remove, Which) {
	if Remove
		KLWV.windows.Delete(Which)
	else
		KLWV.windows[Which] := Map("epoch", 52, "first_paint_done", false,
			"metrics_dir", A_Temp . "\ergopti_delivery_owner_test",
			"full_build_done", false, "pending_full_build_retry", "successor")
	return true
}

_MDO_TerminalRejectsLostOwner(Remove, Mode) {
	OldWindows := KLWV.windows
	OldPush := KLWV.first_paint_push_fn
	OldTimer := KLWV.full_build_timer_fn
	OldDrain := KLWV.ingest_drain_timer_fn
	Timers := []
	try {
		KLWV.windows := Map("typing", Map("epoch", 51, "first_paint_done", false,
			"metrics_dir", A_Temp . "\ergopti_delivery_owner_test"))
		KLWV.first_paint_push_fn := _MDO_ReplaceDuringPush.Bind(Remove)
		KLWV.full_build_timer_fn := (Args*) => Timers.Push(Args)
		KLWV.ingest_drain_timer_fn := (Args*) => Timers.Push(Args)
		switch Mode {
			case "full": Result := KLWV_OnFullBuildTerminal("typing", 51, 0, "ok")
			case "first": Result := KLWV_OnFirstBuildTerminal("typing", 51, 0, "ok")
			case "live": Result := KLWV_OnBuildTerminal("typing", 51, "ok")
			case "fallback": Result := KLWV_ScheduleFirstPaintRetry("typing", 51,
				KLWV.FIRST_PAINT_MAX_RETRIES, "injected failure")
			default: throw ValueError("Unknown terminal fixture")
		}
		AssertFalse(Result, "a push that lost its window must not acknowledge completion")
		AssertEqual(0, Timers.Length, "stale completion must not arm successor work")
		if !Remove {
			AssertFalse(KLWV.windows["typing"]["first_paint_done"])
			AssertFalse(KLWV.windows["typing"]["full_build_done"])
			AssertEqual("successor", KLWV.windows["typing"]["pending_full_build_retry"])
		}
	} finally {
		KLWV.windows := OldWindows
		KLWV.first_paint_push_fn := OldPush
		KLWV.full_build_timer_fn := OldTimer
		KLWV.ingest_drain_timer_fn := OldDrain
	}
}
Test("metrics delivery: full completion rejects replacement (metrics-delivery-owner-full-replace)",
	_MDO_TerminalRejectsLostOwner.Bind(false, "full"))
Test("metrics delivery: full completion rejects deletion (metrics-delivery-owner-full-delete)",
	_MDO_TerminalRejectsLostOwner.Bind(true, "full"))
Test("metrics delivery: first completion rejects replacement (metrics-delivery-owner-first-replace)",
	_MDO_TerminalRejectsLostOwner.Bind(false, "first"))
Test("metrics delivery: first completion rejects deletion (metrics-delivery-owner-first-delete)",
	_MDO_TerminalRejectsLostOwner.Bind(true, "first"))
Test("metrics delivery: live completion rejects replacement (metrics-delivery-owner-live-replace)",
	_MDO_TerminalRejectsLostOwner.Bind(false, "live"))
Test("metrics delivery: live completion rejects deletion (metrics-delivery-owner-live-delete)",
	_MDO_TerminalRejectsLostOwner.Bind(true, "live"))
Test("metrics delivery: exhausted fallback rejects replacement (metrics-delivery-owner-fallback-replace)",
	_MDO_TerminalRejectsLostOwner.Bind(false, "fallback"))
Test("metrics delivery: exhausted fallback rejects deletion (metrics-delivery-owner-fallback-delete)",
	_MDO_TerminalRejectsLostOwner.Bind(true, "fallback"))

class _MDO_WebView {
	__New(Action) {
		this.action := Action
		this.messages := []
	}
	PostWebMessageAsString(Message) {
		this.messages.Push(Message)
		this.action.Call()
	}
}

_MDO_RealDeliveryRejectsReplacement(DuringDiagnostic) {
	global KLPF_LAST_JSON
	OldWindows := KLWV.windows
	HadJson := IsSet(KLPF_LAST_JSON)
	OldJson := HadJson ? KLPF_LAST_JSON : 0
	SuccessorView := _MDO_WebView(() => 0)
	MetricsDir := A_Temp . "\ergopti_delivery_owner_test"
	Successor := Map("epoch", 52, "webview", SuccessorView, "metrics_dir", MetricsDir)
	Replace := () => (KLWV.windows["typing"] := Successor)
	OriginalView := _MDO_WebView(DuringDiagnostic ? () => 0 : Replace)
	try {
		KLPF_LAST_JSON := Map(KLPF_PrefetchPath("typing", MetricsDir), "{}")
		KLWV.windows := Map("typing", Map("epoch", 51, "webview", OriginalView,
			"metrics_dir", MetricsDir))
		Diagnostic := DuringDiagnostic ? (Args*) => Replace.Call() : (Args*) => 0
		AssertFalse(KLWV_PushPrefetch("typing", Diagnostic, 51),
			"delivery must not report current success after its recipient is replaced")
		AssertEqual(1, OriginalView.messages.Length)
		AssertEqual(0, SuccessorView.messages.Length,
			"a predecessor payload must never be delivered into its successor")
		AssertFalse(KLWV_PushPrefetch("typing", (Args*) => 0, 51),
			"an explicitly stale epoch must refuse before native delivery")
		AssertEqual(0, SuccessorView.messages.Length)
		AssertTrue(KLWV_PushPrefetch("typing", (Args*) => 0, 52),
			"the current owner must still receive its payload")
		AssertEqual(1, SuccessorView.messages.Length)
	} finally {
		KLWV.windows := OldWindows
		KLPF_LAST_JSON := HadJson ? OldJson : unset
	}
}
Test("metrics delivery: native posting retains its exact recipient (metrics-delivery-owner-native)",
	_MDO_RealDeliveryRejectsReplacement.Bind(false))
Test("metrics delivery: diagnostics cannot acknowledge a successor (metrics-delivery-owner-diagnostic)",
	_MDO_RealDeliveryRejectsReplacement.Bind(true))

_MDO_FileReadCannotRetargetDelivery() {
	global KLPF_LAST_JSON
	OldWindows := KLWV.windows
	HadJson := IsSet(KLPF_LAST_JSON)
	OldJson := HadJson ? KLPF_LAST_JSON : 0
	Which := "owner_test_" . A_ScriptHwnd . "_" . A_TickCount
	MetricsDir := A_Temp . "\" . Which
	Path := KLPF_PrefetchPath(Which, MetricsDir)
	OriginalView := _MDO_WebView(() => 0)
	SuccessorView := _MDO_WebView(() => 0)
	Successor := Map("epoch", 52, "webview", SuccessorView, "metrics_dir", MetricsDir)
	Read := (FilePath, Encoding) =>
		(KLWV.windows[Which] := Successor, FileRead(FilePath, Encoding))
	try {
		AssertTrue(FSWrite(Path, "{}"))
		KLPF_LAST_JSON := Map()
		KLWV.windows := Map(Which, Map("epoch", 51, "webview", OriginalView,
			"metrics_dir", MetricsDir))
		AssertFalse(KLWV_PushPrefetch(Which, (Args*) => 0, 51, Read))
		AssertEqual(0, OriginalView.messages.Length)
		AssertEqual(0, SuccessorView.messages.Length,
			"a sidecar read that outlives its owner must not retarget the payload")
	} finally {
		KLWV.windows := OldWindows
		KLPF_LAST_JSON := HadJson ? OldJson : unset
		FSDelete(Path)
	}
}
Test("metrics delivery: sidecar reads cannot retarget stale data (metrics-delivery-owner-file-read)",
	_MDO_FileReadCannotRetargetDelivery)

_MDO_ThrowRead(*) {
	throw Error("injected sidecar read refusal")
}

_MDO_ReadFailureIsContainedAndLogged() {
	global KLPF_LAST_JSON
	OldWindows := KLWV.windows
	HadJson := IsSet(KLPF_LAST_JSON)
	OldJson := HadJson ? KLPF_LAST_JSON : 0
	Which := "read_failure_" . A_ScriptHwnd . "_" . A_TickCount
	MetricsDir := A_Temp . "\" . Which
	Path := KLPF_PrefetchPath(Which, MetricsDir)
	View := _MDO_WebView(() => 0)
	Captured := []
	try {
		LoggerSetTestSink((Line) => Captured.Push(Line))
		AssertTrue(FSWrite(Path, "{}"))
		KLPF_LAST_JSON := Map()
		KLWV.windows := Map(Which, Map("epoch", 51, "webview", View, "metrics_dir", MetricsDir))
		AssertFalse(KLWV_PushPrefetch(Which, (Args*) => 0, 51, _MDO_ThrowRead))
		AssertEqual(0, View.messages.Length)
		Logged := false
		for Line in Captured {
			if InStr(Line, "cannot read") && InStr(Line, "injected sidecar read refusal")
				Logged := true
		}
		AssertTrue(Logged, "read refusal must reach the real central logger")
	} finally {
		LoggerClearTestSink()
		KLWV.windows := OldWindows
		KLPF_LAST_JSON := HadJson ? OldJson : unset
		FSDelete(Path)
	}
}
Test("metrics delivery: sidecar read errors are contained and logged (metrics-delivery-owner-read-error)",
	_MDO_ReadFailureIsContainedAndLogged)

_MDO_CommitIsOwnedAndRestoresCritical() {
	OldWindows := KLWV.windows
	OldCritical := A_IsCritical
	try {
		for Level in [0, 27] {
			Critical(Level)
			Entry := Map("epoch", 51, "first_paint_done", false, "full_build_done", false,
				"metrics_dir", A_Temp . "\ergopti_delivery_owner_test",
				"pending_full_build_retry", "owned", "full_build_retry_exhausted", true)
			KLWV.windows := Map("typing", Entry)
			AssertFalse(KLWV_CommitPaint("typing", 50, true))
			AssertFalse(Entry["first_paint_done"])
			AssertEqual(Level, A_IsCritical)
			AssertTrue(KLWV_CommitPaint("typing", 51, true))
			AssertEqual(Level, A_IsCritical)
			AssertTrue(Entry["first_paint_done"] && Entry["full_build_done"])
			AssertFalse(Entry.Has("pending_full_build_retry"))
			AssertFalse(Entry.Has("full_build_retry_exhausted"))
		}
	} finally {
		Critical(OldCritical)
		KLWV.windows := OldWindows
	}
}
Test("metrics delivery: completion commit preserves ownership and Critical (metrics-delivery-owner-commit)",
	_MDO_CommitIsOwnedAndRestoresCritical)
