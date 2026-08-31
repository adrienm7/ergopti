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
; Values are stored as versioned REG_SZ envelopes so strings, numbers, Maps,
; and Arrays retain their types. Untagged values written by older releases are
; still returned as strings. Reads use Reg_TryRead's out-of-band success receipt
; so every possible stored payload remains representable.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Registry base path for all Ergopti persistent storage entries
global STORAGE_REG_BASE := "HKCU\Software\Ergopti\Storage"
global STORAGE_VALUE_PREFIX := "__ERGOPTI_STORAGE_V1__:"





; ====================================
; ====================================
; ======= 2/ Adapter Functions =======
; ====================================
; ====================================

; Writes one supported Storage value to the registry under Key.
; @param Key   {String} The value name to write under STORAGE_REG_BASE.
; @param Value {String|Number|Map|Array} The value to persist.
; @return {Boolean} True on success, false on error.
ST_Set(Key, Value) {
	return _ST_SetWith(Key, Value, Reg_WriteString)
}

_ST_SetWith(Key, Value, WriteFn) {
	try {
		return WriteFn.Call(STORAGE_REG_BASE, Key, _ST_EncodeValue(Value))
	} catch {
		return false
	}
}

_ST_EncodeValue(Value) {
	global STORAGE_VALUE_PREFIX
	if Value is String
		return STORAGE_VALUE_PREFIX . "s:" . Value
	if Value is Integer
		return STORAGE_VALUE_PREFIX . "i:" . String(Value)
	if Value is Float
		return STORAGE_VALUE_PREFIX . "f:" . String(Value)
	if (Value is Map) or (Value is Array)
		return STORAGE_VALUE_PREFIX . "j:" . _ST_JsonEncode(Value)
	throw TypeError("Storage values must be strings, numbers, Maps, or Arrays.")
}

_ST_DecodeValue(Stored) {
	global STORAGE_VALUE_PREFIX
	if !(Stored is String) or SubStr(Stored, 1, StrLen(STORAGE_VALUE_PREFIX)) != STORAGE_VALUE_PREFIX
		return Stored
	Payload := SubStr(Stored, StrLen(STORAGE_VALUE_PREFIX) + 1)
	Tag := SubStr(Payload, 1, 2)
	Body := SubStr(Payload, 3)
	switch Tag {
		case "s:": return Body
		case "i:": return Integer(Body)
		case "f:": return Float(Body)
		case "j:":
			Decoded := JsonParse(Body)
			if !(Decoded is Map) and !(Decoded is Array)
				throw ValueError("Storage JSON envelope must contain an object or array.")
			return Decoded
		default: throw ValueError("Unknown Storage value envelope.")
	}
}

_ST_JsonEncode(Value, Depth := 0, Seen := 0) {
	global JSON_MAX_NESTING_DEPTH
	if Value is String
		return JsonStringLiteral(Value)
	if Value is Number
		return String(Value)
	if !(Value is Map) and !(Value is Array)
		throw TypeError("Nested Storage values must be strings, numbers, Maps, or Arrays.")
	if (Depth >= JSON_MAX_NESTING_DEPTH)
		throw ValueError("Storage value exceeds the JSON nesting limit.")
	if !IsObject(Seen)
		Seen := Map()
	Pointer := ObjPtr(Value)
	if Seen.Has(Pointer)
		throw ValueError("Storage values must not contain reference cycles.")
	Seen[Pointer] := true
	try {
		Parts := []
		if Value is Map {
			for Key, Item in Value {
				if !(Key is String)
					throw TypeError("Storage object keys must be strings.")
				Parts.Push(JsonStringLiteral(Key) . ":" . _ST_JsonEncode(Item, Depth + 1, Seen))
			}
			return "{" . _ST_Join(Parts) . "}"
		}
		for Item in Value
			Parts.Push(_ST_JsonEncode(Item, Depth + 1, Seen))
		return "[" . _ST_Join(Parts) . "]"
	} finally {
		Seen.Delete(Pointer)
	}
}

_ST_Join(Parts) {
	Result := ""
	for Index, Part in Parts
		Result .= (Index = 1 ? "" : ",") . Part
	return Result
}

; Reads a value from the registry. Returns DefaultValue when the key is absent.
; @param Key          {String} The value name to read under STORAGE_REG_BASE.
; @param DefaultValue {Any}    Returned when the key does not exist.
; @return {Any} The stored typed value, or DefaultValue if absent or invalid.
ST_Get(Key, DefaultValue) {
	try {
		local Result := ""
		if !Reg_TryRead(STORAGE_REG_BASE, Key, &Result)
			return DefaultValue
		return _ST_DecodeValue(Result)
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
		local Result := ""
		return Reg_TryRead(STORAGE_REG_BASE, Key, &Result)
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
