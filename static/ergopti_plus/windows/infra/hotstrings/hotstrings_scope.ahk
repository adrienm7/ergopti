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
	Owner := HotstringsScopeFiles(Options)
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
 * @returns {Array|Integer} Detached choice batch, or false before any side effect.
 */
HotstringsCategoryScopePlan(Inventory, Targets, Enabled, &Reason) {
	Reason := ""
	if !(Inventory is Map) || !(Targets is Array) || !(Enabled is Integer)
			|| (Enabled != 0 && Enabled != 1) {
		Reason := "invalid-request"
		return false
	}
	if !Targets.Length {
		Reason := "empty-scope"
		return false
	}
	Changes := [], Selected := Map()
	for Id in Targets {
		if !_HotstringsScopeAddressable(Id) || Selected.Has(Id) {
			Reason := "invalid-category"
			return false
		}
		if !Inventory.Has(Id) || !(Inventory[Id] is Array) {
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
			; This legacy remapping belongs to Layout, outside Hotstrings controls.
			if !(StrLower(StrReplace(Id, "_")) == "magickey" && Name == "replace")
				Changes.Push(Map("group", Id, "section", Name, "enabled", Enabled))
		}
	}
	return Changes
}

_HotstringsScopeAddressable(Value) {
	return Value is String && Value != "" && !InStr(Value, ".")
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
 * @returns {Map} Pending or terminal reload receipt; native refusal restores bytes.
 */
HotstringsCategoryScopeApply(Targets, Enabled, Options := unset) {
	if !IsSet(Options)
		Options := Map()
	Operations() {
		global Features, _LegacyTopCategoryMap
		Inventory := _HotstringsCategoryScopeInventory(_LegacyTopCategoryMap)
		Choices := HotstringsCategoryScopePlan(Inventory, Targets, Enabled, &Reason)
		if !(Choices is Array)
			throw Error("Hotstring category selection refused: " . Reason)
		Candidate := _HSDeepCloneMap(Features)
		Rows := [], Entries := []
		for Choice in Choices {
			Id := Choice["group"]
			if Choice.Has("section") {
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

/**
 * Owns additional files without introducing a second transaction coordinator.
 */
class HotstringsScopeFiles {
	__New(Options) {
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
		for Category in ["_global", "dynamichotstrings"] {
			for Field in _PersonalTomlOverrideFields()
				RowsByPath[this.overrides].Push({ Section: Category, Key: Field, Delete: 1 })
		}
		for Field in ["word_delimiters", "consumed_delimiters"]
			RowsByPath[this.overrides].Push({ Section: "__global__", Key: Field, Delete: 1 })
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
