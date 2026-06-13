; lib/menu_manifest.ahk
;
; ==============================================================================
; MODULE: Menu Manifest Loader
; DESCRIPTION:
; Reads ``static/ergopti_plus/shared/menu_manifest.json`` at boot and exposes
; ordered menu structures so the rest of the driver never hard-codes menu layout.
;
; FEATURES & RATIONALE:
; 1. Single Source of Truth: the manifest is shared with the Hammerspoon driver
;    and the SvelteKit front-end — changing menu order requires editing one file.
; 2. Canonical Parser: delegates all JSON parsing to lib/json.ahk (JsonParse).
; 3. Safe Fallback: returns hard-coded lists on any read or parse failure.
; ==============================================================================





; =============================================
; =============================================
; ======= 1/ Hotstring Groups Loader ==========
; =============================================
; =============================================

; Hard-coded fallback values — kept here as the single recovery point if the
; manifest file cannot be read; they mirror the former global declarations in
; ui/tray_menu.ahk
global _MM_FALLBACK_STANDARD  := ["DistancesReduction", "Autocorrection", "MagicKey"]
global _MM_FALLBACK_ERGOPTI   := ["SFBsReduction", "Rolls"]
global _MM_FALLBACK_DYNAMIC   := ["DynamicHotstrings"]

; Cached objects to avoid redundant disk I/O and JSON parsing
global _MM_HOTSTRING_GROUPS_CACHE := false
global _MM_DEBUG_MENU_CACHE       := false



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

; Invalidates all manifest-driven caches.
MenuManifest_InvalidateCache() {
	global _MM_HOTSTRING_GROUPS_CACHE, _MM_DEBUG_MENU_CACHE
	_MM_HOTSTRING_GROUPS_CACHE := false
	_MM_DEBUG_MENU_CACHE       := false
}

; Loads ``static/ergopti_plus/shared/menu_manifest.json`` and converts the hotstring group id lists
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
	global _SharedDir, _MM_HOTSTRING_GROUPS_CACHE
	global _MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC

	if (_MM_HOTSTRING_GROUPS_CACHE != false)
		return _MM_HOTSTRING_GROUPS_CACHE

	FilePath := _SharedDir . "\menu_manifest.json"

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

	try LoggerDone("MenuManifest", "Hotstring groups loaded ({1} std, {2} ergopti, {3} dynamic).",
		StandardAhk.Length, ErgoptiAhk.Length, DynamicAhk.Length)

	_MM_HOTSTRING_GROUPS_CACHE := _MM_BuildResult(StandardAhk, ErgoptiAhk, DynamicAhk)
	return _MM_HOTSTRING_GROUPS_CACHE
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




; ============================================
; ============================================
; ======= 2/ Debug Menu Order Loader =========
; ============================================
; ============================================

; Loads the ``debug_menu`` array from the shared manifest and returns it as an
; Array of Maps, each with "id" and optionally "platforms".
; Filters out any entry whose ``platforms`` list exists and does not include "ahk".
; Returns a hard-coded fallback array on any read or parse failure.
MenuManifest_LoadDebugMenu() {
	global _SharedDir, _MM_DEBUG_MENU_CACHE

	if (_MM_DEBUG_MENU_CACHE != false)
		return _MM_DEBUG_MENU_CACHE

	FilePath := _SharedDir . "\menu_manifest.json"

	if !FileExist(FilePath) {
		try LoggerWarn("MenuManifest", "manifest not found — using fallback debug menu order.")
		return _MM_DebugFallback()
	}

	FileContent := ""
	try FileContent := FileRead(FilePath, "UTF-8")
	if FileContent == ""
		return _MM_DebugFallback()

	Root := ""
	try Root := JsonParse(FileContent)
	if !(Root is Map)
		return _MM_DebugFallback()

	RawItems := _MM_MapGet(Root, "debug_menu")
	if !(RawItems is Array) || RawItems.Length == 0
		return _MM_DebugFallback()

	Result := []
	for Entry in RawItems {
		if !(Entry is Map)
			continue
		Id := _MM_MapGet(Entry, "id")
		if Id == ""
			continue

		; Filter by platform: skip entries that explicitly exclude "ahk"
		Platforms := _MM_MapGet(Entry, "platforms", 0)
		if Platforms is Array {
			IsForAhk := false
			for P in Platforms {
				if P == "ahk" {
					IsForAhk := true
					break
				}
			}
			if !IsForAhk
				continue
		}

		Result.Push(Map("id", Id))
	}

	try LoggerDone("MenuManifest", "Debug menu order loaded ({1} item(s)).", Result.Length)
	_MM_DEBUG_MENU_CACHE := Result.Length > 0 ? Result : _MM_DebugFallback()
	return _MM_DEBUG_MENU_CACHE
}

; Hard-coded fallback — mirrors the canonical order defined in menu_manifest.json.
_MM_DebugFallback() {
	return [
		Map("id", "window_spy"),
		Map("id", "list_vars"),
		Map("id", "key_history"),
		Map("id", "---"),
		Map("id", "log_level"),
		Map("id", "open_logs"),
		Map("id", "open_today_log"),
		Map("id", "open_error_log"),
		Map("id", "---"),
		Map("id", "healthcheck"),
	]
}
