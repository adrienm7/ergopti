; tests/meta/test_lost_tick_after_filtered_keystroke.ahk

; ==============================================================================
; MODULE: Lost-Tick-After-Filtered-Keystroke Meta Test
; DESCRIPTION:
; Static source guard for the lost-tick-after-filtered-keystroke finding.
;
; Both InputHook callbacks (KL_Hook_OnChar / KL_Hook_OnKeyDown) used to early-
; return on MF_ShouldFilter() BEFORE advancing the KLHook.last_tick watermark
; and driving KL_Watchers_OnKeystroke(). When the user typed into a privacy-
; filtered field (password, private browsing) for a while and then resumed in a
; normal field, the first unfiltered keystroke computed delay = now - last_tick
; across the WHOLE filtered interlude - fabricating a think-pause, breaking the
; walker's burst, and emitting a spurious retroactive idle / session_end.
;
; The fix routes the watermark + watcher update through a shared helper,
; KL_Hook_NoteActivity(), invoked at the TOP of each callback (after the
; A_IsSuspended + Keylogger.initialized guards) and crucially BEFORE the
; MF_ShouldFilter() short-circuit. A filtered key is still a physical keypress:
; its content is dropped, but the timing watermark advances regardless.
;
; This is a meta-static test (scans source text) because keylogger_hook.ahk is
; not part of the headless runner's #Include graph (it wires the production
; InputHook through HookDispatcher at top level). If a regression re-orders the
; filter check ahead of the watermark update, the ordering assertions fail.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

_LTAFK_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; =====================================================
; =====================================================
; ======= 2/ Watermark-before-filter assertions =======
; =====================================================
; =====================================================

; The shared helper must exist; it is what advances last_tick + drives the
; watcher for every physical keypress, filtered or not.
_LTAFK_HelperExists() {
	Src := _LTAFK_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Body := _DriverFuncBody("KL_Hook_NoteActivity")
	Assert(Body != "",
		"KL_Hook_NoteActivity must exist in keylogger_hook.ahk - it is the single place that advances KLHook.last_tick for every physical keypress (lost-tick-after-filtered-keystroke)")
	Assert(InStr(Body, "KLHook.last_tick := now") > 0,
		"KL_Hook_NoteActivity must advance KLHook.last_tick to now (lost-tick-after-filtered-keystroke)")
	Assert(InStr(Body, "KL_Watchers_OnKeystroke") > 0,
		"KL_Hook_NoteActivity must drive KL_Watchers_OnKeystroke so the session/idle machine sees every physical keypress (lost-tick-after-filtered-keystroke)")
}
Test("keylogger_hook: KL_Hook_NoteActivity helper advances watermark + drives watcher (lost-tick-after-filtered-keystroke)", _LTAFK_HelperExists)

; In OnChar, the watermark update must happen BEFORE the privacy filter, so a
; filtered key still advances last_tick.
_LTAFK_OnCharNotesBeforeFilter() {
	Src := _LTAFK_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Body := _DriverFuncBody("KL_Hook_OnChar")
	Assert(Body != "", "KL_Hook_OnChar must exist in keylogger_hook.ahk")
	NotePos := InStr(Body, "KL_Hook_NoteActivity(")
	FilterPos := InStr(Body, "MF_ShouldFilter()")
	Assert(NotePos > 0,
		"KL_Hook_OnChar must call KL_Hook_NoteActivity() (lost-tick-after-filtered-keystroke)")
	Assert(FilterPos > 0,
		"KL_Hook_OnChar must still call MF_ShouldFilter() for privacy (lost-tick-after-filtered-keystroke)")
	Assert(NotePos < FilterPos,
		"KL_Hook_OnChar must advance the watermark via KL_Hook_NoteActivity() BEFORE the MF_ShouldFilter() short-circuit - otherwise a filtered keystroke leaves last_tick stale and the next key fabricates a giant delay (lost-tick-after-filtered-keystroke)")
}
Test("keylogger_hook: OnChar advances watermark before MF_ShouldFilter (lost-tick-after-filtered-keystroke)", _LTAFK_OnCharNotesBeforeFilter)

; Same ordering invariant for the special-key (bracket marker) path of OnKeyDown.
_LTAFK_OnKeyDownNotesBeforeFilter() {
	Src := _LTAFK_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Body := _DriverFuncBody("KL_Hook_OnKeyDown")
	Assert(Body != "", "KL_Hook_OnKeyDown must exist in keylogger_hook.ahk")
	; The shortcut path holds the first MF_ShouldFilter-free activity bump; the
	; bracket-marker path adds the NoteActivity-before-filter ordering we assert.
	NotePos := InStr(Body, "KL_Hook_NoteActivity(")
	FilterPos := InStr(Body, "MF_ShouldFilter()")
	Assert(NotePos > 0,
		"KL_Hook_OnKeyDown must call KL_Hook_NoteActivity() on the special-key path (lost-tick-after-filtered-keystroke)")
	Assert(FilterPos > 0,
		"KL_Hook_OnKeyDown must still call MF_ShouldFilter() for privacy (lost-tick-after-filtered-keystroke)")
	Assert(NotePos < FilterPos,
		"KL_Hook_OnKeyDown must advance the watermark via KL_Hook_NoteActivity() BEFORE MF_ShouldFilter() on the special-key path (lost-tick-after-filtered-keystroke)")
}
Test("keylogger_hook: OnKeyDown special-key path notes activity before filter (lost-tick-after-filtered-keystroke)", _LTAFK_OnKeyDownNotesBeforeFilter)
