; tests/unit/modules/keystats/metrics/test_metrics_navigation_visibility_owner.ahk

; ==============================================================================
; MODULE: Metrics Navigation Visibility Owner Tests
; DESCRIPTION:
; A controlled Source getter retires the real session through KLWV_Hide. The
; exact controller and WebView are retained, then optionally reused through
; KLWV_TakeWarmHost. Real private HWNDs prove Hide's prerequisite; the controller
; setter is passive, so this does not claim observed native COM reentrancy or
; actual WebView pixels. Deferred first-paint delivery is only recorded.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MNV_Controller {
	__New() {
		this.Visible := false, this.Writes := [], this.Closed := 0
	}
	IsVisible {
		get => this.Visible
		set {
			this.Writes.Push(Value)
			this.Visible := Value
		}
	}
	Close() {
		this.Closed += 1
	}
}

class _MNV_View {
	__New(World) {
		this.World := World
	}
	Source {
		get {
			World := this.World
			World.Reads += 1
			if !World.Fired && (InStr(World.Mode, "hide") || InStr(World.Mode, "reuse")) {
				World.Fired := true
				_MNV_RetireAtSource(World)
			}
			return World.Mode == "nav-wrong-source" ? World.Url . "&foreign=1" : World.Url
		}
	}
}

_MNV_RecordTimer(World, Callback, Period) {
	World.Timers.Push(Map("callback", Callback, "period", Period))
	return true
}

_MNV_RetireAtSource(World) {
	AssertEqual(1, KLWV_Hide("typing", World.Gui), "the real public Hide must retire this session")
	AssertFalse(KLWV.windows.Has("typing"), "Hide must revoke the actual live lookup before Source returns")
	AssertTrue(KLWV.warm_hosts["typing"]["controller"] == World.Controller)
	AssertTrue(KLWV.warm_hosts["typing"]["webview"] == World.View)
	AssertFalse(World.Controller.IsVisible, "Hide must really set the retained controller invisible first")
	AssertEqual(1, World.Controller.Writes.Length)
	AssertFalse(World.Controller.Writes[1])
	AssertFalse(DllCall("IsWindowVisible", "Ptr", World.Gui.Hwnd, "Int"),
		"the genuine private host HWND must be hidden at the controlled getter boundary")
	World.HiddenObserved := true
	if InStr(World.Mode, "reuse") {
		Retained := KLWV_TakeWarmHost("typing", World.Key)
		AssertTrue(Retained is Map, "the real native-host cache must return the admitted live HWND")
		AssertTrue(Retained["controller"] == World.Controller && Retained["webview"] == World.View)
		AssertFalse(KLWV.warm_hosts.Has("typing"))
		World.Gui.Show("NoActivate w120 h40")
		AssertTrue(DllCall("IsWindowVisible", "Ptr", World.Gui.Hwnd, "Int"))
		AssertFalse(World.Controller.IsVisible, "the reused host starts with its controller still hidden")
		NextEpoch := World.Mode == "nav-same-epoch-reuse" ? World.Epoch : ++KLWV.epoch
		; Only native Open's final page publication is controlled. Hide and cache
		; extraction above are genuine; full WebView creation is not exercised.
		World.NextEntry := _MNV_Entry(World, NextEpoch, World.Url . "&document=next")
		KLWV.windows["typing"] := World.NextEntry
	}
}

_MNV_Entry(World, Epoch, Url) {
	return Map("which", "typing", "epoch", Epoch, "webview", World.View,
		"controller", World.Controller, "gui", World.Gui, "udir", "", "reuse_key", World.Key,
		"navigation_url", Url, "open_started", BootClockWallMs(), "first_paint_done", true)
}

_MNV_Check(World, Result) {
	_TestPrint("# metrics-navigation-visibility mode=" . World.Mode . " reads=" . World.Reads
		. " hidden_observed=" . World.HiddenObserved . " visible=" . World.Controller.IsVisible
		. " writes=" . World.Controller.Writes.Length . " timers=" . World.Timers.Length
		. " successor=" . IsObject(World.NextEntry))
	AssertTrue(WMHandleExists(World.Gui.Hwnd), "the fixture must retain its exact private HWND")
	AssertTrue(WMHandleExists(World.Foreign.Hwnd), "a foreign private HWND must remain untouched")
	AssertEqual(0, World.Controller.Closed, "real Hide must retain the live controller, not fall back to Close")
	if World.Fired {
		AssertEqual(1, World.Reads, "the controlled Source boundary must execute exactly once")
		AssertTrue(World.HiddenObserved, "the visibility refusal must follow a genuinely completed Hide")
		if InStr(World.Mode, "reuse") {
			AssertTrue(KLWV.windows["typing"] == World.NextEntry)
			AssertTrue(World.NextEntry["controller"] == World.Controller
				&& World.NextEntry["webview"] == World.View, "the controller and WebView must actually be shared")
		} else {
			AssertFalse(KLWV.windows.Has("typing"))
			AssertTrue(KLWV.warm_hosts["typing"]["controller"] == World.Controller)
		}
		AssertFalse(World.Controller.IsVisible, "a retired Source callback must not reveal its retained controller")
		AssertFalse(Result, "the retired callback must not report a new paint admission")
		AssertEqual(1, World.Controller.Writes.Length, "only the genuine Hide may write visibility after retirement")
		AssertEqual(0, World.Timers.Length, "retired navigation cannot publish a new first-paint callback")
	} else if World.Mode == "nav-current" || World.Mode == "delayed-current" {
		AssertEqual(1, World.Reads)
		AssertTrue(KLWV.windows["typing"] == World.Entry)
		AssertTrue(World.Controller.IsVisible, "a current matching document must still reveal its controller")
		AssertEqual(1, World.Controller.Writes.Length)
		AssertTrue(World.Controller.Writes[1])
		if World.Mode == "nav-current" {
			AssertTrue(Result)
			AssertEqual(1, World.Timers.Length)
			AssertEqual(-1, World.Timers[1]["period"])
		} else
			AssertEqual(0, World.Timers.Length, "an already painted current document needs no new paint")
	} else {
		AssertEqual(World.Mode == "nav-stale-epoch" ? 0 : 1, World.Reads)
		AssertFalse(Result)
		AssertTrue(KLWV.windows["typing"] == World.Entry)
		AssertFalse(World.Controller.IsVisible)
		AssertEqual(0, World.Controller.Writes.Length)
		AssertEqual(0, World.Timers.Length)
	}
}

_MNV_Case(Mode) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	PreviousCritical := Critical("On")
	try {
		Saved := {Windows: KLWV.windows, Warm: KLWV.warm_hosts, Retiring: KLWV.retiring,
			Epoch: KLWV.epoch, Timer: KLWV.first_paint_timer_fn, Logger: _TLOG_CaptureLoggerState(),
			Sink: _LOGGER_TEST_SINK, Repeat: _LOGGER_REPEAT_ENABLED, Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN,
			Debug: _LOGGER_DEBUG_ENABLED, Info: _LOGGER_INFO_ENABLED, Warn: _LOGGER_WARN_ENABLED, Error: _LOGGER_ERROR_ENABLED}
		World := {Mode: Mode, Epoch: 91, Key: "private-navigation-owner", Url: "https://fixture.invalid/?epoch=91",
			Reads: 0, Fired: false, HiddenObserved: false, Timers: [], NextEntry: 0,
			Controller: _MNV_Controller(), Gui: 0, Foreign: 0, View: 0}
		Primary := 0, Cleanup := 0
		try {
			_ResetLogger()
			LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
			_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
			KLWV.windows := Map(), KLWV.warm_hosts := Map(), KLWV.retiring := Map(), KLWV.epoch := World.Epoch
			KLWV.first_paint_timer_fn := _MNV_RecordTimer.Bind(World)
			World.Gui := Gui("+ToolWindow -Caption", "Ergopti private navigation owner")
			World.Foreign := Gui("+ToolWindow -Caption", "Ergopti foreign navigation control")
			World.Gui.Show("NoActivate w120 h40"), World.Foreign.Show("Hide w100 h30")
			AssertTrue(DllCall("IsWindowVisible", "Ptr", World.Gui.Hwnd, "Int"))
			AssertTrue(WMHandleExists(World.Foreign.Hwnd))
			World.View := _MNV_View(World)
			World.Entry := _MNV_Entry(World, World.Epoch, World.Url)
			KLWV.windows["typing"] := World.Entry
			if InStr(Mode, "hide") || InStr(Mode, "reuse")
				World.Controller.Visible := true
			Result := InStr(Mode, "delayed")
				? KLWV_DelayedFirstPush("typing", World.Epoch)
				: KLWV_OnNavigationCompleted("typing", Mode == "nav-stale-epoch" ? World.Epoch - 1 : World.Epoch)
			_MNV_Check(World, Result)
		} catch as Failure {
			Primary := Failure
		} finally {
			try {
				; Revoke all private lookup authority before the exact HWND cleanup.
				KLWV.windows := Map(), KLWV.warm_hosts := Map(), KLWV.retiring := Map()
				try {
					if IsObject(World.Gui)
						World.Gui.Destroy()
				} finally {
					if IsObject(World.Foreign)
						World.Foreign.Destroy()
				}
			} catch as Failure {
				Cleanup := Failure
			} finally {
				KLWV.windows := Saved.Windows, KLWV.warm_hosts := Saved.Warm, KLWV.retiring := Saved.Retiring
				KLWV.epoch := Saved.Epoch, KLWV.first_paint_timer_fn := Saved.Timer
				_TLOG_RestoreLoggerState(Saved.Logger)
				_LOGGER_TEST_SINK := Saved.Sink, _LOGGER_REPEAT_ENABLED := Saved.Repeat
				_LOGGER_CLOCK_FN := Saved.Clock, _LOGGER_STAMP_FN := Saved.Stamp
				_LOGGER_DEBUG_ENABLED := Saved.Debug, _LOGGER_INFO_ENABLED := Saved.Info
				_LOGGER_WARN_ENABLED := Saved.Warn, _LOGGER_ERROR_ENABLED := Saved.Error
				if IsObject(World.View)
					World.View.World := 0
				World.Timers.Length := 0
			}
		}
		if IsObject(Primary)
			throw Primary
		if IsObject(Cleanup)
			throw Cleanup
	} finally Critical(PreviousCritical)
}

for _MNV_Mode in ["nav-current", "nav-hide", "nav-reuse", "nav-same-epoch-reuse", "nav-wrong-source",
	"nav-stale-epoch", "delayed-hide", "delayed-current"]
	Test("Metrics navigation visibility: " . _MNV_Mode . " retains the admitted host (metrics-navigation-visibility-owner)",
		_MNV_Case.Bind(_MNV_Mode))
