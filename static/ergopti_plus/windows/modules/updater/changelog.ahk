; modules/updater/changelog.ahk

; ==============================================================================
; MODULE: Updater / Menu Actions + Changelog UI
; DESCRIPTION:
; The dynamic update menu state and label, one-click update flow, version dialog, and the changelog window (HTML/markdown rendering) shown to the user.
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
		if (Tag != "")
			return Format(t("menu.about.update_now"), Tag)
	}
	return t("menu.about.check_for_updates")
}

; Displays the current version in a MsgBox and offers to open the releases page.
Updater_ShowVersion(*) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if A_IsSuspended
		return _Updater_RefuseManualWhileSuspended()
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return
	Ver := Updater_CurrentVersion()
	global UPDATER_CHANNEL
	if Updater_IsLocalSource()
		ChannelSuffix := t("updater.channel_local_source_suffix")
	else
		ChannelSuffix := (UPDATER_CHANNEL == "dev")
			? t("updater.channel_dev_suffix")
			: t("updater.channel_main_suffix")
	Res := MsgBox(
		Format(t("updater.version_message"), Ver, ChannelSuffix),
		t("updater.title_version"),
		"YesNo Iconi"
	)
	if (Res == "Yes")
		_Updater_OpenManualUrl(Updater_ReleasesPageUrl, Request)
}

; One-click update entry point wired to the dynamic tray menu item.
;
; State machine:
;   idle      → fetch latest, compare, cache if newer, rebuild menu, then install
;   available → install immediately from cache (no extra network call)
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

	; Fast path: update already cached by background poller — install straight away.
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
		return
	}
	if _Updater_AsyncTerminalIsCancelled(Terminal) {
		try LoggerDone("Updater", "One-click update check cancelled ({1}).", Terminal.Reason)
		return
	}

	if _Updater_JsonPayloadIsFailure(Json) {
		try LoggerWarn("Updater", "One-click check: network unreachable.")
		try LoggerDone("Updater", "One-click update check finished without a network response.")
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return
		TrayTip(t("updater.no_connection"), t("updater.title_update"))
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "") {
		try LoggerWarn("Updater", "One-click check: tag parse failed.")
		try LoggerDone("Updater", "One-click update check finished with invalid release metadata.")
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return
		TrayTip(t("updater.parse_failed"), t("updater.title_update"))
		return
	}
	if !_Updater_ShouldOfferCandidate(
		Latest, Current, Request.Channel, _Updater_InstalledChannel()) {
		try LoggerSuccess("Updater", "One-click check: already up to date ({1}).", Current)
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return
		TrayTip(Format(t("updater.up_to_date"), Current), t("updater.title_update"))
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
		try LoggerDone("Updater", "One-click update check completed without starting staging.")
}

_Updater_PublishOneClickRelease(Release, Request, IsSuspended := unset, RebuildFn := 0, NotifyFn := 0, InstallFn := 0) {
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
		return _Updater_ActivateCachedRelease(
			Release, Request, IsSuspended, NotifyFn, InstallFn)
	}
	if !_Updater_RequestMayPublish(Request)
		return false
	return _Updater_ActivateCachedRelease(Release, Request)
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
; version (installing it would be a no-op). Called on every ListBox Change event.
_Updater_RefreshInstallBtn(BtnInstall, Releases, Idx, IsLocal) {
	if (IsLocal or Idx <= 0) {
		BtnInstall.Enabled := false
		BtnInstall.Text    := t("updater.changelog_install")
		return
	}
	IsCurrent := (_Updater_NormalizeTag(Releases[Idx].Tag) == _Updater_NormalizeTag(Updater_CurrentVersion()))
	BtnInstall.Enabled := !IsCurrent
	BtnInstall.Text    := IsCurrent ? t("updater.changelog_install_current") : t("updater.changelog_install")
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

_Updater_SwitchChangelogChannel(G, IsLocal, OtherChannel, IsSuspended := unset, NotifyFn := 0, CloseFn := 0, OpenFn := 0, SetChannelFn := 0) {
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
	if IsObject(CloseFn)
		CloseFn.Call(G)
	else
		_Updater_CloseGui(G)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	if IsLocal {
		if IsObject(OpenFn)
			return OpenFn.Call(OtherChannel, Request)
		return _Updater_OpenChangelogWindow(OtherChannel, Request)
	}
	if IsObject(SetChannelFn)
		SetChannelFn.Call(OtherChannel)
	else
		Updater_SetChannel(OtherChannel, Request)
	return true
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
; The notes pane uses WebView2 (NavigateToString) for Markdown rendering and
; falls back to a plain-text Edit when WebView2 is unavailable.
_Updater_BuildChangelogGui(Json, Channel, Request, Terminal := 0) {
	global _VendorDir
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

	; Dev channel shows everything; main channel shows stable releases only.
	; When there are no releases we still open the window: the empty-state is
	; shown inside the notes pane so the user can switch channel without a popup.
	MainOnly := (Channel != "dev")
	Releases := Updater_ParseReleasesList(Json, MainOnly)

	HasReleases := (Releases.Length > 0)
	Labels := []
	for _, R in Releases {
		Date   := SubStr(R.PublishedAt, 1, 10)
		Marker := R.Prerelease ? "  [dev]" : ""
		Label  := (Date != "") ? (R.Tag . "  —  " . Date . Marker) : (R.Tag . Marker)
		Labels.Push(Label)
	}
	if !_Updater_RequestMayPublish(Request)
		return

	WinTitle := t("updater.title_changelog")

	G := Gui("+Resize +MinSize930x400", WinTitle)
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
	IsLocal := Updater_IsLocalSource()
	BadgeText := IsLocal
		? (t("menu.about.channel_local_source") . "  |  " . t("updater.changelog_channel_label") . "  " . Channel)
		: (t("updater.changelog_channel_label") . "  " . Channel)
	OtherChannel := (Channel == "dev") ? "main" : "dev"
	SwitchLabel  := (Channel == "dev")
		? t("updater.changelog_switch_to_main")
		: t("updater.changelog_switch_to_dev")

	BadgeW    := InnerW - ColGap - (InnerW - LeftColW - ColGap)   ; 260 = LeftColW
	BtnSwitchW := InnerW - BadgeW - ColGap                         ; 640
	G.Add("Text", "xm yp+4 w" . BadgeW . " +0x200", BadgeText)
	BtnSwitch := G.Add("Button", "x+10 yp w" . BtnSwitchW, SwitchLabel)

	if (IsLocal)
		G.Add("Text", "xm y+4 w" . InnerW . " cGray", t("updater.changelog_local_source_note"))

	G.Add("Text", "xm y+8 w" . LeftColW, t("updater.changelog_select_release"))

	; ── Two-pane area ─────────────────────────────────────────────────────────
	ListHeight := IsLocal ? 460 : 480

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
	; WebView2 child fills exactly that column, flush with the button baseline.
	Lb.GetPos(&lbx, &lby, , )
	BtnOpen.GetPos(, &btny, , &btnh)
	RightPaneH := (btny + btnh) - lby

	; Decide whether to use WebView2 for Markdown rendering. Skip it (and use the
	; native Edit fallback below) when free RAM is too low to absorb the cold start.
	UseWV := IsSet(WebView2) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll") && !WebView_ShouldUseNativeFallback()

	; Placeholder control that occupies the right-pane slot; the WebView2
	; control will be positioned on top of it after Gui.Show().
	RightPane := G.Add("Text", "x+10 y" . lby . " w" . RightColW . " h" . RightPaneH, "")

	; ── WebView2 controller (created after Show so the Hwnd is valid) ─────────
	WVC := unset           ; controller reference, kept in closure scope
	RightPaneEdit := unset ; native fallback Edit, populated when WebView2 is off

	; Builds a self-contained HTML page that renders the given Markdown string.
	; The JS renderer covers the Markdown subset used in GitHub release notes:
	; ATX headings (#/##/###), **bold**, *italic*, `code`, [links](url),
	; unordered/ordered lists, blockquotes, horizontal rules, tables, and
	; fenced code blocks. No external dependencies — everything is inline.
	MakeHtml := (md) => _Updater_MakeMarkdownHtml(md)

	; Navigates the WebView2 pane to a rendered Markdown page.
	; Falls back to a plain string assignment when WebView2 is not used.
	ShowBody := (md) => (
		UseWV && IsSet(WVC)
			? WVC.CoreWebView2.NavigateToString(MakeHtml(md))
			: (IsSet(RightPaneEdit) ? (RightPaneEdit.Value := _Updater_MarkdownToPlain(md)) : 0)
	)

	OpenSelected := (*) => _Updater_OpenSelectedReleaseUrl(Lb, Releases)

	RefreshBody := (*) => _Updater_RefreshChangelogSelection(
		Lb, Releases, BtnInstall, IsLocal, ShowBody)

	; Capture Idx before _Updater_CloseGui(G) — Lb.Value returns 0 once the window is gone.
	InstallSelected := (*) => (
		((Idx2 := Lb.Value) > 0 and !IsLocal)
			? _Updater_OpenSelectedReleasePrompt(G, Releases[Idx2])
			: ""
	)

	BtnSwitch.OnEvent("Click", (*) => _Updater_SwitchChangelogChannel(
		G, IsLocal, OtherChannel))

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

	; Spin up the WebView2 controller now that the window Hwnd is valid.
	if (UseWV) {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		try {
			; Parent the WebView2 to the RightPane control directly so Fill()
			; covers exactly that control's client area — no manual coordinate
			; arithmetic needed, and resize is handled automatically by the OS.
			; Reuse the shared session environment (infra/webview_utils.ahk) so no
			; second Chromium process boots and reopens are near-instant.
			WVC := WebView2.create(RightPane.Hwnd, , WebView_SharedEnvironment(loader))
			if !_Updater_RequestMayPublish(Request) {
				try WVC.Close()
				_Updater_CloseGui(G)
				return
			}
			G.WVC := WVC
		} catch as Err {
			try LoggerWarn("Updater", "WebView2 create failed: {1} — falling back.", Err.Message)
			UseWV := false
		}
		if (UseWV) {
			try {
				s := WVC.CoreWebView2.Settings
				s.AreDevToolsEnabled              := false
				s.AreDefaultContextMenusEnabled   := false
				s.IsStatusBarEnabled              := false
				s.AreBrowserAcceleratorKeysEnabled := false
				s.IsSwipeNavigationEnabled         := false
			}
			WVC.Fill()
			if !_Updater_RequestMayPublish(Request) {
				_Updater_CloseGui(G)
				return
			}
			; NavigateToString is synchronous enough here — no "ready" handshake needed.
			if (HasReleases) {
				Lb.Choose(1)
				ShowBody(Releases[1].Body)
				_Updater_RefreshInstallBtn(BtnInstall, Releases, 1, IsLocal)
			} else {
				; Empty-state: pass an empty string so the JS renderer shows the centred message.
				ShowBody("")
			}
		}
	}

	; Native fallback: a selectable read-only Edit over the right-pane slot, showing
	; the raw Markdown. Used when WebView2 is unavailable or free RAM is too low.
	if (!UseWV) {
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
			ShowBody(t("updater.changelog_empty"))
		}
	}
}

_Updater_OpenSelectedReleasePrompt(G, Release) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if A_IsSuspended
		return _Updater_RefuseManualWhileSuspended()
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return false
	_Updater_CloseGui(G)
	if !_Updater_RequestMayPublish(Request)
		return false
	Updater_ShowUpdatePrompt(Release, Request)
	return true
}

; Escapes a string for safe embedding as a JS string literal (single-quoted).
_Updater_JsStr(s) {
	s := StrReplace(s, "\",  "\\")
	s := StrReplace(s, "'",  "\'")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`t", "\t")
	return "'" . s . "'"
}

; Builds a self-contained HTML page that renders the given Markdown string.
; The JS renderer covers the Markdown subset used in GitHub release notes:
; ATX headings, **bold**, *italic*, `code`, [links](url), lists, blockquotes,
; horizontal rules, tables, and fenced code blocks. No external dependencies.
; Used by both _Updater_OpenChangelogWindow and Updater_ShowUpdatePrompt.
_Updater_MakeMarkdownHtml(md) {
	return (
		"<!DOCTYPE html><html><head><meta charset='utf-8'>"
		. "<style>"
		. "html,body{margin:0;padding:0;height:100%;font-family:'Segoe UI',sans-serif;font-size:13px;color:#1a1a1a;background:#fff;}"
		. "body{padding:14px 18px;box-sizing:border-box;overflow-y:auto;overflow-x:hidden;}"
		. "h1{font-size:1.35em;margin:.6em 0 .3em;}h2{font-size:1.2em;margin:.6em 0 .25em;border-bottom:1px solid #ddd;padding-bottom:.2em;}"
		. "h3{font-size:1.05em;margin:.5em 0 .2em;}h4,h5,h6{font-size:1em;margin:.4em 0 .15em;}"
		. "p{margin:.35em 0;}ul,ol{margin:.3em 0 .3em 1.4em;padding:0;}li{margin:.15em 0;}"
		. "code{background:#f3f3f3;border-radius:3px;padding:.1em .35em;font-family:Consolas,monospace;font-size:.92em;}"
		. "pre{background:#f3f3f3;border-radius:4px;padding:.7em 1em;overflow-x:auto;}"
		. "pre code{background:none;padding:0;}"
		. "blockquote{border-left:3px solid #ccc;margin:.4em 0 .4em 0;padding:.2em .8em;color:#555;}"
		. "hr{border:none;border-top:1px solid #ddd;margin:.6em 0;}"
		. "a{color:#0969da;}a:hover{text-decoration:underline;}"
		. "table{border-collapse:collapse;margin:.4em 0;}th,td{border:1px solid #ddd;padding:.25em .6em;text-align:left;}"
		. "th{background:#f5f5f5;font-weight:600;}"
		. ".empty{display:flex;align-items:center;justify-content:center;height:100%;color:#888;font-size:1.05em;}"
		. "</style></head><body>"
		. "<script>"
		. "function mdToHtml(s){"
		. "if(!s)return '<div class=empty>' + emptyMsg + '</div>';"
		. "var lines=s.split('\n'),out=[],inPre=false,inUl=false,inOl=false,inBq=false,inTbl=false;"
		. "function closeBlocks(){if(inUl){out.push('</ul>');inUl=false;}if(inOl){out.push('</ol>');inOl=false;}if(inBq){out.push('</blockquote>');inBq=false;}if(inTbl){out.push('</table>');inTbl=false;}}"
		. "function inline(t){t=t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');"
		. "t=t.replace(/``([^``]+)``/g,'<code>$1</code>');"
		. "t=t.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>');"
		. "t=t.replace(/__(.+?)__/g,'<strong>$1</strong>');"
		. "t=t.replace(/\*(.+?)\*/g,'<em>$1</em>');"
		. "t=t.replace(/_(.+?)_/g,'<em>$1</em>');"
		. "t=t.replace(/!\[([^\]]*)\]\(([^)]+)\)/g,'<img alt=" . '"' . "$1" . '"' . " src=" . '"' . "$2" . '"' . " style=" . '"' . "max-width:100%" . '"' . ">');"
		. "t=t.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<a href=" . '"' . "$2" . '"' . " target=" . '"' . "_blank" . '"' . ">$1</a>');"
		. "return t;}"
		. "for(var i=0;i<lines.length;i++){"
		. "var l=lines[i];"
		. "if(/^``````/.test(l)){if(inPre){out.push('</code></pre>');inPre=false;}else{closeBlocks();out.push('<pre><code>');inPre=true;}continue;}"
		. "if(inPre){out.push(l.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'));continue;}"
		. "if(/^\s*$/.test(l)){closeBlocks();continue;}"
		. "var hm=l.match(/^(#{1,6})\s+(.*)/);if(hm){closeBlocks();var n=hm[1].length;out.push('<h'+n+'>'+inline(hm[2])+'</h'+n+'>');continue;}"
		. "if(/^---+$/.test(l.trim())||/^\*\*\*+$/.test(l.trim())){closeBlocks();out.push('<hr>');continue;}"
		. "if(/^\|/.test(l)&&/\|/.test(l)){if(!inTbl){closeBlocks();out.push('<table>');inTbl=true;}"
		. "if(/^[\s|:-]+$/.test(l))continue;"
		. "var cells=l.replace(/^\||\|$/g,'').split('|');"
		. "var tag=(!inTbl||out[out.length-1]==='<table>')?'th':'td';"
		. "out.push('<tr>'+cells.map(function(c){return'<'+tag+'>'+inline(c.trim())+'</'+tag+'>';}).join('')+'</tr>');continue;}"
		. "var bq=l.match(/^>\s?(.*)/);if(bq){if(!inBq){closeBlocks();out.push('<blockquote>');inBq=true;}out.push('<p>'+inline(bq[1])+'</p>');continue;}"
		. "var ul=l.match(/^[-*+]\s+(.*)/);if(ul){if(!inUl){closeBlocks();out.push('<ul>');inUl=true;}out.push('<li>'+inline(ul[1])+'</li>');continue;}"
		. "var ol=l.match(/^\d+\.\s+(.*)/);if(ol){if(!inOl){closeBlocks();out.push('<ol>');inOl=true;}out.push('<li>'+inline(ol[1])+'</li>');continue;}"
		. "closeBlocks();out.push('<p>'+inline(l)+'</p>');}"
		. "if(inPre)out.push('</code></pre>');closeBlocks();"
		. "return out.join('\n');}"
		. "var emptyMsg=" . _Updater_JsStr(t("updater.changelog_empty")) . ";"
		. "var md=" . _Updater_JsStr(md) . ";"
		. "document.body.innerHTML=mdToHtml(md);"
		. "</script></body></html>"
	)
}

; Converts the GitHub-release Markdown subset to clean, readable plain text for the
; native (no-WebView2) fallback. Mirrors the subset rendered by
; _Updater_MakeMarkdownHtml so the low-RAM view stays faithful: headings, bold,
; italic, inline code, links, lists, blockquotes and horizontal rules. It cannot
; reproduce fonts or colours, but it strips the raw markup so the notes read as
; prose instead of "## ... **...**".
_Updater_MarkdownToPlain(md) {
	if (md = "")
		return md
	s := md
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
