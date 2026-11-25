; tests/unit/modules/shortcuts/test_ocr_capture.ahk

; ==============================================================================
; MODULE: OCR Capture (Windows port)
; DESCRIPTION:
; Replays _shared/tests/corpus/keep_awake/ocr_capture_vectors.json, which the
; macOS and Linux suites replay through _shared/shortcuts/engine/ocr_capture.lua,
; through modules/shortcuts/ocr_capture.ahk.
;
; ROOT CAUSE ENCODED:
; A port that joined every word on one line, emptied the clipboard when
; nothing was read, notified a cancelled selection or left the capture file
; behind would differ from macOS and Linux.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TOCR_Run {
	static Clipboard := JSON_NULL, Notice := JSON_NULL, Lines := JSON_NULL, Removed := false
	static Outcome := "", Reason := JSON_NULL, Vector := ""
}

_TOCR_Value(Value) {
	return Value == JSON_NULL ? "" : Value
}

_TOCR_Select(Callback) {
	Select := _TOCR_Run.Vector["select"]
	Callback.Call(Select.Has("path") ? Select["path"] : "", Select.Has("reason") ? Select["reason"] : "")
}

_TOCR_Recognize(Path, Callback) {
	Answer := _TOCR_Run.Vector["recognize"]
	Callback.Call(Answer.Has("words") ? Answer["words"] : 0, Answer.Has("reason") ? Answer["reason"] : "")
}

_TOCR_SetClipboard(Text) {
	_TOCR_Run.Clipboard := Text
	return !(_TOCR_Run.Vector.Has("clipboard_ok") && _TOCR_Run.Vector["clipboard_ok"] == false)
}

_TOCR_Notify(Key, Level, Lines) {
	_TOCR_Run.Notice := Key, _TOCR_Run.Lines := Lines == "" ? JSON_NULL : Lines
}

_TOCR_Vector(Vector) {
	_TOCR_Run.Clipboard := JSON_NULL, _TOCR_Run.Notice := JSON_NULL, _TOCR_Run.Lines := JSON_NULL
	_TOCR_Run.Removed := false, _TOCR_Run.Outcome := "", _TOCR_Run.Reason := JSON_NULL
	_TOCR_Run.Vector := Vector
	Ports := Map("select", _TOCR_Select, "recognize", _TOCR_Recognize, "set_clipboard", _TOCR_SetClipboard,
		"notify", _TOCR_Notify, "remove", (*) => (_TOCR_Run.Removed := true), "log", (*) => 0)
	OcrCaptureRun(Ports, (Outcome, Reason) => (_TOCR_Run.Outcome := Outcome,
		_TOCR_Run.Reason := Reason == "" ? JSON_NULL : Reason))
	Expect := Vector["expect"]
	AssertEqual(Expect["outcome"], _TOCR_Run.Outcome, Vector["id"] . " outcome")
	AssertEqual(_TOCR_Value(Expect["reason"]), _TOCR_Value(_TOCR_Run.Reason), Vector["id"] . " reason")
	AssertEqual(_TOCR_Value(Expect["clipboard"]), _TOCR_Value(_TOCR_Run.Clipboard), Vector["id"] . " clipboard")
	AssertEqual(_TOCR_Value(Expect["notice"]), _TOCR_Value(_TOCR_Run.Notice), Vector["id"] . " notice")
	AssertEqual(_TOCR_Value(Expect["lines"]), _TOCR_Value(_TOCR_Run.Lines), Vector["id"] . " lines")
	AssertEqual(Expect["removed"], _TOCR_Run.Removed, Vector["id"] . " removed")
}

_TOCR_Vectors() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\keep_awake\ocr_capture_vectors.json", "UTF-8"))
	Checked := 0
	for Vector in Corpus["vectors"] {
		_TOCR_Vector(Vector)
		Checked += 1
	}
	AssertTrue(Checked >= 9, "expected the OCR capture vectors, found " . Checked)
}
Test("OCR capture: the port replays every corpus run (ocr-capture-vectors)", _TOCR_Vectors)
