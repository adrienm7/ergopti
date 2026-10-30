; tests/meta/corpus/test_corpus_tap_hold_decisions.ahk

; =============================================================================
; MODULE: Tap-Hold Decision Corpus Replay (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/tap_hold/decision_vectors.json through the
; production owners of platform/remap (TapHoldOwnImmediateModifier,
; TapHoldOwnRoll, TapHoldRollOtherKey), the real activity tracker fed through
; HookDispatcher, the real TapHoldDispatchTap, TapHoldEmitKeyTap and the
; synthetic-key ledger. What reaches _AHK_SendInput is read as the keystrokes an
; application receives.
;
; FEATURES & RATIONALE:
; 1. A hotkey interrupts the thread of the key it was struck under, and that
;    thread cannot resume before it returns. So the wait of an owner plays the
;    next events of the vector inside itself: the same nesting as AutoHotkey.
; 2. The gate each hotkey body adds to Result["tap"] lives in a file the suite
;    cannot include (it declares hotkeys). It is read from that source here, so
;    changing a gate in production changes this replay.
; 3. Not driven: the native InputHook of OneShotShift, which cannot run here
;    without real keystrokes. The next character is handed to the result table
;    and the title-casing OneShotShift applies, both pinned to its source, and
;    the native timeout is read from the same shared timing.
; =============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Corpus and keys =======
; ==================================
; ==================================

; The vector count, pinned as _shared/lua/test/tap_hold_decision_contract.lua
; pins it, so a truncated corpus fails instead of shrinking the contract.
global _CTHD_VECTOR_COUNT := 23

_CTHD_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\tap_hold\decision_vectors.json", "UTF-8"))
	return Corpus
}

; Corpus key -> vk, scan code, and the key name its owner waits on (hotkey file).
_CTHD_KeyTable() {
	static Keys := Map(
		"caps_lock", { Vk: 0x14, Sc: 0x03A, Wait: "CapsLock" },
		"left_shift", { Vk: 0xA0, Sc: 0x02A, Wait: "SC02A", Native: "LShift" },
		"right_shift", { Vk: 0xA1, Sc: 0x036, Wait: "SC036", Native: "RShift" },
		"left_ctrl", { Vk: 0xA2, Sc: 0x01D, Wait: "SC01D", Native: "LCtrl" },
		"space", { Vk: 0x20, Sc: 0x039, Wait: "SC039" },
		"a", { Vk: 0x41, Sc: 0x01E },
		"j", { Vk: 0x4A, Sc: 0x024 })
	return Keys
}

; AHK key name -> [tap_hold.hold_picker] modifier and its side-specific corpus name.
_CTHD_ModifierTable() {
	static Modifiers := Map(
		"LCtrl", { Picker: "ctrl", Side: "left_ctrl" },
		"RCtrl", { Picker: "ctrl", Side: "right_ctrl" },
		"LShift", { Picker: "shift", Side: "left_shift" },
		"RShift", { Picker: "shift", Side: "right_shift" })
	return Modifiers
}

; The gate a hotkey body adds to Result["tap"] for one key: the source line.
_CTHD_GateSource(Key) {
	global _DriverDir
	if (Key == "caps_lock") {
		Source := FileRead(_DriverDir . "\platform\remap\capslock.ahk", "UTF-8")
		Start := InStr(Source, "#HotIf _CapsLockHasHoldModifier()", true)
		Finish := InStr(Source, "`n#HotIf", true, Start + 1)
		AssertTrue(Start > 0 && Finish > Start, "the CapsLock hold-modifier hotkey must exist")
		Body := SubStr(Source, Start, Finish - Start)
	} else {
		Name := Map("left_shift", "_LShiftHandleHold", "right_shift", "_RShiftHandleHold")[Key]
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", Name . " must exist")
	}
	AssertTrue(RegExMatch(Body, 'm)^\s*if \(?Result\["tap"\].*$', &Found) > 0, "the hotkey of " . Key . " must gate its tap on the owner's verdict")
	return Found[0]
}





; ==============================
; ==============================
; ======= 2/ The replay ========
; ==============================
; ==============================

; One replay: the physical keys, the OS logical keys and the clock of a vector.
class _CTHD_World {
	__New(Vector) {
		this.Vector := Vector
		this.Bindings := Vector["bindings"]
		this.Events := Vector["events"].Clone()
		this.Now := 0
		this.Physical := Map()
		this.Logical := Map()
		this.History := []
		this.Strokes := []
		this.HoldPresses := []
		this.FirstBound := ""
		this.OneShotUntil := -1
		for Event in Vector["events"] {
			if (Event[1] == "down" && this.Bindings.Has(Event[2])) {
				this.FirstBound := Event[2]
				break
			}
		}
	}

	; Reads one payload the driver sends. Without {Blind} AutoHotkey lifts the
	; modifiers the user holds around the keystroke.
	OnSend(Payload) {
		Blind := InStr(Payload, "{Blind}") > 0
		Rest := StrReplace(Payload, "{Blind}", "")
		Pos := 1
		while (Pos := RegExMatch(Rest, "i)\{(\w+)(?: (down|up))?\}", &Token, Pos)) {
			Pos += StrLen(Token[0])
			Name := Token[1]
			if (Token[2] = "down") {
				this.Logical[Name] := true
				if (this.Pressing != "" && this.Pressing == this.FirstBound)
					this.HoldPresses.Push(_CTHD_ModifierTable()[Name].Side)
			} else if (Token[2] = "up") {
				if this.Logical.Has(Name)
					this.Logical.Delete(Name)
			} else {
				this.Stroke(StrLower(Name), Blind)
			}
		}
		return Payload
	}

	Pressing := ""

	; One key press of a non-modifier key an application receives, spelled as the
	; corpus does, in the hold-picker order.
	Stroke(Key, UnderHeld := true) {
		Text := ""
		for Modifier in _CTHD_HoldPickerOrder() {
			if !UnderHeld
				break
			for Name, Info in _CTHD_ModifierTable() {
				if (Info.Picker == Modifier && this.Logical.Has(Name)) {
					Text .= Modifier . "+"
					break
				}
			}
		}
		this.Strokes.Push(Text . Key)
	}

	; An ordinary key reaching the application: the armed one-shot captures it.
	Deliver(Key) {
		global ScriptInformation
		if (this.OneShotUntil >= 0) {
			Armed := this.Now <= this.OneShotUntil
			this.OneShotUntil := -1
			if Armed {
				AssertEqual("", TapHoldOneShotResult(Key, ScriptInformation["MagicKey"]),
					"a corpus letter has no special one-shot result")
				; OneShotShift title-cases a character with no special result.
				this.Strokes.Push(Format("{:T}", Key) == StrUpper(Key) ? "shift+" . Key : Key)
				return
			}
		}
		this.Stroke(Key)
	}

	; Advances the clock by Ms, playing every event that falls inside.
	Sleep(Ms) {
		this.Now += Ms
		while (this.Events.Length > 0 && this.Events[1][3] <= this.Now)
			this.PlayNext()
	}

	; KeyWait "U T": the thread of a key struck meanwhile runs inside this wait.
	WaitRelease(Key, Seconds) {
		Deadline := this.Now + Round(Seconds * 1000)
		loop {
			if !this.Physical.Has(Key)
				return true
			if (this.Now >= Deadline)
				return false
			if (this.Events.Length == 0 || this.Events[1][3] > Deadline) {
				this.Now := Deadline
				continue
			}
			this.PlayNext()
		}
	}

	; The name AutoHotkey derives for A_PriorKey on a release: the last press
	; before the most recent event, whatever released in between.
	PriorKey() {
		Index := this.History.Length - 1
		while (Index >= 1) {
			if (this.History[Index].Down)
				return GetKeyName(Format("SC{:03X}", _CTHD_KeyTable()[this.History[Index].Key].Sc))
			Index -= 1
		}
		return ""
	}

	; Plays the next event of the vector, hook first and then the hotkey.
	PlayNext() {
		Event := this.Events.RemoveAt(1)
		Key := Event[2]
		Down := Event[1] == "down"
		if (Event[3] > this.Now)
			this.Now := Event[3]
		Info := _CTHD_KeyTable()[Key]
		this.History.Push({ Key: Key, Down: Down })
		if Down {
			this.Physical[Key] := true
			HookDispatcher._OnKeyDown(0, Info.Vk, Info.Sc)
			this.OnPress(Key, Info)
		} else {
			this.Physical.Delete(Key)
			if (Info.HasOwnProp("Native") && this.Logical.Has(Info.Native))
				this.Logical.Delete(Info.Native)
			HookDispatcher._OnKeyUp(0, Info.Vk, Info.Sc)
		}
	}

	OnPress(Key, Info) {
		if this.Bindings.Has(Key) {
			this.OwnPress(Key, Info)
		} else if Info.HasOwnProp("Native") {
			this.Logical[Info.Native] := true
		} else if TapHoldRollUndecided() {
			TapHoldRollOtherKey("*" . Format("SC{:03X}", Info.Sc), this.RollPorts())
		} else {
			this.Deliver(Key)
		}
	}

	RollPorts() {
		World := this
		return Map(
			"is_down", (Sc) => World.Physical.Has(_CTHD_KeyOfSc(Sc)),
			"tick", () => World.Now,
			"sleep", (Ms) => World.Sleep(Ms),
			"replay", (ScanCodes) => _CTHD_ReplayKeys(World, ScanCodes))
	}

	OwnPress(Key, Info) {
		global TapHold
		World := this
		Wait := (KeyName, Seconds) => World.WaitRelease(Key, Seconds)
		Tick := () => World.Now
		Seconds := TapHoldDuration(TapHold, Key)
		ModKey := ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, Key), Key)
		Previous := this.Pressing
		this.Pressing := Key
		try {
			if TapHoldKeyRolls(Key) {
				if TapHoldRollUndecided()
					throw Error("a vector with two undecided typing keys would replay outside the seam")
				TapFn := () => _CTHD_FireTap(World, Key)
				PressFn := _TapHoldRollPressModifier.Bind(Key, ModKey)
				OwnFn := (Pressed) => TapHoldOwnImmediateModifier(Key, Info.Wait, ModKey, Seconds,
					Wait, (Name) => World.Physical.Has(Key), Tick, Pressed ? (*) => true : 0)
				TapHoldOwnRoll(Key, Info.Wait, Seconds, TapFn, PressFn, OwnFn,
					Map("wait_release", Wait, "tick", Tick))
				return
			}
			; A native modifier held as itself passes through: its own edge holds it.
			Passthrough := Info.HasOwnProp("Native") && ModKey == Info.Native
			if Passthrough {
				this.Logical[Info.Native] := true
				if (Key == this.FirstBound)
					this.HoldPresses.Push(_CTHD_ModifierTable()[Info.Native].Side)
			}
			Result := TapHoldOwnImmediateModifier(Key, Info.Wait, ModKey, Seconds,
				Wait, (Name) => World.Physical.Has(Key), Tick, 0, 0, 0, Passthrough)
			Gate := _CTHD_GateSource(Key)
			if !Result["tap"]
				return
			if (InStr(Gate, "TapMinDurationMs()") && Result["elapsed_ms"] < TapMinDurationMs())
				return
			if (InStr(Gate, "TapHoldPriorKeyIsSelf") && !TapHoldPriorKeyIsSelf(Key, this.PriorKey()))
				return
			_CTHD_FireTap(World, Key)
		} finally {
			this.Pressing := Previous
		}
	}
}

_CTHD_KeyOfSc(Sc) {
	for Key, Info in _CTHD_KeyTable() {
		if (Info.Sc == Sc)
			return Key
	}
	throw Error("no corpus key has scan code " . Sc)
}

_CTHD_ReplayKeys(World, ScanCodes) {
	for Sc in ScanCodes
		World.Deliver(_CTHD_KeyOfSc(Sc))
}

; The tap of a bound key through the single dispatch gate.
_CTHD_FireTap(World, Key) {
	global TapHold, ONE_SHOT_SHIFT_TIMEOUT_SEC
	Tap := TapHoldTapAction(TapHold, Key)
	if (Tap == "one_shot_shift")
		return TapHoldDispatchTap(Key, () => (World.OneShotUntil := World.Now + ONE_SHOT_SHIFT_TIMEOUT_SEC * 1000))
	if (Tap == "" || Tap == Key)
		return TapHoldDispatchTap(Key, () => TextPressKeyFed(StrTitle(Key)))
	return _TapHoldFireAction(Key)
}

_CTHD_HoldPickerOrder() {
	global _SharedDir
	static Order := 0
	if !IsObject(Order)
		Order := TOML_ParseFreshFile(_SharedDir . "\tap_hold\defaults.toml")["tap_hold.hold_picker"]["modifiers"]
	return Order
}

; Replays one vector with the driver's state swapped for the replay's own.
_CTHD_Replay(Vector) {
	global TapHold, _AHK_SendInput, _TapHoldModifierIsHeld, _TapHoldKeyIsDown
	global _TH_TapHoldTrackState, _TH_SyntheticHeldKeys, _TH_SyntheticUserHeldKeys
	global TAP_MIN_DURATION_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC
	World := _CTHD_World(Vector)
	Keys := Map()
	for Key, Binding in Vector["bindings"] {
		Keys[Key] := Map(
			"enabled", true,
			"hold_modifier", Binding["hold"],
			"hold_layer", "",
			"time_activation_seconds", Binding["threshold_ms"] / 1000)
		; A key that types itself has no tap_action at all, as the loader leaves it.
		if Binding.Has("tap")
			Keys[Key]["tap_action"] := Binding["tap"]
	}
	Saved := { TapHold: TapHold, Send: _AHK_SendInput, Held: _TapHoldModifierIsHeld, IsDown: _TapHoldKeyIsDown,
		Track: _TH_TapHoldTrackState, Synth: _TH_SyntheticHeldKeys, User: _TH_SyntheticUserHeldKeys,
		TapMin: TAP_MIN_DURATION_MS, OneShot: ONE_SHOT_SHIFT_TIMEOUT_SEC, Wheel: HookDispatcher._last_wheel_tick }
	TapHold := Map("keys", Keys, "layers", Map())
	_TH_TapHoldTrackState := Map()
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
	HookDispatcher._last_wheel_tick := 0
	TAP_MIN_DURATION_MS := TimingsGet("tap_hold", "tap_min_duration_ms")
	ONE_SHOT_SHIFT_TIMEOUT_SEC := TimingsGetSec("tap_hold", "one_shot_shift_timeout_ms")
	_AHK_SendInput := (Payload) => World.OnSend(Payload)
	_TapHoldModifierIsHeld := (Name) => World.Logical.Has(Name)
	_TapHoldKeyIsDown := (Name, Mode) => (Mode == "") ? World.Logical.Has(Name) : _CTHD_PhysicalName(World, Name)
	try {
		while (World.Events.Length > 0)
			World.PlayNext()
	} finally {
		TapHold := Saved.TapHold
		_AHK_SendInput := Saved.Send
		_TapHoldModifierIsHeld := Saved.Held
		_TapHoldKeyIsDown := Saved.IsDown
		_TH_TapHoldTrackState := Saved.Track
		_TH_SyntheticHeldKeys := Saved.Synth
		_TH_SyntheticUserHeldKeys := Saved.User
		TAP_MIN_DURATION_MS := Saved.TapMin
		ONE_SHOT_SHIFT_TIMEOUT_SEC := Saved.OneShot
		HookDispatcher._last_wheel_tick := Saved.Wheel
	}
	return World
}

; Whether the AHK name Name is physically down: a native modifier of the corpus.
_CTHD_PhysicalName(World, Name) {
	for Key, Info in _CTHD_KeyTable() {
		if (Info.HasOwnProp("Native") && Info.Native == Name)
			return World.Physical.Has(Key)
	}
	return false
}





; ============================
; ============================
; ======= 3/ The tests =======
; ============================
; ============================

_CTHD_Joined(List) {
	Text := ""
	for Item in List
		Text .= (A_Index == 1 ? "" : ", ") . Item
	return "[" . Text . "]"
}

_CTHD_ReplayVector(Vector) {
	Divergences := Vector.Has("divergences") ? Vector["divergences"] : Map()
	Expected := Divergences.Has("windows") ? Divergences["windows"] : Vector["expected"]
	World := _CTHD_Replay(Vector)
	AssertEqual(_CTHD_Joined(Expected["strokes"]), _CTHD_Joined(World.Strokes), Vector["id"] . ": the keystrokes")
	if Expected.Has("hold_presses")
		AssertEqual(_CTHD_Joined(Expected["hold_presses"]), _CTHD_Joined(World.HoldPresses), Vector["id"] . ": the hold's presses")
}

_CTHD_CountIsPinned() {
	global _CTHD_VECTOR_COUNT
	AssertEqual(_CTHD_VECTOR_COUNT, _CTHD_Corpus()["vectors"].Length, "decision_vectors.json changed size: update the count with the corpus")
}
Test("tap_hold decision corpus: holds the pinned number of vectors", _CTHD_CountIsPinned)

_CTHD_OneShotSourcePinned() {
	Body := _DriverFuncBody("OneShotShift")
	AssertTrue(Body != "", "OneShotShift must exist")
	AssertTrue(InStr(Body, 'Format("{:T}", Scalar)') > 0, "the replay reads a capitalised letter through this title-casing")
	AssertTrue(InStr(Body, "TapHoldOneShotResult(Scalar, MagicKey)") > 0, "the replay reads special results through this table")
	AssertTrue(InStr(Body, 'InputHook("L2 T" . TimeoutSec') > 0, "the native capture must time out at the shared timeout the replay reads")
}
Test("tap_hold decision corpus: the one-shot replay matches OneShotShift's own steps", _CTHD_OneShotSourcePinned)

_CTHD_RegisterVectors() {
	for Vector in _CTHD_Corpus()["vectors"]
		Test("tap_hold decision corpus: " . Vector["id"], _CTHD_ReplayVector.Bind(Vector))
}
_CTHD_RegisterVectors()
