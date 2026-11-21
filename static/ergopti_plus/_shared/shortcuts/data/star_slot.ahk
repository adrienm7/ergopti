; _shared/shortcuts/data/star_slot.ahk

; ==============================================================================
; MODULE: Shared ★ Key Slot Policy
; DESCRIPTION:
; Portable AHK twin of _shared/shortcuts/engine/star_slot_core.lua: the
; ordinary Win+★ slot (meta_star) of the key that types the real ★ at its base
; level, whose default opens the hotstrings editor wherever the layout has such
; a key (maintainer's decision of 2026-11-21). The configured magic key never
; moves it. Both implementations replay
; _shared/tests/corpus/shortcuts/star_slot_vectors.json; native probing and
; acquisition stay in the driver.
; ==============================================================================





; ====================================
; ====================================
; ======= 1/ Physical evidence =======
; ====================================
; ====================================

/** The character the slot's key types at its base level. */
global STAR_SLOT_MARKER := "★"

/** Returns the stable ordinary slot, path and binding identities of Windows. */
StarSlot() {
	static Slot := Map("id", "meta_star", "path", "shortcuts.keyboard.meta_star",
		"binding_id", "keyboard__meta_star")
	return Slot
}

/** Returns whether a value is a non-negative integer owner generation. */
_StarSlotGeneration(Value) {
	return (Value is Integer) && Value >= 0
}

/** Returns whether an owner supplied an actual boolean gate. */
_StarSlotBoolean(Value) {
	return (Value is Integer) && (Value == 0 || Value == 1)
}

/**
 * Selects the unique key typing ★ at its base level, without changing lock state.
 * @param {Map} Source Native evidence with generation, status and candidates.
 * @param {Map} KnownCodes Actual physical registry code inventory.
 * @returns {Map} Source (or zero) and stable inactive reason.
 */
StarSlotSelectSource(Source, KnownCodes) {
	global STAR_SLOT_MARKER
	if !(Source is Map) || !_StarSlotGeneration(Source.Get("generation", -1))
		throw TypeError("The ★ key slot source evidence requires an owner generation.")
	if !(KnownCodes is Map)
		throw TypeError("The ★ key slot source requires its physical catalogue.")
	Status := Source.Get("status", "")
	if Status == "unavailable"
		return Map("source", 0, "reason", "source_unavailable")
	if Status != "ready" || !(Source.Get("candidates", 0) is Array)
		throw TypeError("The ★ key slot source evidence lacks its native candidates.")
	Candidates := Map(), Dead := false, Modified := false
	Rows := Source["candidates"]
	loop Rows.Length {
		if !Rows.Has(A_Index)
			throw TypeError("The ★ key slot source candidates contain a hole.")
		Candidate := Rows[A_Index]
		if !(Candidate is Map) || !(Candidate.Get("code", 0) is String)
				|| !KnownCodes.Has(Candidate["code"])
			throw TypeError("The ★ key slot source is outside the physical catalogue.")
		if !_StarSlotGeneration(Candidate.Get("native_code", -1))
				|| !(Candidate.Get("identity", 0) is String) || Candidate["identity"] == ""
				|| !(Candidate.Get("text", 0) is String)
				|| !_StarSlotBoolean(Candidate.Get("direct", -1))
				|| !_StarSlotBoolean(Candidate.Get("dead", -1))
			throw TypeError("The ★ key slot source lacks direct-tap evidence.")
		if Candidate["text"] !== STAR_SLOT_MARKER
			continue
		if Candidate["dead"]
			Dead := true
		else if !Candidate["direct"]
			Modified := true
		else
			Candidates[Candidate["identity"]] := Candidate.Clone()
	}
	if Candidates.Count > 1
		return Map("source", 0, "reason", "source_ambiguous")
	for _, Candidate in Candidates
		return Map("source", Candidate, "reason", "")
	return Map("source", 0, "reason", Dead ? "source_dead"
		: Modified ? "source_requires_modifiers" : "source_missing")
}





; =======================================
; =======================================
; ======= 2/ Ordinary slot policy =======
; =======================================
; =======================================

/**
 * Resolves the same ordinary-slot decision as _shared/shortcuts/engine/star_slot_core.lua.
 * @param {Map} Options Manifest default, stored action, native evidence and gates.
 * @returns {Map} Detached native-acquisition and configured-action decision.
 */
StarSlotResolve(Options) {
	if !(Options is Map) || !HasMethod(Options.Get("is_action", 0), "Call")
		throw TypeError("The ★ key slot resolution requires the ordinary action catalogue.")
	Valid := Options["is_action"], Default := Options.Get("default_action", 0)
	if !(Default is String) || !Valid.Call(Default)
		throw ValueError("The ★ key slot manifest default is not a runnable action.")
	Action := Options.Get("stored_action", Default)
	if !(Action is String) || (Action !== "none" && !Valid.Call(Action))
		throw ValueError("The configured ★ key slot action is not owned.")
	if !_StarSlotGeneration(Options.Get("configuration_generation", -1))
			|| !(Options.Get("explicit_claims", 0) is Map)
		throw TypeError("The ★ key slot resolution requires configuration and claim provenance.")
	Admission := Options.Get("admission", 0)
	if !(Admission is Map)
		throw TypeError("The ★ key slot admission requires its live gates.")
	for Gate in ["master", "paused", "inhibited"] {
		if !_StarSlotBoolean(Admission.Get(Gate, -1))
			throw TypeError("The ★ key slot admission requires boolean gates.")
	}
	Selected := StarSlotSelectSource(Options["source"], Options["known_codes"])
	Slot := StarSlot()
	Decision := Map("slot_id", Slot["id"], "path", Slot["path"], "binding_id", Slot["binding_id"],
		"action", Action, "active", false, "source", Selected["source"],
		"source_reason", Selected["reason"], "source_generation", Options["source"]["generation"],
		"configuration_generation", Options["configuration_generation"], "reason", "")
	if Action == "none"
		Decision["reason"] := "shortcut_disabled"
	else if !Admission["master"]
		Decision["reason"] := "shortcuts_disabled"
	else if Admission["paused"]
		Decision["reason"] := "paused"
	else if Admission["inhibited"]
		Decision["reason"] := "inhibited"
	else if Selected["reason"] != ""
		Decision["reason"] := Selected["reason"]
	else if Options["explicit_claims"].Has(Selected["source"]["identity"])
		Decision["reason"] := "explicit_assignment"
	else
		Decision["active"] := true
	return Decision
}

/** Rechecks source, assignment and live admission before queued native delivery. */
StarSlotCanDeliver(Decision, State) {
	return (Decision is Map) && Decision.Get("active", false) && (State is Map)
		&& State.Get("master", false) && !State.Get("paused", true) && !State.Get("inhibited", true)
		&& State.Get("action", "") == Decision["action"]
		&& State.Get("source_generation", -1) == Decision["source_generation"]
		&& State.Get("configuration_generation", -1) == Decision["configuration_generation"]
}
