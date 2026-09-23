; tests/meta/test_updater_prompt_uses_shared_notes.ahk

; ==============================================================================
; MODULE: Update Prompt Uses The Shared Notes Page (Meta Test)
; DESCRIPTION:
; The Windows update prompt rendered release notes with a third Markdown
; renderer, _Updater_MakeMarkdownHtml: an HTML string built in AHK, parsed by
; innerHTML, that turned any https link or image into live markup and showed
; the CI changelog fold as literal <details> text after the download tables.
; The prompt now loads the shared release-notes page (_shared/ui/release_notes/),
; which renders through the same splitter and DOM-only renderer as the Versions
; window. These guards keep the retired renderer from coming back and pin the
; prompt to the shared page. The WebView2 wiring cannot run headless, so the
; checks read source; the behaviour behind them is covered by
; tests/unit/test_updater_release_notes.ahk and the JS page tests.
; ==============================================================================

#Requires AutoHotkey v2.0

_UPSN_RetiredRendererIsGone() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/updater"))
	Assert(StrLen(Src) > 10000, "modules/updater source must be readable for this meta-test")
	for _, Retired in ["_Updater_MakeMarkdownHtml", "innerHTML", "NavigateToString("]
		Assert(InStr(Src, Retired) = 0,
			"modules/updater must not use " . Retired . " again: release notes render through the shared page")
}
Test("updater: the AHK-built Markdown page is retired (release-notes-shared-page)", _UPSN_RetiredRendererIsGone)

_UPSN_PromptLoadsTheSharedPage() {
	Prompt := _DriverFuncBody("Updater_ShowUpdatePrompt")
	Navigate := _DriverFuncBody("_Updater_NavigateReleaseNotes")
	PageUrl := _DriverFuncBody("_Updater_ReleaseNotesUrl")
	Assert(Prompt != "" && Navigate != "" && PageUrl != "",
		"the prompt, its notes navigator and the page URL helper must exist")
	Assert(InStr(Prompt, "_Updater_NavigateReleaseNotes(WVC, Release)") > 0,
		"the WebView2 notes pane must load the shared release-notes page")
	Assert(InStr(Prompt, "_Updater_ReleaseNotesToPlain(Release.Body)") > 0,
		"the native notes fallback must show the plain-text changelog section")
	Assert(InStr(Navigate, "SetVirtualHostNameToFolderMapping(") > 0
		&& InStr(Navigate, "_Updater_ReleaseNotesSeed(") > 0
		&& InStr(Navigate, "WebMessageReceived(") > 0,
		"the navigator must map the shared tree, seed the body and bind the link bridge")
	Assert(InStr(PageUrl, "/ui/release_notes/index.html") > 0,
		"the pane must navigate to _shared/ui/release_notes/index.html")
	global _SharedDir
	Assert(FileExist(_SharedDir . "\ui\release_notes\index.html") != "",
		"the shared release-notes page must exist")
}
Test("updater: the update prompt loads the shared release-notes page (release-notes-shared-page)",
	_UPSN_PromptLoadsTheSharedPage)

_UPSN_SubscriptionReleasedBeforeClose() {
	Body := _DriverFuncBody("_Updater_CloseGui")
	Assert(Body != "", "_Updater_CloseGui must exist")
	Release := InStr(Body, "G.WVSub := 0")
	Close := InStr(Body, "G.WVC.Close()")
	Assert(Release > 0 && Close > Release,
		"the notes bridge subscription must be released while its controller is still alive")
}
Test("updater: the notes bridge is released before its controller closes (release-notes-shared-page)",
	_UPSN_SubscriptionReleasedBeforeClose)
