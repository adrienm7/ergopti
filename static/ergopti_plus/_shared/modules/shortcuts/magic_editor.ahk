; _shared/modules/shortcuts/magic_editor.ahk

; ==============================================================================
; MODULE: Shared Physical Magic Editor Policy
; DESCRIPTION:
; Portable AHK policy implements the same acknowledged-source and ordinary-slot
; contract as shared shortcuts.magic_editor. Both language implementations replay
; the independent common corpus; native probing and acquisition stay in drivers.
; ==============================================================================





; ====================================
; ====================================
; ======= 1/ Physical evidence =======
; ====================================
; ====================================

/** Returns the stable ordinary slot, path and binding identities. */
MagicEditorSlot() {
	static Slot := Map("id", "magic_editor", "path", "shortcuts.keyboard.magic_editor",
		"binding_id", "keyboard__magic_editor")
	return Slot
}

/** Returns whether a value is a non-negative integer owner generation. */
_MagicEditorGeneration(Value) {
	return (Value is Integer) && Value >= 0
}

/** Returns whether an owner supplied an actual boolean gate. */
_MagicEditorBoolean(Value) {
	return (Value is Integer) && (Value == 0 || Value == 1)
}

/**
 * Selects a unique acknowledged direct-tap source, without changing lock state.
 * @param {Map} Source Native evidence with generation, status and candidates.
 * @param {String} Trigger Current trigger, compared case-sensitively.
 * @param {Map} KnownCodes Actual physical registry code inventory.
 * @returns {Map} Source (or zero) and stable inactive reason.
 */
MagicEditorSelectSource(Source, Trigger, KnownCodes) {
	if !(Source is Map) || !_MagicEditorGeneration(Source.Get("generation", -1))
		throw TypeError("Magic editor source evidence requires an owner generation.")
	if !(Trigger is String) || Trigger == "" || !(KnownCodes is Map)
		throw TypeError("Magic editor source requires its trigger and physical catalogue.")
	Status := Source.Get("status", "")
	if Status == "unavailable"
		return Map("source", 0, "reason", "source_unavailable")
	if Status != "ready" || !(Source.Get("candidates", 0) is Array)
		throw TypeError("Magic editor source evidence lacks its native candidates.")
	Candidates := Map(), Dead := false, Modified := false
	Rows := Source["candidates"]
	loop Rows.Length {
		if !Rows.Has(A_Index)
			throw TypeError("Magic editor source candidates contain a hole.")
		Candidate := Rows[A_Index]
		if !(Candidate is Map) || !(Candidate.Get("code", 0) is String)
				|| !KnownCodes.Has(Candidate["code"])
			throw TypeError("Magic editor source is outside the physical catalogue.")
		if !_MagicEditorGeneration(Candidate.Get("native_code", -1))
				|| !(Candidate.Get("identity", 0) is String) || Candidate["identity"] == ""
				|| !(Candidate.Get("text", 0) is String)
				|| !_MagicEditorBoolean(Candidate.Get("direct", -1))
				|| !_MagicEditorBoolean(Candidate.Get("dead", -1))
			throw TypeError("Magic editor source lacks direct-tap evidence.")
		if Candidate["text"] !== Trigger
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
 * Resolves the same ordinary-slot decision as shared shortcuts.magic_editor.
 * @param {Map} Options Manifest default, stored action, native evidence and gates.
 * @returns {Map} Detached native-acquisition and configured-action decision.
 */
MagicEditorResolve(Options) {
	if !(Options is Map) || !HasMethod(Options.Get("is_action", 0), "Call")
		throw TypeError("Magic editor resolution requires the ordinary action catalogue.")
	Valid := Options["is_action"], Default := Options.Get("default_action", 0)
	if !(Default is String) || !Valid.Call(Default)
		throw ValueError("The magic editor manifest default is not a runnable action.")
	Action := Options.Get("stored_action", Default)
	if !(Action is String) || (Action !== "none" && !Valid.Call(Action))
		throw ValueError("The configured magic editor action is not owned.")
	if !_MagicEditorGeneration(Options.Get("configuration_generation", -1))
			|| !(Options.Get("explicit_claims", 0) is Map)
		throw TypeError("Magic editor resolution requires configuration and claim provenance.")
	Admission := Options.Get("admission", 0)
	if !(Admission is Map)
		throw TypeError("Magic editor admission requires its live gates.")
	for Gate in ["master", "paused", "inhibited"] {
		if !_MagicEditorBoolean(Admission.Get(Gate, -1))
			throw TypeError("Magic editor admission requires boolean gates.")
	}
	Selected := MagicEditorSelectSource(Options["source"], Options["trigger"], Options["known_codes"])
	Slot := MagicEditorSlot()
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
MagicEditorCanDeliver(Decision, State) {
	return (Decision is Map) && Decision.Get("active", false) && (State is Map)
		&& State.Get("master", false) && !State.Get("paused", true) && !State.Get("inhibited", true)
		&& State.Get("action", "") == Decision["action"]
		&& State.Get("source_generation", -1) == Decision["source_generation"]
		&& State.Get("configuration_generation", -1) == Decision["configuration_generation"]
}
