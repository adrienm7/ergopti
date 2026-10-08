; infra/toml/config_snapshot.ahk

; ==============================================================================
; MODULE: Configuration Semantic Snapshot
; DESCRIPTION:
; Projects the typed document into the native section cache and feature rows
; from one admitted source image. Generic data-file parsing and writer admission
; keep their existing owners. Dots inside quoted names remain literal; table
; array members never borrow a scalar section identity from another generation.
; ==============================================================================

#Requires AutoHotkey v2.0

global _ConfigTomlSnapshots := Map()

/** Converts typed values at the native reader boundary, retaining nested shape. */
_ConfigTomlNativeValue(Value, NativeBooleans := true) {
	if Value is TOML_Bool
		return NativeBooleans ? !!Value.Value : TOML_Bool(Value.Value)
	if Value is Array {
		Result := []
		for Child in Value
			Result.Push(_ConfigTomlNativeValue(Child, NativeBooleans))
		return Result
	}
	if Value is Map {
		Result := Map()
		Result.CaseSense := "On"
		for Key, Child in Value
			Result[Key] := _ConfigTomlNativeValue(Child, NativeBooleans)
		return Result
	}
	return Value
}

/** Renders a section from exact semantic segments without flattening literal dots. */
_ConfigTomlSection(Parts) {
	Section := ""
	loop Parts.Length - 1
		Section .= (A_Index == 1 ? "" : ".") . TOML_RenderKey(Parts[A_Index])
	return Section
}

/** Table-array descendants have no single native section/key owner. */
_ConfigTomlArrayMember(Document, Parts) {
	Node := Document
	loop Parts.Length - 1 {
		if !(Node is Map) || !Node.Has(Parts[A_Index])
			throw ValueError("Configuration record has no semantic owner")
		Node := Node[Parts[A_Index]]
		if Node is Array
			return true
	}
	return false
}

/**
 * Builds detached cache/feature projections using the actual typed document owner.
 * @param {String} Source - Exact source admitted by the configuration reader.
 * @returns {Object} Source, Document, Cache, Rows and SkippedRecords.
 */
ConfigTomlDecodeSnapshot(Source) {
	Document := TOML_ParseDocument(Source, &Records)
	Cache := Map(), Rows := [], SkippedRecords := 0
	Cache.CaseSense := "On"
	Namespaces := Map()
	Namespaces.CaseSense := "On"
	for Section in ManifestSections()
		Namespaces[Section] := true
	for Section in TomlConfigStaticForeignOwnershipRegistry()
		Namespaces[Section] := true
	for Entry in ManifestFeatures() {
		Parts := StrSplit(Entry["path"], ".")
		Prefix := ""
		loop Parts.Length - 1 {
			Prefix .= (Prefix == "" ? "" : ".") . Parts[A_Index]
			Namespaces[Prefix] := true
		}
	}
	for Record in Records {
		if _ConfigTomlArrayMember(Document, Record.Path) {
			SkippedRecords += 1
			continue
		}
		_ConfigTomlProjectRecord(Record.Path, Record.Value, Record.Raw,
			Namespaces, Cache, Rows)
	}
	return { Source: Source, Document: Document, Cache: Cache,
		Rows: Rows, SkippedRecords: SkippedRecords }
}

; Reuses the actual inline-table owner to preserve each child literal spelling.
; Typed rendering alone would manufacture legacy Boolean intent from signed zero.
_ConfigTomlRawTree(Value, Raw) {
	Members := Raw is Map ? Raw : TOML_ParseInlineTable(Raw, (Token) => Token)
	Tree := Map()
	Tree.CaseSense := "On"
	for Key, Child in Value {
		if !Members.Has(Key)
			throw ValueError("Configuration inline record lost its source child")
		Tree[Key] := Child is Map ? _ConfigTomlRawTree(Child, Members[Key]) : Members[Key]
	}
	return Tree
}

; Only declared namespace identities expand inline maps. Record-valued leaves
; (including manifest feature records) retain their own cache/row identity.
_ConfigTomlProjectRecord(Parts, Value, Raw, Namespaces, Cache, Rows) {
	ChildRaw := Value is Map ? _ConfigTomlRawTree(Value, Raw) : false
	Canonical := ""
	for Part in Parts {
		if Part == "" || InStr(Part, ".") {
			Canonical := ""
			break
		}
		Canonical .= (Canonical == "" ? "" : ".") . Part
	}
	if Value is Map && ((Canonical != "" && Namespaces.Has(Canonical))
			|| (Parts.Length >= 3 && _ConfigTomlDynamicPersonal(Parts)))
			&& !(ManifestFindEntryByPath(Canonical) is Map) {
		for Key, Child in Value {
			ChildParts := Parts.Clone()
			ChildParts.Push(Key)
			_ConfigTomlProjectRecord(ChildParts, Child, ChildRaw[Key],
				Namespaces, Cache, Rows)
		}
		return
	}
	Section := _ConfigTomlSection(Parts)
	Key := Parts[Parts.Length]
	if !Cache.Has(Section) {
		Cache[Section] := Map()
		Cache[Section].CaseSense := "On"
	}
	if Cache[Section].Has(Key)
		throw ValueError("Configuration paths alias one native cache slot")
	Cache[Section][Key] := _ConfigTomlNativeValue(Value)
	Rows.Push({ Section: Section, Key: Key, Raw: Raw is Map ? TOML_RenderValue(Value) : Raw,
		Value: _ConfigTomlNativeValue(Value), Typed: _ConfigTomlNativeValue(Value, false),
		ChildRaw: ChildRaw })
}

/**
 * Reads an admitted configuration image, reusing only its exact published cache.
 * Existing cache invalidation retires that identity without mutating old objects.
 * @param {String} Path - Configuration source path.
 * @returns {Object} Typed snapshot; native or semantic failures throw.
 */
ConfigTomlReadSnapshot(Path) {
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	global _TomlReadFailures, _TomlUnreadableFiles
	static Generations := Map()
	static DecodeOwner := ConfigTomlDecodeSnapshot, JournalOwner := ConfigMigrateBoot
	static CompareOwner := _ConfigTomlSnapshotEqual
	Key := _ConfigWriteLeaseKey(Path)
	if DecodeOwner != ConfigTomlDecodeSnapshot || JournalOwner != ConfigMigrateBoot
			|| CompareOwner != _ConfigTomlSnapshotEqual
		throw Error("The native configuration snapshot producer was replaced")
	if Generations.Has(Key) {
		Generation := Generations[Key], Previous := Generation.snapshot
		; Native publication retains one private admitted generation even if the
		; physical file changes between consumers. Public equivalent Maps alone
		; cannot issue it. Retirement of an actual cache identity observes anew.
		if CompareOwner.Call(Previous, Generation.shadow)
				&& _ConfigTomlSnapshots.Has(Path) && _ConfigTomlSnapshots[Path] == Previous
				&& _ParseTomlCache.Has(Path) && _ParseTomlCache[Path] == Previous.Cache
				&& (!IsSet(_TomlFileCache) || (_TomlFileCache.Has(Path)
					&& StrCompare(_TomlFileCache[Path], Generation.source, true) == 0)) {
			try {
				if Generation.admission.Call(Generation.source, Generation.present)
						&& CompareOwner.Call(Previous, Generation.shadow)
					return Previous
			} catch {
			}
		}
		Generations.Delete(Key)
	}
	if _ConfigTomlSnapshots.Has(Path)
		_ConfigTomlSnapshots.Delete(Path)
	ReadAdmission := JournalOwner.Call(Path, "capture_read")
	if !HasMethod(ReadAdmission, "Call")
		throw Error("The genuine configuration constructor did not admit this source")
	if _TomlReadFailures.Has(Path)
		_TomlReadFailures.Delete(Path)
	if !FileExist(Path) {
		Snapshot := ConfigTomlDecodeSnapshot("")
		Snapshot.Present := false
		if !ReadAdmission.Call("", 0)
			throw Error("The configuration absence lost its native source admission")
		Shadow := DecodeOwner.Call("")
		Shadow.Present := false
		Generations[Key] := { snapshot: Snapshot, source: "", present: 0,
			admission: ReadAdmission, shadow: Shadow }
		return Snapshot
	}
	try Source := FSReadStrict(Path)
	catch as Err {
		_TomlReadFailures[Path] := true
		if FileExist(Path)
			_TomlUnreadableFiles[Path] := true
		throw Error("Configuration source could not be read")
	}
	if _TomlUnreadableFiles.Has(Path)
		_TomlUnreadableFiles.Delete(Path)
	Snapshot := ConfigTomlDecodeSnapshot(Source)
	Snapshot.Present := true
	if !ReadAdmission.Call(Source, 1)
		throw Error("The configuration read lost its native source admission")
	Shadow := DecodeOwner.Call(Source)
	Shadow.Present := true
	Generations[Key] := { snapshot: Snapshot, source: Source, present: 1,
		admission: ReadAdmission, shadow: Shadow }
	return Snapshot
}

/**
 * Publishes the bootstrap cache only after the whole semantic source is admitted.
 * A refusal latches session persistence protection even if a later read succeeds.
 * @param {String} Path - Effective config.toml path.
 * @returns {Map} Native section cache, or empty defaults with persistence blocked.
 */
ParseConfigTomlFile(Path) {
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	global _ConfigBootReadFailed
	try Snapshot := ConfigTomlReadSnapshot(Path)
	catch as Err {
		_ConfigBootReadFailed := true
		if !TOML_UnreadableFile(Path) && TOML_WriteRefusal(Path) == ""
			TOML_RefuseWrites(Path, "the boot semantic source could not be admitted")
		try LoggerError("ConfigSnapshot", "Configuration at '{1}' could not be admitted at boot; defaults cannot be persisted in this session.", Path)
		return Map()
	}
	; Admitted absence is a boot generation too. The existing writer retires
	; this identity when first-use settings are actually published.
	_ParseTomlCache[Path] := Snapshot.Cache
	if IsSet(_TomlFileCache)
		_TomlFileCache[Path] := Snapshot.Source
	_ConfigTomlSnapshots[Path] := Snapshot
	return Snapshot.Cache
}

; Base foreign ownership data is shared by bootstrap projection and the feature
; loader. Language gate augmentation stays with the feature loader owner.
TomlConfigStaticForeignOwnershipRegistry() {
	static Registry := Map(
		"category_enabled", Map(
			"autocorrection", "FeatureState",
			"distances_reduction", "FeatureState",
			"magic_key", "FeatureState",
			"rolls", "FeatureState",
			"sfbs_reduction", "FeatureState"),
		"hotstrings", Map(
			"terminators", "TerminatorRecords",
			"terminator_states", "TerminatorRecords"),
		"gestures", Map(
			"auto_configure_on_next_start", "Gestures"),
		"personal_editor", Map(
			"compact_view", "PersonalEditor",
			"close_on_add", "PersonalEditor",
			"default_section", "PersonalEditor"),
		"llm", Map(
			"api_entry_id", "LLMMenu",
			"ollama_port", "LLMMenu"),
		"llm.navigation", Map(
			"nav_modifiers", "LLMMenu"),
		"llm.trigger", Map(
			"disabled_apps", "LLMMenu"))
	return Registry
}

; Dynamic personal names are exact semantic segments, including literal dots
; and empty names. They never normalize into a static manifest owner.
_ConfigTomlDynamicPersonal(Parts) {
	return Parts is Array && Parts.Length >= 2
		&& Parts[1] == "hotstrings" && Parts[2] == "personal"
}


; Exact native decoder output is compared to a detached private shadow. This
; rejects in-place source/cache/row mutation without granting write authority.
_ConfigTomlSnapshotEqual(Left, Right) {
	if Type(Left) != Type(Right)
		return false
	if Left is Map {
		if ObjGetBase(Left) != Map.Prototype || ObjGetBase(Right) != Map.Prototype
			return false
		for Name in ObjOwnProps(Left)
			return false
		for Name in ObjOwnProps(Right)
			return false
		if Left.Count != Right.Count || Left.CaseSense != Right.CaseSense
			return false
		ExactRight := Map()
		ExactRight.CaseSense := "On"
		for Name, Value in Right
			ExactRight[Name] := Value
		for Name, Value in Left {
			if !ExactRight.Has(Name) || !_ConfigTomlSnapshotEqual(Value, ExactRight[Name])
				return false
		}
		return true
	}
	if Left is Array {
		if ObjGetBase(Left) != Array.Prototype || ObjGetBase(Right) != Array.Prototype
			return false
		for Name in ObjOwnProps(Left)
			return false
		for Name in ObjOwnProps(Right)
			return false
		if Left.Length != Right.Length
			return false
		loop Left.Length {
			if !Left.Has(A_Index) || !Right.Has(A_Index)
					|| !_ConfigTomlSnapshotEqual(Left[A_Index], Right[A_Index])
				return false
		}
		return true
	}
	if IsObject(Left) {
		ExpectedBase := Left is TOML_Bool ? TOML_Bool.Prototype : Object.Prototype
		if ObjGetBase(Left) != ExpectedBase || ObjGetBase(Right) != ExpectedBase
			return false
		LeftFields := Map(), RightFields := Map()
		LeftFields.CaseSense := "On", RightFields.CaseSense := "On"
		for Pair in [[Left, LeftFields], [Right, RightFields]] {
			Owner := Pair[1], Fields := Pair[2]
			for Name in ObjOwnProps(Owner) {
				Descriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
				if !Descriptor.HasOwnProp("Value")
					return false
				Fields[Name] := Descriptor.Value
			}
		}
		if LeftFields.Count != RightFields.Count
			return false
		if Left is TOML_Bool {
			return LeftFields.Count == 1 && LeftFields.Has("Value") && RightFields.Has("Value")
				&& (LeftFields["Value"] is Integer) && LeftFields["Value"] == RightFields["Value"]
		}
		for Name, Value in LeftFields {
			if !RightFields.Has(Name) || !_ConfigTomlSnapshotEqual(Value, RightFields[Name])
				return false
		}
		return true
	}
	return Left is String ? StrCompare(Left, Right, true) == 0 : Left == Right
}
