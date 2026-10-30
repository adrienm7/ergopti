; tests/unit/modules/hotstrings/engine/test_hse_dispatch_behaviour.ahk

; ==============================================================================
; MODULE: Hotstring Dispatch Behaviour
; DESCRIPTION:
; Drives the real dispatcher, matcher, raw callbacks, forced commit and fire-log
; queue where source scans used to read their spelling. Each case asserts what
; reached the sender and the buffers, so a refactor keeping the behaviour stays
; green and a regression fails whichever way it is spelled. Critical sections and
; the direct SendInput path have no such observable and stay in the meta tests.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================
; ==========================================================
; ======= 1/ Consumed delimiters and the output ring =======
; ==========================================================
; ==========================================================

_HDB_ConsumedDelimiterImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_CONSUMED_DELIMITERS, _AHK04_SendCalls
	Saved := HSE_CONSUMED_DELIMITERS
	try {
		for Vector in [
			{ Consumed: ".", Burst: "{BackSpace 3}{Text}Z", Buffer: "xxZ", Ring: "Z" },
			{ Consumed: "", Burst: "{BackSpace 3}{Text}Z.", Buffer: "xxZ.", Ring: "." }
		] {
			HSE_CONSUMED_DELIMITERS := Vector.Consumed
			_LSCResetFrom(["seed"])
			HSE_Buffer := "xxab."
			HSE_StartIsWordBoundary := true
			_AHK04_SetSendVerdict(true)
			AssertEqual(true, HSE_DispatchMatch(_AHK04_NormalSpec(), "."), "the fire must succeed")
			AssertEqual(Vector.Burst, _AHK04_SendCalls[1].Args[1],
				"the burst must emit the delimiter only when it is not consumed")
			AssertEqual(Vector.Buffer, HSE_Buffer, "the engine must mirror exactly what was emitted")
			AssertEqual(Vector.Ring, GetLastSentCharacterAt(-1),
				"the ring must end at the emitted character, not at the raw end character")
		}
	} finally HSE_CONSUMED_DELIMITERS := Saved
}
Test("hotstrings: a consumed delimiter leaves the burst, the engine and the ring (consumed-endchar-ring-desync)",
	(*) => _AHK04_RunIsolated(_HDB_ConsumedDelimiterImpl))





; ===========================================================
; ===========================================================
; ======= 2/ The NBSP flag describes the winning rule =======
; ===========================================================
; ===========================================================

_HDB_NbspFlagImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_TypoNbspStripped, HSE_LastEndChar
	global HSE_WORD_TERMINATORS, _AHK04_SendCalls
	Nbsp := Chr(0xA0)
	SavedTerminators := HSE_WORD_TERMINATORS
	HSE_RegistryClear()
	HSE_HardReset()
	try {
		if !InStr(HSE_WORD_TERMINATORS, ":")
			HSE_WORD_TERMINATORS .= ":"
		Options := Map("Replacement", "R", "Category", "test", "Section", "nbsp")
		HSE_Register("*?", "x" . Nbsp . ":", 0, Options)
		HSE_Register("", "y", 0, Options)

		; The end-char probe strips the NBSP before the star rule is known to win.
		HSE_Buffer := "abx" . Nbsp . ":"
		HSE_StartIsWordBoundary := true
		Winner := HSE_FindMatchAtEnd(":")
		Assert(IsObject(Winner), "the star rule must match its literal NBSP")
		AssertEqual("", HSE_LastEndChar, "the star rule must be the winner")
		AssertEqual(false, HSE_TypoNbspStripped,
			"a star win consumed no NBSP, so the flag must not describe the discarded candidate")
		_AHK04_SetSendVerdict(true)
		AssertEqual(true, HSE_DispatchMatch(Winner, HSE_LastEndChar), "the star rule must fire")
		AssertEqual("{BackSpace 3}{Text}R", _AHK04_SendCalls[1].Args[1],
			"a stale flag would add a BackSpace and erase the character typed before the trigger")

		; The end-char candidate does consume it, so the flag must survive there.
		HSE_Buffer := "y" . Nbsp . ":"
		Winner := HSE_FindMatchAtEnd(":")
		Assert(IsObject(Winner), "the end-char rule must match through the NBSP")
		AssertEqual(":", HSE_LastEndChar, "the end-char rule must be the winner")
		AssertEqual(true, HSE_TypoNbspStripped,
			"clearing the flag unconditionally would leave the NBSP on screen")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
		HSE_WORD_TERMINATORS := SavedTerminators
	}
}
Test("hotstrings: the NBSP-strip flag describes the winning candidate (F-04)",
	(*) => _AHK04_RunIsolated(_HDB_NbspFlagImpl))





; =============================================================
; =============================================================
; ======= 3/ The real raw callbacks own one transaction =======
; =============================================================
; =============================================================

_HDB_AssertPlan(Effect, Ok, Bs, Ins, Message) {
	AssertEqual(Ok, Effect.Ok, Message . ": verdict")
	AssertEqual(Bs, Effect.Bs, Message . ": deletion")
	AssertEqual(Ins, Effect.Ins, Message . ": insertion")
}

_HDB_RawCallbackCase(Name, Seed, Invoke, Bs, Ins, Burst) {
	global _AHK04_SendCalls
	_LSCResetFrom(Seed)
	_AHK04_SetSendVerdict(true)
	Prepared := Invoke(true)
	_HDB_AssertPlan(Prepared, true, Bs, Ins, Name . " preparation")
	AssertEqual(true, Prepared.Prepared, Name . " must mark a prepared plan")
	AssertEqual(0, _AHK04_SendCalls.Length, Name . " preparation must send nothing")

	_AHK04_SetSendVerdict(false)
	_HDB_AssertPlan(Invoke(false), false, 0, "", Name . " after a refused send")
	AssertEqual(1, _AHK04_SendCalls.Length, Name . " must attempt one burst")

	_LSCResetFrom(Seed)
	_AHK04_SetSendVerdict(true)
	_HDB_AssertPlan(Invoke(false), true, Bs, Ins, Name . " after a successful send")
	AssertEqual(1, _AHK04_SendCalls.Length, Name . " must remain one burst")
	AssertEqual(Burst, _AHK04_SendCalls[1].Args[1], Name . " must erase and insert in that burst")
}

_HDB_RawCallbacksImpl() {
	global _AHK04_SendCalls, LastSentCharacterKeyTime
	_HDB_RawCallbackCase("ellipsis", ["a", ".", ".", "."],
		(PrepareOnly) => _EllipsisRawCallback("", PrepareOnly), 3, "…", "{BackSpace 3}…")
	; The deadkey measures its delay from the "ê" just before the mapped key.
	LastSentCharacterKeyTime["ê"] := A_TickCount
	_HDB_RawCallbackCase("deadkey", [" ", "ê", "x"],
		(PrepareOnly) => ShouldActivateDeadkey("êx", "★", 60, PrepareOnly), 2, "★", "{BackSpace 2}{Text}★")

	; The guards refuse in the wrong context without any output.
	_LSCResetFrom(["[", ".", ".", "."])
	_AHK04_SetSendVerdict(true)
	Declined := _EllipsisRawCallback("", false)
	_HDB_AssertPlan(Declined, false, 0, "", "ellipsis after a non-letter")
	AssertEqual(0, _AHK04_SendCalls.Length, "a declined ellipsis must send nothing")
}
Test("hotstrings: the real raw callbacks prepare silently and report their sender (raw-callback-canonical-effect)",
	(*) => _AHK04_RunIsolated(_HDB_RawCallbacksImpl))

_HDB_ReturnPlan(Plan, *) {
	return Plan
}

_HDB_RawDispatchRefusalImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	; Only an Integer true publishes, and a plan with no effect is a decline: the
	; trigger is still on screen, so neither buffer may move.
	for Plan in [
		{ Ok: "1", Bs: 3, Ins: "…" },
		{ Ok: false, Bs: 3, Ins: "…" },
		{ Ok: true, Bs: 0, Ins: "" }
	] {
		HSE_Buffer := "a..."
		HSE_StartIsWordBoundary := true
		_PrefixBuffer := "a..."
		Spec := { RawCallback: true, Callback: _HDB_ReturnPlan.Bind(Plan), IsPrivate: false }
		Effect := -1
		AssertEqual(false, HSE_DispatchMatch(Spec, "", &Effect), "the plan must not count as a fire")
		AssertEqual(0, Effect, "a refused plan must publish no canonical effect")
		AssertEqual("a...", HSE_Buffer, "a refused plan must leave the engine buffer")
		AssertEqual("a...", _PrefixBuffer, "a refused plan must leave the preview buffer")
	}
}
Test("hotstrings: a raw plan publishes only with a Boolean success and a real effect (raw-callback-canonical-effect)",
	(*) => _AHK04_RunIsolated(_HDB_RawDispatchRefusalImpl))





; ====================================================
; ====================================================
; ======= 4/ The forced commit proves its poke =======
; ====================================================
; ====================================================

_HDB_FailedPokeImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer, _AHK04_SendCalls
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration
	SavedLlm := _LLM_Bridge_Buffer
	SavedActive := _LLM_Bridge_Active
	SavedGeneration := _LLM_Bridge_ContentGeneration
	try {
		_LSCResetFrom(["seed"])
		HSE_Buffer := "zzq"
		HSE_StartIsWordBoundary := true
		_PrefixBuffer := "zzq"
		_LLM_Bridge_Active := true
		_LLM_Bridge_Buffer := "ctxzzq"
		_AHK04_SetSendVerdict(false)
		AssertEqual(false, ActivateHotstrings(), "a refused poke must fail the commit")
		AssertEqual(1, _AHK04_SendCalls.Length, "a refused poke leaves nothing to clean up")
		AssertEqual("zzq", HSE_Buffer, "a Space that never reached the screen must not enter the engine")
		AssertEqual("ctxzzq", _LLM_Bridge_Buffer, "nor the LLM context")
		AssertEqual("zzq", _PrefixBuffer, "nor disturb the preview")
		AssertEqual("seed", GetLastSentCharacterAt(-1), "nor the output ring")
	} finally {
		_LLM_Bridge_Buffer := SavedLlm
		_LLM_Bridge_Active := SavedActive
		_LLM_Bridge_ContentGeneration := SavedGeneration
	}
}
Test("hotstrings: a refused forced-commit poke feeds no buffer (AHK-04-send-transaction)",
	(*) => _AHK04_RunIsolated(_HDB_FailedPokeImpl))





; =========================================================
; =========================================================
; ======= 5/ The fire log leaves the keystroke turn =======
; =========================================================
; =========================================================

/** Runs Body with recording sinks and a disarmed queue owned by generation 71. */
_HDB_RunFireLog(Body) {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled, _HSE_FireLogScheduledGeneration
	global _HSE_FireLogTimer, _PrefixDeferredGeneration
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls, _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	Saved := [_HSE_FireLogQueue, _HSE_FireLogScheduled, _HSE_FireLogScheduledGeneration,
		_HSE_FireLogTimer, _PrefixDeferredGeneration, _Stub_AppendLogRows,
		_Stub_RoiHotstringCalls, _Stub_WpmPushCalls, _Stub_FlushBufferCalls, Keystats.initialized]
	PreviousCritical := Critical("Off")
	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := false
	_HSE_FireLogScheduledGeneration := -1
	_HSE_FireLogTimer := 0
	_PrefixDeferredGeneration := 71
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	Keystats.initialized := true
	try Body()
	finally {
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogQueue := Saved[1], _HSE_FireLogScheduled := Saved[2]
		_HSE_FireLogScheduledGeneration := Saved[3], _HSE_FireLogTimer := Saved[4]
		_PrefixDeferredGeneration := Saved[5], _Stub_AppendLogRows := Saved[6]
		_Stub_RoiHotstringCalls := Saved[7], _Stub_WpmPushCalls := Saved[8]
		_Stub_FlushBufferCalls := Saved[9], Keystats.initialized := Saved[10]
		Critical(PreviousCritical)
	}
}

_HDB_FireLogDeferredImpl() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled, _Stub_AppendLogRows, HSE_FIRE_LOG_DEFER_MS
	Assert(_HSE_QueueFireLog("pex", "par exemple", "endchar", "magickey", "abbreviations"),
		"the fire must enter the queue")
	AssertEqual(1, _HSE_FireLogQueue.Length, "the record must wait in the queue")
	AssertEqual(0, _Stub_AppendLogRows.Length, "no sink may run on the keystroke turn")
	AssertTrue(_HSE_FireLogScheduled, "the queue must own a pending drain")
	; A synchronous fake timer would fail above; a timer that never reaches the OS fails here.
	Sleep(HSE_FIRE_LOG_DEFER_MS + 250)
	AssertEqual(0, _HSE_FireLogQueue.Length, "the real one-shot must drain the queue")
	AssertEqual(1, _Stub_AppendLogRows.Length, "the real one-shot must publish the record once")
}
Test("meta fire-log-never-synchronous: the queue stays deferred",
	(*) => _HDB_RunFireLog(_HDB_FireLogDeferredImpl))

_HDB_FireLogFrozenOwnerImpl() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduledGeneration, _PrefixDeferredGeneration
	global _Stub_AppendLogRows, HSE_FIRE_LOG_DEFER_MS
	Assert(_HSE_QueueFireLog("brb", "be right back", "endchar", "magickey", "abbreviations"),
		"the fire must enter the queue")
	; A newer owner took over while the first timer was queued in the OS: that timer
	; must keep answering for its own generation, never read the current owner's.
	_PrefixDeferredGeneration += 1
	_HSE_FireLogScheduledGeneration := _PrefixDeferredGeneration
	Sleep(HSE_FIRE_LOG_DEFER_MS + 250)
	AssertEqual(1, _HSE_FireLogQueue.Length, "the stale timer must leave the record to its new owner")
	AssertEqual(0, _Stub_AppendLogRows.Length, "the stale timer must publish nothing")
}
Test("meta fire-log-never-synchronous: a queued timer keeps its frozen generation",
	(*) => _HDB_RunFireLog(_HDB_FireLogFrozenOwnerImpl))
