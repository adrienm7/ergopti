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
	; Locate lib/hotstrings/hotstring_prefix_watcher.ahk relative to tests/.
	SplitPath(A_ScriptDir, , &WindowsDir)
	PWFile := WindowsDir . "\lib\hotstrings\hotstring_prefix_watcher.ahk"

	try {
		Body := FileRead(PWFile)
	} catch {
		return
	}

	Assert(InStr(Body, "_PrefixScheduleRender(") > 0,
		"hotstring_prefix_watcher.ahk must define the debounced render scheduler "
		. "_PrefixScheduleRender — without it the ~60 ms tooltip rebuild runs on "
		. "the synchronous keystroke path and every trigger-prefix keystroke lags")

	Assert(InStr(Body, "_PrefixRenderFlush(") > 0,
		"hotstring_prefix_watcher.ahk must define the debounce flush _PrefixRenderFlush")

	; Scope to the hot _OnPrefixChar body. In this codebase the only column-0
	; closing brace after the declaration is the function's own, so the first
	; "`n}" after FnPos bounds the body. NOTE: the profiling shim is named
	; _OnPrefixCharProfiled, so match the exact "_OnPrefixChar(IH, Char) {" head.
	FnPos := InStr(Body, "_OnPrefixChar(IH, Char) {")
	Assert(FnPos > 0,
		"hotstring_prefix_watcher.ahk must define _OnPrefixChar(IH, Char) — entry point not found")

	BodyEnd := InStr(Body, "`n}", false, FnPos)
	if (BodyEnd == 0)
		BodyEnd := StrLen(Body) + 1
	FnBody := SubStr(Body, FnPos, BodyEnd - FnPos)

	Assert(InStr(FnBody, "_PrefixScheduleRender(") > 0,
		"_OnPrefixChar must defer the preview render via _PrefixScheduleRender")

	Assert(!InStr(FnBody, "_LookupAndRender("),
		"_OnPrefixChar must NOT call _LookupAndRender() synchronously — the ~60 ms "
		. "render must stay off the keystroke path (route it through the debounce)")
}

Test("meta prefix: _OnPrefixChar defers the tooltip render off the keystroke path",
	_MetaCheckPrefixRenderDeferred)
