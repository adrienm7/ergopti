; infra/hotstrings/hotstrings_scope.ahk

; ==============================================================================
; MODULE: Hotstrings Scoped Persistence
; DESCRIPTION:
; Coordinates manifest preferences, category overrides and personal metadata in
; one existing conditional journal. Corpus, unknown keys and AI consent survive.
; ==============================================================================

/**
 * Applies recommended values or clears owned settings in one admitted cohort.
 * @param {String} Mode Manifest scope action.
 * @param {Map} Options Paths and lifecycle ports for isolated owner tests.
 * @returns {Map} Pending or terminal reload receipt.
 */
HotstringsScopeApply(Mode, Options := unset) {
	if !IsSet(Options)
		Options := Map()
	ManifestScopePlan("hotstrings", Mode)
	if !_HCW_FlushNumericWrite(false)
		return Map("status", "refused", "scope", "hotstrings", "mode", Mode, "detail", "pending_numeric_write")
	Owner := HotstringsScopeFiles(Options, Mode)
	Operations() {
		Inventory := ManifestScopeInventory("hotstrings", Map("catalogue", Owner.Inventory.Bind(Owner)))
		return ManifestScopePlan("hotstrings", Mode, Inventory).operations
	}
	return ConfigScopeCommitOperations("hotstrings", Mode, Operations, Options, Owner)
}

/**
 * Plans the same explicit category and section choices as the shared Lua owner.
 * @param {Map} Inventory Discovered category ids to actionable section names.
 * @param {Array} Targets Category ids selected by the menu.
 * @param {Integer} Enabled Boolean target, never inferred from mixed state.
 * @param {String} Reason Stable refusal identifier without user values.
 * @param {Array} BoundSections Optional exact group/section leaves of an extension.
 * @returns {Array|Integer} Detached choice batch, or false before any side effect.
 */
HotstringsCategoryScopePlan(Inventory, Targets, Enabled, &Reason, BoundSections := unset) {
	Reason := ""
	if !IsSet(BoundSections)
		BoundSections := []
	if !(Inventory is Map) || !_HotstringsScopeDenseArray(Targets)
			|| !_HotstringsScopeDenseArray(BoundSections) || !(Enabled is Integer)
			|| (Enabled != 0 && Enabled != 1) {
		Reason := "invalid-request"
		return false
	}
	if !Targets.Length && !BoundSections.Length {
		Reason := "empty-scope"
		return false
	}
	Changes := [], Selected := Map(), Leaves := Map(), BoundSeen := Map()
	for Id in Targets {
		if !_HotstringsScopeAddressable(Id) || Selected.Has(Id) {
			Reason := "invalid-category"
			return false
		}
		if !Inventory.Has(Id) || !_HotstringsScopeDenseArray(Inventory[Id]) {
			Reason := "unknown-category"
			return false
		}
		Selected[Id] := true
		Changes.Push(Map("group", Id, "enabled", Enabled))
		Sections := Map()
		for Name in Inventory[Id] {
			if !_HotstringsScopeAddressable(Name) || Name == "-" || Sections.Has(Name) {
				Reason := "invalid-section"
				return false
			}
			Sections[Name] := true
			Changes.Push(Map("group", Id, "section", Name, "enabled", Enabled))
		}
		Leaves[Id] := Sections
	}
	for Leaf in BoundSections {
		if !(Leaf is Map) || !Leaf.Has("group") || !Leaf.Has("section")
				|| !_HotstringsScopeAddressable(Leaf["group"])
				|| !_HotstringsScopeAddressable(Leaf["section"]) || Leaf["section"] == "-" {
			Reason := "invalid-section"
			return false
		}
		Id := Leaf["group"], Section := Leaf["section"]
		if !Inventory.Has(Id) || !_HotstringsScopeDenseArray(Inventory[Id]) {
			Reason := "unknown-category"
			return false
		}
		Names := Map()
		for Name in Inventory[Id] {
			if !_HotstringsScopeAddressable(Name) || Name == "-" || Names.Has(Name) {
				Reason := "invalid-section"
				return false
			}
			Names[Name] := true
		}
		if !Names.Has(Section) || (BoundSeen.Has(Id) && BoundSeen[Id].Has(Section)) {
			Reason := "invalid-section"
			return false
		}
		if !BoundSeen.Has(Id)
			BoundSeen[Id] := Map()
		BoundSeen[Id][Section] := true
		; Opening a bound leaf needs its group. Closing it leaves unrelated
		; symbol choices and the group's gate untouched.
		if Enabled && !Selected.Has(Id) {
			Changes.Push(Map("group", Id, "enabled", true))
			Selected[Id] := true
		}
		if !Leaves.Has(Id)
			Leaves[Id] := Map()
		if !Leaves[Id].Has(Section) {
			Changes.Push(Map("group", Id, "section", Section, "enabled", Enabled))
			Leaves[Id][Section] := true
		}
	}
	return Changes
}

_HotstringsScopeAddressable(Value) {
	return Value is String && Value != "" && !InStr(Value, ".")
}

_HotstringsScopeDenseArray(Values) {
	if !(Values is Array)
		return false
	loop Values.Length
		if !Values.Has(A_Index)
			return false
	return true
}

; The legacy tray map also contains Layout, Gestures and Shortcuts. Only the
; Hotstrings namespace belongs to this owner's discoverable category inventory.
_HotstringsCategoryScopeInventory(Categories, ReadSections := ManifestFeaturesForSection) {
	Inventory := Map()
	for Id, Prefix in Categories {
		if SubStr(Prefix, 1, StrLen("hotstrings.")) != "hotstrings."
			continue
		Inventory[Id] := []
		for Entry in ReadSections.Call(Prefix) {
			Parts := StrSplit(Entry["path"], ".")
			Inventory[Id].Push(Parts[Parts.Length])
		}
	}
	return Inventory
}

/**
 * Publishes a category/section batch through the existing fenced reload owner.
 * @param {Array} Targets Native category ids from the discovered tray catalogue.
 * @param {Integer} Enabled Explicit Boolean target.
 * @param {Map} Options Existing journal/lifecycle ports for isolated tests.
 * @param {Array} BoundSections Optional exact native leaves, alongside whole groups.
 * @returns {Map} Pending or terminal reload receipt; native refusal restores bytes.
 */
HotstringsCategoryScopeApply(Targets, Enabled, Options := unset, BoundSections := unset) {
	if !IsSet(Options)
		Options := Map()
	if !IsSet(BoundSections)
		BoundSections := []
	Operations() {
		global _LegacyTopCategoryMap
		Inventory := _HotstringsCategoryScopeInventory(_LegacyTopCategoryMap)
		Choices := HotstringsCategoryScopePlan(Inventory, Targets, Enabled, &Reason, BoundSections)
		if !(Choices is Array)
			throw Error("Hotstring category selection refused: " . Reason)
		return _HotstringsScopeChoiceOperations(Choices)
	}
	return ConfigScopeCommitOperations("hotstrings", Enabled ? "enable_all" : "disable_all", Operations, Options)
}

; Native bound leaves and pack-owned features join one detached journal image.
_HotstringsScopeChoiceOperations(Choices, ExtensionGroups := unset) {
	global Features, _LegacyTopCategoryMap
	if !IsSet(ExtensionGroups)
		ExtensionGroups := Map()
	Candidate := _HSDeepCloneMap(Features), Rows := [], Entries := []
	for Choice in Choices {
		Id := Choice["group"]
		if ExtensionGroups.Has(Id) {
			Path := Choice.Has("section") ? "hotstrings.modules." . Id . "." . Choice["section"]
				: "hotstrings.groups." . Id
			Rows.Push(ManifestSparseOperation(Path, Choice["enabled"]))
		} else if Choice.Has("section") {
			Entries.Push(Map("path", _LegacyTopCategoryMap[Id] . "." . Choice["section"],
				"value", Choice["enabled"]))
		} else {
			Rows.Push(_ConfigSparseOperation("category_enabled", _CategoryEnabledKey(Id), Choice["enabled"]))
		}
	}
	if _ConfigStageFeatureEntries(Candidate, Entries, Rows) != Entries.Length
		throw Error("A category scope feature could not be resolved.")
	return Rows
}

/**
 * Selects a discovered extension's whole groups and exact native bound leaves.
 * Discovery and ownership are checked inside the existing configuration lease.
 * @param {String} ExtensionId Shipped or installed pack id captured by the menu.
 * @param {Integer} Enabled Explicit Boolean preference.
 * @param {Map} Options Existing journal ports and optional discovery roots.
 * @returns {Map} Pending or terminal receipt; refusal restores the whole cohort.
 */
HotstringsExtensionScopeApply(ExtensionId, Enabled, Options := unset) {
	if !IsSet(Options)
		Options := Map()
	RootsFn := Options.Get("roots", _HotstringExtensions_CurrentRoots)
	Operations() {
		global _LegacyTopCategoryMap
		if A_IsSuspended
			throw Error("An extension selection cannot change while paused.")
		Inventory := _HotstringsCategoryScopeInventory(_LegacyTopCategoryMap)
		NativeIds := Map(), ExtensionGroups := Map(), Targets := [], Bound := []
		for Id in Inventory
			NativeIds[StrLower(StrReplace(Id, "_"))] := Id
		OwnedPack := false
		for Pack in HotstringExtensions_Scan(RootsFn.Call()) {
			if Pack.id != ExtensionId
				continue
			if OwnedPack
				throw Error("Extension ownership is ambiguous.")
			OwnedPack := true
			for File in Pack.toml_files {
				if Inventory.Has(File.category)
					throw Error("Extension category ownership is ambiguous.")
				Inventory[File.category] := [], ExtensionGroups[File.category] := true
				Targets.Push(File.category)
				for Section in File.sections
					Inventory[File.category].Push(Section["name"])
			}
			for File in (Pack.HasOwnProp("bound_files") ? Pack.bound_files : []) {
				Binding := File.binding
				Key := StrLower(StrReplace(Binding["category"], "_"))
				if !NativeIds.Has(Key)
					throw Error("An extension binding has no native category owner.")
				Id := NativeIds[Key]
				if Binding.Has("sections") {
					for Section in Binding["sections"]
						Bound.Push(Map("group", Id, "section", Section))
				} else {
					Targets.Push(Id)
				}
			}
		}
		if !OwnedPack
			throw Error("The extension no longer owns this selection.")
		Choices := HotstringsCategoryScopePlan(Inventory, Targets, Enabled, &Reason, Bound)
		if !(Choices is Array)
			throw Error("Extension selection refused: " . Reason)
		return _HotstringsScopeChoiceOperations(Choices, ExtensionGroups)
	}
	return ConfigScopeCommitOperations("hotstrings", Enabled ? "enable_all" : "disable_all", Operations, Options)
}

/**
 * Publishes every discovered personal section through the fenced reload owner.
 * The existing typed planner discovers and seeds personal paths inside the
 * lease; runtime choices remain unpublished until replacement acknowledgement.
 * @param {Integer} Enabled Explicit Boolean target.
 * @param {Map} Options Existing journal/lifecycle ports for isolated tests.
 * @returns {Map} Pending or terminal receipt; native refusal restores exact bytes.
 */
HotstringsPersonalScopeApply(Enabled, Options := unset) {
	if !IsSet(Options)
		Options := Map()
	Operations() {
		if !(Enabled is Integer) || (Enabled != 0 && Enabled != 1)
			throw TypeError("A personal hotstring scope requires an explicit Boolean target.")
		return _ConfigBuildHotstringIntentPlan("personal", "", Enabled).updates
	}
	return ConfigScopeCommitOperations("hotstrings", Enabled ? "enable_all" : "disable_all", Operations, Options)
}

; Catalogue identity comes from the same owners as the settings window and L4.
_HotstringsScopeCatalogue() {
	Entries := []
	for Entry in _HCW_BuildCategoryList(false) {
		if !Entry.IsExtension
			Entries.Push(Entry)
	}
	for Pack in HotstringExtensions_Scan(_HotstringExtensions_CurrentRoots()) {
		for File in Pack.toml_files {
			Entries.Push({ Key: File.category, Path: File.path, IsPersonal: false,
				IsExtension: true, ExtId: Pack.id })
		}
	}
	return Entries
}

; Category masters are declared by the shared language catalogue.
_HotstringsScopeLanguagePaths() {
	Paths := []
	for Pack in HotstringsLanguageCategories() {
		for Category in Pack["categories"]
			Paths.Push("category_enabled." . Category["v2"])
	}
	return Paths
}

; A fresh reader avoids letting a previous preview's cache define reset scope.
_HotstringsScopeSections(Entry) {
	return _HCW_GetSections(Entry, FSReadUtf8Exact)
}

; Resolve both sides of source identity without changing admitted write paths.
_HotstringsScopeSourceKey(Path) {
	Loop Files, Path
		return StrLower(A_LoopFileFullPath)
	; Missing files have no sections; preserve their lexical identity.
	return _ConfigWriteLeaseKey(Path)
}


/** Resolves only source metadata and the shared fallback, excluding user overrides. */
_HotstringsScopeInheritedDelay(Category, Section) {
	global GLOBAL_DEFAULT_DELAY
	Config := ParseTomlGroupConfig(Category)
	if Config.Sections.Has(Section) && Config.Sections[Section].Delay != ""
		return Config.Sections[Section].Delay
	return Config.Delay != "" ? Config.Delay : GLOBAL_DEFAULT_DELAY
}

/**
 * Owns additional files without introducing a second transaction coordinator.
 */
class HotstringsScopeFiles {
	__New(Options, Mode := "clear") {
		this.mode := Mode
		this.inherited := Options.Get("inherited_delay", _HotstringsScopeInheritedDelay)
		this.catalogue := Options.Get("catalogue", _HotstringsScopeCatalogue)
		this.sections := Options.Get("sections", _HotstringsScopeSections)
		this.languages := Options.Get("language_paths", _HotstringsScopeLanguagePaths)
		this.overrides := Options.Has("override_path") ? Options["override_path"] : HotstringsConfigPath()
		this.personal := Options.Has("personal_path") ? Options["personal_path"] : PersonalTomlPath()
		this.personalKey := _HotstringsScopeSourceKey(this.personal)
		this.paths := [this.overrides]
		this.owned := Map(StrLower(this.overrides), true)
		for Entry in this.catalogue.Call() {
			if Entry.IsPersonal && !this.owned.Has(StrLower(Entry.Path)) {
				this.paths.Push(Entry.Path)
				this.owned[StrLower(Entry.Path)] := true
			}
		}
	}

	; Rescan after lifecycle admission, including newly discovered source sections.
	Inventory() {
		this.entries := this.catalogue.Call()
		Paths := this.languages.Call()
		for Entry in this.entries {
			if Entry.IsPersonal {
				if !this.owned.Has(StrLower(Entry.Path))
					throw Error("The personal hotstring catalogue changed before admission.")
				if _HotstringsScopeSourceKey(Entry.Path) != this.personalKey
					continue
				for Section in this.sections.Call(Entry) {
					Paths.Push("hotstrings.personal." . Section.Name . ".enabled")
					Paths.Push("hotstrings.personal." . Section.Name . ".time_activation_seconds")
				}
			} else {
				if Entry.HasOwnProp("IsVirtual") && Entry.IsVirtual
					continue
				Paths.Push("hotstrings.groups." . Entry.Key)
				for Section in this.sections.Call(Entry)
					Paths.Push("hotstrings.modules." . Entry.Key . "." . Section.Name)
			}
		}
		return Paths
	}

	Build() {
		RowsByPath := Map(this.overrides, [])
		for Item in _HCW_BuildResetAllPlan(this.entries, this.sections) {
			if Item.Kind == "personal" {
				if !RowsByPath.Has(Item.Path)
					RowsByPath[Item.Path] := []
				Section := Item.Sec == "" ? "_meta" : "_meta.sections." . Item.Sec
				RowsByPath[Item.Path].Push({ Section: Section, Key: Item.Field, Delete: 1 })
			} else {
				Section := Item.Category . (Item.Sec == "" ? "" : "." . Item.Sec)
				for Field in _PersonalTomlOverrideFields()
					RowsByPath[this.overrides].Push({ Section: Section, Key: Field, Delete: 1 })
			}
		}
		Groups := []
		for Entry in this.entries {
			if Entry.IsPersonal || Entry.IsExtension
				continue
			Sections := []
			for Section in this.sections.Call(Entry)
				Sections.Push(Section.Name)
			Groups.Push(Map("id", Entry.Key, "sections", Sections, "bundled", true))
		}
		for Recommendation in HotstringsScopeDelayRecommendations(this.mode,
				ManifestFeatures(), Groups, this.inherited) {
			Section := Recommendation["group"] . "." . Recommendation["section"]
			; Replace the existing deletion in place, so no duplicate writer row can
			; discard the measured recommendation during transaction preparation.
			Found := false
			for Index, Row in RowsByPath[this.overrides] {
				if Row.Section == Section && Row.Key == "delay" {
					RowsByPath[this.overrides][Index] := { Section: Section, Key: "delay",
						Value: Recommendation["seconds"] }
					Found := true
					break
				}
			}
			if !Found
				throw Error("A recommended hotstring delay has no owned reset row.")
		}
		for Category in ["_global", "dynamichotstrings"] {
			for Field in _PersonalTomlOverrideFields()
				RowsByPath[this.overrides].Push({ Section: Category, Key: Field, Delete: 1 })
		}
		; Read after admission, independently of the live engine and UI caches.
		DelimiterSourcePresent := FSStrictExists(this.overrides)
		DelimiterSource := DelimiterSourcePresent ? FSReadUtf8Exact(this.overrides) : ""
		if !(DelimiterSource is String)
			throw Error("The admitted hotstring delimiter source is unreadable.")
		Stored := _ParseTomlFileImpl(this.overrides, false, false, DelimiterSource)
		GlobalSettings := Stored.Get("__global__", Map())
		Delimiters := HSE_TerminatorRestoreDefaults(
			GlobalSettings.Get("word_delimiters", ""), GlobalSettings.Get("consumed_delimiters", ""))
		for Field, Pair in Map("word_delimiters", [Delimiters.Word, Delimiters.DefaultWord],
				"consumed_delimiters", [Delimiters.Consumed, Delimiters.DefaultConsumed]) {
			Row := { Section: "__global__", Key: Field }
			if Pair[1] == Pair[2]
				Row.Delete := 1
			else
				Row.Value := Pair[1]
			RowsByPath[this.overrides].Push(Row)
		}
		Candidates := []
		for Path, Rows in RowsByPath {
			; Several TOML sources may share an extension override category.
			Unique := [], Seen := Map()
			for Row in Rows {
				Identity := Row.Section . "`n" . Row.Key
				if !Seen.Has(Identity) {
					Seen[Identity] := true
					Unique.Push(Row)
				}
			}
			if Path == this.overrides {
				Image := TOML_BuildUpdatedContent(Path, Unique)
				if Image.Get("status", "") == "ok"
						&& (Image["source_present"] != DelimiterSourcePresent
						|| !(Image["source_content"] == DelimiterSource))
					throw Error("The admitted hotstring delimiter source changed during planning.")
			} else {
				Present := FSStrictExists(Path)
				Original := Present ? FSReadUtf8Exact(Path) : ""
				Content := Original
				for Row in Unique {
					Section := Row.Section == "_meta" ? "" : SubStr(Row.Section, StrLen("_meta.sections.") + 1)
					Content := _HCW_BuildTomlMetaPatch(Section, Row.Key, "", Content)
				}
				Image := Map("status", "ok", "kind", "rendered", "source_present", Present,
					"source_content", Original, "content", Content)
			}
			Candidates.Push({ path: Path, image: Image })
		}
		return Candidates
	}
}
