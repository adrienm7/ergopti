; modules/keymap/layout/layout_shift_caps.ahk

; ==============================================================================
; MODULE: Shift and CapsLock Layer Tables
; DESCRIPTION:
; The Shift and CapsLock layers of the emulated Ergopti layout, built from the
; Ergopti .keylayout (layout_ergopti.ahk) and registered here. Both layers share
; the same physical key set and produce identical uppercase letters and digits;
; only the punctuation differs.
;
; FEATURES & RATIONALE:
; 1. ``SHIFTED_LETTERS`` is the shared portion (uppercase letters, digits,
;    single-char output). Registered against both ``+SCxxx`` (Shift) and
;    ``SCxxx`` (CapsLock-gated) hotkey patterns.
; 2. ``SHIFT_SYMBOLS`` and ``CAPSLOCK_SYMBOLS`` carry the per-layer entries
;    for keys whose output diverges between the two layers — typically
;    French-typography punctuation that gets a thin non-breaking space prefix
;    on Shift but is plain on CapsLock.
; 3. ``LayerDispatch`` consults the symbol overrides first then falls back to
;    the shared letters table. Single dispatcher for both layers, parameterised
;    by which override Map to consult.
; 4. No character is written here: the tables follow the .keylayout, so a
;    layout change is a new .keylayout, not an edit of this file.
; 5. The digit row of both layers stands down on a layout where "Chiffres en
;    accès direct" swaps it (``DigitRowIsSwapped``), decided per press on the
;    foreground window's layout, so a layout switch never needs a reload.
;
; DEPENDENCIES:
; The callables come from ``ErgoptiLayout_Action`` (layout_ergopti.ahk), which
; binds ``SendNewResult``, ``WrapTextIfSelected``, ``ActivateHotstrings`` and
; ``DeadKey`` (modules/keymap/layout.ahk); ``GetCapsLockCondition`` is in the
; same file. Lazy resolution at call time means the include order does not
; matter.
; ==============================================================================





; ===============================
; ===============================
; ======= 1/ Layer tables =======
; ===============================
; ===============================

global SHIFTED_LETTERS := ""
global SHIFT_SYMBOLS := ""
global CAPSLOCK_SYMBOLS := ""

; Builds the three tables from the Ergopti layout tables read from the
; .keylayout (layout_ergopti.ahk). A key typing the same thing with Shift and
; with CapsLock (letters, digits) joins SHIFTED_LETTERS; any other key gets its
; own entry on each layer it types on. The Shift entries carry the French
; typography (a no-break space before « : ; ! ? € % », committing the pending
; hotstring first) and Shift+Space wraps the selection with hyphens.
_BuildShiftCapsTables() {
	global SHIFTED_LETTERS, SHIFT_SYMBOLS, CAPSLOCK_SYMBOLS

	Spec := ErgoptiLayout_Spec()
	Shift := Spec["levels"]["shift"]
	Caps := Spec["levels"]["caps"]
	DeadTables := Spec["dead_keys"]
	Letters := Map()
	ShiftSymbols := Map()
	CapsSymbols := Map()
	for SC, Descriptor in Shift {
		if Caps.Has(SC) && _ShiftCapsIsPlainText(Descriptor)
			&& _ShiftCapsIsPlainText(Caps[SC]) && (Descriptor["text"] == Caps[SC]["text"])
			Letters[SC] := Descriptor["text"]
		else
			ShiftSymbols[SC] := ErgoptiLayout_Action(Descriptor, DeadTables)
	}
	for SC, Descriptor in Caps {
		if !Letters.Has(SC)
			CapsSymbols[SC] := ErgoptiLayout_Action(Descriptor, DeadTables)
	}
	SHIFTED_LETTERS := Letters
	SHIFT_SYMBOLS := ShiftSymbols
	CAPSLOCK_SYMBOLS := CapsSymbols
}

; A descriptor that only types its text, with no overlay behaviour.
_ShiftCapsIsPlainText(Descriptor) {
	return Descriptor.Has("text") && (Descriptor.Count == 1)
}





; ==============================================
; ==============================================
; ======= 2/ Dispatcher and registration =======
; ==============================================
; ==============================================

; Run the symbol override for ``SC`` if present, otherwise fall back to the
; shared uppercase letter from ``SHIFTED_LETTERS``. The trailing ``*`` swallows
; the hotkey name AHK passes when invoking a hotkey callback. The callable is
; extracted to a local before the call to defeat any ``obj.method`` implicit
; first-arg passing that AHK applies for property-stored Funcs.
; ``SerializeSymbols`` opts a layer registration into the same Critical
; serialization the letter-fallback path below always gets. BOTH real layers now
; pass true: no ``CAPSLOCK_SYMBOLS`` entry ever Sleeps, and the ``SHIFT_SYMBOLS``
; exemption rested on a premise that has since rotted — ActivateHotstrings no longer
; Sleeps (it runs under its own Critical), and the SC039 wrap path is Sleep-free
; too — though "Sleep-free" is not the same as "fast": WrapTextIfSelected makes a
; synchronous clipboard snapshot and therefore releases Critical itself.
; Leaving the Shift layer unserialized let a neighbouring remapped-letter emit
; (itself Critical) preempt between the two SendNewResult halves of an NNBSP+symbol
; pair, transposing or splitting it when typing fast — the same interleave class
; already fixed for the letters (layer-dispatch-capslock-symbols-unserialized).
LayerDispatch(SC, SymbolMap, SerializeSymbols := false, *) {
	if SymbolMap.Has(SC) {
		Cb := SymbolMap[SC]
		if SerializeSymbols {
			_AtCrit := Critical("On")
			try {
				Cb()
			} finally {
				Critical(_AtCrit)
			}
		} else {
			; Unserialized fallback, kept only for callers that explicitly opt out.
			; NOTE: the old "SHIFT_SYMBOLS callbacks may Sleep (ActivateHotstrings)"
			; rationale is obsolete — ActivateHotstrings no longer Sleeps and runs under
			; its own Critical, so both real layers now pass SerializeSymbols=true.
			Cb()
		}
		return
	}
	if SHIFTED_LETTERS.Has(SC) {
		_AtCrit := Critical("On")   ; Serialize the letter emit like _RemapEmit
        try {
		    SendNewResult(SHIFTED_LETTERS[SC])
        } finally {
            Critical(_AtCrit)
        }
	}
}

; Register both the Shift layer (``+SCxxx``) and the CapsLock layer
; (``SCxxx`` gated by ``GetCapsLockCondition``). Iterates the merged set of
; SCs (letters ∪ symbols) so every binding is created exactly once.
; Scancodes for the digit row (1–0). Where "Chiffres en accès direct" swaps the
; digit row (DigitRowIsSwapped: the foreground layout puts its digits behind
; Shift), modules/keymap/layout.ahk's +SCxxx swap hotkeys own these positions.
; The Shift and CapsLock layers register them under a criterion that stands
; down there, so the two variant sets are disjoint on every layout: of two
; eligible variants, the one created first fires, not necessarily the swap.
global _SHIFT_DIGIT_SCS := Map(
	"SC002", true, "SC003", true, "SC004", true, "SC005", true, "SC006", true,
	"SC007", true, "SC008", true, "SC009", true, "SC00A", true, "SC00B", true,
)

RegisterShiftLayer() {
	_BuildShiftCapsTables()
	try LoggerStart("LayoutShift", "Registering Shift layer hotkeys…")
	; try/finally: HotIf sets a PROCESS-WIDE criterion, so a throw before the
	; reset leaks it into every later Hotkey() call in the driver — silently
	; gating unrelated layers behind this condition.
	try {
		HotIf((*) => Features["layout"]["ergopti_base"])
		for SC in SHIFTED_LETTERS {
			if _SHIFT_DIGIT_SCS.Has(SC)
				continue ; the digit row, registered below
			Hotkey("+" . SC, LayerDispatch.Bind(SC, SHIFT_SYMBOLS, true), "I2")
		}
		for SC in SHIFT_SYMBOLS {
			; SC is guaranteed not to be in SHIFTED_LETTERS by table construction —
			; the loops cover disjoint sets, so re-binding is impossible here.
			Hotkey("+" . SC, LayerDispatch.Bind(SC, SHIFT_SYMBOLS, true), "I2")
		}
		; The digit row stands down where the swap owns it, decided per press on
		; the foreground window's layout, so no layout switch needs a reload.
		HotIf((*) => Features["layout"]["ergopti_base"]
			and !DigitRowIsSwapped(GetForegroundKeyboardLayout()))
		for SC in _SHIFT_DIGIT_SCS
			Hotkey("+" . SC, LayerDispatch.Bind(SC, SHIFT_SYMBOLS, true), "I2")
	} finally {
		HotIf() ; Reset to no condition
	}
	try LoggerSuccess("LayoutShift", "Shift layer registered ({1} entries).",
		SHIFTED_LETTERS.Count + SHIFT_SYMBOLS.Count)
}

RegisterCapsLockLayer() {
	; Tables are reused from RegisterShiftLayer if it ran first; otherwise build now.
	if !IsObject(SHIFTED_LETTERS) {
		_BuildShiftCapsTables()
	}
	try LoggerStart("LayoutCaps", "Registering CapsLock layer hotkeys…")

	; --- Magic key overlay (registered first, lowest precedence) ---
	; Use the configurable source scancode, not the hardcoded Ergopti-layout default,
	; so users on bépo or other layouts bind the correct physical key.
	;
	; ONE try/finally covers the whole registration below, not just the second
	; block: HotIf sets a PROCESS-WIDE criterion that stays in force until it is
	; cleared, so a Hotkey() that throws anywhere in here — including this first
	; overlay registration — used to propagate out with the CapsLock condition
	; still armed. Every hotkey registered afterwards, in this module and in every
	; later one, then silently inherited it and would only fire while CapsLock
	; happened to be active. RegisterShiftLayer already guards this way; this
	; sibling did not.
	try {
		HotIf((*) => GetCapsLockCondition() and Features["hotstrings"]["magic_key"]["replace"]["enabled"])
		Hotkey(ScriptInformation["MagicKeySourceScan"], ((*) => SendNewResult(ScriptInformation["MagicKey"])), "I2")

		; --- Letters and symbols (registered last, highest precedence) ---
		HotIf((*) => GetCapsLockCondition() and Features["layout"]["ergopti_base"])
		for SC in SHIFTED_LETTERS {
			if _SHIFT_DIGIT_SCS.Has(SC)
				continue ; the digit row, registered below
			Hotkey(SC, LayerDispatch.Bind(SC, CAPSLOCK_SYMBOLS, true), "I2")
		}
		for SC in CAPSLOCK_SYMBOLS {
			Hotkey(SC, LayerDispatch.Bind(SC, CAPSLOCK_SYMBOLS, true), "I2")
		}
		; Same digit-row exclusion as RegisterShiftLayer, per press on the
		; foreground layout: without it, toggling CapsLock on shadows the
		; direct_access_digits hotkeys with an ergopti_base variant, silently
		; regressing the auto-advance-skips-a-field fix for OTP/device-login
		; digit boxes.
		HotIf((*) => GetCapsLockCondition() and Features["layout"]["ergopti_base"]
			and !DigitRowIsSwapped(GetForegroundKeyboardLayout()))
		for SC in _SHIFT_DIGIT_SCS
			Hotkey(SC, LayerDispatch.Bind(SC, CAPSLOCK_SYMBOLS, true), "I2")
	} finally {
		HotIf() ; Reset to no condition
	}
	try LoggerSuccess("LayoutCaps", "CapsLock layer registered ({1} entries).",
		SHIFTED_LETTERS.Count + CAPSLOCK_SYMBOLS.Count + 1)
}





; =========================================================
; =========================================================
; ======= 3/ The digit row on the foreground layout =======
; =========================================================
; =========================================================

; HKL -> the digit row of that layout: "shifted" (its digits need Shift) and
; "symbols" (scan code -> the character each key types unshifted). A layout's
; digit row does not change while it is loaded, so each one is probed once.
global _DigitRowProfiles := Map()

; The digit row of layout Hkl, probed on first use through the adapter
; (KS_LayoutDigitsAreShifted, KS_LayoutDigitRowSymbols), so the check and the
; symbols always describe the same layout. HKL 0 (no foreground window) is not
; shifted and types nothing.
; @param Hkl {Integer} Keyboard layout handle.
; @return {Map} "shifted" {Boolean} and "symbols" {Map}.
_DigitRowProfile(Hkl) {
	global _DigitRowProfiles
	if !_DigitRowProfiles.Has(Hkl)
		_DigitRowProfiles[Hkl] := Map("shifted", KS_LayoutDigitsAreShifted(Hkl),
			"symbols", KS_LayoutDigitRowSymbols(Hkl))
	return _DigitRowProfiles[Hkl]
}

/** Returns typed effective intent; category masking never treats a string as a switch. */
NumberRowEffectiveMode() {
	global Features
	if !IsSet(Features) || !(Features is Map) || !Features.Has("layout") || !(Features["layout"] is Map)
			|| !IsCategoryGated("Layout")
		return "native"
	Mode := NumberRowPolicyMode(Features["layout"].Get("direct_access_digits", ""))
	; Desired unsupported intent remains stored and greyed in the menu. The
	; effective input owner retains its native source; it never claims symbols.
	if Mode == "symbols" && !NumberRowSymbolsCapable(GetKeyState("CapsLock", "T"))
		return "native"
	return Mode
}

/** Resolves the symbols-first level from the currently selected registry source. */
NumberRowSymbolsLevel(Sc, Caps) {
	global KLE_Id, Features
	Refused := Map("supported", false, "shift", false)
	if !IsSet(Features) || !(Features is Map) || !IsSet(KLE_Id) || !(KLE_Id is String)
			|| !((Caps is Integer) && (Caps == true || Caps == false)) || !KeylayoutEmulation_LayerIsActive("ergopti_base")
			|| Sc < 0x02 || Sc > 0x0B
			|| StrCompare(KLE_Id, KeylayoutEmulation_SelectedId(MasterGateDesiredFeatures(Features)), true) != 0
		return Refused
	Levels := KeylayoutEmulation_NumberRowLevels(Sc, Caps)
	return Levels is Map ? NumberRowPolicySymbolsShift(Mod(Sc - 1, 10) . "", Levels["plain"], Levels["shift"]) : Refused
}

/** Every physical position must have a genuine source pair before offering symbols. */
NumberRowSymbolsCapable(Caps) {
	Loop 10 {
		if !NumberRowSymbolsLevel(A_Index + 1, Caps)["supported"]
			return false
	}
	return true
}

; Resolve one effective digit-row key before the override chooses its level.
; The native profile retains its measured MapVirtualKeyEx/VkKeyScan behavior.
; A registry source instead owns its actual neutral-state descriptors, including
; actions and dead keys: the foreground HKL cannot describe its Shift symbols.
; @param Sc {Integer} Physical scan code in the 1-0 row.
; @param Hkl {Integer} Foreground native keyboard layout.
; @param Caps {Boolean} Explicit CapsLock state, or the live state when omitted.
; @return {Map} Swap, Source and Descriptor; inspection never changes KLE_State.
_DigitRowSwapResolution(Sc, Hkl, Caps := unset) {
	global Features
	if NumberRowEffectiveMode() != "digits" || Sc < 0x02 || Sc > 0x0B
		return Map("swap", false, "source", "native", "descriptor", 0)
	if !IsSet(Caps)
		Caps := GetKeyState("CapsLock", "T")
	Levels := KeylayoutEmulation_NumberRowLevels(Sc, Caps)
	if Levels is Map {
		Plain := Levels["plain"]
		Shift := Levels["shift"]
		Digit := Mod(Sc - 1, 10) . ""
		Swap := !(Plain["Kind"] == "text" && StrCompare(Plain["Text"], Digit, true) == 0)
			&& Shift["Kind"] == "text" && StrCompare(Shift["Text"], Digit, true) == 0
		return Map("swap", Swap, "source", "emulated", "descriptor", Plain)
	}
	Profile := _DigitRowProfile(Hkl)
	Text := Profile["symbols"].Get(Sc, "")
	return Map("swap", Profile["shifted"] && Text != "", "source", "native",
		"descriptor", Map("Kind", "text", "Text", Text, "State", "", "Action", ""))
}

; Whether any effective row key needs the direct-digit override to swap levels.
; @param Hkl {Integer} Foreground native keyboard layout.
; @param Caps {Boolean} CapsLock state, live when omitted.
; @return {Boolean}
DigitRowIsSwapped(Hkl, Caps := unset) {
	global KS_DIGIT_ROW_KEYS
	for _, Key in KS_DIGIT_ROW_KEYS {
		if _DigitRowSwapResolution(Key[2], Hkl, Caps?)["swap"]
			return true
	}
	return false
}

; The native symbol or descriptor preview on the effective unshifted level.
; The emission owner retains the full descriptor, so a dead key is never
; flattened into this label text when the user actually presses the key.
; @param Sc {Integer} Scan code, 0x02 (the 1 key) to 0x0B (the 0 key).
; @param Hkl {Integer} Foreground native keyboard layout.
; @param Caps {Boolean} CapsLock state, live when omitted.
; @return {String} Symbol/preview, or empty when no swap owns this key.
DigitRowSwapSymbol(Sc, Hkl, Caps := unset) {
	Resolution := _DigitRowSwapResolution(Sc, Hkl, Caps?)
	return Resolution["swap"] ? Resolution["descriptor"]["Text"] : ""
}
