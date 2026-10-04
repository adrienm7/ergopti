; tests/meta/test_keylogger_tick_overflow.ahk

; ==============================================================================
; MODULE: Keylogger Clock Domain Meta Tests
; DESCRIPTION:
; The supported AutoHotkey v2 runtime publishes A_TickCount through
; GetTickCount64. Native watcher/hook/mouse/password age guards retain that
; domain; narrowing their elapsed time to DWORD loses long gaps.
; These source guards complement the actual-owner native64 timing tests.
;
; The remaining historical ingest mask assertions are unchanged.
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

_KLTO_ClockWrites(Code, Name) {
	Pattern := "i)(?<![\w.])" . Name . "\h*(?::=|\+=|-=|\*=|/=|//=|\*\*=|<<=|>>=|>>>=|&=|\|=|\^=|\.=|\+\+|--)"
		. "|(?<![\w.])(?:\+\+|--)\h*" . Name . "\b|(?<!&)&\h*" . Name . "\b"
	Count := 0
	Position := InStr(Code, "{") + 1
	while RegExMatch(Code, Pattern, &Found, Position) {
		Count += 1
		Position := Found.Pos + Found.Len
	}
	return Count
}

_KLTO_HookDelayOwner(Body) {
	_KLTO_Native64Calls(Body, 1)
	Origin := _KLTO_UniqueCode(Body, "im)^\h*([A-Za-z_]\w*)\h*:=\h*KLHook\.last_tick\h*$",
		"physical activity must capture its origin once")
	Clock := _KLTO_UniqueCode(Body, "im)^\h*([A-Za-z_]\w*)\h*:=\h*IsSet\(\h*Now\h*\)\h*\?\h*Now\h*:\h*A_TickCount\h*$",
		"the activity owner must select its final native observation once")
	Delay := _KLTO_UniqueCode(Body, "im)^\h*([A-Za-z_]\w*)\h*:=\h*TickElapsed64\h*\(\h*"
		. Origin[1] . "\h*,\h*" . Clock[1] . "\h*\)\h*$", "the delay must retain both captured endpoints")
	Assert(Origin.Pos < Clock.Pos && Clock.Pos < Delay.Pos,
		"physical origin capture must precede the native sample and interval")
	_KLTO_UniqueCode(Body, "im)^\h*if\h+" . Origin[1] . "\h*=\h*0\h*\n\h*" . Delay[1] . "\h*:=\h*0\h*$",
		"absent physical input must retain its zero delay independently of accepted session ownership")
	Code := _DriverMaskNonCode(&Body)
	AssertFalse(StrLower(Origin[1]) = StrLower(Clock[1]) || StrLower(Origin[1]) = StrLower(Delay[1])
		|| StrLower(Clock[1]) = StrLower(Delay[1]), "origin, clock and delay require distinct local identities")
	AssertEqual(1, _KLTO_ClockWrites(Code, Origin[1]), "the captured physical origin cannot be rebound")
	AssertEqual(1, _KLTO_ClockWrites(Code, Clock[1]), "the selected native clock cannot be rebound")
	AssertEqual(2, _KLTO_ClockWrites(Code, Delay[1]), "only the full interval and absent-physical zero own the delay")
	AssertEqual(0, RegExMatch(SubStr(Code, Clock.Pos), "i):=\h*KLHook\.last_tick\b"),
		"the interval cannot reread a newer mutable origin after sampling")
	Publish := _KLTO_UniqueCode(Body, "im)^\h*KLHook\.last_tick\h*:=\h*" . Clock[1] . "\h*$",
		"physical publication must retain the exact selected native sample")
	Assert(Publish.Pos > Delay.Pos, "the physical watermark must follow interval validation")
}

_KLTO_HookWrapSafe() {
	Body := _DriverFuncBody("KL_Hook_NoteActivity")
	_KLTO_HookDelayOwner(Body)
	for Replacement in ["TickElapsed", "'TickElapsed64'"] {
		Changed := StrReplace(Body, "TickElapsed64", Replacement, false, &Count)
		AssertEqual(1, Count)
		_KLTO_AssertRefused(_KLTO_HookDelayOwner.Bind(Changed))
	}
	Changed := RegExReplace(Body, "im)^(\h*LastTick\h*:=\h*KLHook\.last_tick)\h*$", "; $1", &Count)
	AssertEqual(1, Count)
	_KLTO_AssertRefused(_KLTO_HookDelayOwner.Bind(Changed))
	for Rebinding in ["LastTick := 0", "LASTTICK := 0", "now := 0", "NOW := 0", "delay := 1", "DELAY += 1"] {
		Changed := Body . Chr(10) . Rebinding
		_KLTO_AssertRefused(_KLTO_HookDelayOwner.Bind(Changed))
	}
	_KLTO_HookDelayOwner(RegExReplace(Body, "i)\b(?:LastTick|now|delay|TickElapsed64)\b", "$U0"))
}
Test("keylogger: physical activity retains native64 delay ownership (keylogger-hook-native-clock-guard)", _KLTO_HookWrapSafe)





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

	; Preserve the historical ingest guards above, but native password origins
	; need their complete age rather than a modulo32 cache-admission policy.
	Body := _DriverFuncBody("KL_TryGetPwCachedVerdict")
	Assert(_KLTO_PasswordNativeAgePolicy(Body),
		"password cache must snapshot its native origin and enforce strict full64 TTL")
}
Test("keylogger: ingest guards and native64 password cache admission (tickcount-wrap)", _KLTO_KeyloggerIngestWrapSafe)

; This structural guard protects native sampling/snapshot placement, which the
; future-clock behavior cases cannot observe. Strings/comments cannot supply it.
_KLTO_PasswordUniqueMatch(Code, Pattern) {
	if !RegExMatch(Code, Pattern, &Found)
		return false
	if RegExMatch(Code, Pattern, , Found.Pos + Found.Len)
		return false
	return Found
}

_KLTO_PasswordLocalWriteCount(Code, Name) {
	Pattern := "i)(?<![\w.])(?:" . Name
		. "\b\h*(?::=|//=|\*\*=|<<=|>>>=|>>=|[+\-*/|&^.]=|\+\+|--)"
		. "|(?:\+\+|--)\h*" . Name . "\b)"
	Position := 1
	Count := 0
	while RegExMatch(Code, Pattern, &Found, Position) {
		Count += 1
		Position := Found.Pos + Found.Len
	}
	return Count
}

_KLTO_PasswordNativeAgePolicy(Body) {
	if Body == ""
		return false
	Code := _DriverMaskNonCode(&Body)
	; Default-argument bindings belong to the signature, not mutable body writes.
	BodyStart := InStr(Code, "{")
	if !BodyStart
		return false
	Code := SubStr(Code, BodyStart + 1)
	Origin := _KLTO_PasswordUniqueMatch(Code,
		"im)^\h*(\w+)\h*:=\h*KLPasswordCache\.last_at\h*$")
	Clock := _KLTO_PasswordUniqueMatch(Code,
		"im)^\h*(\w+)\h*:=\h*A_TickCount\h*$")
	Predicate := _KLTO_PasswordUniqueMatch(Code,
		"ims)^\h*(\w+)\h*:=\h*\(KLPasswordCache\.last_hwnd[^`n]*`n"
		. ".*?^\h*<\h*KLPW_CACHE_TTL_MS\)\h*$")
	if !IsObject(Origin) || !IsObject(Clock) || !IsObject(Predicate)
		return false
	if Origin.Pos >= Clock.Pos || Clock.Pos >= Predicate.Pos
		return false
	if (_KLTO_PasswordLocalWriteCount(Code, Origin[1]) != 1
		|| _KLTO_PasswordLocalWriteCount(Code, Clock[1]) != 1
		|| _KLTO_PasswordLocalWriteCount(Code, Predicate[1]) != 1)
		return false
	ElapsedPattern := "i)\bTickElapsed64\(\h*" . Origin[1]
		. "\h*,\h*" . Clock[1] . "\h*\)"
	if !IsObject(_KLTO_PasswordUniqueMatch(Predicate[0], ElapsedPattern))
		return false
	if !IsObject(_KLTO_PasswordUniqueMatch(Code, ElapsedPattern))
		return false
	return IsObject(_KLTO_PasswordUniqueMatch(Code,
		"im)^\h*if\h*!" . Predicate[1] . "\h*$"))
}

_KLTO_PasswordNativeSourceControls() {
	Body := _DriverFuncBody("KL_TryGetPwCachedVerdict")
	Assert(_KLTO_PasswordNativeAgePolicy(Body),
		"the real password predicate must snapshot before native sampling and use strict full64 age")
	Renamed := StrReplace(StrReplace(StrReplace(Body, "CacheAt", "CapturedOrigin"),
		"NowTick", "ObservedTime"), "Matches", "Admitted")
	Assert(_KLTO_PasswordNativeAgePolicy(Renamed),
		"coherent local renames must preserve the source policy")
	Prose := Body . "`n; CacheAt := KLPasswordCache.last_at`n"
		. '; NowTick := A_TickCount, TickElapsed(CacheAt, NowTick) <= KLPW_CACHE_TTL_MS'
		. "`n" . 'Ignored := "CacheAt := KLPasswordCache.last_at"' . "`n"
	Assert(_KLTO_PasswordNativeAgePolicy(Prose),
		"prose and quoted data must not alter code-only admission")
}
Test("password-native64-source: canonical and source-only positive controls",
	_KLTO_PasswordNativeSourceControls)

_KLTO_PasswordNativeSourceRefusals() {
	Body := _DriverFuncBody("KL_TryGetPwCachedVerdict")
	Mutants := [
		StrReplace(Body, "TickElapsed64(CacheAt, NowTick)", "TickElapsed(CacheAt, NowTick)"),
		StrReplace(Body, "< KLPW_CACHE_TTL_MS)", "<= KLPW_CACHE_TTL_MS)"),
		StrReplace(Body, "TickElapsed64(CacheAt, NowTick)", "TickElapsed64(KLPasswordCache.last_at, NowTick)"),
		StrReplace(Body, "CacheAt := KLPasswordCache.last_at", "; CacheAt := KLPasswordCache.last_at"),
		StrReplace(Body, "NowTick := A_TickCount", 'Ignored := "NowTick := A_TickCount"'),
		StrReplace(Body, "CacheAt := KLPasswordCache.last_at", "CacheAt := KLPasswordCache.last_at`n`t`t`t`tCACHEAT := 0"),
		StrReplace(Body, "NowTick := A_TickCount", "NowTick := A_TickCount`n`t`t`t`tNOWTICK += 1"),
		StrReplace(Body, "< KLPW_CACHE_TTL_MS)", "< KLPW_CACHE_TTL_MS)`n`t`t`t`tMATCHES := false"),
		StrReplace(Body, "CacheAt := KLPasswordCache.last_at`n", "")
	]
	Moved := StrReplace(Body, "`t`t`t`tCacheAt := KLPasswordCache.last_at`n", "")
	Moved := StrReplace(Moved, "NowTick := A_TickCount",
		"NowTick := A_TickCount`n`t`t`t`tCacheAt := KLPasswordCache.last_at")
	Mutants.Push(Moved)
	for Index, Variant in Mutants {
		Assert(Variant !== Body, "each source refusal control must actually change the owner")
		Assert(!_KLTO_PasswordNativeAgePolicy(Variant),
			"wrong domain/boundary, missing/deferred/reread or case-alias writes must be refused: " . Index)
	}
}
Test("password-native64-source: wrong clocks, boundaries and spoofed snapshots are rejected",
	_KLTO_PasswordNativeSourceRefusals)

_KLTO_PasswordInlineSourceRefusals() {
	Body := _DriverFuncBody("KL_TryGetPwCachedVerdict")
	Code := _DriverMaskNonCode(&Body)
	Origin := _KLTO_PasswordUniqueMatch(Code,
		"im)^\h*(\w+)\h*:=\h*KLPasswordCache\.last_at\h*$")
	Clock := _KLTO_PasswordUniqueMatch(Code,
		"im)^\h*(\w+)\h*:=\h*A_TickCount\h*$")
	Assert(IsObject(Origin) && IsObject(Clock), "real local bindings must exist")
	OriginAlias := StrUpper(Origin[1])
	ClockAlias := StrUpper(Clock[1])
	for Statement in [
		"Ignored := (" . OriginAlias . " := 0)",
		"Ignored := (" . ClockAlias . " += 1)",
		"Ignored := ++" . OriginAlias,
		"Ignored := " . ClockAlias . "--",
		"if true`n`t`t`t`t`t" . OriginAlias . " := 0",
		"Ignored := (" . OriginAlias . " //= 2)"
	] {
		Variant := StrReplace(Body, Clock[0], Clock[0] . "`n`t`t`t`t" . Statement)
		Assert(Variant !== Body, "each valid inline rebind must actually change source")
		Assert(!_KLTO_PasswordNativeAgePolicy(Variant),
			"inline, prefix, postfix and nested case aliases must all revoke the snapshot policy")
	}
	; Comparisons and a different object's property do not rewrite either local.
	Controls := Body . "`nIgnored := (" . Origin[1] . " = " . Clock[1] . ")"
		. "`nOtherObject." . Origin[1] . " := 0`n"
	Assert(_KLTO_PasswordNativeAgePolicy(Controls),
		"read-only comparisons and another object's field cannot inflate local write counts")
}
Test("password-native64-source: every executable local rebind is rejected",
	_KLTO_PasswordInlineSourceRefusals)






; =========================================================================
; =========================================================================
; ======= 6/ keylogger_mouse.ahk -- park idle and dedup guards (tickcount-wrap)
; =========================================================================
; =========================================================================

_KLTO_MouseParkOwner(Body) {
	_KLTO_Native64Calls(Body, 2)
	_KLTO_UniqueCode(Body, "im)^\h*still_ms\h*:=\h*TickElapsed64\h*\(\h*State\.park_still_since\h*,\h*Now\h*\)\h*$",
		"park dwell must consume the actual native stillness origin")
	_KLTO_UniqueCode(Body, "i)TickElapsed64\h*\(\h*State\.park_fired_at\h*,\h*Now\h*\)\h*<\h*30000\b",
		"same-position dedup must consume the actual native last-fire origin")
}

_KLTO_MouseParkWrapSafe() {
	Body := _DriverFuncBody("_KL_Mouse_ProcessParkSample")
	_KLTO_MouseParkOwner(Body)
	for Replacement in ["TickElapsed", "'TickElapsed64'"] {
		Changed := StrReplace(Body, "TickElapsed64", Replacement, false, &Count)
		AssertEqual(2, Count)
		_KLTO_AssertRefused(_KLTO_MouseParkOwner.Bind(Changed))
	}
	Changed := StrReplace(Body, "TickElapsed64(State.park_still_since, Now)",
		"TickElapsed64(State.park_fired_at, Now)", false, &Count)
	AssertEqual(1, Count)
	_KLTO_AssertRefused(_KLTO_MouseParkOwner.Bind(Changed))
	_KLTO_MouseParkOwner(RegExReplace(Body, "i)\b(?:TickElapsed64|State|Now|still_ms)\b", "$U0"))
}
Test("keylogger: mouse park retains native64 dwell and dedup origins (keylogger-mouse-native-clock-guard)", _KLTO_MouseParkWrapSafe)
