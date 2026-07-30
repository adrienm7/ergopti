; ui/menu/menu_shortcuts.ahk

; ==============================================================================
; MODULE: Tray Menu / Shortcuts Submenu
; DESCRIPTION:
; Builds the Shortcuts category: personal shortcuts, script-control entries, extension shortcuts, the edit action and the surrounding-symbols (wrap) editor with its custom-pair CRUD.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; v1 group id -> v2 manifest section path for the three Shortcuts sub-Maps
; (AltGrLAlt / AltGrCapsLock / LAltCapsLock). Each sub-Map renders as a
; sub-submenu of 10 plain-bool toggles. The label of each sub-submenu in
; the legacy render was the raw v1 key (e.g. "AltGrLAlt") because the
; sub-Maps carried no ``__Label`` metadata — preserved verbatim here so
; the manifest path is visually identical.
global _SHORTCUTS_SUBMAP_V1V2 := Map(
	"AltGrLAlt",     "ahk.shortcuts.alt_gr_lalt",
	"AltGrCapsLock", "ahk.shortcuts.alt_gr_caps_lock",
	"LAltCapsLock",  "ahk.shortcuts.lalt_caps_lock",
)

; Build the Shortcuts submenu from the manifest-driven renderer.
; Dynamic handlers supply the platform-specific blocks (personal shortcuts,
; script control, extensions, edit action) that cannot be described in JSON.
_BuildShortcutsSubmenu() {
	DynHandlers := Map(
		"personal_shortcuts",         (M, C) => _SC_Personal(M, C),
		"script_control_shortcuts",   (M, C) => _SC_ScriptControl(M, C),
		"extensions_shortcuts",       (M, C) => _SC_Extensions(M, C),
		"edit_shortcuts",             (M, C) => _SC_EditAction(M, C),
		"wrap_symbols_menu",          (M, C) => _SC_WrapSymbols(M, C),
	)

	return MenuRenderer_Build("shortcuts_menu", "Shortcuts", DynHandlers)
}

; Dynamic handler: personal shortcuts submenu (if any registered).
; Emits its own leading separator when items are present, matching pre-refactor behaviour.
_SC_Personal(SubMenu, _Cat) {
	_AppendPersonalShortcutsSubmenuIfAny(SubMenu)
}

; Dynamic handler: script control shortcuts submenu.
_SC_ScriptControl(SubMenu, _Cat) {
	SubMenu.Add(t("menu.shortcuts.script_shortcuts"), BuildScriptShortcutsMenu())
}

; Dynamic handler: extensions shortcuts submenus.
_SC_Extensions(SubMenu, _Cat) {
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
	if !HasExtShortcuts {
		return false
	}
	SubMenu.Add()
	ExtShortcutsHeader := MenuSectionTitle(t("menu.extensions.header"))
	SubMenu.Add(ExtShortcutsHeader, (*) => NoAction())
	SubMenu.Disable(ExtShortcutsHeader)
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
				ErrLabel := t("common.error_prefix") . ExtId
				ExtMenu.Add(ErrLabel, (*) => NoAction())
				ExtMenu.Disable(ErrLabel)
			}
		} else {
			LoggerWarn("Extensions", "No BuildExtMenu_{1} function found — menu.ahk not loaded?", StrReplace(ExtId, "-", "_"))
			NaLabel := t("menu.extensions.empty")
			ExtMenu.Add(NaLabel, (*) => NoAction())
			ExtMenu.Disable(NaLabel)
		}
		SubMenu.Add(ExtName, ExtMenu)
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

; Dynamic handler: edit personal shortcuts action button.
_SC_EditAction(SubMenu, _Cat) {
	RegisterMenuItem(SubMenu, t("menu.global.edit_shortcuts"), OpenPersonalShortcuts)
}

; Dynamic handler: wrap-symbols submenu (toggles per built-in symbol + custom pairs).
; Attached as an indented sub-item directly below the wrap_text_if_selected feature row.
_SC_WrapSymbols(SubMenu, _Cat) {
	Sub := _WS_BuildSymbolsMenu()
	SubMenu.Add(t("menu.shortcuts.wrap_symbols_title"), Sub)
}

; Build the full wrap-symbols menu (called by _SC_WrapSymbols and on every initMenu refresh).
_WS_BuildSymbolsMenu() {
	global _WS_BUILTIN_GROUPS, _WS_Custom
	Sub := Menu()

	; ── Global bulk actions ──────────────────────────────────────────────────
	RegisterMenuItem(Sub, t("menu.shortcuts.wrap_symbols_check_all"), (*) => _WS_MenuSetAll(true))
	RegisterMenuItem(Sub, t("menu.shortcuts.wrap_symbols_uncheck_all"), (*) => _WS_MenuSetAll(false))
	RegisterMenuItem(Sub, t("menu.global.reset_defaults"), (*) => _WS_MenuReset())
	Sub.Add()

	; ── Built-in symbols, one named nested sub-submenu per group ──────────────
	; Each group from the shared catalogue becomes its own sub-submenu (titled by
	; its i18n label) so the top-level list stays short. Every group sub-submenu
	; carries its own « check all / uncheck all » so the user can flip a whole
	; family at once. Order and grouping come from _shared/modules/wrap_symbols/wrap_symbols.json.
	for _, Group in _WS_BUILTIN_GROUPS {
		GroupMenu := Menu()
		; Collect this group's opening chars for the per-group bulk actions.
		GroupLefts := []
		for _, Pair in Group["pairs"] {
			GroupLefts.Push(Pair["left"])
		}
		RegisterMenuItem(GroupMenu, t("menu.shortcuts.wrap_symbols_check_all"),
			((Chars) => (*) => _WS_MenuSetGroup(Chars, true))(GroupLefts))
		RegisterMenuItem(GroupMenu, t("menu.shortcuts.wrap_symbols_uncheck_all"),
			((Chars) => (*) => _WS_MenuSetGroup(Chars, false))(GroupLefts))
		GroupMenu.Add()
		; Track whether every symbol in the group is enabled so the parent item
		; can show a checkmark when the whole family is on.
		GroupAllOn := true
		for _, Pair in Group["pairs"] {
			L := Pair["left"]
			R := Pair["right"]
			; Display label: "( … )" for asymmetric, "@" for symmetric
			Lbl := (L != R) ? (L . " … " . R) : L
			Enabled := WrapSymbols_IsEnabled(L)
			; Capture L in closure so the lambda references the right char
			RegisterMenuItem(GroupMenu, Lbl, ((Ch) => (*) => _WS_MenuToggle(Ch))(L))
			if Enabled {
				GroupMenu.Check(Lbl)
			} else {
				GroupAllOn := false
			}
		}
		GroupLabel := (Group["i18n"] != "") ? t(Group["i18n"]) : t("menu.shortcuts.wrap_symbols_title")
		Sub.Add(GroupLabel, GroupMenu)
		; Check the parent group item when all of its symbols are enabled.
		if GroupAllOn {
			Sub.Check(GroupLabel)
		}
	}

	; ── Custom symbols ───────────────────────────────────────────────────────
	if (_WS_Custom.Length > 0) {
		Sub.Add()
		for Idx, Pair in _WS_Custom {
			L := Pair["left"]
			R := Pair["right"]
			Lbl := ((L != R) ? (L . " … " . R) : L) . " — " . t("menu.shortcuts.wrap_symbols_custom_label")
			DelSub := Menu()
			RegisterMenuItem(DelSub, t("button.delete"), ((I) => (*) => _WS_MenuRemoveCustom(I))(Idx))
			Sub.Add(Lbl, DelSub)
			Sub.Check(Lbl)
		}
	}

	; ── Add custom ───────────────────────────────────────────────────────────
	Sub.Add()
	RegisterMenuItem(Sub, t("menu.shortcuts.wrap_symbols_add_custom"), (*) => _WS_MenuAddCustom())

	return Sub
}

; Toggle a built-in symbol and refresh the tray.
_WS_MenuToggle(OpenChar) {
	WrapSymbols_Toggle(OpenChar)
	RebuildTrayMenu()
}

; Enable or disable all built-in symbols, then refresh.
_WS_MenuSetAll(Enable) {
	if Enable {
		WrapSymbols_EnableAll()
	} else {
		WrapSymbols_DisableAll()
	}
	RebuildTrayMenu()
}

; Enable or disable every symbol in one group at once, then refresh.
_WS_MenuSetGroup(OpenChars, Enable) {
	WrapSymbols_SetMany(OpenChars, Enable)
	RebuildTrayMenu()
}

; Reset to factory defaults, then refresh.
_WS_MenuReset() {
	WrapSymbols_Reset()
	RebuildTrayMenu()
}

; Remove a custom symbol pair (1-based index), then refresh.
_WS_MenuRemoveCustom(Idx) {
	WrapSymbols_RemoveCustom(Idx)
	RebuildTrayMenu()
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

	WrapSymbols_AddCustom(LeftChar, RightChar)
	RebuildTrayMenu()
}

