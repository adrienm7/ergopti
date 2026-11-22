; modules/updater/changelog.ahk

; ==============================================================================
; MODULE: Updater / Menu Actions + Changelog UI
; DESCRIPTION:
; The dynamic update menu state and label, one-click update flow, the Versions
; window entry and the release notes shown by the update prompt (the shared
; release-notes page). Neither window has a native form any more (maintainer
; decision 2026-11-21): the shared page splits and renders the release body.
;
; Split out of modules/updater.ahk (the module split); see modules/updater.ahk for the module
; overview. Functions and globals are hoisted, so load order across the
; updater/*.ahk files is irrelevant.
; ==============================================================================

#Include %A_LineFile%\..\..\..\core\ui\engine\font_scale.ahk



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
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
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

; @param CheckOnly {Boolean} The answer comes from the public Atom feed: a release
;   it names is announced, never installable.
; @param FeedFn {Func|Integer} Replaces _Updater_FetchFeedJsonAsync (tests only).
_Updater_OneClickUpdateCallback(Json, Current, Request, Terminal := 0, CheckOnly := false, FeedFn := 0) {
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

	if !CheckOnly && _Updater_JsonPayloadIsFailure(Json) {
		; api.github.com gave no list (blocked, throttled, rate-limited): the public
		; feed on github.com still tells whether a newer release exists.
		try LoggerInfo("Updater", "One-click check: the GitHub API gave no list; reading the public Atom feed.")
		_UpdaterCheckInProgress := true
		_Updater_ScheduleMenuRebuildForRequest(Request)
		OnFeed := (FeedJson, CompletedRequest, FeedTerminal := 0) => _Updater_OneClickUpdateCallback(
			FeedJson, Current, CompletedRequest, FeedTerminal, true)
		(IsObject(FeedFn) ? FeedFn : _Updater_FetchFeedJsonAsync).Call(Request.Channel, Request, OnFeed)
		return
	}
	Others := _Updater_RequestOtherChannels(Request)
	if _Updater_JsonPayloadIsFailure(Json) {
		try LoggerWarn("Updater", "One-click check: network unreachable.")
		try LoggerDone("Updater", "One-click update check finished without a network response.")
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return UpdateCheck_Abandon(Request)
		; The API's exhausted rate limit, when it answered one, names the failure (UPD-06)
		UpdateCheck_ShowResult(Request, Map("state", "error", "current", Current,
			"reason", "no_connection", "detail", "GitHub could not be reached",
			"rate_limited", Request.HasOwnProp("RateLimited") && Request.RateLimited == true,
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
	if CheckOnly {
		; Not published to the tray row: installing needs the API's asset list.
		try LoggerInfo("Updater", "One-click check: {1} found through the public feed, check only.", Latest)
		_Updater_ScheduleMenuRebuildForRequest(Request)
		if !_Updater_RequestMayPublish(Request)
			return UpdateCheck_Abandon(Request)
		UpdateCheck_ShowResult(Request, Map("state", "available", "current", Current, "latest", Latest,
			"others", Others, "release", Release, "check_only", true))
		return
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
	HasSuspendOverride := IsSet(IsSuspended)
	; The self-update transaction still stops at a pause (its staging monitor,
	; completion and swap), so an install asked while paused is refused visibly
	; rather than started and cancelled (UPD-2 leaves installs to a follow-up).
	if (HasSuspendOverride ? IsSuspended : A_IsSuspended)
		return _Updater_RefuseInstallWhileSuspended(NotifyFn)
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

; Opens the Versions window, which lists every release and lets the user read
; its notes. Available in all run modes — local-source users see published
; releases too.
Updater_ShowChangelog(*) {
	global UPDATER_CHANNEL
	; The shared-UI webview changelog (same HTML/CSS/JS as macOS) is the only
	; Versions window: without WebView2 it refuses with the shared message.
	Changelog_Open(UPDATER_CHANNEL)
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
	return "window.__i18n_base=" . JsonStringLiteral("https://" . RELEASE_NOTES_VHOST . "/core/i18n/data/locales/", true) . ";"
		. "window._i18n_locale=" . JsonStringLiteral(_I18nLocale, true) . ";"
		. ReadingPrefs_SeedScript()
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
	if !_Updater_RequestMayPublish(Request)
		return false
	Url := Payload.Get("url", "")
	if IsObject(OpenFn)
		return OpenFn.Call(Url, Request)
	return _Updater_OpenManualUrl(() => Url, Request)
}
