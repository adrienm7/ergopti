; modules/updater/changelog.ahk

; ==============================================================================
; MODULE: Updater / Menu Actions + Changelog UI
; DESCRIPTION:
; The dynamic update menu state and label, one-click update flow, version dialog, the native changelog window, and the release notes shown by the update prompt (the shared release-notes page, or the plain-text changelog section when WebView2 is off).
;
; Split out of modules/updater.ahk (the module split); see modules/updater.ahk for the module
; overview. Functions and globals are hoisted, so load order across the
; updater/*.ahk files is irrelevant.
; ==============================================================================



; ====================================
; ===== 1.5) Menu actions =============
; ====================================

; Tracks whether a background check is currently in progress, to disable the
; menu item and avoid overlapping WinHttp calls.
global _UpdaterCheckInProgress := false
global _UpdaterDownloadInProgress := false

; Returns a symbol indicating the current update state:
;   "checking"    — a check is running right now (disable menu item)
;   "downloading" — an asset is downloading right now (disable menu item)
;   "available"   — a newer version is cached from a previous check
;   "idle"        — no cached update, ready to check
Updater_GetUpdateState() {
	global _UpdaterCheckInProgress, _UpdaterDownloadInProgress, UPDATER_LATEST_RELEASE
	if _UpdaterDownloadInProgress
		return "downloading"
	if _UpdaterCheckInProgress
		return "checking"
	if IsSet(UPDATER_LATEST_RELEASE) and Type(UPDATER_LATEST_RELEASE) == "Object"
		return "available"
	return "idle"
}

; Returns the localised label for the one-click update menu item.
; Callers rebuild the menu after any state change so this is always fresh.
Updater_GetUpdateMenuLabel() {
	State := Updater_GetUpdateState()
	if (State == "checking")
		return t("menu.about.update_checking")
	if (State == "downloading")
		return t("menu.about.update_downloading")
	if (State == "available") {
		global UPDATER_LATEST_RELEASE
		Tag := UPDATER_LATEST_RELEASE.HasProp("Tag") ? UPDATER_LATEST_RELEASE.Tag : ""
		; The catalogue names this placeholder {tag} (shared with Linux), and
		; Format() fills numbered placeholders only.
		if (Tag != "")
			return StrReplace(t("menu.about.update_now"), "{tag}", Tag)
	}
	return t("menu.about.check_for_updates")
}

; One-click update entry point wired to the dynamic tray menu item.
;
; State machine:
;   idle      → open the update-check window ("checking"), fetch the list,
;               compare, cache if newer, rebuild menu, then show the answer in
;               the window: the row read "Check for updates", so nothing is
;               downloaded before the window's Update button
;   available → install from cache: the row itself named the release
;               ("Update to vX"), so the click is the user's consent
;   checking  → no-op (item is disabled in the menu, but guard here too)
;
; The item is always enabled when state == "idle" or "available"; disabled when
; "checking". A single click therefore always does the right thing.
Updater_OneClickUpdate(*) {
	global UPDATER_CHANNEL, UPDATER_LATEST_RELEASE, _UpdaterCheckInProgress
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if A_IsSuspended
		return _Updater_RefuseManualWhileSuspended()
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return
	if Updater_IsLocalSource()
		return
	State := Updater_GetUpdateState()
	if (State == "checking" or State == "downloading")
		return

	; The row named the cached release ("Update to vX"): install it.
	if (State == "available") {
		_Updater_ActivateCachedRelease(UPDATER_LATEST_RELEASE, Request)
		return
	}

	; Slow path: need to check first. Mark in-progress and rebuild the menu so the
	; item shows "Vérification…" and is disabled while the network call runs.
	_UpdaterCheckInProgress := true
	_Updater_ScheduleMenuRebuildForRequest(Request)

	Current := Updater_CurrentVersion()
	try LoggerStart("Updater", "One-click update check (channel: {1}, current: {2})…", UPDATER_CHANNEL, Current)
	
	; The answer is shown in the update-check window, never in a tray balloon
	UpdateCheck_Begin(Request, Current)
	_Updater_FetchLatestJsonAsync(UPDATER_CHANNEL, Request,
		(Json, CompletedRequest, Terminal := 0) => _Updater_OneClickUpdateCallback(
			Json, Current, CompletedRequest, Terminal))
}

_Updater_OneClickUpdateCallback(Json, Current, Request, Terminal := 0) {
	global _UpdaterCheckInProgress
	_UpdaterCheckInProgress := false
	; Physical menu state must be reconciled even when the result is discarded
	; during Suspend; otherwise the row remains permanently disabled as
	; “checking” after resume.
	_Updater_ScheduleMenuRebuildForRequest(Request)

	if !_Updater_RequestMayPublish(Request) {
		try LoggerDone("Updater", "One-click update check cancelled at a suspend boundary.")
		UpdateCheck_Abandon(Request)
		return
	}
	if _Updater_AsyncTerminalIsCancelled(Terminal) {
		try LoggerDone("Updater", "One-click update check cancelled ({1}).", Terminal.Reason)
		UpdateCheck_Abandon(Request)
		return
	}

	Others := _Updater_RequestOtherChannels(Request)
	if _Updater_JsonPayloadIsFailure(Json) {
		try LoggerWarn("Updater", "One-click check: network unreachable.")
		try LoggerDone("Updater", "One-click update check finished without a network response.")
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return UpdateCheck_Abandon(Request)
		UpdateCheck_ShowResult(Request, Map("state", "error", "current", Current,
			"reason", "no_connection", "detail", "GitHub could not be reached",
			"network_report", Request.HasOwnProp("NetworkFailureReport") ? Request.NetworkFailureReport : 0))
		return
	}
	if _Updater_JsonIsNoChannelRelease(Json) {
		try LoggerDone("Updater", "One-click update check: no release on channel {1} yet.", Request.Channel)
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return UpdateCheck_Abandon(Request)
		UpdateCheck_ShowResult(Request, Map("state", "no_release", "current", Current, "others", Others))
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "") {
		try LoggerWarn("Updater", "One-click check: tag parse failed.")
		try LoggerDone("Updater", "One-click update check finished with invalid release metadata.")
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return UpdateCheck_Abandon(Request)
		UpdateCheck_ShowResult(Request, Map("state", "error", "current", Current,
			"reason", "parse_failed", "detail", "the latest release names no tag"))
		return
	}
	if !UpdateChannels_ShouldOffer(
		Latest, Current, Request.Channel, _Updater_InstalledChannel()) {
		try LoggerSuccess("Updater", "One-click check: already up to date ({1}).", Current)
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return UpdateCheck_Abandon(Request)
		UpdateCheck_ShowResult(Request, Map("state", "up_to_date", "current", Current,
			"latest", Latest, "others", Others))
		return
	}

	Release := {
		Tag:         Latest,
		Body:        Updater_ParseBody(Json),
		RawJson:     Json,
		HtmlUrl:     _Updater_ParseHtmlUrl(Json),
		PublishedAt: _Updater_ParsePublishedAt(Json),
		Prerelease:  _Updater_ParsePrerelease(Json)
	}
	if !_Updater_PublishOneClickRelease(Release, Request)
		try LoggerDone("Updater", "One-click update check completed without offering the release.")
}

; Publish a release that a "Check for updates" click found and offer it in the
; update-check window. The user asked to check, not to install: the download
; starts only from the window's Update button.
; @param OfferFn {Func} Test seam called as (Release, Request); production
;        shows it with UpdateCheck_ShowAvailable.
; @return {Boolean} True when the release was published and offered.
_Updater_PublishOneClickRelease(Release, Request, IsSuspended := unset, RebuildFn := 0, NotifyFn := 0, OfferFn := 0) {
	HasSuspendOverride := IsSet(IsSuspended)
	if HasSuspendOverride {
		if !_Updater_TryPublishRelease(Request, Release, IsSuspended)
			return false
	} else if !_Updater_TryPublishRelease(Request, Release) {
		return false
	}
	if IsObject(RebuildFn)
		RebuildFn.Call()
	else
		_Updater_ScheduleMenuRebuildForRequest(Request)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	try LoggerInfo("Updater", "One-click check: new version {1} found — offering it before any download.", Release.Tag)
	if IsObject(OfferFn)
		OfferFn.Call(Release, Request)
	else
		UpdateCheck_ShowAvailable(Release, Request)
	return true
}

_Updater_ActivateCachedRelease(Release, Request, IsSuspended := unset, NotifyFn := 0, InstallFn := 0, SuccessFn := 0) {
	if (_Updater_RequestContextValid(Request) and Request.BornSuspended)
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	HasSuspendOverride := IsSet(IsSuspended)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	Tag := Release.HasProp("Tag") ? Release.Tag : ""
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	Started := IsObject(InstallFn)
		? InstallFn.Call(Release)
		: Updater_DownloadAndInstall(Release, Request)
	if !Started
		return false
	if IsObject(SuccessFn)
		SuccessFn.Call(Tag)
	else
		try LoggerSuccess("Updater", "One-click check: new version {1} found — installing.", Tag)
	return true
}

; Opens a window that lists every release and lets the user read its notes.
; Layout: header bar (channel badge + switch button), left ListBox of releases,
; right Edit with the selected release body, bottom action buttons.
; Available in all run modes — local-source users see published releases too.
Updater_ShowChangelog(*) {
	global UPDATER_CHANNEL
	; Delegate to the shared-UI webview changelog (same HTML/CSS/JS as macOS).
	; Falls back to the old AHK-native window when WebView2 is unavailable.
	Changelog_Open(UPDATER_CHANNEL)
}

; Updates the "Install this version" button label and enabled state to reflect
; the currently selected release. Disabled when: no release is selected, the
; app is running from local source, or the selected tag is already the running
; version (installing it would be a no-op). An older release than the running
; build reads « Go back to this version », as on the shared Versions page.
; Called on every ListBox Change event.
_Updater_RefreshInstallBtn(BtnInstall, Releases, Idx, IsLocal) {
	if (IsLocal or Idx <= 0) {
		BtnInstall.Enabled := false
		BtnInstall.Text    := t("updater.changelog_install")
		return
	}
	Current := Updater_CurrentVersion()
	IsCurrent := (_Updater_NormalizeTag(Releases[Idx].Tag) == _Updater_NormalizeTag(Current))
	BtnInstall.Enabled := !IsCurrent
	BtnInstall.Text    := IsCurrent ? t("updater.changelog_install_current")
		: (_Updater_CompareVersions(Releases[Idx].Tag, Current) < 0)
			? t("changelog_window.rollback_release") : t("updater.changelog_install")
}

_Updater_OpenSelectedReleaseUrl(ListBox, Releases, IsSuspended := unset, NotifyFn := 0, RunFn := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	HasSuspendOverride := IsSet(IsSuspended)
	if (HasSuspendOverride ? IsSuspended : A_IsSuspended)
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	Request := HasSuspendOverride
		? _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, IsSuspended)
		: _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	Idx := ListBox.Value
	if !(Releases is Array) or Idx < 1 or Idx > Releases.Length
		return false
	Release := Releases[Idx]
	Url := (Type(Release) == "Object" and Release.HasProp("HtmlUrl") and Release.HtmlUrl != "")
		? Release.HtmlUrl : Updater_ReleasesPageUrl()
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	try {
		if IsObject(RunFn)
			RunFn.Call(Url)
		else
			Run(Url)
	} catch as Err {
		try LoggerError("Updater", "Could not open changelog URL '{1}': {2}.", Url, Err.Message)
		return false
	}
	return true
}

; Shows another channel's releases in the native Versions window. Viewing a
; channel never changes the subscription; _Updater_SubscribeChangelogChannel does.
_Updater_ViewChangelogChannel(G, Channel, IsSuspended := unset, NotifyFn := 0, CloseFn := 0, OpenFn := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if !UpdateChannels_IsKnown(Channel) {
		try LoggerError("Updater", "The Versions window refused an unknown channel to view.")
		return false
	}
	HasSuspendOverride := IsSet(IsSuspended)
	if (HasSuspendOverride ? IsSuspended : A_IsSuspended)
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	Request := HasSuspendOverride
		? _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, IsSuspended)
		: _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	if IsObject(CloseFn)
		CloseFn.Call(G)
	else
		_Updater_CloseGui(G)
	if IsObject(OpenFn)
		return OpenFn.Call(Channel, Request)
	return _Updater_OpenChangelogWindow(Channel, Request)
}

; Subscribes to the channel the native Versions window shows. Updater_SetChannel
; reloads the app, which closes this window, so the user confirms first.
_Updater_SubscribeChangelogChannel(G, Channel, IsSuspended := unset, NotifyFn := 0, CloseFn := 0, ConfirmFn := 0, SetChannelFn := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if !UpdateChannels_IsKnown(Channel) {
		try LoggerError("Updater", "The Versions window refused an unknown channel to subscribe to.")
		return false
	}
	HasSuspendOverride := IsSet(IsSuspended)
	if (HasSuspendOverride ? IsSuspended : A_IsSuspended)
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	Request := HasSuspendOverride
		? _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, IsSuspended)
		: _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	Question := StrReplace(t("changelog_window.subscribe_restart"), "{channel}", _Updater_ChannelLabel(Channel))
	Answer := IsObject(ConfirmFn)
		? ConfirmFn.Call(Question)
		: Ui_MsgBox(Question, t("changelog_window.window_title"), "YesNo Icon?")
	if (Answer !== "Yes") {
		try LoggerInfo("Updater", "Subscription to channel {1} cancelled from the Versions window.", Channel)
		return false
	}
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	if IsObject(CloseFn)
		CloseFn.Call(G)
	else
		_Updater_CloseGui(G)
	if IsObject(SetChannelFn)
		return SetChannelFn.Call(Channel, Request)
	return Updater_SetChannel(Channel, Request)
}

_Updater_RefreshChangelogSelection(ListBox, Releases, BtnInstall, IsLocal, ShowBodyFn, IsSuspended := unset, NotifyFn := 0, RefreshInstallFn := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	HasSuspendOverride := IsSet(IsSuspended)
	if (HasSuspendOverride ? IsSuspended : A_IsSuspended)
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	Request := HasSuspendOverride
		? _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, IsSuspended)
		: _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
			return false
	} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
		return false
	}
	Idx := ListBox.Value
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
			return false
	} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
		return false
	}
	if (Idx < 1 or Idx > Releases.Length) {
		if IsObject(RefreshInstallFn)
			RefreshInstallFn.Call(BtnInstall, Releases, 0, IsLocal)
		else
			_Updater_RefreshInstallBtn(BtnInstall, Releases, 0, IsLocal)
		return true
	}
	if IsObject(RefreshInstallFn)
		RefreshInstallFn.Call(BtnInstall, Releases, Idx, IsLocal)
	else
		_Updater_RefreshInstallBtn(BtnInstall, Releases, Idx, IsLocal)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
			return false
	} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
		return false
	}
	ShowBodyFn.Call(Releases[Idx].Body)
	return true
}

; Internal helper — builds (or rebuilds) the changelog GUI for a given channel.
; Dispatches an async WinHTTP fetch so the keyboard hook is not blocked while
; GitHub responds; _Updater_BuildChangelogGui builds the window once JSON lands.
_Updater_OpenChangelogWindow(Channel, Request := unset) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if !IsSet(Request) {
		if A_IsSuspended
			return _Updater_RefuseManualWhileSuspended()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	}
	if (_Updater_RequestContextValid(Request) and Request.BornSuspended)
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return false
	_Updater_FetchReleasesListJsonAsync(Channel, Request,
		(Json, CompletedRequest, Terminal := 0) => _Updater_BuildChangelogGui(
			Json, Channel, CompletedRequest, Terminal))
}

; Constructs the changelog Gui from the already-fetched releases JSON.
; Separated from _Updater_OpenChangelogWindow so the WinHTTP call runs async.
; It is the native fallback of the shared Versions page, so its notes pane is a
; plain-text Edit showing the changelog section of the selected release.
_Updater_BuildChangelogGui(Json, Channel, Request, Terminal := 0) {
	if !_Updater_RequestMayPublish(Request)
		return
	if _Updater_AsyncTerminalIsCancelled(Terminal) {
		try LoggerDebug("Updater", "Changelog fetch cancelled ({1}).", Terminal.Reason)
		return
	}
	if _Updater_JsonPayloadIsFailure(Json) {
		; Surface non-blocking — a modal MsgBox here would starve the keyboard hook
		try NotifierSend(t("updater.no_connection"), Map("title", t("updater.title_changelog"), "level", "warning"))
		return
	}

	; A channel's view lists its own releases and those of every more stable
	; channel (the shared registry decides). When there are none we still open
	; the window: the empty-state is shown inside the notes pane so the user can
	; view another channel without a popup.
	Releases := Updater_ParseReleasesList(Json, Channel)

	HasReleases := (Releases.Length > 0)
	Labels := []
	for _, R in Releases {
		Date   := SubStr(R.PublishedAt, 1, 10)
		Label  := (Date != "") ? (R.Tag . "  —  " . Date) : R.Tag
		Labels.Push(Label)
	}
	if !_Updater_RequestMayPublish(Request)
		return

	WinTitle := t("changelog_window.window_title")

	G := Gui_Create("+Resize +MinSize930x400", WinTitle)
	G.SetFont("s10", "Segoe UI")
	G.MarginX := 10
	G.MarginY := 8

	; Inner width available for controls (window w930 minus left+right margins).
	; MarginX=10 → usable band: x=10 … x=920 → 910 px wide.
	InnerW    := 910
	LeftColW  := 260
	ColGap    := 10
	RightColW := InnerW - LeftColW - ColGap   ; 640

	; ── Header bar ────────────────────────────────────────────────────────────
	; The picker changes only which channel is shown, like the page's tabs; the
	; button subscribes to the shown channel and is inactive for the current one.
	global UPDATER_CHANNEL
	IsLocal := Updater_IsLocalSource()
	ChannelIds := UpdateChannels_Ids()
	ChannelLabels := []
	ShownIndex := 0
	for Index, Id in ChannelIds {
		ChannelLabels.Push(_Updater_ChannelLabel(Id))
		if (Id == Channel)
			ShownIndex := Index
	}
	SubscribeLabel := StrReplace(t("changelog_window.subscribe"), "{channel}", _Updater_ChannelLabel(Channel))

	PickerW       := LeftColW                                     ; 260
	BtnSubscribeW := InnerW - PickerW - ColGap                    ; 640
	Picker := G.Add("DropDownList", "xm yp+4 w" . PickerW . " Choose" . ShownIndex, ChannelLabels)
	BtnSubscribe := G.Add("Button", "x+10 yp w" . BtnSubscribeW, SubscribeLabel)
	BtnSubscribe.Enabled := (Channel !== UPDATER_CHANNEL)

	G.Add("Text", "xm y+8 w" . LeftColW, t("updater.changelog_select_release"))

	; ── Two-pane area ─────────────────────────────────────────────────────────
	ListHeight := 480

	Lb := G.Add("ListBox", "xm y+4 w" . LeftColW . " h" . ListHeight . " vRelLb", Labels)

	; ── Bottom action buttons — created before RightPane so we can measure them ──
	; "Install this version" lets the user switch to any release, not just the latest.
	; Disabled when: no selection, local-source mode, or the selected tag is already
	; the running version (nothing to install).
	BtnInstall := G.Add("Button", "xm y+10 w" . LeftColW, t("updater.changelog_install"))
	BtnInstall.Enabled := false
	BtnOpen := G.Add("Button", "xm y+6 w" . LeftColW, t("updater.open_on_github"))
	if (!HasReleases) {
		BtnInstall.Enabled := false
		BtnOpen.Enabled    := false
	}

	; RightPane spans from the top of Lb down to the bottom of BtnOpen so the
	; notes Edit fills exactly that column, flush with the button baseline.
	Lb.GetPos(&lbx, &lby, , )
	BtnOpen.GetPos(, &btny, , &btnh)
	RightPaneH := (btny + btnh) - lby

	; Placeholder control that occupies the right-pane slot; the notes Edit is
	; laid over it once the window is shown.
	RightPane := G.Add("Text", "x+10 y" . lby . " w" . RightColW . " h" . RightPaneH, "")

	; This window is the native fallback of the shared Versions page (WebView2
	; missing or failed, or too little free RAM), so its notes pane is native
	; too: a read-only Edit showing the release's changelog section as text.
	RightPaneEdit := unset

	ShowBody := (md) => (IsSet(RightPaneEdit) ? (RightPaneEdit.Value := _Updater_ReleaseNotesToPlain(md)) : 0)

	OpenSelected := (*) => _Updater_OpenSelectedReleaseUrl(Lb, Releases)

	RefreshBody := (*) => _Updater_RefreshChangelogSelection(
		Lb, Releases, BtnInstall, IsLocal, ShowBody)

	; Capture Idx before _Updater_CloseGui(G) — Lb.Value returns 0 once the window is gone.
	InstallSelected := (*) => (
		((Idx2 := Lb.Value) > 0 and !IsLocal)
			? _Updater_InstallChosenRelease(G, Releases[Idx2])
			: ""
	)

	Picker.OnEvent("Change", (*) => (Picker.Value >= 1 && ChannelIds[Picker.Value] !== Channel)
		? _Updater_ViewChangelogChannel(G, ChannelIds[Picker.Value])
		: "")
	BtnSubscribe.OnEvent("Click", (*) => _Updater_SubscribeChangelogChannel(G, Channel))

	Lb.OnEvent("Change", RefreshBody)
	Lb.OnEvent("DoubleClick", OpenSelected)
	BtnInstall.OnEvent("Click", InstallSelected)
	BtnOpen.OnEvent("Click", OpenSelected)
	G.WVC := 0
	G.OnEvent("Close",  (*) => _Updater_CloseGui(G))
	G.OnEvent("Escape", (*) => _Updater_CloseGui(G))

	if !_Updater_RequestMayPublish(Request) {
		_Updater_CloseGui(G)
		return
	}
	G.Show("w930 AutoSize")
	if !_Updater_RequestMayPublish(Request) {
		_Updater_CloseGui(G)
		return
	}

	RightPane.GetPos(&rpx, &rpy, &rpw, &rph)
	RightPaneEdit := G.Add("Edit", "x" . rpx . " y" . rpy . " w" . rpw . " h" . rph
		. " ReadOnly +Multi -Wrap +VScroll", "")
	RightPaneEdit.SetFont("s9", "Consolas")
	if (HasReleases) {
		Lb.Choose(1)
		ShowBody(Releases[1].Body)
		_Updater_RefreshInstallBtn(BtnInstall, Releases, 1, IsLocal)
	} else {
		; An empty body shows the localized empty-notes message.
		ShowBody("")
	}
}

; Installs the release chosen in the native Versions window in one click, in
; the order of the shared page: configuration backup first, then the update
; path. The window closes; a refusal or a failure is shown in a modal box that
; names the reason and the backup.
; @returns {Boolean} Whether the update path started.
_Updater_InstallChosenRelease(G, Release) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if A_IsSuspended
		return _Updater_RefuseManualWhileSuspended()
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return false
	_Updater_CloseGui(G)
	Deps := Map(
		"busy", () => _UpdaterDownloadInProgress || _UpdaterRecoveryPublishTarget != "",
		"blocked", () => Updater_IsLocalSource() ? "changelog_window.install_blocked_source" : "",
		"find", (Tag) => Map("release", Release),
		"backup", (Chosen) => ConfigBackup_Create(_ConfigDir, "pre_install", Chosen.Tag, Updater_CurrentVersion()),
		"asset", (Chosen) => _Updater_FindAsset(Chosen.RawJson, BUNDLE_RELEASE_ASSET, Chosen.Tag),
		"install", (Chosen, Observer) => _Updater_StartObservedInstall(Chosen, Observer, Request),
		"report", _Updater_ReportChosenInstall)
	return ReleaseInstall_Start(Release.Tag, "", Deps)
}

; Hands a chosen release to the update path with an install observer.
; @returns {Boolean} Whether the update path started.
_Updater_StartObservedInstall(Release, Observer, Request, ExpectedFailureOwner := 0) {
	Admission := _Updater_AdmitInstallObserver(Release, Observer, Request, ExpectedFailureOwner)
	if !(Admission is Map)
		return false
	Started := false
	try {
		Started := Updater_DownloadAndInstall(Release, Request, , 0, 0, ExpectedFailureOwner) == true
	} finally {
		if !Started
			_Updater_RestoreInstallObserver(Admission)
	}
	return Started
}

; Only validation and publication are indivisible; no install/network/UI runs here.
_Updater_AdmitInstallObserver(Release, Observer, Request, ExpectedFailureOwner := 0) {
	global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
	PreviousCritical := Critical("On")
	try {
		if !(ExpectedFailureOwner is Map) && ExpectedFailureOwner != 0
			return 0
		if ExpectedFailureOwner is Map
			&& (_Updater_GetManagedFailureOwnerFor(Request, Release) != ExpectedFailureOwner
				|| !_Updater_ManagedFailureOwnerIsCurrent(ExpectedFailureOwner))
			return 0
		Admission := Map("previous", _UpdaterInstallObserver, "observer", Observer,
			"epoch", ++_UpdaterInstallObserverEpoch)
		_UpdaterInstallObserver := Observer
		return Admission
	} finally {
		Critical(PreviousCritical)
	}
}

; An older refusal cannot clear a successor, even when both reuse one callback.
_Updater_RestoreInstallObserver(Admission) {
	global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
	PreviousCritical := Critical("On")
	try {
		if !(Admission is Map) || Admission["epoch"] != _UpdaterInstallObserverEpoch
			|| _UpdaterInstallObserver != Admission["observer"]
			return false
		_UpdaterInstallObserver := Admission["previous"]
		_UpdaterInstallObserverEpoch += 1
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; The native window has closed: only a failure is shown, with its reason and
; the backup the install kept.
_Updater_ReportChosenInstall(Message) {
	if (Message["phase"] != "failed")
		return
	Text := StrReplace(t(Message["reason_key"]), "{tag}", Message["tag"])
	Text := StrReplace(Text, "{path}", Message.Has("backup_path") ? Message["backup_path"] : "")
	if (Message.Has("backup_path") && Message["backup_path"] != "")
		Text .= "`n`n" . StrReplace(t("changelog_window.install_backup_kept"), "{path}", Message["backup_path"])
	Ui_MsgBox(Text, t("changelog_window.window_title"), "Icon!")
}


; ==================================================
; ===== 1.6) Release notes pane (update prompt) ====
; ==================================================

; Virtual host mapped to _SharedDir for the update prompt's notes pane, so the
; shared page, its scripts and the locale fetch resolve over https:// (file://
; is an opaque origin the WebView2 bridge does not serve reliably).
global RELEASE_NOTES_VHOST := "ergopti.releasenotes"

; Returns the pane document URL. A per-open cache-buster forces a fresh
; document instead of a WebView2-cached copy, and makes the exact URL the
; provenance the bridge accepts messages from.
_Updater_ReleaseNotesUrl() {
	global RELEASE_NOTES_VHOST
	return "https://" . RELEASE_NOTES_VHOST . "/ui/release_notes/index.html?cb=" . A_TickCount
}

; Loads the shared release-notes page (_shared/ui/release_notes/) into a
; WebView2 controller: the same section splitter and DOM-only Markdown renderer
; as the Versions window, showing the release's changelog only. Returns the
; link bridge subscription, which the caller keeps with the controller and
; releases before closing it. Throws when the WebView2 calls fail.
_Updater_NavigateReleaseNotes(WVC, Release) {
	global _SharedDir, CHANGELOG_HOST_ACCESS_ALLOW, RELEASE_NOTES_VHOST
	Tag := Release.HasProp("Tag") ? Release.Tag : ""
	Body := Release.HasProp("Body") ? Release.Body : ""
	Url := _Updater_ReleaseNotesUrl()
	Session := _CLW_NewBridgeSessionToken()
	try LoggerStart("Updater", "Loading the release notes pane for {1}…", Tag)
	try {
		WebView := WVC.CoreWebView2
		WebView.SetVirtualHostNameToFolderMapping(RELEASE_NOTES_VHOST, _SharedDir, CHANGELOG_HOST_ACCESS_ALLOW)
		WebView.AddScriptToExecuteOnDocumentCreated(_Updater_ReleaseNotesSeed(Body, Session))
		Subscription := WebView.WebMessageReceived(_Updater_OnReleaseNotesMessage.Bind(Url, Session))
		WebView.Navigate(Url)
	} catch as Err {
		try LoggerError("Updater", "The release notes pane for {1} could not load: {2}.", Tag, Err.Message)
		throw Err
	}
	try LoggerSuccess("Updater", "Release notes pane navigation issued for {1}.", Tag)
	return Subscription
}

; The pane's boot data as one script run before the page: the locale for
; i18n.js, the repository for the link policy, the bridge session, and the body
; as an HTML-safe JSON string literal, so release text is only ever data.
_Updater_ReleaseNotesSeed(Body, Session) {
	global _I18nLocale, UPDATER_GH_OWNER, UPDATER_GH_REPO, RELEASE_NOTES_VHOST
	return "window.__i18n_base=" . JsonStringLiteral("https://" . RELEASE_NOTES_VHOST . "/data/locales/", true) . ";"
		. "window._i18n_locale=" . JsonStringLiteral(_I18nLocale, true) . ";"
		. "window.__release_notes={body:" . JsonStringLiteral(Body, true)
		. ",owner:" . JsonStringLiteral(UPDATER_GH_OWNER, true)
		. ",repo:" . JsonStringLiteral(UPDATER_GH_REPO, true)
		. ",session:" . JsonStringLiteral(Session, true) . "};"
}

; Receives the pane's link clicks. Only the exact document this prompt loaded,
; carrying its session token, may ask for anything, and open_url is the only
; action; _Updater_OpenManualUrl then applies the repository allowlist.
; WebMessageReceived bypasses native Suspend, so the pause state is captured
; before the COM read can pump messages and revalidated before opening.
; OpenFn is a test seam replacing that opener.
_Updater_OnReleaseNotesMessage(ExpectedSource, ExpectedSession, Handler, Args, OpenFn := 0) {
	if !_CLW_BridgeSourceMatches(Args, ExpectedSource) {
		try LoggerWarn("Updater", "Release notes pane: rejected a message from another document.")
		return false
	}
	Envelope := _Updater_ReadManualBridgeMessage(() => Args.TryGetWebMessageAsString())
	if (!IsObject(Envelope) or !Envelope.Ok)
		return false
	try {
		Payload := JsonParse(Envelope.Message)
	} catch as Err {
		try LoggerWarn("Updater", "Release notes pane: rejected an unreadable message ({1}).", Err.Message)
		return false
	}
	if (!(Payload is Map)
			|| Payload.Get("session", "") !== ExpectedSession
			|| Payload.Get("action", "") !== "open_url") {
		try LoggerWarn("Updater", "Release notes pane: rejected a message without the session or with another action.")
		return false
	}
	Request := Envelope.Request
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return false
	Url := Payload.Get("url", "")
	if IsObject(OpenFn)
		return OpenFn.Call(Url, Request)
	return _Updater_OpenManualUrl(() => Url, Request)
}



; ======================================================
; ===== 1.7) Release notes: changelog section ==========
; ======================================================

; Section names the release CI emits between invisible HTML comment markers.
; Mirrors RELEASE_BODY_SECTIONS in _shared/ui/changelog/release_body.js; both
; extractions are pinned by _shared/tests/corpus/updater/release_body_vectors.json.
global UPDATER_RELEASE_BODY_SECTIONS := ["intro", "downloads", "changelog", "footer"]

; Returns the changelog section of a release body as Markdown, the way the
; shared splitter (_shared/ui/changelog/release_body.js) extracts it: from the CI
; section markers, else from the headings and changelog fold every earlier CI
; format used, else the whole body. The native notes views show only this part;
; the downloads stay one click away on GitHub.
_Updater_ReleaseNotesChangelog(Body) {
	Lines := StrSplit(RegExReplace(Body, "\r\n?", "`n"), "`n")
	Mask := _Updater_ReleaseBodyFenceMask(Lines)
	Sections := _Updater_ReleaseBodyParseMarked(Lines, Mask)
	if !IsObject(Sections)
		Sections := _Updater_ReleaseBodyParseHeuristic(Lines, Mask)
	if !IsObject(Sections)
		return _Updater_ReleaseBodyJoin(_Updater_ReleaseBodyTrim(Lines))

	Changelog := Sections.Has("changelog") ? Sections["changelog"] : []
	Changelog := _Updater_ReleaseBodyUnwrapFold(_Updater_ReleaseBodyDropChrome(Changelog))
	Changelog := _Updater_ReleaseBodyTrim(Changelog)
	if (Changelog.Length > 0 && RegExMatch(Changelog[1], "^ {0,3}## +Changelog(?: +#+)? *$"))
		Changelog.RemoveAt(1)
	Changelog := _Updater_ReleaseBodyTrim(Changelog)

	; The timestamp note explains the changelog; legacy bodies put it in the intro.
	Intro := _Updater_ReleaseBodyTrim(_Updater_ReleaseBodyDropChrome(Sections.Has("intro") ? Sections["intro"] : []))
	if (Intro.Length > 0 && RegExMatch(Intro[1], "^ {0,3}## +Ergopti\b"))
		Intro.RemoveAt(1)
	IntroMask := _Updater_ReleaseBodyFenceMask(Intro)
	for LineNo, Line in Intro {
		if (!IntroMask[LineNo] && RegExMatch(Line, "^ {0,3}> ?Timestamps are in\b")) {
			if (Changelog.Length > 0)
				Changelog.InsertAt(1, Line, "")
			break
		}
	}
	return _Updater_ReleaseBodyJoin(_Updater_ReleaseBodyTrim(Changelog))
}

; Plain-text projection of the changelog section for the native (no-WebView2)
; notes views; the localized empty-notes message when there is none.
_Updater_ReleaseNotesToPlain(Body) {
	Changelog := _Updater_ReleaseNotesChangelog(Body)
	if (Changelog == "")
		return t("updater.changelog_empty")
	return _Updater_MarkdownToPlain(Changelog)
}

; Flags every line of a fenced code block, fences included, with the Markdown
; renderer's opening and closing rule.
_Updater_ReleaseBodyFenceMask(Lines) {
	Mask := []
	Mask.Length := Lines.Length
	LineNo := 1
	while (LineNo <= Lines.Length) {
		Mask[LineNo] := false
		if !RegExMatch(Lines[LineNo], "^ {0,3}(``{3,}|~{3,})", &Fence) {
			LineNo += 1
			continue
		}
		Mask[LineNo] := true
		LineNo += 1
		while (LineNo <= Lines.Length && InStr(Trim(Lines[LineNo], " `t"), Fence[1]) != 1) {
			Mask[LineNo] := true
			LineNo += 1
		}
		if (LineNo <= Lines.Length)
			Mask[LineNo] := true
		LineNo += 1
	}
	return Mask
}

; Reads the CI section markers. Returns a Map of section lines, or "" when the
; body has no valid marker structure.
_Updater_ReleaseBodyParseMarked(Lines, Mask) {
	global UPDATER_RELEASE_BODY_SECTIONS
	Sections := Map()
	Current := ""
	Start := 0
	SawMarker := false
	for LineNo, Line in Lines {
		if (!Mask[LineNo] && RegExMatch(Line, "^<!-- ergopti:section=([a-z]+) -->[ \t]*$", &Open)) {
			SawMarker := true
			Known := false
			for _, SectionName in UPDATER_RELEASE_BODY_SECTIONS
				Known := Known || (SectionName == Open[1])
			if (Current != "" || !Known || Sections.Has(Open[1]))
				return ""
			Current := Open[1]
			Start := LineNo + 1
			continue
		}
		if (!Mask[LineNo] && RegExMatch(Line, "^<!-- /ergopti:section -->[ \t]*$")) {
			SawMarker := true
			if (Current == "")
				return ""
			Sections[Current] := _Updater_ReleaseBodySlice(Lines, Start, LineNo - 1)
			Current := ""
			continue
		}
		if (Current == "" && !RegExMatch(Line, "^\s*$"))
			return ""
	}
	if (!SawMarker || Current != "")
		return ""
	return Sections
}

; Splits an unmarked body on the headings and the changelog fold. Returns a Map
; of section lines, or "" when neither a changelog nor downloads is recognisable.
_Updater_ReleaseBodyParseHeuristic(Lines, Mask) {
	Anchors := Map()
	FoldEnd := 0
	for LineNo, Line in Lines {
		if Mask[LineNo]
			continue
		if (!Anchors.Has("intro") && RegExMatch(Line, "^ {0,3}## +Ergopti\b"))
			Anchors["intro"] := LineNo
		if (!Anchors.Has("downloads") && RegExMatch(Line, "^ {0,3}## +Downloads(?: +#+)? *$"))
			Anchors["downloads"] := LineNo
		if !Anchors.Has("changelog") {
			if RegExMatch(Line, "^ {0,3}## +Changelog(?: +#+)? *$") {
				Anchors["changelog"] := LineNo
			} else if _Updater_ReleaseBodyIsChangelogFold(Lines, Mask, LineNo) {
				Anchors["changelog"] := LineNo
				FoldEnd := _Updater_ReleaseBodyFoldEnd(Lines, Mask, LineNo)
			}
		}
	}
	if (!Anchors.Has("changelog") && !Anchors.Has("downloads"))
		return ""

	Last := _Updater_ReleaseBodyPrevContent(Lines, Lines.Length)
	if (Last > 0 && !Mask[Last] && RegExMatch(Lines[Last], "^ {0,3}[_*]Generated by\b.*[_*][ \t]*$")) {
		Rule := _Updater_ReleaseBodyPrevContent(Lines, Last - 1)
		Anchors["footer"] := (Rule > 0 && !Mask[Rule]
			&& RegExMatch(Lines[Rule], "^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")) ? Rule : Last
	}

	; Order the anchors by position (at most four, so an insertion sort).
	Order := []
	for SectionName, Position in Anchors {
		Slot := Order.Length + 1
		while (Slot > 1 && Anchors[Order[Slot - 1]] > Position)
			Slot -= 1
		Order.InsertAt(Slot, SectionName)
	}
	Sections := Map("intro", _Updater_ReleaseBodySlice(Lines, 1, Anchors[Order[1]] - 1))
	Leftover := []
	for Position, SectionName in Order {
		End := (Position < Order.Length) ? Anchors[Order[Position + 1]] - 1 : Lines.Length
		Span := _Updater_ReleaseBodySlice(Lines, Anchors[SectionName], End)
		if (SectionName == "changelog" && FoldEnd > 0 && FoldEnd < End) {
			Leftover := _Updater_ReleaseBodySlice(Lines, FoldEnd + 1, End)
			Span := _Updater_ReleaseBodySlice(Lines, Anchors[SectionName], FoldEnd)
		}
		Collected := Sections.Has(SectionName) ? Sections[SectionName] : []
		for _, Line in Span
			Collected.Push(Line)
		Sections[SectionName] := Collected
	}
	if (_Updater_ReleaseBodyNextContent(Leftover, 1) > 0) {
		Footer := Sections.Has("footer") ? Sections["footer"] : []
		for _, Line in Footer
			Leftover.Push(Line)
		Sections["footer"] := Leftover
	}
	return Sections
}

; True when the fold opened at LineNo has a summary starting with "Changelog".
_Updater_ReleaseBodyIsChangelogFold(Lines, Mask, LineNo) {
	if (Mask[LineNo] || !RegExMatch(Lines[LineNo], "^ {0,3}<details( open)?>[ \t]*$"))
		return false
	Next := _Updater_ReleaseBodyNextContent(Lines, LineNo + 1)
	if (Next == 0 || !RegExMatch(Lines[Next], "^ {0,3}<summary>(.*)</summary>[ \t]*$", &Summary))
		return false
	Text := Trim(RegExReplace(RegExReplace(Summary[1], "<[^>]*>"), "[*_\\]"))
	return RegExMatch(Text, "i)^changelog\b") > 0
}

; LineNo of the </details> closing the fold opened at Start (the last line when
; unclosed), skipping fenced code.
_Updater_ReleaseBodyFoldEnd(Lines, Mask, Start) {
	Depth := 0
	LineNo := Start
	while (LineNo <= Lines.Length) {
		if !Mask[LineNo] {
			if RegExMatch(Lines[LineNo], "^ {0,3}<details( open)?>[ \t]*$") {
				Depth += 1
			} else if RegExMatch(Lines[LineNo], "^ {0,3}</details>[ \t]*$") {
				Depth -= 1
				if (Depth == 0)
					return LineNo
			}
		}
		LineNo += 1
	}
	return Lines.Length
}

; Removes a whole-section fold: the <details> line, its summary and </details>.
_Updater_ReleaseBodyUnwrapFold(Lines) {
	Trimmed := _Updater_ReleaseBodyTrim(Lines)
	if (Trimmed.Length < 3 || !RegExMatch(Trimmed[1], "^ {0,3}<details( open)?>[ \t]*$"))
		return Trimmed
	if (_Updater_ReleaseBodyFoldEnd(Trimmed, _Updater_ReleaseBodyFenceMask(Trimmed), 1) != Trimmed.Length)
		return Trimmed
	if !RegExMatch(Trimmed[Trimmed.Length], "^ {0,3}</details>[ \t]*$")
		return Trimmed
	Summary := _Updater_ReleaseBodyNextContent(Trimmed, 2)
	if (Summary == 0 || !RegExMatch(Trimmed[Summary], "^ {0,3}<summary>(.*)</summary>[ \t]*$"))
		return Trimmed
	return _Updater_ReleaseBodySlice(Trimmed, Summary + 1, Trimmed.Length - 1)
}

; Removes the github.com-only lines: the downloads jump link and empty anchors.
_Updater_ReleaseBodyDropChrome(Lines) {
	Mask := _Updater_ReleaseBodyFenceMask(Lines)
	Kept := []
	for LineNo, Line in Lines {
		if (!Mask[LineNo]
				&& (RegExMatch(Line, "^ {0,3}\*\*\[[^\]]*\]\([^)\s]*#(?:user-content-)?downloads[A-Za-z0-9_-]*\)\*\*[ \t]*$")
				|| RegExMatch(Line, '^ {0,3}<a (?:id|name)="[A-Za-z0-9_-]*"></a>[ \t]*$')))
			continue
		Kept.Push(Line)
	}
	return Kept
}

; Drops leading and trailing blank lines and thematic breaks.
_Updater_ReleaseBodyTrim(Lines) {
	First := 1
	Last := Lines.Length
	while (First <= Last && _Updater_ReleaseBodyIsEdge(Lines[First]))
		First += 1
	while (Last >= First && _Updater_ReleaseBodyIsEdge(Lines[Last]))
		Last -= 1
	return _Updater_ReleaseBodySlice(Lines, First, Last)
}

_Updater_ReleaseBodyIsEdge(Line) {
	return RegExMatch(Line, "^\s*$") || RegExMatch(Line, "^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
}

; Lines[First..Last] as a new array (empty when Last < First).
_Updater_ReleaseBodySlice(Lines, First, Last) {
	Out := []
	LineNo := First
	while (LineNo <= Last) {
		Out.Push(Lines[LineNo])
		LineNo += 1
	}
	return Out
}

; LineNo of the first non-blank line at or after Start, or 0.
_Updater_ReleaseBodyNextContent(Lines, Start) {
	LineNo := Start
	while (LineNo <= Lines.Length) {
		if !RegExMatch(Lines[LineNo], "^\s*$")
			return LineNo
		LineNo += 1
	}
	return 0
}

; LineNo of the last non-blank line at or before Start, or 0.
_Updater_ReleaseBodyPrevContent(Lines, Start) {
	LineNo := Start
	while (LineNo >= 1) {
		if !RegExMatch(Lines[LineNo], "^\s*$")
			return LineNo
		LineNo -= 1
	}
	return 0
}

_Updater_ReleaseBodyJoin(Lines) {
	Out := ""
	for LineNo, Line in Lines
		Out .= (LineNo > 1 ? "`n" : "") . Line
	return Out
}


; Converts the GitHub-release Markdown subset to clean, readable plain text for the
; native (no-WebView2) fallback. Mirrors the subset of the shared renderer
; (_shared/ui/markdown.js) so the low-RAM view stays faithful: headings, bold,
; italic, inline code, links, lists, blockquotes, horizontal rules and folds. It
; cannot reproduce fonts or colours, but it strips the raw markup so the notes
; read as prose instead of "## ... **...**".
_Updater_MarkdownToPlain(md) {
	if (md = "")
		return md
	s := md
	; Invisible comments and fold lines carry no prose; a fold keeps its summary.
	s := RegExReplace(s, "s)<!--.*?-->", "")
	s := RegExReplace(s, "m)^ {0,3}</?details(?: open)?>[ \t]*$", "")
	s := RegExReplace(s, "m)^ {0,3}<summary>(?:<(?:b|strong)>)?(.*?)(?:</(?:b|strong)>)?(.*)</summary>[ \t]*$", "$1$2")
	; Drop fenced-code fences (keep their contents as plain lines).
	s := RegExReplace(s, "m)^\s*``````.*$", "")
	; ATX headings -> bare text.
	s := RegExReplace(s, "m)^#{1,6}\s+", "")
	; Horizontal rules -> a thin separator line.
	s := RegExReplace(s, "m)^\s*(?:---+|\*\*\*+)\s*$", "----------------------------------------")
	; List markers -> a simple bullet; blockquote markers -> an indent bar.
	s := RegExReplace(s, "m)^(\s*)[-*+]\s+", "$1- ")
	s := RegExReplace(s, "m)^>\s?", "  | ")
	; Inline: images/links first, then code, then bold before italic.
	s := RegExReplace(s, "!\[([^\]]*)\]\(([^)]+)\)", "$1")
	s := RegExReplace(s, "\[([^\]]+)\]\(([^)]+)\)", "$1 ($2)")
	s := RegExReplace(s, '``([^``]+)``', "$1")
	s := RegExReplace(s, "\*\*(.+?)\*\*", "$1")
	s := RegExReplace(s, "__(.+?)__", "$1")
	s := RegExReplace(s, "\*(.+?)\*", "$1")
	; Underscore italics only when flanked by non-word chars (spare snake_case).
	s := RegExReplace(s, "(?<!\w)_(.+?)_(?!\w)", "$1")
	return s
}
