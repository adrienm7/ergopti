; ui/menu/menu_hotstring_switches.ahk

; ==============================================================================
; MODULE: Hotstring Gate And « All Sections » Checkboxes
; DESCRIPTION:
; The two switches every hotstring scope offers: the category gate, and one
; « all sections » checkbox where a « tout activer » / « tout désactiver » pair
; used to be — two rows and two keys for one control, whose state the user could
; only guess. Both are checkboxes with one label, ticked from the state they
; govern. Row data only: the renderer draws them, and the batched writers in
; infra/config_io.ahk do the work. Kept apart from the submenu builders so the
; unit harness can build these rows over the live Features and gates.
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

; True when every gate of the scope is open and every one of its paths is on —
; what a scope's « all sections » checkbox shows.
_HS_ScopeAllOn(Gates, Paths) {
	if (Gates.Length == 0)
		return false
	for _, Gate in Gates {
		if !IsCategoryGated(Gate)
			return false
	}
	return _HS_PathsAllEnabled(Paths)
}





; ===========================
; ===========================
; ======= 2/ The rows =======
; ===========================
; ===========================

; The « all sections » checkbox of one scope. A click switches everything to the
; other side through ``Apply(Bool)``, the scope's batched writer. Every write
; rebuilds the tray, so the state captured here is the one the click acts on.
_HS_AllSectionsRow(AllOn, Apply) {
	return Map(
		"label",   t("menu.hotstrings.enable_all_sections"),
		"checked", AllOn ? true : false,
		"action",  (*) => Apply(!AllOn))
}

; The rows every hotstring category submenu opens with. THE ORDER BELOW IS THE
; SHARED ONE, and the three drivers had three of them until 2026-08-07: this
; driver put the bulk actions above « ouvrir le fichier », Linux put them below
; it, and macOS had no category gate row at all.
;
;   1. the category gate — everything under it is inert while it is off
;   2. « ouvrir le fichier », when the category has one
;   3. ─────────
;   4. the « all sections » checkbox
;   5. ─────────
;
; The gate alternated « ✅ Activée (cliquer pour désactiver) » and « ❌ Désactivée
; (cliquer pour activer) ». Its state also drives the parent menu checkmark
; (IsCategoryGated), independent of how many sections are checked. V1Cat is
; captured by value so each closure acts on its own category.
_HS_CategoryHeadRows(V1Cat, V2Section, TomlPath) {
	Rows := []
	Rows.Push(Map(
		"label",   t("menu.hotstrings.category_enable"),
		"checked", IsCategoryGated(V1Cat) ? true : false,
		"action",  ((c) => (*) => ToggleCategoryAllFeatures(c, !IsCategoryGated(c)))(V1Cat)))
	if FileExist(TomlPath)
		Rows.Push(Map("label", t("menu.hotstrings.open_file"), "action", _MakeOpenFileFn(TomlPath)))
	Rows.Push(Map("separator", true))
	Rows.Push(_HS_AllSectionsRow(_HS_ScopeAllOn([V1Cat], _HS_SectionPaths(V2Section)),
		((c) => (Bool) => ToggleCategoryAllSections(c, Bool))(V1Cat)))
	Rows.Push(Map("separator", true))
	return Rows
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
