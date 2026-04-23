; static/drivers/autohotkey/lib/layout_shift_caps.ahk

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
; ``DeadkeyMappingCircumflex`` defined in modules/layout.ahk and
; ``GetCapsLockCondition`` in the same file. Lazy resolution at call time
; means the include order does not matter.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Layer tables =======
; ============================================
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

	; Shift-layer symbol overrides. The French-typography keys get a thin
	; non-breaking space prefix and an ``ActivateHotstrings`` poke so the
	; pending hotstring buffer is committed before the new symbol arrives.
	SHIFT_SYMBOLS := Map(
		"SC039", () => WrapTextIfSelected("-", "-", "-"),
		"SC029", () => (ActivateHotstrings(), SendNewResult(" €")),
		"SC00C", () => (ActivateHotstrings(), SendNewResult(" %")),
		"SC00D", SendNewResult.Bind("º"),
		"SC01B", SendNewResult.Bind("_"),
		"SC022", () => (ActivateHotstrings(), SendNewResult(" :")),
		"SC02B", () => (ActivateHotstrings(), SendNewResult(" !")),
		"SC02F", () => (ActivateHotstrings(), SendNewResult(" " Chr(0x3B))),
		"SC035", () => (ActivateHotstrings(), SendNewResult(" ?")),
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
LayerDispatch(SC, SymbolMap, *) {
	if SymbolMap.Has(SC) {
		Cb := SymbolMap[SC]
		Cb()
		return
	}
	if SHIFTED_LETTERS.Has(SC) {
		SendNewResult(SHIFTED_LETTERS[SC])
	}
}

; Register both the Shift layer (``+SCxxx``) and the CapsLock layer
; (``SCxxx`` gated by ``GetCapsLockCondition``). Iterates the merged set of
; SCs (letters ∪ symbols) so every binding is created exactly once.
RegisterShiftLayer() {
	_BuildShiftCapsTables()
	try LoggerStart("LayoutShift", "Registering Shift layer hotkeys…")
	HotIf((*) => Features["Layout"]["ErgoptiBase"].Enabled)
	for SC, _ in SHIFTED_LETTERS {
		Hotkey("+" . SC, LayerDispatch.Bind(SC, SHIFT_SYMBOLS), "I2")
	}
	for SC, _ in SHIFT_SYMBOLS {
		; SC is guaranteed not to be in SHIFTED_LETTERS by table construction —
		; the loops cover disjoint sets, so re-binding is impossible here.
		Hotkey("+" . SC, LayerDispatch.Bind(SC, SHIFT_SYMBOLS), "I2")
	}
	HotIf()
	try LoggerSuccess("LayoutShift", "Shift layer registered (%d entries).",
		SHIFTED_LETTERS.Count + SHIFT_SYMBOLS.Count)
}

RegisterCapsLockLayer() {
	; Tables are reused from RegisterShiftLayer if it ran first; otherwise build now.
	if !IsObject(SHIFTED_LETTERS) {
		_BuildShiftCapsTables()
	}
	try LoggerStart("LayoutCaps", "Registering CapsLock layer hotkeys…")

	; --- Magic key overlay (registered first, lowest precedence) ---
	HotIf((*) => GetCapsLockCondition() and Features["MagicKey"]["Replace"].Enabled)
	Hotkey("SC02E", ((*) => SendNewResult(ScriptInformation["MagicKey"])), "I2")

	; --- Letters and symbols (registered last, highest precedence) ---
	HotIf((*) => GetCapsLockCondition() and Features["Layout"]["ErgoptiBase"].Enabled)
	for SC, _ in SHIFTED_LETTERS {
		Hotkey(SC, LayerDispatch.Bind(SC, CAPSLOCK_SYMBOLS), "I2")
	}
	for SC, _ in CAPSLOCK_SYMBOLS {
		Hotkey(SC, LayerDispatch.Bind(SC, CAPSLOCK_SYMBOLS), "I2")
	}
	HotIf()
	try LoggerSuccess("LayoutCaps", "CapsLock layer registered (%d entries).",
		SHIFTED_LETTERS.Count + CAPSLOCK_SYMBOLS.Count + 1)
}
