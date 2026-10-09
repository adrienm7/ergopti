; _shared/modules/hotstrings/terminator_scope.ahk

; ==============================================================================
; MODULE: Shared Hotstring Delimiter Restoration
; DESCRIPTION:
; Restores only shipped delimiter defaults. Personal word and consumed markers
; retain their exact sequence, including disabled, duplicate and Unicode values.
; Native owners retain admission, durable publication and compensating rollback.
; ==============================================================================

/**
 * Restores shipped defaults while preserving both independent personal strings.
 * @param {Array} Catalogue Shipped definitions from the generated catalogue owner.
 * @param {String} CurrentWord Admitted current word-delimiter string.
 * @param {String} CurrentConsumed Admitted current consumed-delimiter string.
 * @returns {Object} Word, Consumed and their shipped DefaultWord/DefaultConsumed.
 */
HotstringsTerminatorRestore(Catalogue, CurrentWord, CurrentConsumed) {
	if !(Catalogue is Array) || !(CurrentWord is String) || !(CurrentConsumed is String)
		throw TypeError("Delimiter restoration requires catalogue and string owners.")
	DefaultWord := "", DefaultConsumed := ""
	PersonalWord := CurrentWord, PersonalConsumed := CurrentConsumed
	for Definition in Catalogue {
		if !(Definition is Map)
			throw TypeError("The delimiter catalogue contains a malformed definition.")
		if Definition.Get("type", "") == "separator" || Definition.Get("custom", false)
			continue
		if !(Definition.Get("chars", 0) is Array)
				|| !(Definition.Get("default_enabled", -1) is Integer)
				|| !(Definition["default_enabled"] == 0 || Definition["default_enabled"] == 1)
				|| !(Definition.Get("consume", -1) is Integer)
				|| !(Definition["consume"] == 0 || Definition["consume"] == 1)
			throw TypeError("The delimiter catalogue definition is incomplete.")
		for Character in Definition["chars"] {
			if !(Character is String) || Character == ""
				throw TypeError("The delimiter catalogue character is invalid.")
			; Filter whole strings, rather than deduplicating UTF-16 units: two
			; supplementary characters can share a high surrogate.
			PersonalWord := StrReplace(PersonalWord, Character, "", true)
			PersonalConsumed := StrReplace(PersonalConsumed, Character, "", true)
			if Definition["default_enabled"] {
				DefaultWord .= Character
				if Definition["consume"]
					DefaultConsumed .= Character
			}
		}
	}
	return { Word: DefaultWord . PersonalWord, Consumed: DefaultConsumed . PersonalConsumed,
		DefaultWord: DefaultWord, DefaultConsumed: DefaultConsumed }
}
