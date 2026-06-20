; lib/menu_renderer.ahk

; ==============================================================================
; MODULE: Menu Renderer
; DESCRIPTION:
; Generic manifest-driven menu builder shared by all submenu builders.
; Reads a ``*_menu`` array from ``menu_manifest.json`` and constructs an AHK
; Menu object, dispatching each item type to the appropriate render function.
;
; FEATURES & RATIONALE:
; 1. Single renderer: every submenu (shortcuts, metrics, layout, hotstrings,
;    gestures, tap_holds) is built by the same loop — structure lives in the
;    manifest, not in per-submenu AHK code.
; 2. Dynamic escape hatch: items whose ``type`` is "dynamic" are routed
;    to a caller-supplied Map of handler functions so platform-specific UI
;    (file trees, dialogs, runtime state) stays in the caller.
; 3. Platform filtering: entries with a ``platforms`` array that does not
;    include "ahk" are silently skipped.
; ==============================================================================

; Hard-coded fallback strings when platform JSON is unreadable at boot —
; guards against empty-menu edge case during first-run / manifest missing.
global _MR_MANIFEST_CACHE := false   ; cached parsed root object





; =============================================
; =============================================
; ======= 1/ Manifest Root Access Layer =======
; =============================================
; =============================================

; Returns the parsed manifest root Map, loading and caching it on first call.
; Returns ``false`` on any read / parse failure.
_MR_GetManifestRoot() {
	global _MR_MANIFEST_CACHE, _SharedDir
	if (_MR_MANIFEST_CACHE != false) {
		return _MR_MANIFEST_CACHE
	}
	FilePath := _SharedDir . "\modules\menu\menu_manifest.json"
	if !FileExist(FilePath) {
		try LoggerWarn("MenuRenderer", "manifest not found at '{1}'.", FilePath)
		return false
	}
	FileContent := ""
	try FileContent := FileRead(FilePath, "UTF-8")
	if FileContent == "" {
		try LoggerWarn("MenuRenderer", "manifest is empty.")
		return false
	}
	Root := ""
	try Root := JsonParse(FileContent)
	if !(Root is Map) {
		try LoggerWarn("MenuRenderer", "manifest root is not a JSON object.")
		return false
	}
	_MR_MANIFEST_CACHE := Root
	return Root
}

; Invalidates the manifest cache — call after hot-reload or locale change.
MenuRenderer_InvalidateCache() {
	global _MR_MANIFEST_CACHE
	_MR_MANIFEST_CACHE := false
}

; Returns the array at ``Key`` inside the manifest root, or an empty Array.
_MR_GetMenuDef(Key) {
	Root := _MR_GetManifestRoot()
	if (Root == false) {
		return []
	}
	if !(Root.Has(Key)) {
		try LoggerWarn("MenuRenderer", "menu key '{1}' not found in manifest.", Key)
		return []
	}
	Arr := Root[Key]
	return (Arr is Array) ? Arr : []
}




; ==============================================
; ==============================================
; ======= 2/ Platform Filter Helpers ==========
; ==============================================
; ==============================================

; Returns true when the entry has no ``platforms`` restriction, or when
; "ahk" appears in its ``platforms`` array.
_MR_IsForAhk(Entry) {
	if !(Entry is Map) or !Entry.Has("platforms") {
		return true
	}
	Plats := Entry["platforms"]
	if !(Plats is Array) {
		return true
	}
	for _, P in Plats {
		if P == "ahk" {
			return true
		}
	}
	return false
}

; Safe map-get with a default value.
_MR_Get(Obj, Key, Default := "") {
	if !(Obj is Map) or !Obj.Has(Key) {
		return Default
	}
	return Obj[Key]
}




; ==============================================
; ==============================================
; ======= 3/ Core Renderer ====================
; ==============================================
; ==============================================

; Build an AHK Menu from a manifest menu definition array.
;
; ``ManifestKey``   — key in ``menu_manifest.json`` (e.g. "shortcuts_menu")
; ``CategoryName``  — v1 PascalCase master-gate category (e.g. "Shortcuts")
; ``DynamicHandlers`` — Map of id → Func to call for ``type:"dynamic"`` entries.
;   Each handler receives ``(Menu, CategoryName)`` and populates the menu in place.
; ``GroupBuilders`` — Map of group_id → Func to call for ``type:"group"`` entries.
;   Each builder receives no arguments and returns a Menu object (or ``false``
;   to skip the entry entirely).
;
; Returns the populated Menu object.
MenuRenderer_Build(ManifestKey, CategoryName, DynamicHandlers, GroupBuilders := "") {
	if (GroupBuilders == "") {
		GroupBuilders := Map()
	}

	MenuDef    := _MR_GetMenuDef(ManifestKey)
	Result     := Menu()
	ItemCount  := 0      ; real items added so far
	PendingSep := false  ; separator deferred until next real item

	for Item in MenuDef {
		if !_MR_IsForAhk(Item) {
			continue
		}

		ItemType := _MR_Get(Item, "type", "")

		if ItemType == "---" {
			; Defer separator — only flush when a real item follows.
			PendingSep := true
			continue
		}

		; Flush deferred separator before any real item (never at position 0).
		if PendingSep and ItemCount > 0 {
			Result.Add()
		}
		PendingSep := false

		if ItemType == "toggle" {
			_MR_RenderToggle(Result, Item, CategoryName)
			ItemCount++

		} else if ItemType == "feature" {
			_MR_RenderFeature(Result, Item, CategoryName)
			ItemCount++

		} else if ItemType == "action" {
			Id := _MR_Get(Item, "id")
			if (Id != "" and DynamicHandlers is Map and DynamicHandlers.Has(Id)) {
				(DynamicHandlers[Id])(Result, CategoryName)
				ItemCount++
			}

		} else if ItemType == "section_header" {
			_MR_RenderSectionHeader(Result, Item)
			ItemCount++

		} else if ItemType == "group" {
			_MR_RenderGroup(Result, Item, CategoryName, GroupBuilders)
			ItemCount++

		} else if ItemType == "letter_picker" {
			_MR_RenderLetterPicker(Result, Item, CategoryName)
			ItemCount++

		} else if ItemType == "dynamic" {
			Id := _MR_Get(Item, "id")
			if (Id != "" and DynamicHandlers is Map and DynamicHandlers.Has(Id)) {
				(DynamicHandlers[Id])(Result, CategoryName)
				ItemCount++
			}

		} else {
			try LoggerWarn("MenuRenderer", "Unknown item type '{1}' in '{2}' — skipped.", ItemType, ManifestKey)
		}
	}

	return Result
}




; ============================================
; ============================================
; ======= 4/ Per-Type Render Helpers =========
; ============================================
; ============================================

; Render the category on/off toggle item (always inserted at position 1).
; The caller typically calls ``AddCategoryToggleItem`` directly before calling
; ``MenuRenderer_Build`` so the toggle lands at the top before any manifest
; items; this handler is here as a safety net for menus that embed it inline.
_MR_RenderToggle(ResultMenu, Item, CategoryName) {
	I18nOn  := _MR_Get(Item, "i18n_on")
	I18nOff := _MR_Get(Item, "i18n_off")
	if (I18nOn == "" or I18nOff == "") {
		try LoggerWarn("MenuRenderer", "toggle item missing i18n_on/i18n_off — skipped.")
		return
	}
	IsGated := IsCategoryGated(CategoryName)
	AddCategoryToggleItem(ResultMenu,
		t(I18nOn), t(I18nOff),
		IsGated,
		((Cat, Gated) => (*) => ToggleCategoryAllFeatures(Cat, !Gated))(CategoryName, IsGated))
}

; Render a manifest-path feature toggle.
_MR_RenderFeature(ResultMenu, Item, CategoryName) {
	Path := _MR_Get(Item, "path")
	if (Path == "") {
		; Some feature entries carry only ``id`` — try constructing a plausible path.
		try LoggerWarn("MenuRenderer", "feature item has no path — skipped.")
		return
	}
	Entry := ManifestFindEntryByPath(Path)
	if (Entry == false) {
		try LoggerWarn("MenuRenderer", "feature path '{1}' not in manifest — skipped.", Path)
		return
	}
	MenuAddItemFromManifest(ResultMenu, Entry, CategoryName)
}

; Render a disabled section header label (visual grouping, not clickable).
_MR_RenderSectionHeader(ResultMenu, Item) {
	I18nKey := _MR_Get(Item, "i18n")
	if (I18nKey == "") {
		return
	}
	Label := MenuSectionTitle(t(I18nKey))
	ResultMenu.Add(Label, (*) => "")
	ResultMenu.Disable(Label)
}

; Render a named group submenu.
_MR_RenderGroup(ResultMenu, Item, CategoryName, GroupBuilders) {
	Id    := _MR_Get(Item, "id")
	I18nKey := _MR_Get(Item, "i18n")
	if (Id == "" or I18nKey == "") {
		try LoggerWarn("MenuRenderer", "group item missing id or i18n — skipped.")
		return
	}
	Label := t(I18nKey)

	; Try the caller-supplied builder first.
	if (GroupBuilders is Map and GroupBuilders.Has(Id)) {
		Sub := (GroupBuilders[Id])()
		if (Sub is Menu) {
			ResultMenu.Add(Label, Sub)
		}
		return
	}

	; Built-in group: modifier_combos_group, accented_letters_group.
	Sub := _MR_BuildBuiltinGroup(Id, CategoryName)
	if (Sub is Menu) {
		ResultMenu.Add(Label, Sub)
	}
}

; Render a letter-picker submenu entry.
_MR_RenderLetterPicker(ResultMenu, Item, CategoryName) {
	Id := _MR_Get(Item, "id")
	if (Id == "") {
		try LoggerWarn("MenuRenderer", "letter_picker item missing id — skipped.")
		return
	}
	MenuAddLetterPicker(ResultMenu, CategoryName, Id)
}

; Build a built-in named group that is always rendered the same way.
_MR_BuildBuiltinGroup(GroupId, CategoryName) {
	global _SHORTCUTS_SUBMAP_V1V2

	if (GroupId == "modifier_combos") {
		Sub := Menu()
		for V1Group, V2Section in _SHORTCUTS_SUBMAP_V1V2 {
			GroupSub := Menu()
			for Entry in ManifestFeaturesForSection(V2Section) {
				MenuAddItemFromManifest(GroupSub, Entry, "Shortcuts." . V1Group)
			}
			Sub.Add(V1Group, GroupSub)
		}
		return Sub
	}

	if (GroupId == "accented_letters") {
		Sub := Menu()
		for LetterId in ["EGrave", "ECirc", "EAcute", "AGrave"] {
			MenuAddLetterPicker(Sub, "Shortcuts", LetterId)
		}
		return Sub
	}

	try LoggerWarn("MenuRenderer", "Unknown built-in group '{1}'.", GroupId)
	return false
}
