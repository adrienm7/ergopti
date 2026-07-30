; tests/meta/test_gestures_bulk_actions_ahk_reachable.ahk

; ==============================================================================
; MODULE: Gestures Bulk Actions Reachability Meta Test
; DESCRIPTION:
; Regression guard for gestures-bulk-actions-unreachable-on-ahk.
;
; MenuRenderer_Build evaluates the platform filter FIRST and `continue`s before
; the action-handler dispatch. So a gestures_menu entry tagged platforms:["hs"]
; is dropped even when BuildGesturesMenu registered a fully implemented Windows
; handler for its id -- the row simply never appears and the action is
; unreachable, with no error and no log.
;
; That is exactly what happened to « Tout desactiver » and « Restaurer les
; valeurs par defaut »: _GES_DisableAll / _GES_RestoreDefaults and their workers
; _GES_SetEverySlot / _GES_RestoreFactoryDefaults are implemented against the
; Windows GESTURE_SLOTS and GESTURE_FACTORY_DEFAULTS, they ship on macOS, and the
; shared manifest said "hs" only.
;
; ROOT CAUSE ENCODED: manifest/driver drift. The class of ids is DERIVED from
; BuildGesturesMenu itself, and handlers that are deliberate no-op placeholders
; for macOS-only rows (the finger-group slots) are detected as stubs and skipped
; rather than named in a list, so a newly implemented gesture action joins the
; check automatically.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 1/ Shared-manifest helpers =======
; ==========================================
; ==========================================

; The platform filter is reimplemented here rather than imported: lib/manifest_menu.ahk
; is not part of the headless harness. This is not a tautology -- the assertions
; below run it against the REAL shared menu_manifest.json, so the data under test
; is production data, not a fixture built by this file.
_GBA_ManifestPath() {
	SplitPath(A_ScriptDir, , &WinDir)
	SplitPath(WinDir, , &EpDir)
	return EpDir . "\_shared\modules\menu\menu_manifest.json"
}

_GBA_IsForPlatform(Entry, Platform) {
	if !(Entry is Map) or !Entry.Has("platforms")
		return true
	Plats := Entry["platforms"]
	if !(Plats is Array)
		return true
	for _, P in Plats {
		if (P == Platform)
			return true
	}
	return false
}

_GBA_FindItemById(Items, Id) {
	for _, It in Items {
		if (It is Map) and It.Has("id") and (It["id"] == Id)
			return It
	}
	return false
}

; Maps every dynamic/action id BuildGesturesMenu registers to the handler
; function it registers for it, straight from the driver source.
_GBA_HandlerMap() {
	Body := _DriverFuncBody("BuildGesturesMenu")
	Handlers := Map()
	Pos := 1
	while (Found := RegExMatch(Body, '"([a-z0-9_]+)"\s*,\s*\(M,\s*C\)\s*=>\s*(_GES_\w+)\(', &M, Pos)) {
		Handlers[M[1]] := M[2]
		Pos := Found + StrLen(M[0])
	}
	return Handlers
}

; True when a handler body is an intentional placeholder (empty, or a bare
; `return`). Those exist for the macOS finger-group rows the AHK platform filter
; is SUPPOSED to drop, so they must not be treated as drift.
_GBA_IsStubHandler(FuncName) {
	Body := _DriverFuncBody(FuncName)
	if (Body == "")
		return true
	Nl := InStr(Body, "`n")
	Inner := (Nl > 0) ? SubStr(Body, Nl + 1) : ""
	Inner := RegExReplace(Inner, "\}\s*$", "")
	Inner := Trim(RegExReplace(Inner, "\s+", " "))
	return (Inner == "" or Inner == "return")
}





; =====================================================================
; =====================================================================
; ======= 2/ An implemented handler implies an ahk-visible row ========
; =====================================================================
; =====================================================================

_GBA_ImplementedActionsAreVisibleOnAhk() {
	Raw := ""
	try Raw := FileRead(_GBA_ManifestPath(), "UTF-8")
	Assert(Raw != "", "menu_manifest.json must be readable at " . _GBA_ManifestPath())

	Root := ""
	try Root := JsonParse(Raw)
	Assert(Root is Map and Root.Has("gestures_menu"),
		"menu_manifest.json must declare a gestures_menu array")
	Items := Root["gestures_menu"]
	Assert(Items is Array and Items.Length > 0, "gestures_menu must be a non-empty array")

	Handlers := _GBA_HandlerMap()
	Assert(Handlers.Count >= 5,
		"the handler class must be derived from BuildGesturesMenu and hold its registered ids -- an "
		. "empty class would make this test vacuous (found " . Handlers.Count . ")")

	Checked := 0
	for Id, FuncName in Handlers {
		if _GBA_IsStubHandler(FuncName)
			continue
		Entry := _GBA_FindItemById(Items, Id)
		if (Entry == false)
			continue
		Checked += 1
		Assert(_GBA_IsForPlatform(Entry, "ahk"),
			"menu_manifest.json gestures_menu '" . Id . "' must be visible on the ahk platform: "
			. "BuildGesturesMenu registers " . FuncName . " for it and that handler is fully "
			. "implemented on Windows. MenuRenderer_Build applies the platform filter BEFORE the "
			. "action dispatch, so an hs-only tag makes the action silently unreachable "
			. "(gestures-bulk-actions-unreachable-on-ahk)")
	}
	Assert(Checked >= 4,
		"at least the implemented gesture actions (auto-configure, manual tutorial, disable all, "
		. "restore defaults, the AHK slot list) must have been checked -- got " . Checked)
}
Test("gestures: every implemented gesture action is reachable on Windows (gestures-bulk-actions-unreachable-on-ahk)",
	_GBA_ImplementedActionsAreVisibleOnAhk)





; ==================================================================
; ==================================================================
; ======= 3/ The drift itself is reported, not swallowed ===========
; ==================================================================
; ==================================================================

; A handler supplied for an entry the filter drops is always drift. The renderer
; used to skip it in total silence, which is how this one survived so long.
_GBA_RendererLogsPlatformFilteredHandlers() {
	Body := _DriverFuncBody("MenuRenderer_Build")
	Assert(Body != "", "MenuRenderer_Build must exist in the driver source")

	FilterPos := InStr(Body, "if !_MR_IsForAhk(Item)")
	Assert(FilterPos > 0, "MenuRenderer_Build must still apply the platform filter")

	Seg := SubStr(Body, FilterPos, 700)
	Assert(InStr(Seg, "DynamicHandlers.Has(") > 0 and InStr(Seg, "LoggerDebug(") > 0,
		"MenuRenderer_Build must report an entry it platform-filters away while the caller supplied a "
		. "handler for it -- that asymmetry is always manifest/driver drift, and a silent skip is "
		. "what made the unreachable gesture actions invisible (gestures-bulk-actions-unreachable-on-ahk)")
}
Test("gestures: the renderer reports a handler whose manifest row it filters away (gestures-bulk-actions-unreachable-on-ahk)",
	_GBA_RendererLogsPlatformFilteredHandlers)
