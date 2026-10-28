; infra/hotstrings/terminator_records.ahk

; ==============================================================================
; MODULE: Custom Hotstring Terminator Records
; DESCRIPTION:
; Admits config.toml delimiter state through the typed document owner:
;   hotstrings.terminators          the user's own delimiters, as records;
;   hotstrings.terminator_states    key = enabled, only where it differs from the
;                                   catalogue default (built-in and custom keys);
;   hotstrings.terminator_consume   key = consumed, only where it differs from the
;                                   catalogue default (built-in keys).
; The word and consumed strings the engine matches are DERIVED from these leaves;
; no override-file string remains. A built-in delimiter click writes its leaf
; through the live configuration writer (no reload); record edits keep their
; conditional journal and reload acknowledgement.
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
		return _HotstringsTerminatorRecordsRefused("invalid_namespace")
	Stored := Hotstrings.Get("terminators", [])
	if !_HotstringsTerminatorRecordDenseArray(Stored)
		return _HotstringsTerminatorRecordsRefused("invalid_list")
	Records := [], Rejected := []
	States := Hotstrings.Get("terminator_states", _TOML_DocumentTable())
	if !(States is Map) {
		Rejected.Push(Map("index", 0, "reason", "invalid_states"))
		States := _TOML_DocumentTable()
	}
	Consumption := Hotstrings.Get("terminator_consume", _TOML_DocumentTable())
	if !(Consumption is Map) {
		Rejected.Push(Map("index", 0, "reason", "invalid_consume_states"))
		Consumption := _TOML_DocumentTable()
	}
	Builtin := _HotstringsTerminatorBuiltinResolve(States, Consumption, Rejected)
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
	return { Records: Records, Rejected: Rejected, Builtin: Builtin.State, Stored: Builtin.Stored }
}

/** The settings of a configuration whose delimiter namespace cannot be read: the catalogue alone. */
_HotstringsTerminatorRecordsRefused(Reason) {
	Rejected := [Map("index", 0, "reason", Reason)]
	Builtin := _HotstringsTerminatorBuiltinResolve(_TOML_DocumentTable(), _TOML_DocumentTable(), [])
	return { Records: [], Rejected: Rejected, Builtin: Builtin.State, Stored: Builtin.Stored }
}

/**
 * Resolves each built-in delimiter: a stored boolean leaf, else the catalogue default.
 * Stored keeps only the leaves actually present, so a write can delete a leaf that
 * returns to its default instead of leaving a redundant key.
 */
_HotstringsTerminatorBuiltinResolve(States, Consumption, Rejected) {
	global HSE_Terminators
	State := Map(), Stored := Map("enabled", Map(), "consume", Map())
	State.CaseSense := "On", Stored["enabled"].CaseSense := "On", Stored["consume"].CaseSense := "On"
	for Definition in HSE_Terminators.all() {
		if Definition.Get("type", "") == "separator" || !Definition.Has("key")
			continue
		Key := Definition["key"]
		Enabled := !!Definition["default_enabled"], Consumed := !!Definition["consume"]
		if States.Has(Key) {
			if States[Key] is TOML_Bool {
				Enabled := !!States[Key].Value
				Stored["enabled"][Key] := Enabled
			} else
				Rejected.Push(Map("index", 0, "key", Key, "reason", "invalid_state"))
		}
		if Consumption.Has(Key) {
			if Consumption[Key] is TOML_Bool {
				Consumed := !!Consumption[Key].Value
				Stored["consume"][Key] := Consumed
			} else
				Rejected.Push(Map("index", 0, "key", Key, "reason", "invalid_consume"))
		}
		State[Key] := { Enabled: Enabled, Consume: Consumed }
	}
	return { State: State, Stored: Stored }
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
		LoggerWarn("HotstringsConfig", Format("Terminator setting {1} ignored: {2}; source retained.",
			Rejection.Has("key") ? Rejection["key"] : Rejection["index"], Rejection["reason"]))
	return true
}

/**
 * Derives the two strings the engine matches from the delimiter settings: every
 * enabled built-in delimiter by catalogue order, then every enabled record. The
 * consumed string holds the characters of the enabled delimiters that are consumed.
 * Without an initialized owner the catalogue defaults apply.
 * @returns {Object} Word and Consumed strings.
 */
HotstringsTerminatorStrings() {
	global HSE_Terminators, _HotstringsTerminatorRecords
	Owner := _HotstringsTerminatorRecords
	Word := "", Consumed := ""
	for Definition in HSE_Terminators.all() {
		if Definition.Get("type", "") == "separator" || !Definition.Has("key")
			continue
		if Owner is Object && Owner.Builtin.Has(Definition["key"])
			State := Owner.Builtin[Definition["key"]]
		else
			State := { Enabled: !!Definition["default_enabled"], Consume: !!Definition["consume"] }
		if !State.Enabled
			continue
		for Character in Definition["chars"] {
			Word .= Character
			if State.Consume
				Consumed .= Character
		}
	}
	if Owner is Object {
		for Record in Owner.Records {
			if !Record.Enabled
				continue
			Word .= Record.Char
			if Record.Consume
				Consumed .= Record.Char
		}
	}
	return { Word: Word, Consumed: Consumed }
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
		; A new table follows retained root scalars and dotted metadata; a
		; prepended header would move those genuine values into hotstrings.
		Kept .= (Kept == "" || SubStr(Kept, -1) == "`n" ? "" : "`n")
			. "[hotstrings]`n" . Leaves
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

/**
 * The catalogue defaults of every built-in delimiter, by key.
 * @returns {Map} Key -> { Enabled, Consume }.
 */
_HotstringsTerminatorDefaults() {
	global HSE_Terminators
	Defaults := Map()
	Defaults.CaseSense := "On"
	for Definition in HSE_Terminators.all() {
		if Definition.Get("type", "") == "separator" || !Definition.Has("key")
			continue
		Defaults[Definition["key"]] := { Enabled: !!Definition["default_enabled"], Consume: !!Definition["consume"] }
	}
	return Defaults
}

/**
 * Plans the sparse leaf updates of a set of built-in delimiter changes: a value
 * equal to the catalogue default deletes its leaf, any other value writes it, and
 * a value already stored is not rewritten.
 * @param {Object} Owner The initialized record owner.
 * @param {Map} Changes Key -> Map("enabled", Boolean?, "consume", Boolean?).
 * @returns {Object} Updates (Array), State and Stored (the owner's next maps).
 */
_HotstringsTerminatorBuiltinPlan(Owner, Changes) {
	if !(Changes is Map)
		throw TypeError("Built-in delimiter changes require a Map.")
	Defaults := _HotstringsTerminatorDefaults()
	State := Map(), Stored := Map("enabled", Owner.Stored["enabled"].Clone(), "consume", Owner.Stored["consume"].Clone())
	State.CaseSense := "On"
	for Key, Current in Owner.Builtin
		State[Key] := { Enabled: Current.Enabled, Consume: Current.Consume }
	Updates := []
	for Key, Change in Changes {
		if !(Key is String) || !State.Has(Key)
			throw ValueError("'" . String(Key) . "' is not a built-in delimiter.")
		if !(Change is Map)
			throw TypeError("A built-in delimiter change requires a Map.")
		for Field, Leaf in Map("enabled", "terminator_states", "consume", "terminator_consume") {
			if !Change.Has(Field)
				continue
			Wanted := Change[Field]
			if !(Wanted is Integer) || (Wanted != 0 && Wanted != 1)
				throw TypeError("A delimiter " . Field . " state is a strict Boolean.")
			Wanted := !!Wanted
			DefaultValue := Field == "enabled" ? Defaults[Key].Enabled : Defaults[Key].Consume
			Section := "hotstrings." . Leaf
			if Wanted == DefaultValue {
				if Stored[Field].Has(Key) {
					Updates.Push({ Section: Section, Key: Key, Delete: 1 })
					Stored[Field].Delete(Key)
				}
			} else if !Stored[Field].Has(Key) || Stored[Field][Key] != Wanted {
				Updates.Push({ Section: Section, Key: Key, Value: TOML_Bool(Wanted ? 1 : 0) })
				Stored[Field][Key] := Wanted
			}
			if Field == "enabled"
				State[Key].Enabled := Wanted
			else
				State[Key].Consume := Wanted
		}
	}
	return { Updates: Updates, State: State, Stored: Stored }
}

/**
 * Publishes the next built-in settings and the engine strings derived from them.
 * Runs inside the writer's short Critical window: memory swaps only.
 */
_HotstringsTerminatorPublishBuiltin(Owner, State, Stored) {
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Owner.Builtin := State
	Owner.Stored := Stored
	Strings := HotstringsTerminatorStrings()
	HSE_WORD_TERMINATORS := Strings.Word
	HSE_CONSUMED_DELIMITERS := Strings.Consumed
	if IsSet(HSE_AdvanceRuntimeDecisionGeneration)
		HSE_AdvanceRuntimeDecisionGeneration()
	return 1
}

/**
 * Writes built-in delimiter states through the live configuration writer: sparse
 * against the catalogue defaults, no reload, and the engine strings follow only
 * once the write is durable.
 * @param {Map} Changes Key -> Map("enabled", Boolean?, "consume", Boolean?).
 * @param {Func} WriterFn Optional writer seam.
 * @param {Func} NotifyFn Optional failure notifier seam.
 * @returns {Integer} 1 when persisted or already stored, otherwise 0.
 */
HotstringsTerminatorBuiltinCommit(Changes, WriterFn := 0, NotifyFn := 0) {
	global ConfigurationFile, _HotstringsTerminatorRecords
	Owner := _HotstringsTerminatorRecords
	if !(Owner is Object) {
		LoggerError("HotstringsConfig", "Delimiter settings refused: the terminator owner is not initialized.")
		return 0
	}
	Plan := _HotstringsTerminatorBuiltinPlan(Owner, Changes)
	if Plan.Updates.Length == 0
		return 1
	if !ConfigCommitUpdates(ConfigurationFile, Plan.Updates, "the word expander settings", WriterFn, NotifyFn,
			_HotstringsTerminatorPublishBuiltin.Bind(Owner, Plan.State, Plan.Stored))
		return 0
	; The file changed: record edits compare against its exact source.
	try Owner.Source := FSReadUtf8Exact(ConfigurationFile)
	catch as Err
		LoggerError("HotstringsConfig", Format("The delimiter source could not be re-read after the write: {1}.", Err.Message))
	if IsSet(HSE_InvalidateRuntimeDecisionProjection)
		HSE_InvalidateRuntimeDecisionProjection()
	return 1
}

/** Toggles one built-in delimiter entry by key. */
HotstringsTerminatorToggle(Key, WriterFn := 0, NotifyFn := 0) {
	global _HotstringsTerminatorRecords
	Owner := _HotstringsTerminatorRecords
	if !(Owner is Object) || !Owner.Builtin.Has(Key)
		return 0
	return HotstringsTerminatorBuiltinCommit(Map(Key, Map("enabled", !Owner.Builtin[Key].Enabled)), WriterFn, NotifyFn)
}

/** Enables or disables every built-in delimiter; the user's own records are untouched. */
HotstringsTerminatorSetAll(Enable, WriterFn := 0, NotifyFn := 0) {
	global _HotstringsTerminatorRecords
	Owner := _HotstringsTerminatorRecords
	if !(Owner is Object)
		return 0
	Changes := Map()
	for Key in Owner.Builtin
		Changes[Key] := Map("enabled", Enable ? 1 : 0)
	return HotstringsTerminatorBuiltinCommit(Changes, WriterFn, NotifyFn)
}

/** Returns every built-in delimiter to its catalogue state and consumption. */
HotstringsTerminatorRestoreBuiltin(WriterFn := 0, NotifyFn := 0) {
	global _HotstringsTerminatorRecords
	Owner := _HotstringsTerminatorRecords
	if !(Owner is Object)
		return 0
	Defaults := _HotstringsTerminatorDefaults()
	Changes := Map()
	for Key, Default in Defaults
		Changes[Key] := Map("enabled", Default.Enabled ? 1 : 0, "consume", Default.Consume ? 1 : 0)
	return HotstringsTerminatorBuiltinCommit(Changes, WriterFn, NotifyFn)
}

/**
 * Moves the word and consumed strings of earlier builds into the delimiter leaves,
 * keeping every effective choice: a built-in whose state or consumption differs
 * from the catalogue becomes a leaf (a leaf already stored wins), and every other
 * character becomes a record. Idempotent: a second run finds nothing to add.
 * @param {String} LegacyWord Stored word_delimiters, "" when absent.
 * @param {String} LegacyConsumed Stored consumed_delimiters, "" when absent.
 * @returns {Integer} 1 when the leaves hold the choices, otherwise 0.
 */
HotstringsTerminatorMigrateStrings(LegacyWord, LegacyConsumed, WriterFn := 0, NotifyFn := 0) {
	global ConfigurationFile, _HotstringsTerminatorRecords, HSE_Terminators
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Owner := _HotstringsTerminatorRecords
	if !(Owner is Object) {
		LoggerError("HotstringsConfig", "Delimiter migration refused: the terminator owner is not initialized.")
		return 0
	}
	Defaults := _HotstringsTerminatorDefaults()
	Word := LegacyWord != "" ? LegacyWord : HSE_TerminatorDefaultWordDelimiters()
	Consumed := LegacyConsumed != "" ? LegacyConsumed : HSE_TerminatorDefaultConsumedDelimiters()
	Changes := Map(), Owned := ""
	for Definition in HSE_Terminators.all() {
		if Definition.Get("type", "") == "separator" || !Definition.Has("key")
			continue
		Key := Definition["key"]
		for Character in Definition["chars"]
			Owned .= Character
		Change := Map()
		if !Owner.Stored["enabled"].Has(Key)
			Change["enabled"] := HSE_TerminatorEntryEnabled(Definition["chars"], Word) ? 1 : 0
		if !Owner.Stored["consume"].Has(Key)
			Change["consume"] := HSE_TerminatorAnyCharIn(Definition["chars"], Consumed) ? 1 : 0
		if Change.Count
			Changes[Key] := Change
	}
	Plan := _HotstringsTerminatorBuiltinPlan(Owner, Changes)
	Updates := Plan.Updates
	; Every other character of the old string is a delimiter of the user's own.
	RecordChars := Map()
	RecordChars.CaseSense := "On"
	for Record in Owner.Records
		RecordChars[Record.Char] := true
	Added := []
	for Character in _TextCodepoints(Word) {
		if Character == "`r" || Character == "`n" || InStr(Owned, Character) || RecordChars.Has(Character)
			continue
		if !HotstringsTerminatorRecordCharacter(Character) {
			LoggerWarn("HotstringsConfig", "A delimiter of the old word_delimiters string is not a single character and is dropped.")
			continue
		}
		RecordChars[Character] := true
		Added.Push(Map("key", "custom_" . Format("{:X}", Ord(Character)), "char", Character,
			"label", Character, "consume", TOML_Bool(InStr(Consumed, Character) ? 1 : 0)))
	}
	if Added.Length {
		Document := TOML_ParseDocument(Owner.Source)
		Stored := Document.Has("hotstrings") && Document["hotstrings"] is Map
			? Document["hotstrings"].Get("terminators", []) : []
		if !_HotstringsTerminatorRecordDenseArray(Stored) {
			LoggerError("HotstringsConfig", "Delimiter migration refused: the custom terminator list is not an array.")
			return 0
		}
		Next := ManifestCloneValue(Stored)
		for Record in Added
			Next.Push(Record)
		Updates.Push({ Section: "hotstrings", Key: "terminators", Value: Next })
	}
	if Updates.Length == 0
		return 1
	if !ConfigCommitUpdates(ConfigurationFile, Updates, "the word expander migration", WriterFn, NotifyFn)
		return 0
	try {
		Source := FSReadUtf8Exact(ConfigurationFile)
		Candidate := HotstringsTerminatorRecordsResolve(TOML_ParseDocument(Source))
		Candidate.Source := Source
	} catch as Err {
		LoggerError("HotstringsConfig", Format("The migrated delimiter source could not be re-read: {1}.", Err.Message))
		return 0
	}
	PreviousCritical := Critical("On")
	try {
		_HotstringsTerminatorRecords := Candidate
		Strings := HotstringsTerminatorStrings()
		HSE_WORD_TERMINATORS := Strings.Word
		HSE_CONSUMED_DELIMITERS := Strings.Consumed
	} finally Critical(PreviousCritical)
	LoggerInfo("HotstringsConfig", "Delimiter strings of the override file migrated to config.toml leaves.")
	return 1
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
