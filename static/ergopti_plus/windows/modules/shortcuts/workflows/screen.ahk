; modules/shortcuts/workflows/screen.ahk

; ==============================================================================
; MODULE: Workflow Screen Steps (Windows)
; DESCRIPTION:
; The AutoHotkey port of _shared/shortcuts/engine/workflows/screen.lua: the
; screen steps of a user workflow (wait_for, click_target, capture, ocr and the
; « visible » condition) on top of the screen vision service
; (platform/vision/screen_vision.ahk, docs/design/screen-vision.md). This
; module owns what the steps mean; the vision ports only say how to capture,
; turn an embedded image into a template, match, read and click. It is the
; `screen` port of the workflow effects.
;
; FEATURES & RATIONALE:
; 1. One meaning on every driver: a target is looked for in the front window
;    (as the auto-clicker scans it), an image target is the workflow's
;    embedded PNG, a text target is the shared fuzzy text match of the OCR
;    words, and a hit is clicked at the shared matcher's click point.
; 2. wait_for polls every [workflows] wait_for_poll_ms until its timeout_ms and
;    then fails with image_not_found or text_not_found; the runner's deadline
;    stays the outer bound.
; 3. A refusal of the service is mapped by the step catalogue's screen_reasons
;    to a run reason with its own translated notice, never « not found ».
; 4. Cancel-safe: a late answer after a cancel (Escape, deadline) is dropped.
; ==============================================================================

#Requires AutoHotkey v2.0

; The ports a screen adapter supplies (screen.lua M.new).
global WORKFLOW_SCREEN_PORTS := ["window_image", "capture", "template", "match", "recognize", "save", "click",
	"click_point", "find_text", "after", "now_ms"]

/**
 * The run reason of a refusal of the service.
 * @param {Map} Catalogue The step catalogue (screen_reasons, screen_reason_other).
 * @param {String} Reason A screen vision reason.
 * @returns {String}
 */
WorkflowScreenRunReason(Catalogue, Reason) {
	return Catalogue["screen_reasons"].Get(Reason, Catalogue["screen_reason_other"])
}

/**
 * The text of recognised words: the words of one line joined by a space, the
 * lines by a newline, in the service's reading order.
 * @param {Array} Words Maps text, line.
 * @returns {String}
 */
WorkflowScreenWordsText(Words) {
	Lines := "", Current := "", Line := "", Started := false
	for Word in Words {
		if Started && Word["line"] != Line {
			Lines .= (Lines == "" ? "" : "`n") . Current
			Current := ""
		}
		Line := Word["line"]
		Current .= (Current == "" ? "" : " ") . Word["text"]
		Started := true
	}
	if Current != ""
		Lines .= (Lines == "" ? "" : "`n") . Current
	return Lines
}

/**
 * A one-shot answer that a cancel silences, with the pending timer the cancel
 * also stops.
 */
class WorkflowScreenAnswer {
	__New(Done) {
		this.Done := Done
		this.Open := true
		this.Pending := 0
	}

	Answer(Result) {
		if !this.Open
			return
		this.Open := false
		this.Done.Call(Result)
	}

	Cancel(*) {
		this.Open := false
		Pending := this.Pending
		this.Pending := 0
		if HasMethod(Pending, "Call")
			Pending.Call()
	}
}

/**
 * The screen port of the workflow effects.
 */
class WorkflowScreen {
	; The ids the matcher and the text match report a step's single target under.
	static TextTarget := "workflow_text"
	static ImageTarget := "workflow_image"

	/**
	 * @param {Map} Vision The WORKFLOW_SCREEN_PORTS callables: window_image(Done),
	 *   capture(Mode, Done), template(Bytes, Key, Done), match(Image, Templates,
	 *   Done(Hits, Refused)), recognize(Capture, Done), save(Capture, Done),
	 *   click(X, Y, Button, Done(Ok)), click_point(Frame, Scale, Hit) -> [X, Y],
	 *   find_text(Words, Targets) -> Hits, after(Ms, Fn) -> cancel, now_ms().
	 *   A Done(Value, Reason) gets 0 and a screen vision reason on a refusal.
	 * @param {Map} Options catalogue, poll_ms, text_max_distance, threshold.
	 */
	__New(Vision, Options) {
		global WORKFLOW_SCREEN_PORTS
		_WorkflowRequirePorts(Vision, WORKFLOW_SCREEN_PORTS, "Workflow screen steps")
		if !(Options is Map) || !(Options.Get("catalogue", 0) is Map)
			throw ValueError("Workflow screen steps need the catalogue.", -1)
		if !(Options.Get("poll_ms", 0) is Number) || Options["poll_ms"] <= 0
			throw ValueError("Workflow screen steps need a poll interval.", -1)
		this.Vision := Vision
		this.Options := Options
		this.Catalogue := Options["catalogue"]
	}

	Refused(Reason) {
		return Map("ok", false, "reason", WorkflowScreenRunReason(this.Catalogue, Reason))
	}

	NotFound(Target) {
		return Map("ok", false, "reason", Target["type"] == "image" ? "image_not_found" : "text_not_found")
	}

	; Done(Point, Reason): Point a Map x, y when found, "" when not, 0 with a
	; reason on a refusal.
	Point(Frame, Scale, Hit) {
		XY := this.Vision["click_point"].Call(Frame, Scale, Hit)
		return Map("x", XY[1], "y", XY[2])
	}

	; Looks for a target once in the front window.
	Find(Target, Workflow, Guard, Done) {
		this.Vision["window_image"].Call(ObjBindMethod(this, "FindIn", Target, Workflow, Guard, Done))
	}

	FindIn(Target, Workflow, Guard, Done, Image, Reason := "") {
		if !Guard.Open
			return
		if !IsObject(Image)
			return Done.Call(0, Reason)
		if Target["type"] == "image" {
			Images := Workflow.Get("images", Map())
			Data := (Images is Map) ? Images.Get(Target["image"], "") : ""
			if !(Data is String) || Data == ""
				throw ValueError("A validated workflow names only its own images.", -1)
			Bytes := CryptoBase64Decode(Data)
			if Bytes.Size == 0
				return Done.Call(0, "template_unreadable")
			this.Vision["template"].Call(Bytes, Workflow["id"] . "/" . Target["image"],
				ObjBindMethod(this, "MatchIn", Image, Guard, Done))
			return
		}
		this.Vision["recognize"].Call(Map("image", Image, "layout", "sparse"),
			ObjBindMethod(this, "ReadIn", Target, Image, Guard, Done))
	}

	MatchIn(Image, Guard, Done, Template, Reason := "") {
		if !Guard.Open
			return
		if !IsObject(Template)
			return Done.Call(0, Reason)
		Template["id"] := WorkflowScreen.ImageTarget
		if !Template.Has("threshold")
			Template["threshold"] := this.Options["threshold"]
		this.Vision["match"].Call(Image, [Template], ObjBindMethod(this, "Matched", Image, Guard, Done))
	}

	Matched(Image, Guard, Done, Hits, Refusals := 0) {
		if !Guard.Open
			return
		if (Hits is Array) && Hits.Length > 0
			return Done.Call(this.Point(Image["frame"], Image["scale"], Hits[1]))
		if (Refusals is Map) && Refusals.Has(WorkflowScreen.ImageTarget)
			return Done.Call(0, Refusals[WorkflowScreen.ImageTarget])
		Done.Call("")
	}

	ReadIn(Target, Image, Guard, Done, Words, Reason := "") {
		if !Guard.Open
			return
		if !(Words is Array)
			return Done.Call(0, Reason)
		Hits := this.Vision["find_text"].Call(Words, [Map("id", WorkflowScreen.TextTarget,
			"variants", [Target["text"]], "max_distance", this.Options["text_max_distance"])])
		if !(Hits is Array) || Hits.Length == 0
			return Done.Call("")
		Done.Call(this.Point(Image["frame"], Image["scale"], Hits[1]))
	}

	; « If visible »: one look, the answer as the condition's value.
	visible(Effect, Done, Workflow) {
		Guard := WorkflowScreenAnswer(Done)
		this.Find(Effect["condition"]["target"], Workflow, Guard, (Point, Reason := "") => IsObject(Point)
			? Guard.Answer(Map("ok", true, "value", true))
			: Point == "" ? Guard.Answer(Map("ok", true, "value", false)) : Guard.Answer(this.Refused(Reason)))
		return ObjBindMethod(Guard, "Cancel")
	}

	; Waits until the target shows, polling until timeout_ms.
	wait_for(Effect, Done, Workflow) {
		Guard := WorkflowScreenAnswer(Done)
		Deadline := this.Vision["now_ms"].Call() + Effect["timeout_ms"]
		this.Look(Effect["target"], Workflow, Guard, Deadline)
		return ObjBindMethod(Guard, "Cancel")
	}

	Look(Target, Workflow, Guard, Deadline) {
		this.Find(Target, Workflow, Guard, ObjBindMethod(this, "Looked", Target, Workflow, Guard, Deadline))
	}

	Looked(Target, Workflow, Guard, Deadline, Point, Reason := "") {
		if IsObject(Point)
			return Guard.Answer(Map("ok", true))
		if Point !== ""
			return Guard.Answer(this.Refused(Reason))
		if this.Vision["now_ms"].Call() + this.Options["poll_ms"] > Deadline
			return Guard.Answer(this.NotFound(Target))
		Guard.Pending := this.Vision["after"].Call(this.Options["poll_ms"],
			() => Guard.Open ? this.Look(Target, Workflow, Guard, Deadline) : 0)
	}

	; Clicks the target where it shows now.
	click_target(Effect, Done, Workflow) {
		Guard := WorkflowScreenAnswer(Done)
		Target := Effect["target"]
		Button := Effect.Get("button", "left")
		this.Find(Target, Workflow, Guard, (Point, Reason := "") => IsObject(Point)
			? this.Vision["click"].Call(Point["x"], Point["y"], Button,
				(Ok, *) => Guard.Answer(Ok ? Map("ok", true) : Map("ok", false, "reason", "step_failed")))
			: Guard.Answer(Point == "" ? this.NotFound(Target) : this.Refused(Reason)))
		return ObjBindMethod(Guard, "Cancel")
	}

	; Captures an area; its PNG file's path is the step's value.
	capture(Effect, Done, Workflow := 0) {
		Guard := WorkflowScreenAnswer(Done)
		this.Vision["capture"].Call(Effect["mode"], ObjBindMethod(this, "Captured", Guard, false))
		return ObjBindMethod(Guard, "Cancel")
	}

	; Reads the text of an area; the text is the step's value.
	ocr(Effect, Done, Workflow := 0) {
		Guard := WorkflowScreenAnswer(Done)
		this.Vision["capture"].Call(Effect["mode"], ObjBindMethod(this, "Captured", Guard, true))
		return ObjBindMethod(Guard, "Cancel")
	}

	Captured(Guard, Read, Capture, Reason := "") {
		if !Guard.Open
			return
		if !IsObject(Capture)
			return Guard.Answer(this.Refused(Reason))
		if Read
			return this.Vision["recognize"].Call(Capture, (Words, Why := "") => !Guard.Open ? 0
				: (Words is Array) ? Guard.Answer(Map("ok", true, "value", WorkflowScreenWordsText(Words)))
				: Guard.Answer(this.Refused(Why)))
		this.Vision["save"].Call(Capture, (Path, Why := "") => !Guard.Open ? 0
			: (Path is String) && Path != "" ? Guard.Answer(Map("ok", true, "value", Path)) : Guard.Answer(this.Refused(Why)))
	}
}
