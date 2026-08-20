; infra/personal_info_mask.ahk

; ==============================================================================
; MODULE: Personal-Info Masking
; DESCRIPTION:
; Turns a personal_info value into what a NON-TYPING sink may carry — the
; preview bubble on screen (Section 3) and a persisted metrics record
; (Section 4). The AHK port of _shared/lua/personal_info/mask.lua — AutoHotkey
; cannot require the shared Lua, so the ALGORITHM is re-implemented here while
; the POLICY (which fields are secrets, how much of one stays visible) is read
; at runtime from _shared/modules/personal_info/fields.toml. The two halves are
; pinned together by _shared/modules/personal_info/preview_vectors.toml, which
; every driver's suite replays byte for byte;
; tests/unit/test_personal_info_mask_vectors.ahk is this driver's consumer of
; that corpus.
;
; The two sinks get DIFFERENT answers on purpose: a bubble is read by the person
; the value belongs to, so it may reveal a head and a tail; a log is ingested,
; replicated to every other device and kept for fourteen days, so it may reveal
; nothing at all.
;
; FEATURES & RATIONALE:
; 1. No private list of secret fields. A driver that keeps its own copy and a
;    driver that misspells a field name look identical from the outside, and the
;    second silently reveals the value — which is why the shared declaration
;    writes `masked` out both ways, and why nothing here hardcodes which field
;    is which.
; 2. Never on the typing path. Nothing in this file touches what gets TYPED: the
;    expansion is always the complete value, and a preview row (or a log field)
;    is a separate string built for that sink. If this module is ever reached
;    from an injection path the bug is the call site, not the mask.
; 3. Fail CLOSED. An unreadable declaration, a malformed policy, an unknown
;    field and a lost field name all mask instead of revealing. Absence is never
;    permission — the opposite default reveals whatever a future edit forgets to
;    declare.
; 4. Character-aware, not code-unit-aware. AHK strings are UTF-16, so an astral
;    character is two code units; revealing "the last four code units" of such a
;    value can cut a character in half and produce something both wrong and
;    unreadable. Positions are counted in characters.
; ==============================================================================





; ========================================
; ========================================
; ======= 1/ Declaration constants =======
; ========================================
; ========================================

; Where the shared declaration lives, relative to _SharedDir.
global PI_MASK_DECLARATION_REL := "\modules\personal_info\fields.toml"

; U+2022 BULLET — what a hidden position is drawn as when the declaration itself
; could not be read, so the fail-closed path owes nothing to the file it failed
; to load. Written as a codepoint because this is the one path that has to
; survive a file-encoding accident.
global PI_MASK_FALLBACK_CHAR := Chr(0x2022)

; The content length the fail-closed policy would start revealing above. No real
; value comes near it, which is the point: the degraded policy reveals nothing.
global PI_MASK_NEVER_REVEAL := 0x7FFFFFFF

; U+00A0 NO-BREAK SPACE — a separator like the ASCII space and hyphen.
global PI_MASK_NBSP := Chr(0xA0)

; The keys the shared [policy] block must carry. Named so a half-written
; declaration is reported by the key it is missing, instead of masking with an
; empty arithmetic operand and looking like a policy decision.
global PI_MASK_REQUIRED_POLICY := ["mask_char", "reveal_head", "reveal_tail", "min_length_to_reveal"]

; The parsed declaration, read once. The file ships with the driver and is not
; user-editable, so re-reading it per keystroke would be a file open on the
; preview path for a value that cannot change. "" until the first read.
global _PIMaskDeclaration := ""





; ====================================
; ====================================
; ======= 2/ Character helpers =======
; ====================================
; ====================================

; Split a string into an array of single CHARACTERS.
;
; ``Loop Parse`` and ``SubStr`` walk UTF-16 code units, so an astral character
; arrives as two halves. Recombining the surrogate pair here is what makes
; "reveal the last four" mean four characters rather than four code units,
; mirroring the shared implementation's codepoint iterator.
; @param Text The value to split.
; @return Array of one-character strings.
_PIMaskCharacters(Text) {
	Out := []
	Len := StrLen(Text)
	I := 1
	while (I <= Len) {
		Ch := SubStr(Text, I, 1)
		Code := Ord(Ch)
		; A high surrogate is only half a character; the low half follows it.
		if (Code >= 0xD800 and Code <= 0xDBFF and I < Len) {
			Out.Push(SubStr(Text, I, 2))
			I += 2
			continue
		}
		Out.Push(Ch)
		I += 1
	}
	return Out
}

; Whether a character is decoration rather than content.
;
; Spaces and hyphens group an IBAN, a card number and a French SSN: they carry
; nothing, and masking them turns a recognisable grouping into an unreadable run
; of dots. They also do not count toward the revealed head and tail, so
; "FR76 3000 …" reveals two LETTERS rather than "FR" and then a space.
; @param Ch One character.
; @return true when the character is a separator.
_PIMaskIsSeparator(Ch) {
	global PI_MASK_NBSP
	return (Ch == " " or Ch == "-" or Ch == PI_MASK_NBSP)
}





; ==========================
; ==========================
; ======= 3/ Masking =======
; ==========================
; ==========================

; Whether a policy Map carries every key the mask needs.
; @param Policy The [policy] block, as parsed.
; @return "" when the policy is usable, otherwise the name of the missing key.
PersonalInfoMaskPolicyMissingKey(Policy) {
	global PI_MASK_REQUIRED_POLICY
	if !(Policy is Map) {
		return "policy"
	}
	for _, Key in PI_MASK_REQUIRED_POLICY {
		if !Policy.Has(Key) {
			return Key
		}
	}
	return ""
}

; Mask a value for display.
; @param Value The complete value, as it would be typed.
; @param Policy From fields.toml [policy]: mask_char, reveal_head, reveal_tail,
;   min_length_to_reveal, preserve_separators.
; @return What the preview may show. The input unchanged when it is not a
;   string; an all-masked string when the value is too short to reveal.
PersonalInfoMaskValue(Value, Policy) {
	global PI_MASK_FALLBACK_CHAR
	if (Type(Value) != "String" or Value == "") {
		return Value
	}
	Chars := _PIMaskCharacters(Value)

	; Fail CLOSED. A caller with a broken policy gets everything hidden rather
	; than everything shown: the whole point of this module is that a mistake
	; must not end in a secret on screen.
	if (PersonalInfoMaskPolicyMissingKey(Policy) != "") {
		Hidden := ""
		Loop Chars.Length {
			Hidden .= PI_MASK_FALLBACK_CHAR
		}
		return Hidden
	}

	; ``!`` rather than a comparison against false: AHK v2 has no distinct
	; boolean, so "0" would compare equal to false and a hand-edited policy could
	; flip this rule by accident.
	Preserve := true
	if (Policy.Has("preserve_separators") and !Policy["preserve_separators"]) {
		Preserve := false
	}

	; Content length, not string length: the thresholds are about how much of the
	; SECRET is revealed, and the spaces in "FR76 3000 4000" are not secret.
	Content := 0
	for _, Ch in Chars {
		if !(Preserve and _PIMaskIsSeparator(Ch)) {
			Content += 1
		}
	}

	Head := Policy["reveal_head"]
	Tail := Policy["reveal_tail"]
	if (Content < Policy["min_length_to_reveal"]) {
		Head := 0
		Tail := 0
	}
	MaskChar := Policy["mask_char"]

	Out := ""
	Seen := 0
	for _, Ch in Chars {
		if (Preserve and _PIMaskIsSeparator(Ch)) {
			Out .= Ch
			continue
		}
		Seen += 1
		if (Seen <= Head or Seen > Content - Tail) {
			Out .= Ch
		} else {
			Out .= MaskChar
		}
	}
	return Out
}

; Mask a value only when its field is declared masked, against an explicit
; declaration.
;
; Takes the field NAME so the decision and the masking cannot drift apart in a
; caller that remembers one and forgets the other. An unknown field is masked: a
; field that is not in fields.toml is a field nobody classified, and the safe
; answer for something nobody classified is to hide it.
; @param Value The complete value.
; @param Field The personal_info.toml field the value came from, "" when the
;   provenance was lost on the way here.
; @param Declaration { Policy: Map, Fields: Map } as this module builds it.
; @return What the preview may show.
PersonalInfoMaskFieldWith(Value, Field, Declaration) {
	if (Type(Value) != "String" or Value == "") {
		return Value
	}
	; A declaration that is not an object cannot say anything about this field,
	; and "cannot say" is not "not a secret".
	if !IsObject(Declaration) {
		return PersonalInfoMaskValue(Value, "")
	}
	Fields := Declaration.Fields
	if (Type(Field) == "String" and Field != "" and Fields.Has(Field) and !Fields[Field]) {
		return Value
	}
	return PersonalInfoMaskValue(Value, Declaration.Policy)
}

; What the preview bubble may show for a value.
;
; The ONLY entry point a display path should call: it resolves the shared
; declaration itself, so a caller cannot mask against a policy of its own.
; @param Value The complete value, as it would be typed.
; @param Field The personal_info.toml field it came from.
; @return What the preview may show.
PersonalInfoMaskForPreview(Value, Field := "") {
	return PersonalInfoMaskFieldWith(Value, Field, PersonalInfoMaskDeclaration())
}

; Whether a field is declared a secret.
; @param Field The personal_info.toml field name.
; @return true when the field is masked, including when it is unknown.
PersonalInfoMaskIsMasked(Field) {
	Decl := PersonalInfoMaskDeclaration()
	if (Type(Field) != "String" or Field == "" or !Decl.Fields.Has(Field)) {
		return true
	}
	return Decl.Fields[Field] ? true : false
}





; ========================================
; ========================================
; ======= 4/ Redaction for the log =======
; ========================================
; ========================================

; What a PERSISTED record may keep of a private value.
;
; The preview mask above reveals a head and a tail so the user can recognise
; their own value on their own screen. A log has no such reader: today.log is
; ingested into the metrics store, replicated to every other device and kept for
; fourteen days, so the only safe answer there is that none of the content
; survives.
;
; The LENGTH does survive — one placeholder per position — because the metrics
; arithmetic downstream is computed from it (net_saved_chars, one WPM push per
; character) and dropping it would trade a privacy bug for a metrics bug. The
; Linux driver's recorded_char() makes exactly this trade, one placeholder per
; character, and says so at length; this is the same contract on the same data.
;
; Counted in UTF-16 code units (StrLen), NOT in characters: the record's own
; arithmetic is StrLen-based, so a redaction that shortened an astral pair to a
; single placeholder would leave the row internally inconsistent.
; @param Value The complete value, as it would be typed.
; @return A run of PI_MASK_FALLBACK_CHAR of identical StrLen; the input
;   unchanged when it is not a non-empty string.
PersonalInfoRedactForLog(Value) {
	global PI_MASK_FALLBACK_CHAR
	if (Type(Value) != "String" or Value == "") {
		return Value
	}
	Out := ""
	Loop StrLen(Value) {
		Out .= PI_MASK_FALLBACK_CHAR
	}
	return Out
}





; =========================================
; =========================================
; ======= 5/ The shared declaration =======
; =========================================
; =========================================

; The classification as it degrades when the shared file cannot be read or
; understood: everything masked, nothing revealed. A driver that lost its
; declaration must not conclude that nothing is secret, and raising here would
; take the preview bubble down rather than degrade it.
_PIMaskFailClosedDeclaration() {
	global PI_MASK_FALLBACK_CHAR, PI_MASK_NEVER_REVEAL
	return { Policy: Map("mask_char", PI_MASK_FALLBACK_CHAR,
	                     "reveal_head", 0,
	                     "reveal_tail", 0,
	                     "min_length_to_reveal", PI_MASK_NEVER_REVEAL,
	                     "preserve_separators", true),
	         Fields: Map() }
}

; Read and cache the shared declaration.
; @return { Policy: Map, Fields: Map } — never "" and never an error.
PersonalInfoMaskDeclaration() {
	global _PIMaskDeclaration
	; The lazy-cache guard: "" until the first read, an object thereafter, and an
	; object is truthy — so this is also the init check every public function of
	; this module depends on. _PIMaskLoadDeclaration never returns "", so a failed
	; read is cached as the fail-closed policy rather than retried per keystroke.
	if !_PIMaskDeclaration {
		_PIMaskDeclaration := _PIMaskLoadDeclaration()
	}
	return _PIMaskDeclaration
}

; Parse _shared/modules/personal_info/fields.toml into the shape above.
;
; ParseTomlFile flattens `[fields.iban]` to the section name "fields.iban", so
; the field name is the part after the prefix. A field entry with no `masked`
; key is treated as masked for the same reason an absent field is: the file
; states the decision, and anything that does not state it has not been made.
_PIMaskLoadDeclaration() {
	global _SharedDir, PI_MASK_DECLARATION_REL
	if (!IsSet(_SharedDir) or _SharedDir == "") {
		try LoggerError("PersonalInfoMask", "The shared directory is unknown — masking every personal-info preview.")
		return _PIMaskFailClosedDeclaration()
	}
	Path := _SharedDir . PI_MASK_DECLARATION_REL
	if !FileExist(Path) {
		try LoggerError("PersonalInfoMask", "'{1}' is missing — masking every personal-info preview.", Path)
		return _PIMaskFailClosedDeclaration()
	}
	Parsed := ParseTomlFile(Path)
	; TOML_ReadFailed distinguishes "could not read it" from "it said nothing",
	; and only the first deserves its own line in the log — both fail closed.
	if TOML_ReadFailed(Path) {
		try LoggerError("PersonalInfoMask", "'{1}' could not be read — masking every personal-info preview.", Path)
		return _PIMaskFailClosedDeclaration()
	}
	if (!(Parsed is Map) or !Parsed.Has("policy")) {
		try LoggerError("PersonalInfoMask", "'{1}' declares no [policy] block — masking every personal-info preview.", Path)
		return _PIMaskFailClosedDeclaration()
	}
	Policy := Parsed["policy"]
	Missing := PersonalInfoMaskPolicyMissingKey(Policy)
	if (Missing != "") {
		try LoggerError("PersonalInfoMask", "The shared policy is missing '{1}' — masking every personal-info preview.", Missing)
		return _PIMaskFailClosedDeclaration()
	}

	Fields := Map()
	for Section, Keys in Parsed {
		if (SubStr(Section, 1, 7) != "fields.") {
			continue
		}
		Name := SubStr(Section, 8)
		if (Name == "") {
			continue
		}
		Fields[Name] := (Keys is Map and Keys.Has("masked") and !Keys["masked"]) ? false : true
	}
	if (Fields.Count == 0) {
		try LoggerWarn("PersonalInfoMask", "'{1}' declares no field at all — every value stays masked.", Path)
	}
	try LoggerDebug("PersonalInfoMask", "Field classification loaded ({1} field(s) declared).", Fields.Count)
	return { Policy: Policy, Fields: Fields }
}

; Drop the cached declaration. Tests only — the file cannot change at runtime.
PersonalInfoMaskReset() {
	global _PIMaskDeclaration
	_PIMaskDeclaration := ""
}
