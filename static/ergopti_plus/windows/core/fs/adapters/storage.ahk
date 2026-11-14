; core/fs/adapters/storage.ahk

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
;
; ISOLATED PROFILE:
; A startup smoke or a live check (ERGOPTI_STARTUP_SMOKE_DIR) boots beside the
; user's own driver and shares the signed-in user's HKCU, so its writes would
; move the real driver's WPM widget, LLM and updater state. Every registry port
; of such a driver is its profile's private store file instead (section 3).
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

; The original native units are authoritative; C-string helpers stop at NUL.
_ST_StringHasNativeNul(Text) {
	Pointer := StrPtr(Text)
	Loop StrLen(Text)
		if NumGet(Pointer, (A_Index - 1) * 2, "UShort") == 0
			return true
	return false
}

; Win32 value-name parameters terminate at NUL. Preserve complete native
; String metadata before any conversion, and retain legacy numeric names.
; The admitted name is returned once so no later coercion can change it.
_ST_TryNativeKeyName(Key, &Name) {
	Name := ""
	if Key is String
		Candidate := Key
	else if Key is Number
		Candidate := String(Key)
	else
		return false
	if _ST_StringHasNativeNul(Candidate)
		return false
	Name := Candidate
	return true
}

; Writes one supported Storage value to the registry under Key.
; @param Key   {String} The value name to write under STORAGE_REG_BASE.
; @param Value {String|Number|Map|Array} The value to persist.
; @return {Boolean} True on success, false on error.
ST_Set(Key, Value) {
	return _ST_SetWith(Key, Value, Reg_WriteString)
}

; A caller's writer is replaced too in an isolated profile (section 3).
_ST_SetWith(Key, Value, WriteFn) {
	try {
		if !_ST_TryNativeKeyName(Key, &Name)
			return false
		Write := _ST_Isolate(Map("write", WriteFn), true)["write"]
		return Write.Call(STORAGE_REG_BASE, Name, _ST_EncodeValue(Value))
	} catch {
		return false
	}
}

_ST_EncodeValue(Value) {
	global STORAGE_VALUE_PREFIX
	if Value is String {
		; Ordinary and historical strings retain their exact s: protocol. A
		; NUL-bearing String needs a JSON scalar so REG_SZ cannot truncate it.
		return _ST_StringHasNativeNul(Value)
			? STORAGE_VALUE_PREFIX . "q:" . JsonStringLiteral(Value)
			: STORAGE_VALUE_PREFIX . "s:" . Value
	}
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
		case "q:":
			Decoded := JsonParse(Body)
			if !(Decoded is String)
				throw ValueError("Storage quoted scalar envelope must contain a JSON String.")
			return Decoded
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
		if !_ST_TryNativeKeyName(Key, &Name)
			return DefaultValue
		local Result := ""
		TryRead := _ST_Isolate(Map("try_read", Reg_TryRead))["try_read"]
		if !TryRead.Call(STORAGE_REG_BASE, Name, &Result)
			return DefaultValue
		return _ST_DecodeValue(Result)
	} catch {
		return DefaultValue
	}
}

; Exact read: a missing registry value is distinct from an unreadable store.
ST_ReadExact(Key) {
	try {
		Read := _ST_Isolate(Map("read", RegRead))["read"]
		Result := Read.Call(STORAGE_REG_BASE, Key)
	} catch as Err {
		if (Err is OSError && Err.Number == 2)
			return { Ok: true, Value: "" }
		return { Ok: false }
	}
	try return { Ok: true, Value: _ST_DecodeValue(Result) }
	catch
		return { Ok: false }
}

; Deletes a value from the registry. Reg_DeleteValue itself already treats a
; missing value as success (idempotent delete); only a genuine failure (e.g.
; permission denied) returns false, honouring the Storage port's
; error_behavior=return_false contract.
; @param Key {String} The value name to remove under STORAGE_REG_BASE.
; @return {Boolean} True on success (including "already absent"), false on error.
ST_Delete(Key) {
	try {
		if !_ST_TryNativeKeyName(Key, &Name)
			return false
		DeleteValue := _ST_Isolate(Map("delete_value", Reg_DeleteValue), true)["delete_value"]
		return DeleteValue.Call(STORAGE_REG_BASE, Name)
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
		if !_ST_TryNativeKeyName(Key, &Name)
			return false
		local Result := ""
		TryRead := _ST_Isolate(Map("try_read", Reg_TryRead))["try_read"]
		return TryRead.Call(STORAGE_REG_BASE, Name, &Result)
	} catch {
		return false
	}
}

; Enumerates names while preserving the distinction between an empty store and
; an inaccessible one. The public keys() contract deliberately collapses both
; to [], but clear() must not mistake an access failure for successful work.
; @param Names {Array} Receives key name strings, or an empty Array on failure.
; @param EnumValuesFn {Func|Integer} Optional deterministic test boundary; an
;   isolated profile enumerates its private store instead (section 3).
; @return {Boolean} True when registry enumeration completed, false on error.
_ST_EnumerateKeys(&Names, EnumValuesFn := 0) {
	Names := []
	try {
		if !IsObject(EnumValuesFn) || ST_PrivatePath() != "" {
			Enumerate := _ST_Isolate(Map("enumerate", Reg_TryEnumValueNames))["enumerate"]
			if !Enumerate.Call(STORAGE_REG_BASE, &Names) {
				try LoggerError("storage", "The native registry value-name inventory could not be completely read.")
				return false
			}
			return true
		}
		Records := EnumValuesFn.Call(STORAGE_REG_BASE)
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
; (tests/unit/adapters/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_STORAGE := Map(
    "set",    ST_Set,
    "get",    ST_Get,
    "delete", ST_Delete,
    "has",    ST_Has,
    "keys",   ST_Keys,
    "clear",  ST_Clear,
)





; ===================================
; ===================================
; ======= 3/ Isolated Profile =======
; ===================================
; ===================================

; The first line of the private store file; a different line is refused.
; @return {String}
ST_PrivateHeader() {
	return "ergopti-storage-private 1"
}

; The file that stands for HKCU\Software\Ergopti\Storage in an isolated profile,
; or "" for a real one. ERGOPTI_STARTUP_SMOKE_DIR already moves the paths, logs
; and configuration of a startup smoke or a live check into its scratch folder
; (infra/boot.ahk); the store follows, so the harness can read it there.
; @return {String} Absolute path, or "" when the driver owns the real profile.
ST_PrivatePath() {
	global _DriverStartupSmokeDir
	if !IsSet(_DriverStartupSmokeDir) || _DriverStartupSmokeDir == ""
		return ""
	return _DriverStartupSmokeDir . "\storage_private.txt"
}

; Replaces the registry ports of an isolated profile with its private store's.
; A caller's own port is replaced too: every port here names the machine's key,
; which an isolated driver must never reach.
; @param Ports {Map} Any of write, try_read, read, delete_value, enumerate.
; @param Announce {Boolean} Logs, once per store, which store the writes reach.
; @return {Map} The ports to use, the given ones for a real profile.
_ST_Isolate(Ports, Announce := false) {
	static Announced := ""
	Path := ST_PrivatePath()
	if (Path == "")
		return Ports
	Private := Map("write", _ST_PrivateWrite.Bind(Path),
		"try_read", _ST_PrivateTryRead.Bind(Path),
		"read", _ST_PrivateRead.Bind(Path),
		"delete_value", _ST_PrivateDelete.Bind(Path),
		"enumerate", _ST_PrivateEnumerate.Bind(Path))
	Isolated := Map()
	for Name in Ports {
		if !Private.Has(Name)
			throw ValueError("The storage adapter has no private port named " . Name . ".")
		Isolated[Name] := Private[Name]
	}
	if (Announce && Announced != Path) {
		Announced := Path
		LoggerInfo("storage",
			"Isolated profile: the stored values go to the private store '{1}', never to the machine's registry.", Path)
	}
	return Isolated
}

; Refuses a key other than the current base: the private file stands for it only.
; @param Base {String} Registry key path a port was given.
_ST_PrivateRequireBase(Base) {
	global STORAGE_REG_BASE
	if (Base != STORAGE_REG_BASE)
		throw ValueError("The private store stands for " . STORAGE_REG_BASE . " only.")
}

; Reads the private store; an absent file is the store of a fresh profile.
; @param Path {String} ST_PrivatePath().
; @return {Map} name => stored REG_SZ text, case-insensitive like registry names; throws when invalid.
_ST_PrivateLoad(Path) {
	global STORAGE_REG_BASE
	Values := Map()
	Values.CaseSense := "Off"
	if !FSStrictExists(Path)
		return Values
	Lines := StrSplit(StrReplace(FSReadStrict(Path), "`r", ""), "`n", , 3)
	if (Lines.Length != 3 || Lines[1] != ST_PrivateHeader() || Lines[2] != "base " . STORAGE_REG_BASE)
		throw ValueError("the private store '" . Path . "' has no valid header")
	Stored := JsonParse(Trim(Lines[3], "`n"))
	if !(Stored is Map)
		throw ValueError("the private store '" . Path . "' holds no object")
	for Name, Text in Stored {
		if !(Text is String) || Values.Has(Name)
			throw ValueError("the private store '" . Path . "' holds an invalid value " . Name)
		Values[Name] := Text
	}
	return Values
}

; Writes the whole private store back.
; @param Path {String} ST_PrivatePath().
; @param Values {Map} name => stored REG_SZ text.
_ST_PrivateSave(Path, Values) {
	global STORAGE_REG_BASE
	Text := ST_PrivateHeader() . "`n" . "base " . STORAGE_REG_BASE . "`n" . _ST_JsonEncode(Values) . "`n"
	SplitPath(Path, , &Directory)
	FSEnsureDirectoryStrict(Directory)
	if !FSWriteDurable(Path, Text)
		throw Error("the private store '" . Path . "' could not be written")
}

; Reg_WriteString's contract, over the private store.
; @return {Boolean} True once the value is stored; a failure is logged.
_ST_PrivateWrite(Path, Base, Name, Value) {
	try {
		_ST_PrivateRequireBase(Base)
		Values := _ST_PrivateLoad(Path)
		Values[Name] := String(Value)
		_ST_PrivateSave(Path, Values)
		return true
	} catch as Err {
		LoggerError("storage", "The private stored value {1} could not be written: {2}.", Name, Err.Message)
		return false
	}
}

; Reg_TryRead's contract, over the private store.
; @return {Boolean} True only when the value exists; Value receives it, or "".
_ST_PrivateTryRead(Path, Base, Name, &Value) {
	Value := ""
	try {
		_ST_PrivateRequireBase(Base)
		Values := _ST_PrivateLoad(Path)
	} catch as Err {
		LoggerError("storage", "The private store could not be read for {1}: {2}.", Name, Err.Message)
		return false
	}
	if !Values.Has(Name)
		return false
	Value := Values[Name]
	return true
}

; RegRead's contract, over the private store: an absent value throws
; ERROR_FILE_NOT_FOUND, any other failure its own error.
; @return {String} The stored REG_SZ text.
_ST_PrivateRead(Path, Base, Name) {
	_ST_PrivateRequireBase(Base)
	Values := _ST_PrivateLoad(Path)
	if !Values.Has(Name)
		throw OSError(2, A_ThisFunc, Name)
	return Values[Name]
}

; Reg_DeleteValue's contract, over the private store: an absent value is deleted already.
; @return {Boolean} True once the value is absent; a failure is logged.
_ST_PrivateDelete(Path, Base, Name) {
	try {
		_ST_PrivateRequireBase(Base)
		Values := _ST_PrivateLoad(Path)
		if Values.Has(Name) {
			Values.Delete(Name)
			_ST_PrivateSave(Path, Values)
		}
		return true
	} catch as Err {
		LoggerError("storage", "The private stored value {1} could not be deleted: {2}.", Name, Err.Message)
		return false
	}
}

; Reg_TryEnumValueNames's contract, over the private store.
; @return {Boolean} True when the inventory is complete; Names receives it.
_ST_PrivateEnumerate(Path, Base, &Names) {
	Names := []
	try {
		_ST_PrivateRequireBase(Base)
		Values := _ST_PrivateLoad(Path)
	} catch as Err {
		LoggerError("storage", "The private store could not be enumerated: {1}.", Err.Message)
		return false
	}
	for Name in Values
		Names.Push(Name)
	return true
}
