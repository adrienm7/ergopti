; tests/meta/test_keylogger_tick_overflow.ahk

; ==============================================================================
; MODULE: Keylogger A_TickCount Overflow Guard Meta Test
; DESCRIPTION:
; Static source guard for the "keylogger-tickcount-overflow" audit finding in
; modules/keylogger/keylogger_watchers.ahk and keylogger_hook.ahk.
;
; ROOT CAUSE ENCODED:
; A_TickCount is a 32-bit unsigned counter that wraps from 0xFFFFFFFF back to 0
; approximately every 49.7 days. A naive delta (now - last) is evaluated in
; AHK v2 as a 64-bit signed integer. After the wrap, the result is a large
; negative number, making elapsed-time comparisons always false — idle/session
; timers never fire, and the watcher loses track of keystroke timing permanently
; until the script restarts.
;
; The fix masks every subtraction: (now - last) & 0xFFFFFFFF. This keeps the
; delta in [0, 0xFFFFFFFF] regardless of counter direction and produces the
; correct unsigned elapsed time after a wrap event.
;
; The companion test test_tickcount_wrap_safe.ahk covers the same fix in
; prediction_engine.ahk and llm_bridge.ahk. This test covers the two keylogger
; modules that were not included in that earlier guard.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ keylogger_watchers tick overflow ========
; ===================================================
; ===================================================

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

_KLTO_WatchersWrapSafe() {
	Raw := _KLTO_ReadSource("modules/keylogger/keylogger_watchers.ahk")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger/keylogger_watchers.ahk must be readable")

	Assert(InStr(Src, "& 0xFFFFFFFF") > 0,
		"keylogger_watchers.ahk must apply the & 0xFFFFFFFF mask to every A_TickCount delta (keylogger-tickcount-overflow)")

	; Verify the mask is used on gap computation — both session and idle paths use it
	Assert(InStr(Src, "gap := (now - last) & 0xFFFFFFFF") > 0
		or InStr(Src, "gap := (now - KLHook.last_tick) & 0xFFFFFFFF") > 0,
		"keylogger_watchers.ahk must use (now - last) & 0xFFFFFFFF for gap computation")

	; Verify the mask is also applied to session duration reporting
	Assert(InStr(Src, ") & 0xFFFFFFFF") > 0,
		"keylogger_watchers.ahk must mask session-duration deltas with & 0xFFFFFFFF")
}
Test("keylogger: keylogger_watchers.ahk uses & 0xFFFFFFFF mask on all A_TickCount deltas (keylogger-tickcount-overflow)", _KLTO_WatchersWrapSafe)




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





; ==========================================================================
; ==========================================================================
; ======= 3/ KL_Watchers_Stop drain paths use masked durations (F31) =======
; ==========================================================================
; ==========================================================================

_KLTO_WatchersStopDrainMasked() {
	Raw := _KLTO_ReadSource("modules/keylogger/keylogger_watchers.ahk")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger/keylogger_watchers.ahk must be readable")

	; Negative: bare unmasked idle_end subtraction must NOT appear
	Assert(!InStr(Src, 'KL_LogSession("idle_end", A_TickCount - KLWatch.idle_started_at)'),
		"keylogger_watchers.ahk must NOT use bare unmasked A_TickCount - KLWatch.idle_started_at in drain (F31)")

	; Negative: bare unmasked session_end subtraction must NOT appear
	Assert(!InStr(Src, 'KL_LogSession("session_end", A_TickCount - KLWatch.session_started_at)'),
		"keylogger_watchers.ahk must NOT use bare unmasked A_TickCount - KLWatch.session_started_at in drain (F31)")

	; Positive: masked idle_end form must be present
	Assert(InStr(Src, 'KL_LogSession("idle_end", (A_TickCount - KLWatch.idle_started_at) & 0xFFFFFFFF)') > 0,
		"keylogger_watchers.ahk must use (A_TickCount - KLWatch.idle_started_at) & 0xFFFFFFFF in drain (F31)")

	; Positive: masked session_end form must be present
	Assert(InStr(Src, 'KL_LogSession("session_end", (A_TickCount - KLWatch.session_started_at) & 0xFFFFFFFF)') > 0,
		"keylogger_watchers.ahk must use (A_TickCount - KLWatch.session_started_at) & 0xFFFFFFFF in drain (F31)")
}
Test("keylogger: KL_Watchers_Stop drain paths mask A_TickCount durations with & 0xFFFFFFFF (F31)", _KLTO_WatchersStopDrainMasked)




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

	; Password cache TTL must be masked
	Assert(InStr(Src, "(KLPasswordCache.last_at) & 0xFFFFFFFF) >= KLPW_CACHE_TTL_MS") > 0,
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
