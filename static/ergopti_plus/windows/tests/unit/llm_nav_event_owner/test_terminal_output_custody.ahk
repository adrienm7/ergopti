; tests/unit/llm_nav_event_owner/test_terminal_output_custody.ahk

; ==============================================================================
; MODULE: Terminal Output Custody Adapter Tests
; DESCRIPTION:
; Authored literal UTF-16/native-edge protocol vectors exercise the guarded AHK
; owner through ports. AHK execution remains Windows-only and UNRUN from Linux;
; these boundaries do not qualify a hook, emitter, observer or physical input.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNTOC_WithState(Fn) {
	global _LLM_TerminalOutputRecords, _LLM_TerminalOutputCreating, _LLM_TerminalOutputUnknown
	global _LLM_NavEventOwnerTerminalRouteOwner
	Saved := [_LLM_TerminalOutputRecords, _LLM_TerminalOutputCreating, _LLM_TerminalOutputUnknown,
		_LLM_NavEventOwnerTerminalRouteOwner]
	try {
		_LLM_TerminalOutputRecords := Map(), _LLM_TerminalOutputCreating := false
		_LLM_TerminalOutputUnknown := 0
		_LNTR_WithState(Fn)
	} finally {
		; Teardown restores an injected-port fixture, never a real native debt owner.
		_LLM_TerminalOutputRecords := Saved[1], _LLM_TerminalOutputCreating := Saved[2]
		_LLM_TerminalOutputUnknown := Saved[3]
		_LLM_NavEventOwnerTerminalRouteOwner := Saved[4]
	}
}

_LNTOC_Peek(State, Token, Index, Receipt) {
	AssertEqual(901, Token), AssertEqual(0, Index)
	DllCall("Kernel32\RtlMoveMemory", "Ptr", Receipt, "Ptr", State.Receipt, "UPtr", 184)
	return 0
}

_LNTOC_Plan(State, Owner, Token, Sequence, Text, Length, Key) {
	global _LLM_NavEventOwnerTerminalRouteOwner
	State.Plans += 1
	AssertEqual(_LLM_NavEventOwnerTerminalRouteOwner, Owner)
	AssertEqual(901, Token), AssertEqual(3, Sequence), AssertEqual(24, Key.Size)
	AssertEqual(State.Text.Length, Length)
	Loop Length
		AssertEqual(State.Text[A_Index], NumGet(Text, (A_Index - 1) * 2, "UShort"))
	State.TextBuffer := Text
	if !(State.PlanStatus is Integer) || State.PlanStatus != 0
		return State.PlanStatus
	NumPut("UInt64", Token, "UInt64", Sequence, "UInt64", 7, Key, 0)
	State.KeyBuffer := Key
	if HasMethod(State.OnPlan, "Call")
		State.OnPlan.Call()
	if State.Throw == "plan"
		throw Error("Injected throw after native plan ownership.")
	if State.Mutation == "key_token"
		NumPut("UInt64", 902, Key, 0)
	else if State.Mutation == "key_sequence"
		NumPut("UInt64", 4, Key, 8)
	else if State.Mutation == "key_plan"
		NumPut("UInt64", 0, Key, 16)
	else if State.Mutation == "key_size"
		Key.Size := 8
	return 0
}

_LNTOC_CheckKey(Owner, Key) {
	global _LLM_NavEventOwnerTerminalRouteOwner
	AssertEqual(_LLM_NavEventOwnerTerminalRouteOwner, Owner), AssertEqual(24, Key.Size)
	AssertEqual(901, NumGet(Key, 0, "UInt64"))
	AssertEqual(3, NumGet(Key, 8, "UInt64")), AssertEqual(7, NumGet(Key, 16, "UInt64"))
}

_LNTOC_Begin(State, Owner, Key, Units, Capacity, Count, Attempt) {
	AssertFalse(State.Pending, "A consumer cannot replace an unacknowledged native attempt.")
	_LNTOC_CheckKey(Owner, Key), State.Begins += 1
	AssertEqual(2048, Capacity), AssertEqual(20480, Units.Size)
	AssertEqual(4, Count.Size), AssertEqual(8, Attempt.Size)
	if HasMethod(State.OnBegin, "Call")
		State.OnBegin.Call()
	if !(State.BeginStatus is Integer) || State.BeginStatus != 0
		return State.BeginStatus
	State.Attempt += 1, State.Pending := true
	Remaining := State.Units.Length - State.Accepted
	NumPut("UInt", Remaining, Count), NumPut("UInt64", State.Attempt, Attempt)
	Loop Remaining {
		Unit := State.Units[State.Accepted + A_Index]
		Offset := (A_Index - 1) * 10
		NumPut("UShort", Unit[1], "UShort", Unit[2], "UShort", Unit[3], Units, Offset)
		NumPut("UChar", Unit[4], "UChar", Unit[5], "UChar", Unit[6], "UChar", Unit[7], Units, Offset + 6)
	}
	if State.Mutation == "attempt_count"
		NumPut("UInt", Remaining + 1, Count)
	else if State.Mutation == "attempt_id"
		NumPut("UInt64", 0, Attempt)
	else if State.Mutation == "unit"
		NumPut("UShort", 0x7A, Units, 4)
	else if State.Mutation == "reserved"
		NumPut("UChar", 1, Units, 9)
	else if State.Mutation == "units_size"
		Units.Size := 1
	else if State.Mutation == "count_size"
		Count.Size := 1
	else if State.Mutation == "attempt_size"
		Attempt.Size := 1
	State.UnitsBuffer := Units
	if State.Throw == "begin"
		throw Error("Injected throw after native attempt ownership.")
	return 0
}

_LNTOC_Acknowledge(State, Owner, Key, Attempt, Accepted) {
	_LNTOC_CheckKey(Owner, Key), State.Acks.Push(Accepted)
	AssertEqual(State.Attempt, Attempt), AssertTrue(State.Pending)
	AssertTrue(Accepted >= 0 && Accepted <= State.Units.Length - State.Accepted)
	if !(State.AckStatus is Integer) || State.AckStatus != 0
		return State.AckStatus
	State.Accepted += Accepted, State.Pending := false
	if State.Throw == "acknowledge"
		throw Error("Injected throw after native prefix acceptance.")
	return 0
}

_LNTOC_Consume(State, Owner, Key) {
	_LNTOC_CheckKey(Owner, Key), State.Consumes += 1
	AssertFalse(State.Pending), AssertEqual(State.Units.Length, State.Accepted)
	if State.Throw == "consume"
		throw Error("Injected throw after native edge consumption.")
	return State.RetireStatus
}

_LNTOC_Cancel(State, Owner, Key) {
	_LNTOC_CheckKey(Owner, Key), State.Cancels += 1
	AssertFalse(State.Pending), AssertEqual(0, State.Accepted)
	if State.Throw == "cancel"
		throw Error("Injected throw after native plan cancellation.")
	return State.RetireStatus
}

_LNTOC_State(Text := unset, Units := unset) {
	Source := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(Source.Port))
	State := {Text: IsSet(Text) ? Text : [0x61],
		Units: IsSet(Units) ? Units : [[0, 0, 0x61, 1, 0, 0, 0], [0, 0, 0x61, 1, 1, 0, 0]],
		Receipt: _LNTR_Receipt(), PlanStatus: 0, BeginStatus: 0, AckStatus: 0, RetireStatus: 0,
		Plans: 0, Begins: 0, Acks: [], Consumes: 0, Cancels: 0,
		Accepted: 0, Pending: false, Attempt: 40, OnBegin: 0, OnPlan: 0, Throw: "", Mutation: ""}
	State.Port := Map("peek_terminal_route", _LNTOC_Peek.Bind(State),
		"plan_terminal_output", _LNTOC_Plan.Bind(State),
		"begin_terminal_output_attempt", _LNTOC_Begin.Bind(State),
		"acknowledge_terminal_output", _LNTOC_Acknowledge.Bind(State),
		"consume_terminal_output", _LNTOC_Consume.Bind(State),
		"cancel_terminal_output", _LNTOC_Cancel.Bind(State))
	return State
}

_LNTOC_ExactSuffixCase() {
	_LNTR_LoadFixture(Chr(0x1F600))
	State := _LNTOC_State([0xD83D, 0xDE00],
		[[0, 0, 0xD83D, 1, 0, 0, 0], [0, 0, 0xD83D, 1, 1, 0, 0],
		[0, 0, 0xDE00, 1, 0, 0, 0], [0, 0, 0xDE00, 1, 1, 0, 0]])
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	AssertFalse(Handle["delivery_enabled"]), AssertFalse(Handle["cohort_complete"])
	AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
	First := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	AssertEqual(4, First["unit_count"])
	AssertEqual(0xD83D, First["units"][1]["utf16"])
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, First, 1))
	AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, First, 1))
	Second := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	AssertEqual(3, Second["unit_count"]), AssertEqual(1, Second["units"][1]["key_up"])
	AssertEqual(0xD83D, Second["units"][1]["utf16"])
	AssertTrue(Second["attempt_id"] > First["attempt_id"])
	AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Second, 0))
	Third := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	AssertEqual(3, Third["unit_count"]), AssertEqual(0xDE00, Third["units"][3]["utf16"])
	AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Third, 3))
	AssertTrue(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
	AssertEqual(1, State.Consumes), AssertEqual(0, State.Cancels)
	AssertEqual(3, State.Acks.Length)
	AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Handle), "retired handles cannot delete another edge")
}

_LNTOC_ZeroUpCase() {
	State := _LNTOC_State([], [])
	NumPut("UChar", 1, State.Receipt, 141)
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	AssertEqual(0, Handle["unit_count"])
	AssertEqual(0, LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
	AssertTrue(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
	AssertEqual(0, State.Begins), AssertEqual(0, State.Acks.Length), AssertEqual(1, State.Consumes)
}

_LNTOC_NaturalModifierCase() {
	for Up in [0, 1]
		_LNTOC_WithState(_LNTOC_NaturalModifierVector.Bind(Up))
}

_LNTOC_NaturalModifierVector(Up) {
		State := _LNTOC_State([], [[0, 0x2A, 0, 2, Up, 0, 0]])
		State.Receipt := _LNTR_Receipt(9, 9)
		NumPut("UChar", Up ? 16 : 0, "UChar", Up ? 0 : 16, State.Receipt, 68)
		NumPut("UShort", 0xA0, "UShort", 0x2A, "UChar", 1, "UChar", Up, State.Receipt, 136)
		NumPut("UShort", 0x2A, State.Receipt, 172)
		NumPut("UShort", 0x2A, State.Receipt, 176)
		NumPut("UChar", 4, State.Receipt, 179), NumPut("UChar", 16, State.Receipt, 181)
		Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
		Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
		AssertEqual(1, Attempt["unit_count"]), AssertEqual(2, Attempt["units"][1]["kind"])
		AssertEqual(0x2A, Attempt["units"][1]["scan"]), AssertEqual(Up, Attempt["units"][1]["key_up"])
		AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 1))
		AssertTrue(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
}

_LNTOC_IdentityCase() {
	State := _LNTOC_State()
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	Handle["token"] := "901"
	AssertThrows(() => LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
	Handle["token"] := 901
	Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	for Name in ["owner", "token", "sequence", "plan_id", "attempt_id"] {
		Saved := Attempt[Name], Attempt[Name] := Saved + 1
		AssertThrows(() => LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 1))
		Attempt[Name] := Saved
	}
	for Prefix in [-1, 3, "1"]
		AssertThrows(LLM_NavEventOwner_AcknowledgeTerminalOutput.Bind(Handle, Attempt, Prefix))
	Attempt["units"][1]["utf16"] := 0x7A
	AssertThrows(() => LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 1))
	Attempt["units"][1]["utf16"] := 0x61
	Attempt["cohort_complete"] := "0"
	AssertThrows(() => LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 1))
	Attempt["cohort_complete"] := false
	AssertEqual(0, State.Acks.Length)
	AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 0))
	AssertTrue(LLM_NavEventOwner_CancelTerminalOutput(Handle))
}

_LNTOC_RetentionAndReentryCase() {
	global KLE_State
	State := _LNTOC_State()
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	_LNTR_LoadFixture("z"), KLE_State := "unrelated-live-state"
	NumPut("UShort", 0x7A, State.TextBuffer)
	State.OnBegin := () => AssertEqual(0, LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
	Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	NumPut("UShort", 0x7A, State.UnitsBuffer, 4)
	AssertEqual(0x61, Attempt["units"][1]["utf16"])
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 2))
	AssertTrue(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
	AssertEqual("unrelated-live-state", KLE_State), AssertEqual(1, State.Plans)
}

_LNTOC_RefusalAndCancellationCase() {
	State := _LNTOC_State()
	for Status in [2, 4, 5, 8] {
		State.PlanStatus := Status
		AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	}
	State.PlanStatus := 0
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	State.BeginStatus := 5
	AssertEqual(0, LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
	State.BeginStatus := 0
	Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	State.AckStatus := 2
	AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 1))
	Held := LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle)
	AssertEqual(0, Held["accepted"]), AssertTrue(Held["pending"])
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	State.AckStatus := 0
	AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 0))
	State.RetireStatus := 5
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertTrue(IsObject(LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle)))
	State.RetireStatus := 0
	AssertTrue(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertEqual(0, LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle))
	AssertEqual(0, State.Consumes)
}

_LNTOC_UnknownPlanVector(Mutation, Status) {
	global _LLM_TerminalOutputUnknown
	State := _LNTOC_State(), State.Mutation := Mutation, State.PlanStatus := Status
	AssertThrows(() => LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertTrue(IsObject(_LLM_TerminalOutputUnknown))
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertEqual(1, State.Plans)
}

_LNTOC_UnknownAttemptVector(Mutation, Status) {
	_LNTR_LoadFixture(Chr(0x1F600))
	State := _LNTOC_State([0xD83D, 0xDE00],
		[[0, 0, 0xD83D, 1, 0, 0, 0], [0, 0, 0xD83D, 1, 1, 0, 0],
		[0, 0, 0xDE00, 1, 0, 0, 0], [0, 0, 0xDE00, 1, 1, 0, 0]])
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	State.Mutation := Mutation, State.BeginStatus := Status
	AssertThrows(() => LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
	Held := LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle)
	AssertTrue(Held["unknown"])
	AssertTrue(Held["pending"]), AssertEqual(0, Held["accepted"])
	AssertEqual(4, Held["unit_count"])
	if Mutation == "units_size" || Mutation == "count_size" || Mutation == "attempt_size"
		AssertEqual(0, Held["attempt_id"])
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
	AssertEqual(0, LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
	AssertEqual(1, State.Begins), AssertEqual(0, State.Acks.Length)
}

_LNTOC_UnknownReceiptsCase() {
	for Mutation in ["key_token", "key_sequence", "key_plan", "key_size"]
		_LNTOC_WithState(_LNTOC_UnknownPlanVector.Bind(Mutation, 0))
	_LNTOC_WithState(() => _LNTOC_UnknownPlanVector("", "0"))
	_LNTOC_WithState(() => _LNTOC_UnknownPlanVector("", 77))
	for Mutation in ["attempt_count", "attempt_id", "unit", "reserved", "units_size", "count_size", "attempt_size"]
		_LNTOC_WithState(_LNTOC_UnknownAttemptVector.Bind(Mutation, 0))
	_LNTOC_WithState(() => _LNTOC_UnknownAttemptVector("", "0"))
	_LNTOC_WithState(() => _LNTOC_UnknownAttemptVector("", 77))
}

_LNTOC_UnknownAckCase() {
	State := _LNTOC_State()
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	State.AckStatus := "0"
	AssertThrows(() => LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 1))
	Held := LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle)
	AssertTrue(Held["unknown"]), AssertTrue(Held["pending"]), AssertEqual(0, Held["accepted"])
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
}

_LNTOC_ThrowVector(Operation) {
	global _LLM_TerminalOutputUnknown
	State := _LNTOC_State(), State.Throw := Operation
	if Operation == "plan" {
		AssertThrows(() => LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
		AssertTrue(IsObject(_LLM_TerminalOutputUnknown))
		AssertEqual(7, NumGet(_LLM_TerminalOutputUnknown["key"], 16, "UInt64"))
		NumPut("UInt64", 0, State.KeyBuffer, 16)
		AssertEqual(7, NumGet(_LLM_TerminalOutputUnknown["key"], 16, "UInt64"),
			"unknown ownership must copy the retiring native callback's receipt")
	} else {
		Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
		if Operation == "begin"
			AssertThrows(() => LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
		else if Operation == "cancel"
			AssertThrows(() => LLM_NavEventOwner_CancelTerminalOutput(Handle))
		else {
			Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
			if Operation == "acknowledge"
				AssertThrows(() => LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 1))
			else {
				AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 2))
				AssertThrows(() => LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
			}
		}
		Held := LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle)
		AssertTrue(Held["unknown"], "throw after possible effect must preserve uncertain custody")
		if Operation == "begin" || Operation == "acknowledge" {
			AssertTrue(Held["pending"]), AssertEqual(41, Held["attempt_id"])
			AssertEqual(0, Held["accepted"])
		}
		AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
		AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Handle))
		AssertEqual(0, LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle))
	}
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertEqual(1, State.Plans)
}

_LNTOC_ThrowAfterEffectCase() {
	for Operation in ["plan", "begin", "acknowledge", "consume", "cancel"]
		_LNTOC_WithState(_LNTOC_ThrowVector.Bind(Operation))
}

_LNTOC_RotateOwner(OriginalOwner, OriginalGeneration, Port) {
	global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteGeneration
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", Port),
		"recursive planning cannot duplicate the pending owner")
	_LLM_NavEventOwnerTerminalRouteOwner := OriginalOwner + 1
	_LLM_NavEventOwnerTerminalRouteGeneration := OriginalGeneration + 1
	_LNTR_LoadFixture("z")
}

_LNTOC_OwnerReentryCase() {
	global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_TerminalOutputUnknown, _LLM_TerminalOutputRecords
	State := _LNTOC_State()
	Owner := _LLM_NavEventOwnerTerminalRouteOwner
	Generation := _LLM_NavEventOwnerTerminalRouteGeneration
	State.OnPlan := _LNTOC_RotateOwner.Bind(Owner, Generation, State.Port)
	AssertThrows(() => LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertEqual(Owner, _LLM_TerminalOutputUnknown["owner"],
		"post-ACK custody must retain the owner which actually acquired the native plan")
	AssertEqual(3, _LLM_TerminalOutputUnknown["sequence"])
	AssertEqual(7, NumGet(_LLM_TerminalOutputUnknown["key"], 16, "UInt64"))
	AssertEqual(0, _LLM_TerminalOutputRecords.Count)
	AssertEqual(1, State.Plans), AssertEqual(0, State.Begins)
}

_LNTOC_CrossAxisVector(Axis, Code, Effective, RecipeId) {
	global _LLM_NavEventOwnerTerminalRouteRecipes
	State := _LNTOC_State([], [])
	State.Receipt := _LNTR_Receipt(RecipeId, RecipeId)
	Admission := _LLM_NavEventOwnerTerminalRouteRecipes[RecipeId]
	Route := Admission["route"]
	Route["axis"] := Axis, Route["code"] := Code, Route["effective_modifiers_lr"] := Effective
	Route["target_vk"] := Axis == 1 ? Code : 0, Route["target_scan"] := Axis == 2 ? Code : 0
	NumPut("UShort", Axis == 1 ? Code : 0xA0, "UShort", Axis == 2 ? Code : 0x38, State.Receipt, 136)
	NumPut("UShort", Code, "UShort", Route["target_vk"], "UShort", Route["target_scan"], State.Receipt, 172)
	NumPut("UChar", Axis, "UChar", 4, "UChar", 0, "UChar", Effective, State.Receipt, 178)
	AssertThrows(() => LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port),
		"a natural code from another axis cannot authenticate this modifier")
	AssertEqual(0, State.Plans)
}

_LNTOC_CrossAxisCase() {
	_LNTOC_WithState(() => _LNTOC_CrossAxisVector(1, 0x38, 4, 5))
	_LNTOC_WithState(() => _LNTOC_CrossAxisVector(2, 0xA0, 16, 9))
}

_LNTOC_UnsupportedEventCase() {
	State := _LNTOC_State()
	for Origin in [3, 4] {
		NumPut("UChar", Origin, State.Receipt, 140)
		AssertThrows(() => LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	}
	NumPut("UChar", 1, State.Receipt, 140), NumPut("UInt64", 0, State.Receipt, 128)
	AssertThrows(() => LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	NumPut("UInt64", 1, State.Receipt, 128), NumPut("UInt64", 0, State.Receipt, 24)
	AssertThrows(() => LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertEqual(0, State.Plans)
}

Test("terminal output custody: exact surrogate prefix and zero retry settle once (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_ExactSuffixCase))
Test("terminal output custody: character UP consumes zero output units (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_ZeroUpCase))
Test("terminal output custody: natural modifier DOWN and UP retain exact edges (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_NaturalModifierCase))
Test("terminal output custody: identities, counts and immutable units are strict (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_IdentityCase))
Test("terminal output custody: reentry and retired caller buffers preserve canonical data (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_RetentionAndReentryCase))
Test("terminal output custody: known refusal retains debt and unsent cancellation (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_RefusalAndCancellationCase))
Test("terminal output custody: malformed success receipts retain unknown custody (todo49-output-custody-adapter)",
	_LNTOC_UnknownReceiptsCase)
Test("terminal output custody: unknown acknowledgement never clears pending debt (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_UnknownAckCase))

Test("terminal output custody: every throw after native effect retains unknown ownership (todo49-output-custody-adapter)",
	_LNTOC_ThrowAfterEffectCase)
Test("terminal output custody: owner reentry cannot mint a replacement handle (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_OwnerReentryCase))
Test("terminal output custody: natural modifiers cannot borrow another axis (todo49-output-custody-adapter)",
	_LNTOC_CrossAxisCase)
Test("terminal output custody: foreign origins and uninitialized receipts are fenced (todo49-output-custody-adapter)",
	(*) => _LNTOC_WithState(_LNTOC_UnsupportedEventCase))

/** Executes the consumer, rather than reconstructing its protocol in the test. */
_LNTOC_ConsumerCase(TestCase) {
	Calls := 0
	if TestCase == "surrogate" {
		_LNTR_LoadFixture(Chr(0x1F600))
		State := _LNTOC_State([0xD83D, 0xDE00],
			[[0, 0, 0xD83D, 1, 0, 0, 0], [0, 0, 0xD83D, 1, 1, 0, 0],
			[0, 0, 0xDE00, 1, 0, 0, 0], [0, 0, 0xDE00, 1, 1, 0, 0]])
	} else if TestCase == "zero-up" {
		State := _LNTOC_State([], [])
		NumPut("UChar", 1, State.Receipt, 141)
	} else
		State := _LNTOC_State()
	if TestCase == "admission-refusal"
		State.PlanStatus := 4
	Consumer := TerminalOutputConsumer(901, "none", State.Port, Emit)
	Emit(Attempt) {
		Calls += 1
		AssertFalse(Consumer.Service(), "Emitter reentry cannot begin another attempt.")
		AssertFalse(Consumer.Cancel(), "An in-flight emission cannot release its raw edge.")
		if TestCase == "surrogate" {
			AssertEqual(Calls == 1 ? 4 : 3, Attempt["unit_count"])
			AssertEqual(0xD83D, Attempt["units"][1]["utf16"])
			AssertEqual(Calls == 1 ? 0 : 1, Attempt["units"][1]["key_up"], "A stranded UP must precede the remaining suffix.")
			return Calls == 1 ? 1 : Calls == 2 ? 0 : 3
		}
		if TestCase == "invalid-receipt"
			return 0.5
		if TestCase == "oversized-receipt"
			return Attempt["unit_count"] + 1
		if TestCase == "emit-throw"
			throw Error("Injected uncertain emission.")
		return Attempt["unit_count"]
	}
	if TestCase == "cancel-unsent" {
		AssertTrue(Consumer.Cancel())
		AssertFalse(Consumer.Service())
		AssertEqual(1, State.Cancels), AssertEqual(0, Calls), AssertEqual(0, State.Consumes)
		return
	}
	if TestCase == "ack-refusal"
		State.AckStatus := 4
	if TestCase == "ack-throw"
		State.Throw := "acknowledge"
	if TestCase == "invalid-receipt" || TestCase == "oversized-receipt" || TestCase == "emit-throw" || TestCase == "ack-throw" {
		AssertThrows(() => Consumer.Service())
		AssertTrue(Consumer.Blocked)
		AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertEqual(1, Calls), AssertEqual(0, State.Consumes), AssertEqual(0, State.Cancels)
		AssertEqual(TestCase == "ack-throw" ? 1 : 0, State.Acks.Length)
		return
	}
	if TestCase == "surrogate" {
		AssertFalse(Consumer.Service())
		AssertFalse(Consumer.Cancel(), "Accepted output cannot release raw capture for replay.")
		AssertFalse(Consumer.Service())
		AssertEqual(2, Calls, "Zero acceptance returns without spinning.")
		AssertEqual(0, State.Consumes)
		AssertTrue(Consumer.Service())
		AssertEqual(3, Calls)
	} else if TestCase == "ack-refusal" {
		AssertFalse(Consumer.Service())
		AssertEqual(1, Calls)
		AssertFalse(Consumer.Cancel())
		State.AckStatus := 0
		AssertTrue(Consumer.Service(), "The retained acceptance receipt may be acknowledged without re-emission.")
		AssertEqual(1, Calls), AssertEqual(1, State.Begins), AssertEqual(2, State.Acks.Length)
	} else if TestCase == "admission-refusal" {
		AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertEqual(0, Calls), AssertEqual(0, State.Begins), AssertEqual(0, State.Consumes)
		return
	} else {
		AssertTrue(Consumer.Service())
		AssertEqual(0, Calls), AssertEqual(0, State.Begins), AssertEqual(0, State.Acks.Length)
	}
	AssertEqual(1, State.Consumes), AssertEqual(0, State.Cancels)
	AssertFalse(Consumer.Service(), "A retired consumer cannot remove a replacement FIFO head.")
}

for _LNTOC_ConsumerName in ["surrogate", "zero-up", "cancel-unsent", "admission-refusal", "ack-refusal",
	"ack-throw", "invalid-receipt", "oversized-receipt", "emit-throw"]
	Test("terminal output consumer: " . _LNTOC_ConsumerName . " (todo49-output-consumer)",
		_LNTOC_WithState.Bind(_LNTOC_ConsumerCase.Bind(_LNTOC_ConsumerName)))
