; infra/registry.ahk

; ==============================================================================
; MODULE: Windows Registry Abstraction
; DESCRIPTION:
; Thin, testable wrapper around AHK v2's built-in RegRead / RegWrite / RegDelete
; functions. Centralises all registry access so callers never write raw RegRead()
; calls scattered through the codebase. Every function is wrapped in a try/catch
; that logs the error via LoggerError() and returns a typed sentinel on failure.
;
; FEATURES & RATIONALE:
; 1. Fail-safe reads: Reg_Read returns a default value (empty string or caller-
;    supplied fallback) instead of throwing on missing keys.
; 2. Consistent logging: all errors are logged at ERROR level with the full key
;    path so failures are diagnosable from the log alone.
; 3. Typed writes: Reg_WriteDword, Reg_WriteString, and Reg_WriteBinary cover
;    the three value types used across the codebase.
; 4. Subtree enumeration: Reg_EnumValues returns all value names + data under a
;    given key, used by keylogger_av_state to iterate CloudStore entries.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================






; ==================================
; ==================================
; ======= 2/ Read Operations =======
; ==================================
; ==================================

; Reads a registry string or expanded-string value.
; Returns the value on success, or `fallback` (default "") when the key or
; value does not exist or an error occurs.
;
; Param keyPath   - Full registry path (e.g. "HKCU\Software\…").
; Param valueName - Value name inside the key.
; Param fallback  - Value returned on any failure (default "").
; Returns string  - The registry value or the fallback.
Reg_Read(keyPath, valueName, fallback := "") {
	try {
		val := RegRead(keyPath, valueName)
		return val
	} catch as e {
		LoggerDebug("registry", "Reg_Read failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return fallback
	}
}

; Reads a registry value while keeping success separate from its data. Callers
; which accept every possible REG_SZ string cannot use an in-band fallback
; sentinel to distinguish a missing value from stored content.
;
; Param keyPath   - Full registry path.
; Param valueName - Value name inside the key.
; Param value     - Receives the registry value on success, or "" on failure.
; Returns boolean - True only when RegRead completed successfully.
Reg_TryRead(keyPath, valueName, &value) {
	value := ""
	try {
		value := RegRead(keyPath, valueName)
		return true
	} catch as e {
		LoggerDebug("registry", "Reg_TryRead failed — {1}\{2}: {3}",
			keyPath, valueName, e.Message)
		return false
	}
}


; Reads a REG_DWORD value as an integer.
; Returns the integer on success, or `fallback` (default 0) on any failure.
;
; Param keyPath   - Full registry path.
; Param valueName - Value name inside the key.
; Param fallback  - Integer returned on failure (default 0).
; Returns integer - The DWORD value or the fallback.
Reg_ReadDword(keyPath, valueName, fallback := 0) {
	try {
		val := RegRead(keyPath, valueName)
		return Integer(val)
	} catch as e {
		LoggerDebug("registry", "Reg_ReadDword failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return fallback
	}
}


; Reads a REG_BINARY value as raw bytes (Buffer object).
; Returns a Buffer on success, or an empty Buffer on failure.
;
; Param keyPath   - Full registry path.
; Param valueName - Value name inside the key.
; Returns Buffer  - The raw binary data, or an empty Buffer.
Reg_ReadBinary(keyPath, valueName) {
	try {
		val := RegRead(keyPath, valueName)
		return val
	} catch as e {
		LoggerDebug("registry", "Reg_ReadBinary failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return Buffer(0)
	}
}





; ===================================
; ===================================
; ======= 3/ Write Operations =======
; ===================================
; ===================================

; Writes a REG_DWORD value.
; Returns true on success, false on failure.
;
; Param keyPath   - Full registry path (created if absent).
; Param valueName - Value name to write.
; Param value     - Integer to store as DWORD.
; Returns boolean - True on success, false on error.
Reg_WriteDword(keyPath, valueName, value) {
	try {
		RegWrite(value, "REG_DWORD", keyPath, valueName)
		LoggerDebug("registry", "Reg_WriteDword: {1}\{2} = {3}.", keyPath, valueName, value)
		return true
	} catch as e {
		LoggerError("registry", "Reg_WriteDword failed — {1}\{2} = {3}: {4}", keyPath, valueName, value, e.Message)
		return false
	}
}


; Writes a REG_SZ (string) value.
; Returns true on success, false on failure.
;
; Param keyPath   - Full registry path (created if absent).
; Param valueName - Value name to write.
; Param value     - String to store.
; Returns boolean - True on success, false on error.
Reg_WriteString(keyPath, valueName, value) {
	try {
		RegWrite(value, "REG_SZ", keyPath, valueName)
		LoggerDebug("registry", "Reg_WriteString: {1}\{2} = '{3}'.", keyPath, valueName, value)
		return true
	} catch as e {
		LoggerError("registry", "Reg_WriteString failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return false
	}
}


; Writes a REG_EXPAND_SZ value (string with environment variable references).
; Returns true on success, false on failure.
;
; Param keyPath   - Full registry path (created if absent).
; Param valueName - Value name to write.
; Param value     - String to store (environment variables are NOT expanded by AHK).
; Returns boolean - True on success, false on error.
Reg_WriteExpandString(keyPath, valueName, value) {
	try {
		RegWrite(value, "REG_EXPAND_SZ", keyPath, valueName)
		LoggerDebug("registry", "Reg_WriteExpandString: {1}\{2}.", keyPath, valueName)
		return true
	} catch as e {
		LoggerError("registry", "Reg_WriteExpandString failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return false
	}
}


; Writes a REG_BINARY value from a Buffer object.
; Returns true on success, false on failure.
;
; Param keyPath   - Full registry path (created if absent).
; Param valueName - Value name to write.
; Param buf       - Buffer object containing the raw bytes.
; Returns boolean - True on success, false on error.
Reg_WriteBinary(keyPath, valueName, buf) {
	try {
		RegWrite(buf, "REG_BINARY", keyPath, valueName)
		LoggerDebug("registry", "Reg_WriteBinary: {1}\{2} ({3} bytes).", keyPath, valueName, buf.Size)
		return true
	} catch as e {
		LoggerError("registry", "Reg_WriteBinary failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return false
	}
}





; ====================================
; ====================================
; ======= 4/ Delete Operations =======
; ====================================
; ====================================

; Deletes a single registry value.
; Returns true on success (including when the value was already absent),
; false on unexpected errors.
;
; Param keyPath   - Full registry path.
; Param valueName - Value name to delete.
; Returns boolean - True on success or "not found", false on error.
Reg_DeleteValue(keyPath, valueName) {
	try {
		RegDelete(keyPath, valueName)
		LoggerDebug("registry", "Reg_DeleteValue: {1}\{2}.", keyPath, valueName)
		return true
	} catch as e {
		; 2 = ERROR_FILE_NOT_FOUND — treat as success (idempotent delete).
		; The Win32 error code lands in OSError's Number property, not Extra
		; (Extra is empty for RegDelete's OSError; confirmed empirically —
		; the old `e.Extra = 2` check never matched, so every not-found
		; delete fell through to the false/LoggerError path below despite
		; the docstring's "true on ... not found" contract).
		if (e.Number = 2)
			return true
		LoggerError("registry", "Reg_DeleteValue failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return false
	}
}


; Deletes an entire registry key and all its values and sub-keys.
; Returns true on success (including when the key was already absent).
;
; Param keyPath - Full registry path to delete.
; Returns boolean - True on success or "not found", false on error.
Reg_DeleteKey(keyPath) {
	try {
		RegDeleteKey(keyPath)
		LoggerDebug("registry", "Reg_DeleteKey: {1}.", keyPath)
		return true
	} catch as e {
		; 2 = ERROR_FILE_NOT_FOUND — treat as success (idempotent delete).
		; The Win32 error code lands in OSError's Number property, not Extra.
		if (e.Number = 2)
			return true
		LoggerError("registry", "Reg_DeleteKey failed — {1}: {2}", keyPath, e.Message)
		return false
	}
}





; ==============================
; ==============================
; ======= 5/ Enumeration =======
; ==============================
; ==============================

; Enumerates all values under a registry key.
; Returns an Array of objects: [ {name, type, data}, … ] in enumeration order.
; Returns an empty Array when the key does not exist or any error occurs.
;
; Param keyPath - Full registry path to enumerate.
; Returns Array - Array of {name: string, type: string, data: string} objects.
Reg_EnumValues(keyPath) {
	results := []
	try {
		Loop Reg, keyPath, "V" {
			; Wrap RegRead() individually — binary values (REG_BINARY, REG_MULTI_SZ)
			; can throw on some runners; skip the value rather than aborting the loop.
			local name := A_LoopRegName, type := A_LoopRegType
			try {
				local data := RegRead()
				results.Push({ name: name, type: type, data: data })
			} catch {
				results.Push({ name: name, type: type, data: "" })
			}
		}
	} catch as e {
		LoggerDebug("registry", "Reg_EnumValues failed — {1}: {2}", keyPath, e.Message)
	}
	return results
}


; Enumerates all sub-key names directly under a registry key.
; Returns an Array of strings (key names, not full paths).
; Returns an empty Array when the key does not exist.
;
; Param keyPath - Full registry path to enumerate.
; Returns Array - Array of sub-key name strings.
Reg_EnumSubKeys(keyPath) {
	results := []
	try {
		Loop Reg, keyPath, "K" {
			results.Push(A_LoopRegName)
		}
	} catch as e {
		LoggerDebug("registry", "Reg_EnumSubKeys failed — {1}: {2}", keyPath, e.Message)
	}
	return results
}


; Checks whether a registry key exists.
; Returns true when the key is present, false otherwise.
;
; Param keyPath - Full registry path to test.
; Returns boolean - True if the key exists.
Reg_KeyExists(keyPath) {
	; Content probes cannot distinguish an empty-but-existing key from an absent
	; one. Open the key itself with the minimum query right instead.
	Slash := InStr(keyPath, "\")
	RootName := (Slash > 0) ? SubStr(keyPath, 1, Slash - 1) : keyPath
	SubKey := (Slash > 0) ? SubStr(keyPath, Slash + 1) : ""
	Roots := Map("HKCU", 0x80000001, "HKEY_CURRENT_USER", 0x80000001,
		"HKLM", 0x80000002, "HKEY_LOCAL_MACHINE", 0x80000002,
		"HKCR", 0x80000000, "HKEY_CLASSES_ROOT", 0x80000000,
		"HKU", 0x80000003, "HKEY_USERS", 0x80000003,
		"HKCC", 0x80000005, "HKEY_CURRENT_CONFIG", 0x80000005)
	if !Roots.Has(RootName) {
		try LoggerWarn("registry", "Reg_KeyExists received an unknown registry root: {1}.", RootName)
		return false
	}
	Handle := 0
	Status := DllCall("Advapi32\RegOpenKeyExW", "Ptr", Roots[RootName], "WStr", SubKey,
		"UInt", 0, "UInt", 0x0001, "PtrP", &Handle, "UInt") ; KEY_QUERY_VALUE
	if (Status = 0) {
		try DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
		return true
	}
	if (Status = 2 or Status = 3)
		return false
	try LoggerWarn("registry", "Reg_KeyExists open error {1} for {2}.", Status, keyPath)
	return false
}
