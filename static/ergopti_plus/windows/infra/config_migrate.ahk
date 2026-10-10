; infra/config_migrate.ahk

; ==============================================================================
; MODULE: Config Migration
; DESCRIPTION:
; Versions config.toml at boot, before anything applies or saves it. It reads
; ``[_meta] schema_version``, runs the shared registry's steps for the ``ahk``
; driver in order, and publishes the migrated file once, after a verified
; byte-exact backup. The Windows counterpart of _shared/lua/config_migrate.lua;
; the registry is _shared/core/config_schema/migrations.toml and the decision
; record docs/adr/009-config-versioning.md.
;
; FEATURES & RATIONALE:
; 1. Data-only steps, read at runtime with the driver's own TOML reader. A
;    step is a list of ops from a closed set (rename, move_section, merge_into,
;    map_value, delete, set_if_absent) and this file holds their only Windows
;    semantics. The corpus under _shared/tests/corpus/config_migrations is
;    replayed here, by the Lua engine and by the JS reference, so the three
;    cannot drift; _shared/tests/corpus/config_migration_registries pins which
;    registries all three accept.
; 2. The loader's model. A section is a ``[header]`` path and a key one entry
;    inside it, exactly as the typed TOML parse returns them. Booleans stay
;    TOML_Bool, so map_value tells ``true`` from ``1`` like the other drivers.
; 3. Physical records. A migration-specific renderer preserves every untouched
;    source byte while applying explicit deltas. The candidate is read back
;    and must equal the migrated model before it may replace the file. The
;    stamp is set after every op; the publication refuses when the file
;    changed since it was read.
; 4. A newer, invalid or unparsable file, or any failure, is never written:
;    TOML_RefuseWrites makes every later TOML write to it refuse for the
;    session, and ConfigFullStateCanPersist keeps full saves disarmed.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include config_migrate_records.ahk

#Include config_registry_cache.ahk





; ===========================
; ===========================
; ======= 1/ Registry =======
; ===========================
; ===========================

; The shipped registry. Its path relative to _shared/ is pinned to the Lua
; engine's REGISTRY_PATH by tools/test/test-config-migrations.cjs. Constants
; live in function statics so no include order can leave them unset.
ConfigMigrateRegistryPath() {
	global _SharedDir
	static Relative := "core/config_schema/migrations.toml"
	return _SharedDir . "\" . StrReplace(Relative, "/", "\")
}

; Required and optional fields of each op of the closed set.
_ConfigMigrateOpFields() {
	static Fields := Map(
		"rename", [["section", "key"], ["to_section", "to_key"]],
		"copy_if_absent", [["section", "key"], ["to_section", "to_key"]],
		"move_ergopti_variant", [["section", "key", "to_key", "base_key", "alt_gr_key", "source_key", "false_variant", "true_variant"], ["neutral_variant"]],
		"move_chord_action", [["section", "key", "to_section", "action", "conditional_key", "disabled_action", "platform"], []],
		"move_section", [["section", "to_section"], []],
		"merge_into", [["section", "to_section"], []],
		"map_value", [["section", "key", "map"], []],
		"delete", [["section"], ["key"]],
		"set_if_absent", [["section", "key", "value"], []]
	)
	return Fields
}

; A positive integral number; a TOML 3.0 counts as 3 on every interpreter.
_ConfigMigrateIsVersion(Value) {
	if (Value is Integer)
		return Value >= 1
	return (Value is Float) && Value >= 1 && Value == Floor(Value)
}

_ConfigMigrateIsSectionPath(Text) {
	return (Text is String) && RegExMatch(Text, "^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$")
}

_ConfigMigrateIsBareKey(Text) {
	return (Text is String) && RegExMatch(Text, "^[A-Za-z0-9_-]+$")
}

_ConfigMigrateIsScalar(Value) {
	return (Value is String) || (Value is Integer) || (Value is Float) || (Value is TOML_Bool)
}

; Parses TOML text with the typed reader. Label names the text in errors and
; is never read as a file.
_ConfigMigrateParse(Source, Label) {
	Sections := _ParseTomlFileImpl("config-migration:" . Label, false, false, Source,
		true, &Discarded)
	if Discarded
		throw Error(Label . " has " . Discarded . " unterminated array(s)")
	return Sections
}

; Throws an Error naming the first reason Op is not a valid member of the set.
_ConfigMigrateValidateOp(Op, Where) {
	if !(Op is Map) || !Op.Has("op") || !(Op["op"] is String)
		throw Error(Where . ": an op must be an inline table with an op name")
	Fields := _ConfigMigrateOpFields()
	if !Fields.Has(Op["op"])
		throw Error(Where . ": unknown op '" . Op["op"] . "'")
	Allowed := Map("op", true)
	for Field in Fields[Op["op"]][1] {
		Allowed[Field] := true
		if !Op.Has(Field)
			throw Error(Where . ": " . Op["op"] . " needs '" . Field . "'")
	}
	for Field in Fields[Op["op"]][2]
		Allowed[Field] := true
	for Field in Op {
		if !Allowed.Has(Field)
			throw Error(Where . ": " . Op["op"] . " does not take '" . Field . "'")
	}
	for Field in ["section", "to_section"] {
		if Op.Has(Field) && !_ConfigMigrateIsSectionPath(Op[Field])
			throw Error(Where . ": '" . Field . "' must be a dotted path of bare segments")
	}
	for Field in ["key", "to_key", "conditional_key"] {
		if Op.Has(Field) && !_ConfigMigrateIsBareKey(Op[Field])
			throw Error(Where . ": '" . Field . "' must be one bare segment")
	}
	if ((Op["op"] == "rename" || Op["op"] == "copy_if_absent") && !Op.Has("to_section") && !Op.Has("to_key"))
		throw Error(Where . ": " . Op["op"] . " needs to_section or to_key")
	if Op["op"] == "move_ergopti_variant" {
		for Field in ["base_key", "alt_gr_key", "source_key", "false_variant", "true_variant"] {
			if !_ConfigMigrateIsBareKey(Op[Field])
				throw Error(Where . ": variant intent fields must be declared bare identifiers")
		}
		if Op["key"] == Op["to_key"] || Op["false_variant"] == Op["true_variant"]
			throw Error(Where . ": variant handoff requires distinct source, destination and choices")
		if Op.Has("neutral_variant") && (!_ConfigMigrateIsBareKey(Op["neutral_variant"])
			|| StrCompare(Op["neutral_variant"], Op["false_variant"], true) == 0
			|| StrCompare(Op["neutral_variant"], Op["true_variant"], true) == 0)
			throw Error(Where . ": neutral variant must be a distinct declared bare identifier")
		Seen := Map()
		for Field in ["key", "to_key", "base_key", "alt_gr_key", "source_key"] {
			if Seen.Has(Op[Field])
				throw Error(Where . ": variant intent participants must be distinct")
			Seen[Op[Field]] := true
		}
	}
	if (Op["op"] == "move_chord_action") {
		if !(Op["platform"] is String) || !(Op["platform"] == "macos")
			throw Error(Where . ": move_chord_action requires platform macos")
		for Field in ["action", "disabled_action"] {
			if !_ConfigMigrateIsBareKey(Op[Field])
				throw Error(Where . ": '" . Field . "' must be an action id")
		}
		if Op["section"] == Op["to_section"]
			throw Error(Where . ": move_chord_action must change section")
	}
	if (Op["op"] == "map_value") {
		if !(Op["map"] is Array) || Op["map"].Length == 0
			throw Error(Where . ": map_value needs a non-empty map")
		for Pair in Op["map"] {
			if !(Pair is Map) || Pair.Count != 2 || !Pair.Has("from") || !Pair.Has("to")
					|| !_ConfigMigrateIsScalar(Pair["from"]) || !_ConfigMigrateIsScalar(Pair["to"])
				throw Error(Where . ": each map entry is { from, to } with scalar values")
		}
	}
	if (Op["op"] == "set_if_absent" && !_ConfigMigrateIsScalar(Op["value"])) {
		if !(Op["value"] is Array)
			throw Error(Where . ": set_if_absent writes a scalar or an array")
		for Item in Op["value"] {
			if !_ConfigMigrateIsScalar(Item)
				throw Error(Where . ": set_if_absent arrays hold scalars only")
		}
	}
}

; Validates parsed registry sections and returns Map("current", "unstamped",
; "steps") with the steps in execution order, each a Map of "from", "to",
; "drivers" (a set), "reason" and "ops". Throws on the first defect.
ConfigMigrateValidateRegistry(Sections) {
	if !(Sections is Map) || !Sections.Has("registry")
		throw Error("the registry has no [registry] table")
	Head := Sections["registry"]
	for Field in Head {
		if !(Field == "current_version" || Field == "unstamped_version")
			throw Error("[registry] has an unknown key '" . Field . "'")
	}
	Current := Head.Get("current_version", "")
	Unstamped := Head.Get("unstamped_version", "")
	if !_ConfigMigrateIsVersion(Current) || !_ConfigMigrateIsVersion(Unstamped)
			|| Unstamped > Current
		throw Error("current_version and unstamped_version must be integers with 1 <= unstamped <= current")
	Current := Integer(Current)
	Unstamped := Integer(Unstamped)
	Steps := []
	for Name, Step in Sections {
		if (Name == "registry")
			continue
		; An empty [steps] header next to its sub-tables is valid TOML; the Lua
		; and JS decoders cannot even tell it from an implicit one.
		if (Name == "steps" && (Step is Map) && Step.Count == 0)
			continue
		if (SubStr(Name, 1, 6) != "steps.")
			throw Error("the registry has an unknown table [" . Name . "]")
		Id := SubStr(Name, 7)
		for Field in Step {
			if !(Field == "from" || Field == "to" || Field == "drivers" || Field == "reason"
					|| Field == "ops")
				throw Error("step '" . Id . "' has an unknown field '" . Field . "'")
		}
		From := Step.Get("from", "")
		if !_ConfigMigrateIsVersion(From) || !_ConfigMigrateIsVersion(Step.Get("to", ""))
				|| Step["to"] != From + 1
			throw Error("step '" . Id . "' must go from N to N + 1")
		From := Integer(From)
		if (Id !== "v" . From . "_to_v" . (From + 1))
			throw Error("step '" . Id . "' is misnamed")
		Drivers := Step.Get("drivers", "")
		if !(Drivers is Array) || Drivers.Length == 0
			throw Error("step '" . Id . "' names no driver")
		DriverSet := Map()
		for Driver in Drivers {
			if !(Driver is String) || !(Driver == "ahk" || Driver == "hs" || Driver == "linux")
				throw Error("step '" . Id . "' names an unknown driver")
			DriverSet[Driver] := true
		}
		Reason := Step.Get("reason", "")
		if !(Reason is String) || Trim(Reason) == ""
			throw Error("step '" . Id . "' has no reason")
		Ops := Step.Get("ops", "")
		if !(Ops is Array)
			throw Error("step '" . Id . "' has no ops array")
		for Index, Op in Ops
			_ConfigMigrateValidateOp(Op, "step '" . Id . "' op " . Index)
		Steps.Push(Map("from", From, "to", From + 1, "drivers", DriverSet,
			"reason", Reason, "ops", Ops))
	}
	if (Steps.Length != Current - Unstamped)
		throw Error("the steps do not chain v" . Unstamped . " to v" . Current)
	Ordered := []
	loop Steps.Length {
		Wanted := Unstamped + A_Index - 1
		Found := 0
		for Step in Steps {
			if (Step["from"] == Wanted) {
				Found := Step
				break
			}
		}
		if !(Found is Map)
			throw Error("the chain has a gap at v" . Wanted)
		Ordered.Push(Found)
	}
	return Map("current", Current, "unstamped", Unstamped, "steps", Ordered)
}

; Reads and validates a registry file. Throws on any defect.
ConfigMigrateLoadRegistry(Path) {
	if !FileExist(Path)
		throw Error("the registry '" . Path . "' does not exist")
	Source := FSReadUtf8Exact(Path)
	if !(Source is String)
		throw Error("the registry '" . Path . "' could not be read")
	return ConfigMigrateValidateRegistry(_ConfigMigrateParse(Source, "the registry '" . Path . "'"))
}

; The shipped registry, validated once per process. Throws when it is broken:
; a build that cannot name its own config version must not stamp one.
ConfigMigrateShippedRegistry() {
	static Registry := 0
	if !(Registry is Map)
		Registry := ConfigRegistryCacheLoad(ConfigMigrateRegistryPath(),
			EnvGet("LOCALAPPDATA") . "\ergopti_plus\cache\migration-registry-v1.cache")
	return Registry
}

; The version every file this build writes carries.
ConfigMigrateCurrentVersion() {
	return ConfigMigrateShippedRegistry()["current"]
}

; Adds the schema stamp to a writer's Updates when Path does not exist yet: a
; file this build creates carries this build's version, so a later boot never
; migrates it as an unstamped, older one. An existing file keeps the stamp the
; boot migration gave it; stamping it here would skip the steps it still needs.
ConfigMigrateStampNewFile(Updates, Path) {
	if !FileExist(Path)
		Updates.Push({ Section: "_meta", Key: "schema_version", Value: ConfigMigrateCurrentVersion() })
	return Updates
}





; ======================
; ======================
; ======= 2/ Ops =======
; ======================
; ======================

; The comparison class of a typed value: integers and floats compare by value,
; every other value only within its own kind.
_ConfigMigrateKind(Value) {
	return _TOML_ValueKind(Value)
}

; The document reader owns typed equality for both migration and ordinary saves.
ConfigMigrateSameValue(Left, Right) {
	return TOML_SameValue(Left, Right)
}

; Whether two models hold the same configuration: a section without keys and
; an absent one are the same.
ConfigMigrateSameModel(Left, Right) {
	for Section, Entries in Left {
		if (Entries.Count == 0)
			continue
		if !Right.Has(Section) || !ConfigMigrateSameValue(Entries, Right[Section])
			return false
	}
	for Section, Entries in Right {
		if (Entries.Count > 0) && (!Left.Has(Section) || Left[Section].Count == 0)
			return false
	}
	return true
}

; A copy of the model with its own section Maps; values are shared.
_ConfigMigrateClone(Model) {
	Copy := Map()
	for Section, Entries in Model
		Copy[Section] := Entries.Clone()
	return Copy
}

; Name and every dotted child, in the Map's sorted order.
_ConfigMigrateSectionsAtOrBelow(Model, Name) {
	Out := []
	Prefix := Name . "."
	for Section in Model {
		if (Section == Name || SubStr(Section, 1, StrLen(Prefix)) == Prefix)
			Out.Push(Section)
	}
	return Out
}

_ConfigMigrateDropIfEmpty(Model, Name) {
	if Model.Has(Name) && Model[Name].Count == 0
		Model.Delete(Name)
}

; The keys of a section, captured before a loop moves them.
_ConfigMigrateKeys(Entries) {
	Keys := []
	for Key in Entries
		Keys.Push(Key)
	return Keys
}

; Moves one value; an existing target keeps its value.
_ConfigMigrateMove(Model, Section, Key, ToSection, ToKey) {
	if !Model.Has(Section) || !Model[Section].Has(Key)
		return
	Value := Model[Section][Key]
	Model[Section].Delete(Key)
	if !Model.Has(ToSection)
		Model[ToSection] := Map()
	if !Model[ToSection].Has(ToKey) {
		Model[ToSection][ToKey] := Value
		return
	}
	try LoggerInfo("ConfigMigrate", "[{1}] {2} already holds a value; the old [{3}] {4} is dropped.",
		ToSection, ToKey, Section, Key)
}

; Ancestor values and child sections occupy their whole destination namespace.
; This check belongs only to conditional copies; existing operations keep
; their own conflict rules.
_ConfigMigrateCopyDestinationAbsent(Model, Section, Key) {
	if Model.Has(Section) && Model[Section].Has(Key)
		return false
	Parent := ""
	for Name in StrSplit(Section, ".") {
		if Model.Has(Parent) && Model[Parent].Has(Name)
			return false
		Parent := Parent == "" ? Name : Parent . "." . Name
	}
	return _ConfigMigrateSectionsAtOrBelow(Model, Section . "." . Key).Length == 0
}

; Resolve only aliases and groups declared by the injected shared catalogue.
_ConfigMigrateChordActionSlot(Value, Catalogue, PlatformName) {
	if !(Value is Map) || Value.Count != 2 || !Value.Has("mods") || !Value.Has("key")
			|| !(Value["mods"] is Array) || !(Value["key"] is String)
		return ""
	for Field in Value {
		if !(Field == "mods" || Field == "key")
			return ""
	}
	Platform := Catalogue["platforms"][PlatformName]
	Aliases := Map(), Wanted := Map()
	for Modifier in Platform["modifiers"] {
		Aliases[Modifier["id"]] := Modifier["id"]
		Aliases[Modifier["hammerspoon"]] := Modifier["id"]
	}
	for Modifier in Value["mods"] {
		if !(Modifier is String)
			return ""
		Id := Aliases.Get(StrLower(Modifier), "")
		if Id == "" || Wanted.Has(Id)
			return ""
		Wanted[Id] := true
	}
	KeyId := ""
	Candidate := StrLower(Value["key"])
	for Key in Catalogue["keys"] {
		if Candidate == Key["id"] || Candidate == Key.Get("chord_key", Key["id"])
				|| Candidate == Key.Get("macos_key", Key["id"]) {
			KeyId := Key["id"]
			break
		}
	}
	if KeyId == ""
		return ""
	for Group in Platform["shortcut_groups"] {
		Matched := Group["modifiers"].Length == Value["mods"].Length
		for Modifier in Group["modifiers"] {
			if !Wanted.Has(Modifier)
				Matched := false
		}
		if Matched
			return Group["prefix"] . KeyId
	}
	return ""
}

_ConfigMigrateActionDestinationRepresented(Model, Section, Key, Actions) {
	if Model.Has(Section) && Model[Section].Has(Key) {
		Value := Model[Section][Key]
		return (Value is String) && Actions.Get(Value, false) == true
	}
	return _ConfigMigrateCopyDestinationAbsent(Model, Section, Key)
}

; Resolve every destination before changing any record. Unsupported legacy or
; occupied, unrecognized choices retain their old source and native owner.
_ConfigMigrateMoveChordAction(Model, Op, Context) {
	ChildPath := Op["section"] . "." . Op["key"]
	ChildSource := false
	if Model.Has(Op["section"]) && Model[Op["section"]].Has(Op["key"])
		Value := Model[Op["section"]][Op["key"]]
	else if Model.Has(ChildPath) {
		if _ConfigMigrateSectionsAtOrBelow(Model, ChildPath).Length != 1
			return
		Value := Model[ChildPath]
		ChildSource := true
	} else
		return
	if !(Context is Map) || !(Context.Get("modifier_chords", 0) is Map)
			|| !(Context.Get("assignable_actions", 0) is Map)
		throw Error("config_migrate: missing chord action context")
	Catalogue := Context["modifier_chords"], Actions := Context["assignable_actions"]
	if !Catalogue.Has("keys") || !Catalogue.Has("platforms") || !Catalogue["platforms"].Has(Op["platform"])
		throw Error("config_migrate: missing chord action context")
	if !Actions.Get(Op["action"], false) || !Actions.Get(Op["disabled_action"], false)
		throw Error("config_migrate: migration action is absent from the action catalogue")
	Disabled := (Value is TOML_Bool) && Value.Value == false
	Slot := Disabled ? "" : _ConfigMigrateChordActionSlot(Value, Catalogue, Op["platform"])
	if (!Disabled && Slot == "") || Slot == Op["conditional_key"]
		return
	Section := Op["to_section"]
	if !_ConfigMigrateActionDestinationRepresented(Model, Section, Op["conditional_key"], Actions)
			|| (Slot != "" && !_ConfigMigrateActionDestinationRepresented(Model, Section, Slot, Actions))
		return
	if !Model.Has(Section)
		Model[Section] := Map()
	Target := Model[Section]
	if Slot != "" && !Target.Has(Slot)
		Target[Slot] := Op["action"]
	if !Target.Has(Op["conditional_key"])
		Target[Op["conditional_key"]] := Op["disabled_action"]
	if ChildSource
		Model.Delete(ChildPath)
	else {
		Model[Op["section"]].Delete(Op["key"])
		_ConfigMigrateDropIfEmpty(Model, Op["section"])
	}
}

; Applies one validated op to the model.
_ConfigMigrateApplyOp(Model, Op, Context := 0) {
	Section := Op["section"]
	switch Op["op"] {
		case "rename":
			ToSection := Op.Get("to_section", Section)
			_ConfigMigrateMove(Model, Section, Op["key"], ToSection, Op.Get("to_key", Op["key"]))
			_ConfigMigrateDropIfEmpty(Model, Section)
			_ConfigMigrateDropIfEmpty(Model, ToSection)
		case "copy_if_absent":
			if !Model.Has(Section) || !Model[Section].Has(Op["key"])
				return
			ToSection := Op.Get("to_section", Section)
			ToKey := Op.Get("to_key", Op["key"])
			if !_ConfigMigrateCopyDestinationAbsent(Model, ToSection, ToKey)
				return
			if !Model.Has(ToSection)
				Model[ToSection] := Map()
			Model[ToSection][ToKey] := ManifestCloneValue(Model[Section][Op["key"]])
		case "move_ergopti_variant":
			_ConfigMigrateMoveErgoptiVariant(Model, Op)
		case "move_chord_action":
			_ConfigMigrateMoveChordAction(Model, Op, Context)
		case "move_section":
			for Name in _ConfigMigrateSectionsAtOrBelow(Model, Section) {
				Target := Op["to_section"] . SubStr(Name, StrLen(Section) + 1)
				for Key in _ConfigMigrateKeys(Model[Name])
					_ConfigMigrateMove(Model, Name, Key, Target, Key)
				Model.Delete(Name)
				_ConfigMigrateDropIfEmpty(Model, Target)
			}
		case "merge_into":
			if !Model.Has(Section)
				return
			for Key in _ConfigMigrateKeys(Model[Section])
				_ConfigMigrateMove(Model, Section, Key, Op["to_section"], Key)
			Model.Delete(Section)
			_ConfigMigrateDropIfEmpty(Model, Op["to_section"])
		case "map_value":
			if !Model.Has(Section) || !Model[Section].Has(Op["key"])
				return
			for Pair in Op["map"] {
				if ConfigMigrateSameValue(Pair["from"], Model[Section][Op["key"]]) {
					Model[Section][Op["key"]] := Pair["to"]
					return
				}
			}
		case "delete":
			if !Op.Has("key") {
				for Name in _ConfigMigrateSectionsAtOrBelow(Model, Section)
					Model.Delete(Name)
			} else if Model.Has(Section) {
				if Model[Section].Has(Op["key"])
					Model[Section].Delete(Op["key"])
				_ConfigMigrateDropIfEmpty(Model, Section)
			}
		case "set_if_absent":
			if !Model.Has(Section)
				Model[Section] := Map()
			if !Model[Section].Has(Op["key"])
				Model[Section][Op["key"]] := Op["value"]
		default:
			throw Error("unknown config migration op '" . Op["op"] . "'")
	}
}

; Reads a model's version against a registry: "current", "migrate", "newer",
; "invalid" or "unsupported". Version receives the file's version (the
; unstamped version when the file carries none).
ConfigMigrateClassify(Model, Registry, &Version) {
	Version := Registry["unstamped"]
	if Model.Has("_meta") && Model["_meta"].Has("schema_version") {
		Version := Model["_meta"]["schema_version"]
		if !_ConfigMigrateIsVersion(Version)
			return "invalid"
		Version := Integer(Version)
	}
	if (Version > Registry["current"])
		return "newer"
	if (Version == Registry["current"])
		return "current"
	if (Version < Registry["unstamped"])
		return "unsupported"
	return "migrate"
}

; The canonical document owns metadata identity even when the legacy flat
; operation model cannot address its dotted, inline or quoted source spelling.
; Non-array metadata tables alone may classify a version; a scalar or table
; array must never borrow a flattened member's current-version authority.
_ConfigMigrateClassifyDocument(Document, Registry, &Version) {
	Version := Registry["unstamped"]
	if Document.Has("_meta") && !(Document["_meta"] is Map)
		return "invalid"
	return ConfigMigrateClassify(Document, Registry, &Version)
}

; Runs every step at or above FromVersion that names Driver, then stamps the
; registry's current version. Mutates and returns Model.
ConfigMigrateApplySteps(Model, Registry, Driver, FromVersion, Context := 0) {
	for Step in Registry["steps"] {
		if (Step["from"] < FromVersion) || !Step["drivers"].Has(Driver)
			continue
		for Op in Step["ops"]
			_ConfigMigrateApplyOp(Model, Op, Context)
	}
	if !Model.Has("_meta")
		Model["_meta"] := Map()
	Model["_meta"]["schema_version"] := Registry["current"]
	return Model
}





; ============================
; ============================
; ======= 3/ Candidate =======
; ============================
; ============================

; The batch-writer image of After over Before: a value for every new or
; changed key, a deletion for every vanished key, and a dropped header for a
; section that vanished with nothing surviving below it. A deletion alone
; would leave an empty header, and a drop over a surviving child would take
; the child too; the writer compares section names without case.
_ConfigMigrateWriterBatch(Before, After, &DropSections) {
	Updates := []
	DropSections := []
	for Section, Entries in After {
		for Key, Value in Entries {
			if !(Before.Has(Section) && Before[Section].Has(Key)
					&& ConfigMigrateSameValue(Before[Section][Key], Value))
				Updates.Push({ Section: Section, Key: Key, Value: Value })
		}
	}
	for Section in Before {
		if After.Has(Section)
			continue
		Survivor := false
		for Name in After {
			if (Name = Section || InStr(Name, Section . ".") == 1) {
				Survivor := true
				break
			}
		}
		if !Survivor
			DropSections.Push(Section)
	}
	for Section, Entries in Before {
		Dropped := false
		for Name in DropSections {
			if (Section = Name || InStr(Section, Name . ".") == 1) {
				Dropped := true
				break
			}
		}
		if Dropped
			continue
		for Key in Entries {
			if !(After.Has(Section) && After[Section].Has(Key))
				Updates.Push({ Section: Section, Key: Key, Delete: 1 })
		}
	}
	return Updates
}

; A stamp-only migration has no configuration edit to serialize. Preserve the
; original records and comments, changing only the scalar metadata value.
_ConfigMigrateStampCandidate(Source, Version, Scan) {
	Bom := SubStr(Source, 1, 1) == Chr(0xFEFF) ? Chr(0xFEFF) : ""
	Text := Bom != "" ? SubStr(Source, 2) : Source
	Eol := InStr(Text, "`r`n") ? "`r`n" : "`n"
	Section := ""
	MetaInsert := 0
	Offset := 1
	Depth := 0
	Quote := ""
	Escaped := false
	loop parse, Text, "`n" {
		Row := A_LoopField
		Line := Trim(Row, " `t`r")
		if Depth > 0 {
			Depth := _TOML_ArrayScanFragment(TOML_StripInlineComment(Line), Depth, &Quote, &Escaped)
		} else if SubStr(Line, 1, 1) == "[" {
			Header := TOML_StripInlineComment(Line)
			Section := Trim(RegExReplace(Header, "^\[+|\]+$", ""))
			if Section == "_meta"
				MetaInsert := Offset + StrLen(Row) + (Offset + StrLen(Row) <= StrLen(Text) ? 1 : 0)
		} else if RegExMatch(Line, '^(?:"schema_version"|schema_version)\s*=', &KeyMatch) && Section == "_meta" {
			if !RegExMatch(Row, '^(\s*(?:"schema_version"|schema_version)\s*=\s*)([^\s#]+)', &ValueMatch)
				throw Error("The migration metadata stamp cannot be located.")
			Start := Offset + ValueMatch.Pos(2) - 1
			return Bom . SubStr(Text, 1, Start - 1) . Version . SubStr(Text, Start + ValueMatch.Len(2))
		} else {
			Eq := InStr(Line, "=")
			Value := Eq ? TOML_StripInlineComment(Trim(SubStr(Line, Eq + 1))) : ""
			if SubStr(Value, 1, 1) == "["
				Depth := _TOML_ArrayScanFragment(Value, 0, &Quote, &Escaped)
		}
		Offset += StrLen(Row) + 1
	}
	Stamp := "schema_version = " . Version . Eol
	if MetaInsert {
		Separator := MetaInsert > StrLen(Text) && SubStr(Text, -1) != "`n" ? Eol : ""
		return Bom . SubStr(Text, 1, MetaInsert - 1) . Separator . Stamp . SubStr(Text, MetaInsert)
	}
	; The shared record owner inserts new metadata after opaque root records.
	return _ConfigMigrateRenderRecords(Source,
		[{ Section: "_meta", Key: "schema_version", Value: Version }], [], Scan)["content"]
}

; Plans the migration of Source for Driver without I/O. Returns Map("outcome",
; "version", "detail") where outcome is "current", "migrated", "newer",
; "invalid", "unsupported" or "failed"; a "migrated" plan also carries the
; "candidate" text and the migrated "model".
ConfigMigratePlan(Source, Registry, Driver, Context := 0) {
	Plan := Map("outcome", "failed", "version", "", "detail", "")
	try Before := _ConfigMigrateParse(Source, "config.toml")
	catch as Err {
		Plan["detail"] := "the file is not valid TOML: " . Err.Message
		return Plan
	}
	try {
		Scan := _ConfigMigrateRecordScan(Source)
		_ConfigMigrateRecordValidateModel(Scan, Before)
		; Raw native cells cannot distinguish dotted and quoted semantic aliases.
		; This read-only proof leaves that model and every source byte intact.
		Document := TOML_ParseDocument(Source)
	} catch as Err {
		Plan["detail"] := "the migration record owner refused: " . Err.Message
		return Plan
	}
	Outcome := _ConfigMigrateClassifyDocument(Document, Registry, &Version)
	Plan["version"] := Version
	if (Outcome != "migrate") {
		Plan["outcome"] := Outcome
		return Plan
	}
	; Current canonical metadata needs no physical rewrite. An older version
	; still needs the existing operation owner to address that exact stamp.
	ConfigMigrateClassify(Before, Registry, &LegacyVersion)
	if LegacyVersion != Version || (Document.Has("_meta")
			&& Document["_meta"].Has("schema_version")
			&& !(Before.Has("_meta") && Before["_meta"].Has("schema_version"))) {
		Plan["outcome"] := "failed"
		Plan["detail"] := "legacy metadata is not addressable by this migration owner"
		return Plan
	}
	try _ConfigMigrateVariantSourceWitness(Source, Scan, Before, Registry, Driver, Version)
	catch ConfigMigrateVariantRefusal as Err {
		Plan["outcome"] := "invalid"
		Plan["detail"] := Err.Message
		return Plan
	}
	try _ConfigMigrateRecordValidateSources(Scan, Before, Registry, Driver, Version)
	catch as Err {
		Plan["detail"] := "the migration record source refused: " . Err.Message
		return Plan
	}
	try After := ConfigMigrateApplySteps(_ConfigMigrateClone(Before), Registry, Driver, Version, Context)
	catch ConfigMigrateVariantRefusal as Err {
		Plan["outcome"] := "invalid"
		Plan["detail"] := Err.Message
		return Plan
	}
	Updates := _ConfigMigrateWriterBatch(Before, After, &DropSections)
	try {
		if Updates.Length == 1 && DropSections.Length == 0
				&& Updates[1].Section == "_meta" && Updates[1].Key == "schema_version" {
			_ConfigMigrateRecordValidateTargets(Scan, Updates, DropSections)
			Built := Map("status", "ok", "content", _ConfigMigrateStampCandidate(Source, Registry["current"], Scan))
		} else
			Built := _ConfigMigrateRenderRecords(Source, Updates, DropSections, Scan)
	} catch as Err {
		Plan["detail"] := "the migration record renderer refused: " . Err.Message
		return Plan
	}
	if !(Built is Map) || Built.Get("status", "") != "ok" || !(Built.Get("content", 0) is String) {
		Plan["detail"] := "the record renderer refused the migrated configuration"
		return Plan
	}
	try {
		; A new header can redeclare an existing dotted parent even when the
		; old flat model reads back exactly. Prove its semantic namespace too.
		TOML_ParseDocument(Built["content"])
		Reread := _ConfigMigrateParse(Built["content"], "the migrated candidate")
	} catch as Err {
		Plan["detail"] := "the migrated candidate does not parse: " . Err.Message
		return Plan
	}
	if !ConfigMigrateSameModel(Reread, After) {
		Plan["detail"] := "the rewritten file would not read back as the migrated configuration"
		return Plan
	}
	Plan["outcome"] := "migrated"
	Plan["candidate"] := Built["content"]
	Plan["model"] := After
	return Plan
}





; =======================
; =======================
; ======= 4/ Boot =======
; =======================
; =======================

; ``config.toml`` + 3 + "20260924-101500" -> ``config.pre-v3-20260924-101500.toml``
; in the same directory: the bytes as they were before version 3.
ConfigMigrateBackupPath(FilePath, Version, Stamp) {
	SplitPath(FilePath, , &Dir, &Ext, &NameNoExt)
	return Dir . "\" . NameNoExt . ".pre-v" . Version . "-" . Stamp . (Ext != "" ? "." . Ext : "")
}

; Replaces FilePath with Candidate while it still holds exactly Source,
; through a verified same-directory stage. Returns "" on success, else why not.
_ConfigMigratePublish(FilePath, Candidate, Source, AdmissionFn := 0) {
	global _ParseTomlCache
	static Sequence := 0
	Sequence += 1
	StagePath := FilePath . "." . A_ScriptHwnd . "-migration-" . Sequence . ".stage"
	if !_FSNativeAdmissionAccepted(AdmissionFn)
		return "the actual migration owner lost registry/lease admission before staging"
	if !FSWriteDurable(StagePath, Candidate) || !FSUtf8ExactMatches(StagePath, Candidate) {
		try FSDelete(StagePath)
		return "the staging file could not be written and verified"
	}
	; Report verified staging before the final source/native admission boundary;
	; this identifies the owned path without disclosing configuration content.
	try LoggerInfo("ConfigMigrate", "Verified durable migration stage '{1}' for '{2}' before native publication.",
		StagePath, FilePath)
	if !FSUtf8ExactMatches(FilePath, Source) {
		try FSDelete(StagePath)
		return "the file changed after it was read"
	}
	if !FSConfigAtomicMoveReplace(StagePath, FilePath, &NativeError, AdmissionFn) {
		try FSDelete(StagePath)
		return "the atomic replace was refused"
	}
	if _ParseTomlCache.Has(FilePath)
		_ParseTomlCache.Delete(FilePath)
	return ""
}

; Migrates FilePath for the Windows driver. Returns Map("status", "read_only",
; "from", "to", "backup", "detail"); status is "absent", "current",
; "migrated", "newer", "invalid", "unsupported" or "failed", and only
; "migrated" changes the file. Every status but "absent", "current" and
; "migrated" refuses every later TOML write to FilePath for the session
; (read_only = 1). Registry (a validated Map; the shipped one by default),
; Stamp, BackupFn(Path, Content) -> 1 (must refuse an existing path) and
; PublishFn(Path, Candidate, Source) -> "" are test seams.
ConfigMigrateRun(FilePath, Registry := 0, Stamp := "", BackupFn := 0, PublishFn := 0, Context := 0, AdmissionFn := 0) {
	Result := Map("status", "failed", "read_only", 0, "from", "", "to", "",
		"backup", "", "detail", "")
	try LoggerStart("ConfigMigrate", "Checking the config schema version of '{1}' (ahk driver)…",
		FilePath)

	Refuse(Status, Detail) {
		Result["status"] := Status
		Result["detail"] := Detail
		Result["read_only"] := 1
		TOML_RefuseWrites(FilePath, Detail)
		try LoggerError("ConfigMigrate", "Config migration of '{1}' refused ({2}): {3}. The file is left "
			. "untouched and this session will not write it.", FilePath, Status, Detail)
		return Result
	}

	if !_FSNativeAdmissionAccepted(AdmissionFn)
		return Refuse("failed", "the actual boot registry owner refused before migration effects")
	if !(Registry is Map) {
		try Registry := ConfigMigrateShippedRegistry()
		catch as Err
			return Refuse("failed", Err.Message)
	}
	Result["to"] := Registry["current"]
	if !FileExist(FilePath) {
		Result["status"] := "absent"
		try LoggerSuccess("ConfigMigrate", "No config file at '{1}' yet; nothing to migrate.", FilePath)
		return Result
	}

	Owner := _ConfigWriteLeaseTryAcquire(FilePath, "migration")
	if !(Owner is Object)
		return Refuse("failed", "another configuration transaction owns the file")
	MigrationAdmission := () => _ConfigWriteLeaseOwns(Owner, FilePath) && _FSNativeAdmissionAccepted(AdmissionFn)
	try {
		if !_FSNativeAdmissionAccepted(MigrationAdmission)
			return Refuse("failed", "the migration source/lease lost registry admission")
		; Keep the loader's lenient current-file contract, but prove physical
		; ownership before a fabricated version could authorize later writes.
		Before := TOML_ParseFreshFileTyped(FilePath, &Discarded)
		if TOML_ReadFailed(FilePath)
			return Refuse("failed", "the file could not be read")
		if Discarded
			return Refuse("failed", "the file has " . Discarded . " unterminated array(s)")
		try {
			VersionSource := FSReadStrict(FilePath)
			VersionScan := _ConfigMigrateRecordScan(VersionSource)
			_ConfigMigrateRecordValidateModel(VersionScan, Before)
			VersionDocument := TOML_ParseDocument(VersionSource)
			if !ConfigMigrateSameModel(Before, _ConfigMigrateParse(VersionSource, "the version snapshot"))
				return Refuse("failed", "the file changed while its physical version ownership was checked")
		} catch as Err
			return Refuse("failed", "the physical version owner refused: " . Err.Message)
		Outcome := _ConfigMigrateClassifyDocument(VersionDocument, Registry, &Version)
		Result["from"] := Version
		switch Outcome {
			case "current":
				Result["status"] := "current"
				try LoggerSuccess("ConfigMigrate", "'{1}' is at schema v{2}; nothing to migrate.",
					FilePath, Registry["current"])
				return Result
			case "newer":
				return Refuse("newer", "the file declares schema v" . Version
					. ", newer than this build's v" . Registry["current"])
			case "invalid":
				return Refuse("invalid", "[_meta] schema_version is not a positive integer")
			case "unsupported":
				return Refuse("unsupported", "no migration path from schema v" . Version)
		}

		ConfigMigrateClassify(Before, Registry, &LegacyVersion)
		if LegacyVersion != Version || (VersionDocument.Has("_meta")
				&& VersionDocument["_meta"].Has("schema_version")
				&& !(Before.Has("_meta") && Before["_meta"].Has("schema_version")))
			return Refuse("failed", "legacy metadata is not addressable by this migration owner")

		Source := FSReadUtf8Exact(FilePath)
		if !(Source is String)
			return Refuse("failed", "the file is not exact UTF-8, so it cannot be backed up byte for byte")
		Plan := ConfigMigratePlan(Source, Registry, "ahk", Context)
		if (Plan["outcome"] != "migrated") {
			VariantInvalid := Plan["outcome"] == "invalid"
				&& SubStr(Plan["detail"], 1, StrLen("Ergopti variant migration refused:")) == "Ergopti variant migration refused:"
			return Refuse(VariantInvalid ? "invalid" : "failed", Plan["detail"] != "" ? Plan["detail"]
				: "the file changed while it was classified")
		}

		if !_FSNativeAdmissionAccepted(MigrationAdmission)
			return Refuse("failed", "the migration source/lease lost registry admission before backup")
		BackupPath := ConfigMigrateBackupPath(FilePath, Registry["current"],
			Stamp != "" ? Stamp : FormatTime(A_Now, "yyyyMMdd-HHmmss"))
		Result["backup"] := BackupPath
		Written := HasMethod(BackupFn, "Call") ? BackupFn.Call(BackupPath, Source)
			: FSWriteCreateDurable(BackupPath, Source)
		if !((Written is Integer) && Written == 1) || !FSUtf8ExactMatches(BackupPath, Source)
			return Refuse("failed", "the backup '" . BackupPath . "' could not be written and verified")
		if !_FSNativeAdmissionAccepted(MigrationAdmission)
			return Refuse("failed", "the migration source/lease lost registry admission after backup")
		Published := HasMethod(PublishFn, "Call") ? PublishFn.Call(FilePath, Plan["candidate"], Source)
			: _ConfigMigratePublish(FilePath, Plan["candidate"], Source, MigrationAdmission)
		if (Published != "")
			return Refuse("failed", "publication failed: " . Published)
	} finally {
		_ConfigWriteLeaseRelease(Owner)
	}

	Result["status"] := "migrated"
	try LoggerSuccess("ConfigMigrate", "Migrated '{1}' from schema v{2} to v{3}; backup at '{4}'.",
		FilePath, Result["from"], Registry["current"], Result["backup"])
	return Result
}

; One private issuer owns both read-only preparation and actual boot completion.
; Query requests expose checking closures, never mutable rows or phase setters.
ConfigMigrateBoot(FilePath, Request := "boot", Candidate := unset, OwnerBundle := unset) {
	static Destinations := Map()
	static Native := {
		exists: FSStrictExists, read: FSConfigReadUtf8Exact, generic_read: FSReadUtf8Exact, load_registry: ConfigMigrateLoadRegistry,
		registry_path: ConfigMigrateRegistryPath, registry: ConfigMigrateShippedRegistry,
		decode: TOML_ParseDocument, classify: _ConfigMigrateClassifyDocument,
		migrate: ConfigMigrateRun, key: FileReadActivityKey,
		clone: ManifestCloneValue, same: ConfigMigrateSameValue,
		terminal_owns: _ConfigWriteTerminalOwnsExact, variant_refusal: _ConfigMigrateVariantBootRefusal,
		move: FSConfigAtomicMoveReplace, generic_move: FSAtomicMoveReplace, noop: FSNativeAcknowledge, config_write: TOML_ConfigBatchWrite, generic_write: TOML_BatchWrite, recovery_images: _ConfigTransitionNativeRecoveryImages
	}

	NativeLive() {
		for Name, Owner in ObjOwnProps(Native)
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		return Native.exists == FSStrictExists && Native.read == FSConfigReadUtf8Exact && Native.generic_read == FSReadUtf8Exact
			&& Native.load_registry == ConfigMigrateLoadRegistry
			&& Native.registry_path == ConfigMigrateRegistryPath
			&& Native.registry == ConfigMigrateShippedRegistry
			&& Native.decode == TOML_ParseDocument && Native.classify == _ConfigMigrateClassifyDocument
			&& Native.migrate == ConfigMigrateRun && Native.key == FileReadActivityKey
			&& Native.clone == ManifestCloneValue && Native.same == ConfigMigrateSameValue
			&& Native.terminal_owns == _ConfigWriteTerminalOwnsExact
			&& Native.variant_refusal == _ConfigMigrateVariantBootRefusal
			&& Native.move == FSConfigAtomicMoveReplace && Native.generic_move == FSAtomicMoveReplace && Native.noop == FSNativeAcknowledge
			&& Native.config_write == TOML_ConfigBatchWrite && Native.generic_write == TOML_BatchWrite
			&& Native.recovery_images == _ConfigTransitionNativeRecoveryImages
	}

	PlainContainer(Value, Prototype) {
		if !IsObject(Value) || ObjGetBase(Value) != Prototype
			return false
		for Name in ObjOwnProps(Value)
			return false
		return true
	}

	SameRegistry(Left, Right) {
		if Left is Map {
			if !PlainContainer(Left, Map.Prototype) || !PlainContainer(Right, Map.Prototype)
					|| Left.Count != Right.Count || Left.CaseSense != Right.CaseSense
				return false
			ExactRight := Map()
			ExactRight.CaseSense := "On"
			for Key, Value in Right
				ExactRight[Key] := Value
			for Key, Value in Left {
				if !ExactRight.Has(Key) || !SameRegistry(Value, ExactRight[Key])
					return false
			}
			return true
		}
		if Left is Array {
			if !PlainContainer(Left, Array.Prototype) || !PlainContainer(Right, Array.Prototype)
					|| Left.Length != Right.Length
				return false
			loop Left.Length {
				if !Left.Has(A_Index) || !Right.Has(A_Index)
						|| !SameRegistry(Left[A_Index], Right[A_Index])
					return false
			}
			return true
		}
		if Left is TOML_Bool {
			if !IsObject(Right) || ObjGetBase(Left) != TOML_Bool.Prototype
					|| ObjGetBase(Right) != TOML_Bool.Prototype
				return false
			for Value in [Left, Right] {
				Count := 0
				for Name in ObjOwnProps(Value) {
					if Name != "Value"
						return false
					Descriptor := Object.Prototype.GetOwnPropDesc.Call(Value, Name)
					if !Descriptor.HasOwnProp("Value") || !(Descriptor.Value is Integer)
						return false
					Count += 1
				}
				if Count != 1
					return false
			}
			return Left.Value == Right.Value
		}
		if IsObject(Left) || IsObject(Right)
			return false
		return Native.same.Call(Left, Right)
	}

	RegistryLive(Row) {
		if !NativeLive()
			return false
		try {
			CurrentRegistry := Native.registry.Call()
			return CurrentRegistry == Row.registry
				&& SameRegistry(CurrentRegistry, Row.registry_shadow)
		} catch {
			return false
		}
	}

	ReadImage(ObserveReadFailure := false) {
		if !NativeLive()
			return false
		try {
			Present := Native.exists.Call(FilePath)
			if !(Present is Integer) || (Present != 0 && Present != 1)
				return false
			NativeOpenError := 0
			Source := Present ? Native.read.Call(FilePath, &NativeOpenError) : ""
			if !(Source is String) {
				if ObserveReadFailure && (Source is Integer) && Source == 0
						&& (NativeOpenError is Integer) && NativeOpenError > 0
					RecordReadFailure(Present)
				return false
			}
			; An absent image needs the same strict native classification twice.
			if !Present && Native.exists.Call(FilePath)
				return false
			return { present: Present, source: Source }
		} catch as Err {
			; Only the genuine strict native existence probe throws OSError here;
			; acquisition/activity/type/owner refusal issues no physical receipt.
			if ObserveReadFailure && !IsSet(Present) && Err is OSError
				RecordReadFailure(0)
			return false
		}
	}

	RecordReadFailure(Present) {
		if !NativeLive() || !RegistryLive(Row) || Destinations[Key] != Row
				|| !(OwnerLive() || Row.phase == "prepared" || Row.phase == "refused")
			return
		; Private observed data is minted only by the original real native read.
		; It conveys neither readable source bytes nor write/READY permission.
		Row.read_failure := { path: FilePath, image: Row.image, phase: Row.phase,
			owner: Row.phase == "owned" ? Row.owned_bundle : false, present: Present }
	}

	ClassifyImage(Image, Row) {
		if !RegistryLive(Row)
			return "failed"
		if !Image.present
			return "fresh-missing"
		try {
			return Native.classify.Call(Native.decode.Call(Image.source), Row.registry_shadow, &Version)
		} catch {
			return "failed"
		}
	}

	if !(Request is String) || !(Request == "boot" || Request == "prepare" || Request == "prepare_owned"
			|| Request == "capture_read" || Request == "capture_write" || Request == "capture_noop" || Request == "capture_reconcile_noop" || Request == "capture_transition" || Request == "capture_recovery" || Request == "known" || Request == "check_write" || Request == "consume_read_failure" || Request == "read_only_status")
		throw ValueError("Unknown configuration journal request")
	if !(FilePath is String) || FilePath == "" || !NativeLive()
		return false
	if Request == "prepare_owned" && (!IsSet(OwnerBundle)
			|| !Native.terminal_owns.Call(OwnerBundle, FilePath))
		return false
	if Request == "capture_recovery" && (!IsSet(OwnerBundle) || !IsSet(Candidate)
			|| !(Candidate is String) || Candidate == "" || !Native.terminal_owns.Call(OwnerBundle, FilePath)
			|| !Native.terminal_owns.Call(OwnerBundle, Candidate))
		return false
	Key := Native.key.Call(FilePath)
	if Request == "known"
		return Destinations.Has(Key)
	if Request == "read_only_status" {
		; Observation returns only the retained boot classification, never source
		; bytes, a mutable journal row or preparation/write permission.
		if !Destinations.Has(Key)
			return ""
		ObservedRow := Destinations[Key]
		if !RegistryLive(ObservedRow) || ObservedRow.phase == "ready"
				|| !ObservedRow.HasOwnProp("classification")
			return ""
		for Status in ["newer", "invalid", "unsupported"]
			if ObservedRow.classification == Status
				return Status
		return ""
	}
	if Request == "consume_read_failure" {
		if !Destinations.Has(Key)
			return 0
		ObservedRow := Destinations[Key]
		if !ObservedRow.HasOwnProp("read_failure") || !RegistryLive(ObservedRow)
			return 0
		Failure := ObservedRow.read_failure
		Valid := Failure.image == ObservedRow.image && Failure.phase == ObservedRow.phase
			&& StrCompare(Failure.path, FilePath, true) == 0
			&& (Failure.phase == "ready" || Failure.phase == "prepared" || Failure.phase == "refused"
				|| (Failure.phase == "owned" && Failure.owner == ObservedRow.owned_bundle
					&& Native.terminal_owns.Call(Failure.owner, FilePath)))
		ObservedRow.DeleteProp("read_failure")
		return Valid ? (Failure.present == 1 ? 2 : 1) : 0
	}
	if !Destinations.Has(Key) {
		; Public/custom migration results cannot construct a row. Only genuine
		; native registry and exact source observations reach this constructor.
		if Request != "boot" && Request != "prepare" && Request != "prepare_owned" && Request != "capture_recovery"
			return false
		Row := { phase: "constructing", path: FilePath, image: false, recovery_initialized: Request == "capture_recovery" }
		PreviousCritical := Critical("On")
		try Destinations[Key] := Row
		finally Critical(PreviousCritical)
		try {
			FreshRegistry := Native.load_registry.Call(Native.registry_path.Call())
			Row.registry := Native.registry.Call()
			if !SameRegistry(FreshRegistry, Row.registry)
				throw Error("The default registry differs from its native source")
			Row.registry_shadow := Native.clone.Call(FreshRegistry)
			if !RegistryLive(Row)
				throw Error("The default registry does not match its native source")
			Image := ReadImage()
			if !(Image is Object)
				throw Error("The exact configuration source could not be classified")
			Row.image := Image
			Row.classification := ClassifyImage(Image, Row)
			if Row.classification == "failed"
				throw Error("The canonical configuration source could not be classified")
			Row.phase := "prepared"
		} catch as Err {
			Row.phase := "refused"
			Row.detail := Err.Message
			TOML_RefuseWrites(FilePath, Err.Message)
			return false
		}
		if Request == "prepare"
			return Map("status", Row.classification, "read_only", 1)
	} else {
		Row := Destinations[Key]
		if Request == "prepare" {
			if !Row.recovery_initialized || Row.phase != "prepared"
				throw Error("The configuration source was already initialized")
			; Cold native WAL recovery may restore the admitted old image before
			; the normal readonly startup handoff. Observe it genuinely once.
			Image := ReadImage()
			if !(Image is Object) || !RegistryLive(Row)
				return false
			Classification := ClassifyImage(Image, Row)
			if Classification == "failed"
				return false
			PreviousCritical := Critical("On")
			try {
				Row.image := Image
				Row.classification := Classification
				Row.recovery_initialized := false
				Row.phase := "prepared"
			} finally Critical(PreviousCritical)
			return Map("status", Classification, "read_only", 1)
		}
	}

	if Request == "prepare_owned" {
		; Only the actual retained native target issuer may admit pre-boot wizard
		; writes. Current/fresh source construction does not manufacture READY.
		if !(Row.phase == "prepared" || Row.phase == "ready" || Row.phase == "owned")
				|| !RegistryLive(Row) || TOML_WriteRefusal(FilePath) != ""
			return false
		Image := ReadImage()
		if !(Image is Object)
			return false
		Classification := ClassifyImage(Image, Row)
		if !(Classification == "current" || Classification == "fresh-missing")
			return false
		if Row.phase == "prepared" && (Image.present != Row.image.present
				|| StrCompare(Image.source, Row.image.source, true) != 0)
			return false
		if Row.phase == "owned" && Row.owned_bundle != OwnerBundle
				&& Native.terminal_owns.Call(Row.owned_bundle, FilePath)
			return false
		PreviousCritical := Critical("On")
		try {
			if !RegistryLive(Row) || !Native.terminal_owns.Call(OwnerBundle, FilePath)
				return false
			Row.image := Image
			Row.classification := Classification
			Row.owned_bundle := OwnerBundle
			Row.phase := "owned"
		} finally Critical(PreviousCritical)
		return Map("status", Classification, "read_only", 0)
	}

	OwnerLive() {
		return Row.phase == "ready" || (Row.phase == "owned"
			&& Native.terminal_owns.Call(Row.owned_bundle, FilePath))
	}

	PreserveVariantRefusal(Result) {
		VariantRefusal := Native.variant_refusal.Call(Result, FilePath)
		if VariantRefusal != "" {
			Row.phase := "refused"
			if !Result.Get("read_only", false)
				TOML_RefuseWrites(FilePath, VariantRefusal)
			throw ConfigMigrateVariantRefusal(VariantRefusal)
		}
		return Result
	}

	if Request == "boot" {
		if !(Row.phase == "prepared" || Row.phase == "owned")
			throw Error("Configuration boot requires its exact prepared source")
		if Row.classification == "invalid" || Row.classification == "newer" || Row.classification == "unsupported" {
			Row.phase := "refused"
			Detail := "the original native source classification remains refused for this session"
			TOML_RefuseWrites(FilePath, Detail)
			return PreserveVariantRefusal(Map("status", Row.classification, "read_only", 1, "from", "", "to", Row.registry_shadow["current"],
				"backup", "", "detail", Detail))
		}
		if !RegistryLive(Row) {
			Row.phase := "refused"
			Detail := "the actual registry owner changed before native boot migration"
			TOML_RefuseWrites(FilePath, Detail)
			return PreserveVariantRefusal(Map("status", "failed", "read_only", 1, "from", "", "to", "", "backup", "", "detail", Detail))
		}
		Row.phase := "booting"
		MigrationRegistryAdmission := () => RegistryLive(Row) && Destinations[Key] == Row && Row.phase == "booting"
		; The private model came from the exact genuine native registry source;
		; its live original identity/image remains required through native replace.
		try Result := Native.migrate.Call(FilePath, Row.registry_shadow, "", 0, 0, 0, MigrationRegistryAdmission)
		catch as Err {
			Detail := "the config migration raised: " . Err.Message
			TOML_RefuseWrites(FilePath, Detail)
			try LoggerError("ConfigMigrate", "Config migration of '{1}' refused (failed): {2}. The file is "
				. "left untouched and this session will not write it.", FilePath, Detail)
			Result := Map("status", "failed", "read_only", 1, "from", "", "to", "", "backup", "", "detail", Detail)
		}
		PreserveVariantRefusal(Result)
		Image := ReadImage()
		Status := Result.Get("status", "failed")
		if RegistryLive(Row) && Image is Object && TOML_WriteRefusal(FilePath) == ""
				&& (Status == "absent" || Status == "current" || Status == "migrated") {
			Classification := ClassifyImage(Image, Row)
			if Classification == "current" || (Status == "absent" && Classification == "fresh-missing") {
				Row.image := Image
				Row.classification := Classification
				Row.phase := "ready"
				return Result
			}
		}
		; The initial classified image remains the only permitted read after
		; invalid/newer or pending-migration refusal; it grants no write state.
		Row.phase := "refused"
		if TOML_WriteRefusal(FilePath) == ""
			TOML_RefuseWrites(FilePath, "the native boot source lost configuration admission")
		if Status == "absent" || Status == "current" || Status == "migrated" {
			Result["status"] := "failed"
			Result["read_only"] := 1
			Result["detail"] := "the completed native migration lost its exact boot source/registry handoff"
		}
		return Result
	}

	if !RegistryLive(Row) || !(Row.image is Object)
		return false
	if Request == "capture_read" {
		if Row.HasOwnProp("read_failure")
			Row.DeleteProp("read_failure")
		if !(OwnerLive() || Row.phase == "prepared" || Row.phase == "refused")
			return false
	}
	Image := ReadImage(Request == "capture_read")
	if !(Image is Object)
		return false
	if Request == "capture_read" {
		if OwnerLive() {
			Classification := ClassifyImage(Image, Row)
			if !(Classification == "current" || Classification == "fresh-missing")
				return false
		} else if !(Row.phase == "prepared" || Row.phase == "refused")
			return false
		; A retired semantic read may observe genuinely new native bytes. This
		; does not alter Row.image, the initial boot classification, or READY.
		ExpectedSource := SubStr(Image.source, 1, 1) == Chr(0xFEFF) ? SubStr(Image.source, 2) : Image.source
		ExpectedPresent := Image.present
		; Read ownership does not grant write READY or extend a native bundle.
		return (Source, Present) => RegistryLive(Row) && Destinations[Key] == Row
			&& (Present is Integer) && Present == ExpectedPresent && (Source is String)
			&& StrCompare(Source, ExpectedSource, true) == 0
	}
	if Request == "capture_recovery" {
		if !(Row.phase == "prepared" || Row.phase == "owned" || Row.phase == "ready")
				|| (Row.classification == "invalid" || Row.classification == "newer" || Row.classification == "unsupported")
				|| TOML_WriteRefusal(FilePath) != "" || _ConfigPublicationHasRecoveryDebt(FilePath)
			return false
		try Recovery := Native.recovery_images.Call(Candidate, FilePath, OwnerBundle)
		catch
			return false
		if !(Recovery is Object)
			return false
		for Side in [Recovery.old, Recovery.new] {
			if Side is Object && Side.present {
				Classification := ClassifyImage(Side, Row)
				if !(Classification == "current" || Classification == "migrate")
					return false
			}
		}
		OldImage := Recovery.old is Object ? { source: Recovery.old.source, present: Recovery.old.present } : false
		NewImage := Recovery.new is Object ? { source: Recovery.new.source, present: Recovery.new.present } : false
		RecoveryPhase := Row.phase, RecoveryBundle := OwnerBundle
		RecoveredMatch(Source, Present, Expected) {
			return Expected is Object && (Source is String) && (Present is Integer)
				&& Present == Expected.present && StrCompare(Source, Expected.source, true) == 0
		}
		if !RecoveredMatch(Image.source, Image.present, OldImage) && !RecoveredMatch(Image.source, Image.present, NewImage)
			return false
		; Only actual native WAL/namespace/artifact observations admit older
		; images for recovery. This never completes ordinary write READY.
		return (Source, Present, NextContent, NextPresent) => RegistryLive(Row) && Destinations[Key] == Row
			&& Row.phase == RecoveryPhase && Native.terminal_owns.Call(RecoveryBundle, FilePath)
			&& Native.terminal_owns.Call(RecoveryBundle, Candidate) && TOML_WriteRefusal(FilePath) == ""
			&& !_ConfigPublicationHasRecoveryDebt(FilePath)
			&& (RecoveredMatch(Source, Present, OldImage) || RecoveredMatch(Source, Present, NewImage))
			&& (RecoveredMatch(NextContent, NextPresent, OldImage) || RecoveredMatch(NextContent, NextPresent, NewImage))
	}
	if !OwnerLive() || TOML_WriteRefusal(FilePath) != ""
			|| (Request != "capture_reconcile_noop" && _ConfigPublicationHasRecoveryDebt(FilePath))
		return false
	Classification := ClassifyImage(Image, Row)
	if !(Classification == "current"
			|| (Row.classification == "fresh-missing" && Classification == "fresh-missing"))
		return false
	if Request == "capture_transition" {
		if !IsSet(OwnerBundle) || Row.phase != "owned" || Row.owned_bundle != OwnerBundle
				|| !Native.terminal_owns.Call(OwnerBundle, FilePath)
				|| !IsSet(Candidate) || !(Candidate is Map) || Candidate.Count != 2
				|| !Candidate.Has("present") || !Candidate.Has("content")
				|| !(Candidate["present"] is Integer) || (Candidate["present"] != 0 && Candidate["present"] != 1)
				|| !(Candidate["content"] is String) || (!Candidate["present"] && Candidate["content"] != "")
			return false
		NewPresent := Candidate["present"], NewContent := Candidate["content"]
		if NewPresent && ClassifyImage({ present: 1, source: NewContent }, Row) != "current"
			return false
		OldPresent := Image.present, OldContent := Image.source, ExactBundle := OwnerBundle
		Matches(Source, Present, ExpectedSource, ExpectedPresent) {
			return (Present is Integer) && Present == ExpectedPresent && (Source is String)
				&& StrCompare(Source, ExpectedSource, true) == 0
		}
		return (Source, Present, NextContent, NextPresent) => RegistryLive(Row) && Destinations[Key] == Row
			&& Row.phase == "owned" && Row.owned_bundle == ExactBundle
			&& Native.terminal_owns.Call(ExactBundle, FilePath) && TOML_WriteRefusal(FilePath) == ""
			&& !_ConfigPublicationHasRecoveryDebt(FilePath)
			&& (Matches(Source, Present, OldContent, OldPresent) || Matches(Source, Present, NewContent, NewPresent))
			&& (Matches(NextContent, NextPresent, OldContent, OldPresent) || Matches(NextContent, NextPresent, NewContent, NewPresent))
	}
	if Request == "capture_noop" || Request == "capture_reconcile_noop" {
		if Request == "capture_reconcile_noop" && Classification != "current"
			return false
		ExpectedNoopSource := Image.source
		ExpectedNoopPresent := Image.present
		ExpectedNoopPhase := Row.phase
		ExpectedNoopBundle := Row.phase == "owned" ? Row.owned_bundle : false
		return (Source, Present) => RegistryLive(Row) && Destinations[Key] == Row
			&& Row.phase == ExpectedNoopPhase && OwnerLive() && TOML_WriteRefusal(FilePath) == ""
			&& (Request == "capture_reconcile_noop" || !_ConfigPublicationHasRecoveryDebt(FilePath))
			&& (ExpectedNoopPhase != "owned" || Row.owned_bundle == ExpectedNoopBundle)
			&& (Source is String) && StrCompare(Source, ExpectedNoopSource, true) == 0
			&& (Present is Integer) && Present == ExpectedNoopPresent
	}
	if Request == "check_write"
		return RegistryLive(Row) && OwnerLive() && TOML_WriteRefusal(FilePath) == ""
	if !IsSet(Candidate)
		return false
	if IsSet(Candidate) {
		if !(Candidate is String)
			return false
		if ClassifyImage({ present: 1, source: Candidate }, Row) != "current"
			return false
	}
	ExpectedWriteSource := Image.source
	ExpectedWritePresent := Image.present
	ExpectedCandidate := Candidate
	ExpectedWritePhase := Row.phase
	ExpectedWriteBundle := Row.phase == "owned" ? Row.owned_bundle : false
	; This is early source/candidate admission. The genuine native final
	; replacement and no-op API must later retain and invoke the same guard.
	return (Source, Present, FinalCandidate) => RegistryLive(Row) && Destinations[Key] == Row && Row.phase == ExpectedWritePhase && OwnerLive()
		&& (ExpectedWritePhase != "owned" || Row.owned_bundle == ExpectedWriteBundle)
		&& TOML_WriteRefusal(FilePath) == "" && !_ConfigPublicationHasRecoveryDebt(FilePath)
		&& (Present is Integer) && Present == ExpectedWritePresent && (Source is String)
		&& StrCompare(Source, ExpectedWriteSource, true) == 0 && (FinalCandidate is String)
		&& StrCompare(FinalCandidate, ExpectedCandidate, true) == 0
}

/** Read-only constructor handoff; actual migration keeps its later boot timing. */
ConfigSchemaPrepareSource(Path) {
	return ConfigMigrateBoot(Path, "prepare")
}

/**
 * Observes a retained incompatible boot schema without opening or changing it.
 * @param {String} Path Exact boot configuration destination.
 * @returns {String} newer/invalid/unsupported, or empty when no such state exists.
 */
ConfigSchemaReadOnlyStatus(Path) {
	try Status := ConfigMigrateBoot(Path, "read_only_status")
	catch
		return ""
	return Status is String ? Status : ""
}

/** Captures only genuinely initialized fresh source permission before effects. */
ConfigSchemaCanPrepareWrite(Path) {
	try {
		Result := ConfigMigrateBoot(Path, "check_write")
		return (Result is Integer) && Result == 1
	} catch {
		return false
	}
}


/** Performs only native source reads while the exact chosen-target bundle lives. */
ConfigSchemaPrepareOwnedSource(Path, Bundle) {
	try {
		Result := ConfigMigrateBoot(Path, "prepare_owned", , Bundle)
		return Result is Map && Result.Get("read_only", 1) == 0
	} catch {
		return false
	}
}


/** Checks fresh native source outside Critical, then acknowledges the captured noop. */
ConfigSchemaAcknowledgeNoop(Path, SourceAdmission, LogicalAdmission := 0) {
	static ExistsOwner := FSStrictExists, ReadOwner := FSReadUtf8Exact
	if !HasMethod(SourceAdmission, "Call") || ExistsOwner != FSStrictExists || ReadOwner != FSReadUtf8Exact
		return false
	try {
		Present := ExistsOwner.Call(Path)
		if !(Present is Integer) || (Present != 0 && Present != 1)
			return false
		Source := Present ? ReadOwner.Call(Path) : ""
		if !(Source is String) || (!Present && ExistsOwner.Call(Path))
			return false
		FinalNoop() {
			return ExistsOwner == FSStrictExists && ReadOwner == FSReadUtf8Exact
				&& _FSNativeAdmissionAccepted(LogicalAdmission) && SourceAdmission.Call(Source, Present)
		}
		return FSNativeAcknowledge(FinalNoop)
	} catch {
		return false
	}
}


; This typed refusal rejects successor readiness instead of changing helper ownership.
class ConfigMigrateVariantRefusal extends Error {
}

; A scalar participant does not authorize an ancestor or descendant namespace.
_ConfigMigrateVariantNamespaceClear(Model, Section, Key) {
	View := _ConfigMigrateClone(Model)
	if View.Has(Section) && View[Section].Has(Key)
		View[Section].Delete(Key)
	return _ConfigMigrateCopyDestinationAbsent(View, Section, Key)
}

_ConfigMigrateMoveErgoptiVariant(Model, Op) {
	Section := Op["section"]
	Entries := Model.Get(Section, Map())
	Refuse := (Detail) => ConfigMigrateVariantRefusal("Ergopti variant migration refused: " . Detail)
	for Field in ["key", "to_key", "base_key", "alt_gr_key", "source_key"] {
		if !_ConfigMigrateVariantNamespaceClear(Model, Section, Op[Field])
			throw Refuse("an intent participant has an occupied namespace")
	}
	for Field in ["base_key", "alt_gr_key"] {
		if Entries.Has(Op[Field]) {
			Gate := Entries[Op[Field]]
			if !(Gate is TOML_Bool) || !(Gate.Value is Integer) || (Gate.Value != 0 && Gate.Value != 1)
				throw Refuse("an independent layer gate is not an exact TOML boolean")
		}
	}
	if Entries.Has(Op["source_key"]) {
		Selected := Entries[Op["source_key"]]
		if !(Selected is String) || (Selected != "" && !RegExMatch(Selected, "^[a-z][a-z0-9_]*$"))
			throw Refuse("the registry source intent is malformed")
	}
	if Entries.Has(Op["to_key"]) {
		Target := Entries[Op["to_key"]]
		if !(Target is String) || !(StrCompare(Target, Op["false_variant"], true) == 0 || StrCompare(Target, Op["true_variant"], true) == 0
			|| (Op.Has("neutral_variant") && StrCompare(Target, Op["neutral_variant"], true) == 0))
			throw Refuse("the new variant is not a recognized exact choice")
	}
	if !Entries.Has(Op["key"])
		return
	Legacy := Entries[Op["key"]]
	if !(Legacy is TOML_Bool) || !(Legacy.Value is Integer) || (Legacy.Value != 0 && Legacy.Value != 1)
		throw Refuse("the historical variant is not an exact TOML boolean")
	Variant := Legacy.Value ? Op["true_variant"] : Op["false_variant"]
	if Entries.Has(Op["to_key"]) && StrCompare(Entries[Op["to_key"]], Variant, true) != 0
		throw Refuse("recognized old and new variants conflict")
	; Every typed/source/namespace witness precedes source consumption.
	Entries[Op["to_key"]] := Variant
	Entries.Delete(Op["key"])
}


; Joint intent reads require the same semantic, flat-model and physical owner.
; Table arrays, root/inline owners and quoted/dotted aliases cannot stand in for
; an addressable leaf, including when that leaf is retained rather than deleted.
_ConfigMigrateVariantSourceWitness(Source, Scan, Before, Registry, Driver, FromVersion) {
	Document := TOML_ParseDocument(Source)
	for Step in Registry["steps"] {
		if Step["from"] < FromVersion || !Step["drivers"].Has(Driver)
			continue
		for Op in Step["ops"] {
			if Op["op"] != "move_ergopti_variant"
				continue
			Entries := Before.Get(Op["section"], Map())
			for Field in ["key", "to_key", "base_key", "alt_gr_key", "source_key"] {
				Key := Op[Field]
				Parts := StrSplit(Op["section"], ".")
				Parts.Push(Key)
				Read := _TOML_DocumentLookup(Document, Parts)
				if Read["blocked"] || Read["found"] != Entries.Has(Key)
					throw ConfigMigrateVariantRefusal("Ergopti variant migration refused: joint source ownership disagrees")
				if !Read["found"]
					continue
				if !ConfigMigrateSameValue(Read["value"], Entries[Key])
					throw ConfigMigrateVariantRefusal("Ergopti variant migration refused: joint source types disagree")
				Addressable := 0
				for Record in Scan.Records {
					if Record.Addressable && StrCompare(Record.Header.ModelSection, Op["section"], true) == 0
							&& StrCompare(Record.Key, Key, true) == 0
						Addressable += 1
				}
				if Addressable != 1
					throw ConfigMigrateVariantRefusal("Ergopti variant migration refused: joint source is not one addressable physical leaf")
			}
		}
	}
}


; A generic physical-record refusal must not silently erase an unmigrated
; helper owner. Other migration refusals retain their existing startup policy.
_ConfigMigrateVariantBootRefusal(Result, FilePath) {
	Prefix := "Ergopti variant migration refused:"
	if SubStr(Result.Get("detail", ""), 1, StrLen(Prefix)) == Prefix
		return Result["detail"]
	try {
		Source := FSReadUtf8Exact(FilePath)
		if !(Source is String)
			return ""
		Document := TOML_ParseDocument(Source)
		Legacy := _TOML_DocumentLookup(Document, ["layout", "ergopti_plus"])
		Variant := _TOML_DocumentLookup(Document, ["layout", "ergopti_variant"])
	} catch {
		return ""
	}
	if Legacy["found"] || Legacy["blocked"] || Variant["blocked"]
		return Prefix . " historical or occupied variant ownership remains unadmitted"
	if !Variant["found"]
		return ""
	Value := Variant["value"]
	if !(Value is String) || (StrCompare(Value, "none", true) != 0 && StrCompare(Value, "ergopti", true) != 0 && StrCompare(Value, "ergopti_plus", true) != 0)
		return Prefix . " current variant ownership is not a recognized exact choice"
	if Result.Get("read_only", false)
		return Prefix . " the joint source remains refused by its migration owner"
	for Field in ["ergopti_base", "ergopti_alt_gr", "emulated_layout"] {
		Read := _TOML_DocumentLookup(Document, ["layout", Field])
		if Read["blocked"]
			return Prefix . " an independent intent participant has an occupied namespace"
		if !Read["found"]
			continue
		Value := Read["value"]
		if Field == "emulated_layout" {
			if !(Value is String) || (Value != "" && !RegExMatch(Value, "^[a-z][a-z0-9_]*$"))
				return Prefix . " the registry source intent is malformed"
		} else if !(Value is TOML_Bool) || !(Value.Value is Integer) || (Value.Value != 0 && Value.Value != 1)
			return Prefix . " an independent layer gate is not an exact TOML boolean"
	}
	return ""
}
