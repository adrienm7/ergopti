; infra/personal_info_preview.ahk

; ==============================================================================
; MODULE: Personal-Info Preview Provider
; DESCRIPTION:
; The preview candidate source for every trigger that starts with "@": the
; personal-information tags (@iban, @tel, …), the letter combos (@n, @np,
; @nptm, …) and the three dates (@dt, @date, @td).
;
; WHY A PROVIDER AND NOT AN INDEX ENTRY:
; _PrefixIndex is built exclusively from files — the bundled category TOMLs,
; their in-memory cache and the extension packs. Every @ trigger is created
; imperatively at boot by CreateHotstring, which feeds the ENGINE registry and
; nothing else, so no key beginning with "@" has ever existed in that index:
; _PrefixCollectCandidates returned an empty array for any @ buffer and the
; bubble was silent for the whole family while the expansions fired normally.
; Inserting them into the index at registration time would work until the next
; HotstringPrefixWatcherRebuildIndex — a live section toggle, a personal save,
; the boot-tail warm-up — which builds a fresh Map and swaps it in, so the bug
; would come back intermittently and look like a race.
;
; FEATURES & RATIONALE:
; 1. The ENGINE decides what exists. A tag is previewed only when the engine
;    actually holds a Spec for "@<tag><magic key>", so the bubble can never
;    promise a combo that is not registered — @npx resolves letter by letter but
;    only @n and @np are registered, and a tooltip offering an expansion that
;    will not fire is worse than no tooltip.
; 2. The ENGINE decides what it is. The rendering branch is chosen from the
;    Spec's replacement, not from the tag: "@dt" spells two valid letter aliases
;    AND is the short-date trigger, and only the Spec knows which one the engine
;    will fire.
; 3. Masked for display, complete when typed. A row's text goes through the
;    shared masking policy; the expansion path never reads it.
; ==============================================================================




; =========================================
; =========================================
; ======= 1/ The @-tag catalogue ==========
; =========================================
; =========================================

; The @-tags that expand to ONE personal_info field, and the field each names.
; Read by the registration (modules/hotstrings/hotstrings_text_expansion.ahk
; turns every entry into a CreateHotstring call) and by the provider below, so
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

; The longest @-tag the provider looks back for. Bounds the scan on a buffer
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

; The category a date row resolves through — the same key the dates already use
; for their activation delay (_DynamicHotstringDelay), so the tray menu's
; existing "dynamic hotstrings" entry governs both.
global PI_PREVIEW_DYNAMIC_CATEGORY := "dynamichotstrings"




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
_PIPreviewMaskedText(Fields) {
	global PersonalInformation, PI_PREVIEW_FIELD_SEPARATOR
	if (!IsSet(PersonalInformation) or Fields.Length == 0) {
		return ""
	}
	Text := ""
	for Index, Field in Fields {
		if !PersonalInformation.Has(Field) {
			try LoggerWarn("PersonalInfoPreview", "No value for personal-info field '{1}' — the row is dropped.", Field)
			return ""
		}
		if (Index > 1) {
			Text .= PI_PREVIEW_FIELD_SEPARATOR
		}
		Text .= PersonalInfoMaskForPreview(PersonalInformation[Field], Field)
	}
	return Text
}





; ===============================
; ===============================
; ======= 3/ The provider =======
; ===============================
; ===============================

; Offer the preview a row for the @-trigger the buffer ends with.
;
; Returns an Array so the contract is the same for the no-match case and the
; match case, and so a future provider can offer several rows without changing
; the collector.
; @param Buffer The engine's buffer, exactly what the suffix probe reads.
; @return Array of preview rows — empty when nothing is offered.
PersonalInfoPreviewProvider(Buffer) {
	global ScriptInformation, PI_PREVIEW_CATEGORY, PI_PREVIEW_DYNAMIC_CATEGORY
	Rows := []
	if (Type(Buffer) != "String" or Buffer == "") {
		return Rows
	}
	if (!IsSet(ScriptInformation) or !ScriptInformation.Has("MagicKey")) {
		return Rows
	}
	Tag := _PIPreviewTrailingTag(Buffer)
	if (Tag == "") {
		return Rows
	}

	; The engine's own answer to "does this exist", through the same by-trigger
	; indexes the matcher probes. No Spec means no promise: the letters of a tag
	; can resolve when the combo was never registered.
	Spec := _PreviewSpecForTrigger("@" . Tag . ScriptInformation["MagicKey"])
	if !IsObject(Spec) {
		return Rows
	}

	Replacement := Spec.HasOwnProp("Replacement") ? Spec.Replacement : ""
	if HasMethod(Replacement) {
		; A callable replacement is a value the engine computes at fire time —
		; the three dates. Resolve it the same way, so the bubble shows what the
		; magic key will actually type rather than a stale registration.
		Text := ""
		try {
			Text := Replacement.Call()
		} catch as Err {
			try LoggerError("PersonalInfoPreview", "Resolving the dynamic value for '{1}' failed: {2}. The row is dropped.", Spec.Trigger, Err.Message)
			return Rows
		}
		if (Type(Text) != "String" or Text == "") {
			return Rows
		}
		Category := PI_PREVIEW_DYNAMIC_CATEGORY
	} else {
		Fields := _PIPreviewFieldsForTag(Tag)
		if (Fields.Length == 0) {
			return Rows
		}
		Text := _PIPreviewMaskedText(Fields)
		if (Text == "") {
			return Rows
		}
		Category := PI_PREVIEW_CATEGORY
	}

	; Length, Priority, GroupOrder and Seq are the ENGINE's, so _HSE_Beats ranks
	; this row against the index rows by exactly the rule that will decide the
	; fire. Delay is the engine's activation window for this trigger, so the
	; bubble lives exactly as long as the expansion stays armed.
	Rows.Push({ Trigger:    Spec.Trigger,
	            Output:     Text,
	            Category:   Category,
	            Section:    "",
	            Length:     Spec.HasOwnProp("Length") ? Spec.Length : StrLen(Spec.Trigger),
	            Priority:   Spec.HasOwnProp("Priority") ? Spec.Priority : "",
	            GroupOrder: Spec.HasOwnProp("GroupOrder") ? Spec.GroupOrder : 0,
	            Seq:        Spec.HasOwnProp("Seq") ? Spec.Seq : 0,
	            Delay:      Spec.HasOwnProp("TimeActivationSeconds") ? Spec.TimeActivationSeconds : 0 })
	return Rows
}





; ===============================
; ===============================
; ======= 4/ Registration =======
; ===============================
; ===============================

; Registered at load rather than from HotstringPrefixWatcherInit: this provider
; is a static capability of the driver, not a lifecycle-dependent one, and
; registering it here means the collector is complete from the first keystroke
; regardless of boot ordering. The provider itself asks the engine what exists,
; so it offers nothing at all until the @ triggers are registered — a disabled
; feature needs no gate here.
HotstringPrefixWatcherRegisterPreviewProvider(PersonalInfoPreviewProvider)
