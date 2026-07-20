; modules/keymap/layout/layout_shift_caps.ahk

; ==============================================================================
; MODULE: Shift and CapsLock Layer Tables
; DESCRIPTION:
; Single source of truth for the Shift and CapsLock layers of the emulated
; Ergopti layout. Both layers share the same physical key set and produce
; identical uppercase letters and digits — only the punctuation row differs.
;
; FEATURES & RATIONALE:
; 1. ``SHIFTED_LETTERS`` is the shared portion (uppercase letters, digits,
;    single-char output). Registered against both ``+SCxxx`` (Shift) and
;    ``SCxxx`` (CapsLock-gated) hotkey patterns.
; 2. ``SHIFT_SYMBOLS`` and ``CAPSLOCK_SYMBOLS`` carry the per-layer overrides
;    for keys whose output diverges between the two layers — typically
;    French-typography punctuation that gets a thin non-breaking space prefix
;    on Shift but is plain on CapsLock.
; 3. ``LayerDispatch`` consults the symbol overrides first then falls back to
;    the shared letters table. Single dispatcher for both layers, parameterised
;    by which override Map to consult.
; 4. Adding a key now means a single Map entry instead of two separate
;    ``+SCxxx::`` and ``SCxxx::`` blocks that have to be kept in sync by hand.
;
; DEPENDENCIES:
; References ``SendNewResult``, ``WrapTextIfSelected``, ``ActivateHotstrings``,
; ``DeadKey``, ``InDeadKeySequence``, ``DeadkeyMappingDiaresis``,
; ``DeadkeyMappingCircumflex`` defined in modules/keymap/layout.ahk and
; ``GetCapsLockCondition`` in the same file. Lazy resolution at call time
; means the include order does not matter.
; ==============================================================================





; ============================================
; ===============================
; ======= 1/ Layer tables =======
; ===============================
; ============================================

global SHIFTED_LETTERS := ""
global SHIFT_SYMBOLS := ""
global CAPSLOCK_SYMBOLS := ""

_BuildShiftCapsTables() {
	global SHIFTED_LETTERS, SHIFT_SYMBOLS, CAPSLOCK_SYMBOLS

	; Uppercase letters and digits — identical on the Shift and CapsLock layers.
	SHIFTED_LETTERS := Map(
		; Number row digits
		"SC002", "1", "SC003", "2", "SC004", "3", "SC005", "4", "SC006", "5",
		"SC007", "6", "SC008", "7", "SC009", "8", "SC00A", "9", "SC00B", "0",

		; Top row uppercase letters
		"SC010", "È", "SC011", "Y", "SC012", "O", "SC013", "W", "SC014", "B",
		"SC015", "F", "SC016", "G", "SC017", "H", "SC018", "C", "SC019", "X",
		"SC01A", "Z",

		; Middle row uppercase letters
		"SC01E", "A", "SC01F", "I", "SC020", "E", "SC021", "U",
		"SC023", "V", "SC024", "S", "SC025", "N", "SC026", "T",
		"SC027", "R", "SC028", "Q",

		; Bottom row uppercase letters
		"SC056", "Ê", "SC02C", "É", "SC02D", "À", "SC02E", "J",
		"SC030", "K", "SC031", "M", "SC032", "D", "SC033", "L", "SC034", "P",
	)

	; Shift-layer symbol overrides. The French-typography keys get a
	; non-breaking space prefix and an ``ActivateHotstrings`` poke so the
	; pending hotstring buffer is committed before the new symbol arrives.
	; The space TYPE follows the French typographic rule and differs per
	; punctuation: ":" takes a full no-break space (NBSP, U+00A0) while ";",
	; "!" and "?" take a NARROW no-break space (NNBSP, U+202F). Getting this
	; wrong is not cosmetic — downstream hotstring matching keys off the exact
	; prefix the layout emits (see _BuildUppercasedSymbols / UPPER_TRIGGERS).
	SHIFT_SYMBOLS := Map(
		"SC039", () => WrapTextIfSelected("-", "-", "-"),
		"SC029", () => (ActivateHotstrings(), SendNewResult(Chr(0x202F) "€")),
		"SC00C", () => (ActivateHotstrings(), SendNewResult(Chr(0x202F) "%")),
		"SC00D", SendNewResult.Bind("º"),
		"SC01B", SendNewResult.Bind("_"),
		"SC022", () => (ActivateHotstrings(), SendNewResult(Chr(0xA0) ":")),
		"SC02B", () => (ActivateHotstrings(), SendNewResult(Chr(0x202F) "!")),
		"SC02F", () => (ActivateHotstrings(), SendNewResult(Chr(0x202F) Chr(0x3B))),
		"SC035", () => (ActivateHotstrings(), SendNewResult(Chr(0x202F) "?")),
	)

	; CapsLock-layer symbol overrides. The deadkey-bearing keys (SC01B, SC02B)
	; check ``InDeadKeySequence`` so a chained dead-key sequence still
	; produces the bare deadkey character instead of recursing.
	CAPSLOCK_SYMBOLS := Map(
		"SC029", SendNewResult.Bind("$"),
		"SC00C", SendNewResult.Bind("%"),
		"SC00D", SendNewResult.Bind("="),
		"SC01B", () => (InDeadKeySequence ? SendNewResult("¨") : DeadKey(DeadkeyMappingDiaresis)),
		"SC022", SendNewResult.Bind("."),
		"SC02B", () => (InDeadKeySequence ? SendNewResult("^") : DeadKey(DeadkeyMappingCircumflex)),
		"SC02F", SendNewResult.Bind(","),
		"SC035", SendNewResult.Bind("'"),
	)
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
; Sleeps (it runs under its own Critical) and the SC039 wrap path is Sleep-free too.
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
; Scancodes for the digit row (1–0).  When direct_access_digits is enabled and
; the OS layout puts digits behind Shift, modules/keymap/layout.ahk registers global
; +SCxxx passthrough hotkeys for these positions.  Registering them again here
; with an ergopti_base criterion would shadow the passthrough because AHK picks
; a criterion variant over a global variant whenever the criterion is met.
; Excluding these SCs from RegisterShiftLayer keeps the two sets disjoint.
global _SHIFT_DIGIT_SCS := Map(
	"SC002", true, "SC003", true, "SC004", true, "SC005", true, "SC006", true,
	"SC007", true, "SC008", true, "SC009", true, "SC00A", true, "SC00B", true,
)

RegisterShiftLayer() {
	_BuildShiftCapsTables()
	try LoggerStart("LayoutShift", "Registering Shift layer hotkeys…")
	; When the OS-layout-shifted-digit passthrough is active, skip SC002..SC00B
	; so the global passthrough variant is not shadowed by an ergopti_base variant.
	SkipDigitRow := IsSet(Features)
		&& Features["layout"]["direct_access_digits"]
		&& IsSet(_OsLayoutDigitsAreShifted)
		&& _OsLayoutDigitsAreShifted()
	HotIf((*) => Features["layout"]["ergopti_base"])
	for SC in SHIFTED_LETTERS {
		if (SkipDigitRow && _SHIFT_DIGIT_SCS.Has(SC))
			continue
		Hotkey("+" . SC, LayerDispatch.Bind(SC, SHIFT_SYMBOLS, true), "I2")
	}
	for SC in SHIFT_SYMBOLS {
		; SC is guaranteed not to be in SHIFTED_LETTERS by table construction —
		; the loops cover disjoint sets, so re-binding is impossible here.
		Hotkey("+" . SC, LayerDispatch.Bind(SC, SHIFT_SYMBOLS, true), "I2")
	}
	HotIf()
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
	HotIf((*) => GetCapsLockCondition() and Features["hotstrings"]["magic_key"]["replace"]["enabled"])
	Hotkey(ScriptInformation["MagicKeySourceScan"], ((*) => SendNewResult(ScriptInformation["MagicKey"])), "I2")

	; --- Letters and symbols (registered last, highest precedence) ---
	; Same OS-layout-shifted-digit exclusion as RegisterShiftLayer: without it,
	; toggling CapsLock on shadows the global direct_access_digits passthrough
	; hotkeys with an ergopti_base variant, silently regressing the
	; auto-advance-skips-a-field fix for OTP/device-login digit boxes.
	SkipDigitRow := IsSet(Features)
		&& Features["layout"]["direct_access_digits"]
		&& IsSet(_OsLayoutDigitsAreShifted)
		&& _OsLayoutDigitsAreShifted()
	HotIf((*) => GetCapsLockCondition() and Features["layout"]["ergopti_base"])
	for SC in SHIFTED_LETTERS {
		if (SkipDigitRow && _SHIFT_DIGIT_SCS.Has(SC))
			continue
		Hotkey(SC, LayerDispatch.Bind(SC, CAPSLOCK_SYMBOLS, true), "I2")
	}
	for SC in CAPSLOCK_SYMBOLS {
		Hotkey(SC, LayerDispatch.Bind(SC, CAPSLOCK_SYMBOLS, true), "I2")
	}
	HotIf()
	try LoggerSuccess("LayoutCaps", "CapsLock layer registered ({1} entries).",
		SHIFTED_LETTERS.Count + CAPSLOCK_SYMBOLS.Count + 1)
}
