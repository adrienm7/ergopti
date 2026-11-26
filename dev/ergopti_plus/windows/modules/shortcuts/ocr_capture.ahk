; modules/shortcuts/ocr_capture.ahk

; ==============================================================================
; MODULE: OCR Capture to Clipboard (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/shortcuts/engine/ocr_capture.lua: the « Capture → texte »
; action (sg_actions.ocr_screenshot, Ctrl+O). The region selection, the OCR
; engine and the clipboard are ports; this module owns the order of the
; steps, the text assembly and every outcome, as on macOS and Linux.
;
; FEATURES & RATIONALE:
; 1. The words of one OCR line are joined by a space and the lines by a line
;    feed, in reading order, so the clipboard keeps the line breaks.
; 2. Nothing recognised leaves the clipboard unchanged and says so; Escape
;    cancels quietly; the recognised text is never logged, only its size.
; 3. The capture file is removed whatever the outcome.
;
; Pinned by _shared/tests/corpus/keep_awake/ocr_capture_vectors.json, which
; tests/unit/modules/shortcuts/test_ocr_capture.ahk replays.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================
; ==================================
; ======= 1/ Text ==================
; ==================================
; ==================================

; The notification of each outcome that shows one: Map outcome -> [key, level].
OcrCaptureNotices() {
	static Notices := Map("copied", ["ocr_capture.copied", "info"],
		"nothing_recognised", ["ocr_capture.nothing_recognised", "warning"],
		"failed", ["ocr_capture.failed", "error"])
	return Notices
}

; The clipboard text of OCR words (Maps text, line), one line per OCR line.
; Returns [Text, Lines]; Text is "" when no word has a visible character.
OcrCaptureText(Words) {
	Order := [], ByLine := Map()
	for Word in Words {
		Text := Word.Has("text") && Type(Word["text"]) == "String" ? Trim(Word["text"], " `t`r`n") : ""
		if (Text == "")
			continue
		Line := Word.Has("line") ? String(Word["line"]) : ""
		if !ByLine.Has(Line) {
			ByLine[Line] := []
			Order.Push(Line)
		}
		ByLine[Line].Push(Text)
	}
	Result := ""
	for Index, Line in Order {
		Joined := ""
		for Part in ByLine[Line]
			Joined .= (Joined == "" ? "" : " ") . Part
		Result .= (Index == 1 ? "" : "`n") . Joined
	}
	return [Result, Order.Length]
}




; ==================================
; ==================================
; ======= 2/ Run ===================
; ==================================
; ==================================

; Runs one capture: select, recognise, copy, notify.
; Ports: Map select(Callback(Path, Reason)) — Path "" and Reason "cancelled"
; on Escape; recognize(Path, Callback(Words, Reason)); set_clipboard(Text) ->
; Boolean; notify(Key, Level, Lines); remove(Path); log(Level, Message, Args*).
; Done: Callback(Outcome, Reason) once the run ended, or "".
OcrCaptureRun(Ports, Done := "") {
	for Name in ["select", "recognize", "set_clipboard", "notify", "remove", "log"]
		if !Ports.Has(Name) || !HasMethod(Ports[Name])
			throw ValueError("the OCR capture needs the port " . Name)
	Ports["select"].Call(_OcrCaptureSelected.Bind(Ports, Done))
}

_OcrCaptureFinish(Ports, Done, Outcome, Reason := "", Lines := "") {
	Notices := OcrCaptureNotices()
	if Notices.Has(Outcome)
		Ports["notify"].Call(Notices[Outcome][1], Notices[Outcome][2], Lines)
	if (Outcome == "failed")
		Ports["log"].Call("warn", "OCR capture failed: reason={1}.", Reason)
	else if (Outcome == "cancelled")
		Ports["log"].Call("info", "OCR capture cancelled.")
	if HasMethod(Done)
		Done.Call(Outcome, Reason)
}

_OcrCaptureSelected(Ports, Done, Path, Reason := "") {
	if (Path == "") {
		if (Reason == "cancelled")
			return _OcrCaptureFinish(Ports, Done, "cancelled", Reason)
		return _OcrCaptureFinish(Ports, Done, "failed", Reason == "" ? "capture_empty" : Reason)
	}
	Ports["recognize"].Call(Path, _OcrCaptureRecognised.Bind(Ports, Done, Path))
}

_OcrCaptureRecognised(Ports, Done, Path, Words, Reason := "") {
	Ports["remove"].Call(Path)
	if !IsObject(Words)
		return _OcrCaptureFinish(Ports, Done, "failed", Reason == "" ? "ocr_failed" : Reason)
	Result := OcrCaptureText(Words)
	if (Result[1] == "") {
		Ports["log"].Call("info", "OCR capture recognised nothing; the clipboard is unchanged.")
		return _OcrCaptureFinish(Ports, Done, "nothing_recognised")
	}
	if !Ports["set_clipboard"].Call(Result[1])
		return _OcrCaptureFinish(Ports, Done, "failed", "clipboard_write_failed")
	Ports["log"].Call("info", "OCR capture copied {1} line(s), {2} character(s).", Result[2], StrLen(Result[1]))
	_OcrCaptureFinish(Ports, Done, "copied", "", Result[2])
}
