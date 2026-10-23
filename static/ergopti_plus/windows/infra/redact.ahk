; infra/redact.ahk

; ==============================================================================
; MODULE: Diagnostics Redaction
; DESCRIPTION:
; AHK port of _shared/lua/diagnostics/redact.lua: removes what must not leave
; the machine from diagnostic text before it is copied, saved or sent to a
; GitHub issue — token-like secrets (URL credentials included), the home folder,
; the account name, other accounts' profile folders, the folder and file names
; under the configuration directory and e-mail addresses. The
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
; 5. Folder and file names chosen by the user are masked whole, spaces and
;    non-ASCII letters included; under the configuration directory only the
;    names the product ships stay.
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
;   "space", "quote", "separator", "value_stop", "email_local", "email_domain",
;   "url_userinfo", "at", "letter", "name" (a character of a folder or file
;   name chosen by a person: the path characters plus every non-ASCII one, the
;   ellipsis a log appends to a shortened path excepted), "name_end" (what can
;   follow a complete name: a path separator, a quote, a line break),
;   "name_end_line" (a separator or a line break) or "path_separator".
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
		case "email_local":
			return IsAlnum || InStr("._%+-", Chr(Code), true) > 0
		case "email_domain":
			return IsAlnum || Code = 0x2E || Code = 0x2D
		case "url_userinfo":
			return IsAlnum || InStr("._~%+:=!*-", Chr(Code), true) > 0
		case "name":
			return IsAlnum || Code = 0x5F || Code = 0x2E || Code = 0x2D || (Code >= 0x80 && Code != 0x2026)
		case "name_end":
			return Code = 0x5C || Code = 0x2F || Code = 0x22 || Code = 0x27 || Code = 0x0D || Code = 0x0A
		case "name_end_line":
			return Code = 0x5C || Code = 0x2F || Code = 0x0D || Code = 0x0A
		case "path_separator":
			return Code = 0x5C || Code = 0x2F
		case "at":
			return Code = 0x40
		case "letter":
			return (Code >= 0x41 && Code <= 0x5A) || (Code >= 0x61 && Code <= 0x7A)
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

; Returns the index of the first character of the run of Class that ends at From.
; @param Text {String}
; @param From {Integer} The run's last index.
; @param Class {String}
; @returns {Integer} The run's first index, From + 1 when the run is empty.
_Redact_RunStart(Text, From, Class) {
	Index := From
	while _Redact_CharIs(Text, Index, Class)
		Index -= 1
	return Index + 1
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

; Lower-cases A-Z only, keeping every other character, as the other ports do.
; @param Text {String}
; @returns {String}
_Redact_AsciiLower(Text) {
	Out := ""
	Loop Parse Text {
		Code := Ord(A_LoopField)
		Out .= (Code >= 0x41 && Code <= 0x5A) ? Chr(Code + 32) : A_LoopField
	}
	return Out
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
; @param Accept {Func} (Text, First, Last) → Map { text, last, first? } or 0 to
;   skip. The optional first is an earlier index the replacement starts at
;   (never before the end of the previous replacement).
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
			From := Result.Has("first") ? Max(Pos, Result["first"]) : First
			Out .= SubStr(Text, Pos, From - Pos) . Result["text"]
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

; Accepts the credential in front of the @ of a URL and keeps the scheme.
_Redact_AcceptUrlCredential(Rules, Text, First, Last) {
	Stop := _Redact_RunEnd(Text, Last + 1, "url_userinfo")
	if (Stop <= Last || !_Redact_CharIs(Text, Stop + 1, "at"))
		return 0
	return Map("text", "://" . Rules["secret_placeholder"], "last", Stop)
}

; Accepts an e-mail address: a local part, an @, and a dotted domain ending in
; a top-level label of at least two letters.
_Redact_AcceptEmail(Rules, Text, First, Last) {
	Start := _Redact_RunStart(Text, First - 1, "email_local")
	if (Start == First)
		return 0
	Stop := _Redact_RunEnd(Text, Last + 1, "email_domain")
	; A trailing dot or dash is the sentence's, not the domain's
	while (Stop > Last && (SubStr(Text, Stop, 1) == "." || SubStr(Text, Stop, 1) == "-"))
		Stop -= 1
	Domain := SubStr(Text, Last + 1, Stop - Last)
	Dot := 0
	Loop Parse Domain {
		if (A_LoopField == ".")
			Dot := A_Index
	}
	if (Dot < 2)
		return 0
	Tld := SubStr(Domain, Dot + 1)
	if (StrLen(Tld) < 2)
		return 0
	Loop Parse Tld {
		if !_Redact_CharIs(A_LoopField, 1, "letter")
			return 0
	}
	return Map("text", Rules["email_placeholder"], "last", Stop, "first", Start)
}

; Returns the index of the last character of the name that starts at From: a
; run of name characters, extended over single spaces (at most MaxWords words)
; when that makes the name end at a separator, a quote or the end of the line,
; so "John Smith" is one folder but "jdoe and more" is the folder "jdoe".
; @param Text {String}
; @param From {Integer}
; @param MaxWords {Integer} The most words one name may hold.
; @returns {Integer} The name's last index, From - 1 when there is none.
_Redact_NameEnd(Text, From, MaxWords) {
	FirstEnd := _Redact_RunEnd(Text, From, "name")
	if (FirstEnd < From)
		return FirstEnd
	Stop := FirstEnd
	Loop MaxWords - 1 {
		if (Stop + 1 > StrLen(Text) || _Redact_CharIs(Text, Stop + 1, "name_end"))
			return Stop
		if (SubStr(Text, Stop + 1, 1) !== " ")
			break
		NextEnd := _Redact_RunEnd(Text, Stop + 2, "name")
		if (NextEnd < Stop + 2)
			break
		Stop := NextEnd
	}
	if (Stop + 1 > StrLen(Text) || _Redact_CharIs(Text, Stop + 1, "name_end"))
		return Stop
	return FirstEnd
}

; Accepts the profile folder of another account unless it is a shared profile.
_Redact_AcceptForeignHome(Rules, Text, First, Last) {
	Stop := _Redact_NameEnd(Text, Last + 1, Rules["path_name_max_words"])
	if (Stop <= Last)
		return 0
	Name := _Redact_AsciiLower(SubStr(Text, Last + 1, Stop - Last))
	for Shared in Rules["shared_profile_names"] {
		if (Shared == Name)
			return 0
	}
	return Map("text", SubStr(Text, First, Last - First + 1) . Rules["account_placeholder"], "last", Stop)
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

; Accepts the configuration directory and masks every name below it: a name the
; product ships stays, any other becomes the name placeholder.
_Redact_AcceptConfigDir(Rules, Known, Text, First, Last) {
	if _Redact_CharIs(Text, Last + 1, "name")
		return 0
	; A path right after a quote ends at the closing quote, spaces included
	Quote := (First > 1) ? SubStr(Text, First - 1, 1) : ""
	if !(Quote == "'" || Quote == Chr(34))
		Quote := ""
	Out := Rules["config_placeholder"]
	Index := Last + 1
	while _Redact_CharIs(Text, Index, "path_separator") {
		Start := Index + 1
		if (Quote != "") {
			Stop := Start - 1
			while (Stop + 1 <= StrLen(Text) && !_Redact_CharIs(Text, Stop + 1, "name_end_line")
				&& SubStr(Text, Stop + 1, 1) !== Quote)
				Stop += 1
		} else {
			Stop := _Redact_NameEnd(Text, Start, Rules["path_name_max_words"])
		}
		Name := SubStr(Text, Start, Stop - Start + 1)
		if (Name == "") {
			Out .= SubStr(Text, Index, 1)
			Index := Start
		} else {
			Out .= SubStr(Text, Index, 1) . (Known.Has(_Redact_AsciiLower(Name)) ? Name : Rules["config_name_placeholder"])
			Index := Stop + 1
		}
	}
	return Map("text", Out, "last", Index - 1)
}

; Masks the folder and file names under the configuration directory, in every
; spelling of the directory.
; @param Text {String}
; @param Rules {Map}
; @param Dir {String} The directory as the text spells it.
; @param Folded {Boolean}
; @returns {String}
_Redact_MaskConfigDir(Text, Rules, Dir, Folded) {
	Dir := RegExReplace(Dir, "[/\\]+$")
	if (Dir == "")
		return Text
	Known := Map()
	for Name in Rules["config_known_names"]
		Known[_Redact_AsciiLower(Name)] := true
	Seen := Map()
	for Spelling in [Dir, StrReplace(Dir, "\", "/"), StrReplace(Dir, "/", "\")] {
		if Seen.Has(Spelling)
			continue
		Seen[Spelling] := true
		Text := _Redact_Replace(Text, Spelling, Folded, _Redact_AcceptConfigDir.Bind(Rules, Known))
	}
	return Text
}

; Replaces the home folder, in both slash styles, by its placeholder.
; @param Text {String}
; @param Rules {Map}
; @param Home {String}
; @param Folded {Boolean}
; @returns {String}
_Redact_Home(Text, Rules, Home, Folded) {
	Home := RegExReplace(Home, "[/\\]+$")
	if (Home == "")
		return Text
	Seen := Map()
	for Spelling in [Home, StrReplace(Home, "\", "/"), StrReplace(Home, "/", "\")] {
		if Seen.Has(Spelling)
			continue
		Seen[Spelling] := true
		Text := _Redact_Replace(Text, Spelling, Folded, _Redact_AcceptHome.Bind(Rules))
	}
	return Text
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
; @param Context {Map} { home, user, config_dir, case_insensitive } — the
;   platform's home folder, account name, configuration directory, and whether
;   its paths compare case-insensitively.
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
	Text := _Redact_Replace(Text, "://", false, _Redact_AcceptUrlCredential.Bind(Rules))
	Text := _Redact_Replace(Text, "bearer", true, _Redact_AcceptBearer.Bind(Rules))
	for Key in Rules["secret_keys"]
		Text := _Redact_Replace(Text, Key, true, _Redact_AcceptKeyValue.Bind(Rules))

	for Setting in ["path_name_max_words", "config_placeholder", "config_name_placeholder", "config_known_names"] {
		if !Rules.Has(Setting)
			throw ValueError("redact: the rules lack the path name and configuration directory settings.")
	}
	; The directory is searched as it is spelled, then as the home pass leaves it
	; (a log written earlier already holds "~" for the home folder)
	ConfigDir := Context.Get("config_dir", "")
	Home := Context.Get("home", "")
	if (ConfigDir != "")
		Text := _Redact_MaskConfigDir(Text, Rules, ConfigDir, Folded)
	Text := _Redact_Home(Text, Rules, Home, Folded)
	if (ConfigDir != "")
		Text := _Redact_MaskConfigDir(Text, Rules, _Redact_Home(ConfigDir, Rules, Home, Folded), Folded)

	for Marker in Rules["foreign_home_markers"]
		Text := _Redact_Replace(Text, Marker, true, _Redact_AcceptForeignHome.Bind(Rules))
	Text := _Redact_Replace(Text, "@", false, _Redact_AcceptEmail.Bind(Rules))

	User := Context.Get("user", "")
	if (User != "" && _Redact_CodePointCount(User) >= Rules["min_account_name_length"])
		Text := _Redact_Replace(Text, User, Folded, _Redact_AcceptAccount.Bind(Rules))
	return Text
}
