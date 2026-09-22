; modules/keymap/layout/accented_shortcuts.ahk

; ==============================================================================
; MODULE: Accented-letter shortcuts on any keyboard layout
; DESCRIPTION:
; Lets Ctrl/Alt/Win (+ Shift) on a key that types an accented letter directly
; act as the same chord on a configured Latin letter: Ctrl+é → Ctrl+C on an
; AZERTY, BÉPO or OS-installed Ergopti layout, whose accented keys would
; otherwise send shortcuts no application binds.
;
; FEATURES & RATIONALE:
; 1. Layout-driven, not position-driven: the Ergopti emulation remaps fixed
;    scancodes, which are wrong for every other layout. Here each installed
;    layout is asked which key types the letter WITHOUT Shift or AltGr; a letter
;    that needs either (every accent on QWERTY, ê on AZERTY) gets no shortcut.
; 2. Checked against the live layout on every press: the hotkeys cover the
;    union of the installed layouts' keys, and the HotIf predicate re-resolves
;    the key in the foreground window's current layout. Switching AZERTY →
;    QWERTY therefore gives Ctrl+2 back instead of turning it into Ctrl+C.
; 3. AltGr is left alone: Ctrl+Alt is AltGr on these layouts, so it is not in
;    the prefix list and dead keys such as AltGr+é keep working.
; 4. Only used when the Ergopti base layer is not emulated — the emulation
;    already remaps its own accented keys (layout.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0

; Feature id → accented letter. The feature ids are Features["shortcuts"][Id].
global ACCENTED_SHORTCUT_LETTERS := Map(
	"e_grave", "è",
	"e_circ", "ê",
	"e_acute", "é",
	"a_grave", "à"
)

; Every modifier chord remapped, AltGr (^!) deliberately excluded.
global ACCENTED_SHORTCUT_PREFIXES := ["^", "^+", "!", "!+", "#", "#+"]

; Layout handle (HKL) → Map(scancode → feature id). Filled lazily per layout.
global _AccentedShortcutLayoutCache := Map()
global _AccentedShortcutRegistered := false





; =======================================
; =======================================
; ======= 1/ Layout introspection =======
; =======================================
; =======================================

; Returns the scancode of the key that types Char with no Shift, Ctrl or Alt in
; the given layout, or 0 when the letter is not directly accessible there.
; @param Char {String} One character.
; @param Hkl {Integer} Keyboard layout handle.
; @returns {Integer} Scancode, or 0.
AccentedShortcutDirectScanCode(Char, Hkl) {
	return KS_DirectScanCodeForChar(Hkl, Char)
}

; Maps each directly-typed accented letter of one layout to its scancode.
; @param Hkl {Integer} Keyboard layout handle.
; @param ScanCodeFn {Func} (Char, Hkl) → scancode; injectable for tests.
; @returns {Map} Scancode → feature id.
AccentedShortcutKeysForLayout(Hkl, ScanCodeFn := AccentedShortcutDirectScanCode) {
	global ACCENTED_SHORTCUT_LETTERS
	; « Chiffres en accès direct » swaps the top row of a layout whose digits sit
	; behind Shift (AZERTY, BÉPO): its accents then need Shift, so they are no
	; longer direct and Ctrl+that key must stay Ctrl+digit.
	DigitRowSwapped := _AccentedShortcutDigitAccessEnabled()
		&& ScanCodeFn.Call("1", Hkl) == 0
	Keys := Map()
	for Id, Char in ACCENTED_SHORTCUT_LETTERS {
		Sc := ScanCodeFn.Call(Char, Hkl)
		if !(Sc is Integer) || Sc <= 0 || Keys.Has(Sc)
			continue
		if DigitRowSwapped && Sc >= 0x02 && Sc <= 0x0B
			continue
		Keys[Sc] := Id
	}
	return Keys
}

_AccentedShortcutDigitAccessEnabled() {
	global Features
	return IsSet(Features) && Features.Has("layout")
		&& Features["layout"].Get("direct_access_digits", false)
}

_AccentedShortcutKeysCached(Hkl) {
	global _AccentedShortcutLayoutCache
	if !_AccentedShortcutLayoutCache.Has(Hkl)
		_AccentedShortcutLayoutCache[Hkl] := AccentedShortcutKeysForLayout(Hkl)
	return _AccentedShortcutLayoutCache[Hkl]
}

_AccentedShortcutForegroundLayout() {
	; 0 without a foreground window; the layout probes then fall back to the
	; calling thread's own layout.
	return GetForegroundKeyboardLayout()
}





; =============================================
; =============================================
; ======= 2/ Configuration and dispatch =======
; =============================================
; =============================================

; Returns the configured target letter of an enabled accented shortcut, or ""
; when the user disabled it or left it without a letter.
; @param Id {String} Feature id, e.g. "e_acute".
; @returns {String}
AccentedShortcutTargetLetter(Id) {
	global Features
	if !IsSet(Features) || !Features.Has("shortcuts")
			|| !Features["shortcuts"].Has(Id)
		return ""
	Entry := Features["shortcuts"][Id]
	if !(Entry is Map) || !Entry.Get("enabled", false)
		return ""
	Letter := Entry.Get("letter", "")
	return (Letter is String) ? Letter : ""
}

; Resolves a fired hotkey name ("^+SC003") against a layout's direct keys.
; @param HotkeyName {String} ThisHotkey as AHK reports it.
; @param Keys {Map} Scancode → feature id for the live layout.
; @returns {String} The target letter, or "" when this press is not ours.
AccentedShortcutResolve(HotkeyName, Keys) {
	if !RegExMatch(HotkeyName, "i)SC([0-9A-F]{3})$", &Match)
		return ""
	Sc := Integer("0x" . Match[1])
	if !Keys.Has(Sc)
		return ""
	return AccentedShortcutTargetLetter(Keys[Sc])
}

_AccentedShortcutIsActive(HotkeyName) {
	return AccentedShortcutResolve(HotkeyName,
		_AccentedShortcutKeysCached(_AccentedShortcutForegroundLayout())) != ""
}

_AccentedShortcutEmit(HotkeyName) {
	Letter := AccentedShortcutResolve(HotkeyName,
		_AccentedShortcutKeysCached(_AccentedShortcutForegroundLayout()))
	if (Letter == "")
		return
	Critical("On")
	; {Blind} keeps the held Ctrl/Alt/Win/Shift, so the chord moves to Letter.
	SendEvent("{Blind}" . Letter)
}

; Registers the chords on every key that types an accented letter directly in
; at least one installed layout. Called once at load when the Ergopti base
; layer is not emulated.
; @param Layouts {Array} Installed layouts; injectable for tests.
; @param HotkeyFn {Func} Hotkey registrar; injectable for tests.
; @param HotIfFn {Func} HotIf selector; injectable for tests.
; @param KeysFn {Func} Hkl → Map(scancode → feature id); injectable for tests.
; @returns {Integer} Number of hotkeys registered.
AccentedShortcuts_Register(Layouts := unset, HotkeyFn := Hotkey, HotIfFn := HotIf,
		KeysFn := _AccentedShortcutKeysCached) {
	global ACCENTED_SHORTCUT_PREFIXES, _AccentedShortcutRegistered
	if _AccentedShortcutRegistered
		throw Error("Accented-letter shortcuts are already registered.")
	if !IsSet(Layouts)
		Layouts := KS_InstalledKeyboardLayouts()
	ScanCodes := Map()
	for Hkl in Layouts
		for Sc, Id in KeysFn.Call(Hkl)
			if (AccentedShortcutTargetLetter(Id) != "")
				ScanCodes[Sc] := true
	Count := 0
	HotIfFn.Call(_AccentedShortcutIsActive)
	try {
		for Sc in ScanCodes {
			for Prefix in ACCENTED_SHORTCUT_PREFIXES {
				HotkeyFn.Call(Prefix . Format("SC{:03X}", Sc),
					_AccentedShortcutEmit, "I2")
				Count += 1
			}
		}
	} finally HotIfFn.Call()
	_AccentedShortcutRegistered := true
	try LoggerInfo("AccentedShortcuts",
		"{1} accented-letter chord(s) registered on {2} key(s) across {3} layout(s).",
		Count, ScanCodes.Count, Layouts.Length)
	return Count
}
