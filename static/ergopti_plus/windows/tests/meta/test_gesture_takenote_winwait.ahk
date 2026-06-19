; tests/meta/test_gesture_takenote_winwait.ahk

; ==============================================================================
; MODULE: GestureTakeNote WinWait Qualification Guard
; DESCRIPTION:
; Static source guard for the "gesture-takenote-winwait-unqualified" bug in
; modules/gestures.ahk.
;
; ROOT CAUSE ENCODED:
; GestureTakeNote() launches notepad.exe then waits for a matching window with
; WinWait(). If the wait used only the bare filename (e.g. "Notes.txt") with
; TitleMatchMode 2 (partial match), ANY already-open window whose title contains
; that filename (an Explorer window, a browser tab, an IDE with the file open)
; would satisfy the wait immediately. The function would then attempt to activate
; that unrelated window and skip activating Notepad, leaving the note-taking flow
; broken silently.
;
; The fix: use NotepadMatch (FileName . " ahk_exe notepad.exe") for WinWait, the
; same constrained criterion already used by WMExists() and WinWaitActive() in
; the same function. NotepadMatch was already declared before the Run() call, so
; the fix is a one-word substitution with no new variables.
; ==============================================================================

#Requires AutoHotkey v2.0

_GTN_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_GTN_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_GTN_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ===========================================================================
; ===========================================================================
; ======= 1/ GestureTakeNote WinWait is qualified with ahk_exe notepad.exe ==
; ===========================================================================
; ===========================================================================

_GTN_WinWaitIsQualified() {
	Raw := _GTN_ReadSource("modules/gestures.ahk")
	Src := _GTN_StripComments(Raw)
	Body := _GTN_FuncBody(Src, "GestureTakeNote() {")
	Assert(Body != "", "GestureTakeNote() must exist in modules/gestures.ahk")

	; Negative: bare WinWait on filename alone must not appear after Run()
	; (TitleMatchMode 2 means any open window containing the filename matches)
	RunIdx    := InStr(Body, "Run(")
	BareWait  := InStr(Body, "WinWait(FileName,", false, RunIdx)
	Assert(BareWait = 0,
		"GestureTakeNote must not use WinWait(FileName, ...) after Run() — any window with the filename in its title would match (gesture-takenote-winwait-unqualified)")

	; Positive: WinWait must use NotepadMatch (which includes ahk_exe notepad.exe)
	QualWait := InStr(Body, "WinWait(NotepadMatch,", false, RunIdx)
	Assert(QualWait > 0,
		"GestureTakeNote must use WinWait(NotepadMatch, ...) after Run() to restrict the wait to notepad.exe (gesture-takenote-winwait-unqualified)")
}
Test("gestures: GestureTakeNote WinWait after Run() uses NotepadMatch (ahk_exe notepad.exe qualified)", _GTN_WinWaitIsQualified)
