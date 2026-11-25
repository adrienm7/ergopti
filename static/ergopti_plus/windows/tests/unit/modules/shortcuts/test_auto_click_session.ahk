; tests/unit/modules/shortcuts/test_auto_click_session.ahk

; ==============================================================================
; MODULE: Auto-Click Session (Windows port)
; DESCRIPTION:
; Replays _shared/tests/corpus/keep_awake/auto_click_session_vectors.json,
; which the macOS and Linux suites replay through
; _shared/shortcuts/engine/auto_click_session.lua, through
; modules/shortcuts/auto_click_session.ahk.
;
; ROOT CAUSE ENCODED:
; A port that scanned a disallowed app, clicked after the focus moved during a
; scan, piled scans up or clicked one prompt twice inside its cooldown would
; click what macOS and Linux never click.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TACS_Run {
	static Tick := 0, Clicks := [], Scans := 0, Pending := "", Foreground := "", Vector := ""
}

_TACS_State(*) {
	Tick := _TACS_Run.Vector["ticks"][_TACS_Run.Tick]
	return Tick.Has("state") && Tick["state"] != JSON_NULL ? Tick["state"] : Map()
}

_TACS_Foreground(*) {
	F := _TACS_Run.Foreground
	return (F == JSON_NULL || !IsObject(F)) ? "" : F
}

_TACS_Scan(Window, Request, Callback) {
	_TACS_Run.Scans += 1
	_TACS_Run.Pending := Callback
}

_TACS_Click(X, Y) {
	_TACS_Run.Clicks.Push(X . "," . Y)
	return true
}

_TACS_Now(*) {
	return _TACS_Run.Vector["ticks"][_TACS_Run.Tick]["now_ms"]
}

_TACS_Vector(Corpus, Vector) {
	_TACS_Run.Tick := 0, _TACS_Run.Clicks := [], _TACS_Run.Scans := 0, _TACS_Run.Pending := ""
	_TACS_Run.Vector := Vector
	Ports := Map("foreground", _TACS_Foreground, "state", _TACS_State, "scan", _TACS_Scan, "click", _TACS_Click,
		"now_ms", _TACS_Now, "log", (*) => 0)
	Plan := Map("allowed_apps", Corpus["plan"]["allowed_apps"], "auto_click", Corpus["plan"]["auto_click"],
		"templates", [Map("id", "t")], "text_targets", [Map("id", "copilot")])
	Session := AutoClickSession(Ports, Plan, Map("cooldown_ms", Corpus["cooldown_ms"], "options", Map(), "ocr", Map()))
	for Index, Tick in Vector["ticks"] {
		_TACS_Run.Tick := Index
		_TACS_Run.Foreground := Tick["foreground"]
		Before := _TACS_Run.Pending
		_TACS_Run.Pending := ""
		Session.Tick()
		Callback := IsObject(_TACS_Run.Pending) ? _TACS_Run.Pending : Before
		if Tick.Has("after_scan_foreground")
			_TACS_Run.Foreground := Tick["after_scan_foreground"]
		Answer := Tick["answer"]
		if IsObject(Callback) && Answer != JSON_NULL {
			_TACS_Run.Pending := ""
			if Answer.Has("reason")
				Callback.Call(0, Answer["reason"])
			else
				Callback.Call(Answer)
		} else {
			_TACS_Run.Pending := Callback
		}
	}
	Expected := ""
	for Point in Vector["expect_clicks"]
		Expected .= (Expected = "" ? "" : ";") . Point[1] . "," . Point[2]
	Actual := ""
	for Click in _TACS_Run.Clicks
		Actual .= (Actual = "" ? "" : ";") . Click
	AssertEqual(Expected, Actual, Vector["id"] . " clicks")
	AssertEqual(Vector["expect_scans"], _TACS_Run.Scans, Vector["id"] . " scans")
	AssertEqual(Vector["expect_clicks"].Length, Session.Clicks, Vector["id"] . " count")
}

_TACS_Vectors() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\keep_awake\auto_click_session_vectors.json", "UTF-8"))
	Checked := 0
	for Vector in Corpus["vectors"] {
		_TACS_Vector(Corpus, Vector)
		Checked += 1
	}
	AssertTrue(Checked >= 7, "expected the session vectors, found " . Checked)
}
Test("auto-click session: the port replays every corpus tick (auto-click-session-vectors)", _TACS_Vectors)
