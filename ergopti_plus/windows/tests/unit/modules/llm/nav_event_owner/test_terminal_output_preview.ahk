; tests/unit/modules/llm/nav_event_owner/test_terminal_output_preview.ahk

; ==============================================================================
; MODULE: Terminal Output Preview Tests
; DESCRIPTION:
; Independent literal UTF-16 receipts exercise the actual canonical KLE adapter
; through ports. These AHK cases require Windows execution; no mocked boundary
; is evidence of SendInput delivery, native hook ordering or physical typing.
; ==============================================================================

#Requires AutoHotkey v2.0

_LNTOP_Peek(State, Token, Index, Receipt) {
	State.Peeks += 1
	AssertEqual(901, Token)
	AssertEqual(0, Index)
	Source := _LNTR_Receipt()
	DllCall("Kernel32\RtlMoveMemory", "Ptr", Receipt, "Ptr", Source, "UPtr", 184)
	return 0
}

_LNTOP_Preview(State, Owner, Token, Sequence, Index, Text, Length, Summary, Units, Capacity) {
	State.Calls += 1
	AssertEqual(901, Token)
	AssertEqual(3, Sequence)
	AssertEqual(0, Index)
	AssertEqual(2048, Capacity)
	AssertEqual(State.Expected.Length, Length)
	Loop Length
		AssertEqual(State.Expected[A_Index], NumGet(Text, (A_Index - 1) * 2, "UShort"),
			"the native boundary receives the literal captured canonical UTF-16")
	if !(State.Status is Integer) || State.Status != 0
		return State.Status
	NumPut("UInt64", Owner, "UInt64", Token, "UInt64", Sequence, "UInt64", 7, Summary, 0)
	NumPut("UInt", Length * 2, Summary, 32)
	NumPut("Int", 1, Summary, 40)
	Loop Length {
		Offset := (A_Index - 1) * 20
		NumPut("UShort", State.Expected[A_Index], Units, Offset + 4)
		NumPut("UChar", 1, Units, Offset + 6)
		NumPut("UShort", State.Expected[A_Index], Units, Offset + 14)
		NumPut("UChar", 1, "UChar", 1, Units, Offset + 16)
	}
	if State.Mutation == "dispatch"
		NumPut("UChar", 1, Summary, 44)
	else if State.Mutation == "owner"
		NumPut("UInt64", Owner + 1, Summary, 0)
	else if State.Mutation == "sequence"
		NumPut("UInt64", Sequence + 1, Summary, 16)
	else if State.Mutation == "count"
		NumPut("UInt", Length * 2 + 2, Summary, 32)
	else if State.Mutation == "status"
		NumPut("Int", 0, Summary, 40)
	else if State.Mutation == "reserved"
		NumPut("UInt", 1, Summary, 36)
	else if State.Mutation == "unit_reserved"
		NumPut("UChar", 1, Units, 9)
	else if State.Mutation == "unicode"
		NumPut("UShort", 0x7A, Units, 4)
	else if State.Mutation == "up"
		NumPut("UChar", 0, Units, 17)
	return 0
}

_LNTOP_State(Expected) {
	Source := _LNTR_PortState()
	AssertTrue(LLM_NavEventOwner_RefreshTerminalRoutes(Source.Port))
	State := {Expected: Expected, Status: 0, Calls: 0, Peeks: 0, Mutation: ""}
	State.Port := Map("peek_terminal_route", _LNTOP_Peek.Bind(State),
		"preview_terminal_output", _LNTOP_Preview.Bind(State))
	return State
}

_LNTOP_AsciiCase() {
	State := _LNTOP_State([0x61])
	Preview := LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port)
	AssertEqual(1, State.Calls)
	AssertEqual(2, Preview["unit_count"])
	AssertEqual(0x61, Preview["units"][1]["utf16"])
	AssertEqual(0, Preview["units"][1]["key_up"])
	AssertEqual(0x61, Preview["units"][2]["utf16"])
	AssertEqual(1, Preview["units"][2]["key_up"])
	AssertFalse(Preview["dispatchable"])
	AssertFalse(Preview["delivery_enabled"])
	AssertFalse(Preview["cohort_complete"])
}

_LNTOP_SupplementaryCase() {
	_LNTR_LoadFixture(Chr(0x1F600))
	State := _LNTOP_State([0xD83D, 0xDE00])
	Preview := LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port)
	AssertEqual(4, Preview["unit_count"])
	AssertEqual(0xD83D, Preview["units"][1]["utf16"])
	AssertEqual(0xD83D, Preview["units"][2]["utf16"])
	AssertEqual(0xDE00, Preview["units"][3]["utf16"])
	AssertEqual(0xDE00, Preview["units"][4]["utf16"])
	AssertFalse(Preview["dispatchable"])
}

_LNTOP_EmptyCase() {
	_LNTR_LoadFixture("")
	State := _LNTOP_State([])
	AssertThrows(() => LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port),
		"the canonical resolver excludes an empty mapping from its text subset")
	AssertEqual(0, State.Calls)
}

_LNTOP_MalformedCase() {
	State := _LNTOP_State([0x61])
	for Mutation in ["dispatch", "owner", "sequence", "count", "status", "reserved",
			"unit_reserved", "unicode", "up"] {
		State.Mutation := Mutation
		AssertThrows(() => LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port),
			"a malformed or delivering preview must be rejected: " . Mutation)
	}
	AssertEqual(9, State.Calls)
}

_LNTOP_RefusalCase() {
	State := _LNTOP_State([0x61])
	for Status in [2, 4, 8] {
		State.Status := Status
		AssertEqual(0, LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port),
			"a retired or moved native edge cannot authorize a cached preview")
	}
	State.Status := "0"
	AssertThrows(() => LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port))
	State.Status := 1
	AssertThrows(() => LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port))
	AssertEqual(5, State.Calls)
	AssertThrows(() => LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "acute", State.Port),
		"an unconverted composition cannot reach the native planning boundary")
	AssertEqual(5, State.Calls)
}

_LNTOP_RetainedModelCase() {
	global KLE_State
	State := _LNTOP_State([0x61])
	_LNTR_LoadFixture("z")
	KLE_State := "unrelated-live-state"
	Preview := LLM_NavEventOwner_PreviewTerminalOutput(901, 0, "none", State.Port)
	AssertEqual(0x61, Preview["units"][1]["utf16"],
		"the model which owns the queued recipe supplies its canonical output")
	AssertEqual("unrelated-live-state", KLE_State,
		"preview cannot update global composition")
}

Test("terminal output preview: canonical ASCII preserves guarded units (todo49-output-preview)",
	(*) => _LNTR_WithState(_LNTOP_AsciiCase))
Test("terminal output preview: supplementary Unicode keeps literal UTF-16 pairs (todo49-output-preview)",
	(*) => _LNTR_WithState(_LNTOP_SupplementaryCase))
Test("terminal output preview: unowned empty mapping cannot reach delivery (todo49-output-preview)",
	(*) => _LNTR_WithState(_LNTOP_EmptyCase))
Test("terminal output preview: malformed receipts and dispatch permission are refused (todo49-output-preview)",
	(*) => _LNTR_WithState(_LNTOP_MalformedCase))
Test("terminal output preview: stale native edges and composition retain refusal (todo49-output-preview)",
	(*) => _LNTR_WithState(_LNTOP_RefusalCase))
Test("terminal output preview: retained model ignores live layout and state changes (todo49-output-preview)",
	(*) => _LNTR_WithState(_LNTOP_RetainedModelCase))
