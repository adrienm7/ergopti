; infra/hotstrings/extension_packs.ahk

; ==============================================================================
; MODULE: Existing Extension Pack Discovery
; DESCRIPTION:
; Discovers bundled, committed layout and user packs in overlay order. Desired
; group and section choices stay in the existing feature map; registration uses
; a separate plan so disabling the master never rewrites those choices.
; ==============================================================================

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
