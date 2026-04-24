; static/drivers/autohotkey/modules/layout.ahk

; ==============================================================================
; MODULE: Layout
; DESCRIPTION:
; Defines all physical key remappings for the Ergopti keyboard layout.
; Covers the base layer, Shift, CapsLock, AltGr/ShiftAltGr, and Control
; variants, as well as all dead-key mapping tables.
; ==============================================================================




; ======================================
; ======================================
; ======= 1/ DEAD KEY DEFINITIONS =======
; ======================================
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
		isSet(UIA) and Features["Shortcuts"]["WrapTextIfSelected"].Enabled
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
; ============================
; ======= 3/ BASE LAYER =======
; ============================
; ============================

#HotIf Features["Layout"]["DirectAccessDigits"].Enabled
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

; Cannot be HotIf because the remapping is done with Hotkey function and cannot be undone afterwards
if Features["Layout"]["ErgoptiBase"].Enabled {
	RemapKey("SC039", " ")

	; === Top row ===
	RemapKey("SC010", Features["Shortcuts"]["EGrave"].Letter, "è")
	RemapKey("SC011", "y")
	RemapKey("SC012", "o")
	RemapKey("SC013", "w")
	RemapKey("SC014", "b")
	RemapKey("SC015", "f")
	RemapKey("SC016", "g")
	RemapKey("SC017", "h")
	RemapKey("SC018", "c")
	RemapKey("SC019", "x")
	RemapKey("SC01A", "z")
	Hotkey(
		"SC01B",
		(*) => (InDeadKeySequence ? SendNewResult("¨") : DeadKey(DeadkeyMappingDiaresis)),
		"I2"
	)

	; === Middle row ===
	RemapKey("SC01E", "a")
	RemapKey("SC01F", "i")
	RemapKey("SC020", "e")
	RemapKey("SC021", "u")
	RemapKey("SC022", ".")
	RemapKey("SC023", "v")
	RemapKey("SC024", "s")
	RemapKey("SC025", "n")
	RemapKey("SC026", "t")
	RemapKey("SC027", "r")
	RemapKey("SC028", "q")
	Hotkey(
		"SC02B",
		(*) => (InDeadKeySequence ? SendNewResult("^") : DeadKey(DeadkeyMappingCircumflex)),
		"I2"
	)

	; === Bottom row ===
	RemapKey("SC056", Features["Shortcuts"]["ECirc"].Letter, "ê")
	RemapKey("SC02C", Features["Shortcuts"]["EAcute"].Letter, "é")
	RemapKey("SC02D", Features["Shortcuts"]["AGrave"].Letter, "à")
	RemapKey("SC02E", "j")
	RemapKey("SC02F", ",")
	RemapKey("SC030", "k")
	RemapKey("SC031", "m")
	RemapKey("SC032", "d")
	RemapKey("SC033", "l")
	RemapKey("SC034", "p")
	RemapKey("SC035", "'")
}

if Features["MagicKey"]["Replace"].Enabled {
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
; =============================================
; ======= 6/ ALTGR AND SHIFT+ALTGR LAYER =======
; =============================================
; =============================================

; This code comes before remapping ErgoptiAltGr to be able to override the keys
#HotIf Features["Rolls"]["ChevronEqual"].Enabled
SC138 & SC012:: {
	if GetKeyState("Shift", "P") {
		Features["Layout"]["ErgoptiPlus"].Enabled ? SendNewResult(" %") : SendNewResult("Œ")
	} else {
		AddRollEqual()
	}
}
AddRollEqual() {
	LastSentCharacter := GetLastSentCharacterAt(-1)
	if (
		LastSentCharacter == "<" or LastSentCharacter == ">")
	and A_TimeSincePriorHotkey < (Features["Rolls"]["ChevronEqual"].TimeActivationSeconds * 1000
	) {
		SendNewResult("=")
		UpdateLastSentCharacter("=")
	} else if Features["Layout"]["ErgoptiPlus"].Enabled {
		WrapTextIfSelected("%", "%", "%")
	} else {
		SendNewResult("œ")
	}
}
#HotIf

#HotIf Features["Rolls"]["HashtagQuote"].Enabled
SC138 & SC017:: {
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
	and A_TimeSincePriorHotkey < (Features["Rolls"]["HashtagQuote"].TimeActivationSeconds * 1000
	) {
		SendNewResult("`"")
		UpdateLastSentCharacter("`"")
	} else {
		WrapTextIfSelected("#", "#", "#")
	}
}
#HotIf

; ─────────────────────────────────────────────────────────────────────────────
; AltGr layer (ErgoptiPlus overrides + ErgoptiAltGr Number row + base rows).
; The original ~390 lines of repetitive ``SC138 & SCxxx::`` blocks are now
; defined as data in lib/layout_altgr.ahk and registered here through a
; single dispatcher. Registration order is preserved so AHK's
; "most-recently-defined variant wins" rule still resolves identically when
; multiple Layout sub-features are simultaneously enabled.
; ─────────────────────────────────────────────────────────────────────────────
RegisterAltGrLayer()


; ================================
; ================================
; ======= 7/ CONTROL LAYER =======
; ================================
; ================================

#HotIf Features["Layout"]["ErgoptiBase"].Enabled
^SC02F:: SendFinalResult("^v") ; Correct issue where Win + V paste doesn't work
*^SC00C:: SendFinalResult("^{NumpadSub}") ; Zoom out with Ctrl + %
*^SC00D:: SendFinalResult("^{NumpadAdd}") ; Zoom in with Ctrl + $
#HotIf

; In Microsoft apps like Word or Excel, we can't use Numpad + to zoom
#HotIf Features["Layout"]["ErgoptiBase"].Enabled and MicrosoftApps()
*^SC00C:: SendFinalResult("^{WheelDown}") ; Zoom out with (Shift +) Ctrl + %
*^SC00D:: SendFinalResult("^{WheelUp}") ; Zoom in with (Shift +) Ctrl + $
#HotIf
