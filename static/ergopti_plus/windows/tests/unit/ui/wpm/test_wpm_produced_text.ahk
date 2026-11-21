; tests/unit/ui/wpm/test_wpm_produced_text.ahk

; ==============================================================================
; MODULE: Live WPM Counts The Produced Text (AHK)
; DESCRIPTION:
; Replays _shared/tests/corpus/metrics/live_wpm_produced_text_vectors.json:
; after a hotstring or an AI rewrite the live speed counts the text produced,
; the erased characters taken back first (maintainer decision MET-17,
; 21 November 2026, macOS's rule). Before, the ring kept the typed trigger and
; added the whole output, so the readout ran faster than the page. Linux replays
; the same file. The unit suite stubs wpm_display.ahk's pipeline, so the ring is
; driven here through its pure owner, WPMRing_Retract, with the samples
; WPMWidget_Push writes and the window rule WPMWidget_Calc applies.
; ==============================================================================

#Requires AutoHotkey v2.0

/** The readout of a ring at Now, by WPMWidget_Calc's rule over the shared timings. */
_WPMPT_Speed(Ring, Now) {
	WindowMs := TimingsGet("keystats", "wpm_window_ms")
	MinimumMs := TimingsGet("keystats", "wpm_min_duration_ms")
	Count := 0, Earliest := Now
	for Sample in Ring {
		if Sample.Has("retracted") || Sample["t"] > Now || Now - Sample["t"] > WindowMs
			continue
		Count += 1
		Earliest := Min(Earliest, Sample["t"])
	}
	return Count < 2 ? 0 : Round((Count / 5) / (Max(Now - Earliest, MinimumMs) / 60000))
}

_WPMPT_ReplayVectors() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\metrics\live_wpm_produced_text_vectors.json"
	Data := JsonParse(FileRead(Path, "UTF-8"))
	Cap := 64
	Replayed := 0
	for Vector in Data["cases"] {
		Ring := [], Head := 0
		for Step in Vector["steps"] {
			At := Step["at"]
			if !Step.Has("typed")
				WPMRing_Retract(Ring, Head, Cap, Step["deletes"], At)
			loop Step.Has("typed") ? 1 : Step["produced"] {
				Ring.Push(Map("t", At, "hs", !Step.Has("typed"), "ai", false, "ac", false))
				Head := Mod(Head + 1, Cap)
			}
		}
		Alive := 0
		for Sample in Ring
			Alive += Sample.Has("retracted") ? 0 : 1
		AssertEqual(Vector["count"], Alive, Vector["id"] . ": the characters left are the produced text")
		AssertEqual(Vector["wpm"], _WPMPT_Speed(Ring, Vector["read_at"]),
			Vector["id"] . ": the readout counts the produced text")
		Replayed += 1
	}
	AssertTrue(Replayed >= 4, "the shared vectors carry every produced-text case")
}
Test("wpm: the live speed counts the produced text, not the erased trigger (met-17-2026-11-21)",
	_WPMPT_ReplayVectors)

; A full ring wraps: the newest samples sit just before the head.
_WPMPT_RetractWrapsTheRing() {
	Ring := [], Cap := 4
	loop 4
		Ring.Push(Map("t", A_Index * 10))
	Ring[1] := Map("t", 50), Ring[2] := Map("t", 60)
	AssertEqual(2, WPMRing_Retract(Ring, 2, Cap, 2, 60), "the two newest samples are taken back")
	AssertTrue(Ring[1].Has("retracted") && Ring[2].Has("retracted"))
	AssertFalse(Ring[3].Has("retracted") || Ring[4].Has("retracted"), "older samples stay")
	AssertEqual(1, WPMRing_Retract(Ring, 2, Cap, 1, 35), "a sample later than the producer is not taken back")
	AssertTrue(Ring[3].Has("retracted"), "the newest sample at or before the tick goes")
}
Test("wpm: taking back characters walks a full ring from its head (met-17-2026-11-21)",
	_WPMPT_RetractWrapsTheRing)

; The fired-hotstring sink takes back the trigger before it adds the output.
_WPMPT_HotstringSinkRetractsTheTrigger() {
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls, _Stub_WpmPushCalls, _Stub_WpmRetractCalls
	global _Stub_FlushBufferCalls
	Saved := {Rows: _Stub_AppendLogRows, Roi: _Stub_RoiHotstringCalls, Push: _Stub_WpmPushCalls,
		Retract: _Stub_WpmRetractCalls, Flush: _Stub_FlushBufferCalls, Init: Keystats.initialized}
	_Stub_AppendLogRows := [], _Stub_RoiHotstringCalls := [], _Stub_WpmPushCalls := []
	_Stub_WpmRetractCalls := [], _Stub_FlushBufferCalls := 0
	Keystats.initialized := true
	try {
		KL_LogHotstring("btw", "by the way", "endchar", "", "magickey", "")
		AssertEqual(1, _Stub_WpmRetractCalls.Length, "the trigger is taken back once")
		AssertEqual(3, _Stub_WpmRetractCalls[1].count, "all three trigger characters")
		AssertEqual(0, _Stub_WpmRetractCalls[1].pushes_before, "before the replacement is added")
		AssertEqual(StrLen("by the way"), _Stub_WpmPushCalls.Length)
	} finally {
		_Stub_AppendLogRows := Saved.Rows, _Stub_RoiHotstringCalls := Saved.Roi
		_Stub_WpmPushCalls := Saved.Push, _Stub_WpmRetractCalls := Saved.Retract
		_Stub_FlushBufferCalls := Saved.Flush, Keystats.initialized := Saved.Init
	}
}
Test("wpm: a fired hotstring takes back its trigger before its replacement (met-17-2026-11-21)",
	_WPMPT_HotstringSinkRetractsTheTrigger)

; The other two producers, and the reading that skips a taken-back sample.
_WPMPT_ProducersAndReadingHonourTheMark() {
	for Entry in [
		["_HotstringDispatch", "WPMWidget_Retract(StrLen(Trigger))", "WPMWidget_Push("],
		["_LLM_Bridge_CommitInjectedText", "WPMWidget_Retract(StrLen(Transaction.DeletedText))", "WPMWidget_Push("],
		["WPMWidget_Retract", "WPMRing_Retract(", ""],
		["WPMWidget_Calc", 'ev.Has("retracted")', ""]] {
		Body := _DriverFuncBody(Entry[1])
		At := InStr(Body, Entry[2])
		AssertTrue(At > 0, Entry[1] . " must hold " . Entry[2])
		if Entry[3] != ""
			AssertTrue(InStr(Body, Entry[3], , At) > At, Entry[1] . " must take back before it adds")
	}
}
Test("wpm: the dispatch fallback and the AI commit take back what they erased (met-17-2026-11-21)",
	_WPMPT_ProducersAndReadingHonourTheMark)
