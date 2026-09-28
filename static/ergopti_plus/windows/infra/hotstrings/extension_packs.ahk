; infra/hotstrings/extension_packs.ahk

; ==============================================================================
; MODULE: Existing Extension Pack Discovery
; DESCRIPTION:
; Discovers bundled, committed layout and user packs in overlay order. Desired
; group and section choices stay in the existing feature map; registration uses
; a separate plan so disabling the master never rewrites those choices.
; ==============================================================================

global _HotstringExtensionPacks := []
global _HotstringExtensionPaths := Map()

/**
 * Reads the existing roots in bundled, installed, then user precedence order.
 * @param {String} ConfigDir Configuration directory.
 * @param {String} BundledRoot Shipped extension root.
 * @returns {Array} Discovery roots.
 */
HotstringExtensions_Roots(ConfigDir, BundledRoot) {
	Roots := [BundledRoot]
	for Root in LayoutExtension_Roots(LayoutRegistry_LocalDir(ConfigDir))
		Roots.Push(Root)
	Roots.Push(RTrim(ConfigDir, "\/") . "\extensions")
	return Roots
}

/**
 * Seeds discovered leaves before the boot config loader resolves user choices.
 * @param {Map} Target Desired features before configuration projection.
 * @param {Array} Roots Ordered extension roots.
 * @returns {Array} Complete discovered packs.
 */
HotstringExtensions_Prepare(Target, Roots) {
	Packs := HotstringExtensions_Scan(Roots)
	HotstringExtensions_Seed(Target, Packs, ManifestDefaultFor)
	return Packs
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
 * @returns {Array} Packs with canonical category identities and section metadata.
 */
HotstringExtensions_Scan(Roots) {
	ById := Map()
	for Root in Roots {
		for PackDir in FSListDirectoryStrict(Root, true) {
			SplitPath PackDir, &Id
			Manifest := ParseTomlFile(PackDir . "\manifest.toml")
			if TOML_UnreadableFile(PackDir . "\manifest.toml")
				throw Error("Extension manifest read did not commit.")
			Name := Manifest.Has("extension") ? Manifest["extension"].Get("name", Id) : Id
			if !(Name is String)
				throw TypeError("Extension name must be a string.")
			Files := []
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
				Files.Push({ path: FilePath, stem: Stem, category: Category, sections: Sections, count: Total })
			}
			ById[Id] := { id: Id, name: Name, dir: PackDir, toml_files: Files }
		}
	}
	Packs := []
	for Id, Pack in ById
		Packs.Push(Pack)
	return Packs
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
