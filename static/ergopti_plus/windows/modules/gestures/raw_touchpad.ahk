; modules/gestures/raw_touchpad.ahk

; ==============================================================================
; MODULE: Raw Touchpad Reader (Windows incremental swipes)
; DESCRIPTION:
; Owns the Precision Touchpad's raw HID digitizer reports (usage page 0x0D,
; usage 0x05) for the driver's lifetime, so an incremental swipe slot acts
; while the fingers move, as on macOS and Linux. The Precision Touchpad
; settings keep sending each finished swipe's shortcut (Ctrl+Win+Shift+F2..F10,
; modules/gestures/init.ahk); this owner decides which path acts.
;
; FEATURES & RATIONALE:
; 1. One owner: RawTouchpadStart registers the collection for the script's
;    window and RawTouchpadStop removes it, with paired lifecycle logs; a
;    second start is refused. Its state lives in one RawTouchpadOwner whose
;    natives (registration, clock, scheduling, dispatch) are injected, so the
;    whole chain runs on synthetic reports in the tests.
; 2. Lazy devices: a touchpad's descriptor is read on its first report and
;    forgotten on removal (WM_INPUT_DEVICE_CHANGE); a descriptor without a
;    physical size has no millimetres, so its incremental slots fire once
;    through the shortcut, as Linux does for a pad with no resolution.
; 3. Ownership of a swipe (GestureSwipeHandoff): a touch that acted while
;    moving owns its swipe, and the settings' shortcut for it is swallowed
;    before or after it arrives; a touch that did not act lets the shortcut
;    fire once. This is the Linux rule (the completed swipe fires only when
;    the tracker did not consume it), made independent of whether Windows
;    sends the shortcut before or after the last raw frame.
; 4. The WM_INPUT handler only parses and counts: actions run from a queue on
;    a fresh timer thread, so a slow action never holds raw input back, and
;    the queue is dropped on pause.
; 5. Only slots the system routes to Ergopti's shortcut step: an unmapped slot
;    also runs Windows' own gesture, so stepping it too would act twice.
; ==============================================================================

#Requires AutoHotkey v2.0

; The running owner, "" until RawTouchpadStart.
global _RawTouchpadOwner := ""

; The WM_INPUT receive buffer of the running owner.
global _RawTouchpadReceiver := ""

; The sensitivity choices, in millimetres: the copy of
; _shared/lua/gestures/sensitivity.lua's OPTIONS that
; test_gesture_incremental_rule.ahk pins to the shared menu corpus.
global GESTURE_SENSITIVITY_OPTIONS := [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 6.0,
	7.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0, 40.0, 50.0, 60.0]





; =======================================
; =======================================
; ======= 1/ Slot modes and steps =======
; =======================================
; =======================================

; A swipe slot's mode from the loaded configuration ([gestures.modes]).
; @param Slot {String} Gesture slot id.
; @returns {String} "x1", "incremental", or "" for a slot with no mode.
GestureSlotMode(Slot) {
	global Features
	if !IsSet(Features) || !Features.Has("gestures") || !Features["gestures"].Has("modes")
		return ""
	Modes := Features["gestures"]["modes"]
	if !(Modes is Map) || !Modes.Has(Slot)
		return ""
	Mode := Modes[Slot]
	if (Mode == "x1" || Mode == "incremental")
		return Mode
	_GestureReportInvalidSetting("modes", Slot, Mode)
	return ""
}

; A swipe slot's step in millimetres ([gestures.sensitivities]).
; @param Slot {String} Gesture slot id.
; @returns {Number|String} The step within the shared range, "" when absent or invalid.
GestureSlotSensitivity(Slot) {
	global Features
	if !IsSet(Features) || !Features.Has("gestures") || !Features["gestures"].Has("sensitivities")
		return ""
	Steps := Features["gestures"]["sensitivities"]
	if !(Steps is Map) || !Steps.Has(Slot)
		return ""
	Value := GestureCoerceSensitivity(Steps[Slot])
	if (Value = "")
		_GestureReportInvalidSetting("sensitivities", Slot, Steps[Slot])
	return Value
}

; Coerces a sensitivity within the shared range, or rejects it.
; @returns {Number|String} The step, "" when out of range or not a number.
GestureCoerceSensitivity(Value) {
	global GESTURE_SENSITIVITY_OPTIONS
	if !IsNumber(Value)
		return ""
	Parsed := Value + 0
	if (Parsed < GESTURE_SENSITIVITY_OPTIONS[1] || Parsed > GESTURE_SENSITIVITY_OPTIONS[GESTURE_SENSITIVITY_OPTIONS.Length])
		return ""
	return Parsed
}

; Logs an unusable mode or step once per slot: the slot then acts once per swipe.
_GestureReportInvalidSetting(Leaf, Slot, Value) {
	static Reported := Map()
	Key := Leaf . "." . Slot
	if Reported.Has(Key)
		return
	Reported[Key] := true
	LoggerError("gestures.incremental", "gestures.{1}.{2} = '{3}' is unusable; the slot acts once per swipe.",
		Leaf, Slot, Value)
}

; Persists one slot's mode, as Linux's set_mode and macOS's commit do.
; @param Slot {String} A swipe slot with a mode.
; @param Mode {String} "x1" or "incremental".
; @returns {Boolean} Whether config.toml and the live configuration took it.
GestureSetSlotMode(Slot, Mode, WriterFn := 0, NotifyFn := 0) {
	global Features
	if (GestureSlotMode(Slot) = "" || !(Mode == "x1" || Mode == "incremental")) {
		LoggerWarn("gestures.incremental", "Refusing gesture mode '{1}' for '{2}'.", Mode, Slot)
		return false
	}
	if !WriteFeatureV2(Features, ConfigKey.GESTURES_MODES . "." . Slot, Mode, "", WriterFn, NotifyFn)
		return ConfigReportPersistenceFailure("the gesture mode of " . Slot)
	LoggerInfo("gestures.incremental", "Gesture modes.{1} -> {2}.", Slot, Mode)
	return true
}

; Persists one incremental slot's step.
; @param Slot {String} A swipe slot with a step.
; @param Value {Number} Millimetres within the shared range.
; @returns {Boolean} Whether config.toml and the live configuration took it.
GestureSetSlotSensitivity(Slot, Value, WriterFn := 0, NotifyFn := 0) {
	global Features
	Step := GestureCoerceSensitivity(Value)
	if (GestureSlotSensitivity(Slot) = "" || Step = "") {
		LoggerWarn("gestures.incremental", "Refusing gesture step '{1}' for '{2}'.", Value, Slot)
		return false
	}
	if !WriteFeatureV2(Features, ConfigKey.GESTURES_SENSITIVITIES . "." . Slot, Step, "", WriterFn, NotifyFn)
		return ConfigReportPersistenceFailure("the gesture step of " . Slot)
	LoggerInfo("gestures.incremental", "Gesture sensitivities.{1} -> {2}.", Slot, Step)
	return true
}





; =======================================
; =======================================
; ======= 2/ The owner ==================
; =======================================
; =======================================

class RawTouchpadOwner {
	/**
	 * @param {Map} Options minimums (Map of the [gestures] *_minimum_mm timings),
	 *     stable_frames, handoff_ms; mode_of(slot) and step_of(slot), the
	 *     slot's mode only when the system routes it here; dispatch(slot) ->
	 *     Boolean, one action; schedule(callback), runs it on a fresh thread.
	 */
	__New(Options) {
		if !(Options is Map)
			throw TypeError("The raw touchpad owner needs its options.")
		for Name in ["mode_of", "step_of", "dispatch", "schedule"] {
			if !Options.Has(Name) || !HasMethod(Options[Name], "Call")
				throw TypeError("The raw touchpad owner needs " . Name . ".")
		}
		if !Options.Has("minimums") || !(Options["minimums"] is Map)
			throw TypeError("The raw touchpad owner needs the swipe minimums.")
		this._options := Options
		this._stable := Options["stable_frames"]
		this._handoff := GestureSwipeHandoff(Options["handoff_ms"])
		this._devices := Map()
		this._queue := []
		this._draining := false
		this._last_frame := 0
	}

	; The ownership of completed swipes.
	Handoff() {
		return this._handoff
	}

	; Whether a device is known (usable or refused).
	HasDevice(Handle) {
		return this._devices.Has(Handle)
	}

	; A known device, "" when it was refused.
	Device(Handle) {
		return this._devices[Handle]
	}

	; Remembers a device that is no usable touchpad, so it is read only once.
	RefuseDevice(Handle, Reason) {
		this._devices[Handle] := ""
		LoggerWarn("gestures.incremental", "Device {1} is not read as a touchpad: {2}.", Handle, Reason)
	}

	; Learns a touchpad from its decoded input value capabilities.
	; @param Handle {Integer} Raw input device handle.
	; @param ValueCaps {Array} TouchpadHidDecodeValueCaps output.
	; @param Reader {Object} Its report reader (Point, Value, Tip).
	; @returns {Object} The device: layout, assembler, decoder, tracker or "".
	AddDevice(Handle, ValueCaps, Reader) {
		Layout := TouchpadHidBuildLayout(ValueCaps)
		Device := {layout: Layout, reader: Reader, assembler: TouchpadHidFrameAssembler(),
			decoder: TouchpadLiveTravel(this._stable), tracker: ""}
		if (Layout["units_x"] > 0 && Layout["units_y"] > 0) {
			Device.tracker := GestureIncrementalTracker(Map(
				"units_x", Layout["units_x"], "units_y", Layout["units_y"],
				"minimums", this._options["minimums"],
				"mode_of", this._options["mode_of"], "step_of", this._options["step_of"],
				"slot_of", RawTouchpadAnsweringSlot,
				"fire", ObjBindMethod(this, "_Fire")))
			LoggerInfo("gestures.incremental", "Touchpad {1}: {2} finger(s), {3} x {4} units per mm; incremental swipes count millimetres.",
				Handle, Layout["fingers"].Length, Round(Layout["units_x"], 2), Round(Layout["units_y"], 2))
		} else {
			LoggerWarn("gestures.incremental", "Touchpad {1} reports no physical size: incremental swipes fire once, like x1 ones.", Handle)
		}
		this._devices[Handle] := Device
		return Device
	}

	; Forgets a removed touchpad; a touch it had in progress ends.
	RemoveDevice(Handle, Now) {
		if !this._devices.Has(Handle)
			return
		Device := this._devices.Delete(Handle)
		LoggerInfo("gestures.incremental", "Touchpad {1} removed; its descriptor is forgotten.", Handle)
		if IsObject(Device) && IsObject(Device.tracker) && Device.decoder.Touching()
			this._EndTouch(Device, Now)
	}

	; Parses one report of a known device under its reader and acts on it.
	; @param Handle {Integer} The device.
	; @param Now {Integer} A_TickCount of the report.
	FeedReport(Handle, Now) {
		Device := this._devices[Handle]
		if !IsObject(Device)
			return
		Frame := Device.assembler.Feed(TouchpadHidReadReport(Device.layout, Device.reader, Device.assembler.Wanted()))
		if IsObject(Frame)
			this._FeedFrame(Device, Frame, Now)
	}

	_FeedFrame(Device, Frame, Now) {
		this._last_frame := Now
		Ended := Device.decoder.Feed(Frame)
		if !IsObject(Device.tracker)
			return
		if Device.decoder.Touching() {
			this._handoff.TouchBegan()
			Device.tracker.Update(Device.decoder.Live())
		} else if Ended {
			this._EndTouch(Device, Now)
		}
	}

	_EndTouch(Device, Now) {
		Device.tracker.Finish()
		Pending := this._handoff.TouchEnded(Now)
		if (Pending != "") {
			LoggerDebug("gestures.incremental", "{1}: the touch did not step; its shortcut fires once.", Pending)
			this._Enqueue(Pending)
		}
	}

	; Ends every touch whose frames stopped (a device that never sent its
	; lift frame), so a deferred shortcut cannot wait forever.
	; @param Now {Integer} A_TickCount.
	; @param StaleMs {Integer} Silence after which a touch is over.
	Expire(Now, StaleMs) {
		if (Now - this._last_frame < StaleMs)
			return
		for Handle, Device in this._devices {
			if IsObject(Device) && IsObject(Device.tracker) && Device.decoder.Touching() {
				Device.decoder.Feed([])
				this._EndTouch(Device, Now)
			}
		}
	}

	; Drops queued actions and in-progress touches (pause).
	Reset(Now) {
		this._queue := []
		for Handle, Device in this._devices {
			if !IsObject(Device)
				continue
			if Device.decoder.Touching() {
				Device.decoder.Feed([])
				if IsObject(Device.tracker)
					Device.tracker.Finish()
			}
			Device.assembler := TouchpadHidFrameAssembler()
		}
		this._handoff.TouchEnded(Now)
	}

	; What the settings' shortcut of a swipe slot may do now.
	; @returns {String} "dispatch", "swallow" or "defer".
	ClaimShortcut(Slot, Now) {
		Mode := this._options["mode_of"].Call(Slot)
		return this._handoff.Claim(Slot, Mode = "incremental", Now)
	}

	; The tracker's fire: queues the steps and counts them as fired.
	_Fire(Slot, Fingers, Direction, Count) {
		this._handoff.StepFired()
		loop Count
			this._Enqueue(Slot)
		LoggerDebug("gestures.incremental", "{1}: {2} step(s) while the fingers move.", Slot, Count)
		return Count
	}

	_Enqueue(Slot) {
		this._queue.Push(Slot)
		if !this._draining {
			this._draining := true
			this._options["schedule"].Call(ObjBindMethod(this, "Drain"))
		}
	}

	; Runs every queued action in order, on the scheduled thread.
	Drain() {
		while this._queue.Length {
			Slot := this._queue.RemoveAt(1)
			if !this._options["dispatch"].Call(Slot)
				LoggerDebug("gestures.incremental", "{1}: a queued step did not run.", Slot)
		}
		this._draining := false
	}

	; Queued actions, for the tests and the pause log.
	Queued() {
		return this._queue.Length
	}
}

; Windows has no diagonal slot: a diagonal answers for its dominant straight
; direction, as an unbound diagonal does on macOS and Linux.
RawTouchpadAnsweringSlot(Slot, Fingers, Direction, Dominant) {
	if (Dominant = "")
		return {slot: Slot, direction: Direction}
	return {slot: Format("swipe_{1}_{2}", Min(Fingers, 5), Dominant), direction: Dominant}
}





; =======================================
; =======================================
; ======= 3/ Production lifecycle =======
; =======================================
; =======================================

; The swipe minimums from the shared timings registry.
_RawTouchpadMinimums() {
	return Map(
		"swipe_minimum_mm", TimingsGetNumber("gestures", "swipe_minimum_mm"),
		"pair_swipe_minimum_mm", TimingsGetNumber("gestures", "pair_swipe_minimum_mm"),
		"pair_diagonal_minimum_mm", TimingsGetNumber("gestures", "pair_diagonal_minimum_mm"))
}

; A slot's mode for the reader: only a slot the system routes to Ergopti.
_RawTouchpadModeOf(Slot) {
	return GestureSystemSlotAvailable(Slot) ? GestureSlotMode(Slot) : ""
}

; Starts the reader for the script's window.
; @param Hwnd {Integer} The window that receives WM_INPUT.
; @returns {Boolean} Whether the touchpad collection is registered.
; @throws {Error} On a second start.
RawTouchpadStart(Hwnd := A_ScriptHwnd) {
	global _RawTouchpadOwner, _RawTouchpadReceiver, RAW_INPUT_WM_INPUT, RAW_INPUT_WM_INPUT_DEVICE_CHANGE
	global RAW_INPUT_RIDEV_INPUTSINK, RAW_INPUT_RIDEV_DEVNOTIFY
	global TOUCHPAD_HID
	if IsObject(_RawTouchpadOwner)
		throw Error("The raw touchpad reader is already started.")
	LoggerStart("gestures.incremental", "Registering the touchpad's raw HID reports…")
	; The routing of each slot gates its steps; read it before the first touch.
	GestureSystemRefresh()
	Owner := RawTouchpadOwner(Map(
		"minimums", _RawTouchpadMinimums(),
		"stable_frames", TimingsGet("gestures", "finger_join_frames"),
		"handoff_ms", TimingsGet("gestures", "incremental_handoff_ms"),
		"mode_of", _RawTouchpadModeOf, "step_of", GestureSlotSensitivity,
		"dispatch", GestureRunSlotAction,
		"schedule", (Callback) => SetTimer(Callback, -1)))
	try {
		RawInput_Register(TOUCHPAD_HID.page_digitizer, TOUCHPAD_HID.touch_pad,
			RAW_INPUT_RIDEV_INPUTSINK | RAW_INPUT_RIDEV_DEVNOTIFY, Hwnd)
	} catch as Err {
		LoggerError("gestures.incremental", "The touchpad's raw reports could not be registered ({1}); incremental swipes fire once.",
			Err.Message)
		return false
	}
	_RawTouchpadOwner := Owner
	_RawTouchpadReceiver := RawInputReceiver()
	OnMessage(RAW_INPUT_WM_INPUT, _RawTouchpadOnInput)
	OnMessage(RAW_INPUT_WM_INPUT_DEVICE_CHANGE, _RawTouchpadOnDeviceChange)
	LoggerSuccess("gestures.incremental", "Touchpad raw reports registered; incremental swipes follow the fingers.")
	return true
}

; Stops the reader; a no-op when it never started.
; @returns {Boolean} Whether the registration was removed (true when none).
RawTouchpadStop() {
	global _RawTouchpadOwner, _RawTouchpadReceiver, RAW_INPUT_WM_INPUT, RAW_INPUT_WM_INPUT_DEVICE_CHANGE, RAW_INPUT_RIDEV_REMOVE
	global TOUCHPAD_HID
	if !IsObject(_RawTouchpadOwner)
		return true
	LoggerStart("gestures.incremental", "Removing the touchpad's raw HID reports…")
	OnMessage(RAW_INPUT_WM_INPUT, _RawTouchpadOnInput, 0)
	OnMessage(RAW_INPUT_WM_INPUT_DEVICE_CHANGE, _RawTouchpadOnDeviceChange, 0)
	SetTimer(_RawTouchpadWatchdog, 0)
	_RawTouchpadOwner := ""
	_RawTouchpadReceiver := ""
	try {
		RawInput_Register(TOUCHPAD_HID.page_digitizer, TOUCHPAD_HID.touch_pad, RAW_INPUT_RIDEV_REMOVE, 0)
	} catch as Err {
		LoggerError("gestures.incremental", "The touchpad's raw reports could not be removed: {1}.", Err.Message)
		return false
	}
	LoggerSuccess("gestures.incremental", "Touchpad raw reports removed.")
	return true
}

; Pause drops the touch in progress and every queued step ("pause = tout éteint").
RawTouchpadOnPause() {
	global _RawTouchpadOwner
	if IsObject(_RawTouchpadOwner)
		_RawTouchpadOwner.Reset(A_TickCount)
	return true
}

; Whether the settings' shortcut of a swipe slot must not run now: swallowed
; because the touch already stepped, or deferred to the touch's end.
; @param Slot {String} The slot the shortcut names.
; @returns {Boolean}
RawTouchpadClaimsShortcut(Slot) {
	global _RawTouchpadOwner
	if !IsObject(_RawTouchpadOwner) || SubStr(Slot, 1, 6) != "swipe_"
		return false
	Verdict := _RawTouchpadOwner.ClaimShortcut(Slot, A_TickCount)
	if (Verdict = "dispatch")
		return false
	LoggerDebug("gestures.incremental", "{1}: shortcut {2} by the moving touch.", Slot,
		Verdict = "swallow" ? "swallowed" : "deferred")
	if (Verdict = "defer")
		SetTimer(_RawTouchpadWatchdog, TimingsGet("gestures", "incremental_handoff_ms"))
	return true
}

; Ends a touch whose frames stopped, so a deferred shortcut still fires.
_RawTouchpadWatchdog() {
	global _RawTouchpadOwner
	if !IsObject(_RawTouchpadOwner) {
		SetTimer(_RawTouchpadWatchdog, 0)
		return
	}
	_RawTouchpadOwner.Expire(A_TickCount, TimingsGet("gestures", "incremental_handoff_ms"))
	if (_RawTouchpadOwner.Handoff().Pending() = "")
		SetTimer(_RawTouchpadWatchdog, 0)
}

; WM_INPUT: parses each report of the payload. Raw input keeps arriving while
; the driver is paused (OnMessage bypasses Suspend), so a paused driver reads
; nothing.
_RawTouchpadOnInput(WParam, LParam, Msg, Hwnd) {
	global _RawTouchpadOwner, _RawTouchpadReceiver
	if A_IsSuspended || !IsObject(_RawTouchpadOwner)
		return
	try {
		Payload := _RawTouchpadReceiver.Read(LParam)
		if !IsObject(Payload)
			return
		Owner := _RawTouchpadOwner
		if !Owner.HasDevice(Payload.device)
			_RawTouchpadLearnDevice(Owner, Payload.device)
		Device := Owner.Device(Payload.device)
		if !IsObject(Device)
			return
		Now := A_TickCount
		loop Payload.count {
			Device.reader.Point(Payload.ptr + (A_Index - 1) * Payload.size, Payload.size)
			Owner.FeedReport(Payload.device, Now)
		}
	} catch as Err {
		_RawTouchpadReportFailure(Err)
	}
}

; Reads a new device's descriptor; a device that is not a usable touchpad is
; remembered without a tracker, so it is read once.
_RawTouchpadLearnDevice(Owner, Handle) {
	global TOUCHPAD_HID
	try {
		Preparsed := RawInput_PreparsedData(Handle)
		Caps := RawInput_HidCaps(Preparsed)
		if (Caps["usage_page"] != TOUCHPAD_HID.page_digitizer || Caps["usage"] != TOUCHPAD_HID.touch_pad)
			throw ValueError(Format("collection 0x{1:X}/0x{2:X} is no touchpad", Caps["usage_page"], Caps["usage"]))
		Raw := RawInput_HidValueCaps(Preparsed, Caps["input_value_caps"], &Got)
		Owner.AddDevice(Handle, TouchpadHidDecodeValueCaps(Raw, Got), RawInputHidReader(Preparsed))
	} catch as Err {
		Owner.RefuseDevice(Handle, Err.Message)
	}
}

; A failing report is logged once per message, not once per frame.
_RawTouchpadReportFailure(Err) {
	static Last := ""
	if (Err.Message == Last)
		return
	Last := Err.Message
	LoggerError("gestures.incremental", "Touchpad report refused: {1}.", Err.Message)
}

; WM_INPUT_DEVICE_CHANGE: a removed touchpad's descriptor is forgotten.
_RawTouchpadOnDeviceChange(WParam, LParam, Msg, Hwnd) {
	global _RawTouchpadOwner, RAW_INPUT_GIDC_REMOVAL
	if (WParam = RAW_INPUT_GIDC_REMOVAL && IsObject(_RawTouchpadOwner))
		_RawTouchpadOwner.RemoveDevice(LParam, A_TickCount)
}
