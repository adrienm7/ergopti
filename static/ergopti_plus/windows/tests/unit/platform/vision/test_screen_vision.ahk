; tests/unit/platform/vision/test_screen_vision.ahk

; ==============================================================================
; MODULE: Screen Vision Service (Windows)
; DESCRIPTION:
; Drives platform/vision/screen_vision.ahk through a stubbed worker spawn and
; hand-written queue files: a request is written whole into the queue, an
; answer file reaches its callback once, a refusal arrives as its reason, a
; scan finds its text targets on the worker's words, and a second start is
; refused.
;
; ROOT CAUSE ENCODED:
; The worker's answers arrive through files; a service that read a request
; half-written, answered twice, or let a dead worker leave callers waiting
; would click late, twice, or never tell the menu why nothing happens.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TSV_Spawned {
	static calls := 0
}

_TSV_Spawn(Executable, Args, OnDone) {
	_TSV_Spawned.calls += 1
	return { start: (*) => true, requestTerminate: (*) => true }
}

_TSV_Start() {
	ScreenVisionStop()
	ScreenVisionOwner.spawn_fn := _TSV_Spawn
	AssertTrue(ScreenVisionInit(), "the worker starts")
	Queue := ScreenVisionOwner.queue
	FileAppend('{"ok":true,"capture":{"ok":true},"ocr":{"ok":true}}', Queue . "\ready.json", "UTF-8-RAW")
	_ScreenVisionPoll()
	AssertEqual("ready", ScreenVisionOwner.state, "ready once ready.json is written")
	return Queue
}

_TSV_Finish() {
	ScreenVisionStop()
	ScreenVisionOwner.spawn_fn := 0
}

_TSV_QueueRoundTrip() {
	Queue := _TSV_Start()
	try {
		Answers := []
		ScreenVisionCaptureWindow(4242, (Image, Reason) => Answers.Push([Image, Reason]))
		Request := Queue . "\00000001.req.json"
		AssertTrue(FileExist(Request) != "", "the request is queued whole")
		AssertFalse(FileExist(Request . ".partial") != "", "no partial request is left")
		Sent := JsonParse(FileRead(Request, "UTF-8"))
		AssertEqual("capture", Sent["op"], "the capture op")
		AssertEqual(4242, Sent["window_id"], "the window")
		FileAppend('{"ok":true,"width":10,"height":8,"scale":1,"frame":{"x":5,"y":6,"width":10,"height":8},'
			. '"source":"' . StrReplace(Sent["out_path"], "\", "\\") . '"}', Queue . "\00000001.res.json", "UTF-8-RAW")
		_ScreenVisionPoll()
		_ScreenVisionPoll()
		AssertEqual(1, Answers.Length, "one answer, once")
		AssertEqual(5, Answers[1][1]["frame"]["x"], "the frame")
		AssertEqual(Sent["out_path"], Answers[1][1]["source"], "the image names its capture")
	} finally _TSV_Finish()
}
Test("screen vision: a queued request is answered once (screen-vision-queue)", _TSV_QueueRoundTrip)

_TSV_RefusalAndScan() {
	Queue := _TSV_Start()
	try {
		Refused := ""
		ScreenVisionCaptureWindow(1, (Image, Reason) => (Refused := Reason))
		FileAppend('{"ok":false,"reason":"no_foreground_window"}', Queue . "\00000001.res.json", "UTF-8-RAW")
		_ScreenVisionPoll()
		AssertEqual("no_foreground_window", Refused, "the refusal reason")

		Result := 0
		ScreenVisionScanWindow(7, Map("templates", [], "options", Map("threshold", 0.92),
			"text_targets", [Map("id", "allow", "variants", ["Allow once"], "max_distance", 0)],
			"ocr", Map("layout", "sparse")), (R, Reason) => (Result := R))
		Sent := JsonParse(FileRead(Queue . "\00000002.req.json", "UTF-8"))
		AssertTrue(Sent.Has("ocr"), "a text target asks for OCR")
		FileAppend('{"ok":true,"width":100,"height":50,"scale":1,"frame":{"x":0,"y":0,"width":100,"height":50},'
			. '"hits":[],"refused":{},"words":[{"text":"Allow","x":10,"y":20,"width":30,"height":12,"line":"1"},'
			. '{"text":"once","x":45,"y":20,"width":25,"height":12,"line":"1"}]}', Queue . "\00000002.res.json",
			"UTF-8-RAW")
		_ScreenVisionPoll()
		AssertTrue(IsObject(Result), "the scan answered")
		AssertEqual(1, Result["text_hits"].Length, "the caption is found")
		AssertEqual(60, Result["text_hits"][1]["width"], "the caption spans both words")
	} finally _TSV_Finish()
}
Test("screen vision: refusals and scans reach their callbacks (screen-vision-queue)", _TSV_RefusalAndScan)

_TSV_SingleOwner() {
	_TSV_Start()
	try {
		AssertThrows(() => ScreenVisionInit(), "a second start is refused")
		Late := ""
		ScreenVisionCaptureWindow(3, (Image, Reason) => (Late := Reason))
		ScreenVisionStop()
		AssertEqual("capture_unavailable", Late, "a stop answers every pending call")
	} finally _TSV_Finish()
}
Test("screen vision: one owner, and a stop answers pending calls (screen-vision-queue)", _TSV_SingleOwner)

; A 25 ms poll left armed after the worker went idle would cost the driver CPU
; for its whole life once one auto-click session had run.
_TSV_PollRunsOnlyWhileACallWaits() {
	ScreenVisionStop()
	ScreenVisionOwner.spawn_fn := _TSV_Spawn
	try {
		AssertTrue(ScreenVisionInit(), "the worker starts")
		AssertTrue(ScreenVisionOwner.polling, "the poll watches for readiness")
		Queue := ScreenVisionOwner.queue
		FileAppend('{"ok":true,"capture":{"ok":true},"ocr":{"ok":true}}', Queue . "\ready.json", "UTF-8-RAW")
		_ScreenVisionPoll()
		AssertFalse(ScreenVisionOwner.polling, "a ready worker with no call is not polled")
		Answered := 0
		ScreenVisionCaptureWindow(9, (Image, Reason) => (Answered += 1))
		AssertTrue(ScreenVisionOwner.polling, "a queued call arms the poll")
		_ScreenVisionPoll()
		AssertTrue(ScreenVisionOwner.polling, "the poll stays armed while the answer is owed")
		FileAppend('{"ok":false,"reason":"no_foreground_window"}', Queue . "\00000001.res.json", "UTF-8-RAW")
		_ScreenVisionPoll()
		AssertEqual(1, Answered, "the call is answered")
		AssertFalse(ScreenVisionOwner.polling, "the last answer disarms the poll")
		ScreenVisionStop()
		AssertFalse(ScreenVisionOwner.polling, "a stop leaves no poll")
	} finally _TSV_Finish()
}
Test("screen vision: the queue is polled only while a call waits (screen-vision-idle-poll)",
	_TSV_PollRunsOnlyWhileACallWaits)
