; adapters/hotkey_registrar.ahk

; ==============================================================================
; MODULE: Hotkey Registrar Adapter (AutoHotkey)
; DESCRIPTION:
; AutoHotkey implementation of the HotkeyRegistrar port contract defined in
; static/ergopti_plus/_shared/core/ports/HotkeyRegistrar.spec.js. Wraps the
; built-in Hotkey() so that "register a system-wide chord" is one call the caller
; can make without knowing that AutoHotkey wants "^+s" rather than a modifier list
; and a key, and without knowing that AutoHotkey hands back no object at all.
;
; FEATURES & RATIONALE:
; 1. Canonical chords only: every chord is parsed by infra/chord.ahk before it is
;    translated, so "shift+ctrl+s" and "Ctrl+Shift+S" produce ONE registration
;    rather than two live bindings that both fire.
; 2. Handles are tokens, not chord strings: AutoHotkey addresses a hotkey by its
;    native spec, so returning the spec would let a caller "unbind" a chord it
;    never bound. A token issued by this adapter can only name a binding this
;    adapter created.
; 3. Refusal is a return value: an unparseable chord never reaches the OS, and a
;    chord AutoHotkey rejects yields an empty handle. A variant already owned by
;    another producer in this AHK process is refused without replacement.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ Native Translation =======
; =====================================
; =====================================

; Canonical modifier → AutoHotkey hotkey-spec prefix. "cmd" maps to the Windows
; key because that is the modifier in the same physical position, which is what
; the shared notation means by it
global HOTKEY_MOD_PREFIXES := Map("cmd", "#", "ctrl", "^", "alt", "!", "shift", "+")

; AutoHotkey accepts modifier prefixes in several orders, but its variant
; registry does not promise that every spelling will keep one physical identity.
; Emit the established metrics order so every producer reaches the same spec.
global HOTKEY_NATIVE_MOD_ORDER := ["ctrl", "alt", "shift", "cmd"]

; Human key aliases which name one physical Windows key. The shared notation is
; deliberately platform-neutral and therefore preserves these spellings; the
; adapter must collapse them before ownership is indexed by native spec.
global HOTKEY_PHYSICAL_KEY_ALIASES := Map(
	"esc", "escape",
	"escape", "escape",
	"return", "enter",
	"enter", "enter",
	"bs", "backspace",
	"backspace", "backspace",
	"del", "delete",
	"delete", "delete",
	"ins", "insert",
	"insert", "insert"
)

; Canonical key name → AutoHotkey Hotkey() key name. Braces belong to Send(),
; not Hotkey(); named keys are bare. Anything absent is passed through unchanged,
; which is correct for letters, digits and punctuation.
global HOTKEY_KEY_NATIVE := Map(
	"space", "space",
	"return", "enter",
	"enter", "enter",
	"tab", "tab",
	"escape", "escape",
	"backspace", "backspace",
	"delete", "delete"
)

; Live bindings keyed by handle token, each holding the native spec and the
; enabled state. The spec never leaves this file, so exactly one code path can
; turn a hotkey off
global HOTKEY_REGISTRAR_BINDINGS := Map()

; Native variants remain addressable after Hotkey(spec, "Off"). Keep a
; spec-indexed tombstone so a later registrar owner can safely replace that
; known inert callback instead of mistaking it for an unknown foreign binding.
global HOTKEY_REGISTRAR_SPECS := Map()

; Monotonic token source. Tokens are never reused, so a handle from a released
; binding stays permanently unknown instead of silently addressing a later one
global HOTKEY_REGISTRAR_NEXT_TOKEN := 0

/**
 * Translates a parsed chord into an AutoHotkey hotkey specification.
 * @param {Array} mods Canonical modifier names.
 * @param {String} key Canonical key.
 * @returns {String} The native spec, e.g. "^+s", or "" when a modifier has no
 *          AutoHotkey equivalent (fn, which no Windows API exposes).
 */
HotkeyRegistrarPhysicalKey(key) {
	global HOTKEY_PHYSICAL_KEY_ALIASES

	if (!IsSet(key) || Type(key) != "String" || key = "")
		return ""
	CanonicalKey := ChordCanonicalKey(key)
	return HOTKEY_PHYSICAL_KEY_ALIASES.Get(StrLower(CanonicalKey), CanonicalKey)
}

HotkeyRegistrarNativeKey(key) {
	global HOTKEY_KEY_NATIVE

	PhysicalKey := HotkeyRegistrarPhysicalKey(key)
	if (PhysicalKey = "")
		return ""
	if HOTKEY_KEY_NATIVE.Has(PhysicalKey)
		return HOTKEY_KEY_NATIVE[PhysicalKey]
	if RegExMatch(PhysicalKey, "^sc[0-9a-f]{3,}$")
		return StrUpper(PhysicalKey)
	return StrLower(PhysicalKey)
}

HotkeyRegistrarNativeSpec(mods, key) {
	global HOTKEY_MOD_PREFIXES, HOTKEY_NATIVE_MOD_ORDER

	if !(mods is Array)
		return ""
	Present := Map()
	for _, RawModName in mods {
		if Type(RawModName) != "String"
			return ""
		ModName := StrLower(RawModName)
		if !HOTKEY_MOD_PREFIXES.Has(ModName)
			return ""
		Present[ModName] := true
	}

	spec := ""
	for _, ModName in HOTKEY_NATIVE_MOD_ORDER {
		if Present.Has(ModName)
			spec .= HOTKEY_MOD_PREFIXES[ModName]
	}

	NativeKey := HotkeyRegistrarNativeKey(key)
	if (NativeKey = "")
		return ""
	return spec . NativeKey
}





; ==================================
; ==================================
; ======= 2/ Adapter Methods =======
; ==================================
; ==================================

/**
 * Registers a system-wide chord against a callback.
 * @param {String} chordString Canonical chord string, e.g. "Ctrl+Shift+S".
 * @param {Func} callback Invoked on each press.
 * @returns {String} An opaque handle, or "" when the chord was refused.
 */
HotkeyRegistrarBind(chordString, callback) {
	return _HotkeyRegistrarBindOwned(chordString, callback, "port")
}

; State objects are immutable after construction. A callback observes either
; the complete old authority or the complete new authority through one Map
; reference read; it can never observe a half-published set of booleans.
_HotkeyRegistrarState(Phase, Dispatch := 0, NativeState := "unknown") {
	return Map("phase", Phase, "dispatch", Dispatch, "native", NativeState)
}

; Internal owner-aware seam. HotkeyFn and ProbeFn are injected only by the
; behavioural suite; public port arity remains exactly bind(chord, callback).
_HotkeyRegistrarBindOwned(chordString, callback, Owner := "anonymous",
		HotkeyFn := 0, ProbeFn := 0, HotIfFn := 0) {
	Handle := _HotkeyRegistrarReserveOwned(chordString, callback, Owner,
		HotkeyFn, ProbeFn, HotIfFn)
	if (Handle = "")
		return ""
	if _HotkeyRegistrarActivate(Handle, HotkeyFn, HotIfFn)
		return Handle
	; Hotkey() is exception-atomic for action-only On: failure leaves native Off.
	; Discard that private reservation before reporting refusal.
	_HotkeyRegistrarAbort(Handle)
	return ""
}

; Internal staging primitive: claim one physical spec and install its wrapper in
; confirmed native Off state. The returned handle is not an active binding until
; _HotkeyRegistrarActivate succeeds, so a durable transaction can prepare it
; without publishing the candidate action early.
_HotkeyRegistrarReserveOwned(chordString, callback, Owner := "anonymous",
		HotkeyFn := 0, ProbeFn := 0, HotIfFn := 0) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN

	if (!IsSet(callback) || !HasMethod(callback, "Call")) {
		LoggerError("adapters.hotkey_registrar", "bind(): callback must be a function.")
		return ""
	}

	parsed := ChordParse(chordString)
	if (!parsed["ok"]) {
		LoggerError("adapters.hotkey_registrar", "bind(): refusing '" . chordString . "' — " . parsed["err"] . ".")
		return ""
	}

	PhysicalKey := HotkeyRegistrarPhysicalKey(parsed["key"])
	spec := HotkeyRegistrarNativeSpec(parsed["mods"], PhysicalKey)
	if (spec = "") {
		LoggerWarn("adapters.hotkey_registrar", "bind(): '" . chordString . "' names a modifier Windows does not expose.")
		return ""
	}
	Formatted := ChordFormat(parsed["mods"], PhysicalKey)
	if !Formatted["ok"] {
		LoggerError("adapters.hotkey_registrar", "bind(): refusing '" . chordString . "' — " . Formatted["err"] . ".")
		return ""
	}
	canonical := Formatted["label"]
	OwnerText := String(Owner)
	ConflictOwner := ""
	KnownTombstone := false
	HadPreviousEntry := false
	PreviousEntry := 0
	entry := 0
	ReserveState := 0
	PreviousCritical := Critical("On")
	try {
		if HOTKEY_REGISTRAR_SPECS.Has(spec) {
			Existing := HOTKEY_REGISTRAR_SPECS[spec]
			ExistingState := Existing["state"]
			if (ExistingState["phase"] != "retired")
				ConflictOwner := Existing["owner"]
			else {
				KnownTombstone := true
				HadPreviousEntry := true
				PreviousEntry := Existing
			}
		}
		if (ConflictOwner = "") {
			HOTKEY_REGISTRAR_NEXT_TOKEN += 1
			handle := "hotkey#" . HOTKEY_REGISTRAR_NEXT_TOKEN
			entry := Map(
				"handle", handle,
				"spec", spec,
				"chord", canonical,
				"owner", OwnerText,
				"callback", callback,
				"state", 0)
			ReserveState := _HotkeyRegistrarState("reserving", 0, "off")
			entry["state"] := ReserveState
			HOTKEY_REGISTRAR_SPECS[spec] := entry
		}
	} finally {
		Critical(PreviousCritical)
	}
	if (ConflictOwner != "") {
		LoggerWarn("adapters.hotkey_registrar", "bind(): refusing '" . canonical
			. "' — owner '" . ConflictOwner . "' already holds it.")
		return ""
	}

	; Unknown native variants are probed after the in-memory claim. Sibling binds
	; now see this reservation, while no Critical span covers the OS call.
	if !KnownTombstone && _HotkeyRegistrarNativeExists(spec, HotkeyFn, ProbeFn,
			HotIfFn) {
		RolledBack := _HotkeyRegistrarRollbackClaim(entry, ReserveState,
			PreviousEntry, HadPreviousEntry)
		_HotkeyRegistrarRequireState(RolledBack,
			"bind(): could not roll back an occupied claim for '" . canonical . "'")
		LoggerWarn("adapters.hotkey_registrar", "bind(): refusing '" . canonical
			. "' — another producer already owns this process variant.")
		return ""
	}

	Wrapper := _HotkeyRegistrarDispatch.Bind(entry)
	try {
		; Supplying a callback with Off creates or replaces the global variant in
		; disabled state. This is the only safe reversible staging primitive.
		_HotkeyRegistrarInvoke(spec, Wrapper, "Off", HotkeyFn, HotIfFn)
	}
	catch as err {
		; AHK v2 Hotkey::Dynamic validates the callback, options and key before
		; mutation, and deletes a partially constructed hotkey on failure.
		RolledBack := _HotkeyRegistrarRollbackClaim(entry, ReserveState,
			PreviousEntry, HadPreviousEntry)
		_HotkeyRegistrarRequireState(RolledBack,
			"bind(): could not roll back refused reserve-Off for '" . canonical . "'")
		LoggerWarn("adapters.hotkey_registrar", "bind(): native reserve-Off refused '"
			. canonical . "' without mutation: " . err.Message . ".")
		return ""
	}
	Published := false
	PreviousCritical := Critical("On")
	try {
		if HOTKEY_REGISTRAR_SPECS.Has(spec)
				&& (HOTKEY_REGISTRAR_SPECS[spec] == entry)
				&& (entry["state"] == ReserveState) {
			entry["state"] := _HotkeyRegistrarState("reserved", 0, "off")
			HOTKEY_REGISTRAR_BINDINGS[handle] := entry
			Published := true
		}
	}
	finally Critical(PreviousCritical)
	if !Published {
		_HotkeyRegistrarRequireState(false,
			"bind(): reserve ownership publication was lost for '" . canonical . "'")
	}
	LoggerDebug("adapters.hotkey_registrar", "Reserved " . canonical . " → " . handle . ".")
	return handle
}

; Enables an inert reservation. Publish callback authority while native is still
; confirmed Off, then call On: this closes the interruptible line boundary after
; Hotkey() returns where the newly active wrapper could otherwise swallow its
; first press. A refusal leaves native Off and restores the inert snapshot.
_HotkeyRegistrarActivate(handle, HotkeyFn := 0, HotIfFn := 0) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS

	if (!IsSet(handle) || Type(handle) != "String")
		return false
	Entry := 0
	PreviousState := 0
	TransitionState := 0
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle)
			return false
		Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
		if !HOTKEY_REGISTRAR_SPECS.Has(Entry["spec"])
				|| (HOTKEY_REGISTRAR_SPECS[Entry["spec"]] != Entry)
			return false
		PreviousState := Entry["state"]
		if (PreviousState["phase"] != "reserved")
			return false
		TransitionState := _HotkeyRegistrarState("enabling", Entry["callback"],
			"off")
		Entry["state"] := TransitionState
	} finally {
		Critical(PreviousCritical)
	}

	try _HotkeyRegistrarInvokeAction(Entry["spec"], "On", HotkeyFn, HotIfFn)
	catch as Err {
		Restored := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
			PreviousState)
		_HotkeyRegistrarRequireState(Restored,
			"activate(): could not restore the exact pre-call state for " . handle)
		LoggerWarn("adapters.hotkey_registrar", "activate(): native On refused '"
			. Entry["chord"] . "' without mutation: " . Err.Message . ".")
		return false
	}

	Published := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
		_HotkeyRegistrarState("active", Entry["callback"], "on"))
	_HotkeyRegistrarRequireState(Published,
		"activate(): ownership changed after native On for " . handle)
	LoggerDebug("adapters.hotkey_registrar", "Activated " . Entry["chord"]
		. " (" . handle . ").")
	return true
}

; Discards an inert reservation without touching the OS: reserve state already
; proves that its native variant is Off.
_HotkeyRegistrarAbort(handle) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS

	if (!IsSet(handle) || Type(handle) != "String")
		return false

	Aborted := false
	Entry := 0
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle) {
			return false
		} else {
			Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
			if !HOTKEY_REGISTRAR_SPECS.Has(Entry["spec"])
					|| (HOTKEY_REGISTRAR_SPECS[Entry["spec"]] != Entry)
				return false
			if (Entry["state"]["phase"] != "reserved")
				return false
			Entry["state"] := _HotkeyRegistrarState("retired", 0, "off")
			HOTKEY_REGISTRAR_BINDINGS.Delete(handle)
			Aborted := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	if Aborted
		LoggerDebug("adapters.hotkey_registrar", "Aborted reserved "
			. Entry["chord"] . " (" . handle . ").")
	return Aborted
}

; Every operation intentionally selects the unconditional global HotIf variant.
; HotIf is thread-local default state inherited by newly launched threads; an
; adapter call made from a contextual hotkey would otherwise probe or mutate a
; different variant. The adapter deliberately leaves the caller in global
; context after returning so later raw Hotkey calls cannot inherit stale policy.
_HotkeyRegistrarSelectGlobalContext(HotIfFn := 0) {
	if HasMethod(HotIfFn, "Call")
		return HotIfFn.Call()
	return HotIf()
}

_HotkeyRegistrarInvoke(Name, Callback, Options, HotkeyFn := 0, HotIfFn := 0) {
	_HotkeyRegistrarSelectGlobalContext(HotIfFn)
	if HasMethod(HotkeyFn, "Call")
		return HotkeyFn.Call(Name, Callback, Options)
	return Hotkey(Name, Callback, Options)
}

_HotkeyRegistrarInvokeAction(Name, Action, HotkeyFn := 0, HotIfFn := 0) {
	_HotkeyRegistrarSelectGlobalContext(HotIfFn)
	if HasMethod(HotkeyFn, "Call")
		return HotkeyFn.Call(Name, Action)
	return Hotkey(Name, Action)
}

_HotkeyRegistrarNativeExists(Name, HotkeyFn := 0, ProbeFn := 0, HotIfFn := 0) {
	try _HotkeyRegistrarSelectGlobalContext(HotIfFn)
	catch as Err {
		try LoggerWarn("adapters.hotkey_registrar",
			"Could not select the global HotIf context for '{1}': {2}; treating it as occupied.",
			Name, Err.Message)
		return true
	}
	if HasMethod(ProbeFn, "Call") {
		try return ProbeFn.Call(Name) ? true : false
		catch as Err {
			try LoggerWarn("adapters.hotkey_registrar",
				"Could not probe native variant '{1}': {2}; treating it as occupied.",
				Name, Err.Message)
			return true
		}
	}
	; This probes variants in this AHK process only. Another process holding the
	; OS registration is not observable here because AHK may transparently fall
	; back to its keyboard hook. Never claim cross-process conflict detection.
	; Never let an injected seam fall through into the live process registry.
	if HasMethod(HotkeyFn, "Call")
		return false
	try {
		Hotkey(Name)
		return true
	} catch as Err {
		if (Err is TargetError)
			return false
		try LoggerWarn("adapters.hotkey_registrar",
			"Could not probe native variant '{1}': {2}; treating it as occupied.",
			Name, Err.Message)
		return true
	}
}

; A failed identity revalidation after a non-yielding native call means internal
; ownership corruption, not an ordinary user-level refusal. Continuing would
; strand an enabled native key or a transient handle, so fail fast.
_HotkeyRegistrarRequireState(Condition, Detail) {
	if Condition
		return true
	try LoggerError("adapters.hotkey_registrar", Detail . ".")
	throw Error(Detail)
}

_HotkeyRegistrarDispatch(Entry, Args*) {
	Snapshot := Entry["state"]
	Callback := Snapshot["dispatch"]
	if HasMethod(Callback, "Call")
		; The shared port is deliberately transport-agnostic: AHK's HotkeyName and
		; modifier arguments are native details and must not reach public callbacks.
		Callback.Call()
}

; Restores the exact prior tombstone after an exception-atomic reserve refusal.
; A new spec had no previous entry and is removed; a reusable disabled variant
; regains its former identity. No native compensation is needed or permitted.
_HotkeyRegistrarRollbackClaim(Entry, ExpectedState, PreviousEntry,
		HadPreviousEntry) {
	global HOTKEY_REGISTRAR_SPECS
	RolledBack := false
	PreviousCritical := Critical("On")
	try {
		Spec := Entry["spec"]
		if HOTKEY_REGISTRAR_SPECS.Has(Spec)
				&& (HOTKEY_REGISTRAR_SPECS[Spec] == Entry)
				&& (Entry["state"] == ExpectedState) {
			Entry["state"] := _HotkeyRegistrarState("retired", 0, "off")
			if HadPreviousEntry
				HOTKEY_REGISTRAR_SPECS[Spec] := PreviousEntry
			else
				HOTKEY_REGISTRAR_SPECS.Delete(Spec)
			RolledBack := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	return RolledBack
}

_HotkeyRegistrarPublishLiveState(Entry, ExpectedState, NextState,
		RetireHandle := false) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS

	Published := false
	PreviousCritical := Critical("On")
	try {
		Handle := Entry["handle"]
		Spec := Entry["spec"]
		if HOTKEY_REGISTRAR_BINDINGS.Has(Handle)
				&& (HOTKEY_REGISTRAR_BINDINGS[Handle] == Entry)
				&& HOTKEY_REGISTRAR_SPECS.Has(Spec)
				&& (HOTKEY_REGISTRAR_SPECS[Spec] == Entry)
				&& (Entry["state"] == ExpectedState) {
			Entry["state"] := NextState
			if RetireHandle
				HOTKEY_REGISTRAR_BINDINGS.Delete(Handle)
			Published := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	return Published
}

/**
 * Releases a binding.
 * @param {String} handle A handle previously returned by HotkeyRegistrarBind.
 * @returns {Boolean} true if a live binding was released, false otherwise.
 */
HotkeyRegistrarUnbind(handle) {
	return _HotkeyRegistrarRetire(handle)
}

_HotkeyRegistrarRetire(handle, HotkeyFn := 0, HotIfFn := 0) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS

	if (!IsSet(handle) || Type(handle) != "String") {
		; Not an error: teardown paths unbind defensively and a second call must
		; report "nothing to do" rather than raise mid-reload
		return false
	}

	Entry := 0
	PreviousState := 0
	TransitionState := 0
	RetiredWithoutNative := false
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle)
			return false
		Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
		Snapshot := Entry["state"]
		PreviousState := Snapshot
		Phase := Snapshot["phase"]
		if (Phase = "disabled" || Phase = "reserved") {
			Entry["state"] := _HotkeyRegistrarState("retired", 0, "off")
			HOTKEY_REGISTRAR_BINDINGS.Delete(handle)
			RetiredWithoutNative := true
		} else if (Phase = "active") {
			TransitionState := _HotkeyRegistrarState("retiring",
				Entry["callback"], "on")
			Entry["state"] := TransitionState
		} else {
			return false
		}
	} finally {
		Critical(PreviousCritical)
	}
	if RetiredWithoutNative {
		LoggerDebug("adapters.hotkey_registrar", "Released " . Entry["chord"] . " (" . handle . ").")
		return true
	}

	try _HotkeyRegistrarInvokeAction(Entry["spec"], "Off", HotkeyFn, HotIfFn)
	catch as Err {
		Restored := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
			PreviousState)
		_HotkeyRegistrarRequireState(Restored,
			"unbind(): could not restore the exact pre-call state for " . handle)
		LoggerWarn("adapters.hotkey_registrar", "unbind(): native Off refused '"
			. Entry["chord"] . "' without mutation: " . Err.Message . ".")
		return false
	}

	Published := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
		_HotkeyRegistrarState("retired", 0, "off"), true)
	_HotkeyRegistrarRequireState(Published,
		"unbind(): ownership changed after native Off for " . handle)
	LoggerDebug("adapters.hotkey_registrar", "Released " . Entry["chord"]
		. " (" . handle . ").")
	return true
}

/**
 * Suspends or resumes a binding without releasing it.
 * @param {String} handle A handle previously returned by HotkeyRegistrarBind.
 * @param {Boolean} enabled Desired state.
 * @returns {Boolean} true if the handle now holds the requested state.
 */
HotkeyRegistrarSetEnabled(handle, enabled) {
	return _HotkeyRegistrarSetEnabled(handle, enabled)
}

_HotkeyRegistrarSetEnabled(handle, enabled, HotkeyFn := 0, HotIfFn := 0) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS

	if (!IsSet(handle) || Type(handle) != "String") {
		return false
	}
	want := enabled ? true : false
	Entry := 0
	PreviousState := 0
	TransitionState := 0
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle)
			return false
		Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
		PreviousState := Entry["state"]
		Phase := PreviousState["phase"]
		if ((Phase = "active" && want) || (Phase = "disabled" && !want))
			return true
		if (Phase != "active" && Phase != "disabled")
			return false
		; On is exception-atomic and native remains Off until it succeeds. Expose
		; callback authority first so the first interrupt after On cannot be lost.
		; For Off, retain prior authority until native suppression is gone.
		TransitionState := _HotkeyRegistrarState(want ? "enabling" : "disabling",
			Entry["callback"], PreviousState["native"])
		Entry["state"] := TransitionState
	} finally {
		Critical(PreviousCritical)
	}
	try _HotkeyRegistrarInvokeAction(Entry["spec"], want ? "On" : "Off",
		HotkeyFn, HotIfFn)
	catch as Err {
		Restored := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
			PreviousState)
		_HotkeyRegistrarRequireState(Restored,
			"setEnabled(): could not restore the exact pre-call state for " . handle)
		LoggerWarn("adapters.hotkey_registrar", "setEnabled(): native "
			. (want ? "On" : "Off") . " refused '" . Entry["chord"]
			. "' without mutation: " . Err.Message . ".")
		return false
	}

	NextState := want
		? _HotkeyRegistrarState("active", Entry["callback"], "on")
		: _HotkeyRegistrarState("disabled", 0, "off")
	Published := _HotkeyRegistrarPublishLiveState(Entry, TransitionState, NextState)
	_HotkeyRegistrarRequireState(Published,
		"setEnabled(): ownership changed after native "
		. (want ? "On" : "Off") . " for " . handle)
	LoggerDebug("adapters.hotkey_registrar", Entry["chord"] . " enabled="
		. (want ? "true" : "false") . ".")
	return true
}





; ================================
; ================================
; ======= 3/ Introspection =======
; ================================
; ================================

/**
 * Reports the canonical chord a handle is bound to.
 * Exists so the menu can label a binding without holding the chord string it
 * passed in, which may have been in any accepted spelling.
 * @param {String} handle
 * @returns {String} The canonical chord, or "" when the handle is unknown.
 */
HotkeyRegistrarChordOf(handle) {
	global HOTKEY_REGISTRAR_BINDINGS

	; Parse-time #HotIf helpers may query a retained binding during Bundle_Init's
	; first message pump, before this adapter's registry assignment executes.
	if (!IsSet(HOTKEY_REGISTRAR_BINDINGS)
			|| !IsSet(handle) || Type(handle) != "String")
		return ""
	Chord := ""
	PreviousCritical := Critical("On")
	try {
		; Has()+index must be one atomic snapshot: an unbind callback can otherwise
		; delete the handle after Has() and make the index operation throw.
		if HOTKEY_REGISTRAR_BINDINGS.Has(handle) {
			Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
			Chord := Entry["chord"]
		}
	} finally {
		Critical(PreviousCritical)
	}
	return Chord
}

/**
 * Reports how many bindings this adapter currently holds.
 * A leak here is invisible in the UI — the hotkeys keep firing — so the count is
 * exposed for the suite to assert against after a stop/start cycle.
 * @returns {Integer}
 */
HotkeyRegistrarLiveCount() {
	global HOTKEY_REGISTRAR_BINDINGS

	PreviousCritical := Critical("On")
	try Count := HOTKEY_REGISTRAR_BINDINGS.Count
	finally Critical(PreviousCritical)
	return Count
}





; ====================================
; ====================================
; ======= 4/ Port Dispatch Map =======
; ====================================
; ====================================

; The dispatch map the port-compliance gate parses. Its keys must be exactly the
; contract's method names, which is what lets a rename in the spec fail here
; instead of at runtime on a user's machine
global ADAPTER_HOTKEY_REGISTRAR := Map(
	"bind", HotkeyRegistrarBind,
	"unbind", HotkeyRegistrarUnbind,
	"setEnabled", HotkeyRegistrarSetEnabled
)
