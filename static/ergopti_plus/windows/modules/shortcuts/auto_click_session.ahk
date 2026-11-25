; modules/shortcuts/auto_click_session.ahk

; ==============================================================================
; MODULE: Auto-Click Session (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/shortcuts/engine/keep_awake/auto_click_session.lua: one run of the
; anti-sleep auto-clicker. Every tick asks the policy whether the foreground
; window may be looked at, scans it through the screen vision service, and
; clicks at most one target the policy admits.
;
; FEATURES & RATIONALE:
; 1. Ports only (a Map of functions), so the decision is the shared one and
;    is tested without a screen.
; 2. One scan in flight; a stopped session ignores a late answer; the state
;    and the foreground are asked again after the scan, before a click.
; 3. Image targets first, then text targets; the clicked target waits its
;    cooldown. A refusal is logged once when it starts.
;
; Pinned by _shared/tests/corpus/keep_awake/auto_click_session_vectors.json,
; which tests/unit/modules/shortcuts/test_auto_click_session.ahk replays.
; ==============================================================================

#Requires AutoHotkey v2.0

class AutoClickSession {
	__New(Ports, Plan, Settings) {
		for Name in ["foreground", "state", "scan", "click", "now_ms", "log"] {
			if !Ports.Has(Name)
				throw ValueError("An auto-click session needs the port " . Name . ".")
		}
		if !Settings.Has("cooldown_ms")
			throw ValueError("An auto-click session needs its cooldown.")
		this.Ports := Ports, this.Plan := Plan, this.Settings := Settings
		this.Generation := 1, this.Busy := false, this.Clicks := 0, this.LastReason := ""
		this.LastClicks := Map()
	}

	NoteRefusal(Reason) {
		if Reason != this.LastReason {
			this.LastReason := Reason
			this.Ports["log"].Call("debug", "Auto-click waits: reason={1}.", Reason)
		}
	}

	_State(Foreground, State) {
		return Map("app_id", IsObject(Foreground) && Foreground.Has("app_id") ? Foreground["app_id"] : "",
			"has_window", IsObject(Foreground) && Foreground.Has("window") && Foreground["window"] != "",
			"allowed_apps", this.Plan["allowed_apps"],
			"locked", State.Has("locked") ? State["locked"] : 0,
			"paused", State.Has("paused") ? State["paused"] : 0,
			"secure_field", State.Has("secure_field") ? State["secure_field"] : 0)
	}

	TryClick(Base, Result, Hits) {
		Image := Result["image"]
		for Hit in Hits {
			State := Map()
			for Key, Value in Base
				State[Key] := Value
			State["window"] := Map("width", Image["width"], "height", Image["height"])
			State["match"] := Map("x", Hit["x"], "y", Hit["y"], "width", Hit["width"], "height", Hit["height"])
			State["image_id"] := Hit["id"]
			State["last_clicks"] := this.LastClicks
			State["now_ms"] := this.Ports["now_ms"].Call()
			State["cooldown_ms"] := this.Settings["cooldown_ms"]
			if AutoClickMayClick(State, &Reason) {
				Frame := Image["frame"]
				AutoClickClickPoint(Frame["x"], Frame["y"], Image["scale"],
					{ X: Hit["x"], Y: Hit["y"], Width: Hit["width"], Height: Hit["height"] }, &X, &Y)
				if this.Ports["click"].Call(X, Y) {
					this.LastClicks[Hit["id"]] := State["now_ms"]
					this.Clicks += 1
					this.LastReason := ""
					this.Ports["log"].Call("info", "Auto-click on {1}: reason={2}.", Hit["id"], Reason)
					if this.Ports.Has("on_click")
						this.Ports["on_click"].Call(this.Clicks, Hit["id"])
					return true
				}
				this.Ports["log"].Call("warn", "Auto-click on {1} could not be sent.", Hit["id"])
				return false
			}
			this.NoteRefusal(Reason)
		}
		return false
	}

	Tick() {
		if this.Busy || !this.Plan["auto_click"]
			return
		Foreground := this.Ports["foreground"].Call()
		Base := this._State(Foreground, this.Ports["state"].Call())
		if !AutoClickMayCapture(Base, &Reason) {
			this.NoteRefusal(Reason)
			return
		}
		if this.Plan["templates"].Length = 0 && this.Plan["text_targets"].Length = 0
			return
		this.Busy := true
		Mine := this.Generation
		Request := Map("templates", this.Plan["templates"], "options", this.Settings["options"],
			"text_targets", this.Plan["text_targets"], "ocr", this.Settings["ocr"])
		this.Ports["scan"].Call(Foreground["window"], Request, ObjBindMethod(this, "_Answered", Mine, Foreground, Base))
	}

	_Answered(Mine, Foreground, Base, Result, ScanReason := "") {
		if Mine != this.Generation
			return
		this.Busy := false
		if !IsObject(Result) {
			this.NoteRefusal(ScanReason != "" ? ScanReason : "capture_unavailable")
			return
		}
		State := this.Ports["state"].Call()
		for Key in ["locked", "paused", "secure_field"]
			Base[Key] := State.Has(Key) ? State[Key] : 0
		Still := this.Ports["foreground"].Call()
		if !IsObject(Still) || !Still.Has("window") || Still["window"] != Foreground["window"] {
			this.NoteRefusal("no_foreground_window")
			return
		}
		if !this.TryClick(Base, Result, Result.Has("hits") ? Result["hits"] : [])
			this.TryClick(Base, Result, Result.Has("text_hits") ? Result["text_hits"] : [])
	}

	Stop() {
		this.Generation += 1
		this.Busy := false
	}
}
