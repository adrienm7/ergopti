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

#Include menu_population.ahk





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

; Read the shared Dynamic child records through the existing manifest owner.
; A missing declaration is a boot-model error, never an invented private order.
_MR_GetDynamicHotstringFamilies() {
	Root := _MR_GetManifestRoot()
	Node := Root is Map ? Root.Get("dynamic_hotstring_families", false) : false
	Rows := Node is Map ? Node.Get("rows", false) : false
	if !(Rows is Array) || !Rows.Length
		throw Error("Dynamic hotstring families require their shared menu declaration.")
	Result := [], Seen := Map()
	for Row in Rows {
		if !(Row is Map)
			throw Error("Dynamic hotstring family must be a record.")
		if Row.Get("separator", false) {
			if Row.Has("id")
				throw Error("Dynamic separator cannot also be a family.")
		} else {
			for Key in ["id", "section", "i18n", "legacy_key"] {
				if !Row.Has(Key) || Type(Row[Key]) != "String" || Row[Key] == ""
					throw Error("Dynamic hotstring family requires " . Key . ".")
			}
			if Seen.Has(Row["id"])
				throw Error("Duplicate Dynamic hotstring family: " . Row["id"] . ".")
			Seen[Row["id"]] := true
		}
		Result.Push(ManifestCloneValue(Row))
	}
	return Result
}

; Preserve the native legacy identities while sharing every displayed family.
_MR_DynamicHotstringsKeyMap() {
	Result := Map()
	for Row in _MR_GetDynamicHotstringFamilies() {
		if !Row.Get("separator", false)
			Result[Row["legacy_key"]] := Row["id"]
	}
	return Result
}

; The tray and headless native fixtures consume this same boot-order owner.
_MR_DynamicHotstringsOrder() {
	Result := []
	for Row in _MR_GetDynamicHotstringFamilies()
		Result.Push(Row.Get("separator", false) ? "-" : Row["legacy_key"])
	return Result
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
; An optional empty target keeps caller-owned references used by native repaint
; callbacks while the shared declaration still owns command and separator order.
; Optional GroupDisabled maps declared ids to resolved native Boolean greying.
; Such groups must return a genuine Menu before any parent is attached.
; Returns the populated Menu object.
MenuRenderer_Build(ManifestKey, CategoryName, DynamicHandlers, GroupBuilders := "", ListProviders := "", Commands := "", StateGetters := "", TargetMenu := unset, GroupDisabled := unset) {
	if IsSet(TargetMenu) && (!(TargetMenu is Menu)
			|| TrayMenuItemCount(TargetMenu) != 0)
		throw Error("A manifest menu target must be an empty native menu.")
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

	if IsSet(GroupDisabled) {
		if !(GroupDisabled is Map)
			throw Error("Native group greying must be a Map.")
		for Id, Disabled in GroupDisabled {
			if Type(Id) != "String" || Id == "" || Type(Disabled) != "Integer"
				|| (Disabled != 0 && Disabled != 1)
				throw Error("Native group greying requires an explicit Boolean fact.")
		}
	}
	MenuDef    := _MR_GetMenuDef(ManifestKey)
	if IsSet(TargetMenu)
		Result := TargetMenu
	else
		Result := Menu()
	ItemCount  := 0      ; real items added so far
	PendingSep := false  ; separator deferred until next real item

	for Item in MenuDef {
		if !_MR_CommandLiteralPrefix(Item, &Prefix) {
			try LoggerError("MenuRenderer", "Invalid literal command prefix — row refused.")
			continue
		}
		if !_MR_IsForAhk(Item) {
			; A handler registered for an entry the platform filter drops is
			; always drift: the driver implements the action, the manifest says
			; this platform does not have it, and the row silently disappears
			; with nothing anywhere to explain why. Surface the asymmetry.
			FilteredId := _MR_Get(Item, "id")
			if (FilteredId != "" and DynamicHandlers is Map and DynamicHandlers.Has(FilteredId)) {
				try LoggerDebug("MenuRenderer", "Item '{1}' in '{2}' is platform-filtered out but a handler is registered for it — manifest/driver drift.", FilteredId, ManifestKey)
			}
			; Hidden unless declared `unavailable = "grey"`: not yet ported here, so
			; drawn disabled with the short form of its reason (the maintainer's
			; rule of 2026-09-30); a hidden row is not applicable here.
			if _MR_Get(Item, "unavailable") == "grey" {
				if PendingSep and ItemCount > 0
					Result.Add()
				PendingSep := false
				ItemCount += Item.Has("label_prefix")
					? _MR_RenderGreyedStandIn(Result, Item, ManifestKey, Prefix . t(_MR_Get(Item, "i18n")))
					: _MR_RenderGreyedStandIn(Result, Item, ManifestKey)
			}
			continue
		}

		if Item.Has("caption_count_policy") && !_MR_TranslatedCountPolicy(Item)
			continue
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
			ItemCount += _MR_RenderToggle(Result, Item, ManifestKey, Commands, StateGetters)

		} else if ItemType == "choice" {
			ItemCount += _MR_RenderChoice(Result, Item, ManifestKey, Commands, StateGetters)

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
			Id := _MR_Get(Item, "id")
			if IsSet(GroupDisabled) && GroupDisabled.Has(Id) {
				if !_MR_RenderGroup(Result, Item, CategoryName, GroupBuilders, ManifestKey, StateGetters, GroupDisabled[Id])
					throw Error("Declared native group '" . Id . "' was refused.")
			} else {
				_MR_RenderGroup(Result, Item, CategoryName, GroupBuilders, ManifestKey, StateGetters)
			}
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
			ItemCount += _MR_RenderCommand(Result, Item, ManifestKey, Commands, StateGetters)

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

	_MR_NormalizeSeparators(Result)
	return Result
}




; ============================================
; ============================================
; ======= 4/ Per-Type Render Helpers =========
; ============================================
; ============================================

; How deep a list provider's rows may nest. A provider returning a structure that
; contains itself would recurse until the stack gave out, taking the whole menu
; with it, so this is a runaway-recursion guard — NOT a statement about how deep a
; menu may legitimately be. Kept equal to the shared Lua renderer's
; MAX_LIST_DEPTH so a list that renders on one driver cannot be silently
; truncated on another
;
; Raised 3 → 8 on 2026-08-07. Three was documented as "deeper than any menu the
; driver draws" and that was already false on macOS: the personal-extensions tree
; follows a folder the USER writes, so its depth is theirs to choose, and a single
; level of subfolder already reaches four. A cap sized for a hand-declared menu
; cannot bound a filesystem. This driver's own scan stops at _HS_SCAN_MAX_DEPTH
; (16) for the same tree
global MR_MAX_LIST_DEPTH := 8

; Report a row written in the OTHER drivers' dialect, field by field.
;
; "title", "fn" and "menu" are the hs.menubar field names, and a provider row
; says "label", "action" and "items". The mistake costs nothing to make and used
; to cost everything to find: a "title" is not a label, so the row was dropped
; with a generic warning, and a "menu" was never read at all, so the row appeared
; with its whole subtree missing and NOTHING was logged. It happened three times
; on macOS in the days its menu moved onto the renderer. The shared Lua renderer
; carries the identical check, because a row that renders on one driver and
; vanishes on another is the exact failure this whole migration exists to end.
_MR_ReportDriverDialect(Row, ListId) {
	Named := Row.Has("label") ? Row["label"] : (Row.Has("title") ? Row["title"] : "?")
	if (Row.Has("title") and !Row.Has("label")) {
		try LoggerError("MenuRenderer", "List '{1}' row '{2}' uses 'title' — a provider row says 'label', so this row is dropped.", ListId, Named)
	}
	if (Row.Has("menu") and !Row.Has("items") and !Row.Has("submenu")) {
		try LoggerError("MenuRenderer", "List '{1}' row '{2}' hangs its subtree on 'menu' — a provider row says 'items' (or 'submenu' for a tree already built), so the row renders with nothing under it.", ListId, Named)
	}
	if (Row.Has("fn") and !Row.Has("action")) {
		try LoggerError("MenuRenderer", "List '{1}' row '{2}' carries 'fn' — a provider row says 'action', so the row does nothing when clicked.", ListId, Named)
	}
	; A Win32 item that opens a submenu sends no command, so the subtree wins
	; below and this action is dropped. Mirrors the shared Lua renderer, where the
	; same shape left four macOS categories impossible to switch on.
	if (Row.Has("action") and (Row.Has("items") or Row.Has("submenu"))) {
		try LoggerError("MenuRenderer", "List '{1}' row '{2}' carries both an 'action' and a subtree — a row that opens a submenu is never clicked, so the action can never run.", ListId, Named)
	}
}

; Turn a list provider's row DATA into AHK menu items.
;
; This is the only place a provider's rows become menu items, which is the whole
; reason the two shapes differ: a provider hands over labels, callbacks and
; nested rows, and knows nothing about Menu, Add or Check. A row missing a label
; is dropped with a warning rather than added blank — an unlabelled item is one
; the user cannot identify and cannot report.
;
; Returns the number of items added.
_MR_RenderRows(TargetMenu, Rows, ListId, Depth, PopulationOwner := unset, RequireTracking := false) {
	global MR_MAX_LIST_DEPTH
	global _MenuPopulationBuilding
	if !IsSet(PopulationOwner)
		PopulationOwner := _MenuPopulationBuilding

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
		_MR_ReportDriverDialect(Row, ListId)
		Label := Row.Has("label") ? Row["label"] : ""
		if (Label == "") {
			try LoggerWarn("MenuRenderer", "List '{1}' produced a row with no label — skipped.", ListId)
			continue
		}
		; A greyed row that names why (disabled_reason_key) reads like every greyed
		; row with a reason, « label — head of the reason », and has nothing to run.
		Greyed := Row.Has("disabled") && Row["disabled"] && Row.Has("disabled_reason_key")
			&& Row["disabled_reason_key"] != ""
		if Greyed
			Label := Label . " — " . _MR_ReasonHead(t(Row["disabled_reason_key"]))
		; Rows carry literal text; only the native menu syntax treats & as a mnemonic.
		Label := StrReplace(Label, "&", "&&")

		if (Row.Has("items") and Row["items"] is Array) {
			if PopulationOwner is MenuPopulation && MenuPopulation_IsLeaf(Row["items"]) {
				SubMenu := PopulationOwner.Create(Row["items"], ListId, Depth + 1)
			} else {
				SubMenu := Menu()
				_MR_RenderRows(SubMenu, Row["items"], ListId, Depth + 1, PopulationOwner)
				_MR_NormalizeSeparators(SubMenu)
			}
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
		} else if (Row.Has("action") and (Row["action"] is Func
				or Row["action"] is MenuStartupUiCommand
				or Row["action"] is MenuStartupRepeatableToggleCommand) and !Greyed) {
			Tracked := RegisterMenuItem(TargetMenu, Label, Row["action"])
			if RequireTracking && Tracked != 1
				throw Error("Native leaf command registration was refused")
		} else {
			; A row with neither a submenu nor an action is a label; AHK needs a
			; callback regardless, so it gets an inert one and is disabled below
			Tracked := RegisterMenuItem(TargetMenu, Label, (*) => "")
			if RequireTracking && Tracked != 1
				throw Error("Native leaf label registration was refused")
		}

		; An optional per-row icon. Win32 menus can carry one and hs.menubar rows
		; cannot, which is why the language selector was the last common menu with
		; no shared declaration: describing it would have cost this driver its flags.
		; The field is optional, so a driver that cannot draw icons simply ignores it.
		if (Row.Has("icon") and Row["icon"] != "") {
			try TargetMenu.SetIcon(Label, Row["icon"])
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

; Applies physical explicit affixes before any native child/command publication.
_MR_ExplicitCaption(Item, Getters, &Caption, RawTitle := unset) {
	I18nKey := _MR_Get(Item, "i18n")
	Caption := IsSet(RawTitle) ? RawTitle : t(I18nKey)
	_MR_CaptionFormat(Caption, "", &SourceSlot)
	Getter := _MR_Get(Item, "caption_getter")
	if !_MR_CaptionLayoutMetadata(Item) || Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == ""
		|| Type(I18nKey) != "String" || I18nKey == "" || Type(Caption) != "String" || Caption == ""
		|| Caption == I18nKey || SourceSlot || !(Getters is Map) || !Getters.Has(Getter)
		|| !HasMethod(Getters[Getter], "Call") {
		try LoggerError("MenuRenderer", "Invalid explicit caption source — row refused.")
		return false
	}
	Value := Getters[Getter].Call()
	if Type(Value) != "String" {
		try LoggerError("MenuRenderer", "Invalid explicit caption receipt — row refused.")
		return false
	}
	Caption := Item["caption_layout"] == "prefix" ? Caption . Item["caption_joiner"] . Value
		: Value . Item["caption_joiner"] . Caption
	return true
}

; Accepts literal command decoration without replacing malformed Unicode units.
_MR_CommandLiteralPrefix(Item, &Prefix) {
	Prefix := ""
	if !(Item is Map)
		return false
	if !Item.Has("label_prefix")
		return true
	Prefix := Item["label_prefix"]
	if _MR_Get(Item, "type") != "command" || Type(Prefix) != "String"
		|| Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == ""
		|| Type(_MR_Get(Item, "i18n")) != "String" || _MR_Get(Item, "i18n") == ""
		return false
	return _MR_PlainUnicodeCaption(Prefix)
}

; One literal Unicode validator serves command decoration and native record names.
_MR_PlainUnicodeCaption(Caption) {
	if Type(Caption) != "String"
		return false
	Position := 1
	while Position <= StrLen(Caption) {
		Unit := Ord(SubStr(Caption, Position, 1))
		if Unit < 0x20 || Unit == 0x7F
			return false
		if Unit >= 0xD800 && Unit <= 0xDBFF {
			if Position == StrLen(Caption)
				return false
			NextUnit := Ord(SubStr(Caption, Position + 1, 1))
			if NextUnit < 0xDC00 || NextUnit > 0xDFFF
				return false
			Position += 2
		} else {
			if Unit >= 0xDC00 && Unit <= 0xDFFF
				return false
			Position += 1
		}
	}
	return true
}

; Renders the same declared command/check in full and native-built menus.
_MR_CommandRowData(Item, ManifestKey, Commands, StateGetters) {
	if !_MR_CommandLiteralPrefix(Item, &Prefix) {
		try LoggerError("MenuRenderer", "Invalid literal command prefix — row refused.")
		return false
	}
	ItemType := _MR_Get(Item, "type")
	Id := _MR_Get(Item, "id")
	I18nKey := _MR_Get(Item, "i18n")
	CmdId := _MR_Get(Item, "command", Id)
	if CmdId == ""
		CmdId := Id
	if Id == "" || (I18nKey == "" && _MR_Get(Item, "caption_source") != "native") || !(Commands is Map) || !Commands.Has(CmdId) {
		try LoggerError("MenuRenderer", "Missing declaration or command for '{1}.{2}'.", ManifestKey, Id)
		return false
	}
	Label := unset
	if Item.Has("caption_format") && !_MR_ReadNumberedCaption(Item, StateGetters, &Label)
		return false
	if Item.Has("caption_source") && !_MR_ReadNativeCaption(Item, StateGetters, &Label)
		return false
	if Item.Has("caption_layout") || Item.Has("caption_joiner") {
		if !_MR_ExplicitCaption(Item, StateGetters, &Label)
			return false
	}
	if Item.Has("caption_getters") {
		if !_MR_ReadCaptionValues(Item, StateGetters, &Label)
			return false
	}
	if Item.Has("label_prefix")
		Label := Prefix . (IsSet(Label) ? Label : t(I18nKey))
	Disabled := MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters)
	ReasonKey := _MR_Get(Item, "disabled_reason_key")
	if Disabled && ReasonKey != "" && IsSet(Label)
		return Map("label", Label, "disabled", true, "disabled_reason_key", ReasonKey)
	if Disabled && ReasonKey != ""
		return Map("label", t(I18nKey), "disabled", true, "disabled_reason_key", ReasonKey)
	Row := Map("label", IsSet(Label) ? Label : t(I18nKey), "action", Commands[CmdId])
	if Disabled
		Row["disabled"] := true
	if ItemType == "check"
		Row["checked"] := MenuRenderer_ResolveCheckedWhen(ManifestKey, Id, StateGetters)
	return Row
}

_MR_RenderCommand(ResultMenu, Item, ManifestKey, Commands, StateGetters) {
	Row := _MR_CommandRowData(Item, ManifestKey, Commands, StateGetters)
	if !(Row is Map)
		return 0
	; Keep the existing native stand-in owner and its untracked inert callback.
	if Row.Has("disabled_reason_key") && (Item.Has("caption_layout") || Item.Has("caption_joiner") || Item.Has("label_prefix") || Item.Has("caption_getters"))
		return _MR_RenderGreyedStandIn(ResultMenu,
			Map("id", _MR_Get(Item, "id"), "i18n", _MR_Get(Item, "i18n"),
				"reason_key", Row["disabled_reason_key"]), ManifestKey, Row["label"])
	if Row.Has("disabled_reason_key")
		return _MR_RenderGreyedStandIn(ResultMenu,
			Map("id", _MR_Get(Item, "id"), "i18n", _MR_Get(Item, "i18n"),
				"reason_key", Row["disabled_reason_key"]), ManifestKey)
	return _MR_RenderRows(ResultMenu, [Row], _MR_Get(Item, "id"), 1)
}

; Provider callbacks use the same current declaration as the drawn row.
_MR_CommandProviderDelivery(ManifestKey, CommandId, Action, Getters, *) {
	if MenuRenderer_ResolveDisabledWhen(ManifestKey, CommandId, Getters)
		return false
	return Action.Call()
}

/**
 * Supplies one declared command as provider data for a caller-owned menu.
 * @param {String} ManifestKey Owning shared menu declaration.
 * @param {String} CommandId Declared command identifier.
 * @param {Map} Commands Native callbacks indexed by command identifier.
 * @param {Map} StateGetters Native state readers.
 * @returns {Map|false} Canonical provider row or a refused declaration.
 */
_MR_DeclaredProviderRow(ManifestKey, CommandId, Commands, StateGetters, ExpectedType) {
	Item := _MR_FindItemById(ManifestKey, CommandId)
	if !(Item is Map) || _MR_Get(Item, "type") != ExpectedType || !_MR_IsForAhk(Item)
		return false
	Getters := IsSet(StateGetters) ? StateGetters : Map()
	Row := _MR_CommandRowData(Item, ManifestKey, Commands, Getters)
	if Row is Map && Row.Has("action")
		Row["action"] := _MR_CommandProviderDelivery.Bind(ManifestKey, CommandId, Row["action"], Getters)
	return Row
}

; A checked command uses the same declaration and retained readiness policy.
MenuRenderer_CommandRow(ManifestKey, CommandId, Commands, StateGetters := unset) {
	return _MR_DeclaredProviderRow(ManifestKey, CommandId, Commands,
		IsSet(StateGetters) ? StateGetters : Map(), "command")
}

/**
 * Captures one canonical parent before its actual native child builder runs.
 * @param {String} ManifestKey Owning declaration.
 * @param {String} RowId Identified group.
 * @returns {Func|false} Completed-child receiver, with no state read on admission.
 */
MenuRenderer_GroupReceiver(ManifestKey, RowId) {
	Owner := MenuRenderer_GroupRow
	if !_MR_DeclaredParentCallable(Owner)
		return false
	Root := _MR_GetManifestRoot(), Rows := _MR_GetMenuDef(ManifestKey)
	Selected := false, Matches := 0
	for Item in Rows {
		if _MR_Get(Item, "id") == RowId
			Selected := Item, Matches += 1
	}
	if Type(RowId) != "String" || RowId == "" || Matches != 1 || _MR_Get(Selected, "type") != "group"
		|| !_MR_IsForAhk(Selected) || Type(_MR_Get(Selected, "i18n")) != "String" || _MR_Get(Selected, "i18n") == ""
		|| (Selected.Has("caption_count_policy") && !_MR_TranslatedCountPolicy(Selected))
		return false
	Source := _MR_ReasonedGroupSnapshot(Rows)
	if !Source || MenuRenderer_GroupRow != Owner || !_MR_DeclaredParentCallable(Owner)
		return false
	return _MR_ReceiveDeclaredParent.Bind(ManifestKey, RowId, Root, Rows, Source, Owner)
}

; A callable identity alone does not own dispatch when the same object gains Call.
; Use the intrinsic property test, never the callable object's own HasOwnProp.
_MR_DeclaredParentCallable(Owner) {
	return (Owner is Func || Owner is BoundFunc)
		&& !Object.Prototype.HasOwnProp.Call(Owner, "Call")
}

_MR_DeclaredParentCurrent(Cohort) {
	if MenuRenderer_GroupRow != Cohort["owner"] || !_MR_DeclaredParentCallable(Cohort["owner"])
		|| _MR_GetManifestRoot() != Cohort["root"] || _MR_GetMenuDef(Cohort["key"]) != Cohort["rows"]
		|| !_MR_ReasonedGroupCurrent(Cohort["source"]) || !_MR_ReasonedGroupCurrent(Cohort["states"])
		return false
	for Key, Owner in Cohort["callables"]
		if !Cohort["getters"].Has(Key) || Cohort["getters"][Key] != Owner || !_MR_DeclaredParentCallable(Owner)
			return false
	return true
}

; Each wrapper checks the whole retained original cohort before and after the
; real getter. Withdrawal by one getter cannot invoke a later foreign getter.
_MR_ReadDeclaredParentState(Cohort, Owner) {
	if !_MR_DeclaredParentCurrent(Cohort)
		throw Error("The admitted native feature-parent owner was withdrawn.")
	Value := Owner.Call()
	if !_MR_DeclaredParentCurrent(Cohort)
		throw Error("The native feature-parent owner changed during its state read.")
	return Value
}

_MR_ReceiveDeclaredParent(ManifestKey, RowId, Root, Rows, Source, Owner, Child, Getters) {
	if !(Getters is Map) || !(Child is Menu)
		return false
	States := _MR_ReasonedGroupSnapshot(Getters)
	if !States
		return false
	Cohort := Map("owner", Owner, "root", Root, "key", ManifestKey, "rows", Rows,
		"source", Source, "states", States, "getters", Getters, "callables", Map())
	Guarded := Map()
	for Key, Getter in Getters {
		if !_MR_DeclaredParentCallable(Getter)
			return false
		Cohort["callables"][Key] := Getter
		Guarded[Key] := _MR_ReadDeclaredParentState.Bind(Cohort, Getter)
	}
	if !_MR_DeclaredParentCurrent(Cohort)
		return false
	try Row := Owner.Call(ManifestKey, RowId, Child, Guarded)
	catch
		return false
	if !(Row is Map) || !_MR_DeclaredParentCurrent(Cohort)
		return false
	return Row
}

/**
 * Supplies one declared parent around a completed native Menu.
 * @param {String} ManifestKey Owning shared menu declaration.
 * @param {String} RowId Unique declared group identity.
 * @param {Menu} NativeChild Finished child retained by identity.
 * @param {Map} StateGetters Actual native state readers.
 * @returns {Map|false} Canonical parent row or refused declaration.
 */
MenuRenderer_GroupRow(ManifestKey, RowId, NativeChild, StateGetters := unset) {
	if Type(ManifestKey) != "String" || ManifestKey == "" || Type(RowId) != "String" || RowId == "" {
		try LoggerError("MenuRenderer", "Invalid declared parent identity — provider row refused.")
		return false
	}
	Selected := false
	Matches := 0
	for Item in _MR_GetMenuDef(ManifestKey) {
		if _MR_Get(Item, "id") == RowId {
			Selected := Item
			Matches += 1
		}
	}
	if Type(RowId) != "String" || RowId == "" || Matches != 1
		|| !(_MR_Get(Selected, "type") == "group") || Selected.Has("label_prefix") || !_MR_IsForAhk(Selected)
		|| ((Type(_MR_Get(Selected, "i18n")) != "String" || _MR_Get(Selected, "i18n") == "") && _MR_Get(Selected, "caption_source") != "native")
		|| !(NativeChild is Menu) {
		try LoggerError("MenuRenderer", "Missing or invalid declared parent '{1}.{2}' — provider row refused.", ManifestKey, RowId)
		return false
	}
	Getters := IsSet(StateGetters) ? StateGetters : Map()
	Label := _MR_Get(Selected, "caption_source") == "native" ? "" : t(_MR_Get(Selected, "i18n"))
	if Selected.Has("caption_count_policy") {
		if !_MR_ReadTranslatedCountCaption(Selected, Getters, &Label)
			return false
	} else if Selected.Has("caption_format") {
		if !_MR_ReadNumberedCaption(Selected, Getters, &Label)
			return false
	} else if Selected.Has("caption_source") {
		if !_MR_ReadNativeCaption(Selected, Getters, &Label)
			return false
	} else if Selected.Has("caption_getters") {
		if !_MR_ReadCaptionValues(Selected, Getters, &Label)
			return false
	} else if Selected.Has("caption_layout") || Selected.Has("caption_joiner") {
		if !_MR_ExplicitCaption(Selected, Getters, &Label, Label)
			return false
	} else if Selected.Has("caption_getter") {
		Getter := Selected["caption_getter"]
		_MR_CaptionFormat(Label, "", &SourceSlot)
		if Type(Getter) != "String" || Getter == "" || !SourceSlot || Label == Selected["i18n"]
			|| !(Getters is Map) || !Getters.Has(Getter) || !HasMethod(Getters[Getter], "Call") {
			try LoggerError("MenuRenderer", "Missing or invalid declared parent caption — provider row refused.")
			return false
		}
		try Value := Getters[Getter].Call()
		catch
			return false
		if Type(Value) != "String" {
			try LoggerError("MenuRenderer", "Invalid declared parent caption receipt — provider row refused.")
			return false
		}
		Label := _MR_CaptionFormat(Label, Value, &HasSlot)
	}
	Row := Map("label", Label, "submenu", NativeChild)
	if MenuRenderer_ResolveDisabledWhen(ManifestKey, RowId, Getters) {
		Row["disabled"] := true
		if Selected.Has("disabled_reason_key")
			Row["disabled_reason_key"] := Selected["disabled_reason_key"]
	}
	if _MR_Get(Selected, "checked_when", 0) is Array
		Row["checked"] := MenuRenderer_ResolveCheckedWhen(ManifestKey, RowId, Getters)
	return Row
}

/**
 * Supplies an ordered declared child template as provider data.
 * @param {String} ManifestKey Shared child declaration.
 * @param {Map} Commands Native callback owners.
 * @param {Map} StateGetters Native state and current caption readers.
 * @param {Map} Children Native child data indexed by declared group identity.
 * @returns {Array|false} Canonical provider rows or a refused template.
 */
MenuRenderer_TemplateRows(ManifestKey, Commands, StateGetters, Children) {
	return _MR_TemplateRows(ManifestKey, Commands, StateGetters, Children, Map())
}

/**
 * Supplies inert status declared on an existing live provider row.
 * @param {String} ManifestKey Owning menu declaration.
 * @param {String} RowId Existing provider identity.
 * @param {String} Status Named native status to project.
 * @returns {Array|false} Translated inactive data or a refused declaration.
 */
MenuRenderer_StatusRows(ManifestKey, RowId, Status) {
	Owner := _MR_FindItemById(ManifestKey, RowId)
	Statuses := Owner is Map ? Owner.Get("status_rows", false) : false
	Def := Statuses is Map ? Statuses.Get(Status, false) : false
	if !(Def is Array) || Def.Length == 0 {
		try LoggerError("MenuRenderer", "Missing provider status '{1}.{2}.{3}' — rows refused.", ManifestKey, RowId, Status)
		return false
	}
	for Item in Def {
		if !(Item is Map)
			return false
		ItemType := Item.Get("type", "")
		Label := ItemType == "label" && Item.Get("i18n", false) is String && Item["i18n"] != ""
		if ItemType != "---" && !Label
			return false
		for Field in Item
			if Field != "type" && !(Label && Field == "i18n")
				return false
	}
	return _MR_TemplateRows(ManifestKey, Map(), Map(), Map(), Map(), Def)
}

; Preflight the complete presentation target before collecting any callback/getter rows.
_MR_TemplateInertPresentation(ManifestKey, Checking, RowId := unset) {
	Def := _MR_GetMenuDef(ManifestKey)
	if Checking.Has(ManifestKey) || Def.Length == 0
		return false
	if IsSet(RowId) {
		Matches := 0
		for Item in Def {
			if _MR_Get(Item, "id") == RowId {
				Matches += 1
			}
		}
		if Matches != 1
			return false
	}
	Checking[ManifestKey] := true
	Loop Def.Length
		if !Def.Has(A_Index)
			return false
	for Item in Def {
		if !(Item is Map)
			return false
		Kind := _MR_Get(Item, "type")
		if Kind == "include" {
			Fields := Map("type", true, "section", true, "row_id", true)
			Section := _MR_Get(Item, "section")
			if Type(Section) != "String" || Section == ""
				|| (Item.Has("row_id") && (Type(Item["row_id"]) != "String" || Item["row_id"] == ""))
				return false
			Valid := Item.Has("row_id")
				? _MR_TemplateInertPresentation(Section, Checking, Item["row_id"])
				: _MR_TemplateInertPresentation(Section, Checking)
			if !Valid
				return false
		} else if Kind == "---" {
			Fields := Map("type", true, "platforms", true, "unavailable", true)
			if Item.Has("unavailable") && !(Item["unavailable"] == "hide")
				return false
		} else if Kind == "label" || Kind == "section_header" {
			Fields := Map("type", true, "id", true, "i18n", true, "platforms", true, "unavailable", true)
			Id := _MR_Get(Item, "id")
			Caption := _MR_Get(Item, "i18n")
			Unavailable := _MR_Get(Item, "unavailable")
			if Type(Caption) != "String" || Caption == ""
				|| (Item.Has("id") && (Type(Id) != "String" || Id == ""))
				|| (Kind == "label" && !Item.Has("id"))
				return false
			if Kind == "section_header" {
				Fields["reason_key"] := true
				if Item.Has("unavailable") && !(Unavailable == "hide") && !(Unavailable == "grey")
					return false
				if Unavailable == "grey" && !Item.Has("reason_key")
					return false
				if Item.Has("reason_key") && (Type(Item["reason_key"]) != "String" || Item["reason_key"] == "" || Unavailable == "hide")
					return false
			} else if Item.Has("unavailable") && !(Unavailable == "hide")
				return false
		} else
			return false
		for Field in Item
			if !Fields.Has(Field)
				return false
		if Item.Has("platforms") {
			Platforms := Item["platforms"]
			if !(Platforms is Array) || Platforms.Length == 0
				return false
			Seen := Map()
			Loop Platforms.Length {
				if !Platforms.Has(A_Index)
					return false
				Platform := Platforms[A_Index]
				if Type(Platform) != "String" || (!(Platform == "ahk") && !(Platform == "hs") && !(Platform == "linux")) || Seen.Has(Platform)
					return false
				Seen[Platform] := true
			}
		}
	}
	Checking.Delete(ManifestKey)
	return true
}

; Includes retain their declaration's original command readiness policy.
_MR_TemplateRows(ManifestKey, Commands, StateGetters, Children, Visiting, StatusDefinition := unset, RowId := unset) {
	Def := IsSet(StatusDefinition) ? StatusDefinition : _MR_GetMenuDef(ManifestKey)
	if IsSet(RowId) {
		Selected := false
		Matches := 0
		for Item in Def {
			if _MR_Get(Item, "id") == RowId {
				Selected := Item
				Matches += 1
			}
		}
		if Type(RowId) != "String" || RowId == "" || Matches != 1 {
			try LoggerError("MenuRenderer", "Missing or ambiguous child-template row '{1}.{2}' — rows refused.", ManifestKey, RowId)
			return false
		}
		Def := [Selected]
	}
	if Visiting.Has(ManifestKey) || Def.Length == 0 {
		try LoggerError("MenuRenderer", "Missing or cyclic child template '{1}' — provider rows refused.", ManifestKey)
		return false
	}
	Visiting[ManifestKey] := true
	Rows := []
	for Item in Def {
		if !_MR_CommandLiteralPrefix(Item, &Prefix)
			return false
		if Item.Has("caption_count_policy") && !_MR_TranslatedCountPolicy(Item)
			return false
		if !_MR_CaptionLayoutMetadata(Item) || !_MR_CaptionVectorMetadata(Item, StateGetters, _MR_IsForAhk(Item))
			|| (Item.Has("caption_format") && _MR_IsForAhk(Item) && !_MR_ReadNumberedCaption(Item, StateGetters, &NumberedCaption))
			|| (Item.Has("caption_source") && _MR_IsForAhk(Item) && !_MR_ReadNativeCaption(Item, StateGetters, &NativeCaption))
			return false
		if Item.Has("on_refusal") && _MR_Get(Item, "type") != "include" {
			try LoggerError("MenuRenderer", "Invalid presentation omission policy in '{1}' — rows refused.", ManifestKey)
			return false
		}
		if !_MR_IsForAhk(Item) && !(_MR_Get(Item, "type") == "section_header" && _MR_Get(Item, "unavailable") == "grey")
			continue
		ItemType := _MR_Get(Item, "type")
		Id := _MR_Get(Item, "id")
		if ItemType == "include" {
			Fields := Map("type", true, "section", true, "row_id", true, "present_when", true, "on_refusal", true)
			for Field in Item
				if !Fields.Has(Field)
					return false
			Section := _MR_Get(Item, "section")
			if Type(Section) != "String" || Section == ""
				return false
			Target := _MR_GetMenuDef(Section)
			Omit := Item.Has("on_refusal") && Item["on_refusal"] == "omit_presentation"
			if (Item.Has("on_refusal") && !Omit) || (!Omit && Target.Length == 0)
				return false
			if Item.Has("row_id") {
				SelectedId := Item["row_id"]
				Matches := 0
				for Child in Target
					if _MR_Get(Child, "id") == SelectedId
						Matches += 1
				if Type(SelectedId) != "String" || SelectedId == "" || Matches != 1
					return false
			}
			Present := true
			if Item.Has("present_when") {
				GetterKey := Item["present_when"]
				if Type(GetterKey) != "String" || GetterKey == "" || !StateGetters.Has(GetterKey)
					|| !HasMethod(StateGetters[GetterKey], "Call")
					return false
				try Present := StateGetters[GetterKey].Call()
				catch
					return false
				if Type(Present) != "Integer" || (Present != 0 && Present != 1)
					return false
			}
			PresentationValid := !Omit || (Item.Has("row_id")
				? _MR_TemplateInertPresentation(Section, Map(), Item["row_id"])
				: _MR_TemplateInertPresentation(Section, Map()))
			if !PresentationValid {
				try LoggerError("MenuRenderer", "Invalid inert presentation include '{1}' in '{2}' — presentation omitted.", Section, ManifestKey)
			} else if Present {
				Included := Item.Has("row_id")
					? _MR_TemplateRows(_MR_Get(Item, "section"), Commands, StateGetters, Children, Visiting, , Item["row_id"])
					: _MR_TemplateRows(_MR_Get(Item, "section"), Commands, StateGetters, Children, Visiting)
				if !(Included is Array)
					return false
				for Child in Included
					Rows.Push(Child)
			}
			continue
		}
		if ItemType == "list" {
			Fields := Map("type", true, "id", true, "platforms", true, "unavailable", true)
			for Field in Item
				if !Fields.Has(Field)
					return false
			Supplied := Children.Has(Id) ? _MR_TemplateNativeChildren(Id, Children[Id]) : false
			if !(Supplied is Array)
				return false
			for Child in Supplied
				Rows.Push(Child)
			continue
		}
		if ItemType == "---"
			Row := Map("separator", true)
		else if IsSet(StatusDefinition) && ItemType == "label"
			Row := Map("label", t(Item["i18n"]), "disabled", true)
		else if ItemType == "label" {
			Fields := Map("type", true, "id", true, "i18n", true, "platforms", true, "unavailable", true, "caption_getter", true, "caption_getters", true, "caption_layout", true, "caption_joiner", true)
			I18nKey := _MR_Get(Item, "i18n")
			Unavailable := _MR_Get(Item, "unavailable")
			Valid := Type(Id) == "String" && Id != "" && Type(I18nKey) == "String" && I18nKey != ""
				&& (!Item.Has("unavailable") || Unavailable == "hide")
			Valid := Valid && (!Item.Has("caption_getter") || (Type(Item["caption_getter"]) == "String"
				&& Item["caption_getter"] != "" && Type(Id) == "String" && Id != ""))
			for Field in Item {
				if !Fields.Has(Field)
					Valid := false
			}
			if !Valid {
				try LoggerError("MenuRenderer", "Invalid inert label in template '{1}' — provider rows refused.", ManifestKey)
				return false
			}
			Row := Map("label", t(I18nKey), "disabled", true)
		}
		else if ItemType == "section_header" {
			Fields := Map("type", true, "id", true, "i18n", true, "platforms", true,
				"unavailable", true, "reason_key", true, "caption_getter", true)
			I18nKey := _MR_Get(Item, "i18n")
			Unavailable := _MR_Get(Item, "unavailable")
			Reason := _MR_Get(Item, "reason_key")
			Valid := (!Item.Has("id") || (Type(Id) == "String" && Id != ""))
				&& Type(I18nKey) == "String" && I18nKey != ""
				&& (!Item.Has("unavailable") || Unavailable == "hide" || Unavailable == "grey")
				&& (Unavailable != "grey" || Item.Has("reason_key"))
				&& (!Item.Has("reason_key") || (Type(Reason) == "String" && Reason != ""
					&& Unavailable != "hide"))
			Valid := Valid && (!Item.Has("caption_getter") || (Type(Item["caption_getter"]) == "String"
				&& Item["caption_getter"] != "" && Type(Id) == "String" && Id != ""))
			for Field in Item {
				if !Fields.Has(Field)
					Valid := false
			}
			if !Valid {
				try LoggerError("MenuRenderer", "Invalid section header in template '{1}' — provider rows refused.", ManifestKey)
				return false
			}
			if _MR_IsForAhk(Item)
				Row := Map("label", MenuSectionTitle(t(I18nKey)), "disabled", true)
			else
				Row := Map("label", t(I18nKey) . " — " . _MR_ReasonHead(t(Reason)), "disabled", true)
		}
		else if ItemType == "command" {
			Row := MenuRenderer_CommandRow(ManifestKey, Id, Commands, StateGetters)
			if !(Row is Map)
				return false
		} else if ItemType == "check" {
			Row := MenuRenderer_CheckRow(ManifestKey, Id, Commands, StateGetters)
			if !(Row is Map)
				return false
		} else if ItemType == "group" && Children.Has(Id) && (Children[Id] is Array || HasMethod(Children[Id], "Call")) {
			Label := unset
			if Item.Has("caption_count_policy") && !_MR_ReadTranslatedCountCaption(Item, StateGetters, &Label)
				return false
			if Item.Has("caption_format") && !_MR_ReadNumberedCaption(Item, StateGetters, &Label)
				return false
			if Item.Has("caption_source") && !_MR_ReadNativeCaption(Item, StateGetters, &Label)
				return false
			if Item.Has("caption_layout") || Item.Has("caption_joiner") {
				if !_MR_ExplicitCaption(Item, StateGetters, &Label)
					return false
			}
			Items := Children[Id] is Array ? Children[Id] : _MR_TemplateNativeChildren(Id, Children[Id])
			if !(Items is Array)
				return false
			Row := Map("label", IsSet(Label) ? Label : t(_MR_Get(Item, "i18n")), "items", Items)
			if Item.Has("icon_getter") {
				IconGetter := Item["icon_getter"]
				if Type(IconGetter) != "String" || IconGetter == "" || !(StateGetters is Map)
					|| !StateGetters.Has(IconGetter) || !HasMethod(StateGetters[IconGetter], "Call")
					return false
				try Icon := StateGetters[IconGetter].Call()
				catch
					return false
				if Type(Icon) != "String"
					return false
				Row["icon"] := Icon
			}
			if Item.Has("disabled_when") && MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters) {
				Row["disabled"] := true
				if Item.Has("disabled_reason_key")
					Row["disabled_reason_key"] := Item["disabled_reason_key"]
			}
		}
		else {
			try LoggerError("MenuRenderer", "Missing child data or unsupported row in template '{1}' — provider rows refused.", ManifestKey)
			return false
		}
		if Item.Has("caption_getters") && ItemType != "command" && ItemType != "check" {
			if !_MR_ReadCaptionValues(Item, StateGetters, &Caption)
				return false
			Row["label"] := Prefix . Caption
		}
		CaptionGetter := _MR_Get(Item, "caption_getter")
		if !Item.Has("caption_format") && !Item.Has("caption_source") && CaptionGetter != "" && !((ItemType == "command" || ItemType == "group")
			&& (Item.Has("caption_layout") || Item.Has("caption_joiner"))) {
			if !StateGetters.Has(CaptionGetter) || !HasMethod(StateGetters[CaptionGetter], "Call") {
				try LoggerError("MenuRenderer", "Missing or invalid caption getter in template '{1}' — provider rows refused.", ManifestKey)
				return false
			}
			RawTitle := t(_MR_Get(Item, "i18n"))
			CaptionLayout := _MR_Get(Item, "caption_layout")
			if ItemType == "label" || ItemType == "section_header" {
				_MR_CaptionFormat(RawTitle, "", &SourceSlot)
				Valid := CaptionLayout == "" ? SourceSlot : !SourceSlot && Type(RawTitle) == "String"
					&& RawTitle != "" && RawTitle != _MR_Get(Item, "i18n")
				if !Valid {
					try LoggerError("MenuRenderer", "Invalid inert caption format in template '{1}' — provider rows refused.", ManifestKey)
					return false
				}
			}
			Value := CaptionLayout == "" ? StateGetters[CaptionGetter].Call() : ""
			Title := ItemType == "section_header" ? Row["label"] : RawTitle
			if Type(Value) != "String" {
				try LoggerError("MenuRenderer", "Invalid caption getter in template '{1}' — provider rows refused.", ManifestKey)
				return false
			}
			Caption := _MR_CaptionFormat(Title, Value, &HasSlot)
			if CaptionLayout != "" {
				if !_MR_ExplicitCaption(Item, StateGetters, &Caption, RawTitle)
					return false
				HasSlot := true
			}
			if (ItemType == "label" || ItemType == "section_header") && !HasSlot {
				try LoggerError("MenuRenderer", "Invalid inert caption format in template '{1}' — provider rows refused.", ManifestKey)
				return false
			}
			Row["label"] := Prefix . Caption
		}
		Rows.Push(Row)
	}
	Visiting.Delete(ManifestKey)
	return Rows
}

; Explicit numbered formats interpret only their original {1}; native values remain literal.
_MR_ReadNumberedCaption(Item, Getters, &Caption) {
	if _MR_Get(Item, "caption_format") != "numbered" || !InStr("|command|group|", "|" . _MR_Get(Item, "type") . "|")
		|| Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == ""
		|| Type(_MR_Get(Item, "i18n")) != "String" || _MR_Get(Item, "i18n") == ""
		|| Item.Has("caption_getters") || Item.Has("caption_source") || Item.Has("caption_layout")
		|| Item.Has("caption_joiner") || Item.Has("label_prefix") || Item.Has("reason_key")
		|| Item.Has("disabled_reason_key") || !(Getters is Map)
		return false
	Getter := _MR_Get(Item, "caption_getter")
	if Type(Getter) != "String" || Getter == "" || !Getters.Has(Getter) || !HasMethod(Getters[Getter], "Call")
		return false
	Title := t(_MR_Get(Item, "i18n"))
	if Type(Title) != "String" || Title == _MR_Get(Item, "i18n") || !InStr(Title, "{1}") || !_MR_PlainUnicodeCaption(Title)
		return false
	Remainder := StrReplace(Title, "{1}", "")
	if InStr(Remainder, "{") || InStr(Remainder, "}")
		return false
	try Value := Getters[Getter].Call()
	catch
		return false
	if Type(Value) != "String" || !_MR_PlainUnicodeCaption(Value)
		return false
	Caption := StrReplace(Title, "{1}", Value)
	return true
}

; A translated caption consumes a bounded native count, not a supplied native label.
_MR_TranslatedCountPolicy(Item) {
	if _MR_Get(Item, "type") != "group" || Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == ""
		|| Type(_MR_Get(Item, "i18n")) != "String" || _MR_Get(Item, "i18n") == ""
		return false
	for Field in ["caption_source", "caption_format", "caption_getter", "caption_getters", "caption_layout", "caption_joiner", "caption_count_getter", "caption_count_format", "label_prefix"]
		if Item.Has(Field)
			return false
	Policy := _MR_Get(Item, "caption_count_policy", false)
	if !(Policy is Map) || ObjGetBase(Policy) != Map.Prototype || Policy.Count != 6
		return false
	for Name in ObjOwnProps(Policy)
		return false
	Fields := Map("value_getter", true, "present_getter", true, "visibility", true, "style", true, "format", true, "maximum", true)
	for Field in Policy
		if !Fields.Has(Field)
			return false
	for Field in ["value_getter", "present_getter"]
		if Type(Policy[Field]) != "String" || Policy[Field] == ""
			return false
	Maximum := Policy["maximum"], Format := Policy["format"]
	if !IsNumber(Maximum) || Type(Maximum) == "String" || Maximum != Maximum || Maximum < 0 || Maximum > 2**53 - 1 || Mod(Maximum, 1) != 0
		|| Type(Format) != "String" || !_MR_PlainUnicodeCaption(Format) || !_MR_CaptionValues(Format, ["", ""], &Probe)
		return false
	for Field in ["visibility", "style"] {
		Values := Policy[Field]
		if !(Values is Map) || ObjGetBase(Values) != Map.Prototype || Values.Count != 3
			return false
		for Name in ObjOwnProps(Values)
			return false
		for Platform in ["ahk", "hs", "linux"] {
			if !Values.Has(Platform)
				return false
			Value := Values[Platform]
			if Type(Value) != "String" || (Field == "visibility" ? !(Value == "always" || Value == "available" || Value == "positive") : !(Value == "space" || Value == "decimal"))
				return false
		}
	}
	return Policy
}

_MR_ReadTranslatedCountCaption(Item, Getters, &Caption) {
	Policy := _MR_TranslatedCountPolicy(Item)
	if !Policy || !(Getters is Map)
		return false
	for Field in ["value_getter", "present_getter"]
		if !Getters.Has(Policy[Field]) || !_MR_DeclaredParentCallable(Getters[Policy[Field]])
			return false
	ValueOwner := Getters[Policy["value_getter"]], PresentOwner := Getters[Policy["present_getter"]]
	Title := t(Item["i18n"])
	if Type(Title) != "String" || Title == "" || Title == Item["i18n"] || !_MR_PlainUnicodeCaption(Title)
		return false
	try {
		if Getters[Policy["value_getter"]] != ValueOwner || Getters[Policy["present_getter"]] != PresentOwner
			|| !_MR_DeclaredParentCallable(ValueOwner) || !_MR_DeclaredParentCallable(PresentOwner)
			return false
		Total := ValueOwner.Call()
		if Getters[Policy["value_getter"]] != ValueOwner || Getters[Policy["present_getter"]] != PresentOwner
			|| !_MR_DeclaredParentCallable(ValueOwner) || !_MR_DeclaredParentCallable(PresentOwner)
			return false
		Present := PresentOwner.Call()
		if Getters[Policy["value_getter"]] != ValueOwner || Getters[Policy["present_getter"]] != PresentOwner
			|| !_MR_DeclaredParentCallable(ValueOwner) || !_MR_DeclaredParentCallable(PresentOwner)
			return false
	} catch
		return false
	if Type(Present) != "Integer" || (Present != 0 && Present != 1)
		|| !IsNumber(Total) || Type(Total) == "String" || Total != Total || Total < 0 || Total > Policy["maximum"] || Mod(Total, 1) != 0
		return false
	Visible := Policy["visibility"]["ahk"]
	if Visible != "always" && (!Present || (Visible == "positive" && Total == 0)) {
		Caption := Title
		return true
	}
	Text := Total == 0 ? "0" : Format("{:.0f}", Total)
	if Policy["style"]["ahk"] == "space" {
		Grouped := "", Length := StrLen(Text)
		loop Length {
			Position := A_Index
			Grouped .= SubStr(Text, Position, 1)
			if Position < Length && Mod(Length - Position, 3) == 0
				Grouped .= " "
		}
		Text := Grouped
	}
	return _MR_CaptionValues(Policy["format"], [Title, Text], &Caption)
}

; Record captions are native Unicode data, with kind and policy owned by the declaration.
_MR_ReadNativeCaption(Item, Getters, &Caption) {
	if _MR_Get(Item, "caption_source") != "native" || !InStr("|check|group|", "|" . _MR_Get(Item, "type") . "|")
		|| Item.Has("i18n") || Item.Has("caption_getters") || Item.Has("caption_layout") || Item.Has("caption_joiner")
		|| Item.Has("label_prefix") || Item.Has("reason_key") || Item.Has("disabled_reason_key")
		|| _MR_Get(Item, "unavailable") != "hide" || !(Getters is Map)
		return false
	Getter := _MR_Get(Item, "caption_getter")
	if Type(Getter) != "String" || Getter == "" || !Getters.Has(Getter) || !HasMethod(Getters[Getter], "Call")
		return false
	try Caption := Getters[Getter].Call()
	catch
		return false
	if Type(Caption) != "String" || Caption == "" || !_MR_PlainUnicodeCaption(Caption)
		return false
	if Item.Has("caption_count_getter") || Item.Has("caption_count_format") {
		CountGetter := _MR_Get(Item, "caption_count_getter")
		Format := _MR_Get(Item, "caption_count_format")
		if _MR_Get(Item, "type") != "group" || Type(CountGetter) != "String" || CountGetter == ""
			|| Type(Format) != "String" || !_MR_PlainUnicodeCaption(Format)
			|| !Getters.Has(CountGetter) || !HasMethod(Getters[CountGetter], "Call")
			return false
		try Count := Getters[CountGetter].Call()
		catch
			return false
		if Type(Count) != "String" || Count == "" || !_MR_PlainUnicodeCaption(Count)
			return false
		return _MR_CaptionValues(Format, [Caption, Count], &Caption)
	}
	return true
}

; Ordered getter vectors retain original translated formats and reject malformed native data.
_MR_CaptionVectorMetadata(Item, Getters, ValidateGetters := true) {
	if !Item.Has("caption_getters")
		return true
	Names := Item["caption_getters"]
	if Item.Has("caption_getter") || Item.Has("caption_source") || Item.Has("caption_layout")
		|| Item.Has("caption_joiner") || !(Names is Array) || Names.Length == 0
		|| !InStr("|command|check|group|label|", "|" . _MR_Get(Item, "type") . "|")
		|| Type(_MR_Get(Item, "i18n")) != "String" || _MR_Get(Item, "i18n") == ""
		|| Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == "" || (ValidateGetters && !(Getters is Map))
		return false
	loop Names.Length {
		if !Names.Has(A_Index)
			return false
		Name := Names[A_Index]
		if Type(Name) != "String" || Name == "" || (ValidateGetters && (!Getters.Has(Name) || !HasMethod(Getters[Name], "Call")))
			return false
	}
	return true
}

_MR_ReadCaptionValues(Item, Getters, &Caption) {
	if !_MR_CaptionVectorMetadata(Item, Getters)
		return false
	Values := []
	for Getter in Item["caption_getters"] {
		try Value := Getters[Getter].Call()
		catch
			return false
		if Type(Value) != "String"
			return false
		Values.Push(Value)
	}
	return _MR_CaptionValues(t(_MR_Get(Item, "i18n")), Values, &Caption)
}

_MR_CaptionValues(Format, Values, &Caption) {
	if Type(Format) != "String" || !(Values is Array) || Values.Length == 0
		return false
	for Value in Values
		if Type(Value) != "String"
			return false
	Caption := "", Position := 1, Argument := 1
	while Position <= StrLen(Format) {
		Character := SubStr(Format, Position, 1), Following := SubStr(Format, Position + 1, 1)
		if Character == "%" && Following == "%" {
			Caption .= "%"
			Position += 2
		} else if Character == "%" && Following == "s" {
			if Argument > Values.Length || !Values.Has(Argument)
				return false
			Caption .= Values[Argument]
			Argument += 1
			Position += 2
		} else if Character == "%"
			return false
		else {
			Caption .= Character
			Position += 1
		}
	}
	return Argument == Values.Length + 1
}

; Formats supported slots without interpreting percent bytes inside the native value.
_MR_CaptionFormat(Title, Value, &HasSlot) {
	HasSlot := false
	Caption := "", Position := 1
	while Position <= StrLen(Title) {
		Character := SubStr(Title, Position, 1), Following := SubStr(Title, Position + 1, 1)
		if Character == "%" && Following == "%" {
			Caption .= "%", Position += 2
		} else if Character == "%" && Following == "s" {
			Caption .= Value, HasSlot := true, Position += 2
		} else {
			Caption .= Character, Position += 1
		}
	}
	return Caption
}

; Shares strict native provider admission between template lists and lazy groups.
_MR_TemplateNativeChildren(Id, Provider) {
	if Type(Id) != "String" || Id == "" || !HasMethod(Provider, "Call")
		return false
	try Supplied := Provider.Call()
	catch
		return false
	if !(Supplied is Array)
		return false
	loop Supplied.Length {
		if !Supplied.Has(A_Index)
			return false
		Child := Supplied[A_Index]
		if !(Child is Map) || Child.Has("title") || Child.Has("fn") || Child.Has("menu")
			|| (Child.Has("separator") && (Type(Child["separator"]) != "Integer"
				|| (Child["separator"] != 0 && Child["separator"] != 1)))
			|| (!(Child.Has("separator") && Child["separator"] == 1)
				&& !(Child.Has("label") && Type(Child["label"]) == "String" && Child["label"] != ""))
			return false
	}
	Canonical := []
	for Child in Supplied
		Canonical.Push(Child)
	return Canonical
}

MenuRenderer_CheckRow(ManifestKey, CheckId, Commands, StateGetters := unset) {
	return _MR_DeclaredProviderRow(ManifestKey, CheckId, Commands,
		IsSet(StateGetters) ? StateGetters : Map(), "check")
}

/**
 * Appends one declared command to a menu assembled by its native owner.
 * @param {Menu} TargetMenu Native menu receiving the command.
 * @param {String} ManifestKey Canonical menu declaration.
 * @param {String} CommandId Declared command identifier.
 * @param {Map} Commands Owner callbacks indexed by command identifier.
 * @returns {Integer} Number of rows drawn.
 */
MenuRenderer_AppendCommand(TargetMenu, ManifestKey, CommandId, Commands, StateGetters := unset) {
	Item := _MR_FindItemById(ManifestKey, CommandId)
	if !(Item is Map) || _MR_Get(Item, "type") != "command" || !_MR_IsForAhk(Item)
		return 0
	return _MR_RenderCommand(TargetMenu, Item, ManifestKey, Commands, IsSet(StateGetters) ? StateGetters : Map())
}

; Renders a category's master switch as a checkbox row, in manifest order.
;
; The row is labelled by the toggle's one ``i18n`` key, ticked from its
; ``checked_when`` getters and greyed by its ``disabled_when`` ones, exactly like
; a ``check`` row, and it runs the command the caller registered under its id.
; It used to be a row whose label alternated between « ✅ … (cliquer pour
; désactiver) » and « ❌ … (cliquer pour activer) », inserted at position 1 with
; its own separator, and three builders inserted theirs by hand instead. A toggle
; with no registered command is reported and not drawn: falling back to a
; generic category flip would hide a builder that forgot the switch.
; @returns {Integer} 1 when the row was drawn, 0 otherwise.
_MR_RenderToggle(ResultMenu, Item, ManifestKey, Commands, StateGetters) {
	Row := _MR_ToggleRowData(Item, ManifestKey, Commands, StateGetters)
	if !(Row is Map)
		return 0
	Id := _MR_Get(Item, "id"), CmdId := _MR_Get(Item, "command")
	if CmdId == ""
		CmdId := Id
	if Row.Has("action") && ManifestKey == "llm_menu" && Id == "llm_toggle" && CmdId == "llm_toggle"
		Row["action"] := MenuStartupRepeatableToggleCommand(Id, Row["action"])
	return _MR_RenderRows(ResultMenu, [Row], Id, 1)
}

; Projects the category switch through its declared state and static reason.
; @returns {Map|Integer} Row data, or false when the declaration is refused.
_MR_ToggleRowData(Item, ManifestKey, Commands, StateGetters) {
	Id := _MR_Get(Item, "id")
	I18nKey := _MR_Get(Item, "i18n")
	CmdId := _MR_Get(Item, "command")
	if (CmdId == "") {
		CmdId := Id
	}
	if (Id == "" or I18nKey == "") {
		try LoggerWarn("MenuRenderer", "toggle item in '{1}' missing id or i18n — skipped.", ManifestKey)
		return false
	}
	if !(Commands is Map and Commands.Has(CmdId)) {
		try LoggerError("MenuRenderer", "No command '{1}' for the '{2}' category switch — its submenu has no way to turn it on or off.", CmdId, ManifestKey)
		return false
	}
	ReasonKey := _MR_Get(Item, "disabled_reason_key")
	if Item.Has("disabled_reason_key") && (Type(ReasonKey) != "String" || ReasonKey == "") {
		try LoggerError("MenuRenderer", "Invalid disabled reason for toggle '{1}' — skipped.", Id)
		return false
	}
	Row := Map(
		"label",   t(I18nKey),
		"action",  Commands[CmdId],
		"checked", MenuRenderer_ResolveCheckedWhen(ManifestKey, Id, StateGetters))
	if MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters) {
		Row["disabled"] := true
		if ReasonKey != "" {
			Row["disabled_reason_key"] := ReasonKey
			Row.Delete("action")
		}
	}
	return Row
}

; Renders a ``choice`` row: one setting with a fixed set of values, drawn as ONE
; row whose submenu lists the values with the current one ticked.
;
; The values and their label keys come from the row's ``choices``, which
; build-menu-manifest.js projects from the enum feature at ``path`` — a value
; added to the feature appears without a driver change. The driver supplies the
; current value through ``StateGetters[path]`` and what choosing a value does
; through ``Commands[id]``, called with that value. The shared Lua renderer
; draws the identical row. Optional show_current_choice fills {1} in the parent
; caption from its selected leaf, with no competing native label policy.
; @returns {Integer} 1 when the row was drawn, 0 otherwise.
_MR_ChoiceRowData(Item, ManifestKey, Commands, StateGetters) {
	Id := _MR_Get(Item, "id")
	I18nKey := _MR_Get(Item, "i18n")
	Path := _MR_Get(Item, "path")
	Choices := _MR_Get(Item, "choices", 0)
	CmdId := _MR_Get(Item, "command")
	if (CmdId == "") {
		CmdId := Id
	}
	if (Id == "" or I18nKey == "" or Path == "" or !(Choices is Array) or Choices.Length == 0) {
		try LoggerError("MenuRenderer", "choice item in '{1}' needs id, i18n, path and choices — skipped.", ManifestKey)
		return false
	}
	if !(Commands is Map and Commands.Has(CmdId)) {
		try LoggerError("MenuRenderer", "No command '{1}' for the '{2}.{3}' choice — skipped.", CmdId, ManifestKey, Id)
		return false
	}
	; Fails open like checked_when: no value is ticked rather than a guessed one,
	; and the drift is loud.
	Current := ""
	HasCurrent := false
	if (StateGetters is Map and StateGetters.Has(Path)) {
		Current := (StateGetters[Path])()
		HasCurrent := true
	} else {
		try LoggerError("MenuRenderer", "No getter for the '{1}' value of choice '{2}.{3}' — nothing is ticked.", Path, ManifestKey, Id)
	}
	Command := Commands[CmdId]
	Rows := []
	CurrentLabel := ""
	for Choice in Choices {
		Value := _MR_Get(Choice, "value")
		ChoiceLabel := _MR_Get(Choice, "label")
		if ChoiceLabel == ""
			ChoiceLabel := t(_MR_Get(Choice, "i18n"))
		ChoiceLabel := _MR_Get(Choice, "label_prefix") . ChoiceLabel
		if HasCurrent and Current == Value {
			CurrentI18n := _MR_Get(Choice, "current_i18n")
			CurrentLabel := CurrentI18n == "" ? ChoiceLabel : t(CurrentI18n)
		}
		Rows.Push(Map(
			"label",   ChoiceLabel,
			"checked", HasCurrent and Current == Value,
			"action",  ((V) => (*) => Command(V))(Value)))
	}
	Label := t(I18nKey) . _MR_Get(Item, "current_choice_suffix")
	if _MR_Get(Item, "show_current_choice", false) {
		if CurrentLabel == ""
			CurrentLabel := String(Current)
		Label := StrReplace(Label, _MR_Get(Item, "current_choice_placeholder", "{1}"), CurrentLabel)
	}
	Row := Map("label", Label, "items", Rows)
	if MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters) {
		Row["disabled"] := true
	}
	return Row
}

; Returns provider DATA for one published choice, using the ordinary renderer's
; label, checked-state and mutation policy. Drivers supply only native owners.
; @returns {Map|Integer} The row data, or false when the declaration is absent.
MenuRenderer_ChoiceRow(ManifestKey, RowId, Commands, StateGetters) {
	for Item in _MR_GetMenuDef(ManifestKey) {
		if (_MR_Get(Item, "type") == "choice" and _MR_Get(Item, "id") == RowId and _MR_IsForPlatform(Item, "ahk"))
			return _MR_ChoiceRowData(Item, ManifestKey, Commands, StateGetters)
	}
	try LoggerError("MenuRenderer", "Missing declared choice '{1}.{2}' — provider row refused.", ManifestKey, RowId)
	return false
}

; Draws the same declared choice DATA used by native list providers.
; @returns {Integer} The number of drawn rows.
_MR_RenderChoice(ResultMenu, Item, ManifestKey, Commands, StateGetters) {
	Row := _MR_ChoiceRowData(Item, ManifestKey, Commands, StateGetters)
	return Row is Map ? _MR_RenderRows(ResultMenu, [Row], _MR_Get(Item, "id"), 1) : 0
}

; The command every master-gated category registers for its switch: flip
; ``CategoryEnabled[Category]`` and leave the category's own rows as they are.
; The state is read at click time, not captured when the menu was built.
; @param Category {String} Master-gate category name (e.g. "Shortcuts").
; @returns {Func} The menu callback.
MenuRenderer_CategoryGateCommand(Category) {
	return (*) => ToggleCategoryAllFeatures(Category, !IsCategoryGated(Category))
}

; Renders ONE declared toggle into a menu a driver builds itself.
;
; The IA submenu is assembled natively row by row and does not go through
; MenuRenderer_Build, but its switch is still the manifest's row: the same
; label, tick and command lookup as every other category, from the same code.
; @param TargetMenu {Menu} The menu being built.
; @param ManifestKey {String} Manifest array holding the toggle (e.g. "llm_menu").
; @param ToggleId {String} The toggle row's id.
; @param Commands {Map} Command id → callback.
; @param StateGetters {Map} checked_when / disabled_when key → getter.
; @returns {Integer} 1 when the row was drawn, 0 otherwise.
MenuRenderer_AppendToggle(TargetMenu, ManifestKey, ToggleId, Commands, StateGetters) {
	Item := _MR_FindItemById(ManifestKey, ToggleId)
	if (Item == false or _MR_Get(Item, "type") != "toggle") {
		try LoggerError("MenuRenderer", "No toggle '{1}' in '{2}' — the category switch is not drawn.", ToggleId, ManifestKey)
		return 0
	}
	return _MR_RenderToggle(TargetMenu, Item, ManifestKey, Commands, StateGetters)
}

; Render a manifest-path feature toggle.
_MR_RenderFeature(ResultMenu, Item, CategoryName) {
	Path := _MR_Get(Item, "path")
	if (Path == "") {
		; Some feature entries carry only ``id`` — try constructing a plausible path.
		try LoggerWarn("MenuRenderer", "feature item has no path — skipped.")
		return
	}
	; A row carrying a ``group_label`` names a feature SECTION: it becomes one
	; submenu, titled by that label, holding every feature of the section — the
	; key-combination families of key_combinations_group (AltGrLAlt, …).
	GroupLabel := _MR_Get(Item, "group_label")
	if (GroupLabel != "") {
		GroupSub := Menu()
		for FeatureEntry in ManifestFeaturesForSection(Path) {
			MenuAddItemFromManifest(GroupSub, FeatureEntry, CategoryName . "." . GroupLabel)
		}
		ResultMenu.Add(GroupLabel, GroupSub)
		return
	}
	Entry := ManifestFindEntryByPath(Path)
	if (Entry == false) {
		try LoggerWarn("MenuRenderer", "feature path '{1}' not in manifest — skipped.", Path)
		return
	}
	MenuAddItemFromManifest(ResultMenu, Entry, CategoryName)
}

; Deletes every separator of ``TargetMenu`` that does not sit between two real
; items: a leading one, a trailing one, or the second of two in a row.
;
; The deferred "---" in MenuRenderer_Build only sees the manifest's own
; separators. Rows the driver supplies bring their own — list providers return
; separator rows — and one landing beside a manifest "---" drew two lines in a
; row under « Disposition », back when the category switch was inserted by hand
; with a separator of its own. The shared Lua renderer applies the same rule.
_MR_NormalizeSeparators(TargetMenu) {
	Count := TrayMenuItemCount(TargetMenu)
	Position := 0            ; zero-based, as TrayMenuIsSeparatorAt takes it
	PreviousWasSep := true   ; a leading separator counts as doubled
	while (Position < Count) {
		IsSep := TrayMenuIsSeparatorAt(TargetMenu, Position)
		if (IsSep and PreviousWasSep) {
			TargetMenu.Delete((Position + 1) . "&")
			Count--
			continue
		}
		PreviousWasSep := IsSep
		Position++
	}
	if (Count > 0 and PreviousWasSep) {
		TargetMenu.Delete(Count . "&")
	}
}

; The short form of a translated reason: the text before its first colon,
; ASCII or full-width, which every platform reason opens with, or the whole
; text when it has none.
_MR_ReasonHead(Text) {
	Cut := 0
	for _, Mark in [":", "："] {
		At := InStr(Text, Mark, true)
		if At && (Cut == 0 || At < Cut)
			Cut := At
	}
	return Trim(Cut ? SubStr(Text, 1, Cut - 1) : Text)
}

; Render the disabled stand-in of a row this platform has not yet ported: its
; label and the short form of its translated reason. Returns 1 once drawn.
_MR_RenderGreyedStandIn(ResultMenu, Item, ManifestKey, ResolvedLabel := unset) {
	I18nKey := _MR_Get(Item, "i18n")
	ReasonKey := _MR_Get(Item, "reason_key")
	if (I18nKey == "" or ReasonKey == "") {
		try LoggerError("MenuRenderer", "Greyed row '{1}' in '{2}' lacks its label or reason — not drawn.",
			_MR_Get(Item, "id"), ManifestKey)
		return 0
	}
	if IsSet(ResolvedLabel)
		Label := ResolvedLabel . " — " . _MR_ReasonHead(t(ReasonKey))
	else
		Label := t(I18nKey) . " — " . _MR_ReasonHead(t(ReasonKey))
	ResultMenu.Add(Label, (*) => "")
	ResultMenu.Disable(Label)
	return 1
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

/**
 * Appends one current declared group while retaining its genuine native Menu.
 * @param {Menu} TargetMenu Detached native destination.
 * @param {String} ManifestKey Current declaration owner.
 * @param {String} GroupId Declared group identity.
 * @param {Map} GroupBuilders Genuine native child builders.
 * @param {Integer} Disabled Explicit resolved greying fact, zero or one.
 * @returns {Boolean} Whether the complete parent was attached.
 */
MenuRenderer_AppendGroup(TargetMenu, ManifestKey, GroupId, GroupBuilders, Disabled := false) {
	if !(TargetMenu is Menu) || !(GroupBuilders is Map)
		|| Type(Disabled) != "Integer" || (Disabled != 0 && Disabled != 1)
		return false
	Selected := false, Matches := 0
	for Item in _MR_GetMenuDef(ManifestKey) {
		if Item is Map && _MR_IsForAhk(Item) && _MR_Get(Item, "id") == GroupId {
			Selected := Item
			Matches += 1
		}
	}
	if Matches != 1 || _MR_Get(Selected, "type") != "group"
		|| Type(_MR_Get(Selected, "i18n")) != "String" || _MR_Get(Selected, "i18n") == ""
		|| !GroupBuilders.Has(GroupId) || !HasMethod(GroupBuilders[GroupId], "Call")
		return false
	return _MR_RenderGroup(TargetMenu, Selected, "LLM", GroupBuilders, ManifestKey, "", Disabled)
}

; Render a named group submenu. A group declaring ``checked_when`` ticks its
; title from those getters, as a category's parent row shows its switch: the
; key-combinations group is checked while its own first-row switch is on.

; Plain source/container receipts retain nested identities and callback owners.
_MR_ReasonedGroupSnapshot(Value, Seen := unset) {
	if !(Value is Map) && !(Value is Array)
		return Map("value", Value)
	if ObjGetBase(Value) != (Value is Map ? Map.Prototype : Array.Prototype)
		return false
	for Name in ObjOwnProps(Value)
		return false
	Seen := IsSet(Seen) ? Seen : Map()
	Identity := ObjPtr(Value)
	if Seen.Has(Identity)
		return Seen[Identity]
	Receipt := Map("value", Value, "fields", Map(), "size", Value is Map ? Value.Count : Value.Length)
	Seen[Identity] := Receipt
	if Value is Array {
		loop Value.Length
			if !Value.Has(A_Index)
				return false
	}
	for Key, Field in Value {
		Captured := _MR_ReasonedGroupSnapshot(Field, Seen)
		if !Captured
			return false
		Receipt["fields"][Key] := Captured
	}
	return Receipt
}

; No native getter runs after this pure final receipt comparison.
_MR_ReasonedGroupCurrent(Receipt, Seen := unset) {
	if !(Receipt is Map)
		return false
	if !Receipt.Has("fields")
		return true
	Value := Receipt["value"]
	if ObjGetBase(Value) != (Value is Map ? Map.Prototype : Array.Prototype)
		return false
	for Name in ObjOwnProps(Value)
		return false
	if (Value is Map ? Value.Count : Value.Length) != Receipt["size"]
		return false
	Seen := IsSet(Seen) ? Seen : Map()
	Identity := ObjPtr(Receipt)
	if Seen.Has(Identity)
		return true
	Seen[Identity] := true
	for Key, Captured in Receipt["fields"] {
		if !Value.Has(Key) || Type(Value[Key]) != Type(Captured["value"])
			|| !(Value[Key] == Captured["value"]) || !_MR_ReasonedGroupCurrent(Captured, Seen)
			return false
	}
	return true
}

_MR_RenderGroup(ResultMenu, Item, CategoryName, GroupBuilders, ManifestKey := "", StateGetters := "", Disabled := unset) {
	if Item.Has("disabled_reason_key") {
		Root := _MR_GetManifestRoot(), SourceRows := _MR_GetMenuDef(ManifestKey)
		Source := _MR_ReasonedGroupSnapshot(SourceRows)
		States := _MR_ReasonedGroupSnapshot(StateGetters)
		Builders := _MR_ReasonedGroupSnapshot(GroupBuilders)
		if !Source || !States || !Builders
			return false
		Id := _MR_Get(Item, "id")
		Sub := GroupBuilders is Map && GroupBuilders.Has(Id)
			? GroupBuilders[Id]() : _MR_BuildBuiltinGroup(Id, CategoryName)
		if !(Sub is Menu)
			return false
		Row := MenuRenderer_GroupRow(ManifestKey, Id, Sub, StateGetters)
		if !(Row is Map) || Row["submenu"] != Sub
			return false
		if IsSet(Disabled) && Disabled
			Row["disabled"] := true
		CurrentRoot := _MR_GetManifestRoot()
		if CurrentRoot != Root || !Root.Has(ManifestKey) || Root[ManifestKey] != SourceRows
			|| !_MR_ReasonedGroupCurrent(Source) || !_MR_ReasonedGroupCurrent(States)
			|| !_MR_ReasonedGroupCurrent(Builders)
			return false
		return _MR_RenderRows(ResultMenu, [Row], ManifestKey, 1) == 1
	}

	Id    := _MR_Get(Item, "id")
	I18nKey := _MR_Get(Item, "i18n")
	if (Id == "" or (I18nKey == "" && _MR_Get(Item, "caption_source") != "native")) {
		try LoggerWarn("MenuRenderer", "group item missing id or i18n — skipped.")
		return
	}
	Label := _MR_Get(Item, "caption_source") == "native" ? "" : t(I18nKey)
	if Item.Has("caption_count_policy") && !_MR_ReadTranslatedCountCaption(Item, StateGetters, &Label)
		return false
	if Item.Has("caption_format") && !_MR_ReadNumberedCaption(Item, StateGetters, &Label)
		return false
	if Item.Has("caption_source") && !_MR_ReadNativeCaption(Item, StateGetters, &Label)
		return false
	if Item.Has("caption_getters") && !_MR_ReadCaptionValues(Item, StateGetters, &Label)
		return false
	if Item.Has("caption_layout") || Item.Has("caption_joiner") {
		if !_MR_ExplicitCaption(Item, StateGetters, &Label, Label)
			return false
	}

	; The caller-supplied builder first, else the built-in accented_letters_group.
	if (GroupBuilders is Map and GroupBuilders.Has(Id)) {
		Sub := (GroupBuilders[Id])()
	} else {
		Sub := _MR_BuildBuiltinGroup(Id, CategoryName)
	}
	if !(Sub is Menu) {
		return false
	}
	; New typed captions are literal data; preserve the native ampersand transport.
	; Existing unspecified/scalar group captions retain their prior byte behavior.
	if Item.Has("caption_source") || Item.Has("caption_getters") || Item.Has("caption_format") || Item.Has("caption_count_policy")
		Label := StrReplace(Label, "&", "&&")
	ResultMenu.Add(Label, Sub)
	if IsSet(Disabled) && Disabled
		ResultMenu.Disable(Label)
	if (_MR_Get(Item, "checked_when", 0) is Array) {
		if MenuRenderer_ResolveCheckedWhen(ManifestKey, Id, StateGetters) {
			try ResultMenu.Check(Label)
		}
	}
	return true
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
	; The list used to be hardcoded here as well as declared in the manifest,
	; so editing the manifest moved nothing and the code copy was the real source.
	; The key-combination families left this builder with their group: the
	; Shortcuts menu renders key_combinations_group, first-row switch included.
	Section := _MR_GetMenuDef(GroupId . "_group")

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

; Finds the unique item with the given ``id`` visible to the native Windows menu.
; Hidden siblings cannot decide a native caption, readiness gate or provider status.
; Returns the original item Map, or ``false`` for a missing or ambiguous owner.
_MR_FindItemById(MenuKey, ItemId) {
	if Type(MenuKey) != "String" || MenuKey == "" || Type(ItemId) != "String" || ItemId == ""
		return false
	Selected := false
	for Item in _MR_GetMenuDef(MenuKey) {
		if (Item is Map) && _MR_Get(Item, "id") == ItemId && _MR_IsForAhk(Item) {
			if Selected is Map
				return false
			Selected := Item
		}
	}
	return Selected
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

; Fills an EXISTING menu from one list row's provider, instead of returning a
; fresh Menu the way MenuRenderer_Build does.
;
; The language submenu is attached to the tray empty and populated later — its
; twenty-one locales cost ~156 ms, which is not spent on the boot path — so the
; object is already in the tray by the time its rows exist. Building a new Menu
; would leave the tray pointing at the old empty one.
;
; @param TargetMenu Menu The menu to fill (cleared first).
; @param MenuKey string Manifest key, for the log.
; @param ListId string Row id, for the log.
; @param Provider Func Returns the row array.
; @returns {Integer} Rows added.
MenuRenderer_FillFromList(TargetMenu, MenuKey, ListId, Provider) {
	global _MenuPopulationBuilding
	try TargetMenu.Delete()
	Rows := ""
	try {
		Rows := Provider()
	} catch as e {
		try LoggerError("MenuRenderer", "List '{1}.{2}' provider threw ({3}) — menu left empty.", MenuKey, ListId, e.Message)
		return 0
	}
	if _MenuPopulationBuilding is MenuPopulation && MenuPopulation_IsLeaf(Rows) {
		_MenuPopulationBuilding.Fill(TargetMenu, Rows, ListId, 1)
		return TrayMenuItemCount(TargetMenu)
	}
	return _MR_RenderRows(TargetMenu, Rows, ListId, 1)
}

; Returns a NEW menu filled from one list row's provider.
;
; The AI menu rebuilds its submenus on every open, so none of them has an
; attached object to keep: each builder used to create its own Menu and fill
; it, one direct Menu() per submenu. Creating it here keeps that platform call
; in one place.
;
; @param MenuKey string Manifest key, for the log.
; @param ListId string Row id, for the log.
; @param Provider Func Returns the row array.
; @returns {Menu} The filled menu (empty when the provider threw).
MenuRenderer_NewFromList(MenuKey, ListId, Provider) {
	Target := Menu()
	MenuRenderer_FillFromList(Target, MenuKey, ListId, Provider)
	return Target
}

/**
 * Stages one permanently disabled root presentation without building its feature.
 * The row is not a paused feature head, so resume cannot enable it later.
 * @param {Map} Entry Exact shared top-level declaration.
 */
MenuRenderer_StageDisabledTopLevel(Entry) {
	if !(Entry is Map) || Entry.Get("disabled", false) != true
		|| Type(Entry.Get("i18n", "")) != "String" || Entry.Get("i18n", "") == ""
		|| Type(Entry.Get("reason_key", "")) != "String" || Entry.Get("reason_key", "") == ""
		throw ValueError("Disabled root presentation requires its declared label and reason")
	Label := t(Entry["i18n"]) . " — " . _MR_ReasonHead(t(Entry["reason_key"]))
	TrayMenuStage_AddAction(Label, (*) => false)
	TrayMenuStage_Disable(Label)
}

; Appends row DATA to an EXISTING menu, at its current end.
;
; The third entry point, and the narrowest: unlike MenuRenderer_FillFromList it
; does not clear the target, so a caller assembling a menu in several passes can
; hand each pass over. The model picker is the case — its head rows, the curated
; catalogue and its tail rows are three separate decisions — and the catalogue
; pass has to keep its own function boundary because a regression test pins the
; call that appends it.
;
; @param TargetMenu Menu The menu to append to (left as-is otherwise).
; @param MenuKey string Manifest key, for the log.
; @param ListId string Row id, for the log.
; @param Rows array The row data.
; @returns {Integer} Rows added.
MenuRenderer_AppendRows(TargetMenu, MenuKey, ListId, Rows) {
	if (!(Rows is Array)) {
		try LoggerWarn("MenuRenderer", "List '{1}.{2}' got no row array to append — nothing added.", MenuKey, ListId)
		return 0
	}
	return _MR_RenderRows(TargetMenu, Rows, ListId, 1)
}

; Affix policy belongs only to normal declared inert labels, never status or actions.
_MR_CaptionLayoutMetadata(Item) {
	if !Item.Has("caption_layout") && !Item.Has("caption_joiner")
		return true
	if !(_MR_Get(Item, "type") == "label" || _MR_Get(Item, "type") == "command"
		|| _MR_Get(Item, "type") == "group") || !Item.Has("caption_layout") || !Item.Has("caption_joiner")
		return false
	Layout := Item["caption_layout"], Joiner := Item["caption_joiner"]
	Getter := _MR_Get(Item, "caption_getter")
	return Type(Layout) == "String" && (Layout == "prefix" || Layout == "suffix")
		&& Type(Joiner) == "String" && !RegExMatch(Joiner, "[\x00-\x1f\x7f]")
		&& Type(Getter) == "String" && Getter != ""
}

/**
 * Appends one complete shared template to its existing native Menu owner.
 * The declaration and entire provider tree are admitted before drawing. Unlike
 * Build, this preserves the owner's leading separators and nonempty target.
 * @param {Menu} TargetMenu The exact existing destination object.
 * @param {String} ManifestKey Whole canonical template identity.
 * @param {Map} Commands Existing native commands.
 * @param {Map} StateGetters Existing state and caption readers.
 * @param {Map} Children Existing child rows or declared providers.
 * @returns {Integer} Number of nonseparator rows appended, zero on refusal.
 */
MenuRenderer_AppendTemplate(TargetMenu, ManifestKey, Commands, StateGetters, Children, &Admitted := unset) {
	Admitted := false
	if !(TargetMenu is Menu) || Type(ManifestKey) != "String" || ManifestKey == ""
		return 0
	try {
		Rows := MenuRenderer_TemplateRows(ManifestKey, Commands, StateGetters, Children)
		if !_MR_AppendTemplateRowsAdmitted(Rows, 1, Map())
			return 0
	} catch {
		return 0
	}
	Admitted := true
	return _MR_RenderRows(TargetMenu, Rows, ManifestKey, 1)
}

; Pure whole-tree admission for this declared entry point, never a row-drawing
; escape hatch. Intrinsic own-name inspection precedes native container methods.
_MR_AppendTemplateRowsAdmitted(Rows, Depth, Active) {
	global MR_MAX_LIST_DEPTH
	if !(Rows is Array) || ObjGetBase(Rows) != Array.Prototype || Depth > MR_MAX_LIST_DEPTH
		return false
	for PropertyName in ObjOwnProps(Rows)
		return false
	Identity := ObjPtr(Rows)
	if Active.Has(Identity)
		return false
	Active[Identity] := true
	Fields := Map("label", true, "separator", true, "action", true, "items", true,
		"submenu", true, "checked", true, "disabled", true, "disabled_reason_key", true, "icon", true)
	loop Rows.Length {
		if !Rows.Has(A_Index)
			return false
		Row := Rows[A_Index]
		if !(Row is Map) || ObjGetBase(Row) != Map.Prototype
			return false
		for PropertyName in ObjOwnProps(Row)
			return false
		for Field in Row {
			if Type(Field) != "String" || !Fields.Has(Field)
				return false
		}
		for BooleanKey in ["separator", "checked", "disabled"] {
			if Row.Has(BooleanKey) && (Type(Row[BooleanKey]) != "Integer"
				|| (Row[BooleanKey] != 0 && Row[BooleanKey] != 1))
				return false
		}
		if Row.Has("icon") && Type(Row["icon"]) != "String"
			return false
		if Row.Has("disabled_reason_key") && Type(Row["disabled_reason_key"]) != "String"
			return false
		if Row.Has("separator") && Row["separator"] == 1 {
			if Row.Count != 1
				return false
			continue
		}
		if !Row.Has("label") || Type(Row["label"]) != "String" || Row["label"] == ""
			return false
		Variants := (Row.Has("items") ? 1 : 0) + (Row.Has("submenu") ? 1 : 0) + (Row.Has("action") ? 1 : 0)
		if Variants > 1
			return false
		if Row.Has("items") && !_MR_AppendTemplateRowsAdmitted(Row["items"], Depth + 1, Active)
			return false
		if Row.Has("submenu") && !(Row["submenu"] is Menu)
			return false
		if Row.Has("action") && !(Row["action"] is Func || Row["action"] is MenuStartupUiCommand)
			return false
	}
	Active.Delete(Identity)
	return true
}


/**
 * Captures an existing declared group before its native child producer runs.
 * The returned receiver never adopts a successor source or destination owner.
 * @param {Menu} TargetMenu Existing native destination.
 * @param {String} ManifestKey Canonical declaration owner.
 * @param {String} GroupId Unique declared parent identity.
 * @param {Menu} PreviousChild Exact child currently attached to the parent.
 * @returns {Func|false} Captured replacement receiver, or refused admission.
 */
MenuRenderer_GroupReplacement(TargetMenu, ManifestKey, GroupId, PreviousChild) {
	static EntryOwner := MenuRenderer_GroupReplacement, GroupOwner := MenuRenderer_GroupRow
	static RootOwner := _MR_GetManifestRoot, DefinitionOwner := _MR_GetMenuDef
	static SnapshotOwner := _MR_ReasonedGroupSnapshot, CurrentOwner := _MR_ReasonedGroupCurrent
	static CaptionOwner := TrayMenuItemCaption, CountOwner := TrayMenuHandleItemCount
	static ChildOwner := TrayMenuSubmenuHandle, RenderOwner := _MR_RenderRows
	static TranslationOwner := t, FieldOwner := _MR_Get, PlatformOwner := _MR_IsForAhk
	static DisabledOwner := MenuRenderer_ResolveDisabledWhen, CheckedOwner := MenuRenderer_ResolveCheckedWhen
	static DialectOwner := _MR_ReportDriverDialect, SharedRootOwner := _MM_GetManifestRoot, ItemCountOwner := TrayMenuItemCount
	static LookupOwner := _MR_FindItemById, PlatformAliasOwner := _MR_IsForPlatform
	static TranslationLookupOwner := I18nLookup, ActiveLocaleOwner := _I18nEnsureActiveLoaded
	static FallbackLocaleOwner := _I18nEnsureFallbacksLoaded
	static NativeMethods := Map("Add", Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Add").Call,
		"Enable", Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Enable").Call,
		"Uncheck", Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Uncheck").Call,
		"Check", Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Check").Call)
	NativeLive() {
		if ObjGetBase(TargetMenu) != Menu.Prototype || Object.Prototype.HasOwnProp.Call(TargetMenu, "Handle")
			|| ObjGetBase(PreviousChild) != Menu.Prototype || Object.Prototype.HasOwnProp.Call(PreviousChild, "Handle")
			return false
		for Name, Method in NativeMethods {
			if Object.Prototype.HasOwnProp.Call(TargetMenu, Name)
				|| !Object.Prototype.HasOwnProp.Call(Menu.Prototype, Name)
				|| Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, Name).Call != Method
				|| Object.Prototype.HasOwnProp.Call(Method, "Call")
				return false
		}
		return true
	}
	OwnersLive() {
		for Owner in [EntryOwner, GroupOwner, RootOwner, DefinitionOwner, SnapshotOwner,
			CurrentOwner, CaptionOwner, CountOwner, ChildOwner, RenderOwner,
			TranslationOwner, FieldOwner, PlatformOwner, DisabledOwner, CheckedOwner,
			DialectOwner, SharedRootOwner, ItemCountOwner, LookupOwner, PlatformAliasOwner,
			TranslationLookupOwner, ActiveLocaleOwner, FallbackLocaleOwner] {
			if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		}
		return EntryOwner == MenuRenderer_GroupReplacement && GroupOwner == MenuRenderer_GroupRow
			&& RootOwner == _MR_GetManifestRoot && DefinitionOwner == _MR_GetMenuDef
			&& SnapshotOwner == _MR_ReasonedGroupSnapshot && CurrentOwner == _MR_ReasonedGroupCurrent
			&& CaptionOwner == TrayMenuItemCaption && CountOwner == TrayMenuHandleItemCount
			&& ChildOwner == TrayMenuSubmenuHandle && RenderOwner == _MR_RenderRows
			&& TranslationOwner == t && FieldOwner == _MR_Get && PlatformOwner == _MR_IsForAhk
			&& DisabledOwner == MenuRenderer_ResolveDisabledWhen && CheckedOwner == MenuRenderer_ResolveCheckedWhen
			&& DialectOwner == _MR_ReportDriverDialect && SharedRootOwner == _MM_GetManifestRoot
			&& ItemCountOwner == TrayMenuItemCount && LookupOwner == _MR_FindItemById
			&& PlatformAliasOwner == _MR_IsForPlatform && TranslationLookupOwner == I18nLookup
			&& ActiveLocaleOwner == _I18nEnsureActiveLoaded && FallbackLocaleOwner == _I18nEnsureFallbacksLoaded
			&& NativeLive()
	}
	if !(TargetMenu is Menu) || !(PreviousChild is Menu) || !OwnersLive()
		|| Type(ManifestKey) != "String" || ManifestKey == ""
		|| Type(GroupId) != "String" || GroupId == ""
		return false
	Root := RootOwner.Call()
	if !OwnersLive() || !(Root is Map)
		return false
	SourceRows := DefinitionOwner.Call(ManifestKey)
	if !OwnersLive() || !Root.Has(ManifestKey) || Root[ManifestKey] != SourceRows
		return false
	Source := SnapshotOwner.Call(SourceRows)
	if !OwnersLive() || !Source
		return false
	Row := GroupOwner.Call(ManifestKey, GroupId, PreviousChild, Map())
	if !OwnersLive() || !(Row is Map) || Row.Get("submenu", false) != PreviousChild || Row.Get("disabled", false)
		return false
	Caption := Row["label"], Handle := TargetMenu.Handle, PreviousHandle := PreviousChild.Handle
	SourceLive() {
		if !OwnersLive()
			return false
		CurrentRoot := RootOwner.Call()
		if !OwnersLive() || CurrentRoot != Root || !Root.Has(ManifestKey) || Root[ManifestKey] != SourceRows
			return false
		Accepted := CurrentOwner.Call(Source)
		return OwnersLive() && (Accepted is Integer) && Accepted == 1
	}
	SlotLive() {
		if !SourceLive() || TargetMenu.Handle != Handle || PreviousChild.Handle != PreviousHandle
			return false
		Count := CountOwner.Call(Handle)
		if !SourceLive() || Count < 0
			return false
		Matches := 0, CaptionMatches := 0, Position := -1
		loop Count {
			Text := CaptionOwner.Call(TargetMenu, A_Index - 1)
			if !SourceLive()
				return false
			if Text == Caption
				CaptionMatches += 1
			ChildHandle := ChildOwner.Call(Handle, A_Index - 1)
			if !SourceLive()
				return false
			if ChildHandle == PreviousHandle {
				if Text != Caption
					return false
				Position := A_Index - 1
				Matches += 1
			}
		}
		return Matches == 1 && CaptionMatches == 1 && Position >= 0 && SourceLive()
			&& TargetMenu.Handle == Handle && PreviousChild.Handle == PreviousHandle
	}
	Publish(NativeChild) {
		if !OwnersLive() || !(NativeChild is Menu) || TargetMenu == NativeChild || PreviousChild == NativeChild
			|| ObjGetBase(NativeChild) != Menu.Prototype || Object.Prototype.HasOwnProp.Call(NativeChild, "Handle")
			return false
		PreviousCritical := Critical("On")
		try {
			if !SlotLive()
				return false
			NewRow := GroupOwner.Call(ManifestKey, GroupId, NativeChild, Map())
			if !SourceLive() || !(NewRow is Map) || NewRow.Get("submenu", false) != NativeChild
				|| NewRow.Get("label", "") != Caption || NewRow.Get("disabled", false) || !SlotLive()
				return false
			if RenderOwner.Call(TargetMenu, [NewRow], ManifestKey, 1) != 1
				return false
			TargetMenu.Enable(Caption)
			if !NewRow.Get("checked", false)
				TargetMenu.Uncheck(Caption)
			return true
		} finally Critical(PreviousCritical)
	}
	return SlotLive() ? Publish : false
}
