; adapters/storage.ahk

; ==============================================================================
; MODULE: Storage Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Storage port contract. Uses the Windows Registry
; under HKCU\Software\Ergopti\Storage as the persistent key-value store.
; Wraps the Reg_* helper functions (loaded by run_all.ahk via lib/registry.ahk)
; behind the canonical ST_* interface so domain modules persist data without
; coupling to Registry-specific APIs.
;
; NAMING CONVENTION:
; Port method  -> AHK name mapping:
;   set(key, value)          -> ST_Set(Key, Value)
;   get(key, defaultValue)   -> ST_Get(Key, DefaultValue)
;   delete(key)              -> ST_Delete(Key)
;   has(key)                 -> ST_Has(Key)
;   keys()                   -> ST_Keys()
;   clear()                  -> ST_Clear()
;
; STORAGE NOTES:
; All values are stored as REG_SZ strings. Callers are responsible for
; converting types on retrieval. The sentinel "__NOT_FOUND__" is used as
; the fallback value for Reg_Read so absent keys can be distinguished from
; keys whose stored value is an empty string.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Registry base path for all Ergopti persistent storage entries
global STORAGE_REG_BASE := "HKCU\Software\Ergopti\Storage"

; Sentinel returned by Reg_Read when a value does not exist in the registry
global STORAGE_REG_NOT_FOUND := "__NOT_FOUND__"





; ====================================
; ====================================
; ======= 2/ Adapter Functions =======
; ====================================
; ====================================

; Writes Value to the registry under Key, converting it to a string first.
; @param Key   {String} The value name to write under STORAGE_REG_BASE.
; @param Value {Any}    The value to persist; coerced to String via String().
; @return {Integer} 1 on success, 0 on any error.
ST_Set(Key, Value) {
	try {
		Reg_WriteString(STORAGE_REG_BASE, Key, String(Value))
		return 1
	} catch {
		return 0
	}
}

; Reads a value from the registry. Returns DefaultValue when the key is absent.
; @param Key          {String} The value name to read under STORAGE_REG_BASE.
; @param DefaultValue {Any}    Returned when the key does not exist.
; @return {String|Any} The stored string, or DefaultValue if absent.
ST_Get(Key, DefaultValue) {
	try {
		local Result := Reg_Read(STORAGE_REG_BASE, Key, STORAGE_REG_NOT_FOUND)
		; Reg_Read returns the sentinel when the value name is not present
		if Result = STORAGE_REG_NOT_FOUND
			return DefaultValue
		return Result
	} catch {
		return DefaultValue
	}
}

; Deletes a value from the registry. Returns 1 even when the key is absent.
; @param Key {String} The value name to remove under STORAGE_REG_BASE.
; @return {Integer} 1 always (deletion of absent keys is a no-op success).
ST_Delete(Key) {
	try {
		Reg_DeleteValue(STORAGE_REG_BASE, Key)
		return 1
	} catch {
		; Key absent or already deleted - contract treats this as success
		return 1
	}
}

; Returns 1 if Key exists in the registry store, 0 if absent.
; @param Key {String} The value name to probe under STORAGE_REG_BASE.
; @return {Integer} 1 if present, 0 if absent.
ST_Has(Key) {
	try {
		local Result := Reg_Read(STORAGE_REG_BASE, Key, STORAGE_REG_NOT_FOUND)
		return Result != STORAGE_REG_NOT_FOUND ? 1 : 0
	} catch {
		return 0
	}
}

; Returns an Array of all value names currently stored under STORAGE_REG_BASE.
; @return {Array} Array of key name strings; empty Array on error or no keys.
ST_Keys() {
	try {
		return Reg_EnumValues(STORAGE_REG_BASE)
	} catch {
		return []
	}
}

; Deletes every value under STORAGE_REG_BASE by iterating ST_Keys().
; @return {Integer} 1 on success, 0 if iteration itself throws.
ST_Clear() {
	try {
		local Keys := ST_Keys()
		for K in Keys {
			ST_Delete(K)
		}
		return 1
	} catch {
		return 0
	}
}
