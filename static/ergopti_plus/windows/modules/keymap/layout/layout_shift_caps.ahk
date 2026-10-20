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

; The built-in Ergopti emulation's own unshifted number row: « $ », the digits,
; « % » and « = ». It used to leave that level to « Chiffres en accès direct »,
; so wherever that choice does not apply (the Ergopti row has its digits on
; both levels, which nothing can reorder) the native row typed instead:
; AZERTY's « ² & é " … ».
; The direct-access hotkeys (modules/keymap/layout.ahk) are created first, so
; they still win where their choice applies; CapsLock keeps its own layer.
RegisterBuiltinNumberRow() {
	global ERGOPTI_SPEC, ERGOPTI_NUMBER_ROW
	Row := ERGOPTI_SPEC["number_row_base"]
	try LoggerStart("LayoutNumberRow", "Registering the built-in Ergopti number row…")
	Count := 0
	try {
		HotIf((*) => BuiltinNumberRowIsActive() and !GetCapsLockCondition())
		for SC in ERGOPTI_NUMBER_ROW {
			if !Row.Has(SC) || !Row[SC].Has("text")
				throw Error("The Ergopti number row has no text on " . SC . ".")
			Text := Row[SC]["text"]
			; Digits press and release like the direct-access digits (OTP boxes);
			; the edge keys type like theirs. The tap keys' hotkeys, created
			; earlier, keep an assigned edge key.
			if RegExMatch(Text, "^[0-9]$") {
				Hotkey(SC, _DigitRowDown.Bind(Text), "I2")
				Hotkey(SC . " Up", _DigitRowUp.Bind(Text), "I2")
			} else
				Hotkey(SC, _DigitShiftSend.Bind(Text), "I2")
			Count += 1
		}
	} catch as Err {
		try LoggerError("LayoutNumberRow", "The built-in Ergopti number row could not be registered: {1}", Err.Message)
		throw Err
	} finally {
		HotIf() ; Reset to no condition
	}
	try LoggerSuccess("LayoutNumberRow", "Built-in Ergopti number row registered ({1} keys).", Count)
}

/**
 * What the layout emulation types unshifted on a number-row key, edges
 * included: the registry layout's neutral base level or the built-in Ergopti
 * row; "" when no emulation types that key (the OS layout's then).
 * @param {String} Sc Scan code name, "SC029" to "SC00D".
 * @returns {String}
 */
NumberRowEmulatedBase(Sc) {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex, ERGOPTI_SPEC, ERGOPTI_NUMBER_ROW
	if !ERGOPTI_NUMBER_ROW.Has(Sc)
		return ""
	if KeylayoutEmulation_LayerIsActive("ergopti_base") {
		if !KLE_KeyCodes.Has(Sc)
			return ""
		Level := Keylayout_Resolve(KLE_Model, KLE_LevelIndex[_KLE_ComboKey(false, false, false)], KLE_KeyCodes[Sc])
		return Level["Text"]
	}
	if !BuiltinNumberRowIsActive() || !IsSet(ERGOPTI_SPEC) || !IsObject(ERGOPTI_SPEC)
		return ""
	Row := ERGOPTI_SPEC["number_row_base"]
	return Row.Has(Sc) && Row[Sc].Has("text") ? Row[Sc]["text"] : ""
}

; Whether the built-in Ergopti emulation is in force: the effective switch,
; which a selected registry layout supersedes (MasterGateDesiredFeatures).
BuiltinNumberRowIsActive() {
	global Features
	; Indexed, not Get: the number-row policy reads its stored choice once
	; through Get, and the producer fixtures count exactly that read.
	return IsSet(Features) && Features is Map && Features.Has("layout") && Features["layout"] is Map
		&& Features["layout"].Has("ergopti_base") && Features["layout"]["ergopti_base"] == true
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
			"symbols", KS_LayoutDigitRowSymbols(Hkl), "shift_symbols", KS_LayoutDigitRowShiftedSymbols(Hkl))
	return _DigitRowProfiles[Hkl]
}

; The last stored choice, effective ordering and reason logged, so each switch
; between applied and inert is logged once.
global _NumberRowEffectiveLogged := ""

; Test seam: a layout handle standing for the foreground window's layout in
; NumberRowEffectiveMode (0, always in production, reads the real one).
global _NumberRowForegroundLayout := 0

/**
 * The ordering in effect: the stored choice where it can reorder the effective
 * row, else "native". The stored choice itself is never rewritten: a choice
 * that is inert on one layout applies again on a layout where it can.
 * Category masking never treats a string as a switch.
 * @param {Integer} Hkl Native layout; the foreground window's when omitted.
 * @param {Boolean} Caps CapsLock state; the live one when omitted.
 * @returns {String} "native", "digits" or "symbols".
 */
NumberRowEffectiveMode(Hkl := unset, Caps := unset) {
	global Features, CategoryEnabled
	; Parse-time criteria can run during Bundle_Init, before category publication.
	; Only the actual admitted Layout switch may enable a non-native policy.
	if !IsSet(Features) || !(Features is Map) || !Features.Has("layout") || !(Features["layout"] is Map)
			|| !IsSet(CategoryEnabled) || !(CategoryEnabled is Map) || !CategoryEnabled.Has("Layout")
			|| !(CategoryEnabled["Layout"] is Integer) || CategoryEnabled["Layout"] != true
		return "native"
	Mode := NumberRowPolicyMode(Features["layout"].Get("direct_access_digits", ""))
	if Mode == "" || Mode == "native"
		return "native"
	if !IsSet(Caps)
		Caps := GetKeyState("CapsLock", "T")
	; Capability dependencies are also unpublished during the first pump. A
	; contained admission leaves native input authoritative on an unset source.
	if Mode == "symbols" {
		Supported := false
		try NumberRowSymbolsAdmission(Caps, &Supported)
		if !Supported
			return "native"
	}
	if !IsSet(Hkl)
		Hkl := NumberRowForegroundLayout()
	Effective := NumberRowPolicyEffective(Mode, NumberRowAvailability(Hkl, Caps))
	_NumberRowLogTransition(Mode, Effective)
	return Effective["mode"]
}

; The layout of the foreground window, or the test seam's stand-in.
NumberRowForegroundLayout() {
	global _NumberRowForegroundLayout
	return _NumberRowForegroundLayout ? _NumberRowForegroundLayout : GetForegroundKeyboardLayout()
}

/**
 * What a digit key types under « symbols first » on a row no registry layout
 * owns (the native or the built-in one): its Shift-level symbol unshifted, its
 * digit with Shift. A dead Shift level types its accent.
 * @param {Integer} Sc Scan code, 0x02 (the 1 key) to 0x0B (the 0 key).
 * @param {Boolean} Shift Shift held.
 * @param {Integer} Hkl Native layout of the press.
 * @param {Boolean} Caps CapsLock state.
 * @returns {String} "" when « symbols first » does not apply there.
 */
NumberRowSymbolsFirstText(Sc, Shift, Hkl, Caps) {
	if Sc < 0x02 || Sc > 0x0B || NumberRowEffectiveMode(Hkl, Caps) != "symbols"
		return ""
	if Shift
		return Mod(Sc - 1, 10) . ""
	Level := _DigitRowEffectiveKey(Sc, Hkl, Caps)["shift"]
	return Level is Map ? Level["Text"] : ""
}

; Logs a stored choice turning inert on the effective layout, and applying again.
_NumberRowLogTransition(Mode, Effective) {
	global _NumberRowEffectiveLogged
	State := Mode . "|" . Effective["mode"] . "|" . Effective["reason"]
	if State == _NumberRowEffectiveLogged
		return
	WasInert := StrSplit(_NumberRowEffectiveLogged . "||", "|")[3] != ""
	_NumberRowEffectiveLogged := State
	if Effective["reason"] != "" {
		try LoggerInfo("NumberRow", "'{1}' is not applied on this layout ({2}); the stored choice is kept.",
			Mode, Effective["reason"])
	} else if WasInert {
		try LoggerInfo("NumberRow", "'{1}' applies again on this layout.", Mode)
	}
}

/** Publishes capability only after the existing source owner returns exact true. */
NumberRowSymbolsAdmission(Caps, &Supported) {
	Supported := false
	Observed := NumberRowSymbolsCapable(Caps)
	Supported := (Observed is Integer) && Observed == true
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

/**
 * Whether « symbols first » can be emitted: a registry layout needs a genuine
 * source pair at every position (its own action machine types the levels);
 * the native and built-in rows are typed by NumberRowSymbolsFirstText. Where
 * the row cannot be reordered, NumberRowAvailability keeps the choice inert.
 */
NumberRowSymbolsCapable(Caps) {
	if !KeylayoutEmulation_LayerIsActive("ergopti_base")
		return true
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
	if Sc < 0x02 || Sc > 0x0B
		return Map("swap", false, "source", "native", "descriptor", 0)
	if !IsSet(Caps)
		Caps := GetKeyState("CapsLock", "T")
	Row := _DigitRowEffectiveKey(Sc, Hkl, Caps)
	; « Digits first » applies only where every key of the row has a symbol
	; unshifted and its digit on Shift (NumberRowPolicyAvailability), so an
	; applied choice swaps each key; elsewhere it is inert and swaps nothing.
	return Map("swap", NumberRowEffectiveMode(Hkl, Caps) == "digits", "source", Row["source"],
		"descriptor", Row["plain"])
}

; One digit key of the effective layout: the registry emulation's levels, the
; built-in Ergopti emulation's, or the native layout's, with which one it is.
; @return {Map} "plain" and "shift" descriptors (0 for a level typing nothing), "source".
_DigitRowEffectiveKey(Sc, Hkl, Caps) {
	Levels := KeylayoutEmulation_NumberRowLevels(Sc, Caps)
	if Levels is Map
		return Map("plain", Levels["plain"], "shift", Levels["shift"], "source", "emulated")
	Levels := _DigitRowBuiltinLevels(Sc, Caps)
	if Levels is Map
		return Map("plain", Levels["plain"], "shift", Levels["shift"], "source", "builtin")
	Profile := _DigitRowProfile(Hkl)
	return Map("plain", _DigitRowNativeDescriptor(Profile["symbols"].Get(Sc, "")),
		"shift", _DigitRowNativeDescriptor(Profile["shift_symbols"].Get(Sc, "")), "source", "native")
}

_DigitRowNativeDescriptor(Text) {
	return Text == "" ? 0 : Map("Kind", "text", "Text", Text, "State", "", "Action", "")
}

; Source identity -> Map("model", the registry model it was read from, "availability").
global _NumberRowAvailabilityCache := Map()

/**
 * Which ordering options can reorder the effective row (NumberRowPolicyAvailability),
 * read from the emulated layout while one owns the row, else from layout Hkl.
 * A source's row does not change while it is loaded, so each one is read once.
 * @param {Integer} Hkl Native keyboard layout.
 * @param {Boolean} Caps CapsLock state.
 * @returns {Map} "digits" and "symbols": "" when usable, else the reason.
 */
NumberRowAvailability(Hkl, Caps) {
	global _NumberRowAvailabilityCache, KLE_Model, KS_DIGIT_ROW_KEYS
	Model := 0
	if KeylayoutEmulation_LayerIsActive("ergopti_base") {
		Model := KLE_Model
		Source := "emulated:" . ObjPtr(Model)
	} else
		Source := _DigitRowBuiltinLevels(0x02, Caps) is Map ? "builtin" : "native:" . Hkl
	Key := Source . "|" . (Caps ? 1 : 0)
	Entry := _NumberRowAvailabilityCache.Get(Key, 0)
	; The entry holds its model, so a freed model's address is never reused here.
	if !(Entry is Map) || Entry["model"] !== Model {
		Levels := []
		for _, DigitKey in KS_DIGIT_ROW_KEYS {
			Row := _DigitRowEffectiveKey(DigitKey[2], Hkl, Caps)
			Levels.Push(Map("plain", Row["plain"], "shift", Row["shift"]))
		}
		Entry := Map("model", Model, "availability", NumberRowPolicyAvailability(Levels))
		_NumberRowAvailabilityCache[Key] := Entry
	}
	return Entry["availability"]
}

; The built-in Ergopti emulation's own levels of one row key, in the registry
; descriptor shape, while that emulation owns the row's Shift level
; (RegisterShiftLayer); 0 otherwise. The layout manager and the wizard select
; Ergopti and Ergopti+ this way, so resolving the row on the native layout
; instead swapped AZERTY's symbols onto Shift (digit-row-builtin-ergopti-shift).
; @param Sc {Integer} Physical scan code in the 1-0 row.
; @param Caps {Boolean} CapsLock state: its unshifted level is the CapsLock layer.
; @return {Map|Integer} "plain" and "shift" descriptors, or 0.
_DigitRowBuiltinLevels(Sc, Caps) {
	global ERGOPTI_SPEC
	if !BuiltinNumberRowIsActive() || !IsSet(ERGOPTI_SPEC) || !IsObject(ERGOPTI_SPEC)
		return 0
	Name := Format("SC{:03X}", Sc)
	Levels := ERGOPTI_SPEC["levels"]
	PlainTable := Caps ? Levels["caps"] : ERGOPTI_SPEC["number_row_base"]
	if !PlainTable.Has(Name) || !Levels["shift"].Has(Name)
		return 0
	return Map("plain", _DigitRowBuiltinDescriptor(PlainTable[Name]),
		"shift", _DigitRowBuiltinDescriptor(Levels["shift"][Name]))
}

; A built-in Ergopti descriptor (_ErgoptiDescribe) in the registry shape.
_DigitRowBuiltinDescriptor(Descriptor) {
	global ERGOPTI_SPEC
	if Descriptor.Has("dead") {
		Name := Descriptor["dead"]
		return Map("Kind", "dead", "Text", ERGOPTI_SPEC["terminators"][Name], "State", Name, "Action", Name)
	}
	for Field in ["text", "word", "wrap"]
		if Descriptor.Has(Field)
			return Map("Kind", "text", "Text", Descriptor[Field], "State", "", "Action", "")
	return Map("Kind", "none", "Text", "", "State", "", "Action", "")
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
