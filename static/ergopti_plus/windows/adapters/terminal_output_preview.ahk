; adapters/terminal_output_preview.ahk

; ==============================================================================
; MODULE: Terminal Output Preview
; DESCRIPTION:
; Resolves an owned neutral KLE recipe and previews its exact immutable UTF-16
; output units through the authenticated native FIFO. This boundary never sends
; input, acknowledges a prefix, changes composition or enables partial cohorts.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Previews one captured neutral text DOWN using its retained canonical model.
 * @param {Integer} Token - Exact active terminal capture identity.
 * @param {Integer} Index - Zero-based FIFO index, authenticated again by sequence.
 * @param {String} State - Explicit neutral composition state.
 * @param {Map|Integer} Port - Optional native metadata and preview boundaries.
 * @returns {Map|Integer} A guarded diagnostic, or zero after native retirement.
 */
LLM_NavEventOwner_PreviewTerminalOutput(Token, Index, State, Port := 0) {
	global _LLM_NavEventOwnerTerminalRouteOwner
	Snapshot := LLM_NavEventOwner_PeekTerminalRoute(Token, Index, Port)
	if !(Snapshot is Map)
		return 0
	Step := LLM_NavEventOwner_StepTerminalRoute(Snapshot, State)
	Output := Step.Get("Output", 0)
	if !(Output is String) || StrLen(Output) > 1024
		throw ValueError("The terminal output exceeds the owned neutral subset.")
	Length := StrLen(Output)
	Text := Buffer((Length + 1) * 2, 0)
	StrPut(Output, Text, "UTF-16")
	Summary := Buffer(48, 0)
	Units := Buffer(2048 * 10, 0)
	Fn := _LLM_NavEventOwnerPortFn("preview_terminal_output", Port)
	Status := HasMethod(Fn, "Call")
		? Fn.Call(_LLM_NavEventOwnerTerminalRouteOwner, Token, Snapshot["sequence"],
			Index, Text, Length, Summary, Units, 2048)
		: _LLM_NavEventOwnerNativePreviewTerminalOutput(
			_LLM_NavEventOwnerTerminalRouteOwner, Token, Snapshot["sequence"],
			Index, Text, Length, Summary, Units, 2048)
	if !(Status is Integer)
		throw Error("Terminal output preview returned a malformed ACK.")
	if Status == 2 || Status == 4 || Status == 8
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status, "Terminal output preview")
	return _LLM_NavEventOwnerTerminalOutputDecode(Summary, Units, Text, Length, Snapshot)
}

/** Decodes literal output units while rejecting any dispatch permission. */
_LLM_NavEventOwnerTerminalOutputDecode(Summary, Units, Text, Length, Snapshot) {
	if !(Summary is Buffer) || Summary.Size != 48 || !(Units is Buffer)
			|| Units.Size != 20480 || !(Text is Buffer) || Text.Size != (Length + 1) * 2
			|| !(Length is Integer) || Length < 0 || Length > 1024
			|| !(Snapshot is Map)
		throw ValueError("The terminal output preview ABI is invalid.")
	Owner := NumGet(Summary, 0, "UInt64")
	Token := NumGet(Summary, 8, "UInt64")
	Sequence := NumGet(Summary, 16, "UInt64")
	PlanId := NumGet(Summary, 24, "UInt64")
	Count := NumGet(Summary, 32, "UInt")
	if Owner != Snapshot.Get("owner", 0) || Owner <= 0
			|| Token != Snapshot.Get("token", 0) || Token <= 0
			|| Sequence != Snapshot.Get("sequence", 0) || Sequence <= 0 || PlanId <= 0
			|| Count != Length * 2 || NumGet(Summary, 36, "UInt") != 0
			|| NumGet(Summary, 40, "Int") != 1 || NumGet(Summary, 44, "UChar") != 0
			|| NumGet(Summary, 45, "UChar") != 0 || NumGet(Summary, 46, "UChar") != 0
			|| NumGet(Summary, 47, "UChar") != 0
		throw ValueError("The terminal output preview ownership or guard is invalid.")
	Decoded := []
	Loop Count {
		Offset := (A_Index - 1) * 10
		Code := NumGet(Units, Offset + 4, "UShort")
		Up := NumGet(Units, Offset + 7, "UChar")
		if NumGet(Units, Offset, "UShort") != 0 || NumGet(Units, Offset + 2, "UShort") != 0
				|| NumGet(Units, Offset + 6, "UChar") != 1
				|| Up != Mod(A_Index - 1, 2) || NumGet(Units, Offset + 8, "UChar") != 0
				|| NumGet(Units, Offset + 9, "UChar") != 0
				|| Code != NumGet(Text, Floor((A_Index - 1) / 2) * 2, "UShort")
			throw ValueError("The preview differs from its canonical UTF-16 recipe.")
		Decoded.Push(Map("kind", 1, "utf16", Code, "key_up", Up, "repeat", 0))
	}
	return Map("owner", Owner, "token", Token, "sequence", Sequence, "plan_id", PlanId,
		"unit_count", Count, "units", Decoded, "planner_status", 1,
		"dispatchable", false, "delivery_enabled", false, "cohort_complete", false)
}

_LLM_NavEventOwnerNativePreviewTerminalOutput(Owner, Token, Sequence, Index,
		Text, Length, Summary, Units, Capacity) {
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_PreviewTerminalOutput"),
		"UInt64", Owner, "UInt64", Token, "UInt64", Sequence, "UInt", Index,
		"Ptr", Text, "UInt", Length, "Ptr", Summary, "Ptr", Units, "UInt", Capacity, "Int")
}
