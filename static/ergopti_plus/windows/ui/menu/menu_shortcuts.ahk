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




; The three Shortcuts sub-Maps (AltGrLAlt / AltGrCapsLock / LAltCapsLock) now
; live in the manifest's ``modifier_combos_group`` section, one entry per
; sub-submenu carrying its section path and its ``group_label``. They used to be
; a Map here as well, which made the manifest section decorative: nothing read
; it, so adding a fourth combo there changed nothing until someone also edited
; this file. The sub-submenu label is still the raw v1 key, as the legacy render
; had it — those are key names (AltGr, LAlt, CapsLock), identical in every
; locale, so they carry no i18n key.

; Build the Shortcuts submenu from the manifest-driven renderer.
; Dynamic handlers supply the platform-specific blocks (personal shortcuts,
; script control, extensions, edit action) that cannot be described in JSON.
_BuildShortcutsSubmenu() {
	DynHandlers := Map(
		"personal_shortcuts",         (M, C) => _SC_Personal(M, C),
	)

	; The keyboard slots are a list, not a group: their rows are the user's own
	; assignments, so the manifest can name the section but not enumerate it. The
	; provider returns row DATA and the renderer draws it — which is also what
	; ended the Menu.Insert splice that used to duplicate the groups on every
	; updater-driven tray refresh
	ListProviders := Map(
		"script_control_shortcuts",   () => _SC_ScriptControlRows(),
		"keyboard_slots",             () => KeyboardSlotRows(),
		"wrap_symbols_menu",          () => _SC_WrapSymbolRows(),
		; extensions_shortcuts left DynHandlers on 2026-08-07: its manifest row is
		; `type = "list"` now, so the renderer draws the separator, the header and
		; one row per extension from this data.
		"extensions_shortcuts",       () => _SC_ExtensionRows(),
	)

	; `command` rows: a static label, a click, and the renderer builds the row.
	Commands := Map(
		"edit_shortcuts", OpenPersonalShortcuts
	)

	return MenuRenderer_Build("shortcuts_menu", "Shortcuts", DynHandlers, "", ListProviders, Commands)
}

; Dynamic handler: personal shortcuts submenu (if any registered).
; Emits its own leading separator when items are present, matching pre-refactor behaviour.
_SC_Personal(SubMenu, _Cat) {
	_AppendPersonalShortcutsSubmenuIfAny(SubMenu)
}

; List provider: the script-control shortcuts submenu, as one row.
;
; A `list` of one rather than a `dynamic` handler: the label is static and the
; tree below it is built by another subsystem, which is precisely what `submenu`
; is for. The renderer draws the row.
_SC_ScriptControlRows() {
	return [Map(
		"label",   t("menu.shortcuts.script_shortcuts"),
		"submenu", BuildScriptShortcutsMenu())]
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
	Rows.Push(Map("separator", true))
	Rows.Push(Map("label", MenuSectionTitle(t("menu.extensions.header")), "disabled", true))
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
		ExtMenu   := Menu()
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
				MenuRenderer_AppendRows(ExtMenu, "shortcuts_menu", "extensions_shortcuts",
					[Map("label", t("common.error_prefix") . ExtId)])
			}
		} else {
			LoggerWarn("Extensions", "No BuildExtMenu_{1} function found — menu.ahk not loaded?", StrReplace(ExtId, "-", "_"))
			MenuRenderer_AppendRows(ExtMenu, "shortcuts_menu", "extensions_shortcuts",
				[Map("label", t("menu.extensions.empty"))])
		}
		Rows.Push(Map("label", ExtName, "submenu", ExtMenu))
	}
	return Rows
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
	return [Map(
		"label", t("menu.shortcuts.wrap_symbols_title"),
		"items", _WS_BuildSymbolRows())]
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
	Rows := []

	; ── Global bulk actions ──────────────────────────────────────────────────
	Rows.Push(Map("label", t("menu.shortcuts.wrap_symbols_check_all"),
		"action", (*) => _WS_MenuSetAll(true)))
	Rows.Push(Map("label", t("menu.shortcuts.wrap_symbols_uncheck_all"),
		"action", (*) => _WS_MenuSetAll(false)))
	Rows.Push(Map("label", t("menu.global.reset_defaults"),
		"action", (*) => _WS_MenuReset()))
	Rows.Push(Map("separator", true))

	; ── Built-in symbols, one named nested group per family ──────────────────
	; Order and grouping come from _shared/modules/wrap_symbols/wrap_symbols.json.
	; Each group carries its own « check all / uncheck all » so a whole family can
	; be flipped at once, and the parent row ticks when every symbol in it is on.
	for _, Group in _WS_BUILTIN_GROUPS {
		GroupRows := []
		GroupLefts := []
		for _, Pair in Group["pairs"] {
			GroupLefts.Push(Pair["left"])
		}
		GroupRows.Push(Map("label", t("menu.shortcuts.wrap_symbols_check_all"),
			"action", ((Chars) => (*) => _WS_MenuSetGroup(Chars, true))(GroupLefts)))
		GroupRows.Push(Map("label", t("menu.shortcuts.wrap_symbols_uncheck_all"),
			"action", ((Chars) => (*) => _WS_MenuSetGroup(Chars, false))(GroupLefts)))
		GroupRows.Push(Map("separator", true))

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
		Rows.Push(Map("separator", true))
		for Idx, Pair in _WS_Custom {
			L := Pair["left"]
			R := Pair["right"]
			Lbl := ((L != R) ? (L . " … " . R) : L) . " — " . t("menu.shortcuts.wrap_symbols_custom_label")
			Rows.Push(Map("label", Lbl, "checked", true, "items", [
				Map("label", t("button.delete"), "action", ((I) => (*) => _WS_MenuRemoveCustom(I))(Idx))
			]))
		}
	}

	; ── Add custom ───────────────────────────────────────────────────────────
	Rows.Push(Map("separator", true))
	Rows.Push(Map("label", t("menu.shortcuts.wrap_symbols_add_custom"),
		"action", (*) => _WS_MenuAddCustom()))

	return Rows
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
	IB1 := InputBox(t("dialog.shortcuts.wrap_symbol_prompt"), t("dialog.shortcuts.wrap_symbol_title"), "w360 h140")
	if (IB1.Result != "OK") {
		return
	}
	LeftChar := Trim(IB1.Value, " `t")
	if (StrLen(LeftChar) != 1) {
		MsgBox(t("dialog.shortcuts.wrap_symbol_invalid"), t("dialog.shortcuts.wrap_symbol_title"), "Icon!")
		return
	}

	; Step 2 — closing character (optional — empty means symmetric)
	IB2 := InputBox(t("dialog.shortcuts.wrap_symbol_close_prompt"), t("dialog.shortcuts.wrap_symbol_close_title"), "w360 h140")
	if (IB2.Result != "OK") {
		return
	}
	RightChar := Trim(IB2.Value, " `t")
	if (RightChar != "" and StrLen(RightChar) != 1) {
		MsgBox(t("dialog.shortcuts.wrap_symbol_invalid"), t("dialog.shortcuts.wrap_symbol_close_title"), "Icon!")
		return
	}
	if (RightChar == "") {
		RightChar := LeftChar
	}

	Committed := WrapSymbols_AddCustom(LeftChar, RightChar)
	return _WS_MenuRebuildAfterCommit(Committed)
}
