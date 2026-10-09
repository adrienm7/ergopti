; infra/config_registry_cache.ahk

; ==============================================================================
; MODULE: Shipped Registry Parse Cache
; DESCRIPTION:
; Cache only the typed parse of the immutable migration registry. Exact source,
; parser, validator, codec and interpreter identities fence reuse. Validation
; remains mandatory on hits, and an unreadable authoritative source still fails.
; ==============================================================================

#Requires AutoHotkey v2.0

global _ConfigRegistryCachePending := false

/** Encodes the closed typed TOML model without evaluating cached source code. */
class ConfigRegistryCodec {
	static MAX_BYTES := 4194304
	static MAX_DEPTH := 128

	static Encode(Value) {
		Size := this.Size(Value)
		if Size > this.MAX_BYTES
			throw Error("Registry cache payload exceeds its size limit")
		Bytes := Buffer(Size, 0)
		Position := 0
		this.Write(Value, Bytes, &Position)
		return Bytes
	}

	static Size(Value, Depth := 0) {
		if Depth > this.MAX_DEPTH
			throw Error("Registry cache nesting exceeds its limit")
		if Value is TOML_Bool
			return 2
		if Value is Map || Value is Array {
			Size := Value is Map ? 6 : 5
			for Key, Child in Value {
				if Value is Map {
					if !(Key is String)
						throw TypeError("Registry cache map keys must be strings")
					Size += this.Size(Key, Depth + 1)
				}
				Size += this.Size(Child, Depth + 1)
				if Size > this.MAX_BYTES
					throw Error("Registry cache payload exceeds its size limit")
			}
			return Size
		}
		if Value is String
			return 5 + (StrLen(Value) + 1) * 2
		if Value is Integer || Value is Float
			return 9
		throw TypeError("Registry cache contains an unsupported value")
	}

	static Write(Value, Bytes, &Position) {
		if Value is TOML_Bool {
			NumPut("UChar", 3, "UChar", Value.Value, Bytes, Position)
			Position += 2
		} else if Value is Map || Value is Array {
			IsMap := Value is Map
			NumPut("UChar", IsMap ? 1 : 2, "UInt", IsMap ? Value.Count : Value.Length, Bytes, Position)
			Position += 5
			if IsMap {
				if !(Value.CaseSense == "On" || Value.CaseSense == "Off")
					throw Error("Registry cache refuses locale-dependent map comparison")
				NumPut("UChar", Value.CaseSense == "On" ? 1 : 0, Bytes, Position)
				Position += 1
			}
			for Key, Child in Value {
				if IsMap
					this.Write(Key, Bytes, &Position)
				this.Write(Child, Bytes, &Position)
			}
		} else if Value is String {
			Length := StrLen(Value)
			NumPut("UChar", 4, "UInt", Length, Bytes, Position)
			Position += 5
			StrPut(Value, Bytes.Ptr + Position, Length + 1, "UTF-16")
			Position += (Length + 1) * 2
		} else {
			NumPut("UChar", Value is Integer ? 5 : 6,
				Value is Integer ? "Int64" : "Double", Value, Bytes, Position)
			Position += 9
		}
	}

	static Decode(Bytes) {
		if !(Bytes is Buffer) || Bytes.Size > this.MAX_BYTES
			throw TypeError("Registry cache requires a bounded byte buffer")
		Position := 0
		Value := this.Read(Bytes, &Position)
		if Position != Bytes.Size
			throw Error("Registry cache has trailing bytes")
		return Value
	}

	static Need(Bytes, Position, Length) {
		if Position < 0 || Length < 0 || Position + Length > Bytes.Size
			throw Error("Registry cache is truncated")
	}

	static Read(Bytes, &Position, Depth := 0) {
		if Depth > this.MAX_DEPTH
			throw Error("Registry cache nesting exceeds its limit")
		this.Need(Bytes, Position, 1)
		Tag := NumGet(Bytes, Position, "UChar")
		Position += 1
		if Tag == 1 || Tag == 2 {
			this.Need(Bytes, Position, 4)
			Count := NumGet(Bytes, Position, "UInt")
			Position += 4
			if Count > Bytes.Size - Position
				throw Error("Registry cache has an impossible collection count")
			Value := Tag == 1 ? Map() : []
			if Tag == 1 {
				this.Need(Bytes, Position, 1)
				Flag := NumGet(Bytes, Position, "UChar")
				Position += 1
				if Flag > 1
					throw Error("Registry cache has an invalid map comparison flag")
				Value.CaseSense := Flag ? "On" : "Off"
			}
			loop Count {
				if Tag == 1 {
					Key := this.Read(Bytes, &Position, Depth + 1)
					if !(Key is String) || Value.Has(Key)
						throw Error("Registry cache has an invalid or duplicate map key")
					Value[Key] := this.Read(Bytes, &Position, Depth + 1)
				} else
					Value.Push(this.Read(Bytes, &Position, Depth + 1))
			}
			return Value
		}
		if Tag == 3 {
			this.Need(Bytes, Position, 1)
			Value := NumGet(Bytes, Position, "UChar")
			Position += 1
			if Value > 1
				throw Error("Registry cache has an invalid boolean")
			return TOML_Bool(Value)
		}
		if Tag == 4 {
			this.Need(Bytes, Position, 4)
			Length := NumGet(Bytes, Position, "UInt")
			Position += 4
			this.Need(Bytes, Position, (Length + 1) * 2)
			if NumGet(Bytes, Position + Length * 2, "UShort") != 0
				throw Error("Registry cache string has no terminator")
			Value := Length ? StrGet(Bytes.Ptr + Position, Length, "UTF-16") : ""
			if StrLen(Value) != Length
				throw Error("Registry cache string contains an embedded terminator")
			Position += (Length + 1) * 2
			return Value
		}
		if Tag == 5 || Tag == 6 {
			this.Need(Bytes, Position, 8)
			Value := NumGet(Bytes, Position, Tag == 5 ? "Int64" : "Double")
			Position += 8
			return Value
		}
		throw Error("Registry cache has an unknown value tag")
	}
}

/** Includes dirty parser changes and compiled releases in the cache identity. */
ConfigRegistryCacheCodeIdentity() {
	if A_IsCompiled
		return CryptoSha256Bytes(FSReadBytesStrict(A_ScriptFullPath))
	SplitPath(A_LineFile, , &Directory)
	Files := [Directory . "\config_migrate.ahk", A_LineFile]
	loop files Directory . "\toml\*.ahk", "F"
		Files.Push(A_LoopFileFullPath)
	Identity := "typed-registry-cache-v1`n" . A_AhkVersion . "`n"
	for Path in Files {
		Bytes := FSReadBytesStrict(Path)
		Hash := CryptoSha256Bytes(Bytes)
		if StrLen(Hash) != 64
			throw Error("Registry parser identity could not be hashed")
		SplitPath(Path, &Name)
		Identity .= Name . ":" . Hash . "`n"
	}
	return CryptoSha256(Identity)
}

/** Strict envelope parsing is separate from typed model/schema validation. */
ConfigRegistryCacheDecode(Text, Identity) {
	Lines := StrSplit(Text, "`n")
	if Lines.Length != 5 || Lines[1] != "ERGOPTI_REGISTRY_CACHE_V1"
			|| Lines[2] != Identity || Lines[5] != ""
		throw Error("Registry cache identity or envelope does not match")
	if !RegExMatch(Lines[3], "^[0-9a-f]{64}$") || !RegExMatch(Lines[4], "^[A-Za-z0-9+/]*={0,2}$")
		throw Error("Registry cache checksum or payload encoding is invalid")
	Bytes := CryptoBase64Decode(Lines[4])
	if CryptoSha256Bytes(Bytes) != Lines[3]
		throw Error("Registry cache payload checksum does not match")
	return ConfigRegistryCodec.Decode(Bytes)
}

/** Reads the authoritative file on every load and always validates cached models. */
ConfigRegistryCacheLoad(Path, CachePath, CodeIdentity := unset, ParseFn := 0, ValidateFn := 0) {
	global _ConfigRegistryCachePending
	Source := FSReadUtf8Exact(Path)
	if !(Source is String)
		throw Error("The authoritative migration registry could not be read: " . Path)
	Parse := HasMethod(ParseFn, "Call") ? ParseFn : _ConfigMigrateParse
	Validate := HasMethod(ValidateFn, "Call") ? ValidateFn : ConfigMigrateValidateRegistry
	Started := A_TickCount
	try {
		Code := IsSet(CodeIdentity) ? CodeIdentity : ConfigRegistryCacheCodeIdentity()
		SourceHash := CryptoSha256(Source)
		if StrLen(Code) != 64 || StrLen(SourceHash) != 64
			throw Error("Registry cache identity hashing failed")
		Identity := Code . ":" . SourceHash
		if FileExist(CachePath) {
			Text := FSReadUtf8ExactBounded(CachePath, ConfigRegistryCodec.MAX_BYTES * 2)
			if !(Text is String)
				throw Error("Registry cache envelope could not be read")
			Model := ConfigRegistryCacheDecode(Text, Identity)
			Registry := Validate.Call(Model)
			try LoggerInfo("ConfigMigration", "Registry parse cache hit, validated in {1} ms.", TickElapsed(Started))
			return Registry
		}
	} catch as Err {
		try LoggerWarn("ConfigMigration", "Registry parse cache refused: {1}; parsing the authoritative source.", Err.Message)
	}
	Model := Parse.Call(Source, "the shipped migration registry")
	Registry := Validate.Call(Model)
	if IsSet(Identity)
		_ConfigRegistryCachePending := {Path: CachePath, Identity: Identity, Model: Model}
	try LoggerInfo("ConfigMigration", "Registry parse cache miss, authoritative parse validated in {1} ms.", TickElapsed(Started))
	return Registry
}

/** Publishes a verified cache after menu publication, outside its first-display cost. */
ConfigRegistryCacheFlushPending() {
	global _ConfigRegistryCachePending
	static Sequence := 0
	if !_ConfigRegistryCachePending
		return false
	if !IsObject(_ConfigRegistryCachePending)
		throw TypeError("Registry cache publication requires an owned pending model")
	Entry := _ConfigRegistryCachePending
	_ConfigRegistryCachePending := false
	Stage := Entry.Path . "." . A_ScriptHwnd . "." . (++Sequence) . ".stage"
	OwnStage := false
	try {
		SplitPath(Entry.Path, , &Directory)
		FSEnsureDirectoryStrict(Directory)
		Bytes := ConfigRegistryCodec.Encode(Entry.Model)
		Text := "ERGOPTI_REGISTRY_CACHE_V1`n" . Entry.Identity . "`n"
			. CryptoSha256Bytes(Bytes) . "`n" . CryptoBase64Encode(Bytes) . "`n"
		if !FSWriteCreateDurable(Stage, Text)
			throw Error("Registry cache stage could not be created")
		OwnStage := true
		if !FSUtf8ExactMatches(Stage, Text)
			throw Error("Registry cache staging bytes could not be verified")
		ConfigRegistryCacheDecode(Text, Entry.Identity)
		if !FSAtomicMoveReplace(Stage, Entry.Path)
			throw Error("Registry cache stage could not be published")
		try LoggerInfo("ConfigMigration", "Verified registry parse cache published ({1} payload bytes).", Bytes.Size)
		return true
	} catch as Err {
		try LoggerWarn("ConfigMigration", "Registry cache could not be published: {1}.", Err.Message)
		return false
	} finally {
		if OwnStage && FileExist(Stage) && !FSDelete(Stage)
			try LoggerError("ConfigMigration", "Registry cache stage could not be retired: {1}.", Stage)
	}
}
