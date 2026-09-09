; static/ergopti_plus/windows/tests/unit/test_metrics_delivery_sequence.ahk

; ==============================================================================
; MODULE: Metrics Delivery Sequence Tests
; DESCRIPTION: Nested delivery cannot pair a newer painted payload with an older seed.
; ==============================================================================

#Requires AutoHotkey v2.0

_MDS_NestedPush(State, Path) {
	State["calls"] += 1
	if State["calls"] = 1
		State["inner_ok"] := KLWV_PushPrefetch("typing", (*) => 0, 81, FileRead, Path)
}

_MDS_NestedRead(State, InnerPath, Path, Encoding) {
	_MDS_NestedPush(State, InnerPath)
	return FileRead(Path, Encoding)
}

_MDS_NestedDay(State, InnerPath, Day, RejectOuter := false) {
	WasFirst := State["calls"] = 0
	_MDS_NestedPush(State, InnerPath)
	return WasFirst && RejectOuter ? KLR_PrevDay(Day) : Day
}

_MDS_NewerDeliveryOwnsSeed(Boundary) {
	SavedWindows := KLWV.windows
	SavedDayFn := KLWV.history_day_fn
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day := FormatTime(A_Now, "yyyy-MM-dd")
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Root := _KLRDC_Root()
		OuterSeed := KLPF_CaptureHistorySeed(Root, Day)
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(2, Day . " 10:00:01.000", Day, "code.exe", ["b"]))
		_KLRDC_BuildAsWorker()
		InnerSeed := KLPF_CaptureHistorySeed(Root, Day)
		Assert(KL_JsonEncode(OuterSeed) != KL_JsonEncode(InnerSeed),
			"positive control: the nested receipt must represent a different consumed offset")
		OuterPath := Root . "outer.json"
		InnerPath := Root . "inner.json"
		AssertTrue(FSWriteDurable(OuterPath,
			'{"_history_seed":' . KL_JsonEncode(OuterSeed) . ",`n" . '"revision":"outer"}'))
		AssertTrue(FSWriteDurable(InnerPath,
			'{"_history_seed":' . KL_JsonEncode(InnerSeed) . ",`n" . '"revision":"inner"}'))
		State := Map("calls", 0, "inner_ok", false)
		View := _MCR_View(Boundary = "post" ? _MDS_NestedPush.Bind(State, InnerPath) : (*) => 0)
		Entry := Map("epoch", 81, "webview", View, "metrics_dir", Root,
			"first_paint_done", true, "full_build_done", true, "history_seed", OuterSeed)
		KLWV.windows := Map("typing", Entry)
		Diagnostic := Boundary = "diagnostic" ? (*) => _MDS_NestedPush(State, InnerPath) : (*) => 0
		Read := Boundary = "read" ? _MDS_NestedRead.Bind(State, InnerPath) : FileRead
		ValidationBoundary := Boundary = "validation" || Boundary = "invalid-validation"
		if ValidationBoundary
			KLWV.history_day_fn := _MDS_NestedDay.Bind(State, InnerPath, Day, Boundary = "invalid-validation")
		OuterOk := KLWV_PushPrefetch("typing", Diagnostic, 81, Read, OuterPath)
		ExpectedPosts := (Boundary = "read" || ValidationBoundary) ? 1 : 2
		AssertEqual(ExpectedPosts, View.Messages.Length, "only still-owned native posts may execute")
		AssertEqual("inner", JsonParse(View.Messages[ExpectedPosts])["blob"]["revision"])
		AssertTrue(State["inner_ok"])
		AssertFalse(OuterOk, "a superseded same-window delivery cannot report ownership success")
		AssertTrue(Entry["full_build_done"], "a stale validation must not invalidate the newer history")
		AssertEqual("", Entry.Get("pending_ingest_mode", ""))
		AssertEqual(KL_JsonEncode(InnerSeed), KL_JsonEncode(Entry["last_delivery_seed"]))
		AssertEqual(KL_JsonEncode(InnerSeed), KL_JsonEncode(Entry["history_seed"]))
	} finally {
		KLWV.history_day_fn := SavedDayFn
		KLWV.windows := SavedWindows
		_KLRDC_Cleanup()
	}
}
for Boundary in ["read", "validation", "invalid-validation", "post", "diagnostic"]
	Test("metrics delivery: nested " . Boundary . " owns its seed (metrics-delivery-sequence)",
		_KLRDC_CheckTeardown.Bind(_MDS_NewerDeliveryOwnsSeed.Bind(Boundary)))
