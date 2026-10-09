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
; The fix routes the physical watermark through KL_Hook_NoteActivity after
; privacy classification, passing the verdict into the helper. A filtered key
; still advances last_tick, but it reaches only the privacy-boundary watcher;
; accepted session state is never mutated before classification.
;
; Native registered tests exercise actual callback reentrancy. These source
; checks retain the classification-before-accounting policy across the prepare
; callbacks and the shared ordered commit owner. The hook is definition-only.
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
		"KL_Hook_NoteActivity must drive the authorized session watcher")
	Assert(InStr(Body, "KL_Watchers_OnPrivateKeystroke") > 0,
		"KL_Hook_NoteActivity must record a privacy boundary without session mutation")
}
Test("keylogger_hook: KL_Hook_NoteActivity helper advances watermark + drives watcher (lost-tick-after-filtered-keystroke)", _LTAFK_HelperExists)

; In OnChar, classification must precede watcher selection while the helper is
; still called before the filtered early return.
_LTAFK_OnCharNotesBeforeFilter() {
	Callback := _DriverFuncBody("KL_Hook_OnChar")
	Commit := _DriverFuncBody("_KL_Hook_CommitInput")
	Assert(Callback != "" && Commit != "", "actual callback and commit subjects must exist")
	_LTAFK_OrderedBodies(Callback, Commit)
}
Test("keylogger_hook: OnChar advances watermark with a privacy verdict (lost-tick-after-filtered-keystroke)", _LTAFK_OnCharNotesBeforeFilter)

; Same ordering invariant for the special-key (bracket marker) path of OnKeyDown.
_LTAFK_OnKeyDownNotesBeforeFilter() {
	Callback := _DriverFuncBody("KL_Hook_OnKeyDown")
	Commit := _DriverFuncBody("_KL_Hook_CommitInput")
	Assert(Callback != "" && Commit != "", "actual callback and commit subjects must exist")
	_LTAFK_OrderedBodies(Callback, Commit)
}
Test("keylogger_hook: OnKeyDown notes activity with a privacy verdict (lost-tick-after-filtered-keystroke)", _LTAFK_OnKeyDownNotesBeforeFilter)


_LTAFK_OrderedBodies(Callback, Commit) {
	Assert(Callback != "" && Commit != "", "actual prepare and commit owners must exist")
	Callback := _DriverMaskNonCode(&Callback)
	Commit := _DriverMaskNonCode(&Commit)
	Capture := InStr(Callback, "_KL_Hook_CaptureInput(")
	Filter := InStr(Callback, "MF_ShouldFilter()")
	Prepare := InStr(Callback, "_KL_Hook_PrepareInput(")
	Finish := InStr(Callback, "_KL_Hook_CompleteInput(")
	Assert(Capture > 0 && Capture < Filter && Filter < Prepare && Prepare < Finish,
		"enqueue must precede classification and finalization must follow prepared privacy")
	Note := InStr(Commit, "KL_Hook_NoteActivity(")
	PrivateReturn := InStr(Commit, "if Intent.filtered", true, Note)
	Assert(Note > 0 && PrivateReturn > Note
		&& InStr(Commit, "!Intent.filtered", true, Note) > Note,
		"ordered commit must account physical time with the verdict before excluding content")
}


_LTAFK_MaskedPolicyControls(Name) {
	Callback := _DriverFuncBody(Name)
	Commit := _DriverFuncBody("_KL_Hook_CommitInput")
	Assert(Callback != "" && Commit != "", "mutation controls require actual owner bodies")
	for Needle in ["_KL_Hook_CaptureInput(", "MF_ShouldFilter()", "_KL_Hook_PrepareInput(", "_KL_Hook_CompleteInput("] {
		StrReplace(Callback, Needle, "", true, &Count)
		AssertEqual(1, Count, "the mutated executable call must be unique")
		for Spoof in ["'" . Needle . "'", "; " . Needle] {
			Changed := StrReplace(Callback, Needle, Spoof, true)
			Refused := false
			try _LTAFK_OrderedBodies(Changed, Commit)
			catch
				Refused := true
			AssertTrue(Refused, "a comment or literal cannot stand in for an actual callback call")
		}
	}
	Needle := "KL_Hook_NoteActivity("
	StrReplace(Commit, Needle, "", true, &Count)
	AssertEqual(2, Count, "both actual physical accounting calls are controlled")
	for Spoof in ["'" . Needle . "'", "; " . Needle] {
		Changed := StrReplace(Commit, Needle, Spoof, true)
		Refused := false
		try _LTAFK_OrderedBodies(Callback, Changed)
		catch
			Refused := true
		AssertTrue(Refused, "a comment or literal cannot stand in for physical accounting")
	}
	_LTAFK_OrderedBodies(Callback, Commit)
}
for _LTAFK_Name in ["KL_Hook_OnChar", "KL_Hook_OnKeyDown"]
	Test("keylogger FIFO source policy: code-only calls " . _LTAFK_Name,
		_LTAFK_MaskedPolicyControls.Bind(_LTAFK_Name))
