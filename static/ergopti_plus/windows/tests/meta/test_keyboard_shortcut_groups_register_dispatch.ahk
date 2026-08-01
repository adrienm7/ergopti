; tests/meta/test_keyboard_shortcut_groups_register_dispatch.ahk

; ==============================================================================
; MODULE: Keyboard-Shortcut Groups RegisterMenuItem Dispatch Meta Test
; DESCRIPTION:
; Regression guard for HIGH-04: raw GMenu.Add drops menu clicks.
;
; InsertKeyboardShortcutGroups built the keyboard-shortcut group submenus with
; raw GMenu.Add(Label, Callback) for the per-slot picker and the add-slot item.
; AHK 2.0's WM_COMMAND -> menu-callback dispatch silently drops roughly one
; click in three. infra/menu_dispatcher.ahk installs a parallel WM_COMMAND retry
; path, but ONLY for items registered via RegisterMenuItem(MenuObj, Label, Cb).
;
; Since these items used raw .Add, they were never in the retry path and ~30-50%
; of clicks on a slot picker or the add-slot entry silently did nothing.
;
; The fix swaps both raw GMenu.Add calls for RegisterMenuItem(GMenu, ...),
; keeping the lambda closures identical. The parent TargetMenu.Insert calls stay
; raw — those are the sanctioned exceptions. This test asserts RegisterMenuItem
; is used and no raw GMenu.Add wires the slot/add-slot pickers.
;
; SCOPE: source introspection of ErgoptiPlus.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_KSGRD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_KSGRD_GroupsUseRegisterMenuItem() {
	Body := _DriverFuncBody("InsertKeyboardShortcutGroups")
	Assert(Body != "", "InsertKeyboardShortcutGroups must exist in ErgoptiPlus.ahk")

	Assert(InStr(Body, "RegisterMenuItem(GMenu") > 0,
		"InsertKeyboardShortcutGroups must register group items via RegisterMenuItem(GMenu, ...) (HIGH-04)")
	Assert(!RegExMatch(Body, "GMenu\.Add\([^)]*ShowKeyboardShortcutPicker"),
		"InsertKeyboardShortcutGroups must NOT use raw GMenu.Add for the slot picker — use RegisterMenuItem (HIGH-04)")
	Assert(!RegExMatch(Body, "GMenu\.Add\([^)]*ShowKeyboardSlotPicker"),
		"InsertKeyboardShortcutGroups must NOT use raw GMenu.Add for the add-slot item — use RegisterMenuItem (HIGH-04)")
}
Test("meta keyboard-shortcut-groups: InsertKeyboardShortcutGroups uses RegisterMenuItem (HIGH-04)", _KSGRD_GroupsUseRegisterMenuItem)
