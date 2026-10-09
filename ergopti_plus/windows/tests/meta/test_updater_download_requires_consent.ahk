; tests/meta/test_updater_download_requires_consent.ahk

; ==============================================================================
; MODULE: Updater downloads start only from an explicit consent
; DESCRIPTION:
; The updater may check for releases in the background and on demand, but it
; must download only after the user explicitly chose to install. A "Check for
; updates" click used to download, swap and restart on a newer release at once
; (updater-consent-2026-09-25). Explicit consent points are the update prompt's
; Install button, the tray row that already names the release it installs
; ("Update to vX", the "available" state of Updater_OneClickUpdate), the
; update-check window's Update button, and the native/shared Versions windows'
; explicit Install buttons. The latter first back up the configuration and
; reach the download through their observed-install ports.
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

; Every audited caller must remain present, and no other caller is admitted.
_UDRC_OnlyAuditedDownloadCalls(Code, Bodies) {
	Audited := 0
	for _, Body in Bodies {
		Calls := _UDRC_CountCalls(Body, "Updater_DownloadAndInstall")
		if (Calls != 1)
			return false
		Audited += Calls
	}
	return Audited == _UDRC_CountCalls(Code, "Updater_DownloadAndInstall")
}

_UDRC_ConsentCensusRejectsUnauditedCalls() {
	Call := "Updater_DownloadAndInstall(Release, Request)"
	AssertTrue(_UDRC_OnlyAuditedDownloadCalls(Call . "`n" . Call, [Call, Call]),
		"all audited consent paths are accepted")
	AssertFalse(_UDRC_OnlyAuditedDownloadCalls(Call . "`n" . Call . "`n" . Call, [Call, Call]),
		"an extra background download cannot disappear behind an updated census")
	AssertFalse(_UDRC_OnlyAuditedDownloadCalls(Call, [Call, ""]),
		"a missing consent path cannot leave the guard vacuous")
}
Test("updater: consent census rejects an extra download and a missing caller",
	_UDRC_ConsentCensusRejectsUnauditedCalls)

_UDRC_DownloadStartsOnlyFromConsent() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "the driver source must be readable")
	Code := _DriverMaskNonCode(&Src)
	Bodies := []
	for Name in ["_Updater_InstallPromptRelease", "_Updater_ActivateCachedRelease",
		"_Updater_StartObservedInstall", "_CLW_StartUpdatePath"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", "the audited consent caller must exist: " . Name)
		Bodies.Push(Body)
	}
	Prompt := _DriverFuncBody("_Updater_InstallPromptRelease")
	Activate := _DriverFuncBody("_Updater_ActivateCachedRelease")
	Assert(Prompt != "" && Activate != "", "both consent points must exist")
	AssertEqual(1, _UDRC_CountCalls(Prompt, "Updater_DownloadAndInstall"),
		"the prompt's Install button must start the download")
	AssertEqual(1, _UDRC_CountCalls(Activate, "Updater_DownloadAndInstall"),
		"the named 'Update to vX' row must start the download")
	AssertTrue(_UDRC_OnlyAuditedDownloadCalls(Code, Bodies),
		"only the four audited consent ports may start a download; checks stop before consent")
	AssertEqual(2, _UDRC_CountCalls(Code, "_Updater_StartObservedInstall"),
		"only the native Versions install port and exact terminal click retry may start an observed update")
	AssertEqual(1, _UDRC_CountCalls(_DriverFuncBody("_Updater_RetryManagedFailure"), "_Updater_StartObservedInstall"),
		"only the exact current failed staging intent may enter the retry port")
	AssertEqual(1, _UDRC_CountCalls(_DriverFuncBody("_Updater_InstallChosenRelease"), "_Updater_StartObservedInstall"),
		"the native Versions install button owns the observed update port")
	AssertEqual(1, _UDRC_CountCalls(Code, "_CLW_StartUpdatePath"),
		"only the shared Versions window's install port may start its observed update")
	AssertEqual(1, _UDRC_CountCalls(_DriverFuncBody("_CLW_InstallDeps"), "_CLW_StartUpdatePath"),
		"the shared Versions window owns its observed update port")

	Publish := _DriverFuncBody("_Updater_PublishOneClickRelease")
	Assert(Publish != "", "_Updater_PublishOneClickRelease must exist")
	Assert(_UDRC_CountCalls(Publish, "UpdateCheck_ShowAvailable") > 0,
		"a check that finds a newer release must offer it in the update-check window")
	AssertEqual(0, _UDRC_CountCalls(Publish, "_Updater_ActivateCachedRelease"),
		"a check must never activate the release it found")
	Install := _DriverFuncBody("_UpdateCheck_Install")
	AssertEqual(1, _UDRC_CountCalls(Install, "_Updater_ActivateCachedRelease"),
		"the update-check window's Update button activates the release it shows")
	AssertEqual(2, _UDRC_CountCalls(Code, "_Updater_ActivateCachedRelease"),
		"only the named 'Update to vX' row and the window's Update button may activate a cached release")
}
Test("updater: a download starts only from an explicit consent (updater-consent-2026-09-25)",
	_UDRC_DownloadStartsOnlyFromConsent)
