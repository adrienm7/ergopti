; adapters/terminal_output_sendinput.ahk

; ==============================================================================
; MODULE: Explicit Terminal SendInput Primitive
; DESCRIPTION:
; Receives only an authenticated INPUT40 attempt and reports one exact inserted
; prefix to the existing packet consumer. There is no default backend, native
; cohort activation, automatic sender, independent ACK or retirement policy.
; Native receiving and backend selection remain Windows qualification work.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Creates an explicit callback retaining the original holder and chosen sender. */
LLM_NavEventOwner_TerminalOutputSendInputEmitter(Handle, SendInputFn) {
	if !HasMethod(SendInputFn, "Call")
		throw ValueError("Terminal SendInput requires an explicitly selected sender callback.")
	Record := _LLM_TerminalOutputRecord(Handle)
	if !IsObject(Record) || Record["unknown"]
		throw ValueError("Terminal SendInput requires an existing original custody record.")
	Authority := _LLM_TerminalOutputCaptureAuthority(Handle, Record)
	return _LLM_TerminalOutputSendInputOwned.Bind(Handle, Record, SendInputFn, Authority)
}

/** Uses detached bytes without granting the sender access to its private witness. */
_LLM_TerminalOutputSendInputOwned(Handle, Record, SendInputFn, Authority, Receipt) {
	try {
		_LLM_TerminalOutputRequireRecord(Handle, Record, Authority)
		LLM_NavEventOwner_ValidateTerminalOutputPackets(Handle, Receipt, Authority)
		Attempt := Record["owned_attempt"]
		Count := Record["attempt_count"]
		if !(Count is Integer) || Count < 1 || Count > 2048
			throw ValueError("Terminal SendInput requires a bounded nonempty owned suffix.")
		ByteCount := Count * 40
		Key := _LLM_TerminalOutputKey(Record)
		Witness := Buffer(ByteCount, 0)
		_LLM_TerminalOutputSendInputIdentity(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Authority)
		; No callback observes the copy boundary or private witness. Still validate
		; the detached canonical bytes after the first copy, before publication.
		DllCall("RtlMoveMemory", "Ptr", Witness.Ptr, "Ptr", Record["packet_private"].Ptr, "UPtr", ByteCount)
		_LLM_TerminalOutputSendInputIdentity(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Authority)
		_LLM_TerminalOutputValidateNativePackets(Witness, Record)
		EmittedBytes := Buffer(ByteCount, 0)
		DllCall("RtlMoveMemory", "Ptr", EmittedBytes.Ptr, "Ptr", Witness.Ptr, "UPtr", ByteCount)
		_LLM_TerminalOutputSendInputBytes(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Witness, EmittedBytes, Authority)
		Accepted := SendInputFn.Call(Count, EmittedBytes, 40)
		_LLM_TerminalOutputSendInputBytes(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Witness, EmittedBytes, Authority)
		if !(Accepted is Integer) || Accepted < 0 || Accepted > Count
			throw ValueError("Terminal SendInput did not return an exact inserted prefix.")
		return Accepted
	} catch as Err {
		; The original packet consumer owns uncertain output and cancellation.
		; Preserve its original holder even if the callback removed the registry.
		_LLM_TerminalOutputMarkUnknown(Record, Authority)
		throw Err
	}
}

/** Pins custody and copy bounds before every use of retained packet memory. */
_LLM_TerminalOutputSendInputIdentity(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Authority) {
	if Record.Get("handle", 0) != Handle
		throw ValueError("Terminal SendInput changed its retained original handle.")
	_LLM_TerminalOutputRequireRecord(Handle, Record, Authority)
	_LLM_TerminalOutputValidateCopyIdentity(Handle, Record, Attempt, Key, ByteCount, Authority)
	LLM_NavEventOwner_ValidateTerminalOutputPackets(Handle, Receipt, Authority)
	if !(Record["attempt_count"] is Integer) || Record["attempt_count"] != Count
			|| Record["packet_private"].Size != ByteCount || Record["packet_public"].Size != ByteCount
		throw ValueError("Terminal SendInput changed the original attempt bounds.")
}

/** The sender cannot change any byte, identity or bound and still authorize ACK. */
_LLM_TerminalOutputSendInputBytes(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Witness, EmittedBytes, Authority) {
	_LLM_TerminalOutputSendInputIdentity(Handle, Record, Attempt, Receipt, Key, Count, ByteCount, Authority)
	if Witness.Size != ByteCount || EmittedBytes.Size != ByteCount
		throw ValueError("Terminal SendInput changed detached buffer bounds.")
	_LLM_TerminalOutputValidateNativePackets(Witness, Record)
	_LLM_TerminalOutputValidateNativePackets(EmittedBytes, Record)
	Loop ByteCount {
		Byte := NumGet(Witness, A_Index - 1, "UChar")
		if NumGet(EmittedBytes, A_Index - 1, "UChar") != Byte
				|| NumGet(Record["packet_private"], A_Index - 1, "UChar") != Byte
			throw ValueError("Terminal SendInput changed an immutable detached packet byte.")
	}
}

/** A caller must explicitly select this native primitive after target admission. */
_LLM_TerminalOutputSendInputNative(Count, Packets, PacketSize) {
	if A_PtrSize != 8 || !(Count is Integer) || Count < 0 || Count > 2048
			|| !(PacketSize is Integer) || PacketSize != 40
			|| !(Packets is Buffer) || Packets.Size != Count * PacketSize
		throw ValueError("SendInput requires exact bounded 64-bit INPUT40 arguments.")
	if Count == 0
		return 0
	return DllCall("User32\SendInput", "UInt", Count, "Ptr", Packets.Ptr, "Int", PacketSize, "UInt")
}
