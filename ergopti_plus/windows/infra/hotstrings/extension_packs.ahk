; infra/hotstrings/extension_packs.ahk

; ==============================================================================
; MODULE: Existing Extension Pack Discovery
; DESCRIPTION:
; Discovers bundled, committed layout and user packs in overlay order. Desired
; group and section choices stay in the existing feature map; registration uses
; a separate plan so disabling the master never rewrites those choices.
;
; A manifest may bind one of its files to a historical category
; ([extension.hotstring_bindings.<stem>]): the file then supplies that bundled
; category, or some of its sections, and is listed in bound_files instead of
; toml_files, so it never becomes an ext: category. Every driver routes those
; files into their category through its TOML loader. A layout extension may
; also declare the physical key that types its
; magic key ([extension.magic_key]).
; The Lua scanner (_shared/lua/hotstrings/extensions.lua) applies the same
; rules; both replay the extension_binding_vectors.json and
; extension_magic_key_vectors.json corpora of _shared/tests/corpus/layouts.
; ==============================================================================

global _HotstringExtensionPacks := []
global _HotstringExtensionPaths := Map()
; The bundled categories this boot's extensions bind to their own files, keyed
; by category lowercased without underscores (the spelling every caller of
; HotstringsBundledTomlPath folds to): Map("path", the file of a whole-category
; binding or "", "sections", Map(section → file), "section_extensions",
; Map(section → pack id), "extension", "name").
; Committed once by HotstringExtensions_Prepare; read through
; HotstringsBoundTomlPath (hotstrings_cache.ahk).
global _HotstringBoundSources := Map()

; The only fields a binding may carry: it says where a historical section's
; rules live, never whether they are on, so an `enabled` key is refused.
global HOTSTRING_BINDING_FIELDS := Map("category", true, "feature_section", true, "sections", true, "source", true)
; A bound file replaces a bundled source, so it keeps the common priority tier.
global HOTSTRING_BINDING_SOURCES := Map("common", true)
global HOTSTRING_BINDING_TABLE := "extension.hotstring_bindings"
; Identifier shapes shared with the Lua scanner and the layout inventory.
global HOTSTRING_BINDING_STEM_PATTERN := "^[a-z][a-z0-9_-]*$"
global HOTSTRING_BINDING_ID_PATTERN := "^[a-z][a-z0-9_]*$"
global HOTSTRING_BINDING_FEATURE_PATTERN := "^hotstrings\.[a-z][a-z0-9_]*$"
; [extension.magic_key] carries one field: the physical key, named by its
; KeyboardEvent.code as in _shared/data/keycodes/physical_keys.json, that types
; the magic key on the extension's layout. Replayed with the Lua scanner from
; _shared/tests/corpus/layouts/extension_magic_key_vectors.json.
global EXTENSION_MAGIC_KEY_FIELDS := Map("key", true)
global EXTENSION_KEY_CODE_PATTERN := "^[A-Z][A-Za-z0-9]*$"

/**
 * Reads the existing roots in bundled, installed, shipped Ergopti, then user
 * precedence order. The Ergopti extension the driver ships is installed by
 * shipping: the built-in emulation types it from that copy and machines already
 * use it without an installed record. It follows the installed generations so a
 * generation staged before this version cannot hide the files this code expects.
 * @param {String} ConfigDir Configuration directory.
 * @param {String} BundledRoot Shipped extension root.
 * @param {String} RegistryDir Shipped registry folder with its trailing
 *   backslash; LayoutRegistry_BundledDir() when omitted.
 * @returns {Array} Discovery roots: folders, and the shipped {pack: Dir}.
 */
HotstringExtensions_Roots(ConfigDir, BundledRoot, RegistryDir := unset) {
	Roots := [BundledRoot]
	; The installed-layouts record may have been written by another build or
	; cut short by a crash or a sync tool. Its layouts' packs are then missing
	; from this load, reported, while the bundled, shipped and user packs still
	; load, as on macOS and Linux: startup never depends on that record, and the
	; layout manager keeps refusing installs and removals on it.
	try Installed := LayoutExtension_Roots(LayoutRegistry_LocalDir(ConfigDir))
	catch as Err {
		LoggerError("ExtensionPacks", "The installed layouts' extensions are skipped: {1}", Err.Message)
		Installed := []
	}
	for Root in Installed
		Roots.Push(Root)
	Shipped := HotstringExtensions_ShippedRoot(IsSet(RegistryDir) ? RegistryDir : LayoutRegistry_BundledDir())
	if IsObject(Shipped)
		Roots.Push(Shipped)
	Roots.Push(RTrim(ConfigDir, "\/") . "\extensions")
	return Roots
}

/**
 * The extension root of the layout family the driver ships built in, as
 * layouts/extension.shipped_root does on macOS and Linux: the registry folder
 * named after registry.ergopti_family, whose layouts declare it as their
 * extension_source.
 * @param {String} RegistryDir Shipped registry folder with its trailing backslash.
 * @returns {Object|String} {pack: Dir}, or "" when the registry ships no such extension.
 */
HotstringExtensions_ShippedRoot(RegistryDir) {
	if !(RegistryDir is String) || RegistryDir == ""
		return ""
	Dir := RegistryDir . LayoutRegistry_Settings()["ergopti_family"]
	if !FileExist(Dir . "\manifest.toml") {
		LoggerWarn("ExtensionPacks", "No shipped Ergopti extension in {1}.", RegistryDir)
		return ""
	}
	return {pack: Dir}
}

/**
 * Seeds discovered leaves before the boot config loader resolves user choices,
 * and commits where the bound categories load from this boot.
 * @param {Map} Target Desired features before configuration projection.
 * @param {Array} Roots Ordered extension roots.
 * @returns {Array} Complete discovered packs.
 */
HotstringExtensions_Prepare(Target, Roots) {
	global _HotstringBoundSources
	Packs := HotstringExtensions_Scan(Roots)
	_HotstringBoundSources := HotstringExtensions_RouteBound(Packs)
	HotstringExtensions_Seed(Target, Packs, ManifestDefaultFor)
	return Packs
}

/**
 * Routes every bound file through HotstringExtensions_Source, which refuses two
 * owners of one category or section before anything loads.
 * @param {Array} Packs Discovered packs.
 * @returns {Map} Category folded to lowercase without underscores → Map("path",
 *   whole-category file or "", "sections", Map(lowercase section → file),
 *   "section_extensions", Map(lowercase section → pack id), "extension",
 *   "name": the pack binding it whole, "" otherwise).
 */
HotstringExtensions_RouteBound(Packs) {
	Routes := Map()
	for Pack in Packs {
		for File in (Pack.HasOwnProp("bound_files") ? Pack.bound_files : []) {
			Binding := File.binding
			Category := Binding["category"]
			Key := StrLower(StrReplace(Category, "_"))
			if !Routes.Has(Key)
				Routes[Key] := Map("path", "", "sections", Map(), "section_extensions", Map(),
					"extension", "", "name", "")
			Route := Routes[Key]
			if !Binding.Has("sections") {
				Route["path"] := HotstringExtensions_Source(Packs, Category)
				Route["extension"] := Pack.id
				Route["name"] := Pack.name
				continue
			}
			for Section in Binding["sections"] {
				Route["sections"][StrLower(Section)] := HotstringExtensions_Source(Packs, Category, Section)
				Route["section_extensions"][StrLower(Section)] := Pack.id
			}
		}
	}
	return Routes
}

/**
 * Registers only effective sections through the existing TOML loader.
 * @param {Map} Target Desired or effective feature tree.
 * @param {Array} Packs Discovered packs.
 * @param {Integer} MasterOn Effective hotstring master.
 * @returns {Integer} Number of source entries registered.
 */
HotstringExtensions_Register(Target, Packs, MasterOn) {
	global _HotstringExtensionPaths
	Loaded := 0
	for Request in HotstringExtensions_RegistrationPlan(Target, Packs, MasterOn) {
		_HotstringExtensionPaths[Request.category] := Request.path
		Loaded += LoadExtTomlFile(Request.path, Request.category, Request.section)
	}
	return Loaded
}

/**
 * Discovers existing-format hotstring packs; later roots replace earlier packs.
 * @param {Array} Roots - Absolute roots in overlay order.
 * @returns {Array} Packs with canonical category identities and section metadata;
 *   files bound to a historical category are listed in bound_files, the others
 *   in toml_files.
 */
HotstringExtensions_Scan(Roots) {
	ById := Map()
	for Root in Roots {
		; A {pack: Dir} root names one extension directory itself: the layout
		; extension shipped in the registry folder sits beside layouts that are
		; not installed, so its parent cannot be scanned (extensions.lua root_dirs).
		if IsObject(Root) {
			if !Root.HasOwnProp("pack") || !(Root.pack is String) || Root.pack == ""
				throw ValueError("Invalid extension pack root.")
			PackDirs := [RTrim(Root.pack, "\/")]
		} else {
			PackDirs := FSListDirectoryStrict(Root, true)
		}
		for PackDir in PackDirs {
			SplitPath PackDir, &Id
			Manifest := ParseTomlFile(PackDir . "\manifest.toml")
			if TOML_UnreadableFile(PackDir . "\manifest.toml")
				throw Error("Extension manifest read did not commit.")
			Name := Manifest.Has("extension") ? Manifest["extension"].Get("name", Id) : Id
			if !(Name is String)
				throw TypeError("Extension name must be a string.")
			Bindings := HotstringExtensions_Bindings(Manifest)
			MagicKey := HotstringExtensions_MagicKey(Manifest)
			Files := [], BoundFiles := []
			for FilePath in FSListDirectoryStrict(PackDir . "\hotstrings") {
				if !RegExMatch(FilePath, "i)\.toml$")
					continue
				SplitPath FilePath, , , , &Stem
				Category := "ext:" . Id . ":" . Stem
				Config := ParseTomlGroupConfig(Category, FilePath)
				Counts := _TomlWarmFileCounts(FilePath)
				if TOML_UnreadableFile(FilePath)
					throw Error("Extension hotstring read did not commit.")
				Sections := [], Total := 0
				for Section, Count in Counts {
					if Section == "_meta" || SubStr(Section, 1, 6) == "_meta."
						continue
					Description := Config.Sections.Has(Section) ? Config.Sections[Section].Description : ""
					Sections.Push(Map("name", Section, "description", Description == "" ? Section : Description, "count", Count))
					Total += Count
				}
				Record := { path: FilePath, stem: Stem, category: Category, sections: Sections, count: Total }
				if Bindings.Has(Stem) {
					Record.binding := Bindings[Stem]
					BoundFiles.Push(Record)
					Bindings.Delete(Stem)
				} else {
					Files.Push(Record)
				}
			}
			; A binding names a file the pack must carry: without it a historical
			; section would read as rules the user lost, not as a broken install.
			if Bindings.Count
				throw Error("Bound extension hotstring file is missing.")
			ById[Id] := { id: Id, name: Name, dir: PackDir, toml_files: Files, bound_files: BoundFiles,
				magic_key: MagicKey }
		}
	}
	Packs := []
	for Id, Pack in ById
		Packs.Push(Pack)
	return Packs
}

/**
 * Reads and validates the historical source bindings of one manifest.
 * The per-file table headers, one [extension.hotstring_bindings] table of
 * inline tables and an inline hotstring_bindings key of [extension] are the
 * spellings the Lua decoder accepts, so each is read; a stem declared twice is
 * refused rather than resolved by spelling.
 * @param {Map} Manifest - ParseTomlFile result, one Map per section header.
 * @returns {Map} Validated bindings keyed by hotstring file stem.
 */
HotstringExtensions_Bindings(Manifest) {
	global HOTSTRING_BINDING_TABLE
	Declared := []
	if Manifest.Has("extension") && Manifest["extension"].Has("hotstring_bindings")
		Declared.Push(Manifest["extension"]["hotstring_bindings"])
	if Manifest.Has(HOTSTRING_BINDING_TABLE)
		Declared.Push(Manifest[HOTSTRING_BINDING_TABLE])
	Prefix := HOTSTRING_BINDING_TABLE . "."
	for Header, Values in Manifest {
		if SubStr(Header, 1, StrLen(Prefix)) == Prefix
			Declared.Push(Map(SubStr(Header, StrLen(Prefix) + 1), Values))
	}
	Bindings := Map()
	for Table in Declared {
		if !(Table is Map)
			throw ValueError("Invalid extension hotstring bindings.")
		for Stem, Binding in Table {
			if Bindings.Has(Stem)
				throw ValueError("An extension hotstring binding is declared twice.")
			Bindings[Stem] := _HotstringExtensions_ValidBinding(Stem, Binding)
		}
	}
	return Bindings
}

/**
 * Reads the physical magic key a layout extension declares.
 * The [extension.magic_key] table and the inline magic_key key of [extension]
 * are the spellings the Lua decoder accepts; declaring both is refused.
 * @param {Map} Manifest - ParseTomlFile result, one Map per section header.
 * @returns {String} The declared KeyboardEvent.code, or "" when none is declared.
 */
HotstringExtensions_MagicKey(Manifest) {
	global EXTENSION_MAGIC_KEY_FIELDS, EXTENSION_KEY_CODE_PATTERN
	Declared := []
	if Manifest.Has("extension") && Manifest["extension"].Has("magic_key")
		Declared.Push(Manifest["extension"]["magic_key"])
	if Manifest.Has("extension.magic_key")
		Declared.Push(Manifest["extension.magic_key"])
	if Declared.Length == 0
		return ""
	if Declared.Length > 1
		throw ValueError("The extension magic key is declared twice.")
	Table := Declared[1]
	if !(Table is Map)
		throw ValueError("Invalid extension magic key.")
	for Field in Table {
		if !EXTENSION_MAGIC_KEY_FIELDS.Has(Field)
			throw ValueError("Unknown extension magic key field.")
	}
	Key := Table.Get("key", 0)
	if !(Key is String) || !RegExMatch(Key, EXTENSION_KEY_CODE_PATTERN)
		throw ValueError("Invalid extension magic key code.")
	return Key
}

; One binding, checked field by field against the shapes the Lua scanner uses.
_HotstringExtensions_ValidBinding(Stem, Binding) {
	global HOTSTRING_BINDING_FIELDS, HOTSTRING_BINDING_SOURCES, HOTSTRING_BINDING_STEM_PATTERN
	global HOTSTRING_BINDING_ID_PATTERN, HOTSTRING_BINDING_FEATURE_PATTERN
	if !(Stem is String) || !RegExMatch(Stem, HOTSTRING_BINDING_STEM_PATTERN) || !(Binding is Map)
		throw ValueError("Invalid extension hotstring binding.")
	for Key in Binding {
		if !HOTSTRING_BINDING_FIELDS.Has(Key)
			throw ValueError("Unknown extension hotstring binding field.")
	}
	Category := Binding.Get("category", 0), Feature := Binding.Get("feature_section", 0)
	Source := Binding.Get("source", 0)
	if !(Category is String) || !RegExMatch(Category, HOTSTRING_BINDING_ID_PATTERN)
		|| !(Feature is String) || !RegExMatch(Feature, HOTSTRING_BINDING_FEATURE_PATTERN)
		|| !(Source is String) || !HOTSTRING_BINDING_SOURCES.Has(Source)
		throw ValueError("Invalid historical extension hotstring binding.")
	Valid := Map("category", Category, "feature_section", Feature, "source", Source)
	if Binding.Has("sections") {
		Sections := Binding["sections"]
		if !(Sections is Array) || Sections.Length == 0
			throw ValueError("Invalid extension section selection.")
		Seen := Map()
		for Section in Sections {
			if !(Section is String) || !RegExMatch(Section, HOTSTRING_BINDING_ID_PATTERN) || Seen.Has(Section)
				throw ValueError("Invalid extension section selection.")
			Seen[Section] := true
		}
		Valid["sections"] := Sections.Clone()
	}
	return Valid
}

/**
 * The discovered file that supplies a category, or one section of it.
 * A namespaced ext: key names its own file. A historical category keeps its
 * bundled source unless a pack binds it: a whole-category binding replaces the
 * file, a section binding only those sections, and the category's general
 * metadata stays with the bundled file. Two owners are refused: either silent
 * winner would depend on the order the packs were scanned in.
 * @param {Array} Packs - Discovered packs.
 * @param {String} Category - Runtime category, historical or namespaced.
 * @param {String} Section - Section name, or "" for the category itself.
 * @returns {String} The bound file path, "" when the bundled source applies.
 */
HotstringExtensions_Source(Packs, Category, Section := "") {
	if !(Packs is Array) || !(Category is String) || Category == "" || !(Section is String)
		throw ValueError("Extension source resolution needs packs, a category and a section name.")
	Namespaced := SubStr(Category, 1, 4) == "ext:"
	Owner := ""
	for Pack in Packs {
		for Files in [Pack.toml_files, Pack.HasOwnProp("bound_files") ? Pack.bound_files : []] {
			for File in Files {
				if Namespaced {
					if File.category == Category
						return File.path
					continue
				}
				Binding := File.HasOwnProp("binding") ? File.binding : 0
				if !(Binding is Map) || Binding["category"] !== Category
					|| !_HotstringExtensions_Covers(Binding, Section)
					continue
				if Owner != ""
					throw ValueError("Two extensions bind the same historical hotstring source: "
						. Category . (Section == "" ? "" : "." . Section))
				Owner := File.path
			}
		}
	}
	return Owner
}

; Whether a binding claims one section ("" = the category's general data).
_HotstringExtensions_Covers(Binding, Section) {
	if !Binding.Has("sections")
		return true
	if Section == ""
		return false
	for Name in Binding["sections"] {
		if Name == Section
			return true
	}
	return false
}

/**
 * Seeds only absent dynamic leaves, retaining explicit preferences on refresh.
 * @param {Map} Target - Desired feature map, before configuration is applied.
 * @param {Array} Packs - Discovered extension packs.
 * @param {Func} DefaultFor - Canonical manifest default resolver.
 */
HotstringExtensions_Seed(Target, Packs, DefaultFor) {
	Hotstrings := Target["hotstrings"]
	if !Hotstrings.Has("groups")
		Hotstrings["groups"] := Map()
	if !Hotstrings.Has("modules")
		Hotstrings["modules"] := Map()
	for Pack in Packs {
		for File in Pack.toml_files {
			Category := File.category
			if !Hotstrings["groups"].Has(Category)
				Hotstrings["groups"][Category] := DefaultFor.Call("hotstrings.groups." . Category)
			if !Hotstrings["modules"].Has(Category)
				Hotstrings["modules"][Category] := Map()
			for Section in File.sections {
				Name := Section["name"]
				if !Hotstrings["modules"][Category].Has(Name)
					Hotstrings["modules"][Category][Name] := DefaultFor.Call("hotstrings.modules." . Category . "." . Name)
			}
		}
	}
}

/**
 * Selects effective sections without mutating desired preferences.
 * @param {Map} Target - Desired feature map seeded for these packs.
 * @param {Array} Packs - Discovered extension packs.
 * @param {Integer} MasterOn - Effective Hotstrings master state.
 * @returns {Array} Existing-loader requests with category, section and file path.
 */
HotstringExtensions_RegistrationPlan(Target, Packs, MasterOn) {
	Plan := []
	if !MasterOn
		return Plan
	Hotstrings := Target["hotstrings"]
	for Pack in Packs {
		for File in Pack.toml_files {
			if !_HotstringExtensions_Boolean(Hotstrings["groups"][File.category])
				continue
			for Section in File.sections {
				if _HotstringExtensions_Boolean(Hotstrings["modules"][File.category][Section["name"]])
					Plan.Push({ category: File.category, section: Section["name"], path: File.path })
			}
		}
	}
	return Plan
}

_HotstringExtensions_Boolean(Value) {
	if !(Value is Integer) || (Value != 0 && Value != 1)
		throw ValueError("Extension activation requires a Boolean preference.")
	return Value
}

/**
 * Publishes one discovered preference without changing its master or siblings.
 * @param {String} Path Canonical group or section preference.
 * @param {Integer} Value Explicit desired Boolean.
 * @param {Map} Options Lifecycle ports and optional discovery roots callback.
 * @returns {Map} Receipt retained until reload commits or compensates.
 */
HotstringExtensions_SetEnabled(Path, Value, Options := unset) {
	_HotstringExtensions_Boolean(Value)
	if !IsSet(Options)
		Options := Map()
	if !(Options is Map)
		throw TypeError("Extension publication requires an options map.")
	RootsFn := Options.Get("roots", _HotstringExtensions_CurrentRoots)
	Operations() {
		; Rescan under the configuration lease: a menu opened before uninstall
		; cannot persist activation for content which is no longer owned.
		for Pack in HotstringExtensions_Scan(RootsFn.Call()) {
			for File in Pack.toml_files {
				if Path == "hotstrings.groups." . File.category
					return [ManifestSparseOperation(Path, Value)]
				for Section in File.sections {
					if Path == "hotstrings.modules." . File.category . "." . Section["name"]
						return [ManifestSparseOperation(Path, Value)]
				}
			}
		}
		throw ValueError("The extension no longer owns this preference.")
	}
	return ConfigScopeCommitOperations("hotstrings", "extension_preference", Operations, Options)
}

/**
 * Publishes a discovered file's category and sections in one reload transaction.
 * @param {String} Category Canonical namespaced extension category id.
 * @param {Integer} Value Explicit desired Boolean.
 * @param {Map} Options Lifecycle ports and optional discovery roots callback.
 * @returns {Map} Pending or terminal receipt owned by the reload journal.
 */
HotstringExtensions_SetCategoryEnabled(Category, Value, Options := unset) {
	_HotstringExtensions_Boolean(Value)
	if !IsSet(Options)
		Options := Map()
	if !(Options is Map)
		throw TypeError("Extension publication requires an options map.")
	RootsFn := Options.Get("roots", _HotstringExtensions_CurrentRoots)
	Operations() {
		Inventory := Map()
		; Resolve current ownership under the configuration lease, including a
		; file removed since the tray was built. No cached menu metadata can write.
		for Pack in HotstringExtensions_Scan(RootsFn.Call()) {
			for File in Pack.toml_files {
				if Inventory.Has(File.category)
					throw ValueError("Extension category ownership is ambiguous.")
				Inventory[File.category] := []
				for Section in File.sections
					Inventory[File.category].Push(Section["name"])
			}
		}
		Changes := HotstringsCategoryScopePlan(Inventory, [Category], Value, &Reason)
		if !(Changes is Array)
			throw ValueError("Extension category selection refused: " . Reason)
		Rows := []
		for Change in Changes {
			Path := Change.Has("section")
				? "hotstrings.modules." . Change["group"] . "." . Change["section"]
				: "hotstrings.groups." . Change["group"]
			Rows.Push(ManifestSparseOperation(Path, Change["enabled"]))
		}
		return Rows
	}
	return ConfigScopeCommitOperations("hotstrings", "extension_category_preference", Operations, Options)
}

_HotstringExtensions_CurrentRoots() {
	global _ConfigDir, _ExtensionsDir
	return HotstringExtensions_Roots(_ConfigDir, _ExtensionsDir)
}

/**
 * Counts source entries selected by the exact registration plan.
 * @param {Map} Target Desired or effective features.
 * @param {Array} Packs Complete discovered catalogue or an explicit subset.
 * @param {Integer} MasterOn Effective master state.
 * @returns {Integer} Effective source entry count.
 */
HotstringExtensions_Count(Target, Packs, MasterOn) {
	Counts := Map()
	for Pack in Packs {
		for File in Pack.toml_files {
			for Section in File.sections
				Counts[File.category . "." . Section["name"]] := Section["count"]
		}
	}
	Total := 0
	for Request in HotstringExtensions_RegistrationPlan(Target, Packs, MasterOn)
		Total += Counts[Request.category . "." . Request.section]
	return Total
}
