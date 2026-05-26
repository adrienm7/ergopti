; static/drivers/autohotkey/modules/layout.ahk

; ==============================================================================
; MODULE: Layout
; DESCRIPTION:
; Defines all physical key remappings for the Ergopti keyboard layout.
; Covers the base layer, Shift, CapsLock, AltGr/ShiftAltGr, and Control
; variants, as well as all dead-key mapping tables.
; ==============================================================================





; ======================================
; =======================================
; ======= 1/ DEAD KEY DEFINITIONS =======
; =======================================
; ======================================

; TODO : if KbdEdit is upgraded, some "NEW" Unicode characters will become available
; This AutoHotkey script has all the characters, and the KbdEdit file has some missing ones
; For example, there is no 🄋 character yet in KbdEdit, but it is already available in this emulation

global DeadkeyMappingCircumflex := Map(
	" ", "^", "^", "^",
	"¨", "/", "_", "\",
	"'", "⚠",
	",", "➜",
	".", "•",
	"/", "⁄",
	"0", "🄋", ; NEW
	"1", "➀",
	"2", "➁",
	"3", "➂",
	"4", "➃",
	"5", "➄",
	"6", "➅",
	"7", "➆",
	"8", "➇",
	"9", "➈",
	":", "▶",
	";", "↪",
	"a", "â", "A", "Â",
	"b", "ó", "B", "Ó",
	"c", "ç", "C", "Ç",
	"d", "★", "D", "☆",
	"e", "ê", "E", "Ê",
	"f", "⚐", "F", "⚑",
	"g", "ĝ", "G", "Ĝ",
	"h", "ĥ", "H", "Ĥ",
	"i", "î", "I", "Î",
	"j", "j", "J", "J",
	"k", "☺", "K", "☻",
	"l", "†", "L", "‡",
	"m", "✅", "M", "☑",
	"n", "ñ", "N", "Ñ",
	"o", "ô", "O", "Ô",
	"p", "¶", "P", "⁂",
	"q", "☒", "Q", "☐",
	"r", "º", "R", "°",
	"s", "ß", "S", "ẞ",
	"t", "!", "T", "¡",
	"u", "û", "U", "Û",
	"v", "✓", "V", "✔",
	"w", "ù", "W", "Ù",
	"x", "✕", "X", "✖",
	"y", "ŷ", "Y", "Ŷ",
	"z", "ẑ", "Z", "Ẑ",
	"à", "æ", "À", "Æ",
	"è", "í", "È", "Í",
	"é", "œ", "É", "Œ",
	"ê", "á", "Ê", "Á",
)

global DeadkeyMappingDiaresis := Map(
	" ", "¨", "¨", "¨",
	"0", "🄌", ; NEW
	"1", "➊",
	"2", "➋",
	"3", "➌",
	"4", "➍",
	"5", "➎",
	"6", "➏",
	"7", "➐",
	"8", "➑",
	"9", "➒",
	"a", "ä", "A", "Ä",
	"c", "©", "C", "©",
	"e", "ë", "E", "Ë",
	"h", "ḧ", "H", "Ḧ",
	"i", "ï", "I", "Ï",
	"o", "ö", "O", "Ö",
	"r", "®", "R", "®",
	"t", "™", "T", "™",
	"u", "ü", "U", "Ü",
	"w", "ẅ", "W", "Ẅ",
	"x", "ẍ", "X", "Ẍ",
	"y", "ÿ", "Y", "Ÿ",
)

global DeadkeyMappingSuperscript := Map(
	" ", "ᵉ",
	"(", "⁽", ")", "⁾",
	"+", "⁺",
	",", "ᶿ",
	"-", "⁻",
	".", "ᵝ",
	"/", "̸",
	"0", "⁰",
	"1", "¹",
	"2", "²",
	"3", "³",
	"4", "⁴",
	"5", "⁵",
	"6", "⁶",
	"7", "⁷",
	"8", "⁸",
	"9", "⁹",
	"=", "⁼",
	"a", "ᵃ", "A", "ᴬ",
	"b", "ᵇ", "B", "ᴮ",
	"c", "ᶜ", "C", "ꟲ",
	"d", "ᵈ", "D", "ᴰ",
	"e", "ᵉ", "E", "ᴱ",
	"f", "ᶠ", "F", "ꟳ",
	"g", "ᶢ", "G", "ᴳ",
	"h", "ʰ", "H", "ᴴ",
	"i", "ⁱ", "I", "ᴵ",
	"j", "ʲ", "J", "ᴶ",
	"k", "ᵏ", "K", "ᴷ",
	"l", "ˡ", "L", "ᴸ",
	"m", "ᵐ", "M", "ᴹ",
	"n", "ⁿ", "N", "ᴺ",
	"o", "ᵒ", "O", "ᴼ",
	"p", "ᵖ", "P", "ᴾ",
	"q", "𐞥", "Q", "ꟴ", ; 𐞥 is NEW
	"r", "ʳ", "R", "ᴿ",
	"s", "ˢ", "S", "", ; There is no superscript capital s yet in Unicode
	"t", "ᵗ", "T", "ᵀ",
	"u", "ᵘ", "U", "ᵁ",
	"v", "ᵛ", "V", "ⱽ",
	"w", "ʷ", "W", "ᵂ",
	"x", "ˣ", "X", "", ; There is no superscript capital x yet in Unicode
	"y", "ʸ", "Y", "", ; There is no superscript capital y yet in Unicode
	"z", "ᶻ", "Z", "", ; There is no superscript capital z yet in Unicode
	"[", "˹", "]", "˺",
	"à", "ᵡ", "À", "", ; There is no superscript capital ᵡ yet in Unicode
	"æ", "𐞃", "Æ", "ᴭ", ; 𐞃 is NEW
	"è", "ᵞ", "È", "", ; There is no superscript capital ᵞ yet in Unicode
	"é", "ᵟ", "É", "", ; There is no superscript capital ᵟ yet in Unicode
	"ê", "ᵠ", "Ê", "", ; There is no superscript capital ᵠ yet in Unicode
	"œ", "ꟹ", "Œ", "", ; There is no superscript capital œ yet in Unicode
)

global DeadkeyMappingSubscript := Map(
	" ", "ᵢ",
	"(", "₍", ")", "₎",
	"+", "₊", "-", "₋",
	"/", "̸",
	"0", "₀",
	"1", "₁",
	"2", "₂",
	"3", "₃",
	"4", "₄",
	"5", "₅",
	"6", "₆",
	"7", "₇",
	"8", "₈",
	"9", "₉",
	"=", "₌",
	"a", "ₐ", "A", "ᴀ",
	"b", "ᵦ", "B", "ʙ", ; ᵦ, not real subscript b
	"c", "", "C", "ᴄ", ; There is no subscript c yet in Unicode
	"d", "", "D", "ᴅ", ; There is no subscript d yet in Unicode
	"e", "ₑ", "E", "ᴇ", ; There is no subscript f yet in Unicode
	"f", "", "F", "ꜰ",
	"g", "ᵧ", "G", "ɢ", ; ᵧ, not real subscript g
	"h", "ₕ", "H", "ʜ",
	"i", "ᵢ", "I", "ɪ",
	"j", "ⱼ", "J", "ᴊ",
	"k", "ₖ", "K", "ᴋ",
	"l", "ₗ", "L", "ʟ",
	"m", "ₘ", "M", "ᴍ",
	"n", "ₙ", "N", "ɴ",
	"o", "ₒ", "O", "ᴏ",
	"p", "ᵨ", "P", "ₚ",
	"q", "", "Q", "ꞯ", ; There is no subscript q yet in Unicode
	"r", "ᵣ", "R", "ʀ",
	"s", "ₛ", "S", "ꜱ",
	"t", "ₜ", "T", "ᴛ",
	"u", "ᵤ", "U", "ᴜ",
	"v", "ᵥ", "V", "ᴠ",
	"w", "", "W", "ᴡ", ; There is no subscript w yet in Unicode
	"x", "ₓ", "X", "ᵪ", ; There is no subscript capital x yet in Unicode, we use subscript capital chi instead
	"y", "ᵧ", "Y", "ʏ", ; There is no subscript y yet in Unicode, we use subscript gamma instead
	"z", "", "Z", "ᴢ", ; There is no subscript z yet in Unicode
	"[", "˻", "]", "˼",
	"æ", "", "Æ", "ᴁ", ; There is no subscript æ yet in Unicode
	"è", "ᵧ", "È", "", ; There is no subscript capital ᵧ yet in Unicode
	"ê", "ᵩ", "Ê", "", ; There is no subscript capital ᵩ yet in Unicode
	"œ", "", "Œ", "ɶ", ; There is no subscript œ yet in Unicode
)

global DeadkeyMappingGreek := Map(
	" ", "µ",
	"'", "ς",
	"-", "Μ",
	"_", "Ω", ; Attention, Ohm symbol and not capital Omega
	"a", "α", "A", "Α",
	"b", "β", "B", "Β",
	"c", "ψ", "C", "Ψ",
	"d", "δ", "D", "Δ",
	"e", "ε", "E", "Ε",
	"f", "φ", "F", "Φ",
	"g", "γ", "G", "Γ",
	"h", "η", "H", "Η",
	"i", "ι", "I", "Ι",
	"j", "ξ", "J", "Ξ",
	"k", "κ", "K", "Κ",
	"l", "λ", "L", "Λ",
	"m", "μ", "M", "Μ",
	"n", "ν", "N", "Ν",
	"o", "ο", "O", "Ο",
	"p", "π", "P", "Π",
	"q", "χ", "Q", "Χ",
	"r", "ρ", "R", "Ρ",
	"s", "σ", "S", "Σ",
	"t", "τ", "T", "Τ",
	"u", "θ", "U", "Θ",
	"v", "ν", "V", "Ν",
	"w", "ω", "W", "Ω",
	"x", "ξ", "X", "Ξ",
	"y", "υ", "Y", "Υ",
	"z", "ζ", "Z", "Ζ",
	"é", "η", "É", "Η",
	"ê", "ϕ", "Ê", "", ; Alternative phi character
)

global DeadkeyMappingR := Map(
	" ", "ℝ",
	"'", "ℜ",
	"(", "⟦", ")", "⟧",
	"[", "⟦", "]", "⟧",
	"<", "⟪", ">", "⟫",
	"«", "⟪", "»", "⟫",
	"b", "", "B", "ℬ",
	"c", "", "C", "ℂ",
	"e", "", "E", "⅀",
	"f", "", "F", "ℱ",
	"g", "ℊ", "G", "ℊ",
	"h", "", "H", "ℋ",
	"j", "", "J", "ℐ",
	"l", "ℓ", "L", "ℒ",
	"m", "", "M", "ℳ",
	"n", "", "N", "ℕ",
	"p", "", "P", "ℙ",
	"q", "", "Q", "ℚ",
	"r", "", "R", "ℝ",
	"s", "", "S", "⅀",
	"t", "", "T", "ℭ",
	"u", "", "U", "ℿ",
	"x", "", "X", "ℛ",
	"z", "", "Z", "ℨ",
)

global DeadkeyMappingCurrency := Map(
	" ", "¤",
	"$", "£",
	"&", "৳",
	"'", "£",
	"-", "£",
	"_", "€",
	"``", "₰",
	"a", "؋", "A", "₳",
	"b", "₿", "B", "฿",
	"c", "¢", "C", "₵",
	"d", "₫", "D", "₯",
	"e", "€", "E", "₠",
	"f", "ƒ", "F", "₣",
	"g", "₲", "G", "₲",
	"h", "₴", "H", "₴",
	"i", "﷼", "I", "៛",
	"k", "₭", "K", "₭",
	"l", "₺", "L", "₤",
	"m", "₥", "M", "ℳ",
	"n", "₦", "N", "₦",
	"o", "௹", "O", "૱",
	"p", "₱", "P", "₧",
	"r", "₽", "R", "₹",
	"s", "₪", "S", "₷",
	"t", "₸", "T", "₮",
	"u", "元", "U", "圓",
	"w", "₩", "W", "₩",
	"y", "¥", "Y", "円",
)





; ============================
; ============================
; ======= 2/ UTILITIES =======
; ============================
; ============================

global InDeadKeySequence := false

DeadKey(Mapping) {
	global InDeadKeySequence
	InDeadKeySequence := true
	ih := InputHook(
		"L1",
		"{F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Ins}{Numlock}{PrintScreen}{Pause}{Enter}{BackSpace}{Delete}"
	)
	ih.Start()
	ih.Wait()
	PressedKey := ih.Input
	InDeadKeySequence := false
	if Mapping.Has(PressedKey) {
		SendNewResult(Mapping[PressedKey])
	} else {
		SendNewResult(PressedKey)
	}
}

UpdateLastSentCharacter(Character) {
	; Ring-buffer push is O(1) and does not reallocate past boot — see
	; ``_LSCPush`` in lib/hotstring_engine.ahk.
	_LSCPush(Character)

	global LastSentCharacterKeyTime, LAST_SENT_KEY_TIME_PRUNE_AT
	LastSentCharacterKeyTime[Character] := A_TickCount
	; Amortised-O(1) size bound: prune only when we cross the threshold.
	; Without this, a long typing session accumulates one entry per unique
	; character ever emitted (including synthetic sentinels like "LAlt"),
	; growing the Map unbounded.
	if LastSentCharacterKeyTime.Count > LAST_SENT_KEY_TIME_PRUNE_AT {
		_PruneLastSentKeyTime()
	}
}

_PruneLastSentKeyTime() {
	global LastSentCharacterKeyTime, LAST_SENT_KEY_TIME_MAX_AGE_MS
	Cutoff := A_TickCount - LAST_SENT_KEY_TIME_MAX_AGE_MS
	; Two-pass because AHK v2 Map does not support deletion mid-iteration.
	ToDelete := []
	for Char, Ts in LastSentCharacterKeyTime {
		if Ts < Cutoff {
			ToDelete.Push(Char)
		}
	}
	for _, Char in ToDelete {
		LastSentCharacterKeyTime.Delete(Char)
	}
}

RemapKey(ScanCode, Character, AlternativeCharacter := "") {
	global RemappedList
	InputLevel := "I2"

	Hotkey(
		"*" ScanCode,
		(*) => SendEvent("{Blind}" Character) UpdateLastSentCharacter(Character),
		InputLevel
	)

	if AlternativeCharacter == "" {
		RemappedList[Character] := ScanCode
	} else {
		Hotkey(
			ScanCode,
			(*) => SendEvent("{Text}" . AlternativeCharacter) UpdateLastSentCharacter(AlternativeCharacter),
			InputLevel
		)
	}

	; In theory, * and {Blind} should be sufficient, but it isn't the case when we define custom hotkeys in next sections
	; For example, a new hotkey for ^b leads to ^t giving ^b in QWERTY
	; The same happens for Win shortcuts, where we can get the shortcut on the QWERTY layer and not emulated Ergopti layer
	Hotkey(
		"^" ScanCode,
		(*) => SendEvent("^" Character) UpdateLastSentCharacter(Character),
		InputLevel
	)
	Hotkey(
		"!" ScanCode,
		(*) => SendEvent("!" Character) UpdateLastSentCharacter(Character),
		"I3" ; Needs to be higher to keep the Alt shortcuts
	)
	if Character == "l" {
		; Solves a bug of # + remapped letter L not triggering the Lock shortcup
		Hotkey(
			"#" ScanCode,
			(*) => DllCall("LockWorkStation") UpdateLastSentCharacter(Character),
			InputLevel
		)
	} else {
		Hotkey(
			"#" ScanCode,
			(*) => SendEvent("#" Character) UpdateLastSentCharacter(Character),
			InputLevel
		)
	}
}

WrapTextIfSelected(Symbol, LeftSymbol, RightSymbol) {
	Selection := ""
	if (
		isSet(UIA) and Features["shortcuts"]["wrap_text_if_selected"]
		and not WinActive("Code") ; Electron Apps like VSCode don't fully work with UIA
	) {
		try {
			el := UIA.GetFocusedElement()
			if (el.IsTextPatternAvailable) {
				Selection := el.GetSelection()[1].GetText()
			}
		}
	}

	; This regex is to not trigger the wrapping if there are only blank lines
	RegEx := "^(\r\n|\r|\n)+$"

	if Selection != "" and RegExMatch(Selection, RegEx) = 0 {
		; Send all the text instantly and without triggering hotstrings while typing it
		SendInstant(LeftSymbol Selection RightSymbol)
	} else {
		SendNewResult(Symbol) ; SendEvent({Text}) doesn't work everywhere, for example in Google Sheets
	}
	UpdateLastSentCharacter(Symbol)
}





; ============================
; =============================
; ======= 3/ BASE LAYER =======
; =============================
; ============================


; Returns true when digit keys 1-0 require Shift on the active OS keyboard
; layout (e.g. AZERTY, bépo). Uses VkKeyScanExW to probe the virtual-key
; binding for the character "1": a non-zero Shift bit in the high byte
; confirms that the OS layout places digits behind Shift.
_OsLayoutDigitsAreShifted() {
	HKL := GetForegroundKeyboardLayout()
	if (HKL = 0) {
		return false
	}
	; VkKeyScanExW returns a WORD: low byte = VK code, high byte = modifier
	; flags (bit 0 = Shift, bit 1 = Ctrl, bit 2 = Alt). A high byte of 1
	; means Shift is required to produce the character "1".
	Result := DllCall("VkKeyScanExW", "WStr", "1", "Ptr", HKL, "Short")
	HighByte := (Result >> 8) & 0xFF
	return (HighByte & 0x01) != 0
}

#HotIf Features["layout"]["direct_access_digits"]
; We need to use SendEvent for symbols, otherwise it may trigger and lock AltGr. This issue happens on AZERTY at least.
; For digits, it is better to remap with sending the down event instead of using the RemapKey function.
; Otherwise, there is a problem of digit password boxes that skips to the n+2 box instead of n+2 because two down key events are sent by key
; One example is on the password box of https://github.com/login/device where they implemented an AutoShift in the boxes

; === Number row ===
SC029:: SendNewResult("$")
SC002:: SendEvent("{1 Down}") UpdateLastSentCharacter("1")
SC002 Up:: SendEvent("{1 Up}")
SC003:: SendEvent("{2 Down}") UpdateLastSentCharacter("2")
SC003 Up:: SendEvent("{2 Up}")
SC004:: SendEvent("{3 Down}") UpdateLastSentCharacter("3")
SC004 Up:: SendEvent("{3 Up}")
SC005:: SendEvent("{4 Down}") UpdateLastSentCharacter("4")
SC005 Up:: SendEvent("{4 Up}")
SC006:: SendEvent("{5 Down}") UpdateLastSentCharacter("5")
SC006 Up:: SendEvent("{5 Up}")
SC007:: SendEvent("{6 Down}") UpdateLastSentCharacter("6")
SC007 Up:: SendEvent("{6 Up}")
SC008:: SendEvent("{7 Down}") UpdateLastSentCharacter("7")
SC008 Up:: SendEvent("{7 Up}")
SC009:: SendEvent("{8 Down}") UpdateLastSentCharacter("8")
SC009 Up:: SendEvent("{8 Up}")
SC00A:: SendEvent("{9 Down}") UpdateLastSentCharacter("9")
SC00A Up:: SendEvent("{9 Up}")
SC00B:: SendEvent("{0 Down}") UpdateLastSentCharacter("0")
SC00B Up:: SendEvent("{0 Up}")
SC00C:: SendNewResult("%")
SC00D:: SendNewResult("=")
#HotIf

; On OS layouts where digits are behind Shift (e.g. AZERTY, bépo), swap
; the layers: Shift+digit-key produces the OS native symbol (passthrough),
; while the unshifted key already sends the digit via the block above.
; SC029, SC00C, SC00D (outside the 1-0 run) are intentionally left alone.
if Features["layout"]["direct_access_digits"] and _OsLayoutDigitsAreShifted() {
	; VK codes for digits 1–0 (0x31–0x39 then 0x30) paired with scancodes SC002–SC00B.
	; ToUnicodeEx does not work on KbdEdit/custom layouts (returns the digit, not the
	; shifted symbol). GetKeyName("vkXXscYYY") queries the active layout correctly
	; and returns a single-character string for printable keys — we use that instead.
	_DIGIT_VK_SC := [
		[0x31, 0x02], [0x32, 0x03], [0x33, 0x04], [0x34, 0x05], [0x35, 0x06],
		[0x36, 0x07], [0x37, 0x08], [0x38, 0x09], [0x39, 0x0A], [0x30, 0x0B]
	]
	for Pair in _DIGIT_VK_SC {
		VK := Pair[1]
		SC := Pair[2]
		; GetKeyName with the "vkXXscYYY" form queries whatever character the
		; active layout assigns to this VK+SC combination under Shift.
		Symbol := GetKeyName("vk" . Format("{:02X}", VK) . "sc" . Format("{:03X}", SC))
		; Only bind when we got exactly one printable character back — a longer
		; string means Windows returned a key name ("F1", "Enter"…) which would
		; mean the layout does not assign a printable symbol here.
		if (StrLen(Symbol) = 1) {
			; {Text} sends the Unicode character directly, bypassing the AHK
			; keyboard hook — so the SC002–SC00B digit remaps never fire again.
			Hotkey("+" Format("SC{:03X}", SC), _DigitShiftSend.Bind(Symbol), "I2")
		}
	}
}

; Top-level helper for the shifted-symbol send — must be at module scope so
; AHK v2 hoists it before the if-block above executes.
_DigitShiftSend(Symbol, *) {
	; SendEvent {Text} bypasses the keyboard hook and sends the Unicode
	; character directly, so the SC002–SC00B digit remaps never interfere.
	SendEvent("{Text}" . Symbol)
	UpdateLastSentCharacter(Symbol)
}

; Cannot be HotIf because the remapping is done with Hotkey function and cannot be undone afterwards.
; The character mapping itself lives in lib/layout_ergopti.ahk so the
; keylogger heatmap can read the same source of truth without drifting.
if Features["layout"]["ergopti_base"] {
	for sc_int, entry in ErgoptiBaseMapping() {
		sc_str := Format("SC{:03X}", sc_int)
		if (entry is String) {
			RemapKey(sc_str, entry)
		} else if IsObject(entry) {
			alt := entry.HasOwnProp("alt") ? entry.alt : ""
			RemapKey(sc_str, entry.c, alt)
		}
	}
	; Dead keys (¨ and ^) — their behaviour goes through DeadKey()
	; rather than RemapKey, so they stay inline next to their state
	; machine. Their *positions* are still listed in
	; ErgoptiBaseLabels() so the heatmap can label them.
	Hotkey(
		"SC01B",
		(*) => (InDeadKeySequence ? SendNewResult("¨") : DeadKey(DeadkeyMappingDiaresis)),
		"I2"
	)
	Hotkey(
		"SC02B",
		(*) => (InDeadKeySequence ? SendNewResult("^") : DeadKey(DeadkeyMappingCircumflex)),
		"I2"
	)
}

if Features["hotstrings"]["magic_key"]["replace"]["enabled"] {
	RemapKey("SC02E", "j", ScriptInformation["MagicKey"])
}

; Win + ★ (SC02E) opens the personal TOML hotstring editor.
; Registered at InputLevel 3 so it overrides the #SC02E → "#j" binding that
; RemapKey installs at InputLevel 2 for the layout remapping.
Hotkey("#SC02E", (*) => OpenPersonalEditor(), "I3")





; ==============================
; ==============================
; ======= 4/ SHIFT LAYER =======
; ==============================
; ==============================

; Shift layer — bindings registered table-driven via lib/layout_shift_caps.ahk.
RegisterShiftLayer()





; =================================
; =================================
; ======= 5/ CAPSLOCK LAYER =======
; =================================
; =================================

GetCapsLockCondition() {
	return GetKeyState("CapsLock", "T") and not LayerEnabled
}

; CapsLock layer — bindings registered table-driven via lib/layout_shift_caps.ahk.
RegisterCapsLockLayer()





; =============================================
; ==============================================
; ======= 6/ ALTGR AND SHIFT+ALTGR LAYER =======
; ==============================================
; =============================================

; The AltGr roll for SC012 (= / Œ / %) is registered dynamically via
; _RegisterRollsAltGrHotkeys() below. Static ``SC138 & SC012::`` would have AHK
; promote SC138 to a prefix key at parse time, which silently breaks native
; AltGr/Kana behaviour during the first-run onboarding wizard.
_RollChevronEqualHandler(*) {
	if GetKeyState("Shift", "P") {
		Features["layout"]["ergopti_plus"] ? SendNewResult(" %") : SendNewResult("Œ")
	} else {
		AddRollEqual()
	}
}
AddRollEqual() {
	LastSentCharacter := GetLastSentCharacterAt(-1)
	if (
		LastSentCharacter == "<" or LastSentCharacter == ">")
	and A_TimeSincePriorHotkey < (HotstringsResolve("rolls", "ChevronEqual").Delay * 1000
	) {
		SendNewResult("=")
		UpdateLastSentCharacter("=")
	} else if Features["layout"]["ergopti_plus"] {
		WrapTextIfSelected("%", "%", "%")
	} else {
		SendNewResult("œ")
	}
}

; The AltGr roll for SC017 (# / " / %) is also registered dynamically — same
; rationale as the SC012 block above.
_RollHashtagQuoteHandler(*) {
	if GetKeyState("Shift", "P") {
		SendNewResult("%")
	} else {
		HashtagOrQuote()
	}
}
HashtagOrQuote() {
	LastSentCharacter := GetLastSentCharacterAt(-1)
	if (
		LastSentCharacter == "(" or LastSentCharacter == "[")
	and A_TimeSincePriorHotkey < (HotstringsResolve("rolls", "HashtagQuote").Delay * 1000
	) {
		SendNewResult("`"")
		UpdateLastSentCharacter("`"")
	} else {
		WrapTextIfSelected("#", "#", "#")
	}
}

; Dynamic registration of the two AltGr rolls. Called immediately so the
; behaviour matches the previous static blocks, but kept as a function so
; the onboarding wizard can defer it (the wizard temporarily blocks it by
; registering its hotkeys AFTER Onboarding_Run() to keep SC138 native during
; first-run setup).
_RegisterRollsAltGrHotkeys() {
	HotIf((*) => Features["hotstrings"]["rolls"]["chevron_equal"]["enabled"] and IsRealAltGrPress())
	Hotkey("SC138 & SC012", _RollChevronEqualHandler, "I2")
	HotIf((*) => Features["hotstrings"]["rolls"]["hashtag_quote"]["enabled"] and IsRealAltGrPress())
	Hotkey("SC138 & SC017", _RollHashtagQuoteHandler, "I2")
	HotIf()
}

; ─────────────────────────────────────────────────────────────────────────────
; AltGr layer (ErgoptiPlus overrides + ErgoptiAltGr Number row + base rows).
; The original ~390 lines of repetitive ``SC138 & SCxxx::`` blocks are now
; defined as data in lib/layout_altgr.ahk and registered here through a
; single dispatcher. Registration order is preserved so AHK's
; "most-recently-defined variant wins" rule still resolves identically when
; multiple Layout sub-features are simultaneously enabled.
; ─────────────────────────────────────────────────────────────────────────────
_RegisterRollsAltGrHotkeys()
RegisterAltGrLayer()





; ================================
; ================================
; ======= 7/ CONTROL LAYER =======
; ================================
; ================================

#HotIf Features["layout"]["ergopti_base"]
^SC02F:: SendFinalResult("^v") ; Correct issue where Win + V paste doesn't work
*^SC00C:: SendFinalResult("^{NumpadSub}") ; Zoom out with Ctrl + %
*^SC00D:: SendFinalResult("^{NumpadAdd}") ; Zoom in with Ctrl + $
#HotIf

; In Microsoft apps like Word or Excel, we can't use Numpad + to zoom
#HotIf Features["layout"]["ergopti_base"] and MicrosoftApps()
*^SC00C:: SendFinalResult("^{WheelDown}") ; Zoom out with (Shift +) Ctrl + %
*^SC00D:: SendFinalResult("^{WheelUp}") ; Zoom in with (Shift +) Ctrl + $
#HotIf
