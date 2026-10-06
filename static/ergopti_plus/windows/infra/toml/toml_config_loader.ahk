; infra/toml/toml_config_loader.ahk

; ==============================================================================
; MODULE: TOML Config Loader
; DESCRIPTION:
; Reads the user ``config.toml`` produced by the first-boot generator from
; ``_shared/modules/features/manifest.toml``. Distinct from the legacy ``toml_loader.ahk``
; which only handles flat ``[script]``/``[features]`` overrides — this loader
; supports arbitrarily nested sections (``[hotstrings.autocorrection.accents]``)
; and simple array values (``val_modifiers = ["alt"]``).
;
; FEATURES & RATIONALE:
; 1. A section header is used verbatim: ``[layout]`` lands on the in-memory
;    ``Features["layout"]`` Map. There is no namespace translation, because
;    there is no namespace — a section is named after what it configures.
; 2. No foreign-section skipping. Until Lot 4 the same schema described an
;    ``[ahk.*]`` silo and an ``[hs.*]`` one, so this loader stripped the first
;    and silently ignored the second. Both are gone, which means an unrecognised
;    header is now unambiguously a mistake and gets the loud treatment in (3)
;    instead of being written off as another driver's business.
; 3. Unknown sections and keys produce one cleanup warning per file. They do
;    not represent a runtime failure: valid overrides still apply, and the
;    post-ready startup task offers the existing configuration cleanup tool.
; 4. Dormant until cut-over: written ahead of the migration so the disruptive
;    PR can be focused on call-site rewrites only.
; 5. ``hotstrings.personal.<user-chosen-name>`` is dynamic per-user data:
;    missing category segments are auto-vivified. The three known
;    ``personal_editor`` preferences retain their editor owner instead of
;    entering the manifest-built Features tree.
; 6. An EXISTING ``config.toml`` that cannot be READ latches
;    ``_ConfigBootReadFailed`` (declared with its siblings in ``toml_helpers``).
;    It is the session-wide "the feature tree in memory is defaults, not the
;    user's settings" signal that ``SaveFullConfig`` honours, and it is
;    deliberately never cleared: nothing re-applies the config in-process, so
;    the tree stays untrustworthy until the driver restarts.
; ==============================================================================





#Include ../../_generated/action_catalogue.ahk
#Include ../../../_shared/ahk/config_binding_identity.ahk





; =================================
; =================================
; ======= 1. Value coercion =======
; =================================
; =================================

; True when ``SectionPath`` is a namespace that is inherently dynamic and can
; never be enumerated in the static, compile-time manifest:
;   - ``hotstrings.personal.<name>`` — <name> is a user-chosen personal
;     hotstring category created at runtime via the personal TOML editor
;     (see EnsurePersonalHotstringFeature in infra/personal_features.ahk).
; Editor UI preferences are separately enumerated in the foreign ownership
; registry. Their keys never become dynamic feature paths during this walk.
/**
 * Decodes a dotted TOML section without splitting dots inside quoted keys.
 * @param {String} Header - Section contents without brackets.
 * @returns {Array|Integer} Semantic key segments, or false for malformed input.
 */
TomlConfigSectionParts(Header) {
	if !(Header is String)
		return false
	Rest := Trim(Header)
	Parts := []
	Pattern := "^(?:([A-Za-z0-9_-]+)|" . Chr(34) . "((?:[^" . Chr(34) . "\\]|\\.)*)" . Chr(34) . "|'([^']*)')"
	while (Rest != "") {
		if !RegExMatch(Rest, Pattern, &TokenMatch)
			return false
		Token := TokenMatch[0]
		if SubStr(Token, 1, 1) == Chr(34)
			Part := UnescapeTomlString(SubStr(Token, 2, -1))
		else if SubStr(Token, 1, 1) == "'"
			Part := SubStr(Token, 2, -1)
		else
			Part := Token
		Parts.Push(Part)
		Rest := Trim(SubStr(Rest, StrLen(Token) + 1))
		if Rest == ""
			return Parts
		if SubStr(Rest, 1, 1) != "."
			return false
		Rest := Trim(SubStr(Rest, 2))
		if Rest == ""
			return false
	}
	return false
}

; Manifest paths use semantic names; quotes belong only to TOML serialization.
TomlConfigManifestPath(Header) {
	Parts := TomlConfigSectionParts(Header)
	if !(Parts is Array)
		return ""
	Path := ""
	for Part in Parts {
		; Literal empty names and dots cannot borrow a manifest path identity.
		if Part == "" || InStr(Part, ".")
			return ""
		Path .= (Path == "" ? "" : ".") . Part
	}
	return Path
}

TomlSectionIsDynamicPersonalNamespace(SectionPath) {
	Parts := TomlConfigSectionParts(SectionPath)
	if !(Parts is Array)
		return false
	return _ConfigTomlDynamicPersonal(Parts)
}

; Keys stored in config.toml but deliberately loaded by a subsystem other than
; the manifest-backed Features tree. Keep this registry exact: an unlisted key
; in one of these sections remains a configuration error instead of inheriting
; a broad section-level exemption.
TomlConfigForeignOwnershipRegistry() {
	Registry := TomlConfigStaticForeignOwnershipRegistry()
	; Language packs add category gates through the same catalog FeatureState
	; seeds at boot. These are owned settings, never unused configuration keys.
	for _, Pack in HotstringsLanguageCategories() {
		for _, Category in Pack["categories"]
			Registry["category_enabled"][Category["v2"]] := "FeatureState"
	}
	return Registry
}

; The keys of a key combination, as a regex alternation: the Windows column of
; [tap_hold.catalog] in _shared/tap_hold/defaults.toml. Spelled here because
; this loader runs before that catalogue is read, and in a function because a
; key can be asked about before this file's include position has run;
; tests/unit/test_key_combinations.ahk holds the two together.
TomlConfigKeyCombinationKeys() {
	static Keys := "escape|tab|caps_lock|left_shift|left_ctrl|win|left_alt|space|alt_gr|right_ctrl|right_shift|enter|backspace|delete"
	return Keys
}

/**
 * Publishes the gesture parameter domain from its complete native slot accessor.
 * This accessor is available before gesture initialization; mutable runtime
 * assignments cannot prove that a saved binding has been retired.
 * @returns {Map} Native prefix and complete case-exact slot-id set.
 * @throws {ValueError} If the native owner publishes an invalid inventory.
 */
TomlConfigGestureSlotCatalogue() {
	Ids := GestureSlotIds()
	if !(Ids is Array) || Ids.Length == 0
		throw ValueError("gestures: invalid published slot catalogue")
	Slots := Map()
	Slots.CaseSense := "On"
	Count := 0
	for Index, Slot in Ids {
		if Type(Slot) != "String" || Slot == "" || InStr(Slot, "__", true) || Slots.Has(Slot)
			throw ValueError("gestures: invalid published slot catalogue")
		Slots[Slot] := true
		Count += 1
	}
	if Count != Ids.Length
		throw ValueError("gestures: invalid published slot catalogue")
	return Map("prefix", GestureBindingId("gesture", ""), "slots", Slots)
}

/**
 * Judges only a recognized parameter-action suffix against the native domain.
 * Other binding owners retain their current admission and source ownership.
 * @param {String} Key Persisted parameter key.
 * @param {Map} Catalogue Optional already-published native gesture domain.
 * @returns {String} Shared current/retired/unjudged identity decision.
 */
; Returns a detached publication only while its actual compiled declaration lives.
; Missing or replaced owners cannot prove retirement; no lazy reads occur here.
TomlConfigScriptSlotCatalogue() {
	global _ScriptShortcutBindingPublication, SCRIPT_SHORTCUT_SLOTS
	if !IsSet(_ScriptShortcutBindingPublication) || !IsSet(SCRIPT_SHORTCUT_SLOTS)
		return false
	Publication := _ScriptShortcutBindingPublication
	if !(Publication is Object) || !HasProp(Publication, "Source") || !HasProp(Publication, "Catalogue")
		throw ValueError("script chords: invalid publication receipt")
	if Publication.Source != SCRIPT_SHORTCUT_SLOTS
		return false
	Current := ConfigBindingIdentityScriptPublication(SCRIPT_SHORTCUT_SLOTS).Catalogue
	Captured := Publication.Catalogue
	if !(Captured is Map) || !Captured.Has("prefix") || Captured["prefix"] !== "script__"
		|| !Captured.Has("slots") || !(Captured["slots"] is Map) || Captured["slots"].CaseSense != "On"
		throw ValueError("script chords: invalid publication receipt")
	ConfigBindingIdentityScriptStatus("script__", Captured)
	if Captured["slots"].Count != Current["slots"].Count
		return false
	for Slot in Current["slots"] {
		if !Captured["slots"].Has(Slot)
			return false
	}
	return Map("prefix", "script__", "slots", Captured["slots"].Clone())
}

; Returns only the identity projection of the same complete compiled declarations.
TomlConfigTapSlotCatalogue() {
	global _TapKeyBindingPublication, TAP_KEY_ORDER, TAP_KEY_SCANCODES
	if !IsSet(_TapKeyBindingPublication) || !IsSet(TAP_KEY_ORDER) || !IsSet(TAP_KEY_SCANCODES)
		return false
	Publication := _TapKeyBindingPublication
	if !(Publication is Object) || !HasProp(Publication, "Source") || !HasProp(Publication, "ScanSource")
		|| !HasProp(Publication, "Catalogue") || !HasProp(Publication, "Scans")
		throw ValueError("tap keys: invalid publication receipt")
	if Publication.Source != TAP_KEY_ORDER || Publication.ScanSource != TAP_KEY_SCANCODES
		return false
	Current := ConfigBindingIdentityTapPublication(TAP_KEY_ORDER, TAP_KEY_SCANCODES)
	Captured := Publication.Catalogue
	ConfigBindingIdentityTapStatus("tap_key__", Captured)
	if Captured["slots"].CaseSense != "On" || !(Publication.Scans is Map) || Publication.Scans.CaseSense != "On"
		throw ValueError("tap keys: invalid publication receipt")
	if Captured["slots"].Count != Current.Catalogue["slots"].Count
		|| Publication.Scans.Count != Current.Scans.Count
		return false
	for Slot, Scan in Current.Scans {
		if !Captured["slots"].Has(Slot) || !Publication.Scans.Has(Slot) || Publication.Scans[Slot] != Scan
			return false
	}
	return Map("prefix", "tap_key__", "slots", Captured["slots"].Clone())
}

; Judges native bindings only against their actual acknowledged publication.
TomlConfigParameterBindingStatus(BindingId, Catalogue?) {
	if Type(BindingId) == "String" && SubStr(BindingId, 1, 9) == "tap_key__" {
		TapCatalogue := TomlConfigTapSlotCatalogue()
		return TapCatalogue is Map ? ConfigBindingIdentityTapStatus(BindingId, TapCatalogue) : "unjudged"
	}
	if Type(BindingId) == "String" && SubStr(BindingId, 1, 8) == "script__" {
		ScriptCatalogue := TomlConfigScriptSlotCatalogue()
		return ScriptCatalogue is Map ? ConfigBindingIdentityScriptStatus(BindingId, ScriptCatalogue) : "unjudged"
	}
	if !IsSet(Catalogue)
		Catalogue := TomlConfigGestureSlotCatalogue()
	return ConfigBindingIdentityGestureStatus(BindingId, Catalogue)
}

TomlConfigActionParameterBindingStatus(Key, Catalogue?) {
	if Type(Key) != "String"
		return "unjudged"
	if !IsSet(Catalogue)
		Catalogue := TomlConfigGestureSlotCatalogue()
	for Action, Metadata in GestureActionCatalogueData().Actions {
		if Metadata.Parameter == ""
			continue
		Suffix := "__" . Action
		if StrLen(Key) >= StrLen(Suffix) && SubStr(Key, -StrLen(Suffix)) == Suffix
			return TomlConfigParameterBindingStatus(SubStr(Key, 1, StrLen(Key) - StrLen(Suffix)), Catalogue)
	}
	return "unjudged"
}

/**
 * Reports a retired gesture parameter from config.toml once per file and key.
 * Both the boot loader and direct gesture reload use this configuration owner;
 * the other-file reporter must not deny that config.toml cleanup owns the row.
 * @param {String} FilePath Exact persisted configuration identity.
 * @param {String} Key Retired parameter key.
 * @returns {Boolean} True when this call records the first warning.
 */
TomlConfigReportRetiredGestureParameter(FilePath, Key) {
	static Reported := Map()
	if Type(FilePath) != "String" || FilePath == "" || Type(Key) != "String" || Key == ""
		throw ValueError("A retired gesture parameter requires its configuration file and key.")
	PreviousCritical := Critical("On")
	try {
		if !Reported.Has(FilePath) {
			Keys := Map()
			Keys.CaseSense := "On"
			Reported[FilePath] := Keys
		}
		if Reported[FilePath].Has(Key)
			return false
		Reported[FilePath][Key] := true
	} finally Critical(PreviousCritical)
	Reason := SubStr(Key, 1, 8) == "script__" ? ConfigBindingIdentityScriptRetiredReason()
		: SubStr(Key, 1, 9) == "tap_key__" ? ConfigBindingIdentityTapRetiredReason()
		: "no gesture slot of this build has this name"
	try LoggerWarn("TomlConfigLoader", "Outdated configuration entry '[action_parameters].{1}' in '{2}' ignored "
		. "({3}); it is offered for explicit cleanup.", TOML_RenderKey(Key), FilePath, Reason)
	return true
}

; Action parameters use the binding grammar written by the gesture, shortcut
; and tap-hold owners. Only actions declaring a parameter can consume a value.
TomlConfigActionParameterIsOwned(Key) {
	static Actions := GestureActionCatalogueData().Actions
	if !RegExMatch(Key, "^(?:combination|gesture|keyboard|script|tap_hold|tap_key)__[a-z0-9]+(?:_[a-z0-9]+)*__([a-z0-9]+(?:_[a-z0-9]+)*)$", &Match)
		return false
	return Actions.Has(Match[1]) && Actions[Match[1]].Parameter != ""
		&& TomlConfigActionParameterBindingStatus(Key) != "retired"
}

TomlConfigForeignOwner(SectionPath, Key) {
	SectionPath := TomlConfigManifestPath(SectionPath)
	Registry := TomlConfigForeignOwnershipRegistry()
	if Registry.Has(SectionPath) {
		Section := Registry[SectionPath]
		if Section.Has(Key)
			return Section[Key]
	}
	if SectionPath == "action_parameters" && TomlConfigActionParameterIsOwned(Key)
		return "Gestures"
	; The keyboard picker persists slots outside the shipped-default manifest.
	; Admit exactly the prefixes and keys that ShowKeyboardSlotPicker can create;
	; a broad section exemption would hide misspellings such as win_cc forever.
	if (SectionPath == "shortcuts.keyboard"
			&& RegExMatch(Key,
				"^(?:alt|ctrl|ctrl_shift|win)_(?:[a-z0-9]|space|enter|period|comma|sc029)$"))
		return "ConfigIO"
	; The key-combination slots are keyed by an ordered pair of tap-hold keys,
	; « first_then_second » (infra/key_combinations.ahk); the manifest declares
	; only the pairs that ship a recommendation. The reader refuses a pair of
	; one key twice.
	if ((SectionPath == "shortcuts.key_combination_taps" || SectionPath == "shortcuts.key_combination_holds")
			&& RegExMatch(Key, "^(?:" . TomlConfigKeyCombinationKeys() . ")_then_(?:" . TomlConfigKeyCombinationKeys() . ")$"))
		return "KeyCombinations"
	return ""
}

; Classifies a section header the loader deliberately does not apply.
; ``[_*]`` metadata and ``[updater]`` belong to other readers ("foreign");
; the dissolved ``[ahk.*]`` silo is "obsolete" and remains on disk until
; explicit cleanup. Returns "" for a section the manifest tree must account for.
TomlConfigSectionSkipKind(Header) {
	if (Header == "ahk" or InStr(Header, "ahk.") == 1)
		return "obsolete"
	if (SubStr(Header, 1, 1) == "_" or Header == "updater")
		return "foreign"
	return ""
}

; The single rule deciding whether a ``[SectionPath].Key`` pair belongs to
; nothing: not the manifest-built Features tree, not a dynamic personal
; namespace, and not a registered foreign owner. Returns "section" when a
; segment of SectionPath is missing, "leaf" when only Key is missing, and ""
; otherwise. ForeignOwner receives the registered owner of a key the tree does
; not hold. The boot loader and the unused-key cleanup both call this, so the
; keys the cleanup offers to remove are exactly the ones boot reports as unknown.
; The walk never mutates Features.
TomlConfigUnknownKind(Features, SectionPath, Key, &ForeignOwner := "") {
	; Declaring a neutral default must not transfer a key to the Features owner.
	ForeignOwner := ""
	Registry := TomlConfigForeignOwnershipRegistry()
	if Registry.Has(SectionPath) && Registry[SectionPath].Has(Key) {
		ForeignOwner := Registry[SectionPath][Key]
		return ""
	}
	if TomlSectionIsDynamicPersonalNamespace(SectionPath)
		return ""
	Node := Features
	Parts := TomlConfigSectionParts(SectionPath)
	if !(Parts is Array)
		return "section"
	for _, Part in Parts {
		if (Type(Node) == "Map" and Node.Has(Part))
			Node := Node[Part]
		else if (IsObject(Node) and Node.HasOwnProp(Part))
			Node := Node.%Part%
		else {
			ForeignOwner := TomlConfigForeignOwner(SectionPath, Key)
			return ForeignOwner != "" ? "" : "section"
		}
	}
	if (Type(Node) == "Map")
		Known := Node.Has(Key)
	else if IsObject(Node)
		Known := Node.HasOwnProp(Key)
	else
		; A scalar where a table was expected is a shape violation that the
		; loader rejects on its own; the key is not "unknown".
		return ""
	if Known
		return ""
	; Dynamic keyboard slots belong to ConfigIO only outside the manifest tree.
	ForeignOwner := TomlConfigForeignOwner(SectionPath, Key)
	return ForeignOwner != "" ? "" : "leaf"
}

; Why the loader leaves a manifest-known ``[Section].Key`` value unapplied as
; outdated configuration, or "" when it applies. An older build or a hand edit
; can leave a value this build no longer accepts (a narrowed enum, a boolean
; spelled "yes", a scalar where a table now lives). Such an entry is never an
; ERROR and never blocks a save: the loader warns about it and keeps the
; manifest value, and the configuration cleanup offers it. Both call this, so
; what boot warns about is exactly what the cleanup lists. RawValue is the TOML
; literal, so legacy spellings are judged exactly as at boot.
TomlConfigOutdatedReason(Features, Section, Key, Value, RawValue, ForeignOwner := "") {
	if !TomlConfigValueMatchesManifest(Section, Key, Value, &ExpectedType, RawValue)
		return "its '" . ExpectedType . "' setting no longer accepts this value"
	; A key another module owns is not assigned into the Features tree.
	if (ForeignOwner != "")
		return ""
	return TomlConfigShapeReason(Features, Section, Key, Value)
}

; Why assigning Value at ``[Section].Key`` would break the manifest-seeded
; shape of the Features tree, or "" when it fits. The walk never mutates
; Features; a missing segment of a dynamic personal namespace is created at
; load, so it never conflicts.
TomlConfigShapeReason(Features, Section, Key, Value) {
	Parts := TomlConfigSectionParts(Section)
	if !(Parts is Array)
		return ""
	Node := Features
	for _, Part in Parts {
		if (Type(Node) == "Map" and Node.Has(Part))
			Node := Node[Part]
		else if (IsObject(Node) and Node.HasOwnProp(Part))
			Node := Node.%Part%
		else if (TomlSectionIsDynamicPersonalNamespace(Section) and Type(Node) == "Map")
			return ""
		else
			return "its section crosses a setting that is not a table"
	}
	; A flat-form key must never flatten a seeded {enabled:...} Map node, nor
	; the reverse (toml-loader-shape-mismatch).
	if (Type(Node) == "Map")
		return (Node.Has(Key) and (Node[Key] is Map) != (Value is Map))
			? "it would change the shape of a table setting" : ""
	return IsObject(Node) ? "" : "its section is a setting, not a table"
}

; Logger.Format cannot coerce Array/Map values. Emit a bounded structural
; description instead of producing a secondary "log format failed" diagnostic.
TomlConfigLogValue(Value) {
	ValueType := Type(Value)
	if (ValueType == "Array")
		return Format("<Array:{1}>", Value.Length)
	if (ValueType == "Map")
		return Format("<Map:{1}>", Value.Count)
	if IsObject(Value)
		return "<" . ValueType . ">"
	return Value
}

; Coerce a raw TOML literal to an AHK value. Extends the base ``TomlCoerceValue``
; with nested array and inline table support.
TomlCoerceValueExt(Raw) {
	Trimmed := Trim(Raw, " `t")
	if StrLen(Trimmed) >= 2 && SubStr(Trimmed, 1, 1) == "'" && SubStr(Trimmed, -1) == "'"
		return SubStr(Trimmed, 2, StrLen(Trimmed) - 2)
	if SubStr(Trimmed, 1, 1) == "{"
		return TOML_ParseInlineTable(Trimmed, TomlCoerceValueExt)

	; Array literal — quote-aware split so commas inside quoted strings are not
	; treated as element separators (e.g. ["foo, bar", "baz"] must yield two
	; items, not three). Uses the same algorithm as CS_CoerceValue.
	if (StrLen(Trimmed) >= 2
		and SubStr(Trimmed, 1, 1) == "["
		and SubStr(Trimmed, StrLen(Trimmed), 1) == "]") {
		Inner := SubStr(Trimmed, 2, StrLen(Trimmed) - 2)
		Result := []
		for Token in TOML_SplitArrayElements(Inner)
			Result.Push(TomlCoerceValueExt(Token))
		return Result
	}

	; Delegate primitive coercion to the v1 helper to keep the rules in one
	; place (true/false/integer/float/quoted-string fallback).
	return TomlCoerceValue(Trimmed)
}





; ==================================
; ==================================
; ======= 2. Apply v2 config =======
; ==================================
; ==================================

TomlConfigEnumUsesBooleanLiterals(Entry) {
	HasFalse := false
	HasTrue := false
	for Allowed in Entry.Get("enum_values", []) {
		if !(Allowed is Integer)
			continue
		if (Allowed == 0)
			HasFalse := true
		else if (Allowed == 1)
			HasTrue := true
	}
	return HasFalse && HasTrue
}

/** Resolves the same schema owner for configuration reads and writes. */
TomlConfigExpectedType(CurrentSection, Key, &Entry) {
	Parts := TomlConfigSectionParts(CurrentSection)
	if Parts is Array && Parts.Length >= 3 && _ConfigTomlDynamicPersonal(Parts) {
		Entry := false
		if Key == "enabled"
			return "boolean"
		if Key == "time_activation_seconds"
			return "non-negative number"
		return ""
	}
	CurrentSection := TomlConfigManifestPath(CurrentSection)
	ExpectedType := ""
	Entry := ManifestFindEntryByPath(CurrentSection . "." . Key)
	if !(Entry is Map) {
		if (InStr(CurrentSection, "hotstrings.personal.") == 1) {
			if (Key == "enabled")
				ExpectedType := "boolean"
			else if (Key == "time_activation_seconds")
				ExpectedType := "non-negative number"
			else
				return ""
		} else {
		; Feature entries own a nested value table while their manifest path ends
		; at the feature id itself. These domains mirror config.schema.json: a
		; negative delay disables the downstream gate, and an unbounded personal
		; pattern length makes the combinatorial registration loop unsafe.
			Entry := ManifestFindEntryByPath(CurrentSection)
			if !(Entry is Map) || Entry.Get("type", "") != "feature"
				return ""
			if Key == "enabled"
				ExpectedType := "boolean"
			else if Key == "time_activation_seconds"
				ExpectedType := "non-negative number"
			else if (Key == "pattern_max_length"
					&& CurrentSection
						== "hotstrings.dynamic.text_expansion_personal_information")
				ExpectedType := "integer from 1 through 16"
			else
				return ""
		}
	} else
		ExpectedType := Entry.Get("type", "")
	return ExpectedType
}

TomlConfigValueMatchesManifest(CurrentSection, Key, Value, &ExpectedType,
		RawValue := unset) {
	ExpectedType := TomlConfigExpectedType(CurrentSection, Key, &Entry)
	LiteralKind := IsSet(RawValue) ? TOML_LiteralKind(RawValue) : ""
	switch ExpectedType {
		case "boolean":
			if !(Value is Integer && (Value == 0 || Value == 1))
				return false
			if !IsSet(RawValue) || LiteralKind == "boolean"
				return true
			; Legacy integer literals from the pre-canonical writer: the installed
			; base carries bare 0/1 on boolean keys. The value domain is exact, so
			; intent is unambiguous - accept and let the caller count the
			; migration; the next typed save canonicalizes the spelling.
			; Quoted strings ("true"), out-of-range integers (2) and floats stay
			; rejected. Only the bare 0/1 spellings the old writer produced migrate.
			Stripped := Trim(RawValue, " `t")
			return LiteralKind == "number" && (Stripped == "0" || Stripped == "1")
		case "number":
			return (!IsSet(RawValue) || LiteralKind == "number")
				&& (Value is Integer || Value is Float)
		case "non-negative number":
			if ((IsSet(RawValue) && LiteralKind != "number")
					|| !(Value is Integer || Value is Float) || Value < 0)
				return false
			if (Key == "time_activation_seconds")
				return TickTryDurationMsFromSeconds(Value, &DurationMs)
			return true
		case "integer from 1 through 16":
			return (!IsSet(RawValue) || LiteralKind == "number")
				&& Value is Integer && Value >= 1 && Value <= 16
		case "string", "action":
			return (!IsSet(RawValue) || LiteralKind == "string")
				&& Value is String
		case "array":
			return (!IsSet(RawValue) || LiteralKind == "array")
				&& Value is Array
		case "feature":
			return Value is Map
		case "enum":
			for Allowed in Entry.Get("enum_values", []) {
				if Type(Allowed) != Type(Value) || Allowed != Value
					continue
				if !IsSet(RawValue)
					return true
				if Allowed is String
					return LiteralKind == "string"
				if (Allowed is Integer || Allowed is Float) {
					if ((Allowed == 0 || Allowed == 1)
							&& TomlConfigEnumUsesBooleanLiterals(Entry))
						return LiteralKind == "boolean"
					return LiteralKind == "number"
				}
				return true
			}
			return false
	}
	return true
}

; Inline feature records retain their leaf identity while applying supplied
; children through the same policies as physical child sections. Untouched
; defaults and every ignored source child remain outside runtime mutation.
TomlConfigMergeFeatureRecord(Features, Section, Seed, Typed, ChildRaw,
		&Applied, &Migrated, OutdatedEntries, &UnknownKeys, &UnknownNames, &OutdatedNames) {
	Applied := 0, Migrated := 0
	Merged := _ConfigTomlNativeValue(Seed)
	for Key, Child in Typed {
		Value := _ConfigTomlNativeValue(Child)
		Raw := ChildRaw[Key] is Map ? TOML_RenderValue(Child) : ChildRaw[Key]
		Reason := TomlConfigOutdatedReason(Features, Section, Key, Value, Raw)
		if Reason != "" {
			OutdatedEntries[Section . "`n" . Key] := Reason
			OutdatedNames .= (OutdatedNames == "" ? "" : ", ") . "[" . Section . "]." . Key
			continue
		}
		if TomlConfigUnknownKind(Features, Section, Key, &ForeignOwner) != "" {
			UnknownKeys += 1
			UnknownNames .= (UnknownNames == "" ? "" : ", ") . "[" . Section . "]." . Key
			continue
		}
		if ForeignOwner != ""
			continue
		if Child is Map && Merged.Has(Key) && Merged[Key] is Map {
			Parts := TomlConfigSectionParts(Section)
			Parts.Push(Key), Parts.Push("_")
			Value := TomlConfigMergeFeatureRecord(Features, _ConfigTomlSection(Parts),
				Merged[Key], Child, ChildRaw[Key], &ChildApplied, &ChildMigrated, OutdatedEntries,
				&UnknownKeys, &UnknownNames, &OutdatedNames)
			Migrated += ChildMigrated
			if !ChildApplied
				continue
		} else {
			ChildType := TomlConfigExpectedType(Section, Key, &Entry)
			if ChildType == "boolean"
					&& TOML_LiteralKind(Raw) == "number" {
				Migrated += 1
				try LoggerInfo("TomlConfigLoader", "migrated legacy boolean [{1}].{2} = {3}; the next save persists it as canonical true/false.", Section, Key, Value)
			}
		}
		Merged[Key] := Value
		Applied += 1
	}
	return Merged
}

; Apply the user's v2 ``config.toml`` onto the given v2-shaped Features Map.
; Returns the number of overrides applied (mostly for diagnostics).
; Idempotent and resilient to a missing file (returns 0 silently).
;
; The caller passes the target Map explicitly so this loader can never
; accidentally clobber a v1-shaped global. The v1 PascalCase section names
; (``Layout``, ``Shortcuts``, ``TapHolds``, ``Gestures``, ``LLM``,
; ``Metrics``, ``Script``, ``Hotstrings``) coincidentally also exist as
; top-level v1 ``Features`` Map keys; without the explicit parameter, the
; loader would walk those v1 entries and overwrite the inner
; ``{Enabled: True}`` object literals with plain booleans, breaking every
; downstream ``.Enabled`` access (discovered the hard way during the
; of the sliced cut-over). During the cut-over production passes
; ``Features``; tests pass their isolated Map fixture.
; Only the boot owner converts a local load diagnostic into session authority.
; Later reads of candidates must neither poison nor clear that authority.
; Outdated entries are not rejections: the boot records them so a full save
; keeps them on disk for the cleanup instead of erasing them silently.
ApplyBootConfigToml(Features, FilePath) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Applied := ApplyConfigToml(Features, FilePath, &RejectedOverrides, , &OutdatedEntries)
	_ConfigBootRejectedOverrides += RejectedOverrides
	for Id, Detail in OutdatedEntries
		_ConfigBootOutdatedEntries[Id] := Detail
	return Applied
}

; OutdatedEntries receives a Map from "Section`nKey" to the reason each
; outdated entry was left unapplied (see TomlConfigOutdatedReason).
ApplyConfigToml(Features, FilePath, &RejectedOverrides := 0,
		&MigratedOverrides := 0, &OutdatedEntries := 0) {
	RejectedOverrides := 0
	MigratedOverrides := 0
	OutdatedEntries := Map()
	Applied := 0

	try LoggerStart("TomlConfigLoader", "Applying v2 config from '{1}'…", FilePath)

	; Admit the complete semantic image before applying any feature. A native
	; read refusal must never mean an empty configuration whose defaults may
	; later overwrite the source; the existing session latch retains that debt.
	global _ConfigBootReadFailed
	try Snapshot := ConfigTomlReadSnapshot(FilePath)
	catch as Err {
		if !TOML_UnreadableFile(FilePath) {
			RejectedOverrides += 1
			try LoggerError("TomlConfigLoader", "Semantic configuration at '{1}' could not be admitted; applying NOTHING.", FilePath)
			return -1
		}
	}
	if TOML_UnreadableFile(FilePath) {
		_ConfigBootReadFailed := true
		try LoggerError("TomlConfigLoader",
			"v2 config at '{1}' exists but could not be read — applying NOTHING and blocking config persistence so the defaults now in memory cannot overwrite it.", FilePath)
		return -1
	}

	if !Snapshot.Present {
		try LoggerDebug("TomlConfigLoader", "v2 config.toml not found at '{1}' — skipping.", FilePath)
		return Applied
	}

	; Both bootstrap readers use this admitted image. No second parse can
	; observe another source generation or publish a partially read namespace.
	ObsoleteDriverSections := 0
	SkippedSections := Map()
	UnknownKeys := 0
	UnknownNames := ""
	OutdatedNames := ""
	ForeignOwnedKeys := 0
	IgnoredSectionKeys := Snapshot.SkippedRecords

	for Row in Snapshot.Rows {
		CurrentSection := Row.Section
		Key := Row.Key
		SkipKind := TomlConfigSectionSkipKind(CurrentSection == "" ? TOML_RenderKey(Key) : CurrentSection)
		if SkipKind != "" {
			IgnoredSectionKeys += 1
			if SkipKind == "obsolete" && !SkippedSections.Has(CurrentSection) {
				SkippedSections[CurrentSection] := true
				ObsoleteDriverSections += 1
			}
			continue
		}
		RawValue := TOML_StripInlineComment(Row.Raw)
		Value := _ConfigTomlNativeValue(Row.Value)
		if !TomlConfigValueMatchesManifest(CurrentSection, Key, Value,
				&ExpectedType, RawValue) {
			OutdatedReason := TomlConfigOutdatedReason(Features, CurrentSection, Key,
				Value, RawValue)
			OutdatedEntries[CurrentSection . "`n" . Key] := OutdatedReason
			OutdatedNames .= (OutdatedNames == "" ? "" : ", ") . "[" . CurrentSection . "]." . Key
			continue
		}

		; The manifest defines the universe of valid paths. An unknown section
		; path or leaf is a typo or a stale key left over from an older schema
		; version. Apply the remaining valid keys and summarize unused entries
		; once below. TomlConfigUnknownKind owns that rule; the menu's unused-key
		; cleanup offers to remove exactly these keys.
		if CurrentSection == "action_parameters" && TomlConfigActionParameterBindingStatus(Key) == "retired" {
			TomlConfigReportRetiredGestureParameter(FilePath, Key)
			continue
		}
		UnknownKind := TomlConfigUnknownKind(Features, CurrentSection, Key,
			&ForeignOwner)
		if (UnknownKind != "") {
			UnknownKeys += 1
			UnknownNames .= (UnknownNames == "" ? "" : ", ") . "[" . CurrentSection . "]." . Key
			continue
		}
		if (ForeignOwner != "") {
			ForeignOwnedKeys += 1
			try LoggerDebug("TomlConfigLoader",
				"[{1}].{2} is owned by {3}; Features apply skipped ({4}).",
				CurrentSection, Key, ForeignOwner, TomlConfigLogValue(Value))
			continue
		}

		; An old-shape value (a scalar where the manifest seeds a table, or the
		; reverse) is outdated configuration, decided by the rule the cleanup uses.
		OutdatedReason := TomlConfigShapeReason(Features, CurrentSection, Key, Value)
		if (OutdatedReason != "") {
			OutdatedEntries[CurrentSection . "`n" . Key] := OutdatedReason
			OutdatedNames .= (OutdatedNames == "" ? "" : ", ") . "[" . CurrentSection . "]." . Key
			continue
		}

		; Resolve the node. hotstrings.personal.<user-chosen-name> is a dynamic,
		; per-user namespace that structurally
		; cannot appear in the static manifest (see
		; TomlSectionIsDynamicPersonalNamespace): missing segments are
		; auto-vivified as empty Maps instead of being rejected.
		IsDynamicPersonalNamespace := TomlSectionIsDynamicPersonalNamespace(CurrentSection)
		Parts := TomlConfigSectionParts(CurrentSection)
		Node := Features
		Failed := false
		for _, Part in Parts {
			if (Type(Node) == "Map" and Node.Has(Part)) {
				Node := Node[Part]
			} else if (IsObject(Node) and Node.HasOwnProp(Part)) {
				Node := Node.%Part%
			} else if (IsDynamicPersonalNamespace and Type(Node) == "Map") {
				Node[Part] := Map()
				Node := Node[Part]
			} else {
				Failed := true
				break
			}
		}
		if Failed {
			; Only a dynamic personal path can get here: the classifier above
			; already rejected every other missing segment. It crossed a manifest
			; node that is not a table, so there is nowhere to vivify it.
			try LoggerError("TomlConfigLoader",
				"v2 override skipped — dynamic section '[{1}]' crosses a manifest node that is not a table.", CurrentSection)
			continue
		}

		if ExpectedType == "feature" && Value is Map && Node is Map && Node.Has(Key)
				&& Node[Key] is Map {
			SectionParts := Parts.Clone()
			SectionParts.Push(Key)
			SectionParts.Push("_")
			FeatureSection := _ConfigTomlSection(SectionParts)
			Value := TomlConfigMergeFeatureRecord(Features, FeatureSection, Node[Key],
				Row.Typed, Row.ChildRaw, &RecordApplied, &RecordMigrated, OutdatedEntries,
				&UnknownKeys, &UnknownNames, &OutdatedNames)
			MigratedOverrides += RecordMigrated
			if !RecordApplied
				continue
		}

		; Assign the leaf key on the resolved node. Nested Map vs object
		; properties are both accepted to match the legacy Features shape.
		try {
			if (Type(Node) == "Map") {
				; Refuse to flatten a seeded Map node (e.g. {enabled:...}) into a scalar via a
				; colliding flat-form [section] key (or vice versa) — that clobbers the shape and
				; crashes a later [...]["enabled"] access (toml-loader-shape-mismatch).
				if (Node.Has(Key) and (Node[Key] is Map) != (Value is Map)) {
					RejectedOverrides += 1
					try LoggerWarn("TomlConfigLoader",
						"v2 override skipped - [{1}].{2} would change Map/scalar shape; keeping the manifest-seeded node.", CurrentSection, Key)
					continue
				}
				Node[Key] := Value
			} else if IsObject(Node) {
				Node.%Key% := Value
			} else {
				try LoggerError("TomlConfigLoader",
					"v2 override skipped — '[{1}]' resolved to a scalar, not an object — check the manifest shape.", CurrentSection)
				RejectedOverrides += 1
				continue
			}
		Applied++
		if ExpectedType == "boolean" && TOML_LiteralKind(RawValue) == "number" {
			MigratedOverrides += 1
			try LoggerInfo("TomlConfigLoader",
				"migrated legacy boolean [{1}].{2} = {3}; the next save persists it as canonical true/false.",
				CurrentSection, Key, TomlConfigLogValue(Value))
		}
		try LoggerDebug("TomlConfigLoader", "[{1}].{2} = {3}.",
			CurrentSection, Key, TomlConfigLogValue(Value))
		} catch as e {
			RejectedOverrides += 1
			try LoggerWarn("TomlConfigLoader",
				"v2 override failed for [{1}].{2}: {3}.", CurrentSection, Key, e.Message)
		}
	}

	if ObsoleteDriverSections > 0 {
		try LoggerWarn("TomlConfigLoader",
			"Ignored {1} obsolete [ahk.*] section(s); they remain until explicit cleanup.",
			ObsoleteDriverSections)
	}
	if UnknownKeys > 0 {
		try LoggerWarn("TomlConfigLoader",
			"Ignored {1} unused configuration key(s) in '{2}' ({3}); they are offered for cleanup.",
			UnknownKeys, FilePath, UnknownNames)
	}
	if OutdatedEntries.Count > 0 {
		try LoggerWarn("TomlConfigLoader",
			"Ignored {1} outdated configuration value(s) in '{2}' ({3}): this build no longer accepts them, so their settings keep the manifest value; they are offered for cleanup.",
			OutdatedEntries.Count, FilePath, OutdatedNames)
	}
	if RejectedOverrides {
		try LoggerError("TomlConfigLoader",
			"v2 config only partially applied ({1} value(s), {2} rejected override(s)); this tree must not replace the original configuration.",
			Applied, RejectedOverrides)
	} else {
		try LoggerSuccess("TomlConfigLoader", "v2 config applied ({1} value(s)).", Applied)
	}
	if MigratedOverrides {
		try LoggerInfo("TomlConfigLoader",
			"applied {1} legacy 0/1 boolean(s) with user intent; the next save persists them as canonical true/false.",
			MigratedOverrides)
	}
	try LoggerInfo("TomlConfigLoader",
		"Config summary for '{1}': {2} applied, {3} rejected, {4} unknown key(s) ignored, {5} owned by another module, {6} key(s) in skipped sections, {7} obsolete section(s), {8} outdated value(s) ignored.",
		FilePath, Applied, RejectedOverrides, UnknownKeys, ForeignOwnedKeys,
		IgnoredSectionKeys, ObsoleteDriverSections, OutdatedEntries.Count)
	return Applied
}
