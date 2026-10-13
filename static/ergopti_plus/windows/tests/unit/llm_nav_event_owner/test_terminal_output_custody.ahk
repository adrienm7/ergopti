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
		if TestCase == "unit-mutation"
			Attempt["units"][1]["utf16"] := 0x7A
		if TestCase == "handle-mutation"
			Consumer.Handle["plan_id"] += 1
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
	if TestCase == "invalid-receipt" || TestCase == "oversized-receipt" || TestCase == "emit-throw" || TestCase == "ack-throw"
		|| TestCase == "unit-mutation" || TestCase == "handle-mutation" {
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
	"ack-throw", "invalid-receipt", "oversized-receipt", "emit-throw", "unit-mutation", "handle-mutation"]
	Test("terminal output consumer: " . _LNTOC_ConsumerName . " (todo49-output-consumer)",
		_LNTOC_WithState.Bind(_LNTOC_ConsumerCase.Bind(_LNTOC_ConsumerName)))


/** A zero-output natural edge still owns one exact FIFO retirement receipt. */
_LNTOC_SharedNaturalState(Family, Axis, Origin, Up, Repeat, FamilyIndex) {
	State := _LNTOC_State([], [])
	RecipeId := (FamilyIndex - 1) * 2 + (Axis == 2 ? 1 : 2)
	State.Receipt := _LNTR_Receipt(RecipeId, RecipeId)
	Other := Family[3] == 1 ? 2 : 1
	NumPut("UChar", Family[3] | Other, "UChar", Family[3] | Other, State.Receipt, 68)
	NumPut("UShort", Family[1], "UShort", Family[2], "UChar", Origin,
		"UChar", Up, "UChar", Repeat, State.Receipt, 136)
	NumPut("UShort", Axis == 2 ? Family[2] : Family[1], State.Receipt, 172)
	NumPut("UShort", Axis == 1 ? Family[1] : 0,
		"UShort", Axis == 2 ? Family[2] : 0, State.Receipt, 174)
	NumPut("UChar", Axis, "UChar", 4, "UChar", 0, "UChar", Family[3], State.Receipt, 178)
	return State
}

_LNTOC_SharedNaturalCase(Family, Axis, Origin, Up, Repeat, FamilyIndex) {
	State := _LNTOC_SharedNaturalState(Family, Axis, Origin, Up, Repeat, FamilyIndex)
	Consumer := TerminalOutputConsumer(901, "none", State.Port, _LNTOC_ForbidSharedNaturalEmission)
	AssertEqual(0, Consumer.Handle["unit_count"], "An unchanged LR bit has no native output unit.")
	AssertEqual(0, LLM_NavEventOwner_BeginTerminalOutputAttempt(Consumer.Handle))
	AssertFalse(Consumer.Handle["delivery_enabled"]), AssertFalse(Consumer.Handle["cohort_complete"])
	State.RetireStatus := 4
	AssertFalse(Consumer.Service(), "A known refused retirement must retain its zero-output edge.")
	AssertFalse(Consumer.Retired), AssertFalse(Consumer.Blocked)
	Status := LLM_NavEventOwner_TerminalOutputCustodyStatus(Consumer.Handle)
	AssertEqual(0, Status["unit_count"]), AssertEqual(0, Status["accepted"])
	AssertFalse(Status["pending"]), AssertFalse(Status["unknown"])
	State.RetireStatus := 0
	AssertTrue(Consumer.Service(), "The exact zero-output receipt may retire without any emitter.")
	AssertEqual(1, State.Plans), AssertEqual(0, State.Begins), AssertEqual(0, State.Acks.Length)
	AssertEqual(2, State.Consumes), AssertEqual(0, State.Cancels)
	AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
	AssertEqual(2, State.Consumes, "A settled edge must never consume the replacement FIFO head.")
}

_LNTOC_ForbidSharedNaturalEmission(*) {
	throw Error("A zero-output natural edge must not select or invoke an emitter.")
}

; Literal VK/SCAN/LR identities, independent of production natural tables.
for _LNTOC_SharedFamilyIndex, _LNTOC_SharedFamily in [
	[0xA2, 0x01D, 0x01], [0xA3, 0x11D, 0x02],
	[0xA4, 0x038, 0x04], [0xA5, 0x138, 0x08],
	[0xA0, 0x02A, 0x10], [0xA1, 0x036, 0x20],
	[0x5B, 0x15B, 0x40], [0x5C, 0x15C, 0x80]] {
	for _LNTOC_SharedAxis in [1, 2] {
		for _LNTOC_SharedOrigin in [1, 2] {
			for _LNTOC_SharedEdge in [[0, 0], [0, 1], [1, 0]]
				Test("terminal output natural custody: " . _LNTOC_SharedFamilyIndex
					. ":axis" . _LNTOC_SharedAxis . ":origin" . _LNTOC_SharedOrigin
					. ":up" . _LNTOC_SharedEdge[1] . ":repeat" . _LNTOC_SharedEdge[2]
					. " (todo49-natural-custody)",
					_LNTOC_WithState.Bind(_LNTOC_SharedNaturalCase.Bind(_LNTOC_SharedFamily,
						_LNTOC_SharedAxis, _LNTOC_SharedOrigin, _LNTOC_SharedEdge[1],
						_LNTOC_SharedEdge[2], _LNTOC_SharedFamilyIndex)))
		}
	}
}


/** Even no emitted units cannot erase an uncertain native retirement effect. */
_LNTOC_SharedNaturalUnknownCase(Mode) {
	State := _LNTOC_SharedNaturalState([0xA0, 0x02A, 0x10], 2, 1, 1, 0, 5)
	if Mode == "throw"
		State.Throw := "consume"
	else
		State.RetireStatus := 0.5
	Consumer := TerminalOutputConsumer(901, "none", State.Port, _LNTOC_ForbidSharedNaturalEmission)
	AssertEqual(0, Consumer.Handle["unit_count"])
	AssertThrows(() => Consumer.Service())
	AssertTrue(Consumer.Blocked), AssertFalse(Consumer.Retired)
	Status := LLM_NavEventOwner_TerminalOutputCustodyStatus(Consumer.Handle)
	AssertTrue(Status["unknown"]), AssertEqual(0, Status["unit_count"])
	AssertEqual(0, Status["accepted"]), AssertFalse(Status["pending"])
	State.Throw := "", State.RetireStatus := 0
	AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
	AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Consumer.Handle))
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Consumer.Handle))
	Copied := Consumer.Handle.Clone()
	AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(Copied))
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertEqual(1, State.Plans), AssertEqual(1, State.Consumes)
	AssertEqual(0, State.Begins), AssertEqual(0, State.Acks.Length), AssertEqual(0, State.Cancels)
}

for _LNTOC_SharedUnknownMode in ["throw", "untyped"]
	Test("terminal output natural custody: uncertain retirement " . _LNTOC_SharedUnknownMode
		. " (todo49-natural-custody)",
		_LNTOC_WithState.Bind(_LNTOC_SharedNaturalUnknownCase.Bind(_LNTOC_SharedUnknownMode)))

/** An independent literal packet fixture never invokes a Windows send backend. */
_LNTOC_PacketSerialize(State, Owner, Key, Attempt, Packets, Capacity, Count) {
	_LNTOC_CheckKey(Owner, Key)
	AssertTrue(State.Pending), AssertEqual(State.Attempt, Attempt)
	AssertEqual(2048, Capacity), AssertEqual(81920, Packets.Size), AssertEqual(4, Count.Size)
	State.Serializes += 1
	if HasMethod(State.OnSerialize, "Call")
		State.OnSerialize.Call()
	if !(State.SerializeStatus is Integer) || State.SerializeStatus != 0
		return State.SerializeStatus
	Remaining := State.Packets.Length - State.Accepted
	Loop Remaining {
		Values := State.Packets[State.Accepted + A_Index]
		Offset := (A_Index - 1) * 40
		NumPut("UInt", 1, Packets, Offset)
		NumPut("UShort", Values[1], "UShort", Values[2], "UInt", Values[3], Packets, Offset + 8)
		NumPut("UInt64", 0x4552475054524D31, Packets, Offset + 24)
	}
	NumPut("UInt", Remaining, Count)
	State.PacketInput := Packets
	if State.SerializeMutation >= 0
		NumPut("UChar", NumGet(Packets, State.SerializeMutation, "UChar") ^ 1,
			Packets, State.SerializeMutation)
	if State.SerializeFailure == "packets-size"
		Packets.Size := 40
	else if State.SerializeFailure == "count-size"
		Count.Size := 1
	else if State.SerializeFailure == "count"
		NumPut("UInt", Remaining + 1, Count)
	else if State.SerializeFailure == "key"
		NumPut("UInt64", 902, Key)
	else if State.SerializeFailure == "throw"
		throw Error("Injected unknown serialization completion.")
	return 0
}

_LNTOC_PacketState(Vector := "plain") {
	if Vector == "surrogate" {
		_LNTR_LoadFixture(Chr(0x1F600))
		State := _LNTOC_State([0xD83D, 0xDE00],
			[[0, 0, 0xD83D, 1, 0, 0, 0], [0, 0, 0xD83D, 1, 1, 0, 0],
			[0, 0, 0xDE00, 1, 0, 0, 0], [0, 0, 0xDE00, 1, 1, 0, 0]])
		State.Packets := [[0, 0xD83D, 4], [0, 0xD83D, 6], [0, 0xDE00, 4], [0, 0xDE00, 6]]
	} else {
		State := _LNTOC_State()
		State.Packets := [[0, 0x61, 4], [0, 0x61, 6]]
	}
	State.SerializeStatus := 0, State.Serializes := 0
	State.SerializeMutation := -1, State.SerializeFailure := "", State.OnSerialize := 0
	State.Port["serialize_terminal_output_attempt"] := _LNTOC_PacketSerialize.Bind(State)
	return State
}

_LNTOC_PacketConsumerVector(CaseName) {
	Calls := 0, Saved := 0
	State := _LNTOC_PacketState(CaseName == "surrogate" ? "surrogate" : "plain")
	if CaseName == "zero-up" {
		State.Units := [], State.Text := [], State.Packets := []
		NumPut("UChar", 1, State.Receipt, 141)
	}
	if CaseName == "known-refusal" || CaseName == "current-fifo-refusal" || CaseName == "fresh-refusal-retry"
		State.SerializeStatus := 4
	if CaseName == "admission-refusal"
		State.PlanStatus := 4
	if CaseName == "unknown-string"
		State.SerializeStatus := "0"
	if CaseName == "unknown-float"
		State.SerializeStatus := 0.0
	if InStr(CaseName, "native-byte-") == 1
		State.SerializeMutation := Integer(SubStr(CaseName, 13))
	if InStr(CaseName, "native-") == 1 && !InStr(CaseName, "native-byte-")
		State.SerializeFailure := SubStr(CaseName, 8)
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port, Emit)
	State.OnSerialize := Reenter
	State.Port["observe_terminal_output_packet_copy"] := ObserveCopy
	ObserveCopy(Stage, Destination, Source) {
		if Stage == "after_owned"
			State.CopiedPrivate := Destination
		if CaseName == "copy-retire-borrowed" && Stage == "after_owned"
			Source.Size := 1
		if CaseName == "copy-before-owned-byte" && Stage == "before_owned"
			NumPut("UShort", 0x7A, Source, 10)
		if CaseName == "copy-after-owned-byte" && Stage == "after_owned"
			NumPut("UShort", 0x7A, Destination, 10)
		if CaseName == "copy-before-public-byte" && Stage == "before_public"
			NumPut("UShort", 0x7A, Source, 10)
		if CaseName == "copy-after-public-byte" && Stage == "after_public" {
			NumPut("UShort", 0x7A, Destination, 10)
			NumPut("UShort", 0x7A, Source, 10)
		}
		if CaseName == "copy-before-owned-resize-source" && Stage == "before_owned"
			Source.Size := 1
		if CaseName == "copy-before-owned-resize-destination" && Stage == "before_owned"
			Destination.Size := 1
		if CaseName == "copy-before-public-resize-source" && Stage == "before_public"
			Source.Size := 1
		if CaseName == "copy-before-public-resize-destination" && Stage == "before_public"
			Destination.Size := 1
		if CaseName == "copy-after-owned-resize-destination" && Stage == "after_owned"
			Destination.Size := 1
		if CaseName == "copy-after-public-resize-destination" && Stage == "after_public"
			Destination.Size := 1
		if (CaseName == "copy-before-owned-identity" && Stage == "before_owned")
				|| (CaseName == "copy-after-public-identity" && Stage == "after_public")
			Consumer.Handle["plan_id"] += 1
	}
	Reenter() {
		global _LLM_NavEventOwnerTerminalRouteOwner
		AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertEqual(0, LLM_NavEventOwner_BeginTerminalOutputAttempt(Consumer.Handle))
		AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Consumer.Handle))
		if CaseName == "owner-change"
			_LLM_NavEventOwnerTerminalRouteOwner += 1
	}
	Emit(Receipt) {
		Calls += 1, Saved := Receipt
		AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(Consumer.Handle, Consumer.Attempt, 0))
		AssertEqual(0, LLM_NavEventOwner_SerializeTerminalOutputAttempt(Consumer.Handle, Consumer.Attempt))
		AssertFalse(Receipt["delivery_enabled"]), AssertFalse(Receipt["cohort_complete"])
		AssertEqual(40, Receipt["packet_size"])
		AssertEqual(Receipt["unit_count"] * 40, Receipt["packets"].Size)
		if CaseName == "surrogate" {
			AssertEqual(Calls == 1 ? 4 : 3, Receipt["unit_count"])
			AssertEqual(0xD83D, NumGet(Receipt["packets"], 10, "UShort"))
			AssertEqual(Calls == 1 ? 4 : 6, NumGet(Receipt["packets"], 12, "UInt"))
			return Calls == 1 ? 1 : Calls == 2 ? 0 : 3
		}
		if CaseName == "borrowed-storage" {
			State.PacketInput.Size := 1
			AssertEqual(0x61, NumGet(Receipt["packets"], 10, "UShort"))
		}
		if CaseName == "emit-throw"
			throw Error("Injected uncertain packet delivery.")
		if CaseName == "invalid-prefix"
			return "2"
		if InStr(CaseName, "public-byte-") == 1 {
			Offset := Integer(SubStr(CaseName, 13))
			NumPut("UChar", NumGet(Receipt["packets"], Offset, "UChar") ^ 1, Receipt["packets"], Offset)
		}
		if InStr(CaseName, "field-") == 1
			Receipt[SubStr(CaseName, 7)] += 1
		if CaseName == "foreign-buffer" {
			Clone := Buffer(Receipt["packets"].Size, 0)
			DllCall("Kernel32\RtlMoveMemory", "Ptr", Clone, "Ptr", Receipt["packets"], "UPtr", Clone.Size)
			Receipt["packets"] := Clone
		}
		if CaseName == "resized-buffer"
			Receipt["packets"].Size += 1
		if CaseName == "handle-mutation"
			Consumer.Handle["plan_id"] += 1
		if CaseName == "both-resized" {
			Receipt["packets"].Size += 40
			State.CopiedPrivate.Size += 40
		}
		if CaseName == "private-canonical" {
			NumPut("UShort", 0x7A, Receipt["packets"], 10)
			NumPut("UShort", 0x7A, State.CopiedPrivate, 10)
		}
		if CaseName == "attempt-replaced"
			Consumer.Attempt := Consumer.Attempt.Clone()
		return Receipt["unit_count"]
	}
	if CaseName == "ack-refusal"
		State.AckStatus := 4
	if CaseName == "ack-throw"
		State.Throw := "acknowledge"
	BadNative := InStr(CaseName, "native-") == 1 || InStr(CaseName, "unknown-") == 1 || CaseName == "owner-change"
		|| (InStr(CaseName, "copy-") == 1 && CaseName != "copy-retire-borrowed")
	BadPublic := InStr(CaseName, "public-byte-") == 1 || InStr(CaseName, "field-") == 1
		|| CaseName == "foreign-buffer" || CaseName == "resized-buffer" || CaseName == "handle-mutation" || CaseName == "attempt-replaced" || CaseName == "private-canonical" || CaseName == "both-resized"
	if BadNative || BadPublic || CaseName == "emit-throw" || CaseName == "invalid-prefix" || CaseName == "ack-throw" {
		AssertThrows(() => Consumer.Service())
		AssertTrue(Consumer.Blocked), AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertEqual(BadNative ? 0 : 1, Calls)
		AssertEqual(CaseName == "ack-throw" ? 1 : 0, State.Acks.Length)
		AssertEqual(0, State.Consumes), AssertEqual(0, State.Cancels)
		return
	}
	if CaseName == "admission-refusal" {
		AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertEqual(0, Calls), AssertEqual(0, State.Begins), AssertEqual(0, State.Serializes)
		return
	}
	if CaseName == "known-refusal" || CaseName == "current-fifo-refusal" || CaseName == "fresh-refusal-retry" {
		AssertThrows(() => Consumer.Service())
		AssertTrue(Consumer.Blocked), AssertEqual(0, Calls), AssertEqual(0, State.Acks.Length)
		Status := LLM_NavEventOwner_TerminalOutputCustodyStatus(Consumer.Handle)
		AssertTrue(Status["pending"]), AssertFalse(Status["unknown"]), AssertEqual(0, Status["accepted"])
		AssertFalse(Consumer.Cancel())
		if CaseName == "current-fifo-refusal" {
			State.AckStatus := 4
			AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(Consumer.Handle, Consumer.Attempt, 0))
			AssertTrue(LLM_NavEventOwner_TerminalOutputCustodyStatus(Consumer.Handle)["pending"])
			AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Consumer.Handle))
			State.AckStatus := 0
		}
		AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Consumer.Handle, Consumer.Attempt, 0))
		if CaseName == "fresh-refusal-retry" {
			Fresh := LLM_NavEventOwner_BeginTerminalOutputAttempt(Consumer.Handle)
			AssertTrue(Fresh["attempt_id"] != Consumer.Attempt["attempt_id"])
			State.SerializeStatus := 0
			AssertThrows(() => LLM_NavEventOwner_SerializeTerminalOutputAttempt(Consumer.Handle, Consumer.Attempt))
			Receipt := LLM_NavEventOwner_SerializeTerminalOutputAttempt(Consumer.Handle, Fresh)
			AssertTrue(LLM_NavEventOwner_ValidateTerminalOutputPackets(Consumer.Handle, Receipt))
			AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Consumer.Handle, Fresh, 0))
		}
		AssertTrue(LLM_NavEventOwner_CancelTerminalOutput(Consumer.Handle))
		AssertEqual(1, State.Cancels), AssertEqual(0, State.Consumes)
		return
	}
	if CaseName == "surrogate" {
		AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertFalse(Consumer.Service()), AssertEqual(2, Calls)
		AssertTrue(Consumer.Service()), AssertEqual(3, Calls)
		AssertEqual(1, State.Acks[1]), AssertEqual(0, State.Acks[2]), AssertEqual(3, State.Acks[3])
	} else if CaseName == "ack-refusal" {
		AssertFalse(Consumer.Service()), AssertEqual(1, Calls)
		State.AckStatus := 0
		AssertTrue(Consumer.Service()), AssertEqual(1, Calls), AssertEqual(1, State.Serializes)
	} else
		AssertTrue(Consumer.Service())
	AssertEqual(1, State.Consumes), AssertEqual(0, State.Cancels)
	AssertEqual(CaseName == "zero-up" ? 0 : CaseName == "surrogate" ? 3 : 1, Calls)
	AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
}

/** Foreign receipts cannot borrow an equal tuple or reopen an already closed attempt. */
_LNTOC_PacketReceiptIdentityCase() {
	State := _LNTOC_PacketState()
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	AssertThrows(() => LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt.Clone()))
	AssertEqual(0, State.Serializes), AssertEqual(0, State.Acks.Length)
	Receipt := LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt)
	AssertTrue(LLM_NavEventOwner_ValidateTerminalOutputPackets(Handle, Receipt))
	AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 0))
	Next := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	AssertThrows(() => LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt))
	AssertEqual(1, State.Serializes)
	NewReceipt := LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Next)
	AssertTrue(NewReceipt != Receipt), AssertEqual(2, State.Serializes)
	AssertThrows(() => LLM_NavEventOwner_ValidateTerminalOutputPackets(Handle, Receipt))
	AssertTrue(LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle)["unknown"])
	AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Next, 0))
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
}

/** Every mutated caller byte blocks direct ACK as well as the consumer wrapper. */
_LNTOC_PacketDirectAckMutationCase() {
	State := _LNTOC_PacketState()
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	Receipt := LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt)
	NumPut("UChar", 1, Receipt["packets"], 39)
	AssertThrows(() => LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 2))
	AssertEqual(0, State.Acks.Length), AssertEqual(0, State.Consumes), AssertEqual(0, State.Cancels)
	NumPut("UChar", 0, Receipt["packets"], 39)
	AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 0))
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
}

for _LNTOC_PacketCaseName in ["plain", "surrogate", "zero-up", "borrowed-storage", "known-refusal",
	"ack-refusal", "ack-throw", "emit-throw", "invalid-prefix", "unknown-string", "unknown-float",
	"native-packets-size", "native-count-size", "native-count", "native-key", "native-throw",
	"foreign-buffer", "resized-buffer", "handle-mutation",
	"field-owner", "field-token", "field-sequence", "field-plan_id", "field-attempt_id",
	"field-unit_count", "field-packet_size", "field-delivery_enabled", "field-cohort_complete",
	"owner-change", "attempt-replaced", "admission-refusal", "current-fifo-refusal", "fresh-refusal-retry",
	"copy-before-owned-byte", "copy-after-owned-byte", "copy-before-public-byte", "copy-after-public-byte",
	"copy-before-owned-resize-source", "copy-before-owned-resize-destination",
	"copy-before-public-resize-source", "copy-before-public-resize-destination",
	"copy-after-owned-resize-destination", "copy-after-public-resize-destination",
	"copy-before-owned-identity", "copy-after-public-identity", "copy-retire-borrowed", "private-canonical", "both-resized"]
	Test("terminal output packet receiver: " . _LNTOC_PacketCaseName . " (todo49-packet-receiving)",
		_LNTOC_WithState.Bind(_LNTOC_PacketConsumerVector.Bind(_LNTOC_PacketCaseName)))
Loop 40 {
	for _LNTOC_PacketDirection in ["native-byte-", "public-byte-"] {
		_LNTOC_PacketByteCase := _LNTOC_PacketDirection . (A_Index - 1)
		Test("terminal output packet receiver: " . _LNTOC_PacketByteCase . " (todo49-packet-receiving)",
			_LNTOC_WithState.Bind(_LNTOC_PacketConsumerVector.Bind(_LNTOC_PacketByteCase)))
	}
}
Test("terminal output packet receiver: exact attempt and stale receipt custody (todo49-packet-receiving)",
	_LNTOC_WithState.Bind(_LNTOC_PacketReceiptIdentityCase))
Test("terminal output packet receiver: direct ACK cannot bypass changed packet bytes (todo49-packet-receiving)",
	_LNTOC_WithState.Bind(_LNTOC_PacketDirectAckMutationCase))

/** Every natural LR family exercises literal VK and encoded extended-scan packets. */
_LNTOC_PacketNaturalVector(Axis, Vk, Scan, LR, ScanFlags, Up) {
	global _LLM_NavEventOwnerTerminalRouteRecipes
	State := _LNTOC_PacketState()
	State.Text := [], State.Units := [[Axis == 1 ? Vk : 0, Axis == 2 ? Scan : 0, 0, 2, Up, 0, 0]]
	State.Packets := [[Axis == 1 ? Vk : 0, Axis == 2 ? Scan & 0xFF : 0,
		(Axis == 2 ? ScanFlags : 0) | (Up ? 2 : 0)]]
	State.Receipt := _LNTR_Receipt(9, 9)
	Route := _LLM_NavEventOwnerTerminalRouteRecipes[9]["route"]
	Route["axis"] := Axis, Route["code"] := Axis == 1 ? Vk : Scan
	Route["target_vk"] := Axis == 1 ? Vk : 0, Route["target_scan"] := Axis == 2 ? Scan : 0
	Route["effective_modifiers_lr"] := LR
	NumPut("UChar", Up ? LR : 0, "UChar", Up ? 0 : LR, State.Receipt, 68)
	NumPut("UShort", Vk, "UShort", Scan, "UChar", 1, "UChar", Up, State.Receipt, 136)
	NumPut("UShort", Route["code"], "UShort", Route["target_vk"], "UShort", Route["target_scan"], State.Receipt, 172)
	NumPut("UChar", Axis, "UChar", 4, "UChar", 0, "UChar", LR, State.Receipt, 178)
	Calls := 0
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port, Emit)
	Emit(Receipt) {
		Calls += 1
		Expected := State.Packets[1]
		AssertEqual(1, Receipt["unit_count"]), AssertEqual(40, Receipt["packets"].Size)
		AssertEqual(Expected[1], NumGet(Receipt["packets"], 8, "UShort"))
		AssertEqual(Expected[2], NumGet(Receipt["packets"], 10, "UShort"))
		AssertEqual(Expected[3], NumGet(Receipt["packets"], 12, "UInt"))
		return 1
	}
	AssertTrue(Consumer.Service()), AssertEqual(1, Calls), AssertEqual(1, State.Serializes)
	AssertEqual(1, State.Acks[1]), AssertEqual(1, State.Consumes), AssertEqual(0, State.Cancels)
}

_LNTOC_PacketForeignReceiptVector(Kind) {
	State := _LNTOC_PacketState()
	Handle := LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port)
	Attempt := LLM_NavEventOwner_BeginTerminalOutputAttempt(Handle)
	Receipt := LLM_NavEventOwner_SerializeTerminalOutputAttempt(Handle, Attempt)
	if Kind == "receipt"
		AssertThrows(() => LLM_NavEventOwner_ValidateTerminalOutputPackets(Handle, Receipt.Clone()))
	else
		AssertThrows(() => LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt.Clone(), 2))
	AssertTrue(LLM_NavEventOwner_TerminalOutputCustodyStatus(Handle)["unknown"])
	AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(Handle, Attempt, 0))
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertEqual(0, State.Acks.Length), AssertEqual(0, State.Consumes), AssertEqual(0, State.Cancels)
}

for _LNTOC_PacketNatural in [[0xA2,0x01D,1,8], [0xA3,0x11D,2,9], [0xA4,0x038,4,8], [0xA5,0x138,8,9],
	[0xA0,0x02A,16,8], [0xA1,0x036,32,8], [0x5B,0x15B,64,9], [0x5C,0x15C,128,9]]
	for _LNTOC_PacketAxis in [1, 2]
		for _LNTOC_PacketUp in [0, 1]
			Test("terminal output packet receiver: natural " . _LNTOC_PacketNatural[1]
				. "/" . _LNTOC_PacketAxis . "/" . _LNTOC_PacketUp . " (todo49-packet-receiving)",
				_LNTOC_WithState.Bind(_LNTOC_PacketNaturalVector.Bind(_LNTOC_PacketAxis,
					_LNTOC_PacketNatural[1], _LNTOC_PacketNatural[2], _LNTOC_PacketNatural[3],
					_LNTOC_PacketNatural[4], _LNTOC_PacketUp)))
for _LNTOC_PacketForeign in ["receipt", "attempt"]
	Test("terminal output packet receiver: foreign " . _LNTOC_PacketForeign . " (todo49-packet-receiving)",
		_LNTOC_WithState.Bind(_LNTOC_PacketForeignReceiptVector.Bind(_LNTOC_PacketForeign)))

/** Real callback boundaries may remove or replace the owned registry binding. */
_LNTOC_PacketBindingVector(Phase, Mutation) {
	global _LLM_TerminalOutputRecords, _LLM_TerminalOutputUnknown
	State := _LNTOC_PacketState(), Calls := 0
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port, Emit)
	OriginalHandle := Consumer.Handle
	OriginalRecord := _LLM_TerminalOutputRecords[ObjPtr(OriginalHandle)]
	if Phase == "known-refusal"
		State.SerializeStatus := 4
	if Phase == "native" || Phase == "known-refusal"
		State.OnSerialize := Mutate
	State.Port["observe_terminal_output_packet_copy"] := Observe
	State.Port["acknowledge_terminal_output"] := Ack
	State.Port["consume_terminal_output"] := Consume
	State.Port["cancel_terminal_output"] := Cancel
	State.Port["begin_terminal_output_attempt"] := Begin
	Begin(Owner, Key, Units, Capacity, Count, Attempt) {
		Status := _LNTOC_Begin(State, Owner, Key, Units, Capacity, Count, Attempt)
		if Phase == "begin-throw" {
			Mutate()
			throw Error("Injected begin throw after registry replacement.")
		}
		return Status
	}
	Mutate() {
		if Mutation == "remove"
			_LLM_TerminalOutputRecords.Delete(ObjPtr(OriginalHandle))
		else if Mutation == "replace" || Mutation == "replace-valid-id" {
			Replacement := OriginalRecord.Clone()
			if Mutation == "replace-valid-id"
				Replacement["record_id"] := ObjPtr(Replacement)
			_LLM_TerminalOutputRecords[ObjPtr(OriginalHandle)] := Replacement
		}
		else
			Consumer.Handle := OriginalHandle.Clone()
	}
	Observe(Stage, Destination, Source) {
		if (Phase == "before-copy" && Stage == "before_owned")
				|| (Phase == "after-copy" && Stage == "after_public")
			Mutate()
	}
	Emit(Receipt) {
		Calls += 1
		if Phase == "emitter"
			Mutate()
		return Phase == "cancel" ? 0 : 2
	}
	Ack(Owner, Key, Attempt, Accepted) {
		Status := _LNTOC_Acknowledge(State, Owner, Key, Attempt, Accepted)
		if Phase == "ack" || Phase == "ack-throw"
			Mutate()
		if Phase == "ack-throw"
			throw Error("Injected acknowledgement throw after registry replacement.")
		return Status
	}
	Consume(Owner, Key) {
		Status := _LNTOC_Consume(State, Owner, Key)
		if Phase == "consume" || Phase == "consume-throw"
			Mutate()
		if Phase == "consume-throw"
			throw Error("Injected consumption throw after registry replacement.")
		return Status
	}
	Cancel(Owner, Key) {
		Status := _LNTOC_Cancel(State, Owner, Key)
		Mutate()
		if Phase == "cancel-before-throw"
			throw Error("Injected unsent cancellation throw after registry replacement.")
		return Status
	}
	if Phase == "cancel-before-throw"
		AssertThrows(() => Consumer.Cancel())
	else if Phase == "cancel" {
		AssertFalse(Consumer.Service()), AssertEqual(1, Calls)
		AssertThrows(() => Consumer.Cancel())
	} else
		AssertThrows(() => Consumer.Service())
	AssertTrue(Consumer.Blocked), AssertTrue(OriginalRecord["unknown"])
	AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
	if Mutation == "remove" || Mutation == "replace" || Mutation == "replace-valid-id" {
		AssertTrue(IsObject(_LLM_TerminalOutputUnknown))
		AssertTrue(_LLM_TerminalOutputUnknown["record"] == OriginalRecord)
		AssertTrue(_LLM_TerminalOutputUnknown["handle"] == OriginalHandle)
		AssertEqual(OriginalRecord["owner"], _LLM_TerminalOutputUnknown["owner"])
		AssertEqual(901, NumGet(_LLM_TerminalOutputUnknown["key"], 0, "UInt64"))
		AssertEqual(3, NumGet(_LLM_TerminalOutputUnknown["key"], 8, "UInt64"))
		AssertEqual(7, NumGet(_LLM_TerminalOutputUnknown["key"], 16, "UInt64"))
		; Restoring the original dictionary entry is not observed physical retirement.
		_LLM_TerminalOutputRecords[ObjPtr(OriginalHandle)] := OriginalRecord
	}
	Consumer.Handle := OriginalHandle
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(OriginalHandle, Consumer.Attempt, 0))
	AssertFalse(LLM_NavEventOwner_ConsumeTerminalOutput(OriginalHandle))
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(OriginalHandle))
	Early := Phase == "native" || Phase == "known-refusal" || Phase == "before-copy" || Phase == "after-copy"
		|| Phase == "begin-throw" || Phase == "cancel-before-throw"
	AssertEqual(Early ? 0 : 1, Calls)
	AssertEqual(Early || Phase == "emitter" ? 0 : 1, State.Acks.Length)
}

for _LNTOC_PacketBindingPhase in ["native", "known-refusal", "before-copy", "after-copy", "emitter",
	"ack", "ack-throw", "consume", "consume-throw", "cancel", "begin-throw", "cancel-before-throw"]
	for _LNTOC_PacketBindingMutation in ["remove", "replace", "replace-valid-id", "handle"]
		Test("terminal output packet receiver: binding " . _LNTOC_PacketBindingPhase
			. "/" . _LNTOC_PacketBindingMutation . " (todo49-packet-receiving)",
			_LNTOC_WithState.Bind(_LNTOC_PacketBindingVector.Bind(_LNTOC_PacketBindingPhase,
				_LNTOC_PacketBindingMutation)))


/** Unknown retirement must retain the original pre-callback holder and key. */
_LNTOC_FrozenAuthorityVector(Phase, Mutation, Binding, Outcome) {
	global _LLM_TerminalOutputRecords, _LLM_TerminalOutputUnknown
	State := _LNTOC_PacketState()
	Calls := 0
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port, Emit)
	Handle := Consumer.Handle
	Record := _LLM_TerminalOutputRecord(Handle)
	Owner := Record["owner"]
	OriginalKey := _LLM_TerminalOutputKey(Record)
	Change(*) {
		Calls += 1
		if Mutation == "handle" || Mutation == "all"
			Record["handle"] := Handle.Clone()
		if Mutation == "tuple" || Mutation == "all" {
			Record["owner"] += 10, Record["token"] += 10
			Record["sequence"] += 10, Record["plan_id"] += 10
		}
		if Binding == "remove"
			_LLM_TerminalOutputRecords.Delete(ObjPtr(Handle))
		else if Binding == "replace" {
			Replacement := Record.Clone()
			Replacement["record_id"] := ObjPtr(Replacement)
			_LLM_TerminalOutputRecords[ObjPtr(Handle)] := Replacement
		}
		if Outcome == "throw"
			throw Error("Injected foreign callback lost original custody.")
	}
	Emit(Receipt) {
		if Phase == "emitter"
			Change()
		return Receipt["unit_count"]
	}
	Copy(Stage, Destination, Source) {
		if Stage == Phase
			Change()
	}
	NativeRetire(OwnerArg, Key) {
		Result := RetireFn.Call(OwnerArg, Key)
		Change()
		return Outcome == "refusal" ? 4 : Result
	}
	Ack(OwnerArg, Key, Attempt, Count) {
		Result := AckFn.Call(OwnerArg, Key, Attempt, Count)
		Change()
		return Outcome == "refusal" ? 4 : Result
	}
	if Phase == "begin"
		State.OnBegin := Change
	else if Phase == "serialize"
		State.OnSerialize := Change
	else if InStr(Phase, "owned") || InStr(Phase, "public")
		State.Port["observe_terminal_output_packet_copy"] := Copy
	else if Phase == "ack" {
		AckFn := State.Port["acknowledge_terminal_output"]
		State.Port["acknowledge_terminal_output"] := Ack
	} else if Phase == "consume" || Phase == "cancel" {
		Operation := Phase == "consume" ? "consume_terminal_output" : "cancel_terminal_output"
		RetireFn := State.Port[Operation]
		State.Port[Operation] := NativeRetire
	}
	if Phase == "cancel"
		AssertThrows(() => Consumer.Cancel())
	else
		AssertThrows(() => Consumer.Service())
	AssertEqual(1, Calls)
	AssertTrue(Consumer.Blocked), AssertTrue(Record["unknown"])
	AssertTrue(_LLM_TerminalOutputUnknown is Map)
	AssertTrue(_LLM_TerminalOutputUnknown["record"] == Record)
	AssertTrue(_LLM_TerminalOutputUnknown["handle"] == Handle, "A mutated Record.handle cannot change the retained original holder.")
	AssertEqual(Owner, _LLM_TerminalOutputUnknown["owner"])
	AssertEqual(901, _LLM_TerminalOutputUnknown["token"]), AssertEqual(3, _LLM_TerminalOutputUnknown["sequence"])
	AssertEqual(24, _LLM_TerminalOutputUnknown["key"].Size)
	Loop 24
		AssertEqual(NumGet(OriginalKey, A_Index - 1, "UChar"), NumGet(_LLM_TerminalOutputUnknown["key"], A_Index - 1, "UChar"))
	AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
	; Restoring a dictionary or tuple never grants ACK, cleanup or replacement.
	Record["handle"] := Handle, Record["owner"] := Owner, Record["token"] := 901
	Record["sequence"] := 3, Record["plan_id"] := 7
	_LLM_TerminalOutputRecords[ObjPtr(Handle)] := Record
	AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
	AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(Handle))
	AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
}

for _LNTOC_AuthorityPhase in ["begin", "serialize", "before_owned", "after_owned", "before_public", "after_public", "emitter", "ack", "consume", "cancel"] {
	for _LNTOC_AuthorityMutation in ["handle", "tuple", "all"] {
		for _LNTOC_AuthorityBinding in ["remove", "replace"] {
			for _LNTOC_AuthorityOutcome in ["normal", "throw"]
				Test("terminal frozen authority: " . _LNTOC_AuthorityPhase . ":" . _LNTOC_AuthorityMutation
					. ":" . _LNTOC_AuthorityBinding . ":" . _LNTOC_AuthorityOutcome . " (todo49-frozen-authority)",
					_LNTOC_WithState.Bind(_LNTOC_FrozenAuthorityVector.Bind(_LNTOC_AuthorityPhase,
						_LNTOC_AuthorityMutation, _LNTOC_AuthorityBinding, _LNTOC_AuthorityOutcome)))
		}
	}
}
for _LNTOC_AuthorityRefusalPhase in ["ack", "consume", "cancel"]
	Test("terminal frozen authority: refused " . _LNTOC_AuthorityRefusalPhase . " retains original tuple (todo49-frozen-authority)",
		_LNTOC_WithState.Bind(_LNTOC_FrozenAuthorityVector.Bind(_LNTOC_AuthorityRefusalPhase, "all", "remove", "refusal")))


; The explicit primitive is feature-local; no production initializer chooses it.
#Include %A_LineFile%\..\..\..\..\adapters\terminal_output_sendinput.ahk

/** Actual production callback vectors with injected sender; Windows execution UNRUN. */
_LNTOC_SendInputVector(Mode) {
	global _LLM_TerminalOutputRecords, _LLM_TerminalOutputUnknown
	State := _LNTOC_PacketState(Mode == "surrogate" ? "surrogate" : "plain")
	Calls := 0, SentCounts := [], Emitted := 0, Original := 0, OriginalHandle := 0
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port, (*) => 0)
	OriginalHandle := Consumer.Handle
	Original := _LLM_TerminalOutputRecord(OriginalHandle)
	Send(Count, Packets, PacketSize) {
		Calls += 1
		SentCounts.Push(Count)
		Emitted := Packets
		AssertEqual(40, PacketSize), AssertEqual(Count * 40, Packets.Size)
		AssertTrue(Packets != Original["packet_private"]), AssertTrue(Packets != Original["packet_public"])
		AssertEqual(State.Units.Length - State.Accepted, Count, "Only the authenticated remaining suffix is sent.")
		if Mode == "reentry" {
			AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
			AssertFalse(LLM_NavEventOwner_AcknowledgeTerminalOutput(OriginalHandle, Consumer.Attempt, 0))
			AssertFalse(LLM_NavEventOwner_CancelTerminalOutput(OriginalHandle))
		} else if Mode == "throw"
			throw Error("Injected sender exception after possible insertion.")
		else if Mode == "string"
			return "2"
		else if Mode == "float"
			return 2.0
		else if Mode == "negative"
			return -1
		else if Mode == "overflow"
			return Count + 1
		else if InStr(Mode, "emit-byte-") == 1 {
			Offset := Integer(SubStr(Mode, 11))
			NumPut("UChar", NumGet(Packets, Offset, "UChar") ^ 1, Packets, Offset)
		} else if Mode == "emit-resize"
			Packets.Size := 1
		else if Mode == "emit-grow"
			Packets.Size += 40
		else if Mode == "public-resize"
			Original["packet_public"].Size := 1
		else if Mode == "private-resize"
			Original["packet_private"].Size := 1
		else if Mode == "equal-forgery" {
			; All public/retained/emitted bytes and canonical units agree on a new
			; literal, but the unexposed pre-call witness must still reject it.
			NumPut("UShort", 0x62, Original["canonical"], 4)
			NumPut("UShort", 0x62, Original["canonical"], 14)
			Original["owned_attempt"]["units"][1]["utf16"] := 0x62
			Original["owned_attempt"]["units"][2]["utf16"] := 0x62
			for Forged in [Packets, Original["packet_private"], Original["packet_public"]] {
				NumPut("UShort", 0x62, Forged, 10)
				NumPut("UShort", 0x62, Forged, 50)
			}
		} else if Mode == "count"
			Original["attempt_count"] := Count + 1
		else if Mode == "count-float"
			Original["attempt_count"] := Count + 0.0
		else if Mode == "receipt-count"
			Original["packet_receipt"]["unit_count"] := Count + 1
		else if Mode == "receipt-replace"
			Original["packet_receipt"] := Original["packet_receipt"].Clone()
		else if Mode == "attempt-replace"
			Original["owned_attempt"] := Original["owned_attempt"].Clone()
		else if Mode == "attempt-id"
			Original["attempt_id"] += 1
		else if Mode == "handle-clone"
			Consumer.Handle := OriginalHandle.Clone()
		else if Mode == "handle-fields"
			OriginalHandle["sequence"] += 1
		else if Mode == "record-handle"
			Original["handle"] := OriginalHandle.Clone()
		else if Mode == "record-handle-remove" {
			Original["handle"] := OriginalHandle.Clone()
			_LLM_TerminalOutputRecords.Delete(ObjPtr(OriginalHandle))
		} else if Mode == "record-tuple-remove" {
			Original["owner"] += 1, Original["token"] += 1, Original["sequence"] += 1, Original["plan_id"] += 1
			_LLM_TerminalOutputRecords.Delete(ObjPtr(OriginalHandle))
		} else if Mode == "record-all-remove" {
			Original["handle"] := OriginalHandle.Clone()
			Original["owner"] += 1, Original["token"] += 1, Original["sequence"] += 1, Original["plan_id"] += 1
			_LLM_TerminalOutputRecords.Delete(ObjPtr(OriginalHandle))
		} else if Mode == "record-remove"
			_LLM_TerminalOutputRecords.Delete(ObjPtr(OriginalHandle))
		else if Mode == "record-replace"
			_LLM_TerminalOutputRecords[ObjPtr(OriginalHandle)] := Original.Clone()
		if Mode == "partial" && Calls == 1
			return 1
		if Mode == "zero" && Calls == 1
			return 0
		if Mode == "zero-cancel"
			return 0
		if Mode == "surrogate"
			return Calls == 1 ? 1 : Calls == 2 ? 0 : Count
		return Count
	}
	Consumer.PacketEmitter := LLM_NavEventOwner_TerminalOutputSendInputEmitter(OriginalHandle, Send)
	if Mode == "ack-refusal"
		State.AckStatus := 4
	else if Mode == "ack-throw"
		State.Throw := "acknowledge"
	else if Mode == "serialize-refusal"
		State.SerializeStatus := 4
	Known := ["full", "partial", "zero", "zero-cancel", "surrogate", "reentry", "ack-refusal"]
	IsKnown := false
	for Name in Known
		if Mode == Name
			IsKnown := true
	if !IsKnown {
		AssertThrows(() => Consumer.Service())
		AssertTrue(Consumer.Blocked), AssertFalse(Consumer.Retired)
		AssertEqual(Mode == "serialize-refusal" ? 0 : 1, Calls)
		AssertEqual(Mode == "ack-throw" ? 1 : 0, State.Acks.Length)
		AssertEqual(0, State.Consumes), AssertEqual(0, State.Cancels)
		AssertTrue(Original["pending"])
		AssertEqual(Mode != "serialize-refusal", Original["unknown"])
		if InStr(Mode, "record-") == 1 && Mode != "count" {
			AssertTrue(_LLM_TerminalOutputUnknown is Map)
			AssertTrue(_LLM_TerminalOutputUnknown["record"] == Original)
			AssertTrue(_LLM_TerminalOutputUnknown["handle"] == OriginalHandle)
			AssertEqual(901, _LLM_TerminalOutputUnknown["token"])
			AssertEqual(3, _LLM_TerminalOutputUnknown["sequence"])
			AssertEqual(7, NumGet(_LLM_TerminalOutputUnknown["key"], 16, "UInt64"))
		}
		AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
		AssertEqual(0, LLM_NavEventOwner_PlanTerminalOutput(901, "none", State.Port))
		if Mode == "serialize-refusal" {
			AssertTrue(LLM_NavEventOwner_AcknowledgeTerminalOutput(OriginalHandle, Consumer.Attempt, 0))
			AssertTrue(LLM_NavEventOwner_CancelTerminalOutput(OriginalHandle))
		}
		return
	}
	First := Consumer.Service()
	if Mode == "partial" || Mode == "zero" || Mode == "surrogate" || Mode == "ack-refusal" || Mode == "zero-cancel" {
		AssertFalse(First)
		AssertEqual(Mode == "partial" || Mode == "surrogate" ? 1 : Mode == "ack-refusal" ? 2 : 0, State.Acks[1])
		if Mode == "zero-cancel" {
			AssertTrue(Consumer.Cancel()), AssertEqual(1, State.Cancels)
			AssertEqual(0, State.Consumes), AssertEqual(1, Calls)
			return
		}
		if Mode == "ack-refusal"
			State.AckStatus := 0
		else if Mode != "zero"
			AssertFalse(Consumer.Cancel(), "An accepted prefix keeps the exact terminal edge; zero is tested separately.")
		if Mode == "surrogate"
			AssertFalse(Consumer.Service())
		AssertTrue(Consumer.Service())
	} else
		AssertTrue(First)
	AssertEqual(1, State.Consumes), AssertEqual(0, State.Cancels)
	AssertEqual(Mode == "surrogate" ? 3 : Mode == "partial" || Mode == "zero" ? 2 : 1, Calls)
	AssertEqual(Mode == "surrogate" ? 4 : 2, SentCounts[1])
	if Mode == "partial"
		AssertEqual(1, SentCounts[2])
	if Mode == "zero"
		AssertEqual(2, SentCounts[2])
	if Mode == "surrogate"
		AssertEqual(3, SentCounts[2]), AssertEqual(3, SentCounts[3])
	AssertFalse(Consumer.Service()), AssertFalse(Consumer.Cancel())
}

_LNTOC_SendInputSelectionCase() {
	State := _LNTOC_PacketState()
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port)
	AssertThrows(LLM_NavEventOwner_TerminalOutputSendInputEmitter.Bind(Consumer.Handle, 0))
	AssertThrows(LLM_NavEventOwner_TerminalOutputSendInputEmitter.Bind(Consumer.Handle, "native"))
	AssertFalse(Consumer.Service())
	AssertEqual(0, State.Begins), AssertEqual(0, State.Serializes), AssertEqual(0, State.Acks.Length)
	AssertTrue(Consumer.Cancel()), AssertEqual(1, State.Cancels)
}

_LNTOC_SendInputNaturalCase(Family, Axis, Origin, Up, Repeat, Index) {
	State := _LNTOC_SharedNaturalState(Family, Axis, Origin, Up, Repeat, Index)
	Calls := 0
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port, (*) => 0)
	Consumer.PacketEmitter := LLM_NavEventOwner_TerminalOutputSendInputEmitter(Consumer.Handle, (*) => Calls += 1)
	AssertEqual(0, Consumer.Handle["unit_count"])
	AssertTrue(Consumer.Service())
	AssertEqual(0, Calls), AssertEqual(0, State.Begins), AssertEqual(0, State.Acks.Length)
	AssertEqual(1, State.Consumes), AssertFalse(Consumer.Cancel())
}

_LNTOC_SendInputNativeBoundsCase() {
	AssertEqual(0, _LLM_TerminalOutputSendInputNative(0, Buffer(0), 40), "Zero inputs return without a native emission call.")
	AssertThrows(_LLM_TerminalOutputSendInputNative.Bind(-1, Buffer(0), 40))
	AssertThrows(_LLM_TerminalOutputSendInputNative.Bind("0", Buffer(0), 40))
	AssertThrows(_LLM_TerminalOutputSendInputNative.Bind(0.0, Buffer(0), 40))
	AssertThrows(_LLM_TerminalOutputSendInputNative.Bind(2049, Buffer(0), 40))
	AssertThrows(_LLM_TerminalOutputSendInputNative.Bind(1, Buffer(40), 28))
	AssertThrows(_LLM_TerminalOutputSendInputNative.Bind(1, Buffer(39), 40))
	AssertThrows(_LLM_TerminalOutputSendInputNative.Bind(1, "foreign", 40))
}

Test("terminal explicit SendInput: full (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("full")))
Test("terminal explicit SendInput: partial (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("partial")))
Test("terminal explicit SendInput: zero (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("zero")))
Test("terminal explicit SendInput: zero-cancel (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("zero-cancel")))
Test("terminal explicit SendInput: surrogate (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("surrogate")))
Test("terminal explicit SendInput: reentry (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("reentry")))
Test("terminal explicit SendInput: ack-refusal (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("ack-refusal")))
Test("terminal explicit SendInput: ack-throw (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("ack-throw")))
Test("terminal explicit SendInput: serialize-refusal (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("serialize-refusal")))
Test("terminal explicit SendInput: throw (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("throw")))
Test("terminal explicit SendInput: string (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("string")))
Test("terminal explicit SendInput: float (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("float")))
Test("terminal explicit SendInput: negative (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("negative")))
Test("terminal explicit SendInput: overflow (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("overflow")))
Test("terminal explicit SendInput: emit-resize (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-resize")))
Test("terminal explicit SendInput: emit-grow (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-grow")))
Test("terminal explicit SendInput: public-resize (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("public-resize")))
Test("terminal explicit SendInput: private-resize (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("private-resize")))
Test("terminal explicit SendInput: equal-forgery (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("equal-forgery")))
Test("terminal explicit SendInput: count (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("count")))
Test("terminal explicit SendInput: count-float (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("count-float")))
Test("terminal explicit SendInput: receipt-count (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("receipt-count")))
Test("terminal explicit SendInput: receipt-replace (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("receipt-replace")))
Test("terminal explicit SendInput: attempt-replace (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("attempt-replace")))
Test("terminal explicit SendInput: attempt-id (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("attempt-id")))
Test("terminal explicit SendInput: handle-clone (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("handle-clone")))
Test("terminal explicit SendInput: handle-fields (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("handle-fields")))
Test("terminal explicit SendInput: record-remove (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("record-remove")))
Test("terminal explicit SendInput: record-replace (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("record-replace")))
Test("terminal explicit SendInput: emit-byte-0 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-0")))
Test("terminal explicit SendInput: emit-byte-1 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-1")))
Test("terminal explicit SendInput: emit-byte-2 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-2")))
Test("terminal explicit SendInput: emit-byte-3 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-3")))
Test("terminal explicit SendInput: emit-byte-4 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-4")))
Test("terminal explicit SendInput: emit-byte-5 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-5")))
Test("terminal explicit SendInput: emit-byte-6 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-6")))
Test("terminal explicit SendInput: emit-byte-7 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-7")))
Test("terminal explicit SendInput: emit-byte-8 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-8")))
Test("terminal explicit SendInput: emit-byte-9 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-9")))
Test("terminal explicit SendInput: emit-byte-10 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-10")))
Test("terminal explicit SendInput: emit-byte-11 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-11")))
Test("terminal explicit SendInput: emit-byte-12 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-12")))
Test("terminal explicit SendInput: emit-byte-13 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-13")))
Test("terminal explicit SendInput: emit-byte-14 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-14")))
Test("terminal explicit SendInput: emit-byte-15 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-15")))
Test("terminal explicit SendInput: emit-byte-16 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-16")))
Test("terminal explicit SendInput: emit-byte-17 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-17")))
Test("terminal explicit SendInput: emit-byte-18 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-18")))
Test("terminal explicit SendInput: emit-byte-19 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-19")))
Test("terminal explicit SendInput: emit-byte-20 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-20")))
Test("terminal explicit SendInput: emit-byte-21 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-21")))
Test("terminal explicit SendInput: emit-byte-22 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-22")))
Test("terminal explicit SendInput: emit-byte-23 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-23")))
Test("terminal explicit SendInput: emit-byte-24 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-24")))
Test("terminal explicit SendInput: emit-byte-25 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-25")))
Test("terminal explicit SendInput: emit-byte-26 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-26")))
Test("terminal explicit SendInput: emit-byte-27 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-27")))
Test("terminal explicit SendInput: emit-byte-28 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-28")))
Test("terminal explicit SendInput: emit-byte-29 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-29")))
Test("terminal explicit SendInput: emit-byte-30 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-30")))
Test("terminal explicit SendInput: emit-byte-31 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-31")))
Test("terminal explicit SendInput: emit-byte-32 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-32")))
Test("terminal explicit SendInput: emit-byte-33 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-33")))
Test("terminal explicit SendInput: emit-byte-34 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-34")))
Test("terminal explicit SendInput: emit-byte-35 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-35")))
Test("terminal explicit SendInput: emit-byte-36 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-36")))
Test("terminal explicit SendInput: emit-byte-37 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-37")))
Test("terminal explicit SendInput: emit-byte-38 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-38")))
Test("terminal explicit SendInput: emit-byte-39 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-39")))
Test("terminal explicit SendInput: emit-byte-40 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-40")))
Test("terminal explicit SendInput: emit-byte-41 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-41")))
Test("terminal explicit SendInput: emit-byte-42 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-42")))
Test("terminal explicit SendInput: emit-byte-43 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-43")))
Test("terminal explicit SendInput: emit-byte-44 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-44")))
Test("terminal explicit SendInput: emit-byte-45 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-45")))
Test("terminal explicit SendInput: emit-byte-46 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-46")))
Test("terminal explicit SendInput: emit-byte-47 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-47")))
Test("terminal explicit SendInput: emit-byte-48 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-48")))
Test("terminal explicit SendInput: emit-byte-49 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-49")))
Test("terminal explicit SendInput: emit-byte-50 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-50")))
Test("terminal explicit SendInput: emit-byte-51 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-51")))
Test("terminal explicit SendInput: emit-byte-52 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-52")))
Test("terminal explicit SendInput: emit-byte-53 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-53")))
Test("terminal explicit SendInput: emit-byte-54 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-54")))
Test("terminal explicit SendInput: emit-byte-55 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-55")))
Test("terminal explicit SendInput: emit-byte-56 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-56")))
Test("terminal explicit SendInput: emit-byte-57 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-57")))
Test("terminal explicit SendInput: emit-byte-58 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-58")))
Test("terminal explicit SendInput: emit-byte-59 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-59")))
Test("terminal explicit SendInput: emit-byte-60 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-60")))
Test("terminal explicit SendInput: emit-byte-61 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-61")))
Test("terminal explicit SendInput: emit-byte-62 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-62")))
Test("terminal explicit SendInput: emit-byte-63 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-63")))
Test("terminal explicit SendInput: emit-byte-64 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-64")))
Test("terminal explicit SendInput: emit-byte-65 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-65")))
Test("terminal explicit SendInput: emit-byte-66 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-66")))
Test("terminal explicit SendInput: emit-byte-67 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-67")))
Test("terminal explicit SendInput: emit-byte-68 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-68")))
Test("terminal explicit SendInput: emit-byte-69 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-69")))
Test("terminal explicit SendInput: emit-byte-70 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-70")))
Test("terminal explicit SendInput: emit-byte-71 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-71")))
Test("terminal explicit SendInput: emit-byte-72 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-72")))
Test("terminal explicit SendInput: emit-byte-73 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-73")))
Test("terminal explicit SendInput: emit-byte-74 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-74")))
Test("terminal explicit SendInput: emit-byte-75 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-75")))
Test("terminal explicit SendInput: emit-byte-76 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-76")))
Test("terminal explicit SendInput: emit-byte-77 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-77")))
Test("terminal explicit SendInput: emit-byte-78 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-78")))
Test("terminal explicit SendInput: emit-byte-79 (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("emit-byte-79")))
Test("terminal explicit SendInput: no automatic sender choice (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputSelectionCase))
Test("terminal explicit SendInput: bounded native API rejects invalid arguments (todo49-explicit-sendinput)", _LNTOC_SendInputNativeBoundsCase)

for _LNTOC_SendFamilyIndex, _LNTOC_SendFamily in [
	[0xA2,0x01D,1], [0xA3,0x11D,2], [0xA4,0x038,4], [0xA5,0x138,8],
	[0xA0,0x02A,16], [0xA1,0x036,32], [0x5B,0x15B,64], [0x5C,0x15C,128]] {
	for _LNTOC_SendAxis in [1,2] {
		for _LNTOC_SendOrigin in [1,2] {
			for _LNTOC_SendEdge in [[0,0],[0,1],[1,0]]
				Test("terminal explicit SendInput: zero natural " . _LNTOC_SendFamilyIndex
					. ":axis" . _LNTOC_SendAxis . ":origin" . _LNTOC_SendOrigin
					. ":up" . _LNTOC_SendEdge[1] . ":repeat" . _LNTOC_SendEdge[2]
					. " (todo49-explicit-sendinput)",
					_LNTOC_WithState.Bind(_LNTOC_SendInputNaturalCase.Bind(_LNTOC_SendFamily,
						_LNTOC_SendAxis, _LNTOC_SendOrigin, _LNTOC_SendEdge[1],
						_LNTOC_SendEdge[2], _LNTOC_SendFamilyIndex)))
		}
	}
}

Test("terminal explicit SendInput: record-handle (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("record-handle")))

Test("terminal explicit SendInput: record-handle-remove (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("record-handle-remove")))

Test("terminal explicit SendInput: record-tuple-remove (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("record-tuple-remove")))

Test("terminal explicit SendInput: record-all-remove (todo49-explicit-sendinput)", _LNTOC_WithState.Bind(_LNTOC_SendInputVector.Bind("record-all-remove")))
