; lib/updater/self_update.ahk

; ==============================================================================
; MODULE: Updater / Self-update Download + Swap + Background
; DESCRIPTION:
; The self-update mechanism: release-asset URL parser, background polling timer, tray-notify handler, the update prompt, and the download + executable-swap install flow.
;
; Split out of lib/updater.ahk (the module split); see lib/updater.ahk for the module
; overview. Functions and globals are hoisted, so load order across the
; updater/*.ahk files is irrelevant.
; ==============================================================================





; ==============================================================
; ==============================================================
; ======= 2/ Self-update: asset parser, swap, background =======
; ==============================================================
; ==============================================================



; ====================================
; ===== 2.1) Asset URL parser ========
; ====================================

; Walks the release JSON to find the ``assets`` array, then returns the
; ``browser_download_url`` of the asset whose ``name`` exactly matches
; ``AssetName``. Returns "" on any failure (no assets array, no match, …).
; Bracket-aware so a "]" inside a quoted body field cannot confuse the
; depth counter — same pattern as ``_Updater_SplitReleasesArray``.
_Updater_FindAssetUrl(Json, AssetName) {
	if !RegExMatch(Json, '"assets"\s*:\s*\[', &Anchor)
		return ""
	StartPos := Anchor.Pos + Anchor.Len - 1   ; position of the "[" itself
	Len := StrLen(Json)
	Depth := 0
    InQuotedString := false
	Esc := false
	EndPos := 0
	pos := StartPos
	while (pos <= Len) {
		c := SubStr(Json, pos, 1)
        if InQuotedString {
			if Esc {
				Esc := false
			} else if (c == "\") {
				Esc := true
			} else if (c == '"') {
                InQuotedString := false
			}
		} else {
			if (c == '"') {
                InQuotedString := true
			} else if (c == "[") {
				Depth += 1
			} else if (c == "]") {
				Depth -= 1
				if (Depth == 0) {
					EndPos := pos
					break
				}
			}
		}
		pos += 1
	}
	if (EndPos == 0)
		return ""
	AssetsBlock := SubStr(Json, StartPos, EndPos - StartPos + 1)

	; Each asset is a flat JSON object; match the one whose "name" equals
	; AssetName, then extract its "browser_download_url".
	Escaped := RegExReplace(AssetName, "([\.\\\(\)\[\]\{\}\^\$\|\+\*\?])", "\$1")
	Pattern := '\{[^{}]*"name"\s*:\s*"' . Escaped . '"[^{}]*\}'
	if !RegExMatch(AssetsBlock, Pattern, &O)
		return ""
	if !RegExMatch(O[0], '"browser_download_url"\s*:\s*"([^"]+)"', &U)
		return ""
	return U[1]
}



; =========================================
; ===== 2.2) Background poller ==========
; =========================================

; Schedules the periodic update check. No-op when:
;   - we're running from source (Updater_IsLocalSource — meaningless),
;   - the interval is 0 ("never"),
;   - a timer is already armed.
; ``SetTimer`` uses negative period syntax for "fire after N ms" but we want
; periodic firing — so we use a positive period (interval × 1000 ms).
Updater_StartBackgroundChecks() {
	global UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	if Updater_IsLocalSource() {
		try LoggerDebug("Updater", "Local source — background checks disabled.")
		return
	}
	if (UPDATER_CHECK_INTERVAL <= 0) {
		try LoggerDebug("Updater", "Check interval is 0 (never) — background checks disabled.")
		return
	}
	if IsSet(_UpdaterBackgroundFn) {
		try LoggerDebug("Updater", "Background checks already running — ignoring start.")
		return
	}
	_UpdaterBackgroundFn := Updater_BackgroundTick
	try LoggerStart("Updater", "Starting background update checks (every {1}s)…", UPDATER_CHECK_INTERVAL)
	; Fire once shortly after boot (capped by the configured interval) so short
	; presets like "1m" are honoured without an extra-long initial wait.
	FirstMs := Min(30000, Max(1000, UPDATER_CHECK_INTERVAL * 1000))
	SetTimer(_UpdaterBackgroundFn, -FirstMs)
	try LoggerSuccess("Updater", "Background update checks armed.")
}

; Stops the periodic timer if armed. Safe to call when nothing is running.
Updater_StopBackgroundChecks() {
	global _UpdaterBackgroundFn
	; Drop any in-flight async check first so a late response cannot still pop a
	; notification after the user disabled checks (e.g. switched to "never").
	_Updater_CancelAsyncChecks()
	if !IsSet(_UpdaterBackgroundFn)
		return
	try LoggerTrace("Updater", "Stopping background update checks…")
	try SetTimer(_UpdaterBackgroundFn, 0)
	_UpdaterBackgroundFn := unset
	try LoggerDone("Updater", "Background update checks stopped.")
}

; One iteration of the background poller: re-arms itself for the next interval,
; then dispatches a silent, ASYNCHRONOUS GitHub query. The response is harvested
; off this tick in _Updater_HandleBackgroundResult, so the network round-trip
; never blocks the main thread — the synchronous call here was what froze
; keyboard remapping a few seconds after startup on a slow or stalled network.
Updater_BackgroundTick(*) {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	; Re-arm first so a thrown error below cannot leave the loop dead.
	if IsSet(_UpdaterBackgroundFn) and UPDATER_CHECK_INTERVAL > 0 {
		try SetTimer(_UpdaterBackgroundFn, UPDATER_CHECK_INTERVAL * 1000)
	}
	; Pause invariant: a suspended driver must be fully silent. SetTimer
	; callbacks are not gated by native Suspend, so we re-arm above (so the
	; loop survives pause and resumes cleanly) but skip the network dispatch,
	; the TrayTip and the tray-menu rebuild while suspended.
	if A_IsSuspended
		return
	if Updater_IsLocalSource()
		return
	Current := Updater_CurrentVersion()
	; ``Current`` is captured by the closure and stays valid until the async
	; fetch completes and the callback runs.
	_Updater_FetchLatestJsonAsync(UPDATER_CHANNEL, (Json) => _Updater_HandleBackgroundResult(Json, Current))
}

; Completion handler for a background check, invoked once the async fetch
; finishes (Json == "" on any failure). Compares tags, dedupes via
; LAST_NOTIFIED_TAG, and on a genuinely new release caches it, rebuilds the tray
; menu, and surfaces a TrayTip. Any failure is logged and the loop just waits
; for the next interval — a network blip must not silently kill the updater.
_Updater_HandleBackgroundResult(Json, Current) {
	; A stale async callback can land after the script was suspended (e.g. password
	; field, manual pause). Surfacing a notification or rebuilding the menu then is
	; both pointless and disruptive — bail before touching any state.
	if A_IsSuspended
		return
	global UPDATER_LAST_NOTIFIED_TAG, UPDATER_LATEST_RELEASE
	if (Json == "") {
		try LoggerDebug("Updater", "Background check: network unreachable.")
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "" or !_Updater_IsNewerVersion(Latest, Current)) {
		try LoggerDebug("Updater", "Background check: up to date ({1}).", Current)
		return
	}
	if (_Updater_NormalizeTag(UPDATER_LAST_NOTIFIED_TAG) == _Updater_NormalizeTag(Latest)) {
		try LoggerDebug("Updater", "Background check: {1} already notified — skipping ping.", Latest)
		return
	}
	UPDATER_LAST_NOTIFIED_TAG := Latest
	UPDATER_LATEST_RELEASE := {
		Tag:         Latest,
		Body:        Updater_ParseBody(Json),
		RawJson:     Json,
		HtmlUrl:     _Updater_ParseHtmlUrl(Json),
		PublishedAt: _Updater_ParsePublishedAt(Json),
		Prerelease:  _Updater_ParsePrerelease(Json)
	}
	try LoggerInfo("Updater", "New release available: {1} (current: {2}).", Latest, Current)
	; Rebuild the tray menu so the one-click item label changes to
	; "Mettre à jour vers vX.Y.Z" without requiring a manual open.
	try SetTimer((*) => _Updater_RebuildMenu(), -50)
	; The TrayTip is the user's entry point: clicking the notification bubble opens
	; the full update prompt. The click is intercepted via OnMessage below.
	try TrayTip(Format(t("updater.tray_new_version_body"), Latest), t("updater.tray_new_version_title"))
}

; Wires an OnMessage handler so clicking a Windows balloon notification fires
; Updater_ShowAvailableUpdate. AHK v2 does not expose a dedicated TrayTip-click
; callback, but Windows posts WM_TRAYICON (0x404) with lParam == 0x405
; (NIN_BALLOONUSERCLICK) when the user clicks the notification body.
; Safe to call multiple times — the handler is idempotent (OnMessage replaces
; any prior registration for the same message + function pair).
Updater_InitTrayNotifyHandler() {
	; maxThreads=1: no reentrant update prompts.
	OnMessage(0x404, _Updater_OnTrayMsg, 1)
	try LoggerDebug("Updater", "Tray notification click handler registered.")
}

; OnMessage handler for WM_TRAYICON (0x404).
; lParam 0x405 = NIN_BALLOONUSERCLICK — user clicked the notification body.
; Returns "" to let AHK continue its own tray processing.
_Updater_OnTrayMsg(wParam, lParam, msg, hwnd) {
	; An OnMessage handler bypasses native Suspend() entirely (it only disarms
	; Hotkeys/Hotstrings) — a balloon click landing after the driver was paused
	; must not still pop the update prompt. Deliberately narrower than guarding
	; Updater_ShowAvailableUpdate itself, which also backs the tray menu's
	; "check for updates" item — a menu click is an explicit interaction that
	; must keep working while paused (the tray menu is how the user un-pauses).
	if (lParam == 0x405 and !A_IsSuspended)
		try Updater_ShowAvailableUpdate()
	return ""
}



; =========================================
; ===== 2.3) "Update now" UI ============
; =========================================

; Singleton handle for the update-prompt Gui -- reused across calls so a second
; trigger (TrayTip click, changelog "Install this version", "Show update" menu
; item) brings the existing dialog to the front instead of opening a duplicate
; that could race Updater_DownloadAndInstall against the same staging file
; (updater-download-reentrancy).
global _Updater_PromptGui := unset
global _UpdaterDownloadWorker := 0

; Two-pane window: release tag/date on the left summary, full release notes
; on the right, with three buttons at the bottom: ``Update now`` (downloads
; the asset and triggers the swap), ``Open on GitHub`` (browser fallback),
; and ``Later`` (close). Used both from the TrayTip click and from the
; explicit "Show update" menu item that appears on new-version availability.
Updater_ShowUpdatePrompt(Release) {
	global _VendorDir, _Updater_PromptGui
	if (Type(Release) != "Object")
		return
	; Singleton: bring the existing prompt forward instead of opening a
	; duplicate dialog that could trigger a second concurrent download
	; (updater-download-reentrancy).
	if IsSet(_Updater_PromptGui) {
		try LoggerDebug("Updater", "Update prompt already open -- reusing existing window instead of opening a duplicate.")
		try _Updater_PromptGui.Restore()
		try WinActivate(_Updater_PromptGui.Hwnd)
		return
	}
	G := Gui("+Resize +MinSize720x420 +AlwaysOnTop", t("updater.update_dialog_title"))
	_Updater_PromptGui := G
	G.SetFont("s11 bold", "Segoe UI")
	G.MarginX := 14
	G.MarginY := 12
	; Header: "Update available — vX.Y.Z" so the user immediately sees the
	; tag they're about to install. Date below if we have one.
	HeaderText := Format(t("updater.update_dialog_header"), Release.Tag)
	G.Add("Text", "xm w700", HeaderText)
	G.SetFont("s9 norm")
	if (Release.HasProp("PublishedAt") and Release.PublishedAt != "") {
		G.Add("Text", "xm y+2 cGray w700", SubStr(Release.PublishedAt, 1, 10))
	}
	G.SetFont("s10 norm")
	G.Add("Text", "xm y+10 w700", t("updater.update_dialog_changelog"))

	; Placeholder that WebView2 overlays — same height as the former Edit control.
	BodyPane := G.Add("Text", "xm y+4 w700 h300", "")

	BtnInstall := G.Add("Button", "xm y+12 Default", t("updater.update_dialog_install"))
	BtnOpen    := G.Add("Button", "x+8 yp",          t("updater.update_dialog_open"))
	BtnLater   := G.Add("Button", "x+8 yp",          t("updater.update_dialog_later"))

	BtnInstall.OnEvent("Click", (*) => (_Updater_CloseGui(G), Updater_DownloadAndInstall(Release)))
	BtnOpen.OnEvent("Click",    (*) => Run(Release.HasProp("HtmlUrl") and Release.HtmlUrl != ""
		? Release.HtmlUrl : Updater_ReleasesPageUrl()))
	BtnLater.OnEvent("Click",   (*) => _Updater_CloseGui(G))
	G.WVC := 0
	G.OnEvent("Close",  (*) => _Updater_CloseGui(G))
	G.OnEvent("Escape", (*) => _Updater_CloseGui(G))
	G.Show("w740 AutoSize")

	; Spin up WebView2 for Markdown rendering after Show() (Hwnd is valid then).
	UseWV := IsSet(WebView2) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll") && !WebView_ShouldUseNativeFallback()
	if UseWV {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		WVC := unset
		try {
			; Reuse the shared session environment (lib/webview_utils.ahk) so no
			; second Chromium process boots and reopens are near-instant.
			WVC := WebView2.create(BodyPane.Hwnd, , WebView_SharedEnvironment(loader))
			G.WVC := WVC
		} catch as Err {
			try LoggerWarn("Updater", "WebView2 create failed in update prompt: {1}.", Err.Message)
			UseWV := false
		}
		if UseWV and IsSet(WVC) {
			try {
				s := WVC.CoreWebView2.Settings
				s.AreDevToolsEnabled              := false
				s.AreDefaultContextMenusEnabled   := false
				s.IsStatusBarEnabled              := false
				s.AreBrowserAcceleratorKeysEnabled := false
			}
			WVC.Fill()
			WVC.CoreWebView2.NavigateToString(_Updater_MakeMarkdownHtml(Release.Body))
		}
	}
	if (!UseWV or !IsSet(WVC)) {
		; Fallback: replace the placeholder with a plain read-only Edit.
		BodyPane.GetPos(&bx, &by, &bw, &bh)
		BodyText := (Release.Body != "") ? _Updater_MarkdownToPlain(Release.Body) : t("updater.changelog_empty")
		G.Add("Edit", "x" . bx . " y" . by . " w" . bw . " h" . bh
			. " ReadOnly +Multi -Wrap +VScroll", BodyText)
	}
}

_Updater_CloseGui(G) {
	global _Updater_PromptGui
	; Identity check happens BEFORE Destroy() so it never depends on reading
	; state from an already torn-down Gui. _Updater_CloseGui is shared with
	; the changelog window's own Gui instance, so only clear the singleton
	; when this call is actually closing the update prompt.
	IsPromptGui := IsSet(_Updater_PromptGui) && (G.Hwnd == _Updater_PromptGui.Hwnd)
	if G.HasProp("WVC") && G.WVC
		try G.WVC.Close()
	try G.Destroy()
	if IsPromptGui
		_Updater_PromptGui := unset
}


; Menu/notification entry point — pulls the cached release record from the
; last background tick when present, otherwise hits the API on the spot so
; the user can always summon the prompt from the tray.
Updater_ShowAvailableUpdate(*) {
	global UPDATER_LATEST_RELEASE, UPDATER_CHANNEL
	if IsSet(UPDATER_LATEST_RELEASE) and Type(UPDATER_LATEST_RELEASE) == "Object" {
		Updater_ShowUpdatePrompt(UPDATER_LATEST_RELEASE)
		return
	}
	if Updater_IsLocalSource() {
		MsgBox(t("updater.local_source"), t("updater.title_update"), "Iconi")
		return
	}
	; No cached release — fetch one ASYNCHRONOUSLY so the network round-trip
	; never blocks the AHK main thread (a synchronous WinHttp.Send here would
	; freeze keyboard remapping and drop keystrokes for the whole resolve /
	; connect / receive budget on a stalled or captive-portal network). ``T2``
	; auto-dismisses the brief "Verification…" notice; the actual update prompt
	; is surfaced from the async callback once the response arrives.
	MsgBox(Format(t("updater.checking"), UPDATER_CHANNEL), t("updater.title_update"), "Iconi T2")
	_Updater_FetchLatestJsonAsync(UPDATER_CHANNEL, (Json) => _Updater_ShowAvailableUpdateCallback(Json))
}

; Completion handler for the async fetch dispatched by Updater_ShowAvailableUpdate
; when no release is cached. Mirrors the synchronous tail it replaced: surfaces a
; localized error on failure, otherwise builds the release record and shows the
; update prompt. Runs off a poll timer so it never blocks the main thread.
_Updater_ShowAvailableUpdateCallback(Json) {
	if A_IsSuspended
		return
	if (Json == "") {
		MsgBox(t("updater.no_connection"), t("updater.title_update"), "Icon!")
		return
	}
	Tag := Updater_ParseTagName(Json)
	if (Tag == "") {
		MsgBox(t("updater.parse_failed"), t("updater.title_update"), "Icon!")
		return
	}
	Release := {
		Tag:         Tag,
		Body:        Updater_ParseBody(Json),
		RawJson:     Json,
		HtmlUrl:     _Updater_ParseHtmlUrl(Json),
		PublishedAt: _Updater_ParsePublishedAt(Json),
		Prerelease:  _Updater_ParsePrerelease(Json)
	}
	Updater_ShowUpdatePrompt(Release)
}



; =====================================================
; ===== 2.4) Download + swap (binary replacement) =====
; =====================================================

; Dispatches the whole staging transaction to a child process. AHK's one
; interpreter thread is also the keyboard hook thread, so response-body COM,
; disk persistence, integrity checks and batch creation must never run here.
; This side only validates the request, launches/polls the worker and performs
; the final non-blocking process hand-off after the worker reports READY.
Updater_DownloadAndInstall(Release) {
	global BUNDLE_RELEASE_ASSET
	global _UpdaterDownloadInProgress
	; Re-entrancy guard: two independent "Update now" triggers (the TrayTip
	; update prompt and the changelog's "Install this version" button, each
	; opening its own dialog) can both reach this function before the first
	; download finishes. Without this check both open a second async WinHTTP
	; request against the SAME staging file, and the two eventual stream
	; writes to disk race with no lock, risking a corrupted or truncated exe
	; that the swap script then moves into production
	; (updater-download-reentrancy).
	if _UpdaterDownloadInProgress {
		try LoggerWarn("Updater", "Download already in progress -- ignoring duplicate Updater_DownloadAndInstall call.")
		return
	}
	if (Type(Release) != "Object" or !Release.HasProp("RawJson")) {
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
		return
	}
	AssetName := IsSet(BUNDLE_RELEASE_ASSET) and BUNDLE_RELEASE_ASSET != ""
		? BUNDLE_RELEASE_ASSET : "ErgoptiPlus.exe"
	AssetUrl := _Updater_FindAssetUrl(Release.RawJson, AssetName)
	if (AssetUrl == "") {
		try LoggerError("Updater", "No asset named '{1}' in release '{2}'.", AssetName, Release.Tag)
		MsgBox(t("updater.install_error_no_asset"), t("updater.title_update"), "Icon!")
		return
	}
	if !A_IsCompiled {
		; Running from source — replacing the .ahk would be wrong, and the
		; user is almost certainly developing on this very tree. Bail with a
		; friendly note rather than silently doing nothing.
		MsgBox(t("updater.install_local_source"), t("updater.title_update"), "Iconi")
		return
	}

	LocalAppData := ResolveLocalAppDataDir()
	if (LocalAppData == "") {
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
		return
	}
	StagingDir := LocalAppData . "\Ergopti\updates"
	NewExe := StagingDir . "\ErgoptiPlus_new.exe"
	SwapBat := StagingDir . "\swap_update.cmd"
	CurrentExe := A_ScriptFullPath
	try LoggerStart("Updater", "Downloading update '{1}' from {2}…", Release.Tag, AssetUrl)

	_UpdaterDownloadInProgress := true
	try SetTimer((*) => _Updater_RebuildMenu(), -50)
	_Updater_StartStagingWorker(AssetUrl, NewExe, SwapBat, CurrentExe, Release.Tag)
}


; Starts an isolated PowerShell transaction. ShellRunner owns process polling,
; preventing a slow CDN, antivirus scan or file flush from entering AHK's hook
; dispatch loop.
_Updater_StartStagingWorker(AssetUrl, NewExe, SwapBat, CurrentExe, Tag) {
	global _UpdaterDownloadWorker, UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS, UPDATER_MIN_EXE_SIZE_BYTES
	Script := _Updater_BuildStagingWorkerScript()
	_OnDone := (ExitCode, Stdout, Stderr) => _Updater_PollDownloadAsync(ExitCode, Stdout, Stderr, SwapBat, CurrentExe, Tag)
	_UpdaterDownloadWorker := ShellRunner_Spawn("powershell.exe",
		["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", Script,
			AssetUrl, NewExe, SwapBat, CurrentExe, UPDATER_MIN_EXE_SIZE_BYTES, UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS], _OnDone)
	if !_UpdaterDownloadWorker.start() {
		_UpdaterDownloadWorker := 0
		try LoggerError("Updater", "Could not launch the isolated update staging worker.")
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		_Updater_EndDownloadTransaction()
		return
	}
	SetTimer(_Updater_MonitorStagingWorker, UPDATER_ASYNC_POLL_MS)
}

; Cancels the subprocess while native Suspend is active. ShellRunner deliberately
; defers completion callbacks during Suspend, so this independent timer enforces
; the stronger invariant that no network or staging I/O remains alive while paused.
_Updater_MonitorStagingWorker(*) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	if !_UpdaterDownloadInProgress {
		SetTimer(_Updater_MonitorStagingWorker, 0)
		return
	}
	if !A_IsSuspended
		return
	if IsObject(_UpdaterDownloadWorker) {
		try _UpdaterDownloadWorker.terminate()
	}
	_UpdaterDownloadWorker := 0
	SetTimer(_Updater_MonitorStagingWorker, 0)
	try LoggerWarn("Updater", "Update staging aborted because the driver was suspended.")
	_Updater_EndDownloadTransaction()
}

; The only staging completion callback running in AHK. The worker's READY
; token means it has already persisted and verified the executable plus batch.
_Updater_PollDownloadAsync(ExitCode, Stdout, Stderr, SwapBat, CurrentExe, Tag) {
	global _UpdaterDownloadWorker
	_UpdaterDownloadWorker := 0
	SetTimer(_Updater_MonitorStagingWorker, 0)
	if A_IsSuspended {
		try LoggerWarn("Updater", "Update staging completion discarded while suspended.")
		_Updater_EndDownloadTransaction()
		return
	}
	if (ExitCode != 0 or Stdout != "READY") {
		try LoggerError("Updater", "Update staging worker failed (exit {1}): {2}.", ExitCode, Stdout)
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		_Updater_EndDownloadTransaction()
		return
	}
	try LoggerSuccess("Updater", "Update downloaded and verified for '{1}'.", Tag)
	_SwapLaunched := false
	try {
		Run(A_ComSpec . ' /c "' . SwapBat . '"', , "Hide")
		_SwapLaunched := true
	} catch as Err {
		try LoggerError("Updater", "Swap script launch failed: {1}.", Err.Message)
	}
	if !_SwapLaunched {
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
		_Updater_EndDownloadTransaction()
		return
	}
	global UPDATER_LAST_NOTIFIED_TAG := ""
	ExitApp(0)
}

; Returns a self-contained worker script. Paths and URLs are passed as argv,
; never interpolated into the script, so release metadata cannot alter commands.
_Updater_BuildStagingWorkerScript() {
	return 'param([string]$Url, [string]$NewExe, [string]$SwapBat, [string]$CurrentExe, [int64]$MinimumSize, [int]$TimeoutMs)' . "`n"
		. '$ErrorActionPreference = "Stop"' . "`n"
		. 'try {' . "`n"
		. '  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NewExe) | Out-Null' . "`n"
		. '  Remove-Item -LiteralPath $NewExe -Force -ErrorAction SilentlyContinue' . "`n"
		. '  Remove-Item -LiteralPath $SwapBat -Force -ErrorAction SilentlyContinue' . "`n"
		. '  $Request = [System.Net.HttpWebRequest]::Create($Url)' . "`n"
		. '  $Request.Method = "GET"' . "`n"
		. '  $Request.UserAgent = "ErgoptiPlus-Updater/1.0"' . "`n"
		. '  $Request.Timeout = $TimeoutMs' . "`n"
		. '  $Request.ReadWriteTimeout = $TimeoutMs' . "`n"
		. '  $Response = $Request.GetResponse()' . "`n"
		. '  if ([int]$Response.StatusCode -ne 200) { throw ("HTTP " + [int]$Response.StatusCode) }' . "`n"
		. '  $ExpectedSize = [int64]$Response.ContentLength' . "`n"
		. '  $Input = $Response.GetResponseStream()' . "`n"
		. '  $Output = [System.IO.File]::Open($NewExe, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)' . "`n"
		. '  try { $Input.CopyTo($Output) } finally { $Output.Dispose(); $Input.Dispose(); $Response.Dispose() }' . "`n"
		. '  $ActualSize = (Get-Item -LiteralPath $NewExe).Length' . "`n"
		. '  if ($ExpectedSize -gt 0 -and $ActualSize -ne $ExpectedSize) { Remove-Item -LiteralPath $NewExe -Force; throw "Content-Length mismatch" }' . "`n"
		. '  if ($ActualSize -lt $MinimumSize) { Remove-Item -LiteralPath $NewExe -Force; throw "Downloaded file is too small" }' . "`n"
		. '  $Quote = [char]34' . "`n"
		. '  $CurrentLeaf = Split-Path -Leaf $CurrentExe' . "`n"
		. '  $BakExe = $CurrentExe + ".bak"' . "`n"
		. '  $Batch = @(' . "`n"
		. '    "@echo off", "setlocal DisableDelayedExpansion", ("set NEW_EXE=" + $NewExe), ("set CUR_EXE=" + $CurrentExe), ("set BAK_EXE=" + $BakExe),' . "`n"
		. '    "timeout /t 2 /nobreak >nul 2>&1", ":retry", ("rename " + $Quote + "%CUR_EXE%" + $Quote + " " + $Quote + $CurrentLeaf + ".bak" + $Quote + " >nul 2>&1"),' . "`n"
		. '    "if exist %CUR_EXE% (", "    timeout /t 1 /nobreak >nul 2>&1", "    goto retry", ")",' . "`n"
		. '    ("move /y " + $Quote + "%NEW_EXE%" + $Quote + " " + $Quote + "%CUR_EXE%" + $Quote + " >nul 2>&1"),' . "`n"
		. '    "if not exist %CUR_EXE% (", ("    rename " + $Quote + "%BAK_EXE%" + $Quote + " " + $Quote + $CurrentLeaf + $Quote + " >nul 2>&1"), "    goto :eof", ")",' . "`n"
		. '    "del /q %BAK_EXE% >nul 2>&1", ("start " + $Quote + $Quote + " " + $Quote + "%CUR_EXE%" + $Quote), "goto :eof"' . "`n"
		. '  ) -join [Environment]::NewLine' . "`n"
		. '  [System.IO.File]::WriteAllText($SwapBat, $Batch, [System.Text.Encoding]::ASCII)' . "`n"
		. '  Write-Output "READY"' . "`n"
		. '  exit 0' . "`n"
		. '} catch {' . "`n"
		. '  try { if ($NewExe -and (Test-Path -LiteralPath $NewExe)) { Remove-Item -LiteralPath $NewExe -Force } } catch {}' . "`n"
		. '  Write-Output ("ERR:" + $_.Exception.Message)' . "`n"
		. '  exit 1' . "`n"
		. '}'
}

; The download guard spans HTTP polling, response persistence, integrity checks,
; swap-script creation, and the successful replacement hand-off. Releasing it
; merely because WaitForResponse completed admits a second updater transaction
; while both callbacks still target the same staging filenames.
_Updater_EndDownloadTransaction() {
	global _UpdaterDownloadInProgress
	_UpdaterDownloadInProgress := false
	try SetTimer((*) => _Updater_RebuildMenu(), -50)
}
