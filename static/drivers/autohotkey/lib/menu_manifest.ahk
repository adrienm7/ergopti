; lib/menu_manifest.ahk





; =======================================
; =======================================
; ======= 1/ Menu Manifest Loader =======
; =======================================
; =======================================
;
; MODULE: Menu Manifest Loader
; DESCRIPTION:
; Reads ``static/menu_manifest.json`` at boot and exposes the hotstring group
; arrays so the rest of the driver never hard-codes category lists.
;
; FEATURES & RATIONALE:
; 1. Single Source of Truth: the manifest is shared with the SvelteKit front-end,
;    so adding a new hotstring category only requires editing one JSON file.
; 2. Canonical Parser: delegates all JSON parsing to lib/json.ahk (JsonParse),
;    eliminating the former regex micro-parser and ensuring correctness on any
;    valid manifest shape.
; 3. Safe Fallback: if the file is missing or unparseable, the function returns
;    the hard-coded lists that were in place before this refactor, guaranteeing
;    zero regression at runtime.
; ==============================================================================

; Hard-coded fallback values — kept here as the single recovery point if the
; manifest file cannot be read; they mirror the former global declarations in
; ui/tray_menu.ahk
global _MM_FALLBACK_STANDARD  := ["DistancesReduction", "Autocorrection", "MagicKey"]
global _MM_FALLBACK_ERGOPTI   := ["SFBsReduction", "Rolls"]
global _MM_FALLBACK_DYNAMIC   := ["DynamicHotstrings"]



; ========================================
; ===== 1.1) JSON navigation helpers =====
; ========================================

; Returns the value at Key inside a parsed JSON Map, or Default if absent.
; Safe against nil maps and non-Map values.
_MM_MapGet(Obj, Key, Default := "") {
	if !(Obj is Map)
		return Default
	return Obj.Has(Key) ? Obj[Key] : Default
}

; Resolves an array of category id strings through the category-keys Map and
; returns the corresponding array of AHK feature keys.
; Falls back to Fallback if the array is missing or resolves to nothing.
_MM_ResolveIdArray(IdsArr, CategoryKeysMap, GroupName, Fallback) {
	if !(IdsArr is Array) || IdsArr.Length == 0
		return Fallback

	Keys := []
	for Id in IdsArr {
		if !(Id is String)
			continue
		AhkKey := _MM_MapGet(CategoryKeysMap, Id)
		if AhkKey != ""
			Keys.Push(AhkKey)
		else
			try LoggerWarn("MenuManifest", "No AHK key mapping for id '{1}' in group '{2}'.", Id, GroupName)
	}

	return Keys.Length > 0 ? Keys : Fallback
}



; ==============================
; ===== 1.2) Public loader =====
; ==============================

; Loads ``static/menu_manifest.json`` and converts the hotstring group id lists
; into arrays of AHK Features keys using ``hotstring_category_keys``.
;
; Returns an object with three properties:
;   .standard  — AHK keys for layout-agnostic categories
;   .ergopti   — AHK keys for Ergopti-specific categories
;   .dynamic   — AHK keys for dynamic-hotstring categories
;   .all       — standard + ergopti + dynamic (full set used by IsCategoryAllEnabled)
;
; On any read or parse failure the fallback hard-coded arrays are returned.
MenuManifest_LoadHotstringGroups() {
	global _StaticDir
	global _MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC

	FilePath := _StaticDir . "\menu_manifest.json"

	; Guard: file must exist before we attempt to read it
	if !FileExist(FilePath) {
		try LoggerWarn("MenuManifest", "manifest not found at '{1}' — using fallback lists.", FilePath)
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	try LoggerTrace("MenuManifest", "Loading hotstring groups from '{1}'…", FilePath)

	FileContent := ""
	try FileContent := FileRead(FilePath, "UTF-8")
	if FileContent == "" {
		try LoggerWarn("MenuManifest", "manifest is empty — using fallback lists.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	; ── Parse the whole manifest via the canonical JSON parser
	; Variables inside a function are local by default in AHK v2 — no keyword needed
	Root := ""
	try Root := JsonParse(FileContent)
	if !(Root is Map) {
		try LoggerWarn("MenuManifest", "manifest root is not a JSON object — using fallback lists.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	; ── Extract the two sub-objects we need
	CategoryKeysMap := _MM_MapGet(Root, "hotstring_category_keys")
	if !(CategoryKeysMap is Map) {
		try LoggerWarn("MenuManifest", "hotstring_category_keys block not found — using fallback lists.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	GroupsMap := _MM_MapGet(Root, "hotstring_groups")
	if !(GroupsMap is Map) {
		try LoggerWarn("MenuManifest", "hotstring_groups block not found — using fallback lists.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	; ── Resolve each group's id array to AHK feature keys
	StandardAhk := _MM_ResolveIdArray(_MM_MapGet(GroupsMap, "standard"), CategoryKeysMap, "standard", _MM_FALLBACK_STANDARD)
	ErgoptiAhk  := _MM_ResolveIdArray(_MM_MapGet(GroupsMap, "ergopti"),  CategoryKeysMap, "ergopti",  _MM_FALLBACK_ERGOPTI)
	DynamicAhk  := _MM_ResolveIdArray(_MM_MapGet(GroupsMap, "dynamic"),  CategoryKeysMap, "dynamic",  _MM_FALLBACK_DYNAMIC)

	try LoggerDone("MenuManifest", "Hotstring groups loaded (%d std, %d ergopti, %d dynamic).",
		StandardAhk.Length, ErgoptiAhk.Length, DynamicAhk.Length)

	return _MM_BuildResult(StandardAhk, ErgoptiAhk, DynamicAhk)
}

; Assembles the final result object from the three resolved arrays.
_MM_BuildResult(Standard, Ergopti, Dynamic) {
	All := []
	for v in Standard
		All.Push(v)
	for v in Ergopti
		All.Push(v)
	for v in Dynamic
		All.Push(v)

	return {
		standard: Standard,
		ergopti:  Ergopti,
		dynamic:  Dynamic,
		all:      All
	}
}
