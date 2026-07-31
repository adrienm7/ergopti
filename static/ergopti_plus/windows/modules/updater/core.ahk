; modules/updater/core.ahk

; ==============================================================================
; MODULE: Updater / Config + Version + Release Fetch
; DESCRIPTION:
; Updater constants, channel and check-interval config, semantic-version parsing and comparison, GitHub Releases API URLs, and the (sync + async) latest-release / releases-list fetch and JSON parsing.
;
; Split out of modules/updater.ahk (the module split); see modules/updater.ahk for the module
; overview. Functions and globals are hoisted, so load order across the
; updater/*.ahk files is irrelevant.
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

; WinHttp timeout budget (ms) for the synchronous GitHub Releases / asset calls.
; EVERY phase must be finite: WinHttp treats 0 as "infinite", so a stalled DNS
; resolve (a connecting VPN, a captive portal, a dead resolver) blocks the
; synchronous call — and therefore the AHK main thread, and therefore ALL
; keyboard remapping — until the network recovers. The resolve phase used to be
; passed as 0 here, which is exactly how the background check could freeze the
; driver a few seconds after startup. Bounding every phase turns a permanent
; freeze into a brief, self-healing hiccup on a flaky network.
global UPDATER_HTTP_RESOLVE_TIMEOUT_MS := 5000     ; DNS resolution
global UPDATER_HTTP_CONNECT_TIMEOUT_MS := 15000    ; TCP connect
global UPDATER_HTTP_SEND_TIMEOUT_MS    := 30000    ; request send
global UPDATER_HTTP_RECEIVE_TIMEOUT_MS := 30000    ; response receive
; The download phase streams a multi-MB binary asset, so it needs a far larger receive
; budget than the tiny JSON API calls above. Reusing the 30 s API value made the
; WinHttpRequest receive timeout abort the transfer at 30 s on slow/metered links,
; defeating the 600 s SetTimer poll ceiling (updater-download-receive-timeout).
global UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS := 600000  ; binary download receive

; Floor for the downloaded exe size (512 KB). A real ErgoptiPlus binary is
; several MB; anything below this is certainly a partial download or a CDN
; error page and must not be swapped in as the production exe.
global UPDATER_MIN_EXE_SIZE_BYTES := 524288

; In-flight async background-check requests, keyed by an incrementing id. Each
; value is a Map("http", req, "channel", ch, "on_json", cb, "url", u, "polls", n).
; The background poller dispatches through here so its network round-trip runs
; in WinHTTP async mode and is harvested by a poll timer — the synchronous call
; that used to block (and freeze) the main thread near startup is gone for the
; unprompted path. See _Updater_FetchLatestJsonAsync / _Updater_PollAsync.
global _UpdaterAsyncRequests := Map()
global _UpdaterAsyncCounter  := 0

; Cadence + safety cap for polling an async background check to completion. The
; poll only asks "ready yet?" (WaitForResponse(0), 0 = do not wait), so a slack
; interval is fine — freshness does not matter for a silent check. The max-polls
; cap is derived from the timeout budget so a wedged request can never leave a
; poll timer running forever.
global UPDATER_ASYNC_POLL_MS   := 250
global UPDATER_ASYNC_MAX_POLLS := Ceil((UPDATER_HTTP_RESOLVE_TIMEOUT_MS + UPDATER_HTTP_CONNECT_TIMEOUT_MS + UPDATER_HTTP_SEND_TIMEOUT_MS + UPDATER_HTTP_RECEIVE_TIMEOUT_MS) / UPDATER_ASYNC_POLL_MS) + 20

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

; Per-channel GitHub API cache for conditional GET (If-None-Match). A 304
; response does not count against the anonymous 60 req/h rate limit, which
; makes short intervals like 1m viable for background polling.
global _UpdaterFetchCache          := Map()



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
	; the user has an explicit config-file override). When running from the
	; source tree BUNDLE_CHANNEL is not set, so default to "dev" — all releases
	; are pre-releases in that context and "main" would show an empty list.
	if IsSet(BUNDLE_CHANNEL)
		and (BUNDLE_CHANNEL == "main" or BUNDLE_CHANNEL == "dev") {
		UPDATER_CHANNEL := BUNDLE_CHANNEL
	} else {
		UPDATER_CHANNEL := "dev"
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
	global _UpdaterDownloadInProgress
	if (Channel != "main" and Channel != "dev")
		return
	; The self-update download's WinHttp request and poll-timer chain are
	; tracked only as local closures inside Updater_DownloadAndInstall /
	; _Updater_PollDownloadAsync -- never registered in the shared
	; _UpdaterAsyncRequests map that channel-switch cancellation drains. A
	; Reload here would orphan the in-flight request and the partial staging
	; file with zero log trace. Block the switch instead of racing it
	; (updater-channel-switch-download-race).
	if _UpdaterDownloadInProgress {
		try LoggerWarn("Updater", "Channel switch to '{1}' blocked: a download is currently in progress.", Channel)
		MsgBox(t("updater.channel_switch_blocked_download"), t("updater.title_update"), "Icon!")
		return
	}
	; Persist before publishing/reloading: TOML_Write deliberately converts I/O
	; failures into false, so assigning first makes a menu click look accepted
	; until the next boot silently restores the old channel.
	if !TOML_Write(Channel, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_KEY) {
		try LoggerError("Updater", "Could not persist update channel '{1}'; keeping '{2}'.", Channel, UPDATER_CHANNEL)
		return
	}
	UPDATER_CHANNEL := Channel
	; Cancel in-flight async checks and stop the focus/background timers before
	; the restart so a late WinHTTP response or a queued poll timer cannot fire a
	; callback against a half-torn-down state during the (non-instantaneous)
	; restart. Mirrors the explicit cleanup Updater_SetCheckInterval performs
	; for its in-process restart path instead of relying on the implicit
	; teardown.
	Updater_StopBackgroundChecks()
	ReloadPreservingSuspend()
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
	; Validate before arithmetic — AHK v2 throws a TypeError on a non-numeric
	; string in arithmetic (e.g. "fast" + 0), it does NOT silently coerce to 0
	; as the old comment claimed. A malformed entry falls back to the default
	; instead of aborting the boot auto-execute section.
	if !IsNumber(raw) {
		try LoggerWarn("Updater", "Ignoring non-numeric check_interval_seconds '{1}' — using default ({2} s).", raw, UPDATER_DEFAULT_INTERVAL)
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
	; IsNumber accepts magnitudes that can still overflow Integer(). Treat that
	; malformed extreme exactly like other invalid persisted values, never let it
	; abort the boot auto-execute path.
	try seconds := Integer(raw + 0)
	catch {
		try LoggerWarn("Updater", "Ignoring out-of-range check_interval_seconds '{1}' — using default ({2} s).", raw, UPDATER_DEFAULT_INTERVAL)
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
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
	; Coerce defensively: a valid cadence may arrive as a String ("300") or
	; Float (300.0) — e.g. from a config migration or a future caller, since
	; Updater_LoadCheckInterval reads strings from TOML. An exact Type() ==
	; "Integer" test would silently drop those. Reject only genuinely invalid
	; input (non-numeric or negative) and LoggerWarn so a bad value is visible
	; in the log rather than disappearing without a trace.
	try {
		Seconds := Integer(Seconds)
	} catch {
		try LoggerWarn("Updater", "Ignoring non-numeric check interval: {1}.", Seconds)
		return
	}
	if (Seconds < 0) {
		try LoggerWarn("Updater", "Ignoring negative check interval: {1}.", Seconds)
		return
	}
	; As above, make persistence the commit point. Do not stop/restart the
	; working timer or move the menu checkmark when the durable write failed.
	if !TOML_Write(Seconds, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY) {
		try LoggerError("Updater", "Could not persist background check interval {1} s; keeping {2} s.", Seconds, UPDATER_CHECK_INTERVAL)
		return
	}
	UPDATER_CHECK_INTERVAL := Seconds
	try LoggerInfo("Updater", "Background check interval set to {1} s.", Seconds)
	; Apply the new cadence immediately so the user does not have to reload.
	Updater_StopBackgroundChecks()
	Updater_StartBackgroundChecks()
	; Rebuild the tray menu so the check mark moves to the new row. ``initMenu``
	; is defined in ui/tray_menu.ahk; we call it indirectly via SetTimer so the
	; rebuild happens off the click handler's call stack (avoids surprising
	; reentrancy if the rebuild ever opens a fresh menu under the cursor).
	try SetTimer((*) => _Updater_RebuildMenu(), -50)
}



; ====================================
; ===== 1.3) Version helpers ==========
; ====================================

; Wrapper called from all updater SetTimer(-50) tray rebuild sites. initMenu()
; now stages child menus before publishing the replacement root; it advances the
; dispatcher epoch and prunes retired IDs at that publication point. Calling
; MenuDispatcher_Reset() here would erase registrations made during staging.
_Updater_RebuildMenu() {
	try initMenu()
}

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

; Strips a leading "v" so "v2.1.2" and "2.1.2" compare equal.
; GitHub tag_name always carries the prefix; BUNDLE_VERSION is stamped without
; it (the CI strips it with `${tag#v}`). Without this normalisation the
; background poller fires a spurious "update available" notification even when
; the user is already on the latest release.
_Updater_NormalizeTag(Tag) {
	return (SubStr(Tag, 1, 1) == "v") ? SubStr(Tag, 2) : Tag
}

; Semver helpers — canonical algorithm in _shared/modules/updater/version.js.
; Parses "2.5.0-dev.3" into { Maj, Min, Pat, PreParts } or 0 on failure.
_Updater_ParseVersion(Tag) {
	Norm := _Updater_NormalizeTag(Tag)
	if !RegExMatch(Norm, "^(?P<maj>\d+)\.(?P<min>\d+)\.(?P<pat>\d+)(?:-(?P<pre>.+))?$", &M)
		return 0
	PreParts := 0
	if M.pre != "" {
		PreParts := []
		for , Part in StrSplit(M.pre, ".")
			PreParts.Push(Part)
	}
	return { Maj: Integer(M.maj), Min: Integer(M.min), Pat: Integer(M.pat), PreParts: PreParts }
}

; Compares two prerelease identifier segments (numeric when all digits).
_Updater_ComparePreId(A, B) {
	if RegExMatch(A, "^\d+$") and RegExMatch(B, "^\d+$") {
		ai := Integer(A), bi := Integer(B)
		if (ai > bi)
			return 1
		if (ai < bi)
			return -1
		return 0
	}
	Cmp := StrCompare(A, B)
	return (Cmp > 0) ? 1 : (Cmp < 0) ? -1 : 0
}

; Returns 1 if A > B, -1 if A < B, 0 if equal (semver prerelease rules).
_Updater_ComparePre(A, B) {
	if (A == 0 and B == 0)
		return 0
	if (A == 0 and B != 0)
		return 1
	if (A != 0 and B == 0)
		return -1
	MaxLen := Max(A.Length, B.Length)
	loop MaxLen {
		ai := (A_Index <= A.Length) ? A[A_Index] : ""
		bi := (A_Index <= B.Length) ? B[A_Index] : ""
		if (ai == "")
			return -1
		if (bi == "")
			return 1
		Cmp := _Updater_ComparePreId(ai, bi)
		if (Cmp != 0)
			return Cmp
	}
	return 0
}

; Returns 1 if A > B, -1 if A < B, 0 if equal.
_Updater_CompareVersions(A, B) {
	Pa := _Updater_ParseVersion(A)
	Pb := _Updater_ParseVersion(B)
	if (Pa == 0 or Pb == 0) {
		; Non-semver tag(s): refuse to order them. Fail closed (return 0 = "not
		; newer") rather than guess lexicographically — "10" vs "9" and other
		; ambiguous tags must never trigger or suppress an update by accident.
		; Mirrors macOS modules/updater/init.lua + _shared/.../version.js; kept in
		; lock-step by the version-compare parity gate (D-1)
		return 0
	}
	if (Pa.Maj != Pb.Maj)
		return (Pa.Maj > Pb.Maj) ? 1 : -1
	if (Pa.Min != Pb.Min)
		return (Pa.Min > Pb.Min) ? 1 : -1
	if (Pa.Pat != Pb.Pat)
		return (Pa.Pat > Pb.Pat) ? 1 : -1
	return _Updater_ComparePre(Pa.PreParts, Pb.PreParts)
}

; Returns true when Latest is strictly newer than Current (semver comparison).
; Handles pre-release tags (e.g. 2.5.0-dev.3 → 2.5.0-dev.4). Canonical
; vectors live in _shared/modules/updater/version.js:versionTestVectors().
_Updater_IsNewerVersion(Latest, Current) {
	return _Updater_CompareVersions(Latest, Current) > 0
}

; Returns the GitHub Releases API URL for the chosen channel.
; For the dev channel we fetch the last 10 releases and pick the first one
; whose "prerelease" flag is true.  Using per_page=1 was insufficient because
; GitHub returns releases in reverse-chronological order: if the most recent
; publish is a stable release it lands at position 1 and any newer prerelease
; hiding behind it would go undetected.
Updater_ReleaseApiUrl(Channel) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	if (Channel == "dev")
		return "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases?per_page=10"
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
; Uses If-None-Match when a prior ETag is cached so unchanged feeds return 304
; without consuming the GitHub anonymous rate-limit budget.
Updater_FetchLatestJson(Channel) {
	global _UpdaterFetchCache
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Url := Updater_ReleaseApiUrl(Channel)
	Json := ""
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, false)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		; Always-finite timeouts — a 0 in any slot means "infinite" to WinHttp
		; and lets a stalled DNS resolve freeze the AHK main thread (and all
		; keyboard remapping) until the network recovers. See the constants at
		; the top of this file for the per-phase budget and the rationale.
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		if _UpdaterFetchCache.Has(Channel) {
			Etag := _UpdaterFetchCache[Channel].Etag
			if (Etag != "")
				Req.SetRequestHeader("If-None-Match", Etag)
		}
		Req.Send()
		Etag := ""
		try Etag := Req.GetResponseHeader("ETag")
		Json := _Updater_InterpretResponse(Req.Status, Req.ResponseText, Etag, Channel, Url)
	} catch as Err {
		LoggerWarn("Updater", "HTTP request failed: {1}.", Err.Message)
	}
	return Json
}

; Interprets a completed GitHub Releases response into the single-object JSON
; string every downstream parser expects. Shared by the synchronous fetch above
; and the async background path so their status / ETag / array-unwrap handling
; can never drift apart. Returns "" when there is nothing usable (304 with no
; cached body, 403 rate limit, or any other non-200). Updates the per-channel
; conditional-GET cache on a fresh 200.
_Updater_InterpretResponse(Status, Body, Etag, Channel, Url) {
	global _UpdaterFetchCache
	Json := ""
	if (Status == 304) {
		if _UpdaterFetchCache.Has(Channel)
			Json := _UpdaterFetchCache[Channel].Json
		try LoggerDebug("Updater", "GitHub releases unchanged (304) for channel {1}.", Channel)
	} else if (Status == 200) {
		Json := Body
		if (Etag != "" and Json != "")
			_UpdaterFetchCache[Channel] := { Etag: Etag, Json: Json }
	} else if (Status == 403) {
		try LoggerWarn("Updater", "GitHub API rate limit (HTTP 403) for '{1}'.", Url)
	} else {
		try LoggerWarn("Updater", "GitHub API HTTP {1} for '{2}'.", Status, Url)
	}
	; Array response (dev channel) — unwrap to the highest-semver prerelease so
	; every downstream parser receives a single-object JSON string.
	if (Json != "" and SubStr(LTrim(Json), 1, 1) == "[")
		Json := _Updater_UnwrapLatestPrerelease(Json)
	return Json
}

; Async, non-blocking sibling of Updater_FetchLatestJson. Dispatches the GitHub
; Releases request in WinHTTP async mode (Open(…, true)) and returns at once;
; OnJson(Json) is invoked later from a poll timer once the response completes
; (Json == "" on any failure). This is what the background poller uses, so a
; slow or stalled network can never block the AHK main thread — and therefore
; never freeze keyboard remapping. User-initiated paths keep the synchronous
; fetch (bounded timeouts, the user is actively waiting on the click). Mirrors
; the WinHTTP-async + SetTimer-poll pattern used in modules/llm.
_Updater_FetchLatestJsonAsync(Channel, OnJson) {
	global _UpdaterFetchCache, _UpdaterAsyncRequests, _UpdaterAsyncCounter
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Url := Updater_ReleaseApiUrl(Channel)
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, true)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		if _UpdaterFetchCache.Has(Channel) {
			Etag := _UpdaterFetchCache[Channel].Etag
			if (Etag != "")
				Req.SetRequestHeader("If-None-Match", Etag)
		}
		Req.Send()
	} catch as Err {
		try LoggerDebug("Updater", "Async check dispatch failed: {1}.", Err.Message)
		try OnJson("")
		catch as OnJsonErr {
			try LoggerError("Updater", "OnJson callback threw after an async check dispatch failure: {1}.", OnJsonErr.Message)
		}
		return
	}
	_UpdaterAsyncCounter += 1
	id := _UpdaterAsyncCounter
	_UpdaterAsyncRequests[id] := Map(
		"http", Req, "channel", Channel, "on_json", OnJson, "url", Url, "polls", 0)
	_Updater_PollAsync(id)
}

; Non-blocking completion poll for one in-flight async update check. Asks WinHTTP
; "is the response ready?" via WaitForResponse(0) (0 = do not wait); re-arms
; itself until ready, then interprets the response and fires the stored OnJson.
; A throw means the request errored (DNS / connect / timeout) — treated as a
; failure that yields OnJson(""). UPDATER_ASYNC_MAX_POLLS is a belt-and-suspenders
; cap so a wedged request can never leave a poll timer running forever.
_Updater_PollAsync(id) {
	global _UpdaterAsyncRequests, UPDATER_ASYNC_POLL_MS, UPDATER_ASYNC_MAX_POLLS
	if !_UpdaterAsyncRequests.Has(id)
		return
	rec := _UpdaterAsyncRequests[id]
	http := rec["http"]
	ready := false
	failed := false
	try {
		ready := http.WaitForResponse(0)
	} catch as Err {
		failed := true
		try LoggerDebug("Updater", "Async check failed: {1}.", Err.Message)
	}
	if (!failed and !ready) {
		rec["polls"] += 1
		if (rec["polls"] > UPDATER_ASYNC_MAX_POLLS) {
			failed := true
			try LoggerWarn("Updater", "Async check exceeded its poll budget — aborting.")
		} else {
			SetTimer(() => _Updater_PollAsync(id), -UPDATER_ASYNC_POLL_MS)
			return
		}
	}
	OnJson   := rec["on_json"]
	Channel  := rec["channel"]
	Url      := rec["url"]
	_UpdaterAsyncRequests.Delete(id)
	Json := ""
	if !failed {
		try {
			Etag := ""
			try Etag := http.GetResponseHeader("ETag")
			Json := _Updater_InterpretResponse(http.Status, http.ResponseText, Etag, Channel, Url)
		} catch as Err {
			try LoggerDebug("Updater", "Async response read failed: {1}.", Err.Message)
			Json := ""
		}
	}
	try OnJson(Json)
	catch as OnJsonErr {
		try LoggerError("Updater", "OnJson callback threw while completing an async background check: {1}.", OnJsonErr.Message)
	}
}

; Abandons every in-flight async update check. Called when background checks are
; stopped (e.g. the user switches the cadence to "never") so a response landing
; after the fact cannot still pop a notification. Dropping the registry entry
; releases the WinHTTP object; any pending poll timer no-ops on its next tick
; because the id is gone.
_Updater_CancelAsyncChecks() {
	global _UpdaterAsyncRequests
	if (_UpdaterAsyncRequests.Count == 0)
		return
	; Honour each pending request's contract before dropping it: a bare Clear() abandons
	; the stored on_json callback, so any consumer that owns external state tied to its
	; callback (e.g. the one-click _UpdaterCheckInProgress flag and its disabled menu item)
	; latches forever, unrecoverable without a restart. Snapshot first and Clear() up front
	; so a re-entrant dispatch from a callback cannot mutate the map mid-iteration, then fire
	; each on_json("") so consumers reset themselves (updater-cancel-fires-on-json).
	pending := []
	for _id, rec in _UpdaterAsyncRequests
		pending.Push(rec)
	_UpdaterAsyncRequests.Clear()
	for rec in pending {
		if (rec is Map and rec.Has("on_json"))
			try rec["on_json"]("")
	}
	try LoggerDebug("Updater", "Cancelled all in-flight async update checks.")
}

; Aborts an in-flight self-update staging worker because the process is going
; away. Wired into the driver's single OnExit handler (Ergopti_OnShutdown).
;
; Reload() and ExitApp() tear the process down WITHOUT running any per-module
; destructor, and Reload is this driver's standard "apply settings" mechanism —
; it also fires automatically from the keyboard-layout watcher. The download
; transaction, however, lives entirely in process-local state
; (_UpdaterDownloadInProgress plus the ShellRunner task in
; _UpdaterDownloadWorker) and completes through a callback owned by THIS
; process: swap_update.cmd is launched from _Updater_PollDownloadAsync and from
; nowhere else. So a Reload landing mid-download orphaned the detached
; PowerShell child — it kept downloading, wrote ErgoptiPlus_new.exe and
; swap_update.cmd, and exited, while the fresh instance booted with the flag
; re-zeroed and no residue scan. The user who clicked "Update now" waited, got
; no update, and no log line anywhere said why
; (updater-staging-worker-orphaned-on-exit).
;
; Killing the child and logging a WARNING makes the interrupted update visible
; instead of vanishing. Never throws: an OnExit callback that throws is
; swallowed by AHK and can hang the exit.
_Updater_AbortStagingOnExit() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	if !(IsSet(_UpdaterDownloadInProgress) and _UpdaterDownloadInProgress)
		return
	if (IsSet(_UpdaterDownloadWorker) and IsObject(_UpdaterDownloadWorker)) {
		try _UpdaterDownloadWorker.terminate()
	}
	_UpdaterDownloadWorker := 0
	_UpdaterDownloadInProgress := false
	try SetTimer(_Updater_MonitorStagingWorker, 0)
	try LoggerWarn("Updater", "Update staging aborted: the driver is exiting, and nothing outside this process would ever launch the staged swap script.")
}

; Async, non-blocking sibling of Updater_FetchReleasesListJson. Dispatches the
; GitHub releases-list request in WinHTTP async mode (Open(…, true)) and returns
; at once; OnJson(Json) is invoked from a poll timer once the response completes
; (Json == "" on any failure). Used by _Updater_OpenChangelogWindow so the
; changelog GUI build never blocks the keyboard hook on a slow network.
_Updater_FetchReleasesListJsonAsync(Channel, OnJson) {
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter
	Url := Updater_ReleasesListApiUrl(Channel)
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, true)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		Req.Send()
	} catch as Err {
		try LoggerDebug("Updater", "Async releases-list dispatch failed: {1}.", Err.Message)
		try OnJson("")
		catch as OnJsonErr {
			try LoggerError("Updater", "OnJson callback threw after an async releases-list dispatch failure: {1}.", OnJsonErr.Message)
		}
		return
	}
	; Register in the SHARED async registry, exactly like _Updater_FetchLatestJsonAsync.
	; _Updater_CancelAsyncChecks — the teardown Ergopti_OnSuspendEnter relies on to
	; honour "pause = tout éteint" — cancels by draining that map and nothing else,
	; so a request that keeps its state in closure arguments is structurally
	; uncancellable: its 250 ms poll timer and its live WinHTTP request would keep
	; running for the whole poll budget (~85 s) while the driver is meant to be
	; silent (updater-releases-list-uncancellable).
	_UpdaterAsyncCounter += 1
	id := _UpdaterAsyncCounter
	_UpdaterAsyncRequests[id] := Map(
		"http", Req, "channel", Channel, "on_json", OnJson, "url", Url, "polls", 0)
	_Updater_PollReleasesListAsync(id)
}

; Non-blocking completion poll for one in-flight async releases-list fetch.
; Mirrors _Updater_PollAsync — including its registry-based cancellation: a tick
; whose id has been dropped from _UpdaterAsyncRequests no-ops — but without the
; ETag / _InterpretResponse machinery (the releases list is always returned in
; full — no 304 caching).
_Updater_PollReleasesListAsync(id) {
	global _UpdaterAsyncRequests, UPDATER_ASYNC_POLL_MS, UPDATER_ASYNC_MAX_POLLS
	if !_UpdaterAsyncRequests.Has(id)
		return
	rec := _UpdaterAsyncRequests[id]
	Req := rec["http"]
	Url := rec["url"]
	ready  := false
	failed := false
	try {
		ready := Req.WaitForResponse(0)
	} catch as Err {
		failed := true
		try LoggerDebug("Updater", "Async releases-list poll failed: {1}.", Err.Message)
	}
	if (!failed and !ready) {
		rec["polls"] += 1
		if (rec["polls"] > UPDATER_ASYNC_MAX_POLLS) {
			failed := true
			try LoggerWarn("Updater", "Async releases-list exceeded poll budget — aborting.")
		} else {
			SetTimer(() => _Updater_PollReleasesListAsync(id), -UPDATER_ASYNC_POLL_MS)
			return
		}
	}
	OnJson := rec["on_json"]
	_UpdaterAsyncRequests.Delete(id)
	Json := ""
	if !failed {
		try {
			if (Req.Status == 200) {
				Json := Req.ResponseText
			} else {
				try LoggerWarn("Updater", "Releases-list HTTP {1} for '{2}'.", Req.Status, Url)
			}
		} catch as Err {
			try LoggerDebug("Updater", "Async releases-list response read failed: {1}.", Err.Message)
		}
	}
	try OnJson(Json)
	catch as OnJsonErr {
		try LoggerError("Updater", "OnJson callback threw while completing an async releases-list fetch: {1}.", OnJsonErr.Message)
	}
}

; Given a GitHub releases array JSON string, return the JSON object of the
; highest-semver prerelease entry. GitHub orders by publish date, not semver;
; a stable release at the top must not cause us to miss a newer prerelease
; further down the page. Falls back to the first entry when no prerelease
; is found.
_Updater_UnwrapLatestPrerelease(Json) {
	Chunks := _Updater_SplitReleasesArray(Json)
	BestTag := ""
	BestChunk := ""
	for _, Chunk in Chunks {
		if !_Updater_ParsePrerelease(Chunk)
			continue
		Tag := Updater_ParseTagName(Chunk)
		if (Tag == "")
			continue
		if (BestTag == "" or _Updater_CompareVersions(Tag, BestTag) > 0) {
			BestTag := Tag
			BestChunk := Chunk
		}
	}
	if (BestChunk != "")
		return BestChunk
	if (Chunks.Length > 0)
		return Chunks[1]
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
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Url := Updater_ReleasesListApiUrl(Channel)
	Json := ""
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, false)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		; Always-finite timeouts — a 0 in any slot means "infinite" to WinHttp
		; and would let a stalled DNS resolve block the UI thread until the
		; network recovers. See the constants at the top of this file.
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		Req.Send()
		if (Req.Status == 200) {
			Json := Req.ResponseText
		} else {
			LoggerWarn("Updater", "Releases list HTTP {1} for '{2}'.", Req.Status, Url)
		}
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
; Each entry: { Tag, Body, HtmlUrl, PublishedAt, Prerelease, RawJson }. The original
; API order is preserved (GitHub returns most-recent first) so callers do not
; need to sort. RawJson carries the per-release JSON chunk so changelog-list install
; can resolve the asset download URL via _Updater_FindAssetUrl (AHK-07).
Updater_ParseReleasesList(Json, MainOnly := false) {
	out := []
	for _, chunk in _Updater_SplitReleasesArray(Json) {
		rec := {
			Tag:         Updater_ParseTagName(chunk),
			Body:        Updater_ParseBody(chunk),
			HtmlUrl:     _Updater_ParseHtmlUrl(chunk),
			PublishedAt: _Updater_ParsePublishedAt(chunk),
			Prerelease:  _Updater_ParsePrerelease(chunk),
			RawJson:     chunk
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
	; Unwrap array if callers pass raw list JSON (defensive — normally already
	; unwrapped by Updater_FetchLatestJson or Updater_ParseReleasesList).
	if (SubStr(LTrim(Json), 1, 1) == "[")
		Json := RegExReplace(Json, "^\s*\[", "")
	if RegExMatch(Json, '"tag_name"\s*:\s*"([^"]+)"', &M)
		return M[1]
	return ""
}

; Extracts the "body" field (release notes markdown) from a GitHub release JSON.
; Returns "" when the field is absent, null, or an empty string — callers
; display t("updater.changelog_empty") in that case.
Updater_ParseBody(Json) {
	if (Json == "")
		return ""
	; Unwrap array defensively — normally already done by Updater_FetchLatestJson.
	if (SubStr(LTrim(Json), 1, 1) == "[")
		Json := RegExReplace(Json, "^\s*\[", "")
	; GitHub sets "body": null (not "") when a release has no description.
	; Detect null before trying the quoted-string pattern.
	if RegExMatch(Json, '"body"\s*:\s*null', &_)
		return ""
	; Possessive quantifier (*+) prevents catastrophic backtracking on large bodies.
	if RegExMatch(Json, '"body"\s*:\s*"((?:[^"\\]++|\\.)*+)"', &M) {
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
