; adapters/terminal_output_custody.ahk

; ==============================================================================
; MODULE: Terminal Output Custody Adapter
; DESCRIPTION:
; Owns canonical neutral recipes and strict native plan/attempt receipts without
; selecting or invoking an emitter. Production admission remains refused by the
; native owner. Unknown receipts retain custody instead of authorizing replacement.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LLM_TerminalOutputRecords := Map()
global _LLM_TerminalOutputCreating := false
global _LLM_TerminalOutputUnknown := 0

/** Services one retained FIFO head with at most one exact emission per call. */
class TerminalOutputConsumer {
	__New(Token, State, Port := 0, Emitter := 0) {
		if IsObject(Emitter) && !(Port is Map)
			throw ValueError("An injected output emitter requires an explicit protocol test port.")
		this.Handle := LLM_NavEventOwner_PlanTerminalOutput(Token, State, Port)
		this.Emitter := Emitter
		this.Attempt := 0
		this.Accepted := 0
		this.Busy := false
		this.Blocked := false
		this.Retired := false
	}

	/** Refusal or uncertain delivery retains ownership; no unsent suffix is guessed. */
	Service() {
		if this.Busy || this.Blocked || this.Retired || !(this.Handle is Map)
			return false
		this.Busy := true
		try {
			Status := LLM_NavEventOwner_TerminalOutputCustodyStatus(this.Handle)
			if !(Status is Map) || Status["unknown"] {
				this.Blocked := true
				return false
			}
			if Status["accepted"] == Status["unit_count"] && !Status["pending"] {
				this.Retired := LLM_NavEventOwner_ConsumeTerminalOutput(this.Handle)
				return this.Retired
			}
			if !IsObject(this.Attempt) {
				; Production cannot choose a backend before the complete cohort is admitted.
				if !HasMethod(this.Emitter, "Call")
					return false
				this.Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(this.Handle)
				if !(this.Attempt is Map)
					return false
				try this.Accepted := this.Emitter.Call(this.Attempt)
				catch as Err {
					this.Blocked := true
					throw Err
				}
				if !(this.Accepted is Integer) || this.Accepted < 0 || this.Accepted > this.Attempt["unit_count"] {
					this.Blocked := true
					throw ValueError("The emitter did not return an exact accepted prefix.")
				}
			}
			if !LLM_NavEventOwner_AcknowledgeTerminalOutput(this.Handle, this.Attempt, this.Accepted)
				return false
			this.Attempt := 0
			Status := LLM_NavEventOwner_TerminalOutputCustodyStatus(this.Handle)
			if Status["accepted"] == Status["unit_count"] {
				this.Retired := LLM_NavEventOwner_ConsumeTerminalOutput(this.Handle)
				return this.Retired
			}
			return false
		} catch as Err {
			Status := LLM_NavEventOwner_TerminalOutputCustodyStatus(this.Handle)
			if Status is Map && Status["unknown"]
				this.Blocked := true
			throw Err
		} finally {
			this.Busy := false
		}
	}

	/** Accepted or uncertain output can never release the raw edge for replay. */
	Cancel() {
		if this.Busy || this.Blocked || this.Retired || !(this.Handle is Map) || IsObject(this.Attempt)
			return false
		this.Retired := LLM_NavEventOwner_CancelTerminalOutput(this.Handle)
		return this.Retired
	}
}

/** Resolves and retains the exact native FIFO head; native refusal returns zero. */
LLM_NavEventOwner_PlanTerminalOutput(Token, State, Port := 0) {
	global _LLM_TerminalOutputRecords, _LLM_TerminalOutputCreating
	global _LLM_TerminalOutputUnknown, _LLM_NavEventOwnerTerminalRouteOwner
	global _LLM_NavEventOwnerTerminalRouteGeneration, _LLM_NavEventOwnerTerminalRouteRecipes
	if _LLM_TerminalOutputCreating || _LLM_TerminalOutputRecords.Count
			|| IsObject(_LLM_TerminalOutputUnknown)
		return 0
	_LLM_TerminalOutputCreating := true
	Owner := _LLM_NavEventOwnerTerminalRouteOwner
	Generation := _LLM_NavEventOwnerTerminalRouteGeneration
	Recipes := _LLM_NavEventOwnerTerminalRouteRecipes
	try {
		Snapshot := LLM_NavEventOwner_PeekTerminalRoute(Token, 0, Port)
		if !(Snapshot is Map)
			return 0
		Canonical := _LLM_TerminalOutputCanonical(Snapshot, State, Owner, Recipes)
		if _LLM_NavEventOwnerTerminalRouteOwner != Owner
				|| _LLM_NavEventOwnerTerminalRouteGeneration != Generation
			throw ValueError("The terminal route owner changed before planning.")
		Output := Canonical["text"]
		Length := StrLen(Output)
		Text := Buffer((Length + 1) * 2, 0)
		StrPut(Output, Text, "UTF-16")
		Key := Buffer(24, 0)
		Fn := _LLM_NavEventOwnerPortFn("plan_terminal_output", Port)
		try Status := HasMethod(Fn, "Call")
			? Fn.Call(Owner, Token,
				Snapshot["sequence"], Text, Length, Key)
			: _LLM_TerminalOutputNativePlan(Owner,
				Token, Snapshot["sequence"], Text, Length, Key)
		catch as Err {
			_LLM_TerminalOutputUnknown := _LLM_TerminalOutputUnknownKey(
				Owner, Token, Snapshot["sequence"], Key)
			throw Err
		}
		if !(Status is Integer) || !_LLM_TerminalOutputKnownStatus(Status) {
			_LLM_TerminalOutputUnknown := _LLM_TerminalOutputUnknownKey(
				Owner, Token, Snapshot["sequence"], Key)
			throw Error("Terminal output planning returned an unknown ACK.")
		}
		if !_LLM_TerminalOutputStatus(Status)
			return 0
		if Key.Size != 24 {
			_LLM_TerminalOutputUnknown := _LLM_TerminalOutputUnknownKey(
				Owner, Token, Snapshot["sequence"], Key)
			throw ValueError("The native terminal key changed its ABI size.")
		}
		PlanId := NumGet(Key, 16, "UInt64")
		if _LLM_NavEventOwnerTerminalRouteOwner != Owner
				|| _LLM_NavEventOwnerTerminalRouteGeneration != Generation
				|| NumGet(Key, 0, "UInt64") != Token
				|| NumGet(Key, 8, "UInt64") != Snapshot["sequence"] || PlanId <= 0 {
			_LLM_TerminalOutputUnknown := _LLM_TerminalOutputUnknownKey(
				Owner, Token, Snapshot["sequence"], Key)
			throw ValueError("Terminal output planning returned an invalid owned key.")
		}
		Handle := Map("owner", Owner, "token", Token,
			"sequence", Snapshot["sequence"], "plan_id", PlanId,
			"unit_count", Canonical["count"], "delivery_enabled", false,
			"cohort_complete", false)
		_LLM_TerminalOutputRecords[ObjPtr(Handle)] := Map("handle", Handle,
			"owner", Owner, "token", Token,
			"sequence", Snapshot["sequence"], "plan_id", PlanId,
			"unit_count", Canonical["count"], "canonical", Canonical["units"], "port", Port,
			"accepted", 0, "pending", false, "attempt_id", 0, "attempt_count", 0,
			"busy", false, "unknown", false)
		return Handle
	} finally {
		_LLM_TerminalOutputCreating := false
	}
}

/** Exposes only the exact immutable unsent suffix and retains its attempt. */
LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle) {
	Record := _LLM_TerminalOutputRecord(Handle)
	if !IsObject(Record) || Record["busy"] || Record["pending"] || Record["unknown"]
			|| Record["accepted"] == Record["unit_count"]
		return 0
	Record["busy"] := true
	try {
		Key := _LLM_TerminalOutputKey(Record)
		Units := Buffer(20480, 0), Count := Buffer(4, 0), Attempt := Buffer(8, 0)
		Fn := _LLM_NavEventOwnerPortFn("begin_terminal_output_attempt", Record["port"])
		try Status := HasMethod(Fn, "Call")
			? Fn.Call(Record["owner"], Key, Units, 2048, Count, Attempt)
			: _LLM_TerminalOutputNativeBegin(Record["owner"], Key, Units, Count, Attempt)
		catch as Err {
			Record["unknown"] := true, Record["pending"] := true
			Record["attempt_id"] := Attempt.Size >= 8 ? NumGet(Attempt, 0, "UInt64") : 0
			Record["attempt_count"] := Record["unit_count"] - Record["accepted"]
			throw Err
		}
		if !(Status is Integer) || !_LLM_TerminalOutputKnownStatus(Status) {
			Record["unknown"] := true
			Record["pending"] := true, Record["attempt_id"] := Attempt.Size >= 8 ? NumGet(Attempt, 0, "UInt64") : 0
			Record["attempt_count"] := Record["unit_count"] - Record["accepted"]
			throw Error("Terminal output attempt returned an unknown ACK.")
		}
		if !_LLM_TerminalOutputStatus(Status)
			return 0
		Record["pending"] := true
		Record["attempt_id"] := 0
		Record["attempt_count"] := Record["unit_count"] - Record["accepted"]
		try {
			if Units.Size != 20480 || Count.Size != 4 || Attempt.Size != 8
				throw ValueError("The output attempt buffers violate their exact ABI bounds.")
			Record["attempt_id"] := NumGet(Attempt, 0, "UInt64")
			if Record["attempt_id"] <= 0 || NumGet(Count, 0, "UInt") != Record["attempt_count"]
				throw ValueError("The output attempt identity or suffix count is invalid.")
			Decoded := _LLM_TerminalOutputDecodeUnits(Units, Record,
				Record["accepted"], Record["attempt_count"])
		} catch as Err {
			Record["unknown"] := true
			throw Err
		}
		return Map("owner", Record["owner"], "token", Record["token"],
			"sequence", Record["sequence"], "plan_id", Record["plan_id"],
			"attempt_id", Record["attempt_id"], "unit_count", Record["attempt_count"],
			"units", Decoded, "delivery_enabled", false, "cohort_complete", false)
	} finally {
		Record["busy"] := false
	}
}

/** Reports caller-observed acceptance; this function never emits any unit. */
LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, Accepted) {
	Record := _LLM_TerminalOutputRecord(Handle)
	if !IsObject(Record) || Record["busy"] || Record["unknown"] || !Record["pending"]
		return false
	_LLM_TerminalOutputValidateAttempt(Record, Attempt)
	if !(Accepted is Integer) || Accepted < 0 || Accepted > Record["attempt_count"]
		throw ValueError("An exact output acceptance prefix is required.")
	Record["busy"] := true
	try {
		Key := _LLM_TerminalOutputKey(Record)
		Fn := _LLM_NavEventOwnerPortFn("acknowledge_terminal_output", Record["port"])
		try Status := HasMethod(Fn, "Call")
			? Fn.Call(Record["owner"], Key, Record["attempt_id"], Accepted)
			: _LLM_TerminalOutputNativeAcknowledge(Record["owner"], Key,
				Record["attempt_id"], Accepted)
		catch as Err {
			Record["unknown"] := true
			throw Err
		}
		if !(Status is Integer) || !_LLM_TerminalOutputKnownStatus(Status) {
			Record["unknown"] := true
			throw Error("Terminal output acknowledgement returned an unknown ACK.")
		}
		if !_LLM_TerminalOutputStatus(Status)
			return false
		Record["accepted"] += Accepted
		Record["pending"] := false
		return true
	} finally {
		Record["busy"] := false
	}
}

/** Settles exactly one original FIFO edge only after complete output acceptance. */
LLM_NavEventOwner_ConsumeTerminalOutput(Handle) {
	Record := _LLM_TerminalOutputRecord(Handle)
	if !IsObject(Record) || Record["busy"] || Record["unknown"] || Record["pending"]
			|| Record["accepted"] != Record["unit_count"]
		return false
	return _LLM_TerminalOutputRetire(Record, "consume_terminal_output")
}

/** Relinquishes only an unsent plan; outstanding/accepted output retains custody. */
LLM_NavEventOwner_CancelTerminalOutput(Handle) {
	Record := _LLM_TerminalOutputRecord(Handle)
	if !IsObject(Record) || Record["busy"] || Record["unknown"]
			|| Record["pending"] || Record["accepted"] != 0
		return false
	return _LLM_TerminalOutputRetire(Record, "cancel_terminal_output")
}

/** Reports held custody without granting delivery or guessing unknown outcomes. */
LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle) {
	Record := _LLM_TerminalOutputRecord(Handle)
	if !IsObject(Record)
		return 0
	return Map("accepted", Record["accepted"], "pending", Record["pending"],
		"attempt_id", Record["attempt_id"], "unknown", Record["unknown"],
		"unit_count", Record["unit_count"], "delivery_enabled", false, "cohort_complete", false)
}

/** Copies even an unknown native key before borrowed callback storage retires. */
_LLM_TerminalOutputUnknownKey(Owner, Token, Sequence, Key) {
	Owned := Buffer(24, 0)
	if Key.Size
		DllCall("Kernel32\RtlMoveMemory", "Ptr", Owned, "Ptr", Key, "UPtr", Min(Key.Size, 24))
	return Map("owner", Owner, "token", Token, "sequence", Sequence, "key", Owned, "key_size", Key.Size)
}

_LLM_TerminalOutputKnownStatus(Status) {
	return Status == 0 || Status == 1 || Status == 2 || Status == 4
		|| Status == 5 || Status == 6 || Status == 8
}

_LLM_TerminalOutputStatus(Status) {
	if Status == 2 || Status == 4 || Status == 5 || Status == 8
		return false
	_LLM_NavEventOwnerNativeRequireOk(Status, "Terminal output custody")
	return true
}

_LLM_TerminalOutputRecord(Handle) {
	global _LLM_TerminalOutputRecords
	if !(Handle is Map) || !_LLM_TerminalOutputRecords.Has(ObjPtr(Handle))
		return 0
	Record := _LLM_TerminalOutputRecords[ObjPtr(Handle)]
	for Name in ["owner", "token", "sequence", "plan_id", "unit_count"]
		if !Handle.Has(Name) || !(Handle[Name] is Integer) || Handle[Name] != Record[Name]
			throw ValueError("The terminal custody handle changed its owned identity.")
	if !(Handle.Get("delivery_enabled", 1) is Integer)
			|| !(Handle.Get("cohort_complete", 1) is Integer)
			|| Handle["delivery_enabled"] != 0 || Handle["cohort_complete"] != 0
		throw ValueError("The terminal custody handle cannot authorize delivery.")
	return Record
}

_LLM_TerminalOutputKey(Record) {
	Key := Buffer(24, 0)
	NumPut("UInt64", Record["token"], "UInt64", Record["sequence"],
		"UInt64", Record["plan_id"], Key, 0)
	return Key
}

_LLM_TerminalOutputDecodeUnits(Units, Record, OffsetUnits, Count) {
	Decoded := []
	Loop Count {
		Offset := (A_Index - 1) * 10
		Expected := (OffsetUnits + A_Index - 1) * 10
		Loop 10
			if NumGet(Units, Offset + A_Index - 1, "UChar")
					!= NumGet(Record["canonical"], Expected + A_Index - 1, "UChar")
				throw ValueError("The native output suffix differs from its canonical receipt.")
		Decoded.Push(Map("vk", NumGet(Units, Offset, "UShort"),
			"scan", NumGet(Units, Offset + 2, "UShort"),
			"utf16", NumGet(Units, Offset + 4, "UShort"),
			"kind", NumGet(Units, Offset + 6, "UChar"),
			"key_up", NumGet(Units, Offset + 7, "UChar"),
			"repeat", NumGet(Units, Offset + 8, "UChar"), "reserved", 0))
	}
	return Decoded
}

_LLM_TerminalOutputValidateAttempt(Record, Attempt) {
	if !(Attempt is Map) || !(Attempt.Get("units", 0) is Array)
		throw ValueError("An owned output attempt receipt is required.")
	for Name in ["owner", "token", "sequence", "plan_id", "attempt_id"]
		if !Attempt.Has(Name) || !(Attempt[Name] is Integer) || Attempt[Name] != Record[Name]
			throw ValueError("The output attempt changed its immutable identity.")
	if !(Attempt.Get("unit_count", -1) is Integer)
			|| Attempt["unit_count"] != Record["attempt_count"]
			|| Attempt["units"].Length != Record["attempt_count"]
			|| !(Attempt.Get("delivery_enabled", 1) is Integer)
			|| !(Attempt.Get("cohort_complete", 1) is Integer)
			|| Attempt["delivery_enabled"] != 0 || Attempt["cohort_complete"] != 0
		throw ValueError("The output attempt has an invalid suffix or delivery guard.")
	Names := ["vk", "scan", "utf16", "kind", "key_up", "repeat", "reserved"]
	Offsets := [0, 2, 4, 6, 7, 8, 9]
	Types := ["UShort", "UShort", "UShort", "UChar", "UChar", "UChar", "UChar"]
	for Index, Unit in Attempt["units"] {
		if !(Unit is Map)
			throw ValueError("The output attempt contains an invalid unit.")
		Base := (Record["accepted"] + Index - 1) * 10
		for FieldIndex, Name in Names
			if !Unit.Has(Name) || !(Unit[Name] is Integer)
					|| Unit[Name] != NumGet(Record["canonical"], Base + Offsets[FieldIndex], Types[FieldIndex])
				throw ValueError("The caller changed an immutable output unit.")
	}
}

_LLM_TerminalOutputRetire(Record, Operation) {
	global _LLM_TerminalOutputRecords
	Record["busy"] := true
	try {
		Key := _LLM_TerminalOutputKey(Record)
		Fn := _LLM_NavEventOwnerPortFn(Operation, Record["port"])
		try Status := HasMethod(Fn, "Call") ? Fn.Call(Record["owner"], Key)
			: _LLM_TerminalOutputNativeRetire(Record["owner"], Key, Operation)
		catch as Err {
			Record["unknown"] := true
			throw Err
		}
		if !(Status is Integer) || !_LLM_TerminalOutputKnownStatus(Status) {
			Record["unknown"] := true
			throw Error("Terminal output retirement returned an unknown ACK.")
		}
		if !_LLM_TerminalOutputStatus(Status)
			return false
		_LLM_TerminalOutputRecords.Delete(ObjPtr(Record["handle"]))
		return true
	} finally {
		Record["busy"] := false
	}
}

/** Resolves neutral DOWN, zero-unit UP or an owned natural modifier edge. */
_LLM_TerminalOutputCanonical(Snapshot, State, Owner, Recipes) {
	global KEYLAYOUT_NEUTRAL_STATE
	if !(State is String) || State != KEYLAYOUT_NEUTRAL_STATE
			|| Snapshot.Get("owner", 0) != Owner
			|| Snapshot.Get("status", -1) != 0 || !(Snapshot.Get("route", 0) is Map)
			|| !(Snapshot.Get("event", 0) is Map)
			|| Snapshot.Get("prefixes_before", -1) != 0 || Snapshot.Get("prefixes_after", -1) != 0
			|| Snapshot["composition_before"].Get("dead_key_id", -1) != 0
			|| Snapshot["composition_after"].Get("dead_key_id", -1) != 0
		throw ValueError("Terminal output is outside the owned neutral subset.")
	for Name in ["owner", "observed_generation", "observed_layout_id", "route_generation", "route_layout_id"]
		if !Snapshot.Has(Name) || !(Snapshot[Name] is Integer) || Snapshot[Name] <= 0
			throw ValueError("The terminal output registration identity is malformed.")
	if Snapshot["route_generation"] > Snapshot["observed_generation"]
		throw ValueError("The terminal output recipe precedes no observed registration.")
	Route := Snapshot["route"], Event := Snapshot["event"]
	_LLM_NavEventOwnerTerminalRouteValidate(Route)
	for Name in ["origin", "source_id", "key_up", "repeat", "vk", "scan"]
		if !Event.Has(Name) || !(Event[Name] is Integer)
			throw ValueError("The terminal output event ABI is malformed.")
	if Event["origin"] < 1 || Event["origin"] > 2 || Event["source_id"] <= 0
			|| Event["key_up"] < 0 || Event["key_up"] > 1 || Event["repeat"] < 0 || Event["repeat"] > 1
			|| (Event["key_up"] && Event["repeat"])
		throw ValueError("The terminal output event is outside its owned provenance.")
	if !Recipes.Has(Route["recipe_id"])
		throw ValueError("The terminal output recipe is no longer retained.")
	Admission := Recipes[Route["recipe_id"]]
	if Admission["generation"] != Snapshot["route_generation"]
			|| Admission["layout_id"] != Snapshot["route_layout_id"]
			|| (Route["axis"] == 2 && Event["scan"] != Route["code"])
			|| (Route["axis"] == 1 && Event["vk"] != Route["code"])
		throw ValueError("Terminal output changed its captured registration identity.")
	for Name, Value in Admission["route"]
		if Route[Name] != Value
			throw ValueError("Terminal output changed its captured descriptor.")
	if Route["required_prefixes"] || Route["prefix_bit"]
			|| Route["required_dead_key_id"] || Route["next_dead_key_id"]
		throw ValueError("A composing terminal route cannot authorize neutral output.")
	if Route["kind"] == 1 || Route["kind"] == 2 {
		if !(Admission["recipe"] is Map)
			throw ValueError("The canonical KLE model is no longer owned.")
		LR := Snapshot["modifiers_lr_before"]
		Modifiers := ((LR & 3) ? 1 : 0) | ((LR & 12) ? 2 : 0)
			| ((LR & 48) ? 4 : 0) | ((LR & 192) ? 8 : 0)
		if Route["effective_modifiers_lr"] != 0 || LR != Snapshot["modifiers_lr_after"]
				|| (!Event["key_up"] && Route["required_modifiers"] != Modifiers)
			throw ValueError("The terminal character changed its effective modifiers.")
		Step := Event["key_up"] ? Map("Output", "", "Next", State)
			: KeylayoutEmulation_StepReplayRoute(Admission["recipe"], State)
		if Step["Next"] != KEYLAYOUT_NEUTRAL_STATE
			throw ValueError("The owned terminal character unexpectedly entered composition.")
		Output := Step["Output"]
		if !(Output is String) || StrLen(Output) > 1024
			throw ValueError("The canonical terminal output exceeds its ABI bound.")
		Count := StrLen(Output) * 2, Units := Buffer(Count * 10, 0)
		Text := Buffer((StrLen(Output) + 1) * 2, 0), StrPut(Output, Text, "UTF-16")
		Loop StrLen(Output) {
			Code := NumGet(Text, (A_Index - 1) * 2, "UShort"), Offset := (A_Index - 1) * 20
			NumPut("UShort", Code, Units, Offset + 4), NumPut("UChar", 1, Units, Offset + 6)
			NumPut("UShort", Code, Units, Offset + 14), NumPut("UChar", 1, "UChar", 1, Units, Offset + 16)
		}
		return Map("text", Output, "count", Count, "units", Units)
	}
	Natural := Route["axis"] == 2
		? Map(0x01D, 1, 0x11D, 2, 0x038, 4, 0x138, 8,
			0x02A, 16, 0x036, 32, 0x15B, 64, 0x15C, 128)
		: Map(0xA2, 1, 0xA3, 2, 0xA4, 4, 0xA5, 8,
			0xA0, 16, 0xA1, 32, 0x5B, 64, 0x5C, 128)
	if Route["kind"] != 4 || !Natural.Has(Route["code"])
			|| Route["effective_modifiers_lr"] != Natural[Route["code"]]
			|| (Route["axis"] == 2 && (Route["target_scan"] != Route["code"] || Route["target_vk"]))
			|| (Route["axis"] == 1 && (Route["target_vk"] != Route["code"] || Route["target_scan"]))
		throw ValueError("The terminal output modifier is outside its natural subset.")
	Units := Buffer(10, 0)
	NumPut("UShort", Route["target_vk"], "UShort", Route["target_scan"], Units, 0)
	NumPut("UChar", 2, "UChar", Event["key_up"], "UChar", Event["repeat"], Units, 6)
	return Map("text", "", "count", 1, "units", Units)
}

_LLM_TerminalOutputNativePlan(Owner, Token, Sequence, Text, Length, Key) {
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_PlanTerminalOutput"),
		"UInt64", Owner, "UInt64", Token, "UInt64", Sequence,
		"Ptr", Text, "UInt", Length, "Ptr", Key, "Int")
}

_LLM_TerminalOutputNativeBegin(Owner, Key, Units, Count, Attempt) {
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_BeginTerminalOutputAttempt"),
		"UInt64", Owner, "Ptr", Key, "Ptr", Units, "UInt", 2048,
		"Ptr", Count, "Ptr", Attempt, "Int")
}

_LLM_TerminalOutputNativeAcknowledge(Owner, Key, Attempt, Accepted) {
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_AcknowledgeTerminalOutput"),
		"UInt64", Owner, "Ptr", Key, "UInt64", Attempt, "UInt", Accepted, "Int")
}

_LLM_TerminalOutputNativeRetire(Owner, Key, Operation) {
	Export := Operation == "consume_terminal_output"
		? "ErgoptiNav_ConsumeTerminalOutput" : "ErgoptiNav_CancelTerminalOutput"
	return DllCall(_LLM_NavEventOwnerNativeExport(Export), "UInt64", Owner, "Ptr", Key, "Int")
}
