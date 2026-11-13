; tests/fixtures/layouts/row_host_character.ahk

; Computes the host layout's one-key character without changing its dead-key
; state (ToUnicodeEx flag4 on supported Windows). Used only by native probes.
_LRN_HostCharacter(Vk, Shift, Hkl) {
	State := Buffer(256, 0), Text := Buffer(8, 0)
	if Shift
		NumPut("UChar", 0x80, State, 0x10)
	if GetKeyState("CapsLock", "T")
		NumPut("UChar", 1, State, 0x14)
	Count := DllCall("ToUnicodeEx", "UInt", Vk, "UInt", 0x10, "Ptr", State,
		"Ptr", Text, "Int", 4, "UInt", 4, "Ptr", Hkl, "Int")
	if Count != 1
		throw Error("The native letter probe requires one host-layout UTF-16 character without a pending dead key.")
	return StrGet(Text, Count, "UTF-16")
}
