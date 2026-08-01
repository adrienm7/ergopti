; modules/hotstrings/hotstrings_text_expansion.ahk

; ==============================================================================
; MODULE: Hotstrings — Text Expansion & Dynamic Hotstrings
; DESCRIPTION:
; Registers the text-expansion categories (suffixes_a, personal-info @-combos,
; magic-key text-expansion) and the dynamic hotstrings (dates, phone/SSN/IBAN
; prefixes, repeat key). Extracted from modules/hotstrings.ahk to keep the
; expansion logic readable in isolation.
;
; FEATURES & RATIONALE:
; 1. Personal info combos: @bic★, @ss★, @tel★, and all multi-letter combos
;    generated at startup from the user's personal_info.toml. Tab-separated when
;    multiple fields are combined.
; 2. Magic-key text expansion: delegates to _RegisterTextExpansionSections()
;    so the boot and live-rebuild paths share exactly one code path.
; 3. Dynamic hotstrings: dates resolved at fire time (never stale), and phone /
;    SSN / IBAN prefix triggers that auto-expand the full number.
; ==============================================================================





; ============================================================================
; ============================================================================
; ======= 1/ Text expansion & dynamic hotstrings registration function =======
; ============================================================================
; ============================================================================

; Registers Sections 4–5 of modules/hotstrings.ahk (text expansion + dynamic).
; DeferHeavy must match the caller's intent — true on the boot pass, false on
; live rebuilds. _RegisterTextExpansionSections() and SpaceAroundSymbols are
; defined outside this function (hotstrings_helpers.ahk and the orchestrator).
_HS_RegisterTextExpansionAndDynamic(DeferHeavy := false) {
	global Features, ScriptInformation, PersonalInformation, PersonalInformationLetters
	global PersonalInformationHotstrings, DYN_HOTSTRINGS_DEFAULT_DELAY, SpaceAroundSymbols





	; ================================
	; =================================
	; ======= 4/ TEXT EXPANSION =======
	; =================================
	; ================================




	; ================================
	; ===== 4.1) Suffixes with À =====
	; ================================

	if Features["hotstrings"]["distances_reduction"]["suffixes_a"]["enabled"] {
		LoadHotstringsSection("distancesreduction", "suffixes_a", Features["hotstrings"]["distances_reduction"]["suffixes_a"])
	}




	; ======================================================
	; ===== 4.2) Personal information shortcuts with @ =====
	; ======================================================

	if Features["hotstrings"]["dynamic"]["text_expansion_personal_information"]["enabled"] {
		CreateHotstring("*", "@bic" . ScriptInformation["MagicKey"], PersonalInformation["bic"], Map("FinalResult",
			True))
		CreateHotstring("*", "@cb" . ScriptInformation["MagicKey"], PersonalInformation["credit_card"], Map(
			"FinalResult",
			True))
		CreateHotstring("*", "@cc" . ScriptInformation["MagicKey"], PersonalInformation["credit_card"], Map(
			"FinalResult",
			True))
		CreateHotstring("*", "@iban" . ScriptInformation["MagicKey"], PersonalInformation["iban"], Map("FinalResult",
			True))
		CreateHotstring("*", "@rib" . ScriptInformation["MagicKey"], PersonalInformation["iban"], Map("FinalResult",
			True))
		CreateHotstring("*", "@ss" . ScriptInformation["MagicKey"], PersonalInformation["social_security_number"], Map(
			"FinalResult", True))
		CreateHotstring("*", "@tel" . ScriptInformation["MagicKey"], PersonalInformation["phone_number"], Map(
			"FinalResult",
			True))
		CreateHotstring("*", "@tél" . ScriptInformation["MagicKey"], PersonalInformation["phone_number"], Map(
			"FinalResult",
			True))

		; Map a letter to a value (n ➜ Nom, t ➜ 0606060606, etc.)
		; Declared global at the top of RegisterAllHotstrings — re-init it on every run.
		PersonalInformationHotstrings := Map()
		for InfoKey, InfoValue in PersonalInformationLetters {
			PersonalInformationHotstrings[InfoKey] := PersonalInformation[InfoValue]
		}

		; Generate all possible combinations of letters between 1 and PatternMaxLength characters
		GeneratePersonalInformationHotstrings(
			PersonalInformationHotstrings,
			Features["hotstrings"]["dynamic"]["text_expansion_personal_information"]["pattern_max_length"]
		)

		GeneratePersonalInformationHotstrings(hotstrings, maxLen) {
			keys := []
			; ``hotstrings`` is a Map keyed by the alias LETTER (n, t, …); the combo
			; generator needs those keys, not the personal-data values. The 2-var Map
			; enumerator binds (key, value), so iterate `k, _` and push the KEY -- a
			; mechanical `for _, k` rewrite once seeded the values here and killed every
			; @<letter> combo (a Map is not an Array)
			for k, _ in hotstrings
				keys.Push(k)
			loop maxLen
				Generate(keys, hotstrings, "", A_Index)
		}

		; In case email is "^a" we want to send raw string and not Ctrl + A
		EscapeSpecialChars(text) {
			; Escape braces atomically so the '{' -> '{{}'  expansion does not feed a
			; '}' into a later StrReplace pass (which would corrupt '{' into '{{{}}}')
			escaped := ""
			loop parse, text {
				c := A_LoopField
				if (c == "{")
					escaped .= "{{}"
				else if (c == "}")
					escaped .= "{}}"
				else
					escaped .= c
			}
			; The remaining escapes do not emit '{' or '}' so sequential StrReplace is safe
			escaped := StrReplace(escaped, "^", "{Asc 94}")
			escaped := StrReplace(escaped, "~", "{Asc 126}")
			escaped := StrReplace(escaped, "+", "{+}")
			escaped := StrReplace(escaped, "!", "{!}")
			escaped := StrReplace(escaped, "#", "{#}")
			return escaped
		}

		Generate(keys, hotstrings, combo, len) {
			if (len == 0) {
				value := ""
				loop parse, combo {
					if (hotstrings.Has(A_LoopField)) {
						if (value != "") {
							value := value . "{Tab}"
						}

						value := value . hotstrings[A_LoopField]
					}
				}
				if (value != "") {
					CreateHotstringCombo(combo, EscapeSpecialChars(value))
				}
				return
			}
			for _, key in keys {
				Generate(keys, hotstrings, combo . key, len - 1)
			}
		}

		CreateHotstringCombo(combo, value) {
			CreateHotstring("*", "@" combo "" . ScriptInformation["MagicKey"], value, Map("OnlyText", False).Set(
				"FinalResult", True))
		}

		; Generate manually longer shortcuts, as increasing PatternMaxLength expands memory exponentially
		CreateHotstringComboAuto(Combo) {
			global PersonalInformationHotstrings
			Value := ""
			loop StrLen(Combo) {
				ComboLetter := SubStr(Combo, A_Index, 1)
				; The letters Map is user-editable (personal_info.toml [letters]); a
				; missing alias must skip this optional convenience combo, not throw an
				; UnsetItemError on the boot-critical registration thread. Mirror the
				; Generate() guard and fail loud in the log (fail-soft, §5.3)
				if !PersonalInformationHotstrings.Has(ComboLetter) {
					LoggerWarn("hotstrings", "CreateHotstringComboAuto: letter '{1}' absent from personal-info map -- skipping combo '@{2}'.", ComboLetter, Combo)
					return
				}
				Value := Value . EscapeSpecialChars(PersonalInformationHotstrings[ComboLetter]) . "{Tab}"
			}
			CreateHotstring("*", "@" . Combo . ScriptInformation["MagicKey"], Value, Map("OnlyText", False).Set(
				"FinalResult", True))
		}
		CreateHotstringComboAuto("mm")
		CreateHotstringComboAuto("mnp")
		CreateHotstringComboAuto("mpn")
		CreateHotstringComboAuto("np")
		CreateHotstringComboAuto("npam")
		CreateHotstringComboAuto("npamm")
		CreateHotstringComboAuto("npd")
		CreateHotstringComboAuto("npdm")
		CreateHotstringComboAuto("npdmm")
		CreateHotstringComboAuto("npdmmt")
		CreateHotstringComboAuto("npdmt")
		CreateHotstringComboAuto("npm")
		CreateHotstringComboAuto("npmd")
		CreateHotstringComboAuto("npmm")
		CreateHotstringComboAuto("npmmd")
		CreateHotstringComboAuto("npmt")
		CreateHotstringComboAuto("npt")
		CreateHotstringComboAuto("nptm")
		CreateHotstringComboAuto("nptmm")
		CreateHotstringComboAuto("pn")
		CreateHotstringComboAuto("pnam")
		CreateHotstringComboAuto("pnamm")
		CreateHotstringComboAuto("pnd")
		CreateHotstringComboAuto("pndm")
		CreateHotstringComboAuto("pndmm")
		CreateHotstringComboAuto("pnm")
		CreateHotstringComboAuto("pnmm")
		CreateHotstringComboAuto("pntm")
		CreateHotstringComboAuto("pntmd")
		CreateHotstringComboAuto("pntmm")
		CreateHotstringComboAuto("pntmmd")
	}
	try BootProfile_Mark("HS sub: @-personal-info combos registered")




	; ======================================
	; ===== 4.3) Text expansion with ★ =====
	; ======================================

	; The magic-key text-expansion sections are the MOST-USED feature (more than the
	; rolls), so despite being a heavy registration category (~1060 conform specs,
	; ~240 ms) they register ON the boot critical path, unconditionally, on BOTH the
	; boot pass and live rebuilds. Rationale: "ready" must mean the user's everyday
	; expansions already work, not that they come online ~half a second later; and the
	; ~240 ms registration is far better paid at boot (nobody is typing) than on a
	; post-"ready" timer that would freeze the single thread mid-keystroke. Only the
	; truly heavy + rarely-instant emoji/symbol categories stay deferred (4.4-4.5).
	_RegisterTextExpansionSections()
	try BootProfile_Mark("HS sub: magickey text_expansion registered")




	; ===============================================
	; ===== 4.4-4.5) Emojis & symbols (deferrable) ===
	; ===============================================

	; The emoji + symbol categories are by far the heaviest (~3000 registrations,
	; ~410 ms). On the boot pass (DeferHeavy = true) they are skipped here and loaded
	; off the critical path by RegisterEmojisSymbolsDeferred() below; on a live
	; rebuild (DeferHeavy = false) they load inline, exactly as before.
	if !DeferHeavy {
		_RegisterEmojisSymbolsSections()
	}





	; =====================================
	; =====================================
	; ======= 5/ Dynamic hotstrings =======
	; =====================================
	; =====================================

	; Effective activation delay for the dynamic hotstrings: the user's
	; "dynamichotstrings" delay override when set, otherwise the shared default
	; DYN_HOTSTRINGS_DEFAULT_DELAY (defined in infra/hotstrings/hotstrings_config.ahk,
	; the early-loaded layer the tray menu also reads). No category TOML backs this
	; key, so HotstringsResolve reports HasOverride=false until the user sets one
	; from the tray "Delays" submenu (mirrors the macOS dynamichotstrings delay item).
	_DynamicHotstringDelay() {
		global DYN_HOTSTRINGS_DEFAULT_DELAY
		R := HotstringsResolve("dynamichotstrings", "")
		return R.HasOverride ? R.Delay : DYN_HOTSTRINGS_DEFAULT_DELAY
	}

	; Returns the shortest prefix of a spaced string that contains exactly RawCount
	; non-space characters. Used to build the "spaced" trigger for SSN and IBAN.
	SpacedPrefix(SpacedStr, RawCount) {
		Seen := 0
		Loop Parse, SpacedStr {
			if A_LoopField != " "
				Seen++
			if Seen >= RawCount
				return SubStr(SpacedStr, 1, A_Index)
		}
		return SpacedStr  ; Fallback — fewer raw chars than requested
	}




	; =====================
	; ===== 5.1) Date =====
	; =====================

	; @dt★, @td★, @date★ resolved at fire time — cannot be static TOML entries.
	; "??" flag required: after a prior expansion the output lands immediately
	; before the next "@", so the word boundary before "@" is a digit or letter —
	; not a terminator. Without "?", HSE rejects the match and the shorter
	; "t★" (InWord=true) wins instead.
	_DateShortFr(*) {
		return FormatTime(, "dd/MM/yyyy")
	}
	_DateLongFr(*) {
		; A_WDay: 1=Sunday, 2=Monday, …, 7=Saturday
		days   := ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
		months := ["janvier", "février", "mars", "avril", "mai", "juin",
		           "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
		return days[A_WDay] . " " . FormatTime(, "d") . " " . months[FormatTime(, "M") + 0] . " " . FormatTime(, "yyyy")
	}
	_DateIso(*) {
		return FormatTime(, "yyyy_MM_dd")
	}
	MK := ScriptInformation["MagicKey"]
	; The dynamic hotstrings (dates + phone/SSN/IBAN prefixes) share one activation
	; delay gate so they fire only when the trigger was typed within the configured
	; window. Resolve it once and reuse the options Map for every registration below.
	_DynOpts := Map("FinalResult", True, "TimeActivationSeconds", _DynamicHotstringDelay())
	if Features["hotstrings"]["dynamic"]["date_fr"]["enabled"] {
		CreateHotstring("*?", "@dt" . MK, _DateShortFr, _DynOpts)
	}
	if Features["hotstrings"]["dynamic"]["date_long_fr"]["enabled"] {
		CreateHotstring("*?", "@date" . MK, _DateLongFr, _DynOpts)
	}
	if Features["hotstrings"]["dynamic"]["date"]["enabled"] {
		CreateHotstring("*?", "@td" . MK, _DateIso, _DynOpts)
	}




	; ==================================================
	; ===== 5.2) Phone, SSN and IBAN prefix expand =====
	; ==================================================

	; Prefix-based hotstrings derived from the user's personal data.
	; Registered once at startup from PersonalInformation — same logic as HS rules_engine.
	; Each trigger auto-expands without end-char (*) and is case-sensitive (C).
	Phone  := PersonalInformation["phone_number"]        ; e.g. "0606060606"
	FPhone := PersonalInformation["phone_number_clean"]   ; e.g. "06 06 06 06 06"
	Ssn    := PersonalInformation["social_security_number"] ; e.g. "1 99 99 99 999 999 99"
	Iban   := PersonalInformation["iban"]               ; e.g. "FR00 0000 0000 0000 0000 0000 000"

	; Strip spaces for matching purposes (SSN / IBAN contain decorative spaces)
	SsnRaw  := StrReplace(Ssn,  " ", "")
	IbanRaw := StrReplace(Iban, " ", "")

	if Features["hotstrings"]["dynamic"]["phone_prefixes"]["enabled"] {
		; Mirrors HS: phone[1:2]+★, +33+phone[1:2], phone[1:4], +33+phone[2:4], phone[2:5], fphone[1:5]
		MK := ScriptInformation["MagicKey"]
		if StrLen(Phone) >= 2 {
			CreateHotstring("*C", SubStr(Phone, 1, 2) . MK, (*) => Phone, _DynOpts)
			CreateHotstring("*C", "+33" . SubStr(Phone, 1, 2), (*) => "+33" . SubStr(Phone, 2), _DynOpts)
		}
		if StrLen(Phone) >= 4 {
			CreateHotstring("*C", SubStr(Phone, 1, 4), (*) => Phone, _DynOpts)
			CreateHotstring("*C", "+33" . SubStr(Phone, 2, 3), (*) => "+33" . SubStr(Phone, 2), _DynOpts)
		}
		if StrLen(Phone) >= 6 {
			CreateHotstring("*C", SubStr(Phone, 2, 4), (*) => Phone, _DynOpts)
		}
		if StrLen(FPhone) >= 5 {
			CreateHotstring("*C", SubStr(FPhone, 1, 5), (*) => FPhone, _DynOpts)
		}
	}

	if Features["hotstrings"]["dynamic"]["ssn_prefixes"]["enabled"] {
		; No-space trigger → SSN without spaces; spaced trigger → SSN with spaces.
		; Both use the first 5 raw digits as the distinguishing prefix.
		if StrLen(SsnRaw) >= 5 {
			SsnRawPrefix  := SubStr(SsnRaw, 1, 5)
			SsnSpacedPfx  := SpacedPrefix(Ssn, 5)
			CreateHotstring("*C", SsnRawPrefix,  (*) => SsnRaw, _DynOpts)
			if SsnSpacedPfx != SsnRawPrefix {
				CreateHotstring("*C", SsnSpacedPfx, (*) => Ssn, _DynOpts)
			}
		}
	}

	if Features["hotstrings"]["dynamic"]["iban_prefixes"]["enabled"] {
		; 6 raw chars (case-insensitive) → IBAN without spaces.
		; 7 spaced chars (e.g. "FR76 XX") → IBAN with spaces.
		; Both triggers fire at the 6th raw character typed.
		if StrLen(IbanRaw) >= 6 {
			IbanRawPrefix    := SubStr(IbanRaw, 1, 6)
			IbanSpacedPfx    := SpacedPrefix(Iban, 6)
			; No C flag = case-insensitive matching for the letter prefix (e.g. "fr76")
			CreateHotstring("*", IbanRawPrefix,  (*) => StrReplace(Iban, " ", ""), _DynOpts)
			if IbanSpacedPfx != IbanRawPrefix {
				CreateHotstring("*", IbanSpacedPfx, (*) => Iban, _DynOpts)
			}
		}
	}




	; ===========================
	; ===== 4.6) Repeat key =====
	; ===========================

	; ★ becomes a repeat key. It will activate will the lowest priority of all hotstrings
	; That means a letter will only be repeated if no hotstring defined above matches
	if Features["hotstrings"]["magic_key"]["repeat_corrections"]["enabled"] {
		LoadHotstringsSection("magickey", "repeat_corrections", Features["hotstrings"]["magic_key"]["repeat_corrections"])
	}
	try BootProfile_Mark("HS sub: dynamic + repeat-key registered")
}
