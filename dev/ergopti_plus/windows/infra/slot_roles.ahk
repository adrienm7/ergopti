; infra/slot_roles.ahk

; ==============================================================================
; MODULE: Neutral Keyboard Slot Roles
; DESCRIPTION:
; Resolves the neutral slot ids of the one-shortcut model (PAR-41) to Windows
; modifiers and back. A slot id is modifier ROLES in a fixed order, then one key:
; primary_b, primary_shift_v, meta_space. Port of
; _shared/lua/shortcuts/slot_roles.lua; the corpus
; _shared/tests/corpus/shortcuts/neutral_slots.json replays both.
;
; FEATURES & RATIONALE:
; 1. Pure: no I/O and no driver state, callable before any boot stage.
; 2. Closed vocabulary: an unknown, repeated or misordered role, or a missing
;    key, is refused with a reason, never guessed.
; 3. Absence is explicit: a role this keyboard lacks returns the table's reason.
; ==============================================================================

#Include %A_LineFile%\..\..\_generated\slot_roles.ahk

/**
 * Parses a neutral slot id.
 * @param {String} Slot Candidate slot id.
 * @returns {Map} Map("roles", [...], "key", Key), or Map("reason", Why).
 */
SlotRoleParse(Slot) {
	Refuse := (Reason) => Map("reason", Reason)
	if !(Slot is String) || Slot == ""
		return Refuse("not a string")
	if InStr(Slot, "__") || SubStr(Slot, 1, 1) == "_" || SubStr(Slot, -1) == "_"
		return Refuse("empty token")
	Order := SlotRolesData()["modifier_order"]
	Tokens := StrSplit(Slot, "_")
	Roles := [], Last := 0
	loop Tokens.Length - 1 {
		Rank := _SlotRoleRank(Tokens[A_Index], Order)
		if Rank == 0
			return Refuse("unknown role " . Tokens[A_Index])
		if Rank <= Last
			return Refuse("role out of order or repeated: " . Tokens[A_Index])
		Last := Rank
		Roles.Push(Tokens[A_Index])
	}
	Key := Tokens[Tokens.Length]
	if _SlotRoleRank(Key, Order) != 0
		return Refuse("no key after the roles")
	if Roles.Length == 0
		return Refuse("no modifier: a bare key is never a shortcut slot")
	return Map("roles", Roles, "key", Key)
}

; Case-exact rank of a role, 0 when the token is none: TOML identities are exact.
_SlotRoleRank(Token, Order) {
	for Rank, Role in Order {
		if Role == Token
			return Rank
	}
	return 0
}

/**
 * Resolves a neutral slot to the Windows modifier names.
 * @param {String} Slot Neutral slot id.
 * @returns {Map} Map("modifiers", [...], "key", Key), or Map("reason", Why).
 */
SlotRoleNative(Slot) {
	Parsed := SlotRoleParse(Slot)
	if !Parsed.Has("roles")
		return Parsed
	Data := SlotRolesData()
	Modifiers := []
	for Role in Parsed["roles"] {
		if !Data["native"].Has(Role)
			return Map("reason", Data["absent_reason"][Role])
		Modifiers.Push(Data["native"][Role])
	}
	return Map("modifiers", Modifiers, "key", Parsed["key"])
}

/**
 * Names the neutral slot of a Windows chord.
 * @param {Array} Modifiers Windows modifier ids, in any order.
 * @param {String} Key Key id.
 * @returns {String} The slot id, or "" when a modifier has no role or repeats.
 */
SlotRoleFromNative(Modifiers, Key) {
	Data := SlotRolesData()
	Parts := []
	for Role in Data["modifier_order"] {
		if !Data["native"].Has(Role)
			continue
		Count := 0
		for Modifier in Modifiers
			Count += (Modifier == Data["native"][Role])
		if Count > 1
			return ""
		if Count == 1
			Parts.Push(Role)
	}
	if Parts.Length != Modifiers.Length || !(Key is String) || Key == "" || InStr(Key, "_")
		return ""
	Slot := ""
	for Role in Parts
		Slot .= Role . "_"
	Slot .= Key
	return SlotRoleParse(Slot).Has("roles") ? Slot : ""
}

/**
 * The slot prefixes this driver offers, in menu order.
 * @returns {Array} Prefixes such as "primary_shift_".
 */
SlotRoleFamilyPrefixes() {
	Prefixes := []
	for Family in SlotRolesData()["families"] {
		Prefix := ""
		for Role in Family
			Prefix .= Role . "_"
		Prefixes.Push(Prefix)
	}
	return Prefixes
}

/**
 * The chord spelling of a slot key: the catalogue's own, or the id itself for a
 * physical key outside the catalogue (meta_SC03A).
 * @param {String} Key Key id.
 * @returns {String} The chord key.
 */
SlotRoleChordKey(Key) {
	for Entry in SlotRolesData()["keys"] {
		if Entry["id"] == Key
			return Entry["chord_key"]
	}
	return Key
}
