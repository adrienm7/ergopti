; lib/menu_manifest.ahk
;
; ==============================================================================
; MODULE: Menu Manifest Loader
; DESCRIPTION:
; Reads ``static/ergopti_plus/_shared/menu_manifest.json`` at boot and exposes
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
global _MM_TOP_LEVEL_TAIL_CACHE   := false
global _MM_GLOBAL_ACTIONS_CACHE   := false

; The PARSED manifest root, cached for the process lifetime and deliberately NOT
; cleared by MenuManifest_InvalidateCache(). The three tail loaders below each
; used to FileRead + JsonParse the same 12.7 KB file, and initMenu() invalidates
; their derived caches on every tray rebuild, so a single tray toggle paid three
; cold decodes — benched at 36-42 ms each, ~110 ms per rebuild, and it shows up
; in the boot profile as "tail (global_actions…debug): +78 ms". Keeping the root
; warm is safe because the derived structures carry only ids and platform
; filters (no localised text, no runtime state) and the manifest ships inside
; the driver bundle, so it cannot change while the process runs.
global _MM_MANIFEST_ROOT_CACHE := false



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

; Returns the parsed manifest root, reading and decoding the file at most once
; per process. Returns false — never a partial object — when the manifest cannot
; be read or is not a JSON object, so every caller keeps its own hard-coded
; fallback. A failure is deliberately not cached: a transient I/O error must not
; pin the fallback lists for the rest of the session.
_MM_GetManifestRoot() {
	global _SharedDir, _MM_MANIFEST_ROOT_CACHE

	if (_MM_MANIFEST_ROOT_CACHE != false)
		return _MM_MANIFEST_ROOT_CACHE

	FilePath := _SharedDir . "\modules\menu\menu_manifest.json"
	if !FileExist(FilePath) {
		try LoggerWarn("MenuManifest", "manifest not found at '{1}' — callers fall back to their hard-coded lists.", FilePath)
		return false
	}

	FileContent := ""
	try FileContent := FileRead(FilePath, "UTF-8")
	if FileContent == "" {
		try LoggerWarn("MenuManifest", "manifest at '{1}' is empty — callers fall back to their hard-coded lists.", FilePath)
		return false
	}

	Root := ""
	try Root := JsonParse(FileContent)
	if !(Root is Map) {
		try LoggerWarn("MenuManifest", "manifest root is not a JSON object — callers fall back to their hard-coded lists.")
		return false
	}

	_MM_MANIFEST_ROOT_CACHE := Root
	return Root
}

; Invalidates all manifest-driven caches.
MenuManifest_InvalidateCache() {
	global _MM_HOTSTRING_GROUPS_CACHE, _MM_DEBUG_MENU_CACHE
	global _MM_TOP_LEVEL_TAIL_CACHE, _MM_GLOBAL_ACTIONS_CACHE
	_MM_HOTSTRING_GROUPS_CACHE := false
	_MM_DEBUG_MENU_CACHE       := false
	_MM_TOP_LEVEL_TAIL_CACHE   := false
	_MM_GLOBAL_ACTIONS_CACHE   := false
}

; Loads ``static/ergopti_plus/_shared/menu_manifest.json`` and converts the hotstring group id lists
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

	FilePath := _SharedDir . "\modules\menu\menu_manifest.json"

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
		try LoggerDone("MenuManifest", "Hotstring groups fallback: manifest is empty.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	; ── Parse the whole manifest via the canonical JSON parser
	; Variables inside a function are local by default in AHK v2 — no keyword needed
	Root := ""
	try Root := JsonParse(FileContent)
	if !(Root is Map) {
		try LoggerWarn("MenuManifest", "manifest root is not a JSON object — using fallback lists.")
		try LoggerDone("MenuManifest", "Hotstring groups fallback: manifest root is invalid.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	; ── Extract the two sub-objects we need
	CategoryKeysMap := _MM_MapGet(Root, "hotstring_category_keys")
	if !(CategoryKeysMap is Map) {
		try LoggerWarn("MenuManifest", "hotstring_category_keys block not found — using fallback lists.")
		try LoggerDone("MenuManifest", "Hotstring groups fallback: category-key block is missing.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	GroupsMap := _MM_MapGet(Root, "hotstring_groups")
	if !(GroupsMap is Map) {
		try LoggerWarn("MenuManifest", "hotstring_groups block not found — using fallback lists.")
		try LoggerDone("MenuManifest", "Hotstring groups fallback: group block is missing.")
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
	global _MM_DEBUG_MENU_CACHE

	if (_MM_DEBUG_MENU_CACHE != false)
		return _MM_DEBUG_MENU_CACHE

	Root := _MM_GetManifestRoot()
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




; ======================================================
; ======================================================
; ======= 3/ Top-Level Tail Loader (MENU-1) ============
; ======================================================
; ======================================================

; Loads the tail slice of the ``top_level`` array from the shared manifest —
; starting at the "global_actions" entry — and returns it as an Array of Maps,
; filtered for the AHK platform.  Used by _MI_AppendTail() to drive the
; lower-menu assembly in manifest order rather than imperative order.
MenuManifest_LoadTopLevelTail() {
	global _MM_TOP_LEVEL_TAIL_CACHE

	if (_MM_TOP_LEVEL_TAIL_CACHE != false)
		return _MM_TOP_LEVEL_TAIL_CACHE

	Root := _MM_GetManifestRoot()
	if !(Root is Map)
		return _MM_TopLevelTailFallback()

	RawItems := _MM_MapGet(Root, "top_level")
	if !(RawItems is Array) || RawItems.Length == 0
		return _MM_TopLevelTailFallback()

	; Find the index of the first "global_actions" entry — that is where the tail starts
	TailStart := 0
	for Idx, Entry in RawItems {
		if !(Entry is Map)
			continue
		if _MM_MapGet(Entry, "id") == "global_actions" {
			TailStart := Idx
			break
		}
	}
	if TailStart == 0 {
		try LoggerWarn("MenuManifest", "top_level has no 'global_actions' entry — using fallback tail.")
		return _MM_TopLevelTailFallback()
	}

	; Pull in the separator that visually closes the feature-toggle head section
	; (Gestures on AHK) when the manifest declares one immediately before
	; global_actions — otherwise the tray menu shows no divider there even
	; though menu_manifest.json's top_level array puts one in that exact spot.
	if (TailStart > 1) {
		PrevEntry := RawItems[TailStart - 1]
		if (PrevEntry is Map) and (_MM_MapGet(PrevEntry, "id") == "---") {
			TailStart := TailStart - 1
		}
	}

	Result := []
	Loop RawItems.Length - TailStart + 1 {
		Entry := RawItems[TailStart + A_Index - 1]
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

	try LoggerDone("MenuManifest", "Top-level tail loaded ({1} item(s)).", Result.Length)
	_MM_TOP_LEVEL_TAIL_CACHE := Result.Length > 0 ? Result : _MM_TopLevelTailFallback()
	return _MM_TOP_LEVEL_TAIL_CACHE
}

; Hard-coded fallback — mirrors the canonical AHK tail defined in menu_manifest.json.
_MM_TopLevelTailFallback() {
	return [
		Map("id", "---"),
		Map("id", "global_actions"),
		Map("id", "language"),
		Map("id", "config_folder"),
		Map("id", "setup_wizard"),
		Map("id", "about"),
		Map("id", "---"),
		Map("id", "suspend"),
		Map("id", "reload"),
		Map("id", "quit"),
		Map("id", "debug"),
	]
}




; ==================================================
; ==================================================
; ======= 4/ Global Actions Loader (MENU-2) ========
; ==================================================
; ==================================================

; Loads the ``global_actions`` array from the shared manifest (items for the
; "Actions globales" submenu), filtered for the AHK platform.  Returned as
; an Array of Maps with "id".  Used by _MI_BuildGlobalActionsMenu().
MenuManifest_LoadGlobalActions() {
	global _MM_GLOBAL_ACTIONS_CACHE

	if (_MM_GLOBAL_ACTIONS_CACHE != false)
		return _MM_GLOBAL_ACTIONS_CACHE

	Root := _MM_GetManifestRoot()
	if !(Root is Map)
		return _MM_GlobalActionsFallback()

	RawItems := _MM_MapGet(Root, "global_actions")
	if !(RawItems is Array) || RawItems.Length == 0
		return _MM_GlobalActionsFallback()

	Result := []
	for Entry in RawItems {
		if !(Entry is Map)
			continue
		Id := _MM_MapGet(Entry, "id")
		if Id == ""
			continue
		; Filter by platform
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

	try LoggerDone("MenuManifest", "Global actions loaded ({1} item(s)).", Result.Length)
	_MM_GLOBAL_ACTIONS_CACHE := Result.Length > 0 ? Result : _MM_GlobalActionsFallback()
	return _MM_GLOBAL_ACTIONS_CACHE
}

; Hard-coded fallback — mirrors the canonical content of menu_manifest.json global_actions.
_MM_GlobalActionsFallback() {
	return [
		Map("id", "enable_all"),
		Map("id", "disable_all"),
		Map("id", "reset_defaults"),
	]
}
