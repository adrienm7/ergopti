; modules/shortcuts/capsword_auto_off.ahk

; ==============================================================================
; MODULE: Shortcuts — CapsWord Auto-Off
; DESCRIPTION:
; Ends CapsWord on its own, as [shortcuts.caps_word] says: after a delay
; without a keystroke, on a checked word delimiter, and on a checked pointer
; kind. The decisions are the shared policy's
; (_shared/settings/data/features/caps_word_auto_off_policy.ahk); this module reads
; the settings, maps Windows events to the policy's questions, and owns every
; subscription and timer of one active CapsWord.
;
; FEATURES & RATIONALE:
; 1. Armed per Activation: ToggleCapsWord arms the listeners with the policy of
;    that moment and DisableCapsWord disarms them, so nothing listens while
;    CapsWord is off. A menu change re-arms an active CapsWord with the new
;    policy, so it applies from the next event, as on macOS and Linux. Every handler also checks CapsWordEnabled first: a path
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
; 5. Fixed Exits and Activity: Escape, Delete, the arrows, Home/End, Page
;    Up/Down and F1-F12 always end CapsWord, and a modifier pressed alone is no
;    keystroke for the delay, as on macOS (decision of 2026-11-06). The names
;    are the shared policy's FIXED_EXIT_KEYS (_shared/keyboard/engine/caps_word_auto_off.lua),
;    pinned by tools/test/test-capsword-fixed-exits-single-source.cjs.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk




; The armed state of the one CapsWord this process can have.
class CapsWordAutoOff {
	; Policy compiled from config.toml, "" until CapsWordAutoOffReadConfig runs.
	static Configured := ""
	; The settings Configured was compiled from, "" until then.
	static Values := ""
	; Policy of the active CapsWord, "" while disarmed.
	static Armed := ""
	; Monotonic authority: a retired callback cannot borrow a later activation.
	static Generation := 0
	; Callback identities retained for this activation and its exact cleanup.
	static Callbacks := Map()
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

; Virtual-key code -> shared fixed-exit name (FIXED_EXIT_KEYS).
global CAPSWORD_FIXED_EXIT_VKS := Map(
	0x1B, "escape", 0x2E, "delete", 0x26, "up", 0x28, "down", 0x25, "left", 0x27, "right",
	0x24, "home", 0x23, "end", 0x21, "page_up", 0x22, "page_down",
	0x70, "f1", 0x71, "f2", 0x72, "f3", 0x73, "f4", 0x74, "f5", 0x75, "f6",
	0x76, "f7", 0x77, "f8", 0x78, "f9", 0x79, "f10", 0x7A, "f11", 0x7B, "f12")

; Modifier virtual-key codes: pressed alone they are no keystroke for the delay.
global CAPSWORD_MODIFIER_VKS := Map(
	0x10, true, 0x11, true, 0x12, true, 0xA0, true, 0xA1, true, 0xA2, true,
	0xA3, true, 0xA4, true, 0xA5, true, 0x5B, true, 0x5C, true)

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

; The shared policy admits finite seconds; Windows can arm only its native
; timer domain. Zero alone disables the timer; a smaller positive duration
; still receives the native minimum one millisecond.
_CapsWordAutoOffNativeIdleMs(Seconds, &Reason := "") {
	if !CapsWordAutoOffValidateIdleTimeout(Seconds, &Reason)
		return ""
	if Seconds == 0
		return 0
	Milliseconds := TimerDelayMsFromSeconds(Seconds)
	if Milliseconds is Number {
		try {
			TimerRequireDelayMs(Milliseconds, "CapsWord auto-off")
			return Max(1, Round(Milliseconds))
		} catch ValueError {
			; An unsupported native period is refused before publication.
		}
	}
	Reason := "invalid_idle_timeout"
	return ""
}

; Validates the Windows period before the shared compiler's arithmetic, then
; retains the portable delimiter/pointer policy with the admitted native delay.
_CapsWordAutoOffCompileNativePolicy(Values, &Reason := "") {
	Delay := _CapsWordAutoOffNativeIdleMs(Values.Get(ConfigLeaf.IDLE_TIMEOUT_SECONDS, ""), &Reason)
	if !(Delay is Number)
		return ""
	Policy := CapsWordAutoOffCompile(Values, CapsWordAutoOffPointerKinds(), &Reason)
	if Policy is Map
		Policy["idle_ms"] := Delay
	return Policy
}

; The stored delay, or its default when absent or not a native timer duration.
_CapsWordAutoOffReadIdle(Cache, Snapshot := 0) {
	Default := ManifestDefaultFor(ConfigKey.SHORTCUTS_CAPS_WORD_IDLE_TIMEOUT_SECONDS)
	Raw := IniCacheGet(Cache, ConfigKey.SHORTCUTS_CAPS_WORD, ConfigLeaf.IDLE_TIMEOUT_SECONDS)
	if IsObject(Snapshot)
		ConfigTomlBootSnapshotValue(Snapshot, ConfigKey.SHORTCUTS_CAPS_WORD, ConfigLeaf.IDLE_TIMEOUT_SECONDS, &Raw)
	if Raw == "_"
		return Default
	if _CapsWordAutoOffNativeIdleMs(Raw) is Number
		return Raw
	LoggerWarn("CapsWord", "shortcuts.caps_word.idle_timeout_seconds '{1}' is not a supported native inactivity delay — using {2} s.",
		Raw is Object ? Type(Raw) : String(Raw), Default)
	return Default
}

; The stored delimiter list. An entry the catalogue no longer knows, or a
; repeated one, is outdated configuration: one WARNING each, the rest kept.
_CapsWordAutoOffReadTerminators(Cache) {
	Default := ManifestDefaultFor("shortcuts.caps_word.terminators")
	Raw := IniCacheGet(Cache, ConfigKey.SHORTCUTS_CAPS_WORD, "terminators")
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
_CapsWordAutoOffReadPointer(Cache, Kinds, Snapshot := 0) {
	Values := Map()
	for Kind in Kinds {
		Path := "shortcuts.caps_word.pointer." . Kind
		Raw := IniCacheGet(Cache, "shortcuts.caps_word.pointer", Kind)
		if IsObject(Snapshot)
			ConfigTomlBootSnapshotValue(Snapshot, "shortcuts.caps_word.pointer", Kind, &Raw)
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
	; Read the admitted source once for all leaves: native booleans have lost
	; their type distinction from integers in the compatibility cache.
	Snapshot := ConfigTomlBootSnapshot(Cache)
	return Map(
		ConfigLeaf.IDLE_TIMEOUT_SECONDS, _CapsWordAutoOffReadIdle(Cache, Snapshot),
		"terminators", _CapsWordAutoOffReadTerminators(Cache),
		"pointer", _CapsWordAutoOffReadPointer(Cache, CapsWordAutoOffPointerKinds(), Snapshot))
}

; Compiles settings that passed the reader. A refusal is a driver defect.
_CapsWordAutoOffCompileValues(Values) {
	Policy := _CapsWordAutoOffCompileNativePolicy(Values, &Reason)
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
	_CapsWordAutoOffLog(Values, Policy, Verb)
}

_CapsWordAutoOffLog(Values, Policy, Verb) {
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

; Stores one [shortcuts.caps_word] setting and publishes it without a reload:
; no hotkey is registered from these settings. An active CapsWord is re-armed
; with the new policy, so the change applies from its next event (decision of
; 2026-11-06, as on macOS and Linux) and its delay restarts from the change.
; @param Path {String} "shortcuts.caps_word.idle_timeout_seconds",
;   "shortcuts.caps_word.terminators" or "shortcuts.caps_word.pointer.<kind>".
; @param Value {Any} The new value, in its stored shape.
; @param ConfigPath {String} config.toml to write; the driver's own when "".
; @returns {Boolean} False when the write was refused (already reported).
CapsWordAutoOffStore(Path, Value, ConfigPath := "") {
	global ConfigurationFile
	; Validate only the requested setting against defaults before entering the
	; gateway, preserving invalid-input exceptions without capturing live state.
	_CapsWordAutoOffPrepareStore(Path, Value, CapsWordAutoOffReadValues(Map()))
	Outcome := {candidate: 0}
	Saved := ConfigCommitBuilt(ConfigPath != "" ? ConfigPath : ConfigurationFile,
		"the CapsWord auto-off settings", _CapsWordAutoOffBuildStore.Bind(Path, Value, Outcome))
	if Saved {
		; Logging describes this acknowledged commit after its owner has retired;
		; failure to log cannot turn a durable memory publication into a refusal.
		try _CapsWordAutoOffLog(Outcome.candidate.values, Outcome.candidate.policy, "changed (" . Path . ")")
		_CapsWordAutoOffRearmActive()
	}
	return Saved
}

; Re-arms the active CapsWord with the published policy: its subscriptions,
; idle timer and motion poll then follow the new settings. Runs after the
; configuration owner has retired, so it reads the latest acknowledged policy.
; @returns {Boolean} True when an active CapsWord was re-armed.
_CapsWordAutoOffRearmActive() {
	global CapsWordEnabled
	if !(CapsWordAutoOff.Armed is Map) || !IsSet(CapsWordEnabled) || !CapsWordEnabled
		return false
	EndFn := CapsWordAutoOff.EndFn
	if !HasMethod(EndFn, "Call")
		throw Error("CapsWord auto-off: an armed CapsWord has no end function.")
	return CapsWordAutoOffArm(EndFn)
}

; The detached next-activation policy is captured and published while the same
; configuration owner retains the path, so another menu commit cannot be lost.
_CapsWordAutoOffBuildStore(Path, Value, Outcome) {
	Candidate := _CapsWordAutoOffPrepareStore(Path, Value, CapsWordAutoOffValues())
	Outcome.candidate := Candidate
	return {
		updates: [ManifestSparseOperation(Path, Candidate.value)],
		publish: _CapsWordAutoOffPublishStore.Bind(Candidate.values, Candidate.policy),
	}
}

_CapsWordAutoOffPrepareStore(Path, Value, Values) {
	if Path == ConfigKey.SHORTCUTS_CAPS_WORD_IDLE_TIMEOUT_SECONDS || Path == "shortcuts.caps_word.terminators" {
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
	Policy := _CapsWordAutoOffCompileNativePolicy(Values, &Reason)
	if !(Policy is Map)
		throw ValueError("CapsWord auto-off: '" . Path . "' refused (" . Reason . ").")
	return {values: Values, policy: Policy, value: Value}
}

_CapsWordAutoOffPublishStore(Values, Policy) {
	CapsWordAutoOff.Values := Values
	CapsWordAutoOff.Configured := Policy
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

; Each activation owns distinct bound callbacks. HookDispatcher may already
; hold a snapshot when its old subscriptions are removed. The class fields are
; initialized on first access, including before this file's include position.
_CapsWordAutoOffCallbacks() {
	return CapsWordAutoOff.Callbacks
}

_CapsWordAutoOffBindCallbacks(Generation) {
	Bound := Map(
		"char", _CapsWordAutoOff_OnChar.Bind(Generation),
		"key_down", _CapsWordAutoOff_OnKeyDown.Bind(Generation),
		"idle", _CapsWordAutoOff_OnIdle.Bind(Generation),
		"motion", _CapsWordAutoOff_OnMotionPoll.Bind(Generation))
	for Event, Kind in CapsWordAutoOffPointerEvents()
		Bound[Event] := _CapsWordAutoOff_OnPointer.Bind(Generation, Kind)
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
	global CapsWordEnabled
	if !HasMethod(EndFn, "Call")
		throw TypeError("CapsWordAutoOffArm needs the function that ends CapsWord.")
	Generation := CapsWordAutoOffDisarm()
	Policy := CapsWordAutoOffCurrentPolicy()
	Callbacks := _CapsWordAutoOffBindCallbacks(Generation)
	; Key-downs always: the fixed exits end CapsWord even without a delay.
	Subscriptions := [[HookDispatcherConst.EVT_KB_CHAR, Callbacks["char"]],
		[HookDispatcherConst.EVT_KB_DOWN, Callbacks["key_down"]]]
	for Event, Kind in CapsWordAutoOffPointerEvents() {
		if CapsWordAutoOffEndsOnPointer(Policy, Kind)
			Subscriptions.Push([Event, Callbacks[Event]])
	}
	Motion := CapsWordAutoOffEndsOnPointer(Policy, CapsWordAutoOffPolledKind())
	Position := Motion ? _CapsWordAutoOffPointerPosition() : ""
	PreviousCritical := Critical("On")
	try {
		if Generation != CapsWordAutoOff.Generation || !IsSet(CapsWordEnabled) || !CapsWordEnabled
			return false
		CapsWordAutoOff.Armed := Policy
		CapsWordAutoOff.EndFn := EndFn
		CapsWordAutoOff.Callbacks := Callbacks
		CapsWordAutoOff.Subscriptions := Subscriptions
		for Pair in Subscriptions
			HookDispatcher.Register(Pair[1], Pair[2])
		if Policy["idle_ms"] > 0 {
			TimerArmOneShotMs(Callbacks["idle"], Policy["idle_ms"])
			CapsWordAutoOff.IdleRunning := true
		}
		if Motion {
			CapsWordAutoOff.LastPointer := Position
			SetTimer(Callbacks["motion"], TimingsGet("ui", "capsword_check_interval_ms"))
			CapsWordAutoOff.MotionRunning := true
		}
	} finally Critical(PreviousCritical)
	LoggerDebug("CapsWord", "Auto-off armed: {1} subscription(s), delay={2} ms, motion poll={3}.",
		Subscriptions.Length, Policy["idle_ms"], Motion ? "on" : "off")
	return true
}

; Detach authority before unregistering or logging. Cleanup uses only callbacks
; of the retired activation, so an interruption cannot cancel its successor.
; @param ExpectedGeneration {Integer} Optional originating callback authority.
; @returns {Integer|Boolean} Retirement generation, or false for an old callback.
CapsWordAutoOffDisarm(ExpectedGeneration := unset) {
	PreviousCritical := Critical("On")
	try {
		if IsSet(ExpectedGeneration) && ExpectedGeneration != CapsWordAutoOff.Generation
			return false
		Generation := ++CapsWordAutoOff.Generation
		Callbacks := _CapsWordAutoOffCallbacks()
		Subscriptions := CapsWordAutoOff.Subscriptions
		Idle := CapsWordAutoOff.IdleRunning, Motion := CapsWordAutoOff.MotionRunning
		HadOwner := CapsWordAutoOff.Armed is Map
		CapsWordAutoOff.Subscriptions := []
		CapsWordAutoOff.IdleRunning := false
		CapsWordAutoOff.MotionRunning := false
		CapsWordAutoOff.Armed := ""
		CapsWordAutoOff.EndFn := ""
		CapsWordAutoOff.LastPointer := ""
	} finally Critical(PreviousCritical)
	for Pair in Subscriptions
		HookDispatcher.Unregister(Pair[1], Pair[2])
	if Idle
		TimerSetCallback(Callbacks["idle"], 0)
	if Motion
		TimerSetCallback(Callbacks["motion"], 0)
	if HadOwner || Subscriptions.Length || Idle || Motion
		LoggerDebug("CapsWord", "Auto-off disarmed.")
	return Generation
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

/**
 * Sends the native CapsWord delimiter and retires only its original activation.
 * Space keeps its bounded release wait; neither the send nor wait is Critical.
 * @param Key {String} Space or Enter, selected by the native hotkey.
 * @param SendFn {Func} TextPressKey boundary; tests retain it without OS output.
 * @param WaitFn {Func} KeyWait boundary; tests control the pending release.
 */
CapsWordAutoOffNativeKey(Key, SendFn := TextPressKey, WaitFn := KeyWait) {
	global STUCK_MODIFIER_RELEASE_TIMEOUT_SEC
	Generation := CapsWordAutoOff.Generation
	try {
		SendFn.Call(Key, [])
		if Key == "Space"
			WaitFn.Call("SC039", "T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		_CapsWordAutoOffEnd(Generation, "native " . Key)
	}
}

; Whether an armed listener still speaks for an active CapsWord. A flag cleared
; without DisableCapsWord leaves listeners that disarm themselves here.
_CapsWordAutoOffActive(Generation) {
	global CapsWordEnabled
	if Generation != CapsWordAutoOff.Generation || !(CapsWordAutoOff.Armed is Map)
		return false
	if IsSet(CapsWordEnabled) && CapsWordEnabled
		return true
	CapsWordAutoOffDisarm(Generation)
	return false
}

; Disarms, logs the reason once, and ends CapsWord through its owner.
_CapsWordAutoOffEnd(Generation, Reason, Kind := "") {
	if !_CapsWordAutoOffActive(Generation)
		return
	EndFn := CapsWordAutoOff.EndFn
	Retired := CapsWordAutoOffDisarm(Generation)
	if !Retired
		return
	LoggerInfo("CapsWord", "CapsWord switched off automatically ({1}).", Reason)
	PreviousCritical := Critical("On")
	try {
		; The terminal callback clears CapsWordEnabled. Keep its authority check
		; and that publication together; a new activation must survive old logs.
		if CapsWordAutoOff.Generation == Retired
			EndFn.Call(Reason, Kind)
	} finally Critical(PreviousCritical)
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
	Generation := CapsWordAutoOff.Generation
	if Type(Text) != "String" || Text == "" || !_CapsWordAutoOffActive(Generation)
		return
	if CapsWordAutoOffEndsOnText(CapsWordAutoOff.Armed, Text)
		_CapsWordAutoOffEnd(Generation, "a delimiter in " . StrLen(Text) . " sent character(s)")
}

; A readable name for a typed delimiter in the log.
_CapsWordAutoOffDescribe(Text) {
	Out := ""
	Loop Parse Text
		Out .= (Out == "" ? "" : " ") . Format("U+{:04X}", Ord(A_LoopField))
	return Out
}

_CapsWordAutoOff_OnChar(Generation, Hook, Char) {
	if !_CapsWordAutoOffActive(Generation)
		return
	if CapsWordAutoOffEndsOnText(CapsWordAutoOff.Armed, Char)
		_CapsWordAutoOffEnd(Generation, "delimiter " . _CapsWordAutoOffDescribe(Char))
}

_CapsWordAutoOff_OnKeyDown(Generation, Hook, Vk, Sc) {
	global CAPSWORD_FIXED_EXIT_VKS, CAPSWORD_MODIFIER_VKS
	if !_CapsWordAutoOffActive(Generation)
		return
	if CAPSWORD_FIXED_EXIT_VKS.Has(Vk) {
		_CapsWordAutoOffEnd(Generation, "editing key " . CAPSWORD_FIXED_EXIT_VKS[Vk])
		return
	}
	if CAPSWORD_MODIFIER_VKS.Has(Vk) || !CapsWordAutoOff.IdleRunning
		return
	; A keystroke restarts the delay; the timer adapter replaces its pending period.
	PreviousCritical := Critical("On")
	try {
		if Generation == CapsWordAutoOff.Generation && CapsWordAutoOff.Armed is Map
			TimerArmOneShotMs(_CapsWordAutoOffCallbacks()["idle"], CapsWordAutoOff.Armed["idle_ms"])
	} finally Critical(PreviousCritical)
}

_CapsWordAutoOff_OnIdle(Generation) {
	PreviousCritical := Critical("On")
	try {
		if Generation != CapsWordAutoOff.Generation
			return
		CapsWordAutoOff.IdleRunning := false
	} finally Critical(PreviousCritical)
	if A_IsSuspended || !_CapsWordAutoOffActive(Generation)
		return
	_CapsWordAutoOffEnd(Generation, "no keystroke for " . CapsWordAutoOff.Armed["idle_ms"] . " ms")
}

_CapsWordAutoOff_OnPointer(Generation, Kind, *) {
	if !_CapsWordAutoOffActive(Generation)
		return
	_CapsWordAutoOffEnd(Generation, "pointer " . Kind, Kind)
}

; The pointer position in screen coordinates, as "x,y". CoordMode is
; per-thread, so the poll sets it for itself.
_CapsWordAutoOffPointerPosition() {
	CoordMode("Mouse", "Screen")
	MouseGetPos(&X, &Y)
	return X . "," . Y
}

_CapsWordAutoOff_OnMotionPoll(Generation) {
	if A_IsSuspended || !_CapsWordAutoOffActive(Generation)
		return
	Position := _CapsWordAutoOffPointerPosition()
	if Position == CapsWordAutoOff.LastPointer
		return
	_CapsWordAutoOffEnd(Generation, "pointer " . CapsWordAutoOffPolledKind(), CapsWordAutoOffPolledKind())
}
