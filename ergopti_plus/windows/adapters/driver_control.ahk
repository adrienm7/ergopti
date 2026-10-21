; adapters/driver_control.ahk

; ==============================================================================
; MODULE: Local Driver Control Native Adapter
; DESCRIPTION:
; Owns the two Win32 boundaries of the local reload command: the registered
; window message that rings the driver, and the system random generator that
; makes the session token. infra/driver_control.ahk holds the policy.
; ==============================================================================

/**
 * Registers the session-wide window message named by the shared declaration.
 * @param {String} Name Message name from driver_control.json.
 * @returns {Integer} A message in the registered range.
 */
DriverControl_RegisterMessage(Name) {
	if !(Name is String) || Name == ""
		throw ValueError("The driver control message needs a name.")
	Message := DllCall("User32\RegisterWindowMessageW", "Str", Name, "UInt")
	if !Message
		throw OSError(A_LastError, -1, "The driver control message could not be registered.")
	return Message
}

/**
 * Returns lowercase hexadecimal digits from the system random generator.
 * @param {Integer} Digits Even number of digits.
 * @returns {String}
 */
DriverControl_RandomHex(Digits) {
	if !(Digits is Integer) || Digits <= 0 || Mod(Digits, 2) != 0
		throw ValueError("The driver control token needs an even number of digits.")
	Bytes := Buffer(Digits // 2)
	; BCRYPT_USE_SYSTEM_PREFERRED_RNG
	if DllCall("bcrypt\BCryptGenRandom", "Ptr", 0, "Ptr", Bytes, "UInt", Bytes.Size, "UInt", 2, "UInt") != 0
		throw OSError(A_LastError, -1, "The driver control token could not be generated.")
	Hex := ""
	loop Bytes.Size
		Hex .= Format("{:02x}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Hex
}
