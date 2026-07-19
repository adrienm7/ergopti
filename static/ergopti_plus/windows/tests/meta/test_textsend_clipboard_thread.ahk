; tests/meta/test_textsend_clipboard_thread.ahk

; ==============================================================================
; MODULE: TextSend Clipboard Thread-Safety Meta Test
; DESCRIPTION:
; Static source guards for the four clipboard-path findings in TextSend
; (adapters/text_sender.ahk):
;
;   - textsend-clipwait-blocks-input-thread
;   - textsend-clipboard-blocks-and-races
;   - textsend-clipwait-blocks-kbd-thread
;   - textsend-restore-timer-race
;
; The original clipboard branch ran CB_Write + ClipWait(1) + Ctrl+V inline on the
; input-gating keyboard thread, ignored ClipWait's return (so a timeout pasted the
; previous clipboard), and armed an uncoordinated restore timer that a later
; injection could let clobber a clipboard a newer send just wrote.
;
; The fix:
;   1. Defers the whole round-trip via SetTimer(..., -1) so it never blocks the
;      keyboard thread (textsend-clipwait-blocks-*-thread).
;   2. Uses a small finite ClipWait timeout constant instead of 1 s
;      (textsend-clipwait-blocks-input-thread).
;   3. Checks ClipWait's boolean and bails loudly (LoggerError) without pasting on
;      timeout (textsend-clipwait-blocks-kbd-thread, fail-fast rule 5.3).
;   4. Guards the deferred restore with a module generation counter so a stale
;      restore no-ops once a newer injection takes over (textsend-restore-timer-race).
;
; Meta-static (scans source text) because TextSend's clipboard path arms real
; SetTimer / ClipWait calls against the live OS clipboard, which a behavioral
; headless run cannot drive deterministically without blocking.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_TSCT_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the function body from its declaration to the first flush-left closing
; brace, with comment lines stripped so comment prose never matches a code pattern.
; Returns "" when the declaration is absent.
_TSCT_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; =================================================
; =================================================
; ======= 2/ Off-thread deferral assertions =======
; =================================================
; =================================================

; The keyboard-thread TextSend body must NOT call ClipWait / ^v inline; it must
; hand the round-trip to a one-shot timer so the hook thread returns immediately.
_TSCT_TextSendDefersClipboardWork() {
	Src := _TSCT_ReadSource("adapters/text_sender.ahk")
	Body := _TSCT_FuncBodyStripped(Src, "TextSend(Text, Opts, Callback) {")
	Assert(Body != "", "TextSend must exist in adapters/text_sender.ahk")
	Assert(!InStr(Body, "ClipWait"),
		"TextSend must NOT call ClipWait inline - blocking the keyboard thread starves the low-level hook and drops keystrokes; defer the clipboard round-trip onto a timer")
	Assert(InStr(Body, "SetTimer") > 0,
		"TextSend clipboard branch must schedule the round-trip via SetTimer so the input-gating thread returns at once")
	Assert(InStr(Body, "_TextSenderStartClipboard") > 0,
		"TextSend must delegate clipboard work to the deferred FIFO worker so the keyboard thread returns at once")
}
Test("text_sender: TextSend defers clipboard work off the keyboard thread (textsend-clipboard-blocks-and-races)", _TSCT_TextSendDefersClipboardWork)





; ==================================================
; ==================================================
; ======= 3/ Finite small timeout assertions =======
; ==================================================
; ==================================================

; The blocking ClipWait must use a small finite timeout constant, never the old 1 s.
_TSCT_ClipWaitTimeoutIsSmall() {
	Src := _TSCT_ReadSource("adapters/text_sender.ahk")
	Assert(InStr(Src, "TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC := 0.2") > 0,
		"A small finite ClipWait timeout constant (0.2 s) must be defined so the wait never stalls perceptibly")
	Body := _TSCT_FuncBodyStripped(Src, "_TextSendClipboard(Text, Saved, Callback := 0) {")
	Assert(Body != "", "_TextSendClipboard helper must exist")
	Assert(!InStr(Body, "ClipWait(1)"),
		"_TextSendClipboard must NOT call ClipWait(1) - a full second blocks far too long; use the small finite TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC")
	Assert(InStr(Body, "ClipWait(TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC)") > 0,
		"_TextSendClipboard must pass the small finite TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC to ClipWait")
}
Test("text_sender: clipboard ClipWait uses a small finite timeout (textsend-clipwait-blocks-input-thread)", _TSCT_ClipWaitTimeoutIsSmall)





; =====================================================
; =====================================================
; ======= 4/ ClipWait return-checked assertions =======
; =====================================================
; =====================================================

; ClipWait's boolean must gate the paste: on timeout, no ^v and a loud LoggerError.
_TSCT_ClipWaitReturnChecked() {
	Src := _TSCT_ReadSource("adapters/text_sender.ahk")
	Body := _TSCT_FuncBodyStripped(Src, "_TextSendClipboard(Text, Saved, Callback := 0) {")
	Assert(Body != "", "_TextSendClipboard helper must exist")
	Assert(InStr(Body, "if !ClipWait(") > 0,
		"_TextSendClipboard must consult ClipWait's return value - a timeout must abort the paste, not be treated as success (fail-fast rule 5.3)")
	Assert(InStr(Body, "LoggerError") > 0,
		"_TextSendClipboard must LoggerError on ClipWait timeout - a silent fallback that pastes stale clipboard content is a fail-fast violation")
}
Test("text_sender: clipboard branch checks ClipWait return and bails loudly (textsend-clipwait-blocks-kbd-thread)", _TSCT_ClipWaitReturnChecked)





; ======================================================
; ======================================================
; ======= 5/ Restore generation-guard assertions =======
; ======================================================
; ======================================================

; The deferred restore must be serialised by a generation counter so a stale
; restore can never clobber a clipboard a later injection just populated.
_TSCT_RestoreGuardedByGeneration() {
	Src := _TSCT_ReadSource("adapters/text_sender.ahk")
	Assert(InStr(Src, "_TEXT_CLIPBOARD_GENERATION") > 0,
		"A module generation counter (_TEXT_CLIPBOARD_GENERATION) must exist to serialise overlapping clipboard restores")

	WriteBody := _TSCT_FuncBodyStripped(Src, "_TextSendClipboard(Text, Saved, Callback := 0) {")
	Assert(InStr(WriteBody, "_TEXT_CLIPBOARD_GENERATION += 1") > 0,
		"_TextSendClipboard must bump the generation counter so each injection claims a unique slot")

	RestoreBody := _TSCT_FuncBodyStripped(Src, "_TextSendRestoreClipboard(Saved, Generation) {")
	Assert(RestoreBody != "", "_TextSendRestoreClipboard guard helper must exist")
	Assert(InStr(RestoreBody, "_TEXT_CLIPBOARD_GENERATION") > 0,
		"_TextSendRestoreClipboard must compare the captured generation against the current counter")
	Assert(InStr(RestoreBody, "return") > 0,
		"_TextSendRestoreClipboard must early-return (no-op) when a newer injection has advanced the generation")
}
Test("text_sender: deferred clipboard restore is generation-guarded (textsend-restore-timer-race)", _TSCT_RestoreGuardedByGeneration)

; A generation check prevents stale restoration, but it does not preserve the
; older requested output when two writes overlap. Clipboard sends therefore need
; a FIFO whose session snapshot is taken only before the first request.
_TSCT_ClipboardRequestsAreFifoSerialized() {
	Src := _TSCT_ReadSource("adapters/text_sender.ahk")
	TextBody := _TSCT_FuncBodyStripped(Src, "TextSend(Text, Opts, Callback) {")
	StartBody := _TSCT_FuncBodyStripped(Src, "_TextSenderStartClipboard() {")
	FinishBody := _TSCT_FuncBodyStripped(Src, "_TextSenderFinishClipboard() {")
	Assert(InStr(Src, "_TEXT_CLIPBOARD_QUEUE := []") > 0 and InStr(Src, "_TEXT_CLIPBOARD_BUSY := false") > 0,
		"clipboard TextSend must own an explicit FIFO and busy state; a generation counter alone drops superseded requested output")
	Assert(InStr(TextBody, "_TEXT_CLIPBOARD_QUEUE.Push") > 0,
		"TextSend must enqueue each clipboard request instead of starting competing workers")
	Assert(InStr(TextBody, "!_TEXT_CLIPBOARD_BUSY and _TEXT_CLIPBOARD_QUEUE.Length = 0") > 0,
		"TextSend must snapshot the user clipboard only at the start of an empty FIFO session")
	Assert(InStr(StartBody, "_TEXT_CLIPBOARD_QUEUE.RemoveAt(1)") > 0 and InStr(StartBody, "_TEXT_CLIPBOARD_BUSY := true") > 0,
		"the worker must claim one FIFO request before performing clipboard I/O")
	Assert(InStr(StartBody, "_TextSendClipboard(Request.Text") > 0,
		"only the FIFO worker may invoke the clipboard round-trip helper")
	Assert(InStr(FinishBody, "_TEXT_CLIPBOARD_BUSY := false") > 0 and InStr(FinishBody, "SetTimer(_TextSenderStartClipboard, -1)") > 0,
		"only completion after the restore window may start the next clipboard request")
}
Test("text_sender: overlapping clipboard sends are serialized FIFO and retain the original clipboard snapshot (textsend-clipboard-output-drop)", _TSCT_ClipboardRequestsAreFifoSerialized)
