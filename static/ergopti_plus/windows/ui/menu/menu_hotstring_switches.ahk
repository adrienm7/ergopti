; ui/menu/menu_hotstring_switches.ahk

; ==============================================================================
; MODULE: Hotstring Scope Menu Bindings
; DESCRIPTION:
; Standard category submenus bind the shared explicit commands to the atomic
; category owner. Language and whole-tree section controls retain their separate
; checkbox contract. Native providers supply source files and section data;
; the shared declaration and renderer own category row labels and ordering.
; ==============================================================================





; ========================================
; ========================================
; ======= 1/ What « all on » means =======
; ========================================
; ========================================

; The v2 feature paths the manifest declares under one hotstring section: the
; set its batched « all sections » writers switch.
_HS_SectionPaths(V2Section) {
	Paths := []
	for _, Entry in ManifestFeaturesForSection(V2Section)
		Paths.Push(Entry["path"])
	return Paths
}

; True when every path is enabled. An empty list is not « all on »: there is
; nothing the checkbox could have switched on.
_HS_PathsAllEnabled(Paths) {
	if (Paths.Length == 0)
		return false
	for _, V2Path in Paths {
		State := ReadFeatureStateV2(V2Path)
		if !(State.Has("enabled") and State["enabled"])
			return false
	}
	return true
}

; Section selection remains independent of the scope's runtime master.
_HS_ScopeAllOn(Gates, Paths) {
	if (Gates.Length == 0)
		return false
	return _HS_PathsAllEnabled(Paths)
}





; ===========================
; ===========================
; ======= 2/ The rows =======
; ===========================
; ===========================

/**
 * Builds the declared file command through its existing native opening owner.
 * @param {String} TomlPath Captured category source.
 * @param {Func|Integer} OpenFn Native opening callback, or 0 for Run.
 * @returns {Map} Shared command provider data.
 */
_HS_CategoryFileRow(TomlPath, OpenFn := 0) {
	if OpenFn is Integer && OpenFn == 0
		OpenFn := _MakeOpenFileFn(TomlPath)
	if !HasMethod(OpenFn, "Call")
		return false
	return MenuRenderer_CommandRow("hotstring_file_commands", "hotstring_file_open",
		Map("hotstring_file_open", OpenFn),
		Map("hotstring_file_ready", (*) => FileExist(TomlPath) != ""))
}

; The « all sections » checkbox of one scope. A click switches everything to the
; other side through ``Apply(Bool)``, the scope's batched writer. Every write
; rebuilds the tray, so the state captured here is the one the click acts on.
_HS_AllSectionsRow(AllOn, Apply) {
	return Map(
		"label",   t("menu.hotstrings.enable_all_sections"),
		"checked", AllOn ? true : false,
		"action",  (*) => Apply(!AllOn))
}

/**
 * Builds one category through the shared command and provider declaration.
 * @param {String} V1Cat Native category id.
 * @param {String} TomlPath The category's resolved bundled source.
 * @param {Array} Sections Native section rows, in source order.
 * @param {Func} Apply The journal-backed category transaction.
 * @param {Menu} TargetMenu Optional empty native menu held by repaint callbacks.
 * @returns {Menu} The rendered category submenu.
 */
_HS_CategoryMenu(V1Cat, TomlPath, Sections, Apply := HotstringsCategoryScopeApply, TargetMenu := unset) {
	Commands := Map(
		"hotstring_category_enable_all", (*) => Apply([V1Cat], true),
		"hotstring_category_disable_all", (*) => Apply([V1Cat], false))
	Providers := Map(
		"hotstring_category_file", (*) => FileExist(TomlPath)
			? [_HS_CategoryFileRow(TomlPath)] : [],
		"hotstring_category_sections", (*) => Sections)
	return MenuRenderer_Build("hotstring_category_menu", "Hotstrings", "", "", Providers, Commands, "",
		IsSet(TargetMenu) ? TargetMenu : unset)
}

; The « all sections » checkbox that opens a language submenu, for every section
; of every category of the pack — the scope ToggleLanguageAllSections switches.
_HS_LanguageSwitchRow(Pack) {
	Gates := []
	Paths := []
	for _, Cat in Pack["categories"] {
		Gates.Push(Cat["v1"])
		for _, V2Path in _HS_SectionPaths("hotstrings." . Cat["v2"])
			Paths.Push(V2Path)
	}
	return _HS_AllSectionsRow(_HS_ScopeAllOn(Gates, Paths),
		((p) => (Bool) => ToggleLanguageAllSections(p, Bool))(Pack))
}
