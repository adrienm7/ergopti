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
; 2. Micro-parser: uses the same regex strategy already proven in toml_loader.ahk
;    — no external dependency, handles the specific shape of menu_manifest.json.
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


; =============================
; ===== 1.1) JSON helpers =====
; =============================

; Extracts every quoted string from a JSON array literal such as
; ``["foo", "bar", "baz"]`` and returns an AHK Array.
; Returns an empty Array if the literal cannot be parsed.
_MM_ParseStringArray(ArrayLiteral) {
	Result := []
	Pos := 1
	while RegExMatch(ArrayLiteral, '`"([^`"\\]*(?:\\.[^`"\\]*)*)`"', &M, Pos) {
		Result.Push(M[1])
		Pos := M.Pos + M.Len
	}
	return Result
}

; Extracts the value of a top-level JSON key whose value is an array literal.
; Searches for ``"key": [...]`` in RawJson and returns the bracketed substring.
; Returns "" if the key is not found.
_MM_ExtractArrayLiteral(RawJson, Key) {
	; Match "key": [ ... ] — content may span multiple lines
	Pattern := '`"' . Key . '`"\s*:\s*(\[[^\]]*\])'
	if RegExMatch(RawJson, Pattern, &M)
		return M[1]
	return ""
}

; Looks up Key inside a JSON object literal (the value of ``hotstring_category_keys``).
; Returns the string value, or "" if not found.
_MM_LookupStringKey(ObjectLiteral, Key) {
	Pattern := '`"' . Key . '`"\s*:\s*`"([^`"\\]*)`"'
	if RegExMatch(ObjectLiteral, Pattern, &M)
		return M[1]
	return ""
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

	; ── Locate the hotstring_category_keys object so we can resolve ids → AHK keys
	CategoryKeysLit := ""
	if RegExMatch(FileContent, '`"hotstring_category_keys`"\s*:\s*(\{[^}]*\})', &CKMatch)
		CategoryKeysLit := CKMatch[1]

	if CategoryKeysLit == "" {
		try LoggerWarn("MenuManifest", "hotstring_category_keys block not found — using fallback lists.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	; ── Locate the hotstring_groups object
	GroupsLit := ""
	if RegExMatch(FileContent, '`"hotstring_groups`"\s*:\s*(\{(?:[^{}]|\{[^{}]*\})*\})', &GMatch)
		GroupsLit := GMatch[1]

	if GroupsLit == "" {
		try LoggerWarn("MenuManifest", "hotstring_groups block not found — using fallback lists.")
		return _MM_BuildResult(_MM_FALLBACK_STANDARD, _MM_FALLBACK_ERGOPTI, _MM_FALLBACK_DYNAMIC)
	}

	; ── Parse each group's id array and resolve to AHK keys
	StandardAhk := _MM_ResolveGroup(GroupsLit, CategoryKeysLit, "standard", _MM_FALLBACK_STANDARD)
	ErgoptiAhk  := _MM_ResolveGroup(GroupsLit, CategoryKeysLit, "ergopti",  _MM_FALLBACK_ERGOPTI)
	DynamicAhk  := _MM_ResolveGroup(GroupsLit, CategoryKeysLit, "dynamic",  _MM_FALLBACK_DYNAMIC)

	try LoggerDone("MenuManifest", "Hotstring groups loaded (%d std, %d ergopti, %d dynamic).",
		StandardAhk.Length, ErgoptiAhk.Length, DynamicAhk.Length)

	return _MM_BuildResult(StandardAhk, ErgoptiAhk, DynamicAhk)
}

; Resolves one named group from the hotstring_groups block.
; Reads its id array, maps each id through hotstring_category_keys, and
; returns the resulting AHK-key array.  Falls back to Fallback on failure.
_MM_ResolveGroup(GroupsLit, CategoryKeysLit, GroupName, Fallback) {
	ArrayLit := _MM_ExtractArrayLiteral(GroupsLit, GroupName)
	if ArrayLit == ""
		return Fallback

	Ids  := _MM_ParseStringArray(ArrayLit)
	Keys := []
	for Id in Ids {
		AhkKey := _MM_LookupStringKey(CategoryKeysLit, Id)
		if AhkKey != ""
			Keys.Push(AhkKey)
		else
			try LoggerWarn("MenuManifest", "No AHK key mapping for id '{1}' in group '{2}'.", Id, GroupName)
	}

	if Keys.Length == 0
		return Fallback

	return Keys
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
