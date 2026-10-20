; modules/shortcuts/capsword_auto_off.ahk

; ==============================================================================
; MODULE: Shortcuts — CapsWord Auto-Off
; DESCRIPTION:
; Ends CapsWord on its own, as [shortcuts.caps_word] says: after a delay
; without a keystroke, on a checked word delimiter, and on a checked pointer
; kind. The decisions are the shared policy's
; (_shared/modules/features/caps_word_auto_off_policy.ahk); this module reads
; the settings, maps Windows events to the policy's questions, and owns every
; subscription and timer of one active CapsWord.
;
; FEATURES & RATIONALE:
; 1. Armed per Activation: ToggleCapsWord arms the listeners with the policy of
;    that moment and DisableCapsWord disarms them, so nothing listens while
;    CapsWord is off. Every handler also checks CapsWordEnabled first: a path
;    that clears the flag without DisableCapsWord (the fatal error net) leaves
;    inert listeners that disarm themselves on their next event.
; 2. Typed Delimiters: the HookDispatcher InputHook (I1) sees what the user
;    types and the layout emulation sends at level 2, never TextSender's level-0
;    output. Space and Enter keep capsword.ahk's own hotkeys, which send the key
;    themselves (invisible here), and a tap-hold's synthetic tap goes through
;    the tap-hold dispatcher; both ask CapsWordAutoOffEndsOnNativeKey. Every
;    other delimiter (Tab, the no-break spaces, punctuation) is the typed
;    character, read through CapsWordAutoOffEndsOnText.
; 3. Pointer Kinds: left, right, middle and the X buttons through the
;    dispatcher, scrolling through its wheel events, pointer movement through a
;    poll that runs only while CapsWord is active. Windows keeps touchpad
;    gestures to itself (the manifest declares no gesture kind for it); the
;    scrolling a two-finger swipe produces still counts as pointer motion.
; 4. Defaults: Space, Tab, Enter and every pointer kind, no delay — Space,
;    Enter and the left and right clicks ended CapsWord before; Tab, the middle
;    and X buttons and the pointer motion join them for parity with macOS.
; ==============================================================================

#Requires AutoHotkey v2.0




; The armed state of the one CapsWord this process can have.
class CapsWordAutoOff {
	; Policy compiled from config.toml, "" until CapsWordAutoOffReadConfig runs.
	static Configured := ""
	; The settings Configured was compiled from, "" until then.
	static Values := ""
	; Policy of the active CapsWord, "" while disarmed.
	static Armed := ""
	; What ends CapsWord: called with the reason and the pointer kind ("" otherwise).
	static EndFn := ""
	; [event type, callback] pairs registered on HookDispatcher.
	static Subscriptions := []
	; Whether the idle and the pointer-motion timers are running.
	static IdleRunning := false
	static MotionRunning := false
	; Last pointer position the motion poll saw, as "x,y".
	static LastPointer := ""
}





; ===========================
; ===========================
; ======= 1/ Settings =======
; ===========================
; ===========================

; The pointer kinds the manifest declares for this platform, in order.
; @returns {Array}
CapsWordAutoOffPointerKinds() {
	Kinds := []
	for Entry in ManifestFeaturesForSection("shortcuts.caps_word.pointer")
		Kinds.Push(Entry["id"])
	if Kinds.Length == 0
		throw Error("The manifest declares no [shortcuts.caps_word.pointer] kind.")
	return Kinds
}

; The stored delay, or its default when absent or not a number of seconds.
_CapsWordAutoOffReadIdle(Cache) {
	Default := ManifestDefaultFor("shortcuts.caps_word.idle_timeout_seconds")
	Raw := IniCacheGet(Cache, "shortcuts.caps_word", "idle_timeout_seconds")
	if Raw == "_"
		return Default
	if CapsWordAutoOffValidateIdleTimeout(Raw)
		return Raw
	LoggerWarn("CapsWord", "shortcuts.caps_word.idle_timeout_seconds '{1}' is not a number of seconds, 0 or more — using {2} s.",
		Raw is Object ? Type(Raw) : String(Raw), Default)
	return Default
}

; The stored delimiter list. An entry the catalogue no longer knows, or a
; repeated one, is outdated configuration: one WARNING each, the rest kept.
_CapsWordAutoOffReadTerminators(Cache) {
	Default := ManifestDefaultFor("shortcuts.caps_word.terminators")
	Raw := IniCacheGet(Cache, "shortcuts.caps_word", "terminators")
	if Raw == "_"
		return ManifestCloneValue(Default)
	if !(Raw is Array) {
		LoggerWarn("CapsWord", "shortcuts.caps_word.terminators is not a list of delimiter keys — using the default.")
		return ManifestCloneValue(Default)
	}
	Kept := []
	Seen := Map()
	for Key in Raw {
		if !CapsWordAutoOffIsTerminatorKey(Key) {
			LoggerWarn("CapsWord", "shortcuts.caps_word.terminators names '{1}', which is no delimiter — ignored.",
				Key is Object ? Type(Key) : String(Key))
			continue
		}
		if Seen.Has(Key) {
			LoggerWarn("CapsWord", "shortcuts.caps_word.terminators names '{1}' twice — kept once.", Key)
			continue
		}
		Seen[Key] := true
		Kept.Push(Key)
	}
	return Kept
}

; The stored pointer switches, each its default when absent or no boolean.
_CapsWordAutoOffReadPointer(Cache, Kinds) {
	Values := Map()
	for Kind in Kinds {
		Path := "shortcuts.caps_word.pointer." . Kind
		Raw := IniCacheGet(Cache, "shortcuts.caps_word.pointer", Kind)
		if Raw == "_" {
			Values[Kind] := ManifestDefaultFor(Path) ? 1 : 0
		} else if Type(Raw) == "Integer" && (Raw == 0 || Raw == 1) {
			Values[Kind] := Raw
		} else {
			LoggerWarn("CapsWord", "{1} '{2}' is not true or false — using its default.",
				Path, Raw is Object ? Type(Raw) : String(Raw))
			Values[Kind] := ManifestDefaultFor(Path) ? 1 : 0
		}
	}
	return Values
}

; The settings of a parsed config.toml, each invalid entry already read as its
; default (one WARNING each).
; @param Cache {Map} The parsed configuration cache (Map() for the defaults).
; @returns {Map} "idle_timeout_seconds", "terminators", "pointer".
CapsWordAutoOffReadValues(Cache) {
	return Map(
		"idle_timeout_seconds", _CapsWordAutoOffReadIdle(Cache),
		"terminators", _CapsWordAutoOffReadTerminators(Cache),
		"pointer", _CapsWordAutoOffReadPointer(Cache, CapsWordAutoOffPointerKinds()))
}

; Compiles settings that passed the reader. A refusal is a driver defect.
_CapsWordAutoOffCompileValues(Values) {
	Policy := CapsWordAutoOffCompile(Values, CapsWordAutoOffPointerKinds(), &Reason)
	if !(Policy is Map)
		throw Error("CapsWord auto-off settings refused after validation: " . Reason)
	return Policy
}

; Compiles the policy from a parsed config.toml.
; @param Cache {Map} The parsed configuration cache (Map() for the defaults).
; @returns {Map} The compiled policy.
CapsWordAutoOffCompileConfig(Cache) {
	return _CapsWordAutoOffCompileValues(CapsWordAutoOffReadValues(Cache))
}

; Publishes settings for the next activation and logs what they are.
_CapsWordAutoOffPublish(Values, Policy, Verb) {
	CapsWordAutoOff.Values := Values
	CapsWordAutoOff.Configured := Policy
	Delimiters := ""
	for Key in Values["terminators"]
		Delimiters .= (Delimiters == "" ? "" : ",") . Key
	Pointer := ""
	for Kind, On in Policy["pointer"]
		Pointer .= (Pointer == "" ? "" : ",") . Kind . "=" . (On ? "on" : "off")
	LoggerInfo("CapsWord", "Auto-off settings {1}: delay={2} ms, delimiters=[{3}], pointer=[{4}].",
		Verb, Policy["idle_ms"], Delimiters, Pointer)
}

; Reads [shortcuts.caps_word] once at boot; the next activation uses it.
; @param Cache {Map} The parsed configuration cache.
CapsWordAutoOffReadConfig(Cache) {
	Values := CapsWordAutoOffReadValues(Cache)
	_CapsWordAutoOffPublish(Values, _CapsWordAutoOffCompileValues(Values), "read")
}

; The policy an activation arms: the configured one, or the manifest defaults
; when a parse-time key combination activates CapsWord before the config read.
CapsWordAutoOffCurrentPolicy() {
	if CapsWordAutoOff.Configured is Map
		return CapsWordAutoOff.Configured
	LoggerDebug("CapsWord", "Auto-off armed before the configuration read — using the manifest defaults.")
	return CapsWordAutoOffCompileConfig(Map())
}

; A detached copy of the current settings, for the menu's ticks.
; @returns {Map} "idle_timeout_seconds", "terminators", "pointer".
CapsWordAutoOffValues() {
	return ManifestCloneValue(CapsWordAutoOff.Values is Map
		? CapsWordAutoOff.Values : CapsWordAutoOffReadValues(Map()))
}

; Stores one [shortcuts.caps_word] setting and publishes it to the next
; activation, without a reload: no hotkey is registered from these settings.
; An active CapsWord keeps the settings it was armed with.
; @param Path {String} "shortcuts.caps_word.idle_timeout_seconds",
;   "shortcuts.caps_word.terminators" or "shortcuts.caps_word.pointer.<kind>".
; @param Value {Any} The new value, in its stored shape.
; @param ConfigPath {String} config.toml to write; the driver's own when "".
; @returns {Boolean} False when the write was refused (already reported).
CapsWordAutoOffStore(Path, Value, ConfigPath := "") {
	global ConfigurationFile
	Values := CapsWordAutoOffValues()
	if Path == "shortcuts.caps_word.idle_timeout_seconds" || Path == "shortcuts.caps_word.terminators" {
		Values[SubStr(Path, StrLen("shortcuts.caps_word.") + 1)] := ManifestCloneValue(Value)
	} else if InStr(Path, "shortcuts.caps_word.pointer.") == 1 {
		Kind := SubStr(Path, StrLen("shortcuts.caps_word.pointer.") + 1)
		if !Values["pointer"].Has(Kind)
			throw ValueError("No CapsWord pointer kind '" . Kind . "' on this platform.")
		Values["pointer"][Kind] := Value ? 1 : 0
		Value := Value ? true : false
	} else {
		throw ValueError("No CapsWord auto-off setting at '" . Path . "'.")
	}
	Policy := CapsWordAutoOffCompile(Values, CapsWordAutoOffPointerKinds(), &Reason)
	if !(Policy is Map)
		throw ValueError("CapsWord auto-off: '" . Path . "' refused (" . Reason . ").")
	if !ConfigCommitUpdates(ConfigPath != "" ? ConfigPath : ConfigurationFile,
			[ManifestSparseOperation(Path, Value)], "the CapsWord auto-off settings")
		return false
	_CapsWordAutoOffPublish(Values, Policy, "changed (" . Path . ")")
	return true
}





; =======================================
; =======================================
; ======= 2/ Native Event Mapping =======
; =======================================
; =======================================

; HookDispatcher pointer event -> the pointer kind it is. This is the Windows
; adapter's half of the kind list: every kind it names must be declared, and
; every declared kind must be reached (test_capsword_auto_off.ahk).
CapsWordAutoOffPointerEvents() {
	static Events := Map(
		HookDispatcherConst.EVT_MS_LDOWN, "left_click",
		HookDispatcherConst.EVT_MS_RDOWN, "right_click",
		HookDispatcherConst.EVT_MS_MDOWN, "middle_click",
		HookDispatcherConst.EVT_MS_X1DOWN, "other_buttons",
		HookDispatcherConst.EVT_MS_X2DOWN, "other_buttons",
		HookDispatcherConst.EVT_MS_WUP, "pointer_motion",
		HookDispatcherConst.EVT_MS_WDN, "pointer_motion",
		HookDispatcherConst.EVT_MS_WRIGHT, "pointer_motion",
		HookDispatcherConst.EVT_MS_WLEFT, "pointer_motion")
	return Events
}

; The pointer kind the motion poll reports.
CapsWordAutoOffPolledKind() {
	return "pointer_motion"
}

; Stable bound callbacks: HookDispatcher.Unregister compares identities, and a
; static initializer resolves at any time after parse (no include-position
; global), as capsword.ahk's own accessor does.
_CapsWordAutoOffCallbacks() {
	static Bound := _CapsWordAutoOffBindCallbacks()
	return Bound
}

_CapsWordAutoOffBindCallbacks() {
	Bound := Map(
		"char", _CapsWordAutoOff_OnChar.Bind(),
		"key_down", _CapsWordAutoOff_OnKeyDown.Bind(),
		"idle", _CapsWordAutoOff_OnIdle.Bind(),
		"motion", _CapsWordAutoOff_OnMotionPoll.Bind())
	for Event, Kind in CapsWordAutoOffPointerEvents()
		Bound[Event] := _CapsWordAutoOff_OnPointer.Bind(Kind)
	return Bound
}





; =================================
; =================================
; ======= 3/ Arm and Disarm =======
; =================================
; =================================

; Arms the listeners of one active CapsWord.
; @param EndFn {Func} Ends CapsWord; called with the reason and the pointer kind.
CapsWordAutoOffArm(EndFn) {
	if !HasMethod(EndFn, "Call")
		throw TypeError("CapsWordAutoOffArm needs the function that ends CapsWord.")
	CapsWordAutoOffDisarm()
	Policy := CapsWordAutoOffCurrentPolicy()
	Callbacks := _CapsWordAutoOffCallbacks()
	CapsWordAutoOff.Armed := Policy
	CapsWordAutoOff.EndFn := EndFn
	Subscriptions := [[HookDispatcherConst.EVT_KB_CHAR, Callbacks["char"]]]
	if Policy["idle_ms"] > 0
		Subscriptions.Push([HookDispatcherConst.EVT_KB_DOWN, Callbacks["key_down"]])
	for Event, Kind in CapsWordAutoOffPointerEvents() {
		if CapsWordAutoOffEndsOnPointer(Policy, Kind)
			Subscriptions.Push([Event, Callbacks[Event]])
	}
	for Pair in Subscriptions
		HookDispatcher.Register(Pair[1], Pair[2])
	CapsWordAutoOff.Subscriptions := Subscriptions
	if Policy["idle_ms"] > 0 {
		TimerArmOneShotMs(Callbacks["idle"], Policy["idle_ms"])
		CapsWordAutoOff.IdleRunning := true
	}
	if CapsWordAutoOffEndsOnPointer(Policy, CapsWordAutoOffPolledKind()) {
		CapsWordAutoOff.LastPointer := _CapsWordAutoOffPointerPosition()
		SetTimer(Callbacks["motion"], TimingsGet("ui", "capsword_check_interval_ms"))
		CapsWordAutoOff.MotionRunning := true
	}
	LoggerDebug("CapsWord", "Auto-off armed: {1} subscription(s), delay={2} ms, motion poll={3}.",
		Subscriptions.Length, Policy["idle_ms"], CapsWordAutoOff.MotionRunning ? "on" : "off")
}

; Removes every listener of the active CapsWord. Safe when nothing is armed.
CapsWordAutoOffDisarm() {
	if !(CapsWordAutoOff.Armed is Map) && CapsWordAutoOff.Subscriptions.Length == 0
			&& !CapsWordAutoOff.IdleRunning && !CapsWordAutoOff.MotionRunning
		return
	Callbacks := _CapsWordAutoOffCallbacks()
	for Pair in CapsWordAutoOff.Subscriptions
		HookDispatcher.Unregister(Pair[1], Pair[2])
	CapsWordAutoOff.Subscriptions := []
	if CapsWordAutoOff.IdleRunning {
		TimerSetCallback(Callbacks["idle"], 0)
		CapsWordAutoOff.IdleRunning := false
	}
	if CapsWordAutoOff.MotionRunning {
		TimerSetCallback(Callbacks["motion"], 0)
		CapsWordAutoOff.MotionRunning := false
	}
	CapsWordAutoOff.Armed := ""
	CapsWordAutoOff.EndFn := ""
	CapsWordAutoOff.LastPointer := ""
	LoggerDebug("CapsWord", "Auto-off disarmed.")
}

; Whether a key the driver binds itself, typing the delimiter Key, ends the
; active CapsWord. Read from #HotIf criteria (parse-time armed): an inactive or
; not yet armed CapsWord answers false without touching the policy.
; @param Key {String} Built-in delimiter key ("space", "enter", "tab"…).
; @returns {Boolean}
CapsWordAutoOffEndsOnNativeKey(Key) {
	global CapsWordEnabled
	if !IsSet(CapsWordEnabled) || !CapsWordEnabled
		return false
	Policy := CapsWordAutoOff.Armed
	return Policy is Map && CapsWordAutoOffEndsOnKey(Policy, Key)
}





; =================================
; =================================
; ======= 4/ Event Handlers =======
; =================================
; =================================

; Whether an armed listener still speaks for an active CapsWord. A flag cleared
; without DisableCapsWord leaves listeners that disarm themselves here.
_CapsWordAutoOffActive() {
	global CapsWordEnabled
	if !(CapsWordAutoOff.Armed is Map)
		return false
	if IsSet(CapsWordEnabled) && CapsWordEnabled
		return true
	CapsWordAutoOffDisarm()
	return false
}

; Disarms, logs the reason once, and ends CapsWord through its owner.
_CapsWordAutoOffEnd(Reason, Kind := "") {
	EndFn := CapsWordAutoOff.EndFn
	CapsWordAutoOffDisarm()
	LoggerInfo("CapsWord", "CapsWord switched off automatically ({1}).", Reason)
	EndFn.Call(Reason, Kind)
}

; Reports text the driver itself has put on screen: the layout emulation's
; layers, AltGr and dead keys, a hotstring, the magic key or a correction, an
; accepted prediction. Most of it goes out at SendLevel 0 or through
; SendInput, which the auto-off InputHook never sees, so the emitters call this
; where they record their output (the ring of sent characters, TextSend) and a
; checked delimiter in it ends CapsWord as if typed. A temporary edit that the
; ring does not record either (a poke later erased) is never reported.
; @param Text {String} The literal characters that reached the screen.
CapsWordAutoOffObserveOutput(Text) {
	if Type(Text) != "String" || Text == "" || !_CapsWordAutoOffActive()
		return
	if CapsWordAutoOffEndsOnText(CapsWordAutoOff.Armed, Text)
		_CapsWordAutoOffEnd("a delimiter in " . StrLen(Text) . " sent character(s)")
}

; A readable name for a typed delimiter in the log.
_CapsWordAutoOffDescribe(Text) {
	Out := ""
	Loop Parse Text
		Out .= (Out == "" ? "" : " ") . Format("U+{:04X}", Ord(A_LoopField))
	return Out
}

_CapsWordAutoOff_OnChar(Hook, Char) {
	if !_CapsWordAutoOffActive()
		return
	if CapsWordAutoOffEndsOnText(CapsWordAutoOff.Armed, Char)
		_CapsWordAutoOffEnd("delimiter " . _CapsWordAutoOffDescribe(Char))
}

_CapsWordAutoOff_OnKeyDown(Hook, Vk, Sc) {
	if !_CapsWordAutoOffActive() || !CapsWordAutoOff.IdleRunning
		return
	; A keystroke restarts the delay: re-arming the same callback replaces its pending period.
	TimerArmOneShotMs(_CapsWordAutoOffCallbacks()["idle"], CapsWordAutoOff.Armed["idle_ms"])
}

_CapsWordAutoOff_OnIdle() {
	CapsWordAutoOff.IdleRunning := false
	if A_IsSuspended || !_CapsWordAutoOffActive()
		return
	_CapsWordAutoOffEnd("no keystroke for " . CapsWordAutoOff.Armed["idle_ms"] . " ms")
}

_CapsWordAutoOff_OnPointer(Kind, *) {
	if !_CapsWordAutoOffActive()
		return
	_CapsWordAutoOffEnd("pointer " . Kind, Kind)
}

; The pointer position in screen coordinates, as "x,y". CoordMode is
; per-thread, so the poll sets it for itself.
_CapsWordAutoOffPointerPosition() {
	CoordMode("Mouse", "Screen")
	MouseGetPos(&X, &Y)
	return X . "," . Y
}

_CapsWordAutoOff_OnMotionPoll() {
	if A_IsSuspended || !_CapsWordAutoOffActive()
		return
	Position := _CapsWordAutoOffPointerPosition()
	if Position == CapsWordAutoOff.LastPointer
		return
	_CapsWordAutoOffEnd("pointer " . CapsWordAutoOffPolledKind(), CapsWordAutoOffPolledKind())
}
