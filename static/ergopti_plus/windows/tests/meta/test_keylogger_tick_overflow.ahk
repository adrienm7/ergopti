; tests/meta/test_keylogger_tick_overflow.ahk

; ==============================================================================
; MODULE: Keylogger Clock Domain Meta Tests
; DESCRIPTION:
; The supported AutoHotkey v2 runtime publishes A_TickCount through
; GetTickCount64. Watcher idle/session origins and final observations retain
; that native domain; narrowing their elapsed time to DWORD loses long gaps.
; These source guards complement the actual-owner native64 session tests.
;
; The remaining historical hook/ingest/mouse mask assertions are unchanged.
; They are not evidence that their native producers have a DWORD contract;
; migrating those owners requires separate causal behavioral qualification.
; Genuine DWORD consumers keep the original TickElapsed helper unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ Watcher native clock ownership =======
; =================================================
; =================================================

_KLTO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_KLTO_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_KLTO_UniqueCode(Body, Pattern, Message) {
	Code := _DriverMaskNonCode(&Body)
	Assert(Trim(Code) != "", "the clock owner must be defined")
	Position := RegExMatch(Code, Pattern, &Found)
	Assert(Position > 0, Message)
	AssertEqual(0, RegExMatch(Code, Pattern, , Position + Found.Len),
		"the clock decision must have one executable owner")
	return Found
}

_KLTO_Native64Calls(Body, Expected) {
	Code := _DriverMaskNonCode(&Body)
	Assert(Trim(Code) != "", "the native clock owner must be defined")
	AssertFalse(RegExMatch(Code, "i)\b(?:TickElapsed|TickExpired|TickRemaining)\h*\(|&\h*0xFFFFFFFF\b"),
		"native watcher intervals cannot acquire a DWORD narrowing operation")
	Count := 0
	Position := 1
	while RegExMatch(Code, "i)\bTickElapsed64\h*\(", &Found, Position) {
		Count += 1
		Position := Found.Pos + Found.Len
	}
	AssertEqual(Expected, Count, "every native watcher duration must use the full64 owner")
}

_KLTO_Native64Stored(Body, Pattern, Key) {
	Found := _KLTO_UniqueCode(Body, Pattern, "the frozen duration must retain its corresponding native endpoints")
	Actual := Trim(SubStr(Body, Found.Pos(1), Found.Len(1)))
	AssertTrue(Actual == Chr(34) . Key . Chr(34) || Actual == "'" . Key . "'",
		"the native duration must be stored under its exact event key")
}

_KLTO_WatchersNative64(EndIdle, Close, Key, Periodic) {
	_KLTO_Native64Calls(EndIdle, 1)
	_KLTO_Native64Calls(Close, 2)
	_KLTO_Native64Calls(Key, 1)
	_KLTO_Native64Calls(Periodic, 1)
	_KLTO_Native64Stored(EndIdle, "im)^\h*KLWatch\.idle_close\h*:=\h*Map\h*\(([^,\r\n]+),\h*"
		. "TickElapsed64\h*\(\h*KLWatch\.idle_started_at\h*,\h*EndTick\h*\)\h*\)\h*$",
		"duration")
	for Endpoint in ["IdleEndTick", "SessionEndTick"] {
		Origin := Endpoint = "IdleEndTick" ? "idle_started_at" : "session_started_at"
		_KLTO_Native64Stored(Close, "im)^\h*Owner\h*\[([^\r\n\]]+)\]\h*:=\h*TickElapsed64\h*\(\h*"
			. "KLWatch\." . Origin . "\h*,\h*" . Endpoint . "\h*\)\h*$",
			Endpoint = "IdleEndTick" ? "idle_end" : "session_end")
	}
	_KLTO_UniqueCode(Key, "im)^\h*gap\h*:=\h*TickElapsed64\h*\(\h*last\h*,\h*now\h*\)\h*$",
		"accepted activity must retain its selected native origin")
	_KLTO_UniqueCode(Periodic, "im)^\h*gap\h*:=\h*TickElapsed64\h*\(\h*LastTick\h*,\h*now\h*\)\h*$",
		"periodic activity must retain its captured physical origin")
}

_KLTO_WatchersWrapSafe() {
	_KLTO_WatchersNative64(_DriverFuncBody("_KL_Watchers_EndIdle"),
		_DriverFuncBody("_KL_Watchers_CloseSession"),
		_DriverFuncBody("KL_Watchers_OnKeystroke"), _DriverFuncBody("KL_Watchers_IdleTick"))
}
Test("keylogger: watcher native64 clocks retain all five intervals (keylogger-native-clock-guard)", _KLTO_WatchersWrapSafe)




; ===============================================
; ===============================================
; ======= 2/ keylogger_hook tick overflow ========
; ===============================================
; ===============================================

_KLTO_HookWrapSafe() {
	Raw := _KLTO_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger/keylogger_hook.ahk must be readable")

	Assert(InStr(Src, "& 0xFFFFFFFF") > 0,
		"keylogger_hook.ahk must apply the & 0xFFFFFFFF mask to the A_TickCount inter-keystroke delay (keylogger-tickcount-overflow)")

	Assert(InStr(Src, "last_tick) & 0xFFFFFFFF") > 0,
		"keylogger_hook.ahk must mask the (now - last_tick) delay with & 0xFFFFFFFF")
}
Test("keylogger: keylogger_hook.ahk uses & 0xFFFFFFFF mask on inter-keystroke delay (keylogger-tickcount-overflow)", _KLTO_HookWrapSafe)





; ======================================================
; ======================================================
; ======= 3/ Shutdown retained native boundaries =======
; ======================================================
; ======================================================

_KLTO_WatchersStopNative64(Stop, Close) {
	_KLTO_UniqueCode(Stop, "im)^\h*if\h+!\h*_KL_Watchers_CloseSession\h*\(\h*EndTick\h*,\h*EndTick\h*\)\h*$",
		"shutdown must delegate both selected boundaries to the retained close owner")
	_KLTO_Native64Calls(Close, 2)
	for Endpoint in ["IdleEndTick", "SessionEndTick"] {
		Origin := Endpoint = "IdleEndTick" ? "idle_started_at" : "session_started_at"
		_KLTO_Native64Stored(Close, "im)^\h*Owner\h*\[([^\r\n\]]+)\]\h*:=\h*TickElapsed64\h*\(\h*"
			. "KLWatch\." . Origin . "\h*,\h*" . Endpoint . "\h*\)\h*$",
			Endpoint = "IdleEndTick" ? "idle_end" : "session_end")
	}
}

_KLTO_WatchersStopDrainMasked() {
	_KLTO_WatchersStopNative64(_DriverFuncBody("KL_Watchers_Stop"), _DriverFuncBody("_KL_Watchers_CloseSession"))
}
Test("keylogger: shutdown close owner preserves native64 boundaries (keylogger-native-clock-guard)", _KLTO_WatchersStopDrainMasked)

; Pass materialized source into the guard; only its assertion Error is a refusal.
_KLTO_AssertRefused(Action) {
	Refused := false
	try Action.Call()
	catch as Failure {
		AssertEqual("Error", Type(Failure), "a source refusal must be an actual assertion")
		Refused := true
	}
	AssertTrue(Refused, "changed clock ownership must be refused")
}

_KLTO_Native64Mutations() {
	Inputs := [_DriverFuncBody("_KL_Watchers_EndIdle"), _DriverFuncBody("_KL_Watchers_CloseSession"),
		_DriverFuncBody("KL_Watchers_OnKeystroke"), _DriverFuncBody("KL_Watchers_IdleTick")]
	_KLTO_WatchersNative64(Inputs*)
	for Index, Body in Inputs {
		for Replacement in ["TickElapsed", "TickExpired", "TickRemaining", "NotElapsed64", "'TickElapsed64'"] {
			Changed := Inputs.Clone()
			Changed[Index] := StrReplace(Body, "TickElapsed64", Replacement, false, &Count)
			AssertTrue(Count > 0, "every mutation must change a real helper call")
			_KLTO_AssertRefused(_KLTO_WatchersNative64.Bind(Changed*))
		}
		Changed := Inputs.Clone()
		Changed[Index] := ""
		_KLTO_AssertRefused(_KLTO_WatchersNative64.Bind(Changed*))
		Changed[Index] := "/*" . Chr(10) . Body . Chr(10) . "*/"
		_KLTO_AssertRefused(_KLTO_WatchersNative64.Bind(Changed*))
		Changed[Index] := Body . Chr(10) . "gap := (now - last) & 0xFFFFFFFF"
		_KLTO_AssertRefused(_KLTO_WatchersNative64.Bind(Changed*))
		Changed[Index] := Body . Chr(10) . "GAP := TICKELAPSED64(last, now)"
		_KLTO_AssertRefused(_KLTO_WatchersNative64.Bind(Changed*))
	}
	Changed := Inputs.Clone()
	for Index, Body in Inputs
		Changed[Index] := RegExReplace(Body, "i)\b(?:TickElapsed64|KLWatch|Owner|EndTick|IdleEndTick|SessionEndTick|gap|last|LastTick|now)\b",
			"$U0")
	_KLTO_WatchersNative64(Changed*)
	Changed := Inputs.Clone()
	Changed[2] := StrReplace(Inputs[2], '"idle_end"', '"session_end"', true, &Count)
	AssertTrue(Count > 0)
	_KLTO_AssertRefused(_KLTO_WatchersNative64.Bind(Changed*))
	Changed[2] := StrReplace(Inputs[2], "IdleEndTick)", "SessionEndTick)", false, &Count)
	AssertEqual(1, Count)
	_KLTO_AssertRefused(_KLTO_WatchersNative64.Bind(Changed*))
	Stop := _DriverFuncBody("KL_Watchers_Stop")
	_KLTO_WatchersStopNative64(Stop, Inputs[2])
	for Replacement in ["(EndTick, 0)", "(0, EndTick)", "(EndTick, EndTick + 1)"] {
		ChangedStop := StrReplace(Stop, "(EndTick, EndTick)", Replacement, false, &Count)
		AssertEqual(1, Count, "shutdown has one selected boundary delegation")
		_KLTO_AssertRefused(_KLTO_WatchersStopNative64.Bind(ChangedStop, Inputs[2]))
	}
	ChangedStop := StrReplace(Stop, "_KL_Watchers_CloseSession(EndTick, EndTick)",
		"'_KL_Watchers_CloseSession(EndTick, EndTick)'", false, &Count)
	AssertEqual(1, Count)
	_KLTO_AssertRefused(_KLTO_WatchersStopNative64.Bind(ChangedStop, Inputs[2]))
	_KLTO_WatchersStopNative64(StrUpper(Stop), Inputs[2])
	Legacy := _DriverFuncBody("TickElapsed")
	_KLTO_UniqueCode(Legacy, "im)^\h*return\h+\(NowTick\h*-\h*StartTick\)\h*&\h*0xFFFFFFFF\h*$",
		"the explicit DWORD clock helper must retain its unsigned wrap contract")
}
Test("keylogger: native clock source guards reject narrowed or absent owners (keylogger-native-clock-guard)", _KLTO_Native64Mutations)




; =========================================================================
; =========================================================================
; ======= 4/ keylogger_hook.ahk -- context_at TTL comparison (tickcount-wrap)
; =========================================================================
; =========================================================================

_KLTO_HookContextAtWrapSafe() {
	Raw := _KLTO_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger/keylogger_hook.ahk must be readable")

	; Negative: bare subtraction on context_at must not appear
	Assert(!InStr(Src, "(A_TickCount - KLHook.context_at) < KLHookConst.CONTEXT_TTL_MS"),
		"keylogger_hook.ahk must not use bare (A_TickCount - KLHook.context_at) without & 0xFFFFFFFF mask (tickcount-wrap)")

	; Positive: masked form must be present
	Assert(InStr(Src, "(KLHook.context_at) & 0xFFFFFFFF) < KLHookConst.CONTEXT_TTL_MS") > 0,
		"keylogger_hook.ahk must mask context_at TTL comparison with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("keylogger: keylogger_hook.ahk context_at TTL uses & 0xFFFFFFFF mask (tickcount-wrap)", _KLTO_HookContextAtWrapSafe)




; =========================================================================
; =========================================================================
; ======= 5/ keylogger.ahk -- ingest idle and password-cache guards (tickcount-wrap)
; =========================================================================
; =========================================================================

_KLTO_KeyloggerIngestWrapSafe() {
	; Whole keylogger module dir — the password-cache guard lives in the
	; keylogger_password.ahk sibling after the F1 split, the ingest guards in
	; keylogger.ahk; concatenating the dir keeps every mask assertion move-resilient.
	Raw := _DriverDirConcat("modules/keylogger")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger sources must be readable")

	; Ingest idle guard must be masked
	Assert(!RegExMatch(Src, "A_TickCount - KLHook\.last_tick < KeylogConst\.INGEST_IDLE_MS"),
		"keylogger.ahk must not use bare A_TickCount - KLHook.last_tick < INGEST_IDLE_MS without mask (tickcount-wrap)")
	Assert(InStr(Src, "KLHook.last_tick) & 0xFFFFFFFF < KeylogConst.INGEST_IDLE_MS") > 0,
		"keylogger.ahk must mask ingest idle guard with & 0xFFFFFFFF (tickcount-wrap)")

	; Live-push idle guard must be masked
	Assert(!RegExMatch(Src, "A_TickCount - KLHook\.last_tick >= KeylogConst\.INGEST_LIVE_PUSH_IDLE_MS"),
		"keylogger.ahk must not use bare A_TickCount - KLHook.last_tick >= INGEST_LIVE_PUSH_IDLE_MS without mask (tickcount-wrap)")
	Assert(InStr(Src, "KLHook.last_tick) & 0xFFFFFFFF >= KeylogConst.INGEST_LIVE_PUSH_IDLE_MS") > 0,
		"keylogger.ahk must mask live-push idle guard with & 0xFFFFFFFF (tickcount-wrap)")

	; Password cache TTL must be masked regardless of whether the predicate is
	; expressed as a fresh (< TTL) or expired (>= TTL) comparison.
	Assert(InStr(Src, "(A_TickCount - KLPasswordCache.last_at) & 0xFFFFFFFF") > 0
		and InStr(Src, "KLPW_CACHE_TTL_MS") > 0,
		"keylogger module must mask password cache TTL with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("keylogger: keylogger.ahk ingest and password-cache guards use & 0xFFFFFFFF mask (tickcount-wrap)", _KLTO_KeyloggerIngestWrapSafe)




; =========================================================================
; =========================================================================
; ======= 6/ keylogger_mouse.ahk -- park idle and dedup guards (tickcount-wrap)
; =========================================================================
; =========================================================================

_KLTO_MouseParkWrapSafe() {
	Raw := _KLTO_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger/keylogger_mouse.ahk must be readable")

	; park_still_since must be masked before comparison
	Assert(!InStr(Src, "still_ms := Now - State.park_still_since"),
		"keylogger_mouse.ahk must not assign still_ms from bare A_TickCount - park_still_since (tickcount-wrap)")
	Assert(InStr(Src, "still_ms := (Now - State.park_still_since) & 0xFFFFFFFF") > 0,
		"keylogger_mouse.ahk must mask park_still_since delta with & 0xFFFFFFFF (tickcount-wrap)")

	; park_fired_at dedup guard must be masked
	Assert(!InStr(Src, "(Now - State.park_fired_at) < 30000"),
		"keylogger_mouse.ahk must not use bare (A_TickCount - park_fired_at) without & 0xFFFFFFFF mask (tickcount-wrap)")
	Assert(InStr(Src, "State.park_fired_at) & 0xFFFFFFFF) < 30000") > 0,
		"keylogger_mouse.ahk must mask park_fired_at dedup guard with & 0xFFFFFFFF (tickcount-wrap)")
}
Test("keylogger: keylogger_mouse.ahk park idle and dedup guards use & 0xFFFFFFFF mask (tickcount-wrap)", _KLTO_MouseParkWrapSafe)
