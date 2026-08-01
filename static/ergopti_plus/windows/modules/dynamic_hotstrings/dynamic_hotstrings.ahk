; modules/dynamic_hotstrings/dynamic_hotstrings.ahk

; ==============================================================================
; MODULE: Dynamic Hotstrings
; DESCRIPTION:
; Hotstrings whose replacement is computed at fire time rather than read from a
; TOML: the three date formats, and the phone / SSN / IBAN prefix expansions
; derived from the user's personal information.
;
; FEATURES & RATIONALE:
; 1. Same folder name as the other two drivers. macOS and Linux both keep this
;    behaviour in modules/dynamic_hotstrings/; on Windows it lived inside
;    modules/hotstrings/hotstrings_text_expansion.ahk, so the one subsystem the
;    three drivers agree about the shape of had two names and one hiding place.
; 2. Resolved at fire time, never registered as text: a date registered as a
;    string is stale the next day, which is the whole reason these are not
;    corpus entries.
; 3. One activation-delay gate for every registration here, resolved once — the
;    user's "dynamichotstrings" override when set, the shared default otherwise.
;
; ORDERING CONTRACT: _DynHS_RegisterAll() must be called from exactly where
; section 5 used to sit in _HS_RegisterTextExpansionAndDynamic — after the
; emoji/symbol sections and BEFORE the repeat-key registration. The engine's
; collision tiebreak falls through to registration order, so moving the call
; changes which of two equal-length triggers wins.
; ==============================================================================

#Requires Autohotkey v2.0+




; =====================================
; =====================================
; ======= 1/ Helpers ==================
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
; ===== 1.1) Date =====
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



; ==========================================
; ==========================================
; ======= 2/ Registration ==================
; ==========================================
; ==========================================

; Registers every dynamic hotstring. Reads the feature gates, the magic key and
; PersonalInformation from the globals the driver has already populated by the
; time hotstring registration runs.
_DynHS_RegisterAll() {
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
	; ===== 2.1) Phone, SSN and IBAN prefix expand =====
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
}
