; static/drivers/autohotkey/lib/registry.ahk

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




; =============================================
; =============================================
; ======= 1/ Constants ========================
; =============================================
; =============================================

; Sentinel returned by Reg_Read when the key or value is absent.
global REG_NOT_FOUND := "__REG_NOT_FOUND__"




; =============================================
; =============================================
; ======= 2/ Read Operations ==================
; =============================================
; =============================================

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
		val := RegRead(keyPath, valueName, "REG_BINARY")
		return val
	} catch as e {
		LoggerDebug("registry", "Reg_ReadBinary failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return Buffer(0)
	}
}




; =============================================
; =============================================
; ======= 3/ Write Operations =================
; =============================================
; =============================================

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
		LoggerDebug("registry", "Reg_WriteBinary: {1}\{2} (%u bytes).", keyPath, valueName, buf.Size)
		return true
	} catch as e {
		LoggerError("registry", "Reg_WriteBinary failed — {1}\{2}: {3}", keyPath, valueName, e.Message)
		return false
	}
}




; =============================================
; =============================================
; ======= 4/ Delete Operations ================
; =============================================
; =============================================

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
		if (e.Extra = 2)
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
		if (e.Extra = 2)
			return true
		LoggerError("registry", "Reg_DeleteKey failed — {1}: {2}", keyPath, e.Message)
		return false
	}
}




; =============================================
; =============================================
; ======= 5/ Enumeration ======================
; =============================================
; =============================================

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
			results.Push({ name: A_LoopRegName, type: A_LoopRegType, data: RegRead() })
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
	try {
		Loop Reg, keyPath, "K" {
			return true
		}
		; No error thrown but nothing found — key exists but has no sub-keys
		; (which is still a valid key). Use a direct RegRead as a probe.
		RegRead(keyPath, "")
		return true
	} catch as e {
		; ERROR_FILE_NOT_FOUND (2) or ERROR_PATH_NOT_FOUND (3) = key absent.
		if (e.Extra = 2 or e.Extra = 3)
			return false
		; Any other error: key may exist but is inaccessible.
		LoggerDebug("registry", "Reg_KeyExists probe error — {1}: {2}", keyPath, e.Message)
		return false
	}
}
