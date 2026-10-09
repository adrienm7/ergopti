; platform/remap/tap_hold_roll.ahk

; ==============================================================================
; MODULE: Tap-Holds — A Typing Key Decided By The Order Of The Releases
; DESCRIPTION:
; Space, Enter, Tab, Backspace, Delete and Escape that keep their own key on a
; tap and gain a hold are struck in the flow of text, where the next key goes
; down before they come up. With the hold taken at key-down, « word, Space,
; a » typed « wordA » and then the space: the letter was struck under the
; Shift the hold had already pressed (« fonctionnerA ussi », 2026-10-01).
;
; FEATURES & RATIONALE:
; 1. Such a key takes nothing at key-down. It is a tap when it comes up first
;    or when a second key is struck before either came up (typing rolling on),
;    and its hold when the key struck under it comes up first or its threshold
;    passes. A quick chord therefore stays a chord and needs no wait.
; 2. The keys struck meanwhile must wait for the decision, and they are other
;    hotkeys or no hotkey at all. A block of static hotkeys, eligible only
;    while a key is undecided, takes them (tap_hold_roll_keys.ahk, kept apart
;    so the test suites include this logic without hooking the keyboard); a
;    static variant is created before every Hotkey() one, so it wins over
;    the layout emulation and the layer.
; 3. A key struck during the wait runs as a thread that interrupts the owner
;    of the undecided key, which cannot resume before that thread returns. The
;    decision is therefore taken in the interrupting thread, by looking at the
;    physical keys, and the owner reads it when it resumes.
; 4. The waiting keys are then sent again as the keys they are, above the
;    input level of every hotkey of the driver, so the emulation, the layer or
;    the application handles each exactly as if it had just been struck: after
;    the tap, or under the hold.
; 5. Scope: only the keys of the shared list ([tap_hold.rollover] in
;    _shared/tap_hold/defaults.toml) whose tap is the key itself. A modifier
;    key, or a key whose tap runs an action, keeps the hold it takes at
;    key-down: its chords and its clicks must not wait.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================
; ========================
; ======= 1/ State =======
; ========================
; ========================

; The typing keys decided by the order of the releases, read once here, at
; this file's include position, and never from a #HotIf.
global TAPHOLD_ROLL_KEYS := _TapHoldReadRollKeys()

; How often the thread of a waiting key looks at the physical keys, and the
; send level its key is sent again at: above the input level of every hotkey of
; the driver (the emulation's Alt chords are at 3).
global TAPHOLD_ROLL_POLL_MS := 5
global TAPHOLD_ROLL_REPLAY_SEND_LEVEL := 4

; The undecided key and the keys waiting for it. "generation" tells one press
; from the next; "outcomes" holds, per key, what was decided and whether the
; hold was pressed, until the key's owner reads it. Owned here and reached
; through this accessor only, so it exists whatever the include order.
_TapHoldRollState() {
	static State := Map("key", "", "sc", 0, "name", "", "down_at", 0, "threshold_ms", 0,
		"tap_fn", 0, "press_fn", 0, "queue", [], "waiting", false, "generation", 0,
		"tapping", "", "outcomes", Map())
	return State
}

; Reads [tap_hold.rollover] keys from the shared defaults.
; @returns {Map} Key id -> true; empty when the list cannot be read, which is
;          logged: every key then keeps the hold it takes at key-down.
_TapHoldReadRollKeys() {
	global _SharedDir
	Keys := Map()
	Path := (IsSet(_SharedDir) ? _SharedDir : "") . "\tap_hold\defaults.toml"
	try {
		Sections := TOML_ParseFreshFile(Path)
		List := Sections.Has("tap_hold.rollover") ? Sections["tap_hold.rollover"].Get("keys", "") : ""
		if !(List is Array) || List.Length == 0
			throw Error("[tap_hold.rollover] declares no keys")
		for KeyId in List
			Keys[KeyId] := true
	} catch as Err {
		try LoggerError("TapHoldRoll", "The typing keys could not be read from '{1}': {2}. Every hold is taken at key-down.",
			Path, Err.Message)
		return Map()
	}
	return Keys
}

; Whether KeyId is decided by the order of the releases: a typing key of the
; shared list whose tap is the key itself.
; @param KeyId {String} Canonical tap-hold key id.
; @returns {Boolean}
TapHoldKeyRolls(KeyId) {
	global TapHold, TAPHOLD_ROLL_KEYS
	if !IsSet(TAPHOLD_ROLL_KEYS) || !TAPHOLD_ROLL_KEYS.Has(KeyId)
		return false
	Tap := TapHoldTapAction(TapHold, KeyId)
	return Tap == "" || Tap == KeyId
}

; Whether a typing key is down and not yet a tap or a hold: the criterion of
; the block of hotkeys in tap_hold_roll_keys.ahk.
; @returns {Boolean}
TapHoldRollUndecided() {
	return _TapHoldRollState()["key"] != ""
}

; Whether the tap of KeyId is being typed by the roll owner now: the keys
; struck around it are typing, not a chord, and do not cancel it.
; @returns {Boolean}
TapHoldRollTapIsRunning(KeyId) {
	return _TapHoldRollState()["tapping"] == KeyId
}





; =========================
; =========================
; ======= 2/ Owners =======
; =========================
; =========================

; The hold of a key, on a modifier: decided by the order of the releases for a
; typing key, taken at key-down for every other.
; @param TapFn {Func} Types the key's tap; the roll owner runs it itself, at
;        the moment the order of the keys requires it.
; @returns {Map} As TapHoldOwnImmediateModifier. "tap" is false for a typing
;          key: its tap is already typed.
TapHoldOwnHoldModifier(KeyId, KeyName, ModKey, TapThresholdSec, TapFn) {
	if !TapHoldKeyRolls(KeyId)
		return TapHoldOwnImmediateModifier(KeyId, KeyName, ModKey, TapThresholdSec)
	return TapHoldOwnRoll(KeyId, KeyName, TapThresholdSec, TapFn,
		_TapHoldRollPressModifier.Bind(KeyId, ModKey),
		_TapHoldRollOwnModifier.Bind(KeyId, KeyName, ModKey, TapThresholdSec))
}

; The hold of a key, on the navigation layer: as TapHoldOwnHoldModifier.
TapHoldOwnHoldLayer(KeyId, KeyName, TapThresholdSec, TapFn) {
	if !TapHoldKeyRolls(KeyId)
		return TapHoldOwnImmediateLayer(KeyId, KeyName, TapThresholdSec)
	return TapHoldOwnRoll(KeyId, KeyName, TapThresholdSec, TapFn,
		ActivateLayer, _TapHoldRollOwnLayer.Bind(KeyId, KeyName, TapThresholdSec))
}

; Presses a modifier hold from the thread of the key struck under it, and
; publishes it as the immediate owner does (TapHoldAltGrTakesItsLCtrl).
_TapHoldRollPressModifier(KeyId, ModKey) {
	global _TH_OwnedModifiers
	if !TapHoldSyntheticKeyDown(ModKey)
		return false
	_TH_OwnedModifiers[KeyId] := ModKey
	return true
}

; Owns a modifier hold until the key comes up: the immediate owner, which
; presses nothing more when the hold is already down.
_TapHoldRollOwnModifier(KeyId, KeyName, ModKey, TapThresholdSec, Pressed) {
	return TapHoldOwnImmediateModifier(KeyId, KeyName, ModKey, TapThresholdSec, 0, 0, 0,
		Pressed ? (*) => true : 0)
}

; Owns a layer hold until the key comes up, as _TapHoldRollOwnModifier.
_TapHoldRollOwnLayer(KeyId, KeyName, TapThresholdSec, Pressed) {
	return TapHoldOwnImmediateLayer(KeyId, KeyName, TapThresholdSec, 0, 0, 0,
		Pressed ? (*) => true : 0)
}

; Owns one press of a typing key from its key-down to its release.
; @param KeyId {String} Canonical tap-hold key id.
; @param KeyName {String} Key name the release wait watches.
; @param TapThresholdSec {Number} The key's tap threshold.
; @param TapFn {Func} Types the key's tap.
; @param PressHoldFn {Func} Presses the hold; returns true when it is down.
; @param OwnHoldFn {Func} OwnHoldFn(Pressed) owns the hold until the release.
; @param Ports {Map} Test seams: "wait_release"(KeyName, Seconds), "tick"().
; @returns {Map} "activated" (the hold was owned), "tap" (always false),
;          "decision" ("tap", "hold" or "" for a press a click made neither).
TapHoldOwnRoll(KeyId, KeyName, TapThresholdSec, TapFn, PressHoldFn, OwnHoldFn, Ports := 0) {
	WaitRelease := _TapHoldRollPort(Ports, "wait_release", _TapHoldModifierWaitRelease)
	Tick := _TapHoldRollPort(Ports, "tick", _TapHoldModifierTickNow)
	State := _TapHoldRollState()
	; A typing key struck while another is undecided is the next key of the text.
	if (State["key"] != "")
		_TapHoldRollResolve("tap")
	_TapHoldClaimPress(KeyId)
	try {
		PreviousCritical := Critical("On")
		State["generation"] += 1
		State["key"] := KeyId
		State["sc"] := _TapHoldScanCodeOf(KeyId)
		State["name"] := KeyName
		State["down_at"] := Tick.Call()
		State["threshold_ms"] := TapThresholdSec * 1000
		State["tap_fn"] := TapFn
		State["press_fn"] := PressHoldFn
		State["queue"] := []
		State["waiting"] := false
		if State["outcomes"].Has(KeyId)
			State["outcomes"].Delete(KeyId)
		Critical(PreviousCritical)
		; A key struck during this wait decides in its own thread (TapHoldRollOtherKey).
		Released := WaitRelease.Call(KeyName, TapThresholdSec)
		_TapHoldRollResolve(Released ? "tap" : "hold", KeyId)
		Outcome := State["outcomes"].Has(KeyId) ? State["outcomes"][KeyId] : Map("decision", "", "pressed", false)
		Result := Map("activated", false, "tap", false, "decision", Outcome["decision"])
		if (Outcome["decision"] == "hold") {
			OwnHoldFn.Call(Outcome["pressed"])
			Result["activated"] := true
		} else if !Released {
			; Its tap is typed and the key is still down: nothing more until it is up.
			_TapHoldRollWaitUp(KeyName, WaitRelease)
		}
		return Result
	} finally {
		if (State["key"] == KeyId)
			State["key"] := ""
		if State["outcomes"].Has(KeyId)
			State["outcomes"].Delete(KeyId)
		_TapHoldEndPressClaim(KeyId)
	}
}

_TapHoldRollPort(Ports, Name, Default) {
	return (Ports is Map) && Ports.Has(Name) ? Ports[Name] : Default
}

; Waits for a key whose tap is already typed to come up.
_TapHoldRollWaitUp(KeyName, WaitRelease) {
	loop {
		if A_IsSuspended || WaitRelease.Call(KeyName, STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
			return
		if !_TapHoldModifierKeyIsDown(KeyName)
			return
	}
}

; Decides the undecided key, once: types its tap or presses its hold, then
; sends the waiting keys again in the order they were struck. A second call,
; from the owner or from another waiting key, changes nothing.
; @param Decision {String} "tap" or "hold".
; @param OnlyKeyId {String} When given, decide only while that key is the
;        undecided one (the owner's own call).
; @param Ports {Map} Test seam "replay"(ScanCodes).
_TapHoldRollResolve(Decision, OnlyKeyId := "", Ports := 0) {
	State := _TapHoldRollState()
	PreviousCritical := Critical("On")
	try {
		KeyId := State["key"]
		if (KeyId == "" || (OnlyKeyId != "" && OnlyKeyId != KeyId))
			return
		TapFn := State["tap_fn"]
		PressFn := State["press_fn"]
		Queue := State["queue"]
		State["key"] := ""
		State["queue"] := []
		Outcome := Map("decision", Decision, "pressed", false)
		State["outcomes"][KeyId] := Outcome
	} finally Critical(PreviousCritical)
	if A_IsSuspended {
		Outcome["decision"] := ""
	} else if (Decision == "hold") {
		Outcome["pressed"] := PressFn.Call() ? true : false
	} else {
		Previous := State["tapping"]
		State["tapping"] := KeyId
		try TapFn.Call()
		finally State["tapping"] := Previous
	}
	if (Queue.Length > 0)
		_TapHoldRollPort(Ports, "replay", _TapHoldRollReplay).Call(Queue)
}

; Sends keys again as the keys they are, press and release: the hook suppresses
; the release of a key whose press a hotkey suppressed, and a key still held
; types on through its own auto-repeat.
; @param ScanCodes {Array} Scan codes, extended ones above 0x100.
_TapHoldRollReplay(ScanCodes) {
	global TAPHOLD_ROLL_REPLAY_SEND_LEVEL
	PreviousLevel := A_SendLevel
	SendLevel(TAPHOLD_ROLL_REPLAY_SEND_LEVEL)
	try {
		for Sc in ScanCodes
			SendEvent("{Blind}{" . Format("SC{:03X}", Sc) . "}")
	} finally SendLevel(PreviousLevel)
}

; A key struck while a typing key is undecided: it waits, and its thread takes
; the decision the order of the keys gives.
; @param HotkeyName {String} The hotkey that fired; A_ThisHotkey by default.
; @param Ports {Map} Test seams: "is_down"(ScanCode), "tick"(), "sleep"(Ms),
;        "replay"(ScanCodes).
TapHoldRollOtherKey(HotkeyName := unset, Ports := 0) {
	global TAPHOLD_ROLL_POLL_MS
	Name := IsSet(HotkeyName) ? HotkeyName : A_ThisHotkey
	if !RegExMatch(Name, "i)SC([0-9A-F]{3})$", &Found)
		throw ValueError("A typing-key roll hotkey must be named by its scan code.", -1, Name)
	Sc := Integer("0x" . Found[1])
	IsDown := _TapHoldRollPort(Ports, "is_down", _TapHoldRollScIsDown)
	Tick := _TapHoldRollPort(Ports, "tick", _TapHoldModifierTickNow)
	Wait := _TapHoldRollPort(Ports, "sleep", Sleep)
	State := _TapHoldRollState()
	PreviousCritical := Critical("On")
	try {
		if (State["key"] == "") {
			; Decided since the criterion was read: the key is itself.
			Undecided := false
		} else {
			Undecided := true
			; The undecided key's own auto-repeat belongs to its owner.
			if (Sc == State["sc"])
				return
			State["queue"].Push(Sc)
			Second := State["waiting"]
			State["waiting"] := true
			Generation := State["generation"]
			KeySc := State["sc"]
		}
	} finally Critical(PreviousCritical)
	if !Undecided {
		_TapHoldRollPort(Ports, "replay", _TapHoldRollReplay).Call([Sc])
		return
	}
	; A second key struck before either came up: typing rolling on.
	if Second {
		_TapHoldRollResolve("tap", , Ports)
		return
	}
	loop {
		; Decided by a key struck after this one, which sent this one again too.
		if (State["key"] == "" || State["generation"] != Generation)
			return
		if !IsDown.Call(KeySc) {
			_TapHoldRollResolve("tap", , Ports)
			return
		}
		if (!IsDown.Call(Sc) || TickElapsed(State["down_at"], Tick.Call()) > State["threshold_ms"]) {
			_TapHoldRollResolve("hold", , Ports)
			return
		}
		Wait.Call(TAPHOLD_ROLL_POLL_MS)
	}
}

; Whether the key of a scan code is physically down.
_TapHoldRollScIsDown(Sc) {
	return GetKeyState(Format("SC{:03X}", Sc), "P")
}

