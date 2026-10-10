; infra/hotstrings/terminator_records.ahk

; ==============================================================================
; MODULE: Custom Hotstring Terminator Records
; DESCRIPTION:
; Admits config.toml records through the typed document owner. Record edits retain
; foreign source spans and join the conditional journal and reload acknowledgement.
; The historical delimiter strings remain independent preference owners.
; ==============================================================================

#Requires AutoHotkey v2.0

global _HotstringsTerminatorRecords := 0

/** Returns one Unicode scalar verdict, including a complete surrogate pair. */
HotstringsTerminatorRecordCharacter(Value) {
	if !(Value is String) || Value == ""
		return false
	if StrLen(Value) == 1 {
		ScalarUnit := Ord(Value)
		return ScalarUnit != 0 && (ScalarUnit < 0xD800 || ScalarUnit > 0xDFFF)
	}
	if StrLen(Value) != 2
		return false
	First := NumGet(StrPtr(Value), 0, "UShort")
	Last := NumGet(StrPtr(Value), 2, "UShort")
	return First >= 0xD800 && First <= 0xDBFF && Last >= 0xDC00 && Last <= 0xDFFF
}

/** Resolves the same ordered key/character collision policy as both Lua drivers. */
HotstringsTerminatorRecordsResolve(Document) {
	global HSE_Terminators
	if !(Document is Map)
		throw TypeError("Terminator records require a typed configuration document.")
	Hotstrings := Document.Get("hotstrings", _TOML_DocumentTable())
	if !(Hotstrings is Map)
		return { Records: [], Rejected: [Map("index", 0, "reason", "invalid_namespace")] }
	Stored := Hotstrings.Get("terminators", [])
	if !_HotstringsTerminatorRecordDenseArray(Stored)
		return { Records: [], Rejected: [Map("index", 0, "reason", "invalid_list")] }
	Records := [], Rejected := []
	States := Hotstrings.Get("terminator_states", _TOML_DocumentTable())
	if !(States is Map) {
		Rejected.Push(Map("index", 0, "reason", "invalid_states"))
		States := _TOML_DocumentTable()
	}
	Keys := Map(), Characters := Map()
	Keys.CaseSense := "On", Characters.CaseSense := "On"
	for Definition in HSE_Terminators.all() {
		if Definition.Has("key")
			Keys[Definition["key"]] := true
		for Character in Definition.Get("chars", [])
			Characters[Character] := true
	}
	for RecordOrdinal, Record in Stored {
		Reason := ""
		if !(Record is Map)
			Reason := "invalid_record"
		else if !(Record.Get("key", 0) is String) || Record["key"] == ""
			Reason := "invalid_key"
		else if Keys.Has(Record["key"])
			Reason := "key_collision"
		else if !HotstringsTerminatorRecordCharacter(Record.Get("char", 0))
			Reason := "invalid_character"
		else if !(Record.Get("label", 0) is String) || Record["label"] == ""
			Reason := "invalid_label"
		else if !(Record.Get("consume", 0) is TOML_Bool)
			Reason := "invalid_consume"
		else if Characters.Has(Record["char"])
			Reason := "character_collision"
		if Reason != "" {
			Rejected.Push(Map("index", RecordOrdinal, "reason", Reason))
			continue
		}
		Keys[Record["key"]] := true, Characters[Record["char"]] := true
		Enabled := true
		if States.Has(Record["key"]) {
			if States[Record["key"]] is TOML_Bool
				Enabled := !!States[Record["key"]].Value
			else
				Rejected.Push(Map("index", RecordOrdinal, "reason", "invalid_state"))
		}
		Records.Push({ Index: RecordOrdinal, Key: Record["key"], Char: Record["char"],
			Label: Record["label"], Consume: !!Record["consume"].Value, Enabled: Enabled })
	}
	return { Records: Records, Rejected: Rejected }
}

/** Consumes only the boot loader's admitted image; refusal publishes no record owner. */
HotstringsTerminatorRecordsInitBoot(Snapshot) {
	if Snapshot is Integer && Snapshot == 0
		return false
	if !(Snapshot is Object) || !HasProp(Snapshot, "Source") || !(Snapshot.Source is String)
		throw TypeError("The terminator boot owner requires an admitted configuration snapshot.")
	return HotstringsTerminatorRecordsInit(Snapshot.Source)
}

/** Initializes one boot owner without borrowing a later unrelated source read. */
HotstringsTerminatorRecordsInit(Source) {
	global _HotstringsTerminatorRecords, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	if _HotstringsTerminatorRecords is Object
		throw Error("The custom terminator record owner is already initialized.")
	Candidate := HotstringsTerminatorRecordsResolve(TOML_ParseDocument(Source))
	Candidate.Source := Source
	_HotstringsTerminatorRecords := Candidate
	HSE_WORD_TERMINATORS := HotstringsGetWordDelimiters()
	HSE_CONSUMED_DELIMITERS := HotstringsGetConsumedDelimiters()
	for Rejection in Candidate.Rejected
		LoggerWarn("HotstringsConfig", Format("Custom terminator record {1} ignored: {2}; source retained.",
			Rejection["index"], Rejection["reason"]))
	return true
}

/**
 * Projects admitted canonical records over only their exact historical scalar.
 * Explicit disabled and consume=false win for that scalar. Other characters and
 * the saved historical preferences remain unchanged; no migration is performed.
 */
HotstringsTerminatorRecordString(Base, Consumed := false) {
	global _HotstringsTerminatorRecords
	if !(_HotstringsTerminatorRecords is Object)
		return Base
	for Record in _HotstringsTerminatorRecords.Records {
		; The record owns its exact scalar, even when an older string contains it.
		Base := StrReplace(Base, Record.Char, "", true)
		if Record.Enabled && (!Consumed || Record.Consume)
			Base .= Record.Char
	}
	return Base
}

/** Captures the exact boot owner and displayed record without borrowing a fresh read. */
HotstringsTerminatorRecordCapture(Record) {
	global _HotstringsTerminatorRecords
	Owner := _HotstringsTerminatorRecords
	if !(Owner is Object) || !HasProp(Owner, "Source") || !(Owner.Source is String)
		throw ValueError("A displayed terminator requires its initialized source owner.")
	for OwnedRecord in Owner.Records {
		if OwnedRecord == Record
			return { Owner: Owner, Record: Record, Source: Owner.Source,
				Key: Record.Key, Char: Record.Char, Label: Record.Label,
				Consume: Record.Consume, Enabled: Record.Enabled }
	}
	throw ValueError("The displayed terminator does not belong to the runtime owner.")
}

/** Refuses a retired owner or changed record before a retained menu can acquire effects. */
HotstringsTerminatorRecordCurrent(Admission) {
	global _HotstringsTerminatorRecords
	if !(Admission is Object)
		return false
	for Field in ["Owner", "Record", "Source", "Key", "Char", "Label", "Consume", "Enabled"]
		if !HasProp(Admission, Field)
			return false
	if !(Admission.Owner is Object) || Admission.Owner != _HotstringsTerminatorRecords
			|| !(Admission.Record is Object) || !(Admission.Source is String)
			|| !HasProp(Admission.Owner, "Source") || Admission.Owner.Source !== Admission.Source
		return false
	for Record in Admission.Owner.Records {
		if Record == Admission.Record
			return Record.Key == Admission.Key && Record.Char == Admission.Char
				&& Record.Label == Admission.Label && Record.Consume == Admission.Consume
				&& Record.Enabled == Admission.Enabled
	}
	return false
}

/** Builds a detached list edit; unknown fields and quarantined rows survive. */
HotstringsTerminatorRecordPlan(Source, Operation) {
	if !(Operation is Map) || !(Operation.Get("mode", 0) is String)
		throw TypeError("A terminator edit requires an explicit operation map.")
	if Operation.Has("admission") {
		Admission := Operation["admission"]
		if !HotstringsTerminatorRecordCurrent(Admission)
				|| (Operation["mode"] != "remove" && Operation["mode"] != "state")
				|| Operation.Get("key", 0) !== Admission.Key || Source !== Admission.Source
			throw ValueError("The displayed terminator source owner changed before editing.")
	}
	Document := TOML_ParseDocument(Source, , &Physical)
	Before := HotstringsTerminatorRecordsResolve(Document)
	Hotstrings := Document.Get("hotstrings", _TOML_DocumentTable())
	if !(Hotstrings is Map)
		throw ValueError("The hotstrings namespace is not a table.")
	Stored := Hotstrings.Get("terminators", [])
	if !_HotstringsTerminatorRecordDenseArray(Stored)
		throw ValueError("The custom terminator list is not an array.")
	Next := ManifestCloneValue(Stored)
	States := ManifestCloneValue(Hotstrings.Get("terminator_states", _TOML_DocumentTable()))
	HasStates := Hotstrings.Has("terminator_states")
	RecordEditMode := Operation["mode"]
	if RecordEditMode == "add" {
		Record := ManifestCloneValue(Operation.Get("record", 0))
		if !(Record is Map)
			throw TypeError("Adding a terminator requires a record.")
		Record["key"] := _HotstringsTerminatorFreshKey(Stored, States, Record.Get("key", 0))
		; Add owns a new active slot, never an update of an existing key/state.
		States[Record["key"]] := TOML_Bool(true), HasStates := true
		Next.Push(Record)
	} else if RecordEditMode == "upsert" {
		Record := Operation.Get("record", 0)
		if !(Record is Map) || !(Record.Get("key", 0) is String)
			throw TypeError("A terminator edit requires a keyed record.")
		Selected := 0
		for Entry in Before.Records
			if Entry.Key == Record["key"]
				Selected := Entry.Index
		if Selected {
			Merged := ManifestCloneValue(Next[Selected])
			for RecordMemberKey, RecordMemberValue in Record
				Merged[RecordMemberKey] := ManifestCloneValue(RecordMemberValue)
			Next[Selected] := Merged
		} else
			Next.Push(ManifestCloneValue(Record))
	} else if RecordEditMode == "remove" {
		RecordMemberKey := Operation.Get("key", 0), Selected := 0
		if !(RecordMemberKey is String)
			throw TypeError("Removing a terminator requires its exact key.")
		for Entry in Before.Records
			if Entry.Key == RecordMemberKey
				Selected := Entry.Index
		if !Selected
			throw ValueError("The requested terminator has no admitted record owner.")
		Next.RemoveAt(Selected)
	} else if RecordEditMode == "state" {
		RecordMemberKey := Operation.Get("key", 0), Enabled := Operation.Get("enabled", -1)
		if !(RecordMemberKey is String) || !(Enabled is Integer) || (Enabled != 0 && Enabled != 1)
			throw TypeError("A terminator state requires a key and strict Boolean.")
		Selected := 0
		for Entry in Before.Records
			if Entry.Key == RecordMemberKey
				Selected := Entry.Index
		if !Selected || !(States is Map)
			throw ValueError("The requested terminator state has no admitted record owner.")
		States[RecordMemberKey] := TOML_Bool(Enabled), HasStates := true
	} else
		throw ValueError("Unsupported terminator record operation.")
	Model := ManifestCloneValue(Document)
	if !Model.Has("hotstrings")
		Model["hotstrings"] := _TOML_DocumentTable()
	Model["hotstrings"]["terminators"] := Next
	if HasStates
		Model["hotstrings"]["terminator_states"] := States
	After := HotstringsTerminatorRecordsResolve(Model)
	if RecordEditMode == "upsert" || RecordEditMode == "add" {
		Admitted := false
		for Entry in After.Records
			if Entry.Key == Record["key"] && Entry.Char == Record.Get("char", "")
					&& (RecordEditMode != "add" || Entry.Enabled)
				Admitted := true
		if !Admitted
			throw ValueError("The proposed terminator record violates the catalogue policy.")
	}
	; Updating an earlier record cannot take a later admitted sibling
	; character and silently quarantine that sibling on the next boot.
	for Original in Before.Records {
		if (RecordEditMode == "upsert" && Original.Key == Record["key"])
				|| (RecordEditMode == "remove" && Original.Key == RecordMemberKey)
				|| (RecordEditMode == "state" && Original.Key == RecordMemberKey)
			continue
		Kept := false
		for Entry in After.Records
			if Entry.Key == Original.Key && Entry.Char == Original.Char
					&& Entry.Consume == Original.Consume && Entry.Enabled == Original.Enabled
				Kept := true
		if !Kept
			throw ValueError("The proposed terminator record displaced an admitted sibling.")
	}
	Candidate := (SubStr(Source, 1, 1) == Chr(0xFEFF) ? Chr(0xFEFF) : "")
		. _HotstringsTerminatorRecordImage(Physical, Next, States, HasStates)
	if !TOML_SameValue(TOML_ParseDocument(Candidate), Model)
		throw ValueError("The terminator image changed a foreign semantic owner.")
	return { Content: Candidate, Settings: After }
}

/** Chooses a new exact key within the finite occupied-key cardinality bound. */
_HotstringsTerminatorFreshKey(Stored, States, Preferred) {
	global HSE_Terminators
	if !_HotstringsTerminatorRecordDenseArray(Stored) || !(States is Map)
		throw ValueError("Adding a terminator requires addressable record and state owners.")
	if !(Preferred is String) || Preferred == ""
		throw TypeError("Adding a terminator requires a nonempty preferred key.")
	OccupiedKeys := Map()
	OccupiedKeys.CaseSense := "On"
	for ExistingRecord in Stored {
		if ExistingRecord is Map && ExistingRecord.Get("key", 0) is String
			OccupiedKeys[ExistingRecord["key"]] := true
	}
	for ExistingStateKey in States
		OccupiedKeys[ExistingStateKey] := true
	for PredefinedRecord in HSE_Terminators.all() {
		if PredefinedRecord.Has("key")
			OccupiedKeys[PredefinedRecord["key"]] := true
	}
	; N occupied keys cannot cover N+1 distinct candidates. No random fallback,
	; fixed retry ceiling or cached menu snapshot participates in this choice.
	loop OccupiedKeys.Count + 1 {
		CandidateKey := A_Index == 1 ? Preferred : Preferred . "_" . (A_Index - 1)
		if !OccupiedKeys.Has(CandidateKey)
			return CandidateKey
	}
	throw Error("The finite fresh terminator key proof was violated.")
}

/** Replaces only a direct list assignment or its complete table-array subtree. */
_HotstringsTerminatorRecordImage(Physical, Records, States, HasStates) {
	Kept := "", Trivia := "", Inserted := false
	Leaves := "terminators = " . TOML_RenderValue(Records) . "`n"
	if HasStates
		Leaves .= "terminator_states = " . TOML_RenderValue(States) . "`n"
	for PhysicalRecordRow in Physical {
		Section := PhysicalRecordRow.Section == "" ? [] : TOML_ParseKeyPath(PhysicalRecordRow.Section, true)
		Parts := Section.Clone()
		if PhysicalRecordRow.Kind == "assignment" {
			for StateMemberKey in TOML_ParseKeyPath(PhysicalRecordRow.Key, true)
				Parts.Push(StateMemberKey)
			if Parts.Length == 1 && Parts[1] == "hotstrings" {
				InlineChanges := Map()
				InlineChanges.CaseSense := "On"
				InlineChanges["terminators"] := Map("delete", false, "value", Records)
				if HasStates
					InlineChanges["terminator_states"] := Map("delete", false, "value", States)
				Kept .= _TOML_InlineTableRewriteRecord(PhysicalRecordRow.Text, InlineChanges)
				Inserted := true
				continue
			}
		}
		Owned := Parts.Length >= 2 && Parts[1] == "hotstrings"
			&& (Parts[2] == "terminators" || (HasStates && Parts[2] == "terminator_states"))
		if Owned {
			if PhysicalRecordRow.Kind == "trivia"
				Trivia .= PhysicalRecordRow.Text
		} else {
			Kept .= PhysicalRecordRow.Text
			if PhysicalRecordRow.Kind == "header" && Section.Length == 1 && Section[1] == "hotstrings" {
				; Reuse the existing parent declaration instead of manufacturing a
				; dotted parent that would conflict with its explicit table header.
				Kept .= (SubStr(PhysicalRecordRow.Text, -1) == "`n" ? "" : "`n") . Leaves
				Inserted := true
			}
		}
	}
	if !Inserted {
		; A direct parent header keeps this editor's new list representable by
		; the ordinary writer instead of introducing ignored root dotted leaves.
		Kept := "[hotstrings]`n" . Leaves . Kept
	}
	return Kept . (SubStr(Kept, -1) == "`n" ? "" : "`n") . Trivia
}

/**
 * Publishes one record edit through the existing exact-source WAL/reload owner.
 * @param {Map} Operation Explicit add/upsert/remove/state record request.
 * @param {Map} Options Existing path, locator, port, acquire, settle and reload seams.
 * @returns {Map} pending/committed/refused/recovery_required; never an early success.
 */
HotstringsTerminatorRecordsEdit(Operation, Options := unset) {
	global ConfigurationFile, _PathsFile
	if !IsSet(Options)
		Options := Map()
	if !(Options is Map)
		throw TypeError("Terminator record edits require owner options.")
	PreviousCritical := Critical("Off")
	try {
		Path := Options.Get("path", ConfigurationFile)
		Locator := Options.Get("locator", _PathsFile)
		Port := Options.Get("port", 0)
		ReloadFn := Options.Get("reload", ReloadPreservingSuspend)
		Receipt := Map("status", "refused", "scope", "terminator_records")
		if TOML_WriteRefusal(Path) != "" {
			Receipt["error"] := "source_write_refused"
			LoggerError("HotstringsConfig", "Custom terminator editing refused a session-protected source.")
			return Receipt
		}
		if !HasMethod(ReloadFn, "Call")
			throw TypeError("Terminator editing requires a callable reload owner.")
		if Operation.Has("admission") && (A_IsSuspended
				|| !HotstringsTerminatorRecordCurrent(Operation["admission"]))
			return Receipt
		Acquired := ConfigTransitionAcquireLifecycleBundle(Locator, [Path], Port,
			Options.Get("acquire", 0), Options.Get("settle", 0))
		if !ConfigTransitionResultIs(Acquired, "bundle_acquired") {
			Receipt["detail"] := Acquired
			ConfigTransitionLogFailure("HotstringsConfig", Acquired)
			return Receipt
		}
		Bundle := Acquired["bundle"], Transferred := false
		Rollback() {
			try Resolution := ConfigTransitionRollbackOwned(Locator, Bundle, Port)
			catch as Err
				Resolution := Map("status", "fatal", "kind", "rollback_threw", "detail", Err.Message)
			Receipt["detail"] := Resolution
			if ConfigTransitionResultIs(Resolution, "absent") || ConfigTransitionResultIs(Resolution, "recovered_old") {
				Receipt["status"] := "refused"
				return false
			}
			Receipt["status"] := "recovery_required"
			ConfigTransitionRetainBarrier(Bundle)
			try ConfigTransitionLogFailure("HotstringsConfig", Resolution)
			return true
		}
		Succeeded(*) {
			if Receipt["status"] != "pending" || !(_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object)
				return false
			Receipt["status"] := "committed"
			return true
		}
		Refused(*) {
			if Receipt["status"] != "pending"
				return false
			Retained := true
			try Retained := Rollback()
			finally {
				if !Retained
					_ConfigWriteTerminalRelease(Bundle)
			}
		}
		try {
			Present := FileExist(Path) ? 1 : 0
			OriginalRecordSource := Present ? FSReadUtf8Exact(Path) : ""
			if !(OriginalRecordSource is String)
				throw Error("The terminator source could not be read exactly.")
			if Operation.Has("admission") && A_IsSuspended
				throw ValueError("The displayed terminator operation was paused before publication.")
			Candidate := HotstringsTerminatorRecordPlan(OriginalRecordSource, Operation)
			Expected := ConfigTransitionExpectedOld(Present, OriginalRecordSource, Port)
			if !(Expected is Map)
				throw Error("The terminator source precondition could not be established.")
			Result := ConfigTransitionCommitOwned(Locator,
				[ConfigTransitionPresentTarget(Path, Candidate.Content, Expected)], Bundle, Port)
			Receipt["detail"] := Result
			if !ConfigTransitionResultIs(Result, "committed_new") {
				Transferred := Rollback()
				return Receipt
			}
			Receipt["status"] := "pending"
			try Launched := ReloadFn.Call(Succeeded, Bundle, Refused)
			catch as Err {
				Launched := false
				Receipt["reload_error"] := Err.Message
			}
			if (Launched is Integer) && Launched == 1 {
				Transferred := true
				return Receipt
			}
			Transferred := Rollback()
			return Receipt
		} catch as Err {
			Receipt["error"] := Err.Message
			Transferred := Rollback()
			try LoggerError("HotstringsConfig", "Custom terminator editing was refused before runtime publication.")
			return Receipt
		} finally {
			if !Transferred
				_ConfigWriteTerminalRelease(Bundle)
		}
	} finally Critical(PreviousCritical)
}

/** Rejects sparse record arrays before indexing an owned row. */
_HotstringsTerminatorRecordDenseArray(Values) {
	if !(Values is Array)
		return false
	loop Values.Length
		if !Values.Has(A_Index)
			return false
	return true
}
