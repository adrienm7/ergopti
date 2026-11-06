; tests/unit/infra/config/persistence/test_config_registry_cache.ahk

; ==============================================================================
; MODULE: Registry Parse Cache Tests
; DESCRIPTION:
; Preserve typed TOML values and reject truncated or hostile payloads. Exact
; source/code invalidation and unconditional validation prevent stale migrations.
; ==============================================================================

#Requires AutoHotkey v2.0

_CRC_TypedRoundTrip() {
	Sensitive := Map()
	Sensitive.CaseSense := "On"
	Sensitive["A"] := TOML_Bool(true)
	Sensitive["a"] := TOML_Bool(false)
	Values := [Sensitive, Map("empty", "", "text", "é😀"), [], -9223372036854775807,
		9223372036854775807, 1.25, "0", 0, TOML_Bool(false)]
	Decoded := ConfigRegistryCodec.Decode(ConfigRegistryCodec.Encode(Values))
	AssertEqual("On", Decoded[1].CaseSense)
	AssertEqual(2, Decoded[1].Count)
	AssertTrue(Decoded[1]["A"] is TOML_Bool)
	AssertTrue(Decoded[1]["A"].Value)
	AssertFalse(Decoded[1]["a"].Value)
	AssertEqual("é😀", Decoded[2]["text"])
	AssertEqual(0, Decoded[3].Length)
	AssertEqual(Values[4], Decoded[4])
	AssertEqual(Values[5], Decoded[5])
	AssertTrue(Decoded[6] is Float)
	AssertTrue(Decoded[7] is String)
	AssertTrue(Decoded[8] is Integer)
	AssertTrue(Decoded[9] is TOML_Bool)
}
Test("registry cache: exact typed values and case-sensitive maps survive decoding", _CRC_TypedRoundTrip)

_CRC_RejectsCorruption() {
	Bytes := ConfigRegistryCodec.Encode(Map("value", [TOML_Bool(true), "text"]))
	loop Bytes.Size {
		Short := Buffer(A_Index - 1)
		loop Short.Size
			NumPut("UChar", NumGet(Bytes, A_Index - 1, "UChar"), Short, A_Index - 1)
		Threw := false
		try ConfigRegistryCodec.Decode(Short)
		catch
			Threw := true
		AssertTrue(Threw, "every truncated prefix must refuse")
	}
	for Hostile in [Buffer(1, 255), Buffer(2, 3), Buffer(5, 2), Buffer(6, 1)] {
		Threw := false
		try ConfigRegistryCodec.Decode(Hostile)
		catch
			Threw := true
		AssertTrue(Threw, "unknown tags and impossible counts/booleans refuse")
	}
}
Test("registry cache: every truncated prefix and hostile header refuses", _CRC_RejectsCorruption)

_CRC_IdentityAndValidation() {
	global _ConfigRegistryCachePending
	Saved := _ConfigRegistryCachePending
	Directory := A_Temp . "\ergopti-registry-test-" . A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Directory)
	SourcePath := Directory . "\registry.toml"
	CachePath := Directory . "\registry.cache"
	State := {Parsed: 0, Validated: 0}
	Parse := (Source, Label) => _CRC_Parse(State, Source)
	Validate := (Model) => _CRC_Validate(State, Model)
	Code := CryptoSha256("parser-one")
	try {
		FileAppend("original", SourcePath, "UTF-8-RAW")
		ConfigRegistryCacheLoad(SourcePath, CachePath, Code, Parse, Validate)
		AssertTrue(ConfigRegistryCacheFlushPending())
		ConfigRegistryCacheLoad(SourcePath, CachePath, Code, Parse, Validate)
		AssertEqual(1, State.Parsed, "a verified hit skips only parsing")
		AssertEqual(2, State.Validated, "a hit still validates")
		ConfigRegistryCacheLoad(SourcePath, CachePath, CryptoSha256("parser-two"), Parse, Validate)
		AssertEqual(2, State.Parsed, "dirty parser changes invalidate")
		FileDelete(SourcePath)
		FileAppend("changed", SourcePath, "UTF-8-RAW")
		ConfigRegistryCacheLoad(SourcePath, CachePath, Code, Parse, Validate)
		AssertEqual(3, State.Parsed, "exact authoritative byte changes invalidate")
		FileDelete(SourcePath)
		Threw := false
		try ConfigRegistryCacheLoad(SourcePath, CachePath, Code, Parse, Validate)
		catch
			Threw := true
		AssertTrue(Threw, "a cached model cannot hide source unreadability")
	} finally {
		_ConfigRegistryCachePending := Saved
		DirDelete(Directory, true)
	}
}
_CRC_Parse(State, Source) {
	State.Parsed += 1
	return Map("source", Source)
}
_CRC_Validate(State, Model) {
	State.Validated += 1
	return Model
}
Test("registry cache: hits validate, source/parser changes miss and missing source fails", _CRC_IdentityAndValidation)

_CRC_Fingerprint(Value) {
	if Value is TOML_Bool
		return "boolean:" . Value.Value
	if Value is Map || Value is Array {
		Text := Value is Map ? "map:" . Value.CaseSense . ":" : "array:"
		for Key, Child in Value {
			if Value is Map
				Text .= StrLen(Key) . ":" . Key
			Part := _CRC_Fingerprint(Child)
			Text .= StrLen(Part) . ":" . Part
		}
		return Text
	}
	return Type(Value) . ":" . StrLen(String(Value)) . ":" . String(Value)
}

_CRC_ShippedModelEquality() {
	Source := FSReadUtf8Exact(ConfigMigrateRegistryPath())
	Parsed := _ConfigMigrateParse(Source, "registry codec equality fixture")
	Decoded := ConfigRegistryCodec.Decode(ConfigRegistryCodec.Encode(Parsed))
	AssertEqual(_CRC_Fingerprint(Parsed), _CRC_Fingerprint(Decoded),
		"the entire shipped typed parse remains exact")
	AssertEqual(_CRC_Fingerprint(ConfigMigrateValidateRegistry(Parsed)),
		_CRC_Fingerprint(ConfigMigrateValidateRegistry(Decoded)),
		"cached and fresh models produce the same validated migration plan")
}
Test("registry cache: shipped typed model and validated plan remain identical", _CRC_ShippedModelEquality)

_CRC_InvalidCachedSchemaReparses() {
	global _ConfigRegistryCachePending
	Saved := _ConfigRegistryCachePending
	Directory := A_Temp . "\ergopti-registry-schema-" . A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Directory)
	SourcePath := Directory . "\registry.toml"
	CachePath := Directory . "\registry.cache"
	State := {Parsed: 0, Validated: 0}
	Code := CryptoSha256("schema-refusal-fixture")
	try {
		FileAppend("authoritative", SourcePath, "UTF-8-RAW")
		Bytes := ConfigRegistryCodec.Encode(Map("invalid", true))
		Envelope := "ERGOPTI_REGISTRY_CACHE_V1`n" . Code . ":" . CryptoSha256("authoritative")
			. "`n" . CryptoSha256Bytes(Bytes) . "`n" . CryptoBase64Encode(Bytes) . "`n"
		FileAppend(Envelope, CachePath, "UTF-8-RAW")
		Model := ConfigRegistryCacheLoad(SourcePath, CachePath, Code,
			(Source, Label) => _CRC_Parse(State, Source),
			(Value) => _CRC_RequireSource(State, Value))
		AssertEqual("authoritative", Model["source"])
		AssertEqual(1, State.Parsed, "a checksum-valid cache cannot bypass schema refusal")
		AssertEqual(2, State.Validated, "both cached and reparsed models reach validation")
	} finally {
		_ConfigRegistryCachePending := Saved
		DirDelete(Directory, true)
	}
}

_CRC_RequireSource(State, Value) {
	State.Validated += 1
	if !Value.Has("source")
		throw Error("schema requires an authoritative source field")
	return Value
}
Test("registry cache: checksum-valid invalid schema reparses the authoritative file", _CRC_InvalidCachedSchemaReparses)

; Every driver update changes the cache identity, so the first boot after one
; logged a WARNING for an expected miss (13 errors-sink lines since 2026-10-03).
; A stale cache is INFO; a tampered or malformed one still warns.
_CRC_CaptureLoad(SourcePath, CachePath, Code, Parse, Validate) {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	Saved := [LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL, _LOGGER_PENDING,
		_LOGGER_PENDING_ERRORS, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH]
	LOGGER_RING_BUFFER := [], LOGGER_RING_CURSOR := 0, LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := [], _LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := "", LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_DEDUP_KEY := "", _LOGGER_DEDUP_LEVEL := "", _LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
	try {
		ConfigRegistryCacheLoad(SourcePath, CachePath, Code, Parse, Validate)
		Out := ""
		for _, Line in LOGGER_RING_BUFFER
			Out .= Line . "`n"
		return Out
	} finally {
		LOGGER_RING_BUFFER := Saved[1], LOGGER_RING_CURSOR := Saved[2], LOGGER_MIN_LEVEL := Saved[3]
		_LOGGER_PENDING := Saved[4], _LOGGER_PENDING_ERRORS := Saved[5]
		LOGGER_LOG_PATH := Saved[6], LOGGER_ERRORS_LOG_PATH := Saved[7]
		_LoggerRefreshFastFlags()
	}
}

_CRC_StaleIsInfoCorruptionWarns() {
	global _ConfigRegistryCachePending
	Saved := _ConfigRegistryCachePending
	Directory := A_Temp . "\ergopti-registry-stale-" . A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Directory)
	SourcePath := Directory . "\registry.toml"
	CachePath := Directory . "\registry.cache"
	State := {Parsed: 0, Validated: 0}
	Parse := (Source, Label) => _CRC_Parse(State, Source)
	Validate := (Model) => _CRC_Validate(State, Model)
	try {
		FileAppend("original", SourcePath, "UTF-8-RAW")
		ConfigRegistryCacheLoad(SourcePath, CachePath, CryptoSha256("parser-one"), Parse, Validate)
		AssertTrue(ConfigRegistryCacheFlushPending())
		Stale := _CRC_CaptureLoad(SourcePath, CachePath, CryptoSha256("parser-two"), Parse, Validate)
		AssertTrue(InStr(Stale, "Registry parse cache is stale") > 0, "the stale miss is still logged: " . Stale)
		AssertTrue(InStr(Stale, "[WARNING]") == 0, "a cache from the previous driver build is an expected miss: " . Stale)
		_ConfigRegistryCachePending := false
		Text := FileRead(CachePath, "UTF-8-RAW")
		FileDelete(CachePath)
		Lines := StrSplit(Text, "`n")
		Lines[3] := Format("{:064}", 0)
		Tampered := ""
		for Line in Lines
			Tampered .= (A_Index == 1 ? "" : "`n") . Line
		FileAppend(Tampered, CachePath, "UTF-8-RAW")
		Corrupt := _CRC_CaptureLoad(SourcePath, CachePath, CryptoSha256("parser-one"), Parse, Validate)
		AssertTrue(InStr(Corrupt, "[WARNING]") > 0 && InStr(Corrupt, "Registry parse cache refused") > 0,
			"a tampered cache must still warn: " . Corrupt)
	} finally {
		_ConfigRegistryCachePending := Saved
		DirDelete(Directory, true)
	}
}
Test("registry cache: a stale cache is an INFO miss, a tampered one warns (registry-cache-stale-info)",
	_CRC_StaleIsInfoCorruptionWarns)

_CRC_PendingOwnsSourceModel(MutateReturned) {
	global _ConfigRegistryCachePending
	SavedPending := _ConfigRegistryCachePending
	Root := A_Temp . "\ergopti_registry_pending_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	SourcePath := Root . "\registry.toml", CachePath := Root . "\registry.cache", Created := false
	Source := '[registry]`ncurrent_version = 2`nunstamped_version = 1`n'
		. '[steps.v1_to_v2]`nfrom = 1`nto = 2`ndrivers = ["ahk"]`nreason = "owned source"`n'
		. 'ops = [{ op = "rename", section = "data", key = "old", to_key = "new" }]`n'
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(SourcePath, Source))
		Before := FSReadBytesStrict(SourcePath)
		Registry := ConfigRegistryCacheLoad(SourcePath, CachePath)
		AssertEqual("new", Registry["steps"][1]["ops"][1]["to_key"])
		Mutable := MutateReturned ? Registry : ManifestCloneValue(Registry)
		Mutable["steps"][1]["ops"][1]["to_key"] := "foreign"
		AssertTrue(ConfigRegistryCacheFlushPending(), "the real deferred encoder and native publication must complete")
		Fresh := ConfigRegistryCacheLoad(SourcePath, CachePath)
		Plan := ConfigMigratePlan('[data]`nold = "Original"`n', Fresh, "ahk")
		ActualKey := Fresh["steps"][1]["ops"][1]["to_key"]
		After := FSReadBytesStrict(SourcePath)
		_TestPrint("# registry-pending-owner mutate_returned=" . MutateReturned
			. " cached_to_key=" . ActualKey . " plan=" . Plan["outcome"]
			. " has_new=" . (Plan.Has("model") && Plan["model"].Has("data") && Plan["model"]["data"].Has("new"))
			. " has_foreign=" . (Plan.Has("model") && Plan["model"].Has("data") && Plan["model"]["data"].Has("foreign"))
			. " before_bytes=" . Before.Size . " after_bytes=" . After.Size)
		AssertEqual(Before.Size, After.Size)
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
			"Ptr", After, "UPtr", Before.Size, "UPtr"), "the authoritative source must never be altered by this probe")
		AssertEqual("new", ActualKey, "a cache must retain the source parse, independently of a returned runtime registry")
		AssertEqual("migrated", Plan["outcome"])
		AssertEqual("Original", Plan["model"]["data"]["new"])
		AssertFalse(Plan["model"]["data"].Has("foreign"), "fresh migrations must follow the still-authoritative registry source")
	} finally {
		_ConfigRegistryCachePending := SavedPending
		if Created {
			Pristine := _ConfigRegistryPristineStore()
			if Pristine.Has(SourcePath)
				Pristine.Delete(SourcePath)
			_TOML_InvalidateParseCache(SourcePath)
			DirDelete(Root, true)
		}
	}
}
for _CRC_MutateReturned in [true, false]
	Test("registry cache: pending source model owns returned mutation=" . _CRC_MutateReturned
		. " (registry-pending-source-ownership)", _CRC_PendingOwnsSourceModel.Bind(_CRC_MutateReturned))


_CRC_PendingOwnsDeepValues(Mode) {
	global _ConfigRegistryCachePending
	SavedPending := _ConfigRegistryCachePending
	Root := A_Temp . "\ergopti_registry_deep_pending_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	SourcePath := Root . "\registry.toml", CachePath := Root . "\registry.cache", Created := false
	Source := '[registry]`ncurrent_version = 2`nunstamped_version = 1`n'
		. '[steps.v1_to_v2]`nfrom = 1`nto = 2`ndrivers = ["ahk"]`nreason = "deep owned source"`n'
		. 'ops = [{ op = "rename", section = "data", key = "old", to_key = "new" },'
		. '{ op = "set_if_absent", section = "data", key = "flags", value = [true, false] }]`n'
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(SourcePath, Source))
		Before := FSReadBytesStrict(SourcePath)
		Registry := ConfigRegistryCacheLoad(SourcePath, CachePath)
		Ops := Registry["steps"][1]["ops"]
		AssertEqual(2, Ops.Length)
		AssertTrue(Ops[2]["value"][1] is TOML_Bool && Ops[2]["value"][1].Value)
		if Mode == "typed-booleans" {
			Ops[2]["value"][1].Value := false
			Ops[2]["value"][2].Value := true
		} else {
			Ops.Push(Map("op", "set_if_absent", "section", "data", "key", "foreign", "value", "Injected"))
		}
		AssertTrue(ConfigRegistryCacheFlushPending(), "The actual deferred encoder and native publisher must flush the detached source model")
		Fresh := ConfigRegistryCacheLoad(SourcePath, CachePath)
		Plan := ConfigMigratePlan('[data]`nold = "Original"`n', Fresh, "ahk")
		FreshOps := Fresh["steps"][1]["ops"]
		_TestPrint("# registry-deep-pending mode=" . Mode . " ops=" . FreshOps.Length
			. " flag0=" . FreshOps[2]["value"][1].Value . " flag1=" . FreshOps[2]["value"][2].Value
			. " migrated=" . (Plan["outcome"] == "migrated") . " has_foreign=" . Plan["model"]["data"].Has("foreign"))
		AssertEqual(2, FreshOps.Length, "Appending to the returned runtime ops array cannot append an operation to the pending source parse")
		AssertTrue(FreshOps[2]["value"][1] is TOML_Bool && FreshOps[2]["value"][1].Value)
		AssertTrue(FreshOps[2]["value"][2] is TOML_Bool && !FreshOps[2]["value"][2].Value)
		AssertEqual("migrated", Plan["outcome"])
		AssertEqual("Original", Plan["model"]["data"]["new"])
		AssertFalse(Plan["model"]["data"].Has("foreign"))
		AssertTrue(Plan["model"]["data"]["flags"][1] is TOML_Bool && Plan["model"]["data"]["flags"][1].Value)
		AssertTrue(Plan["model"]["data"]["flags"][2] is TOML_Bool && !Plan["model"]["data"]["flags"][2].Value)
		; A later runtime mutation on a genuine cache hit must also be local.
		FreshOps[1]["to_key"] := "hit_foreign"
		Again := ConfigRegistryCacheLoad(SourcePath, CachePath)
		AssertEqual("new", Again["steps"][1]["ops"][1]["to_key"])
		AssertFalse(ConfigRegistryCacheFlushPending(), "A genuine cache hit schedules no new cache model from its returned runtime")
		After := FSReadBytesStrict(SourcePath)
		AssertEqual(Before.Size, After.Size)
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before, "Ptr", After, "UPtr", Before.Size, "UPtr"))
	} finally {
		_ConfigRegistryCachePending := SavedPending
		if Created {
			Pristine := _ConfigRegistryPristineStore()
			if Pristine.Has(SourcePath)
				Pristine.Delete(SourcePath)
			_TOML_InvalidateParseCache(SourcePath)
			DirDelete(Root, true)
		}
	}
}
for _CRC_DeepMode in ["typed-booleans", "ops-array"]
	Test("Registry cache pending source: " . _CRC_DeepMode . " stays independent of mutable runtime values (registry-pending-deep-ownership)",
		_CRC_PendingOwnsDeepValues.Bind(_CRC_DeepMode))
