; ui/menu/menu_shortcuts.ahk

; ==============================================================================
; MODULE: Tray Menu / Shortcuts Submenu
; DESCRIPTION:
; Builds the Shortcuts category: personal shortcuts, script-control entries, extension shortcuts, the edit action and the surrounding-symbols (wrap) editor with its custom-pair CRUD.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; The key combinations are the manifest's ``key_combinations_group``: its own
; first-row switch, then one row per ordered pair of tap-hold keys, in two
; lists (the hand of the key held first) supplied as data by
; KeyCombinationRows (infra/key_combinations.ahk).

; Build the Shortcuts submenu from the manifest-driven renderer.
; Dynamic handlers supply the platform-specific blocks (personal shortcuts,
; script control, extensions, edit action) that cannot be described in JSON.
_BuildShortcutsSubmenu() {
	DynHandlers := Map()
	DeclaredFrames := Map("personal_shortcuts", Map(
		"manifest_key", "personal_shortcuts_frame",
		"children_id", "personal_shortcuts_registered",
		"provider", _PersonalShortcutRows))

	; The keyboard slots are a list, not a group: their rows are the user's own
	; assignments, so the manifest can name the section but not enumerate it. The
	; provider returns row DATA and the renderer draws it — which is also what
	; ended the Menu.Insert splice that used to duplicate the groups on every
	; updater-driven tray refresh
	ListProviders := Map(
		"keyboard_slots",             () => KeyboardSlotRows(),
		; The number-row tap keys: labels read live from the layout in use.
		"tap_keys",                   () => TapKeyRows(),
		"wrap_symbols_menu",          () => _SC_WrapSymbolRows(),
		; extensions_shortcuts left DynHandlers on 2026-08-07: its manifest row is
		; `type = "list"` now, so the renderer draws the separator, the header and
		; one row per extension from this data.
		"extensions_shortcuts",       () => _SC_ExtensionRows(),
	)

	; `command` rows: a static label, a click, and the renderer builds the row.
	; The category switch is one of them: the Shortcuts master gate.
	Commands := _SC_ScopeCommands()
	Getters := _SC_Getters()

	GroupBuilders := Map(
		"key_combinations", () => _SC_KeyCombinationsSubmenu(),
		"script_control",   () => _SC_ScriptControlSubmenu())

	return MenuRenderer_Build("shortcuts_menu", "Shortcuts", DynHandlers, GroupBuilders, ListProviders, Commands, Getters, , , DeclaredFrames)
}

; The checked_when getters of the Shortcuts submenu: its switch, and the ticks
; of the key-combinations and script-control group titles.
_SC_Getters() {
	return Map(
		"shortcuts_enabled", () => IsCategoryGated("Shortcuts"),
		"key_combinations_enabled", () => IsCategoryGated("KeyCombinations"),
		"script_control_enabled", () => ScriptShortcutChordsAreOn())
}

; The « Combinaisons de touches » group: its own first-row switch (the
; KeyCombinations gate, independent of Shortcuts), then one submenu per first
; key listing the pairs it begins, all declared by key_combinations_group.
_SC_KeyCombinationsSubmenu(Options := unset) {
	Commands := _SC_KeyCombinationCommands(IsSet(Options) ? Options : Map())
	Getters := Map("key_combinations_enabled", () => IsCategoryGated("KeyCombinations"))
	ListProviders := Map(
		"key_combination_rows_left", () => KeyCombinationRows("left"),
		"key_combination_rows_right", () => KeyCombinationRows("right"))
	return MenuRenderer_Build("key_combinations_group", "Shortcuts", "", "", ListProviders, Commands, Getters)
}

; Shared group commands use the combination owner, not the whole Shortcuts scope.
_SC_KeyCombinationCommands(Options := unset) {
	OwnedOptions := IsSet(Options) ? Options : Map()
	return Map(
		"key_combinations_toggle", MenuRenderer_CategoryGateCommand("KeyCombinations"),
		"scope_restore", (*) => KeyCombinationsApplyScope("recommended", OwnedOptions),
		"scope_clear", (*) => KeyCombinationsApplyScope("clear", OwnedOptions))
}

; « Raccourcis de gestion du script », declared by script_control_group: its
; switch, the restore of its preset, the clear to the system's behaviour, then
; one row per slot. Its title in the Shortcuts submenu is ticked while the
; switch is on (checked_when), which only the switch row can change.
; @param Options {Map} Scope ports for tests; the real config otherwise.
_SC_ScriptControlSubmenu(Options := unset) {
	Getters := Map("script_control_enabled", () => ScriptShortcutChordsAreOn())
	ListProviders := Map("script_control_shortcuts", () => ScriptShortcutRows())
	return MenuRenderer_Build("script_control_group", "Shortcuts", "", "", ListProviders,
		_SC_ScriptControlCommands(IsSet(Options) ? Options : Map()), Getters)
}

; The commands of script_control_group's first rows. The restore and the clear
; apply at once, like every scope row: their owner backs up first. Options are
; the scope ports ("path", "reload"...) plus "toggle_reload", the switch's own
; reload, for tests.
_SC_ScriptControlCommands(Options := unset) {
	OwnedOptions := IsSet(Options) ? Options : Map()
	return Map(
		"script_control_toggle", (*) => SetScriptShortcutChordsOn(!ScriptShortcutChordsAreOn(),
			OwnedOptions.Get("path", ""), OwnedOptions.Get("toggle_reload", 0)),
		"scope_restore", (*) => ScriptShortcutsApplyScope("recommended", OwnedOptions),
		"scope_clear", (*) => ScriptShortcutsApplyScope("clear", OwnedOptions))
}

; Dynamic handler: extensions shortcuts submenus.
; List provider: one row per installed extension that ships shortcuts/menu.ahk,
; behind its own separator and section header. `list` since 2026-08-07 — the row
; SHAPE is the renderer's now; the submenu hanging off each extension is still
; the native Menu its builder populates, handed over as `submenu`.
_SC_ExtensionRows() {
	global _ExtensionsDir
	ExtShortcutsBaseDir := _ExtensionsDir . "\"
	HasExtShortcuts := false
	if DirExist(ExtShortcutsBaseDir) {
		Loop Files ExtShortcutsBaseDir . "*", "D" {
			MenuAhkPath := A_LoopFileFullPath . "\shortcuts\menu.ahk"
			if FileExist(MenuAhkPath) {
				HasExtShortcuts := true
				break
			}
		}
	}
	Rows := []
	if !HasExtShortcuts {
		return Rows
	}
	BoundaryRows := MenuRenderer_TemplateRows("shortcut_extension_boundary", Map(), Map(), Map())
	if !(BoundaryRows is Array)
		return []
	for Row in BoundaryRows
		Rows.Push(Row)
	OwnedMenus := [], Completed := false
	try {
		Loop Files ExtShortcutsBaseDir . "*", "D" {
			ExtId       := A_LoopFileName
			ExtDir      := A_LoopFileFullPath
			MenuAhkPath := ExtDir . "\shortcuts\menu.ahk"
			if !FileExist(MenuAhkPath)
				continue
			ExtName      := ExtId
			ManifestPath := ExtDir . "\manifest.toml"
			if FileExist(ManifestPath) {
				try {
					MC := FileRead(ManifestPath, "UTF-8")
					if RegExMatch(MC, 'name\s*=\s*"([^"]+)"', &NM)
						ExtName := NM[1]
				}
			}
			MarkerState := Map("shortcut_extension_name", (*) => ExtId)
			; Admit both possible complete markers before native allocation or builders.
			ErrorRows := MenuRenderer_TemplateRows("shortcut_extension_error_frame", Map(), MarkerState, Map())
			EmptyRows := MenuRenderer_TemplateRows("shortcut_extension_empty_frame", Map(), Map(), Map())
			if !(ErrorRows is Array) || ErrorRows.Length == 0
					|| !_MR_AppendTemplateRowsAdmitted(ErrorRows, 1, Map())
					|| !(EmptyRows is Array) || EmptyRows.Length == 0
					|| !_MR_AppendTemplateRowsAdmitted(EmptyRows, 1, Map())
				return []
			ExtMenu := Menu()
			OwnedMenus.Push(ExtMenu)
			BuilderFn := "BuildExtMenu_" . StrReplace(ExtId, "-", "_")
			if IsSet(%BuilderFn%) and HasMethod(%BuilderFn%) {
				BuildFailed := false
				try {
					%BuilderFn%(ExtMenu, ExtName)
				} catch as Err {
					; A broken bundled extension is user-actionable, so fail LOUD:
					; ERROR (not a Warn the user never reads) plus a visible disabled
					; row in the submenu so a crashed builder is not indistinguishable
					; from an absent one.
					LoggerError("Extensions", "BuildExtMenu for '{1}' threw: {2}.", ExtId, Err.Message)
					BuildFailed := true
				}
				; Even a builder that returns without throwing may have populated
				; nothing (bad TOML, missing global) — an empty submenu is just as
				; opaque, so surface the same marker.
				if (BuildFailed or _ExtMenuItemCount(ExtMenu) == 0) {
					if !BuildFailed
						LoggerError("Extensions", "BuildExtMenu for '{1}' added no items — extension menu is empty.", ExtId)
					; A label and nothing else: the renderer draws it inert and greyed,
					; which is exactly what a marker is.
					if MenuRenderer_AppendTemplate(ExtMenu, "shortcut_extension_error_frame", Map(), MarkerState, Map()) == 0
						throw Error("Shortcut extension error marker was withdrawn during its native builder")
				}
			} else {
				LoggerWarn("Extensions", "No BuildExtMenu_{1} function found — menu.ahk not loaded?", StrReplace(ExtId, "-", "_"))
				if MenuRenderer_AppendTemplate(ExtMenu, "shortcut_extension_empty_frame", Map(), Map(), Map()) == 0
					throw Error("Shortcut extension empty marker was withdrawn before publication")
			}
			Rows.Push(Map("label", ExtName, "submenu", ExtMenu))
		}
		Completed := true
	} finally {
		if !Completed
			_SC_ExtensionDisposeOwnedMenus(OwnedMenus)
	}
	return Rows
}


; These are exactly the top-level menus allocated above. External builders may
; attach borrowed children: their reachability is not an ownership receipt.
; Delete detaches them; the existing dispatcher preserves their live callbacks.
_SC_ExtensionDisposeOwnedMenus(OwnedMenus) {
	for OwnedMenu in OwnedMenus {
		try {
			OwnedMenu.Delete()
		} catch as CleanupError {
			try LoggerError("Extensions", "Owned extension menu cleanup failed: {1}.", CleanupError.Message)
		} finally {
			try MenuDispatcher_PruneMenu(OwnedMenu)
		}
	}
}

; Returns how many items a Menu currently holds, via its native HMENU. Used to
; tell a builder that populated nothing from one that succeeded. Returns 0 if the
; handle is unavailable so the caller treats an inaccessible menu as empty (and
; thus shows the error marker) rather than silently passing it through.
_ExtMenuItemCount(MenuObj) {
	try {
		HMENU := MenuObj.Handle
		if (HMENU)
			return DllCall("GetMenuItemCount", "ptr", HMENU, "int")
	}
	return 0
}

; Dynamic handler: wrap-symbols submenu (toggles per built-in symbol + custom pairs).
; Attached as an indented sub-item directly below the wrap_text_if_selected feature row.
; List provider: the wrap-symbol picker, as a ROW.
;
; The manifest called this row Windows-only until 2026-08-06 — and macOS and
; Linux had both been drawing it all along, in a different place each. It is one
; shared `list` row now; the tree behind it is still this driver's native Menu,
; handed over through the renderer's `submenu` field.
_SC_WrapSymbolRows() {
	Rows := MenuRenderer_TemplateRows("shortcut_wrap_frame", Map(), Map(),
		Map("shortcut_wrap_symbols_ahk", _WS_BuildSymbolRows))
	return Rows is Array ? Rows : []
}

; The wrap-symbols tree, as row DATA.
;
; The manifest called this row Windows-only until 2026-08-06 — and macOS and
; Linux had both been drawing it all along, in a different place each. It became
; one shared `list` row then, but the tree behind it was still a native Menu
; handed over through the renderer's `submenu` field, so every level of it was
; assembled here. Since 2026-08-07 the renderer builds all of it: nested groups
; are `items`, and the driver supplies labels, ticks and callbacks.
_WS_BuildSymbolRows() {
	global _WS_BUILTIN_GROUPS, _WS_Custom
	Getters := Map("wrap_symbols_ready", (*) => true)
	Rows := MenuRenderer_TemplateRows("wrap_symbols_global_controls", Map(
		"wrap_symbols_enable_all", (*) => _WS_MenuSetAll(true),
		"wrap_symbols_disable_all", (*) => _WS_MenuSetAll(false),
		"wrap_symbols_restore", (*) => _WS_MenuReset()), Getters, Map())
	if !(Rows is Array)
		return []

	; ── Built-in symbols, one named nested group per family ──────────────────
	; Order and grouping come from _shared/modules/wrap_symbols/wrap_symbols.json.
	; Each group carries its own « check all / uncheck all » so a whole family can
	; be flipped at once, and the parent row ticks when every symbol in it is on.
	for _, Group in _WS_BUILTIN_GROUPS {
		GroupLefts := []
		for _, Pair in Group["pairs"] {
			GroupLefts.Push(Pair["left"])
		}
		GroupRows := MenuRenderer_TemplateRows("wrap_symbols_group_controls", Map(
			"wrap_symbols_enable_group", _WS_ControlSetGroup.Bind(GroupLefts, true),
			"wrap_symbols_disable_group", _WS_ControlSetGroup.Bind(GroupLefts, false)), Getters, Map())
		if !(GroupRows is Array)
			return []

		GroupAllOn := true
		for _, Pair in Group["pairs"] {
			L := Pair["left"]
			R := Pair["right"]
			; Display label: "( … )" for asymmetric, "@" for symmetric
			Lbl := (L != R) ? (L . " … " . R) : L
			Enabled := WrapSymbols_IsEnabled(L)
			; Capture L in the closure so the lambda references the right char
			GroupRows.Push(Map("label", Lbl, "checked", Enabled,
				"action", ((Ch) => (*) => _WS_MenuToggle(Ch))(L)))
			if !Enabled {
				GroupAllOn := false
			}
		}
		GroupLabel := (Group["i18n"] != "") ? t(Group["i18n"]) : t("menu.shortcuts.wrap_symbols_title")
		Rows.Push(Map("label", GroupLabel, "checked", GroupAllOn, "items", GroupRows))
	}

	; ── Custom symbols ───────────────────────────────────────────────────────
	if (_WS_Custom.Length > 0) {
		CustomSeparator := MenuRenderer_TemplateRows("wrap_symbols_custom_separator", Map(), Getters, Map())
		if !(CustomSeparator is Array)
			return []
		for _, Row in CustomSeparator
			Rows.Push(Row)
		for Idx, Pair in _WS_Custom {
			L := Pair["left"]
			R := Pair["right"]
			Lbl := ((L != R) ? (L . " … " . R) : L) . " — " . t("menu.shortcuts.wrap_symbols_custom_label")
			CustomControls := MenuRenderer_TemplateRows("wrap_symbols_custom_controls", Map(
				"wrap_symbols_delete_custom", _WS_ControlRemoveCustom.Bind(Idx)), Getters, Map())
			if !(CustomControls is Array)
				return []
			Rows.Push(Map("label", Lbl, "checked", true, "items", CustomControls))
		}
	}

	; ── Add custom ───────────────────────────────────────────────────────────
	AddControls := MenuRenderer_TemplateRows("wrap_symbols_add_controls", Map(
		"wrap_symbols_add_custom", (*) => _WS_MenuAddCustom()), Getters, Map())
	if !(AddControls is Array)
		return []
	for _, Row in AddControls
		Rows.Push(Row)

	return Rows
}

; Native callbacks capture payloads with Bind and discard menu-event arguments.
_WS_ControlSetGroup(OpenChars, Enable, *) {
	return _WS_MenuSetGroup(OpenChars, Enable)
}

_WS_ControlRemoveCustom(Idx, *) {
	return _WS_MenuRemoveCustom(Idx)
}

; Rebuild only after a strictly acknowledged durable wrap-symbol commit. A
; refused writer, replace or final authorization must leave the visible tray
; projection unchanged instead of advertising a state that never committed.
_WS_MenuRebuildAfterCommit(Committed, RebuildFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; A caller may wrap the menu callback itself. Tray construction can be
		; expensive and must remain interruptible even after persistence returns.
		Critical("Off")
		try return _WS_MenuRebuildAfterCommit(Committed, RebuildFn)
		finally Critical(InheritedCritical)
	}
	if !(Committed is Integer) || Committed != 1
		return false
	try Rebuilt := HasMethod(RebuildFn, "Call")
		? RebuildFn.Call() : RebuildTrayMenu()
	catch as Err {
		try LoggerError("WrapSymbols",
			"Could not rebuild the tray after the durable wrap-symbol commit: {1}.",
			Err.Message)
		return false
	}
	if !(Rebuilt is Integer) || Rebuilt != 1 {
		try LoggerError("WrapSymbols",
			"The tray rebuild refused the durable wrap-symbol projection.")
		return false
	}
	return 1
}

; Toggle a built-in symbol and refresh the tray after durable publication.
_WS_MenuToggle(OpenChar, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0,
		RebuildFn := 0) {
	Committed := WrapSymbols_Toggle(OpenChar, WriterFn, ReplaceFn, DeleteFn)
	return _WS_MenuRebuildAfterCommit(Committed, RebuildFn)
}

; Enable or disable all built-in symbols, then refresh.
_WS_MenuSetAll(Enable, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0,
		RebuildFn := 0) {
	if Enable {
		Committed := WrapSymbols_EnableAll(WriterFn, ReplaceFn, DeleteFn)
	} else {
		Committed := WrapSymbols_DisableAll(WriterFn, ReplaceFn, DeleteFn)
	}
	return _WS_MenuRebuildAfterCommit(Committed, RebuildFn)
}

; Enable or disable every symbol in one group at once, then refresh.
_WS_MenuSetGroup(OpenChars, Enable, WriterFn := 0, ReplaceFn := 0,
		DeleteFn := 0, RebuildFn := 0) {
	Committed := WrapSymbols_SetMany(OpenChars, Enable,
		WriterFn, ReplaceFn, DeleteFn)
	return _WS_MenuRebuildAfterCommit(Committed, RebuildFn)
}

; Reset to factory defaults, then refresh.
_WS_MenuReset(WriterFn := 0, ReplaceFn := 0, DeleteFn := 0,
		RebuildFn := 0) {
	Committed := WrapSymbols_Reset(WriterFn, ReplaceFn, DeleteFn)
	return _WS_MenuRebuildAfterCommit(Committed, RebuildFn)
}

; Remove a custom symbol pair (1-based index), then refresh.
_WS_MenuRemoveCustom(Idx, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0,
		RebuildFn := 0) {
	Committed := WrapSymbols_RemoveCustom(Idx,
		WriterFn, ReplaceFn, DeleteFn)
	return _WS_MenuRebuildAfterCommit(Committed, RebuildFn)
}

; Open a two-step GUI dialog to add a custom wrap-symbol pair.
_WS_MenuAddCustom() {
	; Step 1 — opening character
	IB1 := Ui_InputBox(t("dialog.shortcuts.wrap_symbol_prompt"), t("dialog.shortcuts.wrap_symbol_title"), "w360 h140")
	if (IB1.Result != "OK") {
		return
	}
	LeftChar := Trim(IB1.Value, " `t")
	if (StrLen(LeftChar) != 1) {
		Ui_MsgBox(t("dialog.shortcuts.wrap_symbol_invalid"), t("dialog.shortcuts.wrap_symbol_title"), "Icon!")
		return
	}

	; Step 2 — closing character (optional — empty means symmetric)
	IB2 := Ui_InputBox(t("dialog.shortcuts.wrap_symbol_close_prompt"), t("dialog.shortcuts.wrap_symbol_close_title"), "w360 h140")
	if (IB2.Result != "OK") {
		return
	}
	RightChar := Trim(IB2.Value, " `t")
	if (RightChar != "" and StrLen(RightChar) != 1) {
		Ui_MsgBox(t("dialog.shortcuts.wrap_symbol_invalid"), t("dialog.shortcuts.wrap_symbol_close_title"), "Icon!")
		return
	}
	if (RightChar == "") {
		RightChar := LeftChar
	}

	Committed := WrapSymbols_AddCustom(LeftChar, RightChar)
	return _WS_MenuRebuildAfterCommit(Committed)
}

; Bind real inventories at click time, inside the admitted configuration builder.
_SC_ScopeCommands(Options := unset) {
	OwnedOptions := IsSet(Options) ? Options : Map()
	return Map(
		"shortcuts_toggle", MenuRenderer_CategoryGateCommand("Shortcuts"),
		"edit_shortcuts", OpenPersonalShortcuts,
		"scope_restore", (*) => _SC_ApplyScope("recommended", OwnedOptions),
		"scope_clear", (*) => _SC_ApplyScope("clear", OwnedOptions))
}

_SC_ApplyScope(Mode, Options) {
	CandidateOptions := Options.Clone()
	CandidateOptions["supplement"] := ConfigIOShortcutScopeOperations
	Providers := Map("personal", PersonalShortcutScopePaths, "parameters", ConfigScopeActionParameterPaths)
	return ConfigScopeApply("shortcuts", Mode, Providers, CandidateOptions)
}
