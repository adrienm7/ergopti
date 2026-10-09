; infra/redact.ahk

; ==============================================================================
; MODULE: Diagnostics Redaction
; DESCRIPTION:
; AHK port of _shared/lua/diagnostics/redact.lua: removes what must not leave
; the machine from diagnostic text before it is copied, saved or sent to a
; GitHub issue — token-like secrets, the home folder and the account name. The
; rules are data in _shared/modules/diagnostics/redaction.json and both ports
; replay _shared/tests/corpus/diagnostics/redaction_vectors.json.
;
; FEATURES & RATIONALE:
; 1. Secrets first, so a token that happens to contain the account name is
;    removed whole rather than half-rewritten.
; 2. The home folder in both slash styles, case-insensitively when the caller
;    says paths compare so (Windows), and only as a whole path.
; 3. The account name only as a whole word of a minimum length: a one-letter
;    account name replaced everywhere would shred the report.
; 4. Case folding is ASCII-only, as in the Lua port, so the two agree.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Character Classes =======
; ====================================
; ====================================

; True when the character at Index exists and belongs to the named class.
; @param Text {String}
; @param Index {Integer} 1-based position.
; @param Class {String} "alnum", "word", "word_dash", "path", "bearer",
;   "space", "quote", "separator" or "value_stop".
; @returns {Boolean}
_Redact_CharIs(Text, Index, Class) {
	if (Index < 1 || Index > StrLen(Text))
		return false
	Code := Ord(SubStr(Text, Index, 1))
	IsAlnum := (Code >= 0x30 && Code <= 0x39) || (Code >= 0x41 && Code <= 0x5A)
		|| (Code >= 0x61 && Code <= 0x7A)
	switch Class, true {
		case "alnum":
			return IsAlnum
		case "word":
			return IsAlnum || Code = 0x5F
		case "word_dash":
			return IsAlnum || Code = 0x5F || Code = 0x2D
		case "path":
			return IsAlnum || Code = 0x5F || Code = 0x2E || Code = 0x2D
		case "bearer":
			return IsAlnum || InStr("._~+/=-", Chr(Code), true) > 0
		case "space":
			return Code = 0x20 || Code = 0x09
		case "quote":
			return Code = 0x22 || Code = 0x27
		case "separator":
			return Code = 0x3D || Code = 0x3A
		case "value_stop":
			; Whitespace as Lua's %s sees it, then the two quotes, comma,
			; semicolon, closing parenthesis, closing brace and ampersand
			return (Code >= 0x09 && Code <= 0x0D) || Code = 0x20 || Code = 0x22
				|| Code = 0x27 || Code = 0x2C || Code = 0x3B || Code = 0x29
				|| Code = 0x7D || Code = 0x26
	}
	throw ValueError("redact: unknown character class '" . Class . "'.")
}

; Returns the index of the last character of the run of Class starting at From.
; @param Text {String}
; @param From {Integer}
; @param Class {String}
; @returns {Integer} The run's last index, From - 1 when the run is empty.
_Redact_RunEnd(Text, From, Class) {
	Index := From
	while _Redact_CharIs(Text, Index, Class)
		Index += 1
	return Index - 1
}

; Counts the code points of a string (a surrogate pair counts once).
; @param Text {String}
; @returns {Integer}
_Redact_CodePointCount(Text) {
	Count := 0
	Loop Parse Text {
		Code := Ord(A_LoopField)
		if !(Code >= 0xDC00 && Code <= 0xDFFF)
			Count += 1
	}
	return Count
}





; ======================================
; ======================================
; ======= 2/ Generic Replacement =======
; ======================================
; ======================================

; Replaces every accepted occurrence of Needle, scanning left to right.
; @param Text {String}
; @param Needle {String} Non-empty literal.
; @param CaseInsensitive {Boolean} ASCII-only folding.
; @param Accept {Func} (Text, First, Last) → Map { text, last } or 0 to skip.
; @returns {String}
_Redact_Replace(Text, Needle, CaseInsensitive, Accept) {
	Out := ""
	Pos := 1
	NeedleLen := StrLen(Needle)
	Loop {
		First := InStr(Text, Needle, CaseInsensitive ? false : true, Pos)
		if !First
			break
		Last := First + NeedleLen - 1
		Result := Accept.Call(Text, First, Last)
		if (Result is Map) {
			Out .= SubStr(Text, Pos, First - Pos) . Result["text"]
			Pos := Result["last"] + 1
		} else {
			Out .= SubStr(Text, Pos, First - Pos + 1)
			Pos := First + 1
		}
	}
	return Out . SubStr(Text, Pos)
}





; ============================
; ============================
; ======= 3/ The Rules =======
; ============================
; ============================

; Accepts a token prefix followed by a long run of its charset.
_Redact_AcceptToken(Rules, Token, Text, First, Last) {
	if _Redact_CharIs(Text, First - 1, "word")
		return 0
	Stop := _Redact_RunEnd(Text, Last + 1, Token["charset"])
	if (Stop - Last < Token["min_length"])
		return 0
	return Map("text", Rules["secret_placeholder"], "last", Stop)
}

; Accepts "Bearer <token>" and keeps the word and its spacing.
_Redact_AcceptBearer(Rules, Text, First, Last) {
	if _Redact_CharIs(Text, First - 1, "word")
		return 0
	Spaces := _Redact_RunEnd(Text, Last + 1, "space")
	if (Spaces == Last)
		return 0
	Stop := _Redact_RunEnd(Text, Spaces + 1, "bearer")
	if (Stop - Spaces < Rules["bearer_min_length"])
		return 0
	return Map("text", SubStr(Text, First, Spaces - First + 1) . Rules["secret_placeholder"], "last", Stop)
}

; Accepts key=value / "key": "value" and keeps the key and separator.
_Redact_AcceptKeyValue(Rules, Text, First, Last) {
	if _Redact_CharIs(Text, First - 1, "word") || _Redact_CharIs(Text, Last + 1, "word")
		return 0
	Index := Last + 1
	if _Redact_CharIs(Text, Index, "quote")
		Index += 1
	Index := _Redact_RunEnd(Text, Index, "space") + 1
	if !_Redact_CharIs(Text, Index, "separator")
		return 0
	Index := _Redact_RunEnd(Text, Index + 1, "space") + 1
	if _Redact_CharIs(Text, Index, "quote")
		Index += 1
	Stop := Index
	while (Stop <= StrLen(Text) && !_Redact_CharIs(Text, Stop, "value_stop"))
		Stop += 1
	Stop -= 1
	if (_Redact_CodePointCount(SubStr(Text, Index, Stop - Index + 1)) < Rules["secret_value_min_length"])
		return 0
	return Map("text", SubStr(Text, First, Index - First) . Rules["secret_placeholder"], "last", Stop)
}

; Accepts the home folder only as a whole path.
_Redact_AcceptHome(Rules, Text, First, Last) {
	if _Redact_CharIs(Text, Last + 1, "path")
		return 0
	return Map("text", Rules["home_placeholder"], "last", Last)
}

; Accepts the account name only as a whole word.
_Redact_AcceptAccount(Rules, Text, First, Last) {
	if _Redact_CharIs(Text, First - 1, "word") || _Redact_CharIs(Text, Last + 1, "word")
		return 0
	return Map("text", Rules["account_placeholder"], "last", Last)
}





; =============================
; =============================
; ======= 4/ Public API =======
; =============================
; =============================

; Redacts diagnostic text before it leaves the machine.
; @param Text {String}
; @param Rules {Map} Parsed _shared/modules/diagnostics/redaction.json.
; @param Context {Map} { home, user, case_insensitive } — the platform's home
;   folder, account name, and whether its paths compare case-insensitively.
; @returns {String}
Redact_Apply(Text, Rules, Context) {
	if !(Rules is Map)
		throw TypeError("redact: Rules must be the parsed redaction.json.")
	Folded := Context.Get("case_insensitive", false) ? true : false
	for Token in Rules["token_prefixes"] {
		; Validated before scanning, so a bad rule fails even on text that never
		; contains its prefix
		if !(Token["charset"] == "alnum" || Token["charset"] == "word"
			|| Token["charset"] == "word_dash")
			throw ValueError("redact: unknown charset '" . Token["charset"] . "'.")
		Text := _Redact_Replace(Text, Token["prefix"], false,
			_Redact_AcceptToken.Bind(Rules, Token))
	}
	Text := _Redact_Replace(Text, "bearer", true, _Redact_AcceptBearer.Bind(Rules))
	for Key in Rules["secret_keys"]
		Text := _Redact_Replace(Text, Key, true, _Redact_AcceptKeyValue.Bind(Rules))

	Home := RegExReplace(Context.Get("home", ""), "[/\\]+$")
	if (Home != "") {
		Seen := Map()
		for Spelling in [Home, StrReplace(Home, "\", "/"), StrReplace(Home, "/", "\")] {
			if Seen.Has(Spelling)
				continue
			Seen[Spelling] := true
			Text := _Redact_Replace(Text, Spelling, Folded, _Redact_AcceptHome.Bind(Rules))
		}
	}

	User := Context.Get("user", "")
	if (User != "" && _Redact_CodePointCount(User) >= Rules["min_account_name_length"])
		Text := _Redact_Replace(Text, User, Folded, _Redact_AcceptAccount.Bind(Rules))
	return Text
}
