; modules/shortcuts/ocr_capture_action.ahk

; ==============================================================================
; MODULE: OCR Capture Action (Windows)
; DESCRIPTION:
; The Windows ports of the « Capture → texte » action (sg_actions.ocr_screenshot,
; Ctrl+O): the overlay of platform/vision/region_select.ahk, the capture and
; Windows.Media.Ocr through the screen vision worker, the clipboard owner and
; the notifier. modules/shortcuts/ocr_capture.ahk owns the steps.
;
; FEATURES & RATIONALE:
; 1. Native on Windows: PowerToys Text Extractor (Win+Shift+T) is no longer
;    required, and the clipboard is touched only once text was read.
; 2. One run at a time: a second Ctrl+O while the overlay is open is refused.
; ==============================================================================

#Requires AutoHotkey v2.0

class OcrCaptureOwner {
	static running := false
	static ports := 0
}

; Binds test ports in place of the native ones (tests).
OcrCaptureSetPorts(Ports) {
	OcrCaptureOwner.ports := Ports
	OcrCaptureOwner.running := false
}

_OcrCaptureDefaultPorts() {
	return Map(
		"select", _OcrCaptureSelect,
		"recognize", (Path, Callback) => ScreenVisionRecognizeFile(Path, Map("layout", "block"), Callback),
		"set_clipboard", (Text) => CB_Write(Text),
		"notify", _OcrCaptureNotify,
		"remove", (Path) => (FileExist(Path) ? FileDelete(Path) : 0),
		"log", _OcrCaptureLog)
}

_OcrCaptureSelect(Callback) {
	AutoClickVision()
	Started := RegionSelect((Rect, Reason) => IsObject(Rect)
		? ScreenVisionCaptureRegion(Rect, (Image, Why) => Callback.Call(IsObject(Image) ? Image["source"] : "", Why))
		: Callback.Call("", Reason))
	if !Started
		Callback.Call("", "capture_unavailable")
}

_OcrCaptureNotify(Key, Level, Lines) {
	try NotifierSend(StrReplace(t(Key), "{1}", Lines), Map("level", Level))
}

_OcrCaptureLog(Level, Message, Args*) {
	switch Level {
		case "warn": LoggerWarn("OcrCapture", Message, Args*)
		case "error": LoggerError("OcrCapture", Message, Args*)
		default: LoggerInfo("OcrCapture", Message, Args*)
	}
}

; Runs one capture (Ctrl+O). Returns whether it started.
OcrCaptureAction(*) {
	if OcrCaptureOwner.running {
		LoggerInfo("OcrCapture", "OCR capture refused: a selection is already open.")
		return false
	}
	OcrCaptureOwner.running := true
	try {
		OcrCaptureRun(IsObject(OcrCaptureOwner.ports) ? OcrCaptureOwner.ports : _OcrCaptureDefaultPorts(),
			(*) => (OcrCaptureOwner.running := false))
	} catch as Err {
		OcrCaptureOwner.running := false
		LoggerError("OcrCapture", "OCR capture raised: {1}.", Err.Message)
		return false
	}
	return true
}
