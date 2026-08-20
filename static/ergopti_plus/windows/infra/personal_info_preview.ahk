; infra/personal_info_preview.ahk

; ==============================================================================
; MODULE: Personal-Info Resolution And Preview Projection
; DESCRIPTION:
; The shared catalogue and field resolver for every trigger that starts with
; "@", plus the masking projection used after the engine has selected and frozen
; an exact fire decision. Candidate discovery is deliberately absent here:
; HSE_PreviewNextDecision is the single owner of the answer shown by the tooltip.
;
; FEATURES & RATIONALE:
; 1. The ENGINE decides what exists — and it answers in two ways. A
;    registered Spec still wins where there is one. Where there is not, the
;    engine resolves @<letters><magic key> at fire time
;    (HSE_TryPersonalInfoCombo), so a tag whose letters all alias a filled-in
;    field WILL expand and must be previewed. This module used to require a Spec
;    and return nothing otherwise, which was correct while the multi-letter
;    combos came from a hand-written list of thirty-one registrations; once every
;    combination fires, that same check became the bubble refusing to preview
;    expansions that work.
; 2. Masked for display, complete when typed. The engine freezes the complete
;    field/value snapshot on its decision; this module masks that same snapshot
;    for display, and the expansion path never reads the masked text.
; ==============================================================================




; =========================================
; =========================================
; ======= 1/ The @-tag catalogue ==========
; =========================================
; =========================================

; The @-tags that expand to ONE personal_info field, and the field each names.
; Read by the registration (modules/hotstrings/hotstrings_text_expansion.ahk
; turns every entry into a CreateHotstring call) and by the engine resolver, so
; the set of tags and the field a tag resolves to cannot drift between what the
; driver types and what the bubble promises.
global PERSONAL_INFO_TAGS := Map(
	"bic",  "bic",
	"cb",   "credit_card",
	"cc",   "credit_card",
	"iban", "iban",
	"rib",  "iban",
	"ss",   "social_security_number",
	"tel",  "phone_number",
	"tél",  "phone_number"
)

; The order those tags are REGISTERED in. AHK v2 enumerates a Map in an order of
; its own, not in insertion order, and registration order is the engine's last
; collision tie-break (Spec.Seq) — so it has to be stated rather than inherited
; from the literal above.
global PERSONAL_INFO_TAG_ORDER := ["bic", "cb", "cc", "iban", "rib", "ss", "tel", "tél"]

; The longest @-tag the engine resolver looks back for. Bounds the scan on a buffer
; that holds a long word, and no registered tag comes close: the hand-listed
; combos top out at six letters and the literal tags at four.
global PI_PREVIEW_MAX_TAG_LEN := 12

; U+21E5 RIGHTWARDS ARROW TO BAR, between two fields of a multi-field row. The
; expansion types a real Tab there (the values land in consecutive form fields);
; a literal tab is invisible in a tooltip, so the bubble shows the glyph for it —
; the same separator macOS uses for the same rows.
global PI_PREVIEW_FIELD_SEPARATOR := " " . Chr(0x21E5) . " "

; The category a personal-information row resolves its colour, delay and
; "show the bubble" toggle through. These rows carry the user's own data, so
; they wear the personal colour on all three drivers. It has to be named here:
; CreateHotstring registers every @ trigger with an EMPTY category, and resolving
; that would paint them the generic global default instead.
global PI_PREVIEW_CATEGORY := "personal"

; =====================================
; =====================================
; ======= 2/ Resolving a tag ==========
; =====================================
; =====================================

; Whether a character may appear inside an @-tag.
;
; A cased letter, tested by asking whether the character has a distinct upper
; and lower form. A character class would have to enumerate the accented letters
; — "@tél" is one of the shipped tags — and would then miss whichever one a user
; puts in their [letters] aliases next.
; @param Ch One character.
; @return true when the character is a letter.
_PIPreviewIsTagChar(Ch) {
	if (Ch == "") {
		return false
	}
	return (StrLower(Ch) !== StrUpper(Ch))
}

; The @-tag the buffer ends with, or "" when it does not end with one.
;
; Walks back from the end rather than matching a regex: PCRE's letter classes
; are ASCII unless the pattern opts into Unicode, and the accented "@tél" is a
; shipped tag rather than a corner case.
; @param Buffer The engine's buffer.
; @return The tag WITHOUT its leading "@", or "".
_PIPreviewTrailingTag(Buffer) {
	global PI_PREVIEW_MAX_TAG_LEN
	Len := StrLen(Buffer)
	I := Len
	Steps := 0
	while (I >= 1 and Steps <= PI_PREVIEW_MAX_TAG_LEN) {
		Ch := SubStr(Buffer, I, 1)
		if (Ch == "@") {
			; "@" with nothing after it is not a tag yet.
			return (I == Len) ? "" : SubStr(Buffer, I + 1)
		}
		if !_PIPreviewIsTagChar(Ch) {
			return ""
		}
		I -= 1
		Steps += 1
	}
	return ""
}

; The personal_info fields an @-tag expands to, in the order they are typed.
;
; Lower-cased first, because the engine registers the @ triggers
; case-INSENSITIVELY: typing "@NP" fires the same expansion as "@np" and must
; preview the same row.
; @param Tag The tag without its "@".
; @return Array of personal_info field names — empty when the tag names none.
_PIPreviewFieldsForTag(Tag) {
	global PERSONAL_INFO_TAGS, PersonalInformationLetters
	Fields := []
	if (Tag == "") {
		return Fields
	}
	Key := StrLower(Tag)
	if (IsSet(PERSONAL_INFO_TAGS) and PERSONAL_INFO_TAGS.Has(Key)) {
		Fields.Push(PERSONAL_INFO_TAGS[Key])
		return Fields
	}
	if !IsSet(PersonalInformationLetters) {
		return Fields
	}
	Loop Parse, Key {
		; One unknown letter means the tag is not a combo at all. Returning the
		; letters that DID resolve would preview a partial expansion the engine
		; never registered.
		if !PersonalInformationLetters.Has(A_LoopField) {
			return []
		}
		Fields.Push(PersonalInformationLetters[A_LoopField])
	}
	return Fields
}

; The masked, display-ready text for a list of personal_info fields.
;
; Each value is masked against the shared declaration BY FIELD NAME, so a field
; that becomes a secret is covered by editing one shared TOML rather than every
; producer. What is TYPED is untouched: the engine holds its own replacement
; string and never reads this one.
; @param Fields Array of personal_info field names.
; @return The row text, or "" when a field has no value.
_PIPreviewMaskedText(Fields, Values := unset) {
	global PersonalInformation, PI_PREVIEW_FIELD_SEPARATOR
	if (!(Fields is Array) or Fields.Length == 0) {
		return ""
	}
	UseSnapshot := IsSet(Values)
	if (UseSnapshot and (!(Values is Array) or Values.Length != Fields.Length))
		return ""
	if (!UseSnapshot and !IsSet(PersonalInformation))
		return ""
	Text := ""
	for Index, Field in Fields {
		if (!UseSnapshot and !PersonalInformation.Has(Field)) {
			try LoggerWarn("PersonalInfoPreview", "No value for personal-info field '{1}' — the row is dropped.", Field)
			return ""
		}
		Value := UseSnapshot ? Values[Index] : PersonalInformation[Field]
		if !(Value is String) or Value == ""
			return ""
		if (Index > 1) {
			Text .= PI_PREVIEW_FIELD_SEPARATOR
		}
		Text .= PersonalInfoMaskForPreview(Value, Field)
	}
	return Text
}
