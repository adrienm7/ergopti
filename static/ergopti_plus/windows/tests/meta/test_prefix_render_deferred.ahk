; tests/meta/test_prefix_render_deferred.ahk

; ==============================================================================
; MODULE: PrefixWatcher Deferred-Render Guard Test
; DESCRIPTION:
; Regression guard for the per-keystroke typing latency. The hotstring preview
; tooltip is rebuilt from scratch on every render (Gui destroy + recreate +
; layered-window border + DWM); the HotPath profiler measured this at ~60 ms per
; matching keystroke and ~16 ms per no-match hide. Running it synchronously from
; _OnPrefixChar made every keystroke on a trigger prefix block for that long.
;
; THE FIX: _OnPrefixChar updates the buffer synchronously (cheap) then defers the
; render through _PrefixScheduleRender, a re-armable one-shot timer that coalesces
; a burst of keystrokes into ONE trailing render once typing pauses. The render
; itself (_LookupAndRender) must therefore never be called directly from the hot
; OnChar path — only from the debounce flush (_PrefixRenderFlush).
;
; This source-level assertion mirrors the sibling meta/test_llm_ensure_model_ready_guard.ahk:
; scope to the _OnPrefixChar body and assert it schedules rather than renders.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckPrefixRenderDeferred() {
	; Move-resilient: scan the hotstrings lib dir and the _OnPrefixChar body via
	; the framework helpers instead of a pinned hotstring_prefix_watcher.ahk path.
	; The _Prefix* render tokens are unique to infra/hotstrings, so the present-string
	; checks are unambiguous within that scope.
	DirSrc := _DriverDirConcat("infra/hotstrings")

	Assert(InStr(DirSrc, "_PrefixScheduleRender(") > 0,
		"hotstring_prefix_watcher.ahk must define the debounced render scheduler "
		. "_PrefixScheduleRender — without it the ~60 ms tooltip rebuild runs on "
		. "the synchronous keystroke path and every trigger-prefix keystroke lags")

	Assert(InStr(DirSrc, "_PrefixRenderFlush(") > 0,
		"hotstring_prefix_watcher.ahk must define the debounce flush _PrefixRenderFlush")

	; Scope to the hot _OnPrefixChar body. The bare-name helper anchors on the
	; column-0 definition, so it never matches the _OnPrefixCharProfiled shim.
	FnBody := _DriverFuncBody("_OnPrefixChar")
	Assert(FnBody != "",
		"hotstring_prefix_watcher.ahk must define _OnPrefixChar(IH, Char) — entry point not found")

	Assert(InStr(FnBody, "_PrefixScheduleRender(") > 0,
		"_OnPrefixChar must defer the preview render via _PrefixScheduleRender")

	Assert(!InStr(FnBody, "_LookupAndRender("),
		"_OnPrefixChar must NOT call _LookupAndRender() synchronously — the ~60 ms "
		. "render must stay off the keystroke path (route it through the debounce)")
}

Test("meta prefix: _OnPrefixChar defers the tooltip render off the keystroke path",
	_MetaCheckPrefixRenderDeferred)

; Regression for the magic-key latency spike. When a hotstring fires, the
; debounce timer armed for the PRE-expansion buffer is still pending. Left
; armed, it fires reentrantly inside HSE_DispatchMatch's SendInput message pump
; and draws a throwaway tooltip in the middle of the expansion — measured at
; ~35 ms added to the ★ keystroke at speed. The fix cancels the pending render
; (_PrefixCancelRender) BEFORE HSE_DispatchMatch, so the obsolete preview can
; never paint during the send. This asserts the ordering at the source level.
_MetaCheckPrefixRenderCancelledOnFire() {
	; Move-resilient: scan the hotstrings lib dir for the cancel helper definition
	; and the _OnPrefixChar body for the cancel-before-dispatch ordering. Both
	; _PrefixCancelRender and HSE_DispatchMatch appear once each (as code) inside
	; the body, so the positional assertion is preserved.
	DirSrc := _DriverDirConcat("infra/hotstrings")

	Assert(InStr(DirSrc, "_PrefixCancelRender(") > 0,
		"hotstring_prefix_watcher.ahk must define _PrefixCancelRender — without it the "
		. "obsolete pre-expansion preview fires reentrantly during the magic-key send")

	FnBody := _DriverFuncBody("_OnPrefixChar")
	Assert(FnBody != "",
		"hotstring_prefix_watcher.ahk must define _OnPrefixChar(IH, Char) — entry point not found")

	CancelPos   := InStr(FnBody, "_PrefixCancelRender(")
	DispatchPos := InStr(FnBody, "HSE_DispatchMatch(")
	Assert(CancelPos > 0,
		"_OnPrefixChar must cancel the pending render via _PrefixCancelRender when a match fires")
	Assert(DispatchPos > 0,
		"_OnPrefixChar must dispatch the match via HSE_DispatchMatch")
	Assert(CancelPos < DispatchPos,
		"_PrefixCancelRender must run BEFORE HSE_DispatchMatch — otherwise the obsolete "
		. "preview can still fire reentrantly inside the send's message pump")
}

Test("meta prefix: _OnPrefixChar cancels the pending render before dispatching a fire",
	_MetaCheckPrefixRenderCancelledOnFire)
