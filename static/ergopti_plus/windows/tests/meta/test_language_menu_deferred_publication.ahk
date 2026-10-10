; tests/meta/test_language_menu_deferred_publication.ahk

; A deferred language submenu used to be attached empty then populated in place.
; A click in that window was silently lost. The placeholder must be disabled and
; the fully built Menu published and enabled together.

#Requires AutoHotkey v2.0

_LMDP_DeferredLanguageMenuIsPublishedAtomically() {
	Deferred := _DriverFuncBody("BuildLanguageMenuDeferred")
	Assert(Deferred != "", "BuildLanguageMenuDeferred must exist")
	Assert(InStr(Deferred, "StagedMenu := Menu()") > 0 and InStr(Deferred, "BuilderOwner.Call(StagedMenu)") > 0,
		"BuildLanguageMenuDeferred must populate a detached Menu before publishing it")
	Assert(InStr(Deferred, 'ReplacementOwner.Call(Destination, "top_level", "language", PreviousChild)') > 0,
		"BuildLanguageMenuDeferred must replace the placeholder with the complete staged submenu")
	Publisher := _DriverFuncBody("MenuRenderer_GroupReplacement")
	Assert(Publisher != "", "the declared group replacement owner must exist")
	RenderAt := InStr(Publisher, 'RenderOwner.Call(TargetMenu, [NewRow]')
	EnableAt := InStr(Publisher, 'TargetMenu.Enable(Caption)')
	Assert(RenderAt > 0 && EnableAt > RenderAt,
		"BuildLanguageMenuDeferred must enable the row only after the complete submenu is published")
	CaptureAt := InStr(Deferred, 'ReplacementOwner.Call(Destination, "top_level", "language", PreviousChild)')
	ProduceAt := InStr(Deferred, 'BuilderOwner.Call(StagedMenu)')
	Assert(CaptureAt > 0 && ProduceAt > CaptureAt,
		"the exact current parent cohort must be captured before native locale production can yield")
	Assert(InStr(Deferred, 'A_TrayMenu != Destination') > 0 && InStr(Deferred, '_LangMenuRef != PreviousChild') > 0
		&& InStr(Deferred, '_I18nLocale != Locale') > 0,
		"a completed old language child cannot adopt refreshed globals or a successor locale")
	Tail := _DriverFuncBody("_MI_StageLanguage")
	Assert(Tail != "", "_MI_StageLanguage must exist")
	Assert(InStr(Tail, 'TrayMenuStage_Disable(t("menu.global.language"))') > 0,
		"the deferred language placeholder must be disabled so an early click is not silently lost")
}
Test("tray language: deferred submenu is staged before it becomes clickable (language-menu-deferred-publication)", _LMDP_DeferredLanguageMenuIsPublishedAtomically)
