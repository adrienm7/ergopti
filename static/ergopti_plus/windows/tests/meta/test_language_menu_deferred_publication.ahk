; tests/meta/test_language_menu_deferred_publication.ahk

; A deferred language submenu used to be attached empty then populated in place.
; A click in that window was silently lost. The placeholder must be disabled and
; the fully built Menu published and enabled together.

#Requires AutoHotkey v2.0

_LMDP_DeferredLanguageMenuIsPublishedAtomically() {
	Deferred := _DriverFuncBody("BuildLanguageMenuDeferred")
	Assert(Deferred != "", "BuildLanguageMenuDeferred must exist")
	Assert(InStr(Deferred, "StagedMenu := Menu()") > 0 and InStr(Deferred, "I18nBuildLanguageMenu(StagedMenu)") > 0,
		"BuildLanguageMenuDeferred must populate a detached Menu before publishing it")
	Assert(InStr(Deferred, 'A_TrayMenu.Add(t("menu.global.language"), StagedMenu)') > 0,
		"BuildLanguageMenuDeferred must replace the placeholder with the complete staged submenu")
	Assert(InStr(Deferred, 'A_TrayMenu.Enable(t("menu.global.language"))') > 0,
		"BuildLanguageMenuDeferred must enable the row only after the complete submenu is published")
	Tail := _DriverFuncBody("_MI_AppendTail")
	Assert(Tail != "", "_MI_AppendTail must exist")
	Assert(InStr(Tail, 'A_TrayMenu.Disable(t("menu.global.language"))') > 0,
		"the deferred language placeholder must be disabled so an early click is not silently lost")
}
Test("tray language: deferred submenu is staged before it becomes clickable (language-menu-deferred-publication)", _LMDP_DeferredLanguageMenuIsPublishedAtomically)
