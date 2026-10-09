; _shared/modules/hotstrings/personal_scope.ahk

; ==============================================================================
; MODULE: Personal File Scope Admission (Windows Port)
; DESCRIPTION:
; Replays the shared admission contract without treating provenance as an
; exclusive gate. Native owners must adopt and recheck additional-file gates.
; ==============================================================================

/**
 * Validates one exact descriptor, native owner and pathname binding.
 * @param {Object} Value Native evidence or a captured selection.
 * @returns {Integer} True only for a valid source binding.
 */
PersonalScopeBindingValid(Value) {
	return Value is Map && Value.Has("source") && PersonalFileDescriptorValid(Value["source"])
		&& Value.Has("owner") && Value["owner"] is String && Value["owner"] != ""
		&& Value.Has("path") && Value["path"] is String && Value["path"] != ""
}

/**
 * Admits one current exclusive binding before any native mutation.
 * @param {Array} Inventory Dense current native evidence records.
 * @param {Map} Selected Captured descriptor, native owner and pathname.
 * @param {String} Reason Stable refusal identifier without user values.
 * @returns {Map|Integer} Detached admitted binding, or false without effects.
 */
PersonalScopeAdmit(Inventory, Selected, &Reason) {
	Reason := ""
	if !(Inventory is Array) || !PersonalScopeBindingValid(Selected) {
		Reason := "invalid-request"
		return false
	}
	Found := 0, Ids := Map()
	loop Inventory.Length {
		if !Inventory.Has(A_Index) {
			Reason := "invalid-request"
			return false
		}
		Record := Inventory[A_Index]
		if !PersonalScopeBindingValid(Record) || !Record.Has("admitted") || !Record.Has("exclusive")
			|| !(Record["admitted"] is Integer) || !(Record["exclusive"] is Integer)
			|| (Record["admitted"] != 0 && Record["admitted"] != 1)
			|| (Record["exclusive"] != 0 && Record["exclusive"] != 1) {
			Reason := "invalid-inventory"
			return false
		}
		Id := Record["source"]["id"]
		if Ids.Has(Id) {
			Reason := "duplicate-source"
			return false
		}
		Ids[Id] := true
		if Id == Selected["source"]["id"]
			Found := Record
	}
	if !(Found is Map)
		Reason := "unknown-source"
	else if !(Found["owner"] == Selected["owner"]) || !(Found["path"] == Selected["path"])
		Reason := "stale-binding"
	else if !Found["admitted"]
		Reason := "unadmitted-source"
	else if !Found["exclusive"]
		Reason := "unavailable-owner"
	if Reason != ""
		return false
	for Record in Inventory {
		if Record["admitted"] && Record["owner"] == Found["owner"]
			&& !(Record["source"]["id"] == Found["source"]["id"]) {
			Reason := "shared-owner"
			return false
		}
	}
	return Map("source", PersonalFileDescriptorCopy(Found["source"]), "owner", Found["owner"], "path", Found["path"])
}

/** Mirrors the shared detached adoption plan; native capability admission remains separate. */
PersonalScopePlanAdoption(Candidates) {
	if !(Candidates is Array)
		throw TypeError("Invalid personal-file adoption candidates.")
	Inventory := [], Ids := Map(), Paths := Map(), Physical := Map(), Legacy := Map()
	for Candidate in Candidates {
		if !(Candidate is Map) || !Candidate.Has("source") || !PersonalFileDescriptorValid(Candidate["source"])
			|| !Candidate.Has("path") || !(Candidate["path"] is String) || Candidate["path"] == ""
			throw TypeError("Invalid personal-file adoption evidence.")
		for Field in ["physical", "legacy_owner"] {
			if Candidate.Has(Field) && (!(Candidate[Field] is String) || Candidate[Field] == "")
				throw TypeError("Invalid personal-file adoption evidence.")
		}
		Inventory.Push(Map("source", PersonalFileDescriptorCopy(Candidate["source"]),
			"owner", Candidate["source"]["id"], "path", Candidate["path"], "admitted", true, "exclusive", true))
		for Field, Values in Map("id", Ids, "path", Paths, "physical", Physical, "legacy_owner", Legacy) {
			if Field != "id" && !Candidate.Has(Field)
				continue
			Key := Field == "id" ? Candidate["source"]["id"] : Candidate[Field]
			if !Values.Has(Key)
				Values[Key] := []
			Values[Key].Push(Inventory.Length)
		}
	}
	for Pair in [[Ids, "duplicate-source"], [Paths, "path-alias"], [Physical, "physical-alias"], [Legacy, "ambiguous-legacy-owner"]] {
		for Key, Indices in Pair[1] {
			if Indices.Length > 1 {
				for Index in Indices {
					Inventory[Index]["admitted"] := false
					Inventory[Index]["exclusive"] := false
					if !Inventory[Index].Has("reason")
						Inventory[Index]["reason"] := Pair[2]
				}
			}
		}
	}
	return Inventory
}
