; infra/manifest_menu.ahk

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





; =============================================
; =============================================
; ======= 1/ Manifest Root Access Layer =======
; =============================================
; =============================================

; Returns the parsed manifest root Map, or ``false`` on any read / parse failure.
;
; Thin delegate to the single shared accessor. This function used to keep its own
; independent cache of the very same menu_manifest.json, so the 12.5 KB file was
; decoded once here and again in infra/menu_manifest.ahk — ~44 ms of pure duplicate
; work on the boot path. One decoder means one decode per process, and the
; failure contract is inherited unchanged: a failed load is never cached, so a
; transient I/O error stays retryable instead of freezing the session into the
; fallback defaults.
_MR_GetManifestRoot() {
	return _MM_GetManifestRoot()
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

; Returns true when the entry is visible on ``Platform``.
; Driver-neutral: call as _MR_IsForPlatform(Entry, "ahk") for Windows,
; _MR_IsForPlatform(Entry, "linux") for the future Linux driver.
; An entry with no ``platforms`` restriction is visible on all platforms.
_MR_IsForPlatform(Entry, Platform) {
	if !(Entry is Map) or !Entry.Has("platforms") {
		return true
	}
	Plats := Entry["platforms"]
	if !(Plats is Array) {
		return true
	}
	for _, P in Plats {
		if P == Platform {
			return true
		}
	}
	return false
}

; Legacy alias: Windows driver entry point.
_MR_IsForAhk(Entry) {
	return _MR_IsForPlatform(Entry, "ahk")
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
; ``ListProviders`` — Map of list_id → Func to call for ``type:"list"`` entries.
;   A provider returns DATA, never a Menu: each row is a Map with "label" and
;   optionally "action", "items", "checked", "disabled" or "separator", and this
;   renderer turns it into AHK menu items. The asymmetry is the point — a
;   provider that could return a finished Menu would be building menu items
;   outside the renderer again, which is what the list type exists to stop. The
;   macOS renderer takes the same shape, which is what lets a section rendered on
;   both drivers finally be compared.
;
; Returns the populated Menu object.
MenuRenderer_Build(ManifestKey, CategoryName, DynamicHandlers, GroupBuilders := "", ListProviders := "", Commands := "", StateGetters := "") {
	if (GroupBuilders == "") {
		GroupBuilders := Map()
	}
	if (ListProviders == "") {
		ListProviders := Map()
	}
	; The two the declarative "check" / "command" types read. Optional so every
	; existing caller keeps working unchanged: a menu with no declarative row
	; passes neither, and the branch that needs them says so when one is missing
	; rather than rendering a row with no behaviour.
	if (Commands == "") {
		Commands := Map()
	}
	if (StateGetters == "") {
		StateGetters := Map()
	}

	MenuDef    := _MR_GetMenuDef(ManifestKey)
	Result     := Menu()
	ItemCount  := 0      ; real items added so far
	PendingSep := false  ; separator deferred until next real item

	for Item in MenuDef {
		if !_MR_IsForAhk(Item) {
			; A handler registered for an entry the platform filter drops is
			; always drift: the driver implements the action, the manifest says
			; this platform does not have it, and the row silently disappears
			; with nothing anywhere to explain why. Surface the asymmetry.
			FilteredId := _MR_Get(Item, "id")
			if (FilteredId != "" and DynamicHandlers is Map and DynamicHandlers.Has(FilteredId)) {
				try LoggerDebug("MenuRenderer", "Item '{1}' in '{2}' is platform-filtered out but a handler is registered for it — manifest/driver drift.", FilteredId, ManifestKey)
			}
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
			} else {
				; Manifest/handler drift: the entry exists but nothing can render
				; it, so the item simply vanishes from the menu. Every sibling
				; branch reports, and the unknown-item-type fallback below has
				; logged since it was written — this one was the exception.
				try LoggerWarn("MenuRenderer", "No handler for action item '{1}' in '{2}' — skipped.", Id, ManifestKey)
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

		} else if ItemType == "list" {
			Id := _MR_Get(Item, "id")
			if (Id != "" and ListProviders is Map and ListProviders.Has(Id)) {
				Rows := (ListProviders[Id])()
				Added := _MR_RenderRows(Result, Rows, Id, 1)
				ItemCount += Added
			} else {
				; Same class of drift as the action and dynamic branches: a list
				; entry with no provider is a whole menu section that vanishes
				try LoggerWarn("MenuRenderer", "No provider for list item '{1}' in '{2}' — skipped.", Id, ManifestKey)
			}

		} else if (ItemType == "check" or ItemType == "command") {
			; The declarative row: the manifest carries its label, its checkmark
			; predicate and its greying predicate, and the driver supplies only a
			; NAMED behaviour through Commands.
			;
			; Every other type that carries behaviour hands the id back to a driver
			; function that builds the row itself, which is why 639 rows across the
			; three drivers lived outside their renderers. Here the row is built
			; ONCE, in each driver's renderer, from one shared declaration — so the
			; same setting cannot render as a tick on one OS and a checkbox on
			; another. The Lua renderer implements the identical two types.
			Id := _MR_Get(Item, "id")
			I18nKey := _MR_Get(Item, "i18n")
			CmdId := _MR_Get(Item, "command")
			if (CmdId == "") {
				CmdId := Id
			}
			if (Id == "" or I18nKey == "") {
				try LoggerWarn("MenuRenderer", "'{1}' item missing id or i18n in '{2}' — skipped.", ItemType, ManifestKey)
			} else if !(Commands is Map and Commands.Has(CmdId)) {
				; Same class of drift as the action branch: a declared row whose
				; command nobody registered renders one item short, permanently.
				try LoggerWarn("MenuRenderer", "No command '{1}' for '{2}.{3}' — skipped.", CmdId, ManifestKey, Id)
			} else {
				Row := Map("label", t(I18nKey), "action", Commands[CmdId])
				if MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters) {
					Row["disabled"] := true
				}
				; Only "check" carries a tick. Giving a plain command row
				; checked := false would draw an empty box beside a row that
				; toggles nothing.
				if (ItemType == "check") {
					Row["checked"] := MenuRenderer_ResolveCheckedWhen(ManifestKey, Id, StateGetters)
				}
				_MR_RenderRows(Result, [Row], Id, 1)
				ItemCount++
			}

		} else if ItemType == "dynamic" {
			Id := _MR_Get(Item, "id")
			if (Id != "" and DynamicHandlers is Map and DynamicHandlers.Has(Id)) {
				(DynamicHandlers[Id])(Result, CategoryName)
				ItemCount++
			} else {
				try LoggerWarn("MenuRenderer", "No handler for dynamic item '{1}' in '{2}' — skipped.", Id, ManifestKey)
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

; How deep a list provider's rows may nest. A provider returning a structure that
; contains itself would recurse until the stack gave out, taking the whole menu
; with it; three levels is deeper than any menu the driver draws. Kept equal to
; the macOS renderer's MAX_LIST_DEPTH so a list that renders on one driver cannot
; be silently truncated on the other
global MR_MAX_LIST_DEPTH := 3

; Turn a list provider's row DATA into AHK menu items.
;
; This is the only place a provider's rows become menu items, which is the whole
; reason the two shapes differ: a provider hands over labels, callbacks and
; nested rows, and knows nothing about Menu, Add or Check. A row missing a label
; is dropped with a warning rather than added blank — an unlabelled item is one
; the user cannot identify and cannot report.
;
; Returns the number of items added.
_MR_RenderRows(TargetMenu, Rows, ListId, Depth) {
	global MR_MAX_LIST_DEPTH

	if (Depth > MR_MAX_LIST_DEPTH) {
		try LoggerError("MenuRenderer", "List '{1}' nests deeper than {2} level(s) — truncated.", ListId, MR_MAX_LIST_DEPTH)
		return 0
	}
	if (!(Rows is Array)) {
		try LoggerWarn("MenuRenderer", "List '{1}' produced no row array — skipped.", ListId)
		return 0
	}

	Added := 0
	for Row in Rows {
		if (!(Row is Map)) {
			try LoggerWarn("MenuRenderer", "List '{1}' produced a non-row entry — skipped.", ListId)
			continue
		}
		if (Row.Has("separator") and Row["separator"]) {
			TargetMenu.Add()
			continue
		}
		Label := Row.Has("label") ? Row["label"] : ""
		if (Label == "") {
			try LoggerWarn("MenuRenderer", "List '{1}' produced a row with no label — skipped.", ListId)
			continue
		}

		if (Row.Has("items") and Row["items"] is Array) {
			SubMenu := Menu()
			_MR_RenderRows(SubMenu, Row["items"], ListId, Depth + 1)
			TargetMenu.Add(Label, SubMenu)
		} else if (Row.Has("submenu") and Row["submenu"] is Menu) {
			; A submenu this driver has ALREADY built as a native Menu.
			;
			; TRANSITIONAL, and narrow on purpose. The row itself — its label, its
			; checkmark, its position among the manifest's other rows — is
			; materialised here, which is the whole point; only the tree hanging off
			; it is still the driver's. That tree is `SubMenus[Category]`, assembled
			; by a different subsystem, and turning it into data is the next
			; migration rather than a precondition for this one.
			;
			; It is deliberately NOT `items`: a caller must say which of the two it
			; is handing over, so a Menu passed where row data was expected fails
			; here instead of rendering an empty submenu.
			TargetMenu.Add(Label, Row["submenu"])
		} else if (Row.Has("action") and Row["action"] is Func) {
			RegisterMenuItem(TargetMenu, Label, Row["action"])
		} else {
			; A row with neither a submenu nor an action is a label; AHK needs a
			; callback regardless, so it gets an inert one and is disabled below
			RegisterMenuItem(TargetMenu, Label, (*) => "")
		}

		if (Row.Has("checked") and Row["checked"]) {
			try TargetMenu.Check(Label)
		}
		; A row with none of the three — no nested rows, no native submenu, no
		; callback — is a label, and AHK needs it disabled to read as one.
		if ((Row.Has("disabled") and Row["disabled"])
			or (!Row.Has("items") and !Row.Has("action") and !Row.Has("submenu"))) {
			try TargetMenu.Disable(Label)
		}
		Added++
	}
	return Added
}

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

; Render a letter-picker submenu entry. The manifest ``id`` is the v2 alpha id
; (e.g. "e_grave"); accented-letter pickers live under the shortcuts section and
; are gated by the Shortcuts master.
_MR_RenderLetterPicker(ResultMenu, Item, _CategoryName) {
	Id := _MR_Get(Item, "id")
	if (Id == "") {
		try LoggerWarn("MenuRenderer", "letter_picker item missing id — skipped.")
		return
	}
	MenuAddLetterPicker(ResultMenu, "shortcuts." . Id, "Shortcuts")
}

; Build a built-in named group that is always rendered the same way.
_MR_BuildBuiltinGroup(GroupId, CategoryName) {
	; The rows come from the manifest section named after the group — the
	; ``<id>_group`` convention the renderer already uses for hotstrings_params.
	; Both lists used to be hardcoded here as well as declared in the manifest,
	; so editing the manifest moved nothing and the code copy was the real source.
	Section := _MR_GetMenuDef(GroupId . "_group")

	if (GroupId == "modifier_combos") {
		Sub := Menu()
		for Entry in Section {
			if !_MR_IsForAhk(Entry)
				continue
			; ``path`` is a feature-manifest SECTION here: each row expands to
			; every feature under it, gathered in one labelled submenu.
			V2Section := _MR_Get(Entry, "path")
			GroupLabel := _MR_Get(Entry, "group_label")
			if (V2Section == "" or GroupLabel == "")
				continue
			GroupSub := Menu()
			for FeatureEntry in ManifestFeaturesForSection(V2Section) {
				MenuAddItemFromManifest(GroupSub, FeatureEntry, "Shortcuts." . GroupLabel)
			}
			Sub.Add(GroupLabel, GroupSub)
		}
		return Sub
	}

	if (GroupId == "accented_letters") {
		Sub := Menu()
		for Entry in Section {
			if !_MR_IsForAhk(Entry)
				continue
			LetterId := _MR_Get(Entry, "id")
			if (LetterId == "")
				continue
			MenuAddLetterPicker(Sub, "shortcuts." . LetterId, "Shortcuts")
		}
		return Sub
	}

	try LoggerWarn("MenuRenderer", "Unknown built-in group '{1}'.", GroupId)
	return false
}





; =======================================================
; =======================================================
; ======= 5/ Declarative Disabled Resolver (MG-1) =======
; =======================================================
; =======================================================

; Finds the manifest item with the given ``id`` inside the ``MenuKey`` array.
; Returns the item Map, or ``false`` if not found.
_MR_FindItemById(MenuKey, ItemId) {
	MenuDef := _MR_GetMenuDef(MenuKey)
	for Item in MenuDef {
		if (Item is Map) and _MR_Get(Item, "id") == ItemId {
			return Item
		}
	}
	return false
}

; Evaluates the declarative ``disabled_when`` predicate of a manifest item
; against a caller-supplied Map of canonical state key -> zero-arg getter Func.
;
; ``disabled_when`` is an array of canonical state keys; the item is enabled
; only when EVERY key's getter returns a truthy value — it is disabled as
; soon as any one of them is falsy. Items without a ``disabled_when`` array
; are never disabled by this mechanism (returns ``false``).
;
; A missing getter for a declared key means the manifest and the driver's
; getters Map have drifted — logged as ERROR and treated as disabled so the
; mismatch fails loud instead of silently rendering an always-enabled item (§5.3).
MenuRenderer_ResolveDisabledWhen(MenuKey, ItemId, Getters) {
	Item := _MR_FindItemById(MenuKey, ItemId)
	if (Item == false) {
		; A lookup miss means the caller passed an id that is not in MenuKey's
		; array — a typo'd or drifted manifest reference. Failing OPEN here
		; silently renders a security-sensitive item (e.g. a keylogger-gated
		; toggle) as always-enabled, so fail CLOSED, matching both the sibling
		; getter-mismatch branch below and the macOS twin (§5.3).
		try LoggerError("MenuRenderer", "No manifest item '{1}.{2}' — treating as disabled.", MenuKey, ItemId)
		return true
	}

	Keys := _MR_Get(Item, "disabled_when", 0)
	if !(Keys is Array) or Keys.Length == 0 {
		return false
	}

	for Key in Keys {
		if !(Getters is Map) or !Getters.Has(Key) {
			try LoggerError("MenuRenderer", "No getter for disabled_when key '{1}' on item '{2}.{3}' — treating as disabled.", Key, MenuKey, ItemId)
			return true
		}
		if !(Getters[Key])() {
			return true
		}
	}

	return false
}

; Evaluates the declarative ``checked_when`` predicate of a manifest item, the
; mirror of ``disabled_when``: an array of canonical state keys, the item checked
; only when EVERY getter returns truthy. Items without the array are never
; checked by this mechanism (returns ``false``).
;
; FAILS OPEN, unlike its sibling, and the asymmetry is deliberate. A checkmark
; is an ASSERTION to the user that something is currently on. Inventing one when
; the state cannot be read tells them a filter is active that is not — they stop
; looking for the setting, and the data they thought was excluded is being
; recorded. `disabled_when` fails CLOSED for the same underlying reason: in both
; directions the safe answer is the one that does not overstate what is enabled.
;
; A missing getter is still logged as an ERROR — the manifest and the driver's
; getters Map have drifted, and a row whose checkmark silently never appears is
; exactly the kind of quiet wrong that this file exists to make loud.
MenuRenderer_ResolveCheckedWhen(MenuKey, ItemId, Getters) {
	Item := _MR_FindItemById(MenuKey, ItemId)
	if (Item == false) {
		try LoggerError("MenuRenderer", "No manifest item '{1}.{2}' — treating as unchecked.", MenuKey, ItemId)
		return false
	}

	Keys := _MR_Get(Item, "checked_when", 0)
	if !(Keys is Array) or Keys.Length == 0 {
		return false
	}

	for Key in Keys {
		if !(Getters is Map) or !Getters.Has(Key) {
			try LoggerError("MenuRenderer", "No getter for checked_when key '{1}' on item '{2}.{3}' — treating as unchecked.", Key, MenuKey, ItemId)
			return false
		}
		if !(Getters[Key])() {
			return false
		}
	}

	return true
}

; Returns the ``i18n_dynamic`` key declared on a manifest item — the locale key
; a dynamic handler prefixes to a runtime value (a shortcut label, a model name)
; before rendering its own row.
;
; Rows whose label is computed cannot be rendered declaratively, so their
; handler builds the string. That is not a reason for the handler to also OWN
; the locale key: two rows declared ``i18n_dynamic`` and no code read it, while
; the handlers carried their own copy of the same string. Editing the manifest
; moved nothing, which is the failure this accessor removes.
;
; A missing declaration is an ERROR rather than a silent "": the handler is
; about to concatenate this into a user-visible label, and an empty prefix
; renders as a bare shortcut with no indication of what it does.
MenuRenderer_I18nDynamic(MenuKey, ItemId) {
	Item := _MR_FindItemById(MenuKey, ItemId)
	if (Item == false) {
		try LoggerError("MenuRenderer", "No manifest item '{1}.{2}' — no i18n_dynamic key.", MenuKey, ItemId)
		return ""
	}
	Key := _MR_Get(Item, "i18n_dynamic")
	if (Key == "") {
		try LoggerError("MenuRenderer", "Item '{1}.{2}' declares no i18n_dynamic key.", MenuKey, ItemId)
	}
	return Key
}
