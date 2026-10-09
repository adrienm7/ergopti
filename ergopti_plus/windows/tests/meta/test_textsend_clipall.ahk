; tests/meta/test_textsend_clipall.ahk

; ==============================================================================
; MODULE: TextSend ClipboardAll Meta Test
; DESCRIPTION:
; Static source guard for the textsend-clip-destroys-nontext finding.
;
; CB_Save()/CB_Restore() use A_Clipboard (text only). In AHK v2, A_Clipboard
; coerces non-text content (CF_BITMAP images, CF_HDROP file lists, HTML, RTF)
; to "". When TextSend's clipboard branch used CB_Save/CB_Restore, any non-text
; clipboard content held by the user was silently destroyed: CB_Save() returned
; "" and CB_Restore("") then cleared the clipboard entirely.
;
; The fix adds CB_SaveAll()/CB_RestoreAll() to clipboard.ahk that use
; ClipboardAll(), which round-trips ALL clipboard formats, and switches
; TextSend's clipboard branch to use them.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helper =====================
; ===================================================
; ===================================================

_TSCA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts the function body from FuncDef to the next non-indented closing brace,
; then strips all comment lines so comment text does not pollute code-pattern searches.
_TSCA_FuncBodyStripped(Src, FuncDef) {
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




; ===================================================
; ===================================================
; ======= 2/ TextSend assertions ====================
; ===================================================
; ===================================================

; CB_SaveAll() is called by the FIFO owner immediately before its write. This
; preserves all formats without retaining a stale snapshot across an intervening
; user copy while another clipboard request is queued.
_TSCA_TextSendUsesSaveAll() {
	Src := _TSCA_ReadSource("adapters/text_sender.ahk")
	Body := _TSCA_FuncBodyStripped(Src, "_TextSenderStartClipboard() {")
	Assert(Body != "", "_TextSenderStartClipboard must exist in adapters/text_sender.ahk")
	Assert(!InStr(Body, "CB_Save()"),
		"The FIFO clipboard owner must NOT call CB_Save() — it is text-only and destroys non-text clipboard content; use CB_SaveAll() instead")
	Assert(InStr(Body, "CB_SaveAll()") > 0,
		"The FIFO clipboard owner must call CB_SaveAll() to preserve all clipboard formats")
}
Test("text_sender: FIFO clipboard owner uses CB_SaveAll instead of CB_Save (textsend-clip-destroys-nontext)", _TSCA_TextSendUsesSaveAll)

_TSCA_TextSendUsesRestoreAll() {
	Src := _TSCA_ReadSource("adapters/text_sender.ahk")
	; The retrying all-format restore coordinator is called from both timeout
	; bail-outs and the deferred restore helper, so assert against the whole file.
	Assert(!InStr(Src, "CB_Restore("),
		"The clipboard branch must NOT call CB_Restore() — it is text-only; use CB_RestoreAll() instead")
	Assert(InStr(Src, "CB_RestoreOwnedAllEventually(") > 0,
		"The clipboard branch must use the retrying all-format restore coordinator")
}
Test("text_sender: clipboard branch uses CB_RestoreAll instead of CB_Restore (textsend-clip-destroys-nontext)", _TSCA_TextSendUsesRestoreAll)




; ===================================================
; ===================================================
; ======= 3/ Clipboard adapter assertions ===========
; ===================================================
; ===================================================

_TSCA_SaveAllUsesClipboardAll() {
	Src := _TSCA_ReadSource("adapters/clipboard.ahk")
	Body := _TSCA_FuncBodyStripped(Src, "CB_SaveAll() {")
	Assert(Body != "", "CB_SaveAll must exist in adapters/clipboard.ahk")
	Assert(InStr(Body, "ClipboardAll()") > 0,
		"CB_SaveAll must call ClipboardAll() — not A_Clipboard — to capture all clipboard formats")
}
Test("clipboard: CB_SaveAll uses ClipboardAll() to capture all formats (textsend-clip-destroys-nontext)", _TSCA_SaveAllUsesClipboardAll)

_TSCA_RestoreAllAssignsClipboard() {
	Src := _TSCA_ReadSource("adapters/clipboard.ahk")
	Body := _TSCA_FuncBodyStripped(Src, "CB_RestoreAll(Saved) {")
	Assert(Body != "", "CB_RestoreAll must exist in adapters/clipboard.ahk")
	Assert(InStr(Body, "A_Clipboard := Saved") > 0,
		"CB_RestoreAll must assign A_Clipboard := Saved to restore all clipboard formats")
}
Test("clipboard: CB_RestoreAll assigns A_Clipboard := Saved to restore all formats (textsend-clip-destroys-nontext)", _TSCA_RestoreAllAssignsClipboard)
