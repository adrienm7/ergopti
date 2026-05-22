; lib/updater.ahk

; ==============================================================================
; MODULE: Updater
; DESCRIPTION:
; Provides version display and update checking against GitHub Releases.
; Exposes menu-ready actions: show current version, open changelog, switch
; update channel (main vs dev), and check for updates.
;
; FEATURES & RATIONALE:
; 1. No background polling: checks are always user-initiated from the tray menu
;    so the driver never makes unexpected network calls.
; 2. Channel-aware: the user can switch between the "main" (stable) and "dev"
;    (pre-release) channels. The setting is persisted in the shared config TOML.
; 3. GitHub Releases API: uses a synchronous WinHttp call so no async plumbing
;    is needed. The call is gated behind the user clicking "Check for updates".
; ==============================================================================



; =====================================
; ===== 1.1) Constants & Defaults =====
; =====================================

global UPDATER_GH_OWNER  := "adrienm7"
global UPDATER_GH_REPO   := "ergopti"
global UPDATER_CHANNEL   := "main"    ; overwritten by Updater_LoadChannel()
global UPDATER_INI_KEY   := "channel"
global UPDATER_INI_SECTION := "ahk.updater"

; Background update-check interval. 0 means "never" (disabled). The default
; 24h cadence is a sensible balance between freshness and network restraint
; — most users do not want a release-day notification but appreciate hearing
; about a security fix within the same day. Honoured by ``Updater_StartBackgroundChecks``.
global UPDATER_INI_INTERVAL_KEY    := "check_interval_seconds"
global UPDATER_DEFAULT_INTERVAL    := 86400
global UPDATER_CHECK_INTERVAL      := UPDATER_DEFAULT_INTERVAL

; User-facing presets for the frequency submenu. Kept in display order so the
; menu renders the way users naturally read time: short to long, with the
; "off" row at the very bottom — a destructive choice deserves its own slot.
global UPDATER_INTERVAL_PRESETS := [
	{ Code: "1m",    Seconds: 60      },
	{ Code: "5m",    Seconds: 300     },
	{ Code: "10m",   Seconds: 600     },
	{ Code: "1h",    Seconds: 3600    },
	{ Code: "2h",    Seconds: 7200    },
	{ Code: "3h",    Seconds: 10800   },
	{ Code: "6h",    Seconds: 21600   },
	{ Code: "12h",   Seconds: 43200   },
	{ Code: "24h",   Seconds: 86400   },
	{ Code: "2d",    Seconds: 172800  },
	{ Code: "7d",    Seconds: 604800  },
	{ Code: "never", Seconds: 0       }
]

; Last release tag we already surfaced a notification for, so we don't keep
; nagging the user every interval tick about the same available update. Reset
; only when the user installs (or explicitly dismisses) the offer.
global UPDATER_LAST_NOTIFIED_TAG   := ""

; Latest release record cached from the most recent successful background check.
; Used by the "Show update" tray entry so clicking the notification or the menu
; row does not have to re-hit the GitHub API. Cleared after a successful install.
global UPDATER_LATEST_RELEASE      := unset

; Background timer handle so ``Updater_SetCheckInterval`` can stop the previous
; timer before scheduling a new one with the freshly chosen cadence.
global _UpdaterBackgroundFn        := unset



; ====================================
; ===== 1.2) Channel persistence =====
; ====================================

; Loads the saved channel from config.toml (via the shared INI cache).
;
; Priority order:
;   1. ``[Updater] UpdateChannel`` in config.toml — explicit user override
;      via the tray menu's "Update channel" submenu.
;   2. ``BUNDLE_CHANNEL`` stamped at build time — "dev" for pre-release exes,
;      "main" for stable. This means a user who downloads a dev pre-release
;      stays on dev (and gets pre-release update notifications) without
;      flipping any setting; the same exe published to main defaults to
;      "main".
;   3. Hardcoded "main" — last-resort default for dev / source-tree runs
;      where the build placeholder was never replaced.
Updater_LoadChannel() {
	global _IniCache, UPDATER_CHANNEL, UPDATER_INI_SECTION, UPDATER_INI_KEY
	global BUNDLE_CHANNEL

	; Step 2: seed from the build-stamped channel first (overridden below if
	; the user has an explicit config-file override).
	if IsSet(BUNDLE_CHANNEL)
		and (BUNDLE_CHANNEL == "main" or BUNDLE_CHANNEL == "dev") {
		UPDATER_CHANNEL := BUNDLE_CHANNEL
	}

	; Step 1: explicit user override always wins.
	if IsSet(_IniCache) {
		raw := IniCacheGet(_IniCache, UPDATER_INI_SECTION, UPDATER_INI_KEY)
		if (raw != "_" and (raw == "main" or raw == "dev"))
			UPDATER_CHANNEL := raw
	}
}

; Persists the chosen channel to config.toml and reloads the menu.
Updater_SetChannel(Channel) {
	global UPDATER_CHANNEL, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_KEY
	if (Channel != "main" and Channel != "dev")
		return
	UPDATER_CHANNEL := Channel
	TOML_Write(Channel, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_KEY)
	Reload
}


; =========================================
; ===== 1.2b) Check-interval persistence ==
; =========================================

; Reads the saved background-check cadence from the INI cache. Accepts any
; non-negative integer (seconds); 0 means "never". Defaults to 24h when the
; key is absent so a fresh install gets a sensible cadence out of the box.
Updater_LoadCheckInterval() {
	global _IniCache, UPDATER_CHECK_INTERVAL, UPDATER_INI_SECTION
	global UPDATER_INI_INTERVAL_KEY, UPDATER_DEFAULT_INTERVAL
	if !IsSet(_IniCache) {
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
	raw := IniCacheGet(_IniCache, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY)
	if (raw == "_" or raw == "") {
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
	; ``raw + 0`` coerces to a number; we floor at 0 so a malformed entry
	; downgrades to "never" rather than crashing the background poller.
	seconds := Integer(raw + 0)
	if (seconds < 0)
		seconds := 0
	UPDATER_CHECK_INTERVAL := seconds
}

; Persists the chosen cadence to config.toml AND restarts the background
; poller in-process so the change takes effect without a Reload. The menu
; re-tick has to wait for the next tray rebuild — that's fine because the
; same item is what triggered this call (the user sees their click confirmed).
Updater_SetCheckInterval(Seconds) {
	global UPDATER_CHECK_INTERVAL, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY
	if (Type(Seconds) != "Integer" or Seconds < 0)
		return
	UPDATER_CHECK_INTERVAL := Seconds
	try TOML_Write(Seconds, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY)
	try LoggerInfo("Updater", "Background check interval set to %d s.", Seconds)
	; Apply the new cadence immediately so the user does not have to reload.
	Updater_StopBackgroundChecks()
	Updater_StartBackgroundChecks()
	; Rebuild the tray menu so the check mark moves to the new row. ``initMenu``
	; is defined in ui/tray_menu.ahk; we call it indirectly via SetTimer so the
	; rebuild happens off the click handler's call stack (avoids surprising
	; reentrancy if the rebuild ever opens a fresh menu under the cursor).
	try SetTimer((*) => initMenu(), -50)
}



; ====================================
; ===== 1.3) Version helpers ==========
; ====================================

; Returns true when running directly from the AHK source tree (not compiled).
; Detected by checking A_IsCompiled, which is 1 only for .exe builds.
; This state takes priority over any user-selected channel — update checking
; is meaningless and channel selection is hidden when running from source.
Updater_IsLocalSource() {
	return !A_IsCompiled
}

; Returns the current driver version string.
; In compiled mode: BUNDLE_VERSION (stamped at build time).
; In local-source mode: the placeholder stays as-is → shown as "local".
Updater_CurrentVersion() {
	global BUNDLE_VERSION
	if Updater_IsLocalSource()
		return "local"
	if (BUNDLE_VERSION == "__BUNDLE_VERSION__" or BUNDLE_VERSION == "")
		return "local"
	return BUNDLE_VERSION
}

; Returns the GitHub Releases API URL for the chosen channel.
Updater_ReleaseApiUrl(Channel) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	if (Channel == "dev")
		; Latest pre-release: list releases and pick the first one.
		return "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases?per_page=1"
	; Stable: the dedicated "latest" endpoint always returns the newest non-pre-release.
	return "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases/latest"
}

; Returns the GitHub Releases HTML page URL (for "Open in browser" actions).
Updater_ReleasesPageUrl() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	return "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases"
}

; Returns the GitHub release URL to surface as the "current version" deep link
; in the tray menu. In compiled mode this is the stamped BUNDLE_RELEASE_URL
; (frozen at build time, so the link always points at the version actually
; running — even if a newer release has shipped since). In dev / source mode
; or when stamping failed we fall back to the channel's "latest" page so the
; menu entry still does something useful.
Updater_CurrentReleaseUrl() {
	global BUNDLE_RELEASE_URL, UPDATER_GH_OWNER, UPDATER_GH_REPO
	if IsSet(BUNDLE_RELEASE_URL)
		and BUNDLE_RELEASE_URL != ""
		and BUNDLE_RELEASE_URL != "__BUNDLE_RELEASE_URL__"
		return BUNDLE_RELEASE_URL
	return "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases/latest"
}

; Direct-link click handler for the tray's version label. The user explicitly
; asked for "no intermediate dialog": clicking the version line should jump
; straight to the release page in their default browser. Best-effort — any
; failure logs a warning so we don't pop a dialog on a flaky network.
Updater_OpenCurrentRelease(*) {
	try {
		Run(Updater_CurrentReleaseUrl())
	} catch as e {
		try LoggerWarn("Updater", "Failed to open release URL: {1}.", e.Message)
	}
}



; ====================================
; ===== 1.4) Network call =============
; ====================================

; Makes a synchronous GET to the GitHub Releases API and returns the raw JSON
; string. Returns "" on any error (network, HTTP non-200, COM failure).
Updater_FetchLatestJson(Channel) {
	Url := Updater_ReleaseApiUrl(Channel)
	Json := ""
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, false)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		Req.Send()
		if (Req.Status == 200)
			Json := Req.ResponseText
	} catch as Err {
		LoggerWarn("Updater", "HTTP request failed: {1}.", Err.Message)
	}
	return Json
}

; Returns the GitHub Releases LIST API URL for the channel. The page size is
; intentionally generous so the changelog window can show several months of
; history without paging — even on a busy dev channel that lands one release
; per commit. GitHub's free-tier limit (60 anon req/hour) leaves us plenty of
; headroom because the call is user-initiated only.
Updater_ReleasesListApiUrl(Channel := "") {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	return "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases?per_page=50"
}

; Fetches the releases LIST endpoint (synchronous, like ``Updater_FetchLatestJson``)
; and returns the raw JSON array string. Returns "" on any error.
Updater_FetchReleasesListJson(Channel := "") {
	Url := Updater_ReleasesListApiUrl(Channel)
	Json := ""
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, false)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		Req.Send()
		if (Req.Status == 200)
			Json := Req.ResponseText
	} catch as Err {
		LoggerWarn("Updater", "Releases list HTTP request failed: {1}.", Err.Message)
	}
	return Json
}

; Splits the top-level JSON array of releases into one substring per object,
; honouring quoted strings and escape sequences so a "}" inside a release body
; cannot fool the depth counter. Returns an Array of object-JSON strings.
_Updater_SplitReleasesArray(Json) {
	out := []
	Trimmed := LTrim(Json)
	if (SubStr(Trimmed, 1, 1) != "[")
		return out
	len := StrLen(Trimmed)
	pos := 2
	depth := 0
	start := 0
	in_str := false
	esc := false
	while (pos <= len) {
		c := SubStr(Trimmed, pos, 1)
		if in_str {
			if esc {
				esc := false
			} else if (c == "\") {
				esc := true
			} else if (c == '"') {
				in_str := false
			}
		} else {
			if (c == '"') {
				in_str := true
			} else if (c == "{") {
				if (depth == 0)
					start := pos
				depth += 1
			} else if (c == "}") {
				depth -= 1
				if (depth == 0 and start > 0) {
					out.Push(SubStr(Trimmed, start, pos - start + 1))
					start := 0
				}
			}
		}
		pos += 1
	}
	return out
}

; Extracts the boolean "prerelease" flag — true means a dev-channel release,
; false a stable one. Defaults to false when the field is absent.
_Updater_ParsePrerelease(Json) {
	if RegExMatch(Json, '"prerelease"\s*:\s*(true|false)', &M)
		return M[1] == "true"
	return false
}

; Extracts the "html_url" field from a single-release JSON object.
_Updater_ParseHtmlUrl(Json) {
	if RegExMatch(Json, '"html_url"\s*:\s*"([^"]+)"', &M)
		return M[1]
	return ""
}

; Extracts the "published_at" ISO-8601 timestamp from a release object.
_Updater_ParsePublishedAt(Json) {
	if RegExMatch(Json, '"published_at"\s*:\s*"([^"]+)"', &M)
		return M[1]
	return ""
}

; Build an array of release records from the raw JSON list. When ``MainOnly``
; is true the list is restricted to stable releases (``prerelease == false``);
; otherwise both pre-releases and stables come through so the dev channel can
; show every nightly side by side with the latest stable.
;
; Each entry: { Tag, Body, HtmlUrl, PublishedAt, Prerelease }. The original
; API order is preserved (GitHub returns most-recent first) so callers do not
; need to sort.
Updater_ParseReleasesList(Json, MainOnly := false) {
	out := []
	for _, chunk in _Updater_SplitReleasesArray(Json) {
		rec := {
			Tag:         Updater_ParseTagName(chunk),
			Body:        Updater_ParseBody(chunk),
			HtmlUrl:     _Updater_ParseHtmlUrl(chunk),
			PublishedAt: _Updater_ParsePublishedAt(chunk),
			Prerelease:  _Updater_ParsePrerelease(chunk)
		}
		if (rec.Tag == "")
			continue
		if (MainOnly and rec.Prerelease)
			continue
		out.Push(rec)
	}
	return out
}

; Extracts the "tag_name" field from a GitHub release JSON payload.
; Handles both object (latest endpoint) and array (list endpoint) responses.
Updater_ParseTagName(Json) {
	if (Json == "")
		return ""
	; Array response (dev channel: [{...}, ...]) — unwrap the first element.
	if (SubStr(LTrim(Json), 1, 1) == "[") {
		; Strip the leading "[" and grab the first object.
		Json := RegExReplace(Json, "^\s*\[", "")
	}
	if RegExMatch(Json, '"tag_name"\s*:\s*"([^"]+)"', &M)
		return M[1]
	return ""
}

; Extracts the "body" field (release notes markdown) from a GitHub release JSON.
Updater_ParseBody(Json) {
	if (Json == "")
		return ""
	if (SubStr(LTrim(Json), 1, 1) == "[")
		Json := RegExReplace(Json, "^\s*\[", "")
	if RegExMatch(Json, '"body"\s*:\s*"((?>(?:[^"\\]|\\.)*))"', &M) {
		; Unescape the most common JSON escape sequences.
		Body := M[1]
		Body := StrReplace(Body, "\n",  "`n")
		Body := StrReplace(Body, "\r",  "")
		Body := StrReplace(Body, "\t",  "`t")
		Body := StrReplace(Body, '\"',  '"')
		Body := StrReplace(Body, "\\",  "\")
		return Body
	}
	return ""
}



; ====================================
; ===== 1.5) Menu actions =============
; ====================================

; Displays the current version in a MsgBox and offers to open the releases page.
Updater_ShowVersion(*) {
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
		Run(Updater_ReleasesPageUrl())
}

; Checks GitHub for a newer release and shows the result.
Updater_CheckForUpdate(*) {
	global UPDATER_CHANNEL
	if Updater_IsLocalSource() {
		MsgBox(t("updater.local_source"), t("updater.title_update"), "Iconi")
		return
	}
	Current := Updater_CurrentVersion()
	MsgBox(Format(t("updater.checking"), UPDATER_CHANNEL),
		t("updater.title_update"), "Iconi T2")
	Json := Updater_FetchLatestJson(UPDATER_CHANNEL)
	if (Json == "") {
		MsgBox(t("updater.no_connection"), t("updater.title_update"), "Icon!")
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "") {
		MsgBox(t("updater.parse_failed"), t("updater.title_update"), "Icon!")
		return
	}
	if (Latest == Current) {
		MsgBox(Format(t("updater.up_to_date"), Current),
			t("updater.title_update"), "Iconi")
		return
	}
	Res := MsgBox(
		Format(t("updater.new_version"), Current, Latest),
		t("updater.title_update_available"),
		"YesNo Iconi"
	)
	if (Res == "Yes")
		Run(Updater_ReleasesPageUrl())
}

; Opens a window that lists every release on the active channel and lets the
; user expand any one of them to read its full notes. Two-pane layout: the
; left ListBox lists tags (newest first, mirroring the API order), the right
; Edit shows the selected release's body. "Open on GitHub" jumps to the
; selected release in the browser. Replaces the previous single-MsgBox UX
; which only ever surfaced the latest release.
Updater_ShowChangelog(*) {
	global UPDATER_CHANNEL
	; In local-source mode the channel is meaningless (the tray menu also
	; hides the entry there) — fall back to "main" defensively so a manual
	; invocation never surfaces dev-only nightlies to a source-tree user.
	EffectiveChannel := Updater_IsLocalSource() ? "main" : UPDATER_CHANNEL
	Json := Updater_FetchReleasesListJson(EffectiveChannel)
	if (Json == "") {
		MsgBox(t("updater.no_connection"), t("updater.title_changelog"), "Icon!")
		return
	}
	; Main-channel users only ever see stable releases; the dev channel folds
	; every nightly into the list so the user can read the per-commit notes.
	MainOnly := (EffectiveChannel != "dev")
	Releases := Updater_ParseReleasesList(Json, MainOnly)
	if (Releases.Length == 0) {
		MsgBox(t("updater.changelog_empty"), t("updater.title_changelog"), "Icon!")
		return
	}

	; Build the ListBox labels: tag + short date when present. The publish
	; date is sliced from the ISO timestamp so the row stays compact.
	Labels := []
	for _, R in Releases {
		Date := SubStr(R.PublishedAt, 1, 10)   ; "YYYY-MM-DD" or empty
		Marker := R.Prerelease ? "  (dev)" : ""
		Label := (Date != "") ? (R.Tag . "  —  " . Date . Marker) : (R.Tag . Marker)
		Labels.Push(Label)
	}

	G := Gui("+Resize +MinSize900x500", t("updater.title_changelog"))
	G.SetFont("s10", "Segoe UI")
	G.MarginX := 10
	G.MarginY := 10

	G.Add("Text", "xm w260", t("updater.changelog_select_release"))
	Lb := G.Add("ListBox", "xm y+4 w260 h440 vRelLb", Labels)
	BodyEdit := G.Add("Edit", "x+10 yp w620 h440 ReadOnly +HScroll +Multi -Wrap vBodyEdit", "")
	BtnOpen := G.Add("Button", "xm y+10 w260", t("updater.open_on_github"))
	BtnClose := G.Add("Button", "x+10 yp w620 Default", t("updater.close"))

	; Helper closure: refresh the right pane each time the selection moves.
	; Falls back to a localised "no notes available" string when the body is
	; empty so the user is never left staring at a blank pane.
	RefreshBody := (*) => (
		(Idx := Lb.Value) > 0 ? (
			BodyEdit.Value := (Releases[Idx].Body != "")
				? Releases[Idx].Body
				: t("updater.changelog_empty")
		) : ""
	)
	OpenSelected := (*) => (
		(Idx := Lb.Value) > 0 ? Run(Releases[Idx].HtmlUrl != ""
			? Releases[Idx].HtmlUrl
			: Updater_ReleasesPageUrl()) : ""
	)

	Lb.OnEvent("Change", RefreshBody)
	; Double-click on a release opens it in the browser — the standard
	; affordance for "this is the actionable element of a list".
	Lb.OnEvent("DoubleClick", OpenSelected)
	BtnOpen.OnEvent("Click", OpenSelected)
	BtnClose.OnEvent("Click", (*) => G.Destroy())
	G.OnEvent("Close",        (*) => G.Destroy())
	G.OnEvent("Escape",       (*) => G.Destroy())

	Lb.Choose(1)
	RefreshBody()
	G.Show("w900 h510")
}





; =============================================================
; ==============================================================
; ======= 2/ Self-update: asset parser, swap, background =======
; ==============================================================
; =============================================================



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
	InStr := false
	Esc := false
	EndPos := 0
	pos := StartPos
	while (pos <= Len) {
		c := SubStr(Json, pos, 1)
		if InStr {
			if Esc {
				Esc := false
			} else if (c == "\") {
				Esc := true
			} else if (c == '"') {
				InStr := false
			}
		} else {
			if (c == '"') {
				InStr := true
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
	; Fire once shortly after boot so users with a "1m" preset don't have to
	; wait 24h on first install for the welcome ping. Then settle into the
	; configured cadence.
	SetTimer(_UpdaterBackgroundFn, -30000)
	try LoggerSuccess("Updater", "Background update checks armed.")
}

; Stops the periodic timer if armed. Safe to call when nothing is running.
Updater_StopBackgroundChecks() {
	global _UpdaterBackgroundFn
	if !IsSet(_UpdaterBackgroundFn)
		return
	try LoggerTrace("Updater", "Stopping background update checks…")
	try SetTimer(_UpdaterBackgroundFn, 0)
	_UpdaterBackgroundFn := unset
	try LoggerDone("Updater", "Background update checks stopped.")
}

; One iteration of the background poller: hits GitHub silently, compares
; tags, surfaces a TrayTip on a NEW version (dedupe via LAST_NOTIFIED_TAG),
; then re-arms itself with the current configured interval. Any failure is
; logged and the loop continues — network blips must not silently kill the
; updater.
Updater_BackgroundTick(*) {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_LAST_NOTIFIED_TAG
	global UPDATER_LATEST_RELEASE, _UpdaterBackgroundFn
	; Re-arm first so a thrown error below cannot leave the loop dead.
	if IsSet(_UpdaterBackgroundFn) and UPDATER_CHECK_INTERVAL > 0 {
		try SetTimer(_UpdaterBackgroundFn, UPDATER_CHECK_INTERVAL * 1000)
	}
	if Updater_IsLocalSource()
		return
	Current := Updater_CurrentVersion()
	Json := Updater_FetchLatestJson(UPDATER_CHANNEL)
	if (Json == "") {
		try LoggerDebug("Updater", "Background check: network unreachable.")
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "" or Latest == Current) {
		try LoggerDebug("Updater", "Background check: up to date ({1}).", Current)
		return
	}
	if (UPDATER_LAST_NOTIFIED_TAG == Latest) {
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
	; The TrayTip is the user's entry point: clicking the icon opens the
	; full changelog + install UI. AHK v2 routes TrayTip clicks through
	; OnNotify (NIN_BALLOONUSERCLICK) — wired below in Updater_InitTrayTipHandler.
	try TrayTip(Format(t("updater.tray_new_version_body"), Latest), t("updater.tray_new_version_title"))
}



; =========================================
; ===== 2.3) "Update now" UI ============
; =========================================

; Two-pane window: release tag/date on the left summary, full release notes
; on the right, with three buttons at the bottom: ``Update now`` (downloads
; the asset and triggers the swap), ``Open on GitHub`` (browser fallback),
; and ``Later`` (close). Used both from the TrayTip click and from the
; explicit "Show update" menu item that appears on new-version availability.
Updater_ShowUpdatePrompt(Release) {
	if (Type(Release) != "Object")
		return
	G := Gui("+Resize +MinSize720x420 +AlwaysOnTop", t("updater.update_dialog_title"))
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
	BodyText := (Release.Body != "") ? Release.Body : t("updater.changelog_empty")
	G.Add("Edit", "xm y+4 w700 h300 ReadOnly +Multi -Wrap +HScroll", BodyText)

	BtnInstall := G.Add("Button", "xm y+12 Default", t("updater.update_dialog_install"))
	BtnOpen    := G.Add("Button", "x+8 yp",          t("updater.update_dialog_open"))
	BtnLater   := G.Add("Button", "x+8 yp",          t("updater.update_dialog_later"))

	BtnInstall.OnEvent("Click", (*) => (G.Destroy(), Updater_DownloadAndInstall(Release)))
	BtnOpen.OnEvent("Click",    (*) => Run(Release.HasProp("HtmlUrl") and Release.HtmlUrl != ""
		? Release.HtmlUrl : Updater_ReleasesPageUrl()))
	BtnLater.OnEvent("Click",   (*) => G.Destroy())
	G.OnEvent("Close",  (*) => G.Destroy())
	G.OnEvent("Escape", (*) => G.Destroy())
	G.Show("w740 AutoSize")
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
	; No cached release — synchronously fetch one. ``T2`` ensures the
	; placeholder dialog auto-dismisses after 2s if the user is impatient.
	MsgBox(Format(t("updater.checking"), UPDATER_CHANNEL), t("updater.title_update"), "Iconi T2")
	Json := Updater_FetchLatestJson(UPDATER_CHANNEL)
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

; Downloads the release asset to a staging folder, writes a tiny swap batch,
; spawns it detached and exits the current process. The batch waits for our
; exe handle to release, moves the new exe over the current one, then
; relaunches. Best-effort: surfaces a single localized error MsgBox on any
; pre-exit failure so the user knows it didn't work.
Updater_DownloadAndInstall(Release) {
	global BUNDLE_RELEASE_ASSET
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

	; Staging dir lives under LOCALAPPDATA so the swap survives reboots and
	; the user does not need write access to the EXE's directory.
	LocalAppData := EnvGet("LOCALAPPDATA")
	if (LocalAppData == "") {
		try LocalAppData := A_LocalAppData
	}
	if (LocalAppData == "") {
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
		return
	}
	StagingDir := LocalAppData . "\Ergopti\updates"
	try DirCreate(StagingDir)
	NewExe := StagingDir . "\ErgoptiPlus_new.exe"
	SwapBat := StagingDir . "\swap_update.cmd"
	CurrentExe := A_ScriptFullPath
	try {
		if FileExist(NewExe)
			FileDelete(NewExe)
	}

	try LoggerStart("Updater", "Downloading update '{1}' from {2}…", Release.Tag, AssetUrl)
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", AssetUrl, false)
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		Req.Send()
		if (Req.Status != 200) {
			try LoggerError("Updater", "Asset download returned HTTP {1}.", Req.Status)
			MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
			return
		}
		Stream := ComObject("ADODB.Stream")
		Stream.Type := 1     ; adTypeBinary
		Stream.Open()
		Stream.Write(Req.ResponseBody)
		Stream.SaveToFile(NewExe, 2)   ; adSaveCreateOverWrite
		Stream.Close()
	} catch as e {
		try LoggerError("Updater", "Download failed: {1}.", e.Message)
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		return
	}
	if !FileExist(NewExe) {
		try LoggerError("Updater", "Download completed but file missing at '{1}'.", NewExe)
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		return
	}
	try LoggerSuccess("Updater", "Update downloaded to '{1}'.", NewExe)

	; Swap script: waits for the parent exe handle to release, replaces the
	; binary, then relaunches it. Uses CMD (built-in, no PowerShell startup
	; cost). ``timeout /t N /nobreak`` is the standard "sleep N seconds" idiom.
	; The ``goto :eof`` at the end prevents the script from inheriting any
	; lingering shell state.
	; Single-quoted outer strings let us embed literal double quotes around
	; the batch %VARS% without escape gymnastics. Each `r`n is concatenated
	; from a double-quoted neighbour because escape sequences only resolve
	; inside double-quoted AHK strings.
	BatLines := "@echo off`r`n"
		. "setlocal`r`n"
		. "set NEW_EXE=" . NewExe . "`r`n"
		. "set CUR_EXE=" . CurrentExe . "`r`n"
		. "timeout /t 2 /nobreak >nul 2>&1`r`n"
		. ":retry`r`n"
		. 'del /q "%CUR_EXE%" >nul 2>&1' . "`r`n"
		. 'if exist "%CUR_EXE%" (' . "`r`n"
		. "    timeout /t 1 /nobreak >nul 2>&1`r`n"
		. "    goto retry`r`n"
		. ")`r`n"
		. 'move /y "%NEW_EXE%" "%CUR_EXE%" >nul 2>&1' . "`r`n"
		. 'if exist "%CUR_EXE%" (' . "`r`n"
		. '    start "" "%CUR_EXE%"' . "`r`n"
		. ")`r`n"
		. "goto :eof`r`n"
	try {
		if FileExist(SwapBat)
			FileDelete(SwapBat)
		FileAppend(BatLines, SwapBat, "CP0")
	} catch as e {
		try LoggerError("Updater", "Could not write swap script: {1}.", e.Message)
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
		return
	}
	try LoggerInfo("Updater", "Launching swap script and exiting in 1s…")
	; Run detached and hidden so the user does not see a black flash. Then
	; ExitApp so our handle on the current exe drops and the swap can proceed.
	try Run('cmd /c "' . SwapBat . '"', , "Hide")
	; Reset the dedupe so a future user-driven check after a failure can
	; re-prompt; the post-swap exe will set its own state from scratch.
	global UPDATER_LAST_NOTIFIED_TAG := ""
	; Tiny delay lets the spawned cmd actually start polling before we vanish.
	Sleep(200)
	ExitApp(0)
}
