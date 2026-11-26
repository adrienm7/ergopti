; tests/unit/modules/shortcuts/workflows/test_workflow_screen.ahk

; ==============================================================================
; MODULE: Workflow Screen Steps (Windows port)
; DESCRIPTION:
; Replays the cases of _shared/tests/lua/workflows/workflow_screen_contract.lua,
; which the macOS and Linux suites run against the shared screen.lua, against
; modules/shortcuts/workflows/screen.ahk over a recording vision adapter: an
; embedded image seen in the front window, wait_for polling at the registry
; interval and giving up at its timeout, a text target clicked at the
; matcher's click point, a service refusal mapped through screen_reasons, the
; OCR text joined by line, a capture's file, and a cancel that silences the
; late answer. Also checks that the effects hand the running workflow to the
; screen port.
;
; ROOT CAUSE ENCODED:
; Every Windows screen step stopped with screen_service_missing: nothing
; turned a wait_for, click_target, capture, ocr or « visible » into calls on
; the screen vision service.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Recording vision ================
; ============================================
; ============================================

; "\x89PNG fake", base64 "iVBORyBmYWtl" as the contract's.
global _TWFS_PNG_BASE64 := "iVBORyBmYWtl"

; Script: found (Array of booleans per look), words, refuse, ocr_refuse.
_TWFS_Vision(Script) {
	World := { Looks: 0, Clicks: [], Timers: [], Templates: [], Now: 0, Mode: "" }
	Frame := Map("x", 100, "y", 200, "width", 50, "height", 50)
	Found := Script.Get("found", [])
	Vision := Map(
		"window_image", (Done) => Script.Has("refuse") ? Done.Call(0, Script["refuse"])
			: (World.Looks += 1, Done.Call(Map("width", 50, "height", 50, "frame", Frame, "scale", 2))),
		"capture", (Mode, Done) => (World.Mode := Mode, Script.Has("refuse") ? Done.Call(0, Script["refuse"])
			: Done.Call(Map("image", Map("frame", Frame, "scale", 1)))),
		"template", (Bytes, Key, Done) => (World.Templates.Push(Map("bytes", CryptoBase64Encode(Bytes), "key", Key)),
			Done.Call(Map("path", "C:\cache\t.png"))),
		"match", (Image, Templates, Done) => (Found.Length >= World.Looks && Found[World.Looks])
			? Done.Call([Map("id", Templates[1]["id"], "x", 10, "y", 20, "width", 4, "height", 6)], Map())
			: Done.Call([], Map()),
		"recognize", (Capture, Done) => Script.Has("ocr_refuse") ? Done.Call(0, Script["ocr_refuse"])
			: Done.Call(Script.Get("words", [])),
		"save", (Capture, Done) => Done.Call("C:\cache\capture.png"),
		"click", (X, Y, Button, Done) => (World.Clicks.Push(Map("x", X, "y", Y, "button", Button)), Done.Call(true)),
		"click_point", _WorkflowClickPoint,
		"find_text", _TWFS_FindText,
		"after", (Ms, Fn) => _TWFS_After(World, Ms, Fn),
		"now_ms", () => World.Now)
	return { Screen: WorkflowScreen(Vision, Map("catalogue", WorkflowCatalogue(), "poll_ms", 250,
		"text_max_distance", 1, "threshold", 0.9)), World: World }
}

_TWFS_FindText(Words, Targets) {
	for Word in Words
		if Word["text"] == Targets[1]["variants"][1]
			return [Map("id", Targets[1]["id"], "x", Word["x"], "y", Word["y"], "width", Word["width"],
				"height", Word["height"])]
	return []
}

_TWFS_After(World, Ms, Fn) {
	Timer := { Ms: Ms, Fn: Fn, Live: true }
	World.Timers.Push(Timer)
	return () => Timer.Live := false
}

; Fires the pending timer, advancing the clock by its delay.
_TWFS_Tick(World) {
	for Timer in World.Timers
		if Timer.Live {
			Timer.Live := false
			World.Now += Timer.Ms
			Timer.Fn.Call()
			return true
		}
	return false
}

_TWFS_Workflow() {
	global _TWFS_PNG_BASE64
	return Map("id", "wf_1", "images", Map("send", _TWFS_PNG_BASE64))
}

_TWFS_Image() {
	return Map("type", "image", "image", "send")
}

_TWFS_Visible(Target) {
	return Map("condition", Map("type", "visible", "target", Target))
}




; ============================================
; ============================================
; ======= 2/ Contract cases ==================
; ============================================
; ============================================

_TWFS_ImageVisible() {
	global _TWFS_PNG_BASE64
	T := _TWFS_Vision(Map("found", [true]))
	Result := 0
	T.Screen.visible(_TWFS_Visible(_TWFS_Image()), (R) => Result := R, _TWFS_Workflow())
	AssertTrue(Result["ok"] && Result["value"], "an embedded image seen in the front window is visible")
	AssertEqual(_TWFS_PNG_BASE64, T.World.Templates[1]["bytes"], "the embedded base64 is decoded to its bytes")
	AssertEqual("wf_1/send", T.World.Templates[1]["key"], "the template is keyed by workflow and image")
	T := _TWFS_Vision(Map("found", []))
	T.Screen.visible(_TWFS_Visible(_TWFS_Image()), (R) => Result := R, _TWFS_Workflow())
	AssertTrue(Result["ok"] && !Result["value"], "an image not seen is not visible, without failing")
}
Test("workflow screen: an embedded image is visible or not, never a failure (workflow-screen)", _TWFS_ImageVisible)

_TWFS_WaitForPolls() {
	T := _TWFS_Vision(Map("found", [false, false, true]))
	Result := 0
	T.Screen.wait_for(Map("target", _TWFS_Image(), "timeout_ms", 5000), (R) => Result := R, _TWFS_Workflow())
	AssertEqual(0, Result, "nothing is answered before the image shows")
	AssertTrue(_TWFS_Tick(T.World), "a poll is pending")
	AssertEqual(250, T.World.Timers[1].Ms, "the poll interval of the timing registry")
	AssertTrue(_TWFS_Tick(T.World), "a second poll is pending")
	AssertTrue(IsObject(Result) && Result["ok"], "wait_for ends once the image shows")
	AssertEqual(3, T.World.Looks, "one look per poll")
	T := _TWFS_Vision(Map("words", []))
	Result := 0
	T.Screen.wait_for(Map("target", Map("type", "text", "text", "OK"), "timeout_ms", 600), (R) => Result := R,
		_TWFS_Workflow())
	while !IsObject(Result) && _TWFS_Tick(T.World)
		continue
	AssertEqual("text_not_found", Result["reason"], "wait_for gives up at its timeout")
	AssertTrue(T.World.Now <= 600, "no look starts past the timeout")
}
Test("workflow screen: wait_for polls until found or its timeout (workflow-screen)", _TWFS_WaitForPolls)

_TWFS_ClickTarget() {
	T := _TWFS_Vision(Map("words", [Map("text", "Send", "x", 20, "y", 40, "width", 10, "height", 10, "line", 1)]))
	Result := 0
	T.Screen.click_target(Map("target", Map("type", "text", "text", "Send")), (R) => Result := R, _TWFS_Workflow())
	AssertTrue(Result["ok"], "a text target is clicked")
	AssertEqual(112, T.World.Clicks[1]["x"], "at the matcher's click point (x)")
	AssertEqual(222, T.World.Clicks[1]["y"], "at the matcher's click point (y)")
	AssertEqual("left", T.World.Clicks[1]["button"], "with the left button by default")
	T := _TWFS_Vision(Map("found", []))
	T.Screen.click_target(Map("target", _TWFS_Image(), "button", "right"), (R) => Result := R, _TWFS_Workflow())
	AssertEqual("image_not_found", Result["reason"], "an absent image fails with image_not_found")
	AssertEqual(0, T.World.Clicks.Length, "and nothing is clicked")
}
Test("workflow screen: click_target clicks at the click point or names the miss (workflow-screen)", _TWFS_ClickTarget)

_TWFS_RefusalMaps() {
	Catalogue := WorkflowCatalogue()
	T := _TWFS_Vision(Map("refuse", "capture_permission_missing"))
	Result := 0
	T.Screen.visible(_TWFS_Visible(_TWFS_Image()), (R) => Result := R, _TWFS_Workflow())
	AssertEqual("screen_permission_missing", Result["reason"], "a service refusal maps to its run reason")
	AssertEqual("ocr_unavailable", WorkflowScreenRunReason(Catalogue, "ocr_engine_missing"), "a known reason maps")
	AssertEqual("screen_read_failed", WorkflowScreenRunReason(Catalogue, "not_in_the_vocabulary"),
		"an unknown one falls to screen_reason_other")
	Known := Map()
	for Reason in Catalogue["run_reasons"]
		Known[Reason] := true
	for _, Reason in Catalogue["screen_reasons"]
		AssertTrue(Known.Has(Reason), Reason . " is a run reason with a notice")
}
Test("workflow screen: a service refusal maps to its run reason (workflow-screen)", _TWFS_RefusalMaps)

_TWFS_OcrAndCapture() {
	T := _TWFS_Vision(Map("words", [Map("text", "Hello", "line", 1), Map("text", "world", "line", 1),
		Map("text", "Bye", "line", 2)]))
	Read := 0, Captured := 0
	T.Screen.ocr(Map("mode", "region"), (R) => Read := R, _TWFS_Workflow())
	AssertEqual("Hello world`nBye", Read["value"], "OCR joins words by line")
	AssertEqual("region", T.World.Mode, "in the mode the step names")
	T.Screen.capture(Map("mode", "full"), (R) => Captured := R, _TWFS_Workflow())
	AssertEqual("C:\cache\capture.png", Captured["value"], "a capture's value is its PNG file")
}
Test("workflow screen: ocr joins words by line and capture stores its file (workflow-screen)", _TWFS_OcrAndCapture)

_TWFS_CancelSilences() {
	T := _TWFS_Vision(Map("found", []))
	Result := 0
	Cancel := T.Screen.wait_for(Map("target", _TWFS_Image(), "timeout_ms", 5000), (R) => Result := R, _TWFS_Workflow())
	Cancel.Call()
	AssertFalse(_TWFS_Tick(T.World), "the poll timer is cancelled")
	AssertEqual(0, Result, "and no answer follows")
}
Test("workflow screen: a cancel drops the late answer and stops polling (workflow-screen)", _TWFS_CancelSilences)

; A screen port that records the workflow it is handed.
class _TWFS_RecordingScreen {
	Seen := 0
	visible(Effect, Done, Workflow) {
		this.Seen := Workflow
		Done.Call(Map("ok", true, "value", true))
		return 0
	}
}

_TWFS_EffectsHandTheWorkflow() {
	global WORKFLOW_REQUIRED_EFFECT_PORTS
	Screen := _TWFS_RecordingScreen()
	Ports := Map("screen", Screen)
	for Name in WORKFLOW_REQUIRED_EFFECT_PORTS
		Ports[Name] := (*) => 0
	Result := 0
	Workflow := _TWFS_Workflow()
	WorkflowEffects(Ports).Perform(Map("op", "probe", "condition", Map("type", "visible",
		"target", Map("type", "text", "text", "x"))), (R) => Result := R, Workflow)
	AssertTrue(Screen.Seen == Workflow, "the effects hand the running workflow to the screen port")
	AssertTrue(Result["value"], "and its answer back")
}
Test("workflow screen: the effects hand the running workflow to the screen port (workflow-screen)",
	_TWFS_EffectsHandTheWorkflow)
