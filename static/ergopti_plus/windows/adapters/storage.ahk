; adapters/storage.ahk

; ==============================================================================
; MODULE: Storage Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the Storage port contract. Uses the Windows Registry
; under HKCU\Software\Ergopti\Storage as the persistent key-value store.
; Wraps the Reg_* helper functions (loaded by run_all.ahk via infra/registry.ahk)
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
; @return {Boolean} True on success, false on error.
ST_Set(Key, Value) {
	try {
		Reg_WriteString(STORAGE_REG_BASE, Key, String(Value))
		return true
	} catch {
		return false
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

; Deletes a value from the registry. Reg_DeleteValue itself already treats a
; missing value as success (idempotent delete); only a genuine failure (e.g.
; permission denied) returns false, honouring the Storage port's
; error_behavior=return_false contract.
; @param Key {String} The value name to remove under STORAGE_REG_BASE.
; @return {Boolean} True on success (including "already absent"), false on error.
ST_Delete(Key) {
	try {
		return Reg_DeleteValue(STORAGE_REG_BASE, Key)
	} catch as e {
		LoggerError("storage", "ST_Delete failed for '{1}': {2}.", Key, e.Message)
		return false
	}
}

; Returns true if Key exists in the registry store, false if absent.
; @param Key {String} The value name to probe under STORAGE_REG_BASE.
; @return {Boolean} True on success, false on error.
ST_Has(Key) {
	try {
		local Result := Reg_Read(STORAGE_REG_BASE, Key, STORAGE_REG_NOT_FOUND)
		return Result != STORAGE_REG_NOT_FOUND ? true : false
	} catch {
		return false
	}
}

; Enumerates names while preserving the distinction between an empty store and
; an inaccessible one. The public keys() contract deliberately collapses both
; to [], but clear() must not mistake an access failure for successful work.
; @param Names {Array} Receives key name strings, or an empty Array on failure.
; @param EnumValuesFn {Func|Integer} Optional deterministic test boundary.
; @return {Boolean} True when registry enumeration completed, false on error.
_ST_EnumerateKeys(&Names, EnumValuesFn := 0) {
	Names := []
	try {
		Records := IsObject(EnumValuesFn)
			? EnumValuesFn.Call(STORAGE_REG_BASE)
			: Reg_EnumValues(STORAGE_REG_BASE)
		for Rec in Records
			Names.Push(Rec.name)
		return true
	} catch as Err {
		LoggerError("storage", "Registry enumeration failed: {1}.", Err.Message)
		return false
	}
}

; Returns an Array of all value names currently stored under STORAGE_REG_BASE.
; @return {Array} Array of key name strings; empty Array on error or no keys.
ST_Keys() {
	_ST_EnumerateKeys(&Names)
	return Names
}

; Internal clear operation with injectable registry boundaries for deterministic
; failure coverage. Deletion stops at the first error to limit partial work.
; @param EnumValuesFn {Func|Integer} Optional registry enumeration function.
; @param DeleteFn {Func|Integer} Optional key deletion function.
; @return {Boolean} True only when enumeration and every deletion succeeded.
_ST_ClearWith(EnumValuesFn := 0, DeleteFn := 0) {
	if !_ST_EnumerateKeys(&Keys, EnumValuesFn)
		return false
	for Key in Keys {
		Deleted := IsObject(DeleteFn) ? DeleteFn.Call(Key) : ST_Delete(Key)
		if !Deleted
			return false
	}
	return true
}

; Deletes every value under STORAGE_REG_BASE.
; Enumeration failure is distinct from a valid empty store and fails closed.
; @return {Boolean} True only when every key was deleted without error.
ST_Clear() {
	return _ST_ClearWith()
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_STORAGE := Map(
    "set",    ST_Set,
    "get",    ST_Get,
    "delete", ST_Delete,
    "has",    ST_Has,
    "keys",   ST_Keys,
    "clear",  ST_Clear,
)
