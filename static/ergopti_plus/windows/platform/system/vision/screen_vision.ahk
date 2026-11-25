; platform/system/vision/screen_vision.ahk

; ==============================================================================
; MODULE: Screen Vision Service (Windows)
; DESCRIPTION:
; The Windows implementation of the screen vision service
; (docs/design/screen-vision.md): capture a window or a region, find library
; images in it, read its text with Windows.Media.Ocr, find text targets among
; the words, and import an image of any format Windows decodes. The work runs
; in one long-lived PowerShell worker (vendor/ergopti_screen_vision_worker.ps1)
; that compiles the C# matcher and capture code once and keeps one OCR engine.
;
; FEATURES & RATIONALE:
; 1. One owner: ScreenVisionInit() starts the worker once and refuses a second
;    start; ScreenVisionStop() asks it to leave and retires the child.
; 2. A folder queue (<id>.req.json in, <id>.res.json out, each renamed into
;    place), polled on a timer from the timings registry: ShellRunner gives no
;    stdin stream to a running child, and a file protocol cannot tear. The
;    timer runs only while the worker starts or a call waits for its answer:
;    an idle worker between auto-click sessions costs the driver no poller.
; 3. Every call answers once through its callback, Callback(Answer, Reason):
;    an answer Map, or 0 with a reason of the closed vocabulary. A request
;    past its deadline answers "ocr_timeout"; a dead worker answers
;    "capture_unavailable" to every pending call.
; 4. Text targets are matched here, through modules/shortcuts/text_target.ahk,
;    on the words the worker returns, as the Lua drivers do.
; ==============================================================================

#Requires AutoHotkey v2.0


class ScreenVisionOwner {
	static state := "stopped"
	static handle := 0
	static queue := ""
	static pending := Map()
	static counter := 0
	static ready := 0
	static started := 0
	static spawn_fn := 0
	static polling := false
}




; ===================================
; ===================================
; ======= 1/ JSON requests ==========
; ===================================
; ===================================

; Serialises a request: Map, Array, String, Integer, Float.
_ScreenVisionJson(Value) {
	if Value is Map {
		Parts := []
		for Key, Item in Value
			Parts.Push(JsonStringLiteral(String(Key)) . ":" . _ScreenVisionJson(Item))
		return "{" . _ScreenVisionJoin(Parts) . "}"
	}
	if Value is Array {
		Parts := []
		for Item in Value
			Parts.Push(_ScreenVisionJson(Item))
		return "[" . _ScreenVisionJoin(Parts) . "]"
	}
	if (Value is Integer) || (Value is Float)
		return String(Value)
	return JsonStringLiteral(String(Value))
}

_ScreenVisionJoin(Parts) {
	Out := ""
	for Index, Part in Parts
		Out .= (Index = 1 ? "" : ",") . Part
	return Out
}




; ===================================
; ===================================
; ======= 2/ Lifecycle ==============
; ===================================
; ===================================

; The vendor files the worker needs, the worker script first; a bundle without
; one of them refuses.
_ScreenVisionWorkerFiles() {
	global _VendorDir
	return [_VendorDir . "\ergopti_screen_vision_worker.ps1", _VendorDir . "\ergopti_screen_vision_matcher.cs",
		_VendorDir . "\ergopti_screen_vision_capture.cs"]
}

; Starts the worker once.
; @returns {Boolean} The worker was started (its readiness arrives later).
ScreenVisionInit() {
	if ScreenVisionOwner.state != "stopped"
		throw Error("The screen vision service is already initialised.")
	LoggerStart("ScreenVision", "Starting the screen vision worker.")
	Files := _ScreenVisionWorkerFiles()
	for Name in Files {
		if !FileExist(Name) {
			ScreenVisionOwner.state := "failed"
			ScreenVisionOwner.ready := Map("ok", false, "reason", "capture_unavailable")
			LoggerError("ScreenVision", "The bundle lacks {1}; screen vision is unavailable.", Name)
			return false
		}
	}
	Queue := EnvGet(AppDirsWindowsCacheBaseEnv()) . "\" . AppDirsWindowsCacheRelative() . "\vision\"
		. DllCall("GetCurrentProcessId")
	try {
		if DirExist(Queue)
			DirDelete(Queue, true)
		DirCreate(Queue)
	} catch as Err {
		ScreenVisionOwner.state := "failed"
		ScreenVisionOwner.ready := Map("ok", false, "reason", "capture_unavailable")
		LoggerError("ScreenVision", "The queue folder cannot be prepared: {1}.", Err.Message)
		return false
	}
	ScreenVisionOwner.queue := Queue
	ScreenVisionOwner.counter := 0
	ScreenVisionOwner.pending := Map()
	Spawn := IsObject(ScreenVisionOwner.spawn_fn) ? ScreenVisionOwner.spawn_fn : ShellRunner_SpawnTreeOwned
	Args := ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File",
		Files[1], "-QueueDir", Queue,
		"-ParentPid", String(DllCall("GetCurrentProcessId")),
		"-PollMs", String(TimingsGet("screen_vision", "worker_poll_ms"))]
	try {
		Handle := Spawn.Call(ShellRunner_WinPsPath(), Args, _ScreenVisionWorkerExited)
		Started := IsObject(Handle) && Handle.start() == true
	} catch as Err {
		Started := false
		LoggerError("ScreenVision", "The worker could not be started: {1}.", Err.Message)
	}
	if !Started {
		ScreenVisionOwner.state := "failed"
		ScreenVisionOwner.ready := Map("ok", false, "reason", "capture_unavailable")
		LoggerError("ScreenVision", "The screen vision worker refused to start.")
		return false
	}
	ScreenVisionOwner.handle := Handle
	ScreenVisionOwner.state := "starting"
	ScreenVisionOwner.started := A_TickCount
	_ScreenVisionArmPoll(true)
	LoggerSuccess("ScreenVision", "Screen vision worker started; waiting for its readiness.")
	return true
}

; Stops the worker and answers every pending call; ScreenVisionInit may run again.
ScreenVisionStop() {
	if ScreenVisionOwner.state = "stopped"
		return
	_ScreenVisionArmPoll(false)
	if ScreenVisionOwner.queue != ""
		try FileAppend("", ScreenVisionOwner.queue . "\stop")
	if IsObject(ScreenVisionOwner.handle)
		try ScreenVisionOwner.handle.requestTerminate()
	_ScreenVisionFailPending("capture_unavailable")
	ScreenVisionOwner.state := "stopped"
	ScreenVisionOwner.handle := 0
	ScreenVisionOwner.ready := 0
	LoggerInfo("ScreenVision", "Screen vision worker stopped.")
}

_ScreenVisionWorkerExited(ExitCode, *) {
	if ScreenVisionOwner.state = "stopped"
		return
	LoggerError("ScreenVision", "The screen vision worker exited ({1}).", ExitCode)
	ScreenVisionOwner.state := "failed"
	ScreenVisionOwner.handle := 0
	if !IsObject(ScreenVisionOwner.ready) || ScreenVisionOwner.ready["ok"]
		ScreenVisionOwner.ready := Map("ok", false, "reason", "capture_unavailable")
	_ScreenVisionFailPending("capture_unavailable")
}

_ScreenVisionFailPending(Reason) {
	Pending := ScreenVisionOwner.pending
	ScreenVisionOwner.pending := Map()
	for Id, Entry in Pending
		_ScreenVisionAnswer(Entry["callback"], 0, Reason)
}

_ScreenVisionAnswer(Callback, Answer, Reason) {
	try Callback.Call(Answer, Reason)
	catch as Err
		LoggerError("ScreenVision", "A screen vision callback raised: {1}.", Err.Message)
}

; Arms or disarms the queue poll; arming an armed poll keeps its period.
_ScreenVisionArmPoll(On) {
	if On && !ScreenVisionOwner.polling
		SetTimer(_ScreenVisionPoll, TimingsGet("screen_vision", "worker_poll_ms"))
	else if !On && ScreenVisionOwner.polling
		SetTimer(_ScreenVisionPoll, 0)
	ScreenVisionOwner.polling := On
}

; Reads the readiness file and every finished answer, and expires late requests.
; Disarms itself once the worker is past its start and no call waits.
_ScreenVisionPoll() {
	Queue := ScreenVisionOwner.queue
	if ScreenVisionOwner.state = "starting" {
		if FileExist(Queue . "\ready.json") {
			ScreenVisionOwner.ready := JsonParse(FileRead(Queue . "\ready.json", "UTF-8"))
			ScreenVisionOwner.state := ScreenVisionOwner.ready["ok"] ? "ready" : "failed"
			LoggerInfo("ScreenVision", "Screen vision worker ready: capture {1}, ocr {2}.",
				ScreenVisionOwner.ready["ok"] ? "ready" : ScreenVisionOwner.ready["reason"],
				_ScreenVisionPart("ocr")["ok"] ? "ready" : _ScreenVisionPart("ocr")["reason"])
			if ScreenVisionOwner.state = "failed"
				_ScreenVisionFailPending(ScreenVisionOwner.ready["reason"])
		} else if A_TickCount - ScreenVisionOwner.started > TimingsGet("screen_vision", "worker_start_timeout_ms") {
			LoggerError("ScreenVision", "The screen vision worker did not become ready in time.")
			ScreenVisionStop()
			ScreenVisionOwner.state := "failed"
			ScreenVisionOwner.ready := Map("ok", false, "reason", "capture_unavailable")
			return
		}
	}
	for Id, Entry in ScreenVisionOwner.pending.Clone() {
		Path := Queue . "\" . Id . ".res.json"
		if FileExist(Path) {
			Text := FileRead(Path, "UTF-8")
			try FileDelete(Path)
			ScreenVisionOwner.pending.Delete(Id)
			Answer := JsonParse(Text)
			if Answer["ok"]
				_ScreenVisionAnswer(Entry["callback"], Answer, "")
			else
				_ScreenVisionAnswer(Entry["callback"], 0, Answer["reason"])
		} else if A_TickCount > Entry["deadline"] {
			ScreenVisionOwner.pending.Delete(Id)
			try FileDelete(Queue . "\" . Id . ".req.json")
			LoggerError("ScreenVision", "A screen vision request ({1}) timed out.", Entry["op"])
			_ScreenVisionAnswer(Entry["callback"], 0, "ocr_timeout")
		}
	}
	if ScreenVisionOwner.state != "starting" && ScreenVisionOwner.pending.Count == 0
		_ScreenVisionArmPoll(false)
}

; Sends one request to the worker; Callback(Answer, Reason) runs once.
_ScreenVisionRequest(Request, Callback) {
	if ScreenVisionOwner.state = "stopped"
		throw Error("The screen vision service is not initialised.")
	if ScreenVisionOwner.state = "failed" {
		_ScreenVisionAnswer(Callback, 0, IsObject(ScreenVisionOwner.ready)
			? ScreenVisionOwner.ready["reason"] : "capture_unavailable")
		return
	}
	Id := Format("{:08}", ++ScreenVisionOwner.counter)
	Final := ScreenVisionOwner.queue . "\" . Id . ".req.json"
	try {
		FileAppend(_ScreenVisionJson(Request), Final . ".partial", "UTF-8-RAW")
		FileMove(Final . ".partial", Final, true)
	} catch as Err {
		LoggerError("ScreenVision", "A screen vision request could not be queued: {1}.", Err.Message)
		_ScreenVisionAnswer(Callback, 0, "capture_unavailable")
		return
	}
	ScreenVisionOwner.pending[Id] := Map("callback", Callback, "op", Request["op"],
		"deadline", A_TickCount + TimingsGet("screen_vision", "ocr_timeout_ms")
			+ (ScreenVisionOwner.state = "starting" ? TimingsGet("screen_vision", "worker_start_timeout_ms") : 0))
	_ScreenVisionArmPoll(true)
}




; ===================================
; ===================================
; ======= 3/ Public API =============
; ===================================
; ===================================

_ScreenVisionPart(Name) {
	Ready := ScreenVisionOwner.ready
	if !IsObject(Ready)
		return Map("ok", false, "reason", "capture_unavailable")
	if !Ready["ok"]
		return Map("ok", false, "reason", Ready["reason"])
	return Ready[Name]
}

; The private folder of the running service, where a caller leaves a PNG it
; hands to the service (a workflow's embedded image as a template).
ScreenVisionCacheDir() {
	if ScreenVisionOwner.state = "stopped" || ScreenVisionOwner.queue == ""
		throw Error("The screen vision service is not initialised.")
	return ScreenVisionOwner.queue
}

; What works now: Map capture, region, ocr, each Map ok, reason.
ScreenVisionAvailability() {
	if ScreenVisionOwner.state = "stopped"
		throw Error("The screen vision service is not initialised.")
	Capture := _ScreenVisionPart("capture")
	return Map("capture", Capture, "region", Capture, "ocr", _ScreenVisionPart("ocr"))
}

; Captures a window (its HWND) into a private PNG the image names.
ScreenVisionCaptureWindow(Hwnd, Callback) {
	_ScreenVisionRequest(Map("op", "capture", "window_id", Hwnd,
		"out_path", ScreenVisionOwner.queue . "\capture-" . (ScreenVisionOwner.counter + 1) . ".png"),
		_ScreenVisionImageAnswer.Bind(Callback))
}

; Captures a screen rectangle, in physical pixels, into a private PNG.
ScreenVisionCaptureRegion(Rect, Callback) {
	_ScreenVisionRequest(Map("op", "capture", "rect", Rect,
		"out_path", ScreenVisionOwner.queue . "\capture-" . (ScreenVisionOwner.counter + 1) . ".png"),
		_ScreenVisionImageAnswer.Bind(Callback))
}

_ScreenVisionImageAnswer(Callback, Answer, Reason) {
	if !IsObject(Answer)
		return Callback.Call(0, Reason)
	Callback.Call(Map("width", Answer["width"], "height", Answer["height"], "scale", Answer["scale"],
		"frame", Answer["frame"], "source", Answer["source"]), "")
}

; Finds library images (Maps id, path, threshold) in a captured image.
; Callback(Hits, Refused): Arrays and Maps; every template refused on a failure.
ScreenVisionMatch(Image, Templates, Options, Callback) {
	_ScreenVisionRequest(Map("op", "match", "source", Image["source"], "templates", Templates, "options", Options),
		_ScreenVisionMatchAnswer.Bind(Templates, Callback))
}

_ScreenVisionMatchAnswer(Templates, Callback, Answer, Reason) {
	if IsObject(Answer)
		return Callback.Call(Answer["hits"], Answer["refused"])
	Refused := Map()
	for Template in Templates
		Refused[Template["id"]] := Reason
	Callback.Call([], Refused)
}

; Recognises the text of a captured image. Callback(Words, Reason).
ScreenVisionRecognizeText(Image, Options, Callback) {
	ScreenVisionRecognizeFile(Image["source"], Options, Callback)
}

; Recognises the text of an image file. Callback(Words, Reason).
ScreenVisionRecognizeFile(Path, Options, Callback) {
	_ScreenVisionRequest(Map("op", "ocr", "source", Path, "ocr", Options), _ScreenVisionWordsAnswer.Bind(Callback))
}

_ScreenVisionWordsAnswer(Callback, Answer, Reason) {
	Callback.Call(IsObject(Answer) ? Answer["words"] : 0, Reason)
}

; Captures a window, matches its library images and reads its text targets in
; one worker request. Request: Map templates, options, text_targets, ocr.
; Callback(Result, Reason): Map image, hits, refused, text_hits, text_reason.
ScreenVisionScanWindow(Hwnd, Request, Callback) {
	Targets := Request.Has("text_targets") ? Request["text_targets"] : []
	Sent := Map("op", "scan", "window_id", Hwnd, "templates", Request["templates"], "options", Request["options"])
	if Targets.Length > 0
		Sent["ocr"] := Request["ocr"]
	_ScreenVisionRequest(Sent, _ScreenVisionScanAnswer.Bind(Targets, Callback))
}

_ScreenVisionScanAnswer(Targets, Callback, Answer, Reason) {
	if !IsObject(Answer)
		return Callback.Call(0, Reason)
	Words := Answer.Has("words") ? Answer["words"] : []
	Callback.Call(Map("image", Map("width", Answer["width"], "height", Answer["height"], "scale", Answer["scale"],
		"frame", Answer["frame"]), "hits", Answer["hits"], "refused", Answer["refused"],
		"text_hits", Targets.Length > 0 ? TextTargetFindAll(Words, Targets) : [],
		"text_reason", Answer.Has("text_reason") ? Answer["text_reason"] : ""), "")
}

; Converts an image of any format Windows decodes into a library PNG.
; Callback(Info, Reason): Map width, height.
ScreenVisionImport(Path, OutPath, Callback) {
	_ScreenVisionRequest(Map("op", "import", "path", Path, "out_path", OutPath), Callback)
}

; Finds text targets among recognised words, synchronously.
ScreenVisionFindText(Words, Targets) {
	return TextTargetFindAll(Words, Targets)
}
