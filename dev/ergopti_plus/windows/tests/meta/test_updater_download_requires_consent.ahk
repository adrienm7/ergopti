; tests/meta/test_updater_download_requires_consent.ahk

; ==============================================================================
; MODULE: Updater downloads start only from an explicit consent
; DESCRIPTION:
; The updater may check for releases in the background and on demand, but it
; must download only after the user explicitly chose to install. A "Check for
; updates" click used to download, swap and restart on a newer release at once
; (updater-consent-2026-09-25). Two consent points remain: the update prompt's
; Install button, and the tray row that already names the release it installs
; ("Update to vX", the "available" state of Updater_OneClickUpdate).
; ==============================================================================

#Requires AutoHotkey v2.0

; Calls of Callee in Body; a definition line ("Name(...) {") is not a call.
_UDRC_CountCalls(Body, Callee) {
	Count := 0
	Position := 1
	while (Found := RegExMatch(Body, "m)(?<![\w.])" . Callee . "\((?!.*\)\s*\{\s*$)", &Match, Position)) {
		Count++
		Position := Found + Match.Len
	}
	return Count
}

_UDRC_DownloadStartsOnlyFromConsent() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "the driver source must be readable")
	Code := _DriverMaskNonCode(&Src)
	Total := _UDRC_CountCalls(Code, "Updater_DownloadAndInstall")
	Prompt := _DriverFuncBody("_Updater_InstallPromptRelease")
	Activate := _DriverFuncBody("_Updater_ActivateCachedRelease")
	Assert(Prompt != "" && Activate != "", "both consent points must exist")
	AssertEqual(1, _UDRC_CountCalls(Prompt, "Updater_DownloadAndInstall"),
		"the prompt's Install button must start the download")
	AssertEqual(1, _UDRC_CountCalls(Activate, "Updater_DownloadAndInstall"),
		"the named 'Update to vX' row must start the download")
	AssertEqual(2, Total,
		"no other code may start an update download: a check must stop at the consent prompt")

	Publish := _DriverFuncBody("_Updater_PublishOneClickRelease")
	Assert(Publish != "", "_Updater_PublishOneClickRelease must exist")
	Assert(_UDRC_CountCalls(Publish, "Updater_ShowUpdatePrompt") > 0,
		"a check that finds a newer release must open the consent prompt")
	AssertEqual(0, _UDRC_CountCalls(Publish, "_Updater_ActivateCachedRelease"),
		"a check must never activate the release it found")
	AssertEqual(1, _UDRC_CountCalls(Code, "_Updater_ActivateCachedRelease"),
		"only the named 'Update to vX' row may activate a cached release")
}
Test("updater: a download starts only from an explicit consent (updater-consent-2026-09-25)",
	_UDRC_DownloadStartsOnlyFromConsent)
