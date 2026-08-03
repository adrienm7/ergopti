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
;    chord AutoHotkey rejects yields an empty handle. A hotkey another program has
;    already claimed is an ordinary fact the menu must be able to display.
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

; Canonical key name → AutoHotkey key name, for the keys AutoHotkey spells with
; braces or in upper case. Anything absent is passed through unchanged, which is
; correct for letters, digits and punctuation
global HOTKEY_KEY_NATIVE := Map(
	"space", "{Space}",
	"return", "{Enter}",
	"enter", "{Enter}",
	"tab", "{Tab}",
	"escape", "{Escape}",
	"backspace", "{Backspace}",
	"delete", "{Delete}"
)

; Live bindings keyed by handle token, each holding the native spec and the
; enabled state. The spec never leaves this file, so exactly one code path can
; turn a hotkey off
global HOTKEY_REGISTRAR_BINDINGS := Map()

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
HotkeyRegistrarNativeSpec(mods, key) {
	global HOTKEY_MOD_PREFIXES, HOTKEY_KEY_NATIVE

	spec := ""
	for _, modName in mods {
		if (!HOTKEY_MOD_PREFIXES.Has(modName)) {
			return ""
		}
		spec .= HOTKEY_MOD_PREFIXES[modName]
	}

	if (HOTKEY_KEY_NATIVE.Has(key)) {
		return spec . HOTKEY_KEY_NATIVE[key]
	}
	; Scan codes are the one key spelling AutoHotkey wants in upper case; the
	; notation core lower-cases every multi-character key name, so "sc029" arrives
	; here and would silently bind nothing without this
	if (RegExMatch(key, "^sc[0-9a-f]{3,}$")) {
		return spec . StrUpper(key)
	}
	return spec . StrLower(key)
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
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_NEXT_TOKEN

	if (!IsSet(callback) || !(callback is Func)) {
		LoggerError("adapters.hotkey_registrar", "bind(): callback must be a function.")
		return ""
	}

	parsed := ChordParse(chordString)
	if (!parsed["ok"]) {
		LoggerError("adapters.hotkey_registrar", "bind(): refusing '" . chordString . "' — " . parsed["err"] . ".")
		return ""
	}

	spec := HotkeyRegistrarNativeSpec(parsed["mods"], parsed["key"])
	if (spec = "") {
		LoggerWarn("adapters.hotkey_registrar", "bind(): '" . chordString . "' names a modifier Windows does not expose.")
		return ""
	}

	; "On" is explicit rather than implied so a chord that was previously bound
	; and turned off cannot come back disabled
	try {
		Hotkey(spec, callback, "On")
	} catch as err {
		LoggerWarn("adapters.hotkey_registrar", "bind(): the OS refused '" . chordString . "' — " . err.Message . ".")
		return ""
	}

	HOTKEY_REGISTRAR_NEXT_TOKEN += 1
	handle := "hotkey#" . HOTKEY_REGISTRAR_NEXT_TOKEN
	canonical := ChordCanonicalize(chordString)
	HOTKEY_REGISTRAR_BINDINGS[handle] := Map("spec", spec, "chord", canonical, "enabled", true)
	LoggerDebug("adapters.hotkey_registrar", "Bound " . canonical . " → " . handle . ".")
	return handle
}

/**
 * Releases a binding.
 * @param {String} handle A handle previously returned by HotkeyRegistrarBind.
 * @returns {Boolean} true if a live binding was released, false otherwise.
 */
HotkeyRegistrarUnbind(handle) {
	global HOTKEY_REGISTRAR_BINDINGS

	if (!IsSet(handle) || Type(handle) != "String" || !HOTKEY_REGISTRAR_BINDINGS.Has(handle)) {
		; Not an error: teardown paths unbind defensively and a second call must
		; report "nothing to do" rather than raise mid-reload
		return false
	}

	entry := HOTKEY_REGISTRAR_BINDINGS[handle]
	HOTKEY_REGISTRAR_BINDINGS.Delete(handle)
	try {
		Hotkey(entry["spec"], "Off")
	} catch as err {
		LoggerError("adapters.hotkey_registrar", "unbind(): " . entry["chord"] . " failed to release — " . err.Message . ".")
		return false
	}

	LoggerDebug("adapters.hotkey_registrar", "Released " . entry["chord"] . " (" . handle . ").")
	return true
}

/**
 * Suspends or resumes a binding without releasing it.
 * @param {String} handle A handle previously returned by HotkeyRegistrarBind.
 * @param {Boolean} enabled Desired state.
 * @returns {Boolean} true if the handle now holds the requested state.
 */
HotkeyRegistrarSetEnabled(handle, enabled) {
	global HOTKEY_REGISTRAR_BINDINGS

	if (!IsSet(handle) || Type(handle) != "String" || !HOTKEY_REGISTRAR_BINDINGS.Has(handle)) {
		return false
	}

	entry := HOTKEY_REGISTRAR_BINDINGS[handle]
	want := enabled ? true : false
	if (entry["enabled"] = want) {
		return true
	}

	try {
		Hotkey(entry["spec"], want ? "On" : "Off")
	} catch as err {
		LoggerError("adapters.hotkey_registrar", "setEnabled(): " . entry["chord"] . " failed — " . err.Message . ".")
		return false
	}

	entry["enabled"] := want
	LoggerDebug("adapters.hotkey_registrar", entry["chord"] . " enabled=" . (want ? "true" : "false") . ".")
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

	if (!IsSet(handle) || Type(handle) != "String" || !HOTKEY_REGISTRAR_BINDINGS.Has(handle)) {
		return ""
	}
	return HOTKEY_REGISTRAR_BINDINGS[handle]["chord"]
}

/**
 * Reports how many bindings this adapter currently holds.
 * A leak here is invisible in the UI — the hotkeys keep firing — so the count is
 * exposed for the suite to assert against after a stop/start cycle.
 * @returns {Integer}
 */
HotkeyRegistrarLiveCount() {
	global HOTKEY_REGISTRAR_BINDINGS

	return HOTKEY_REGISTRAR_BINDINGS.Count
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
