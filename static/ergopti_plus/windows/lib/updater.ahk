; lib/updater.ahk

; ==============================================================================
; MODULE: Updater
; DESCRIPTION:
; Provides version display, one-click self-update, and background polling
; against GitHub Releases. The "Check / Update" menu item is dynamic: it
; reads as "Vérifier les mises à jour" at rest, "Mettre à jour vers vX.Y.Z"
; when a newer version is cached, and is disabled while a check is in
; progress. Clicking it always does the right thing in one action.
;
; FEATURES & RATIONALE:
; 1. One-click update: a single menu item handles check → download → swap.
;    No intermediate dialog is shown when an update is already cached.
; 2. Background polling: optional periodic silent check; surfaces a TrayTip
;    on new releases and updates the menu label immediately.
; 3. Channel-aware: the user can switch between the "main" (stable) and "dev"
;    (pre-release) channels. The setting is persisted in the shared config TOML.
; 4. GitHub Releases API: WinHttp synchronous call gated behind user click or
;    background timer — never on startup.
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
	if (Channel != "main" and Channel != "dev")
		return
	UPDATER_CHANNEL := Channel
	TOML_Write(Channel, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_KEY)
	; Cancel in-flight async checks and stop the focus/background timers before
	; the restart so a late WinHTTP response or a queued poll timer cannot fire a
	; callback against a half-torn-down state during the (non-instantaneous)
	; restart. Mirrors the explicit cleanup Updater_SetCheckInterval performs
	; for its in-process restart path instead of relying on the implicit
	; teardown.
	Updater_StopBackgroundChecks()
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
	; Validate before arithmetic — AHK v2 throws a TypeError on a non-numeric
	; string in arithmetic (e.g. "fast" + 0), it does NOT silently coerce to 0
	; as the old comment claimed. A malformed entry falls back to the default
	; instead of aborting the boot auto-execute section.
	if !IsNumber(raw) {
		try LoggerWarn("Updater", "Ignoring non-numeric check_interval_seconds '{1}' — using default ({2} s).", raw, UPDATER_DEFAULT_INTERVAL)
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
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
	UPDATER_CHECK_INTERVAL := Seconds
	try TOML_Write(Seconds, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY)
	try LoggerInfo("Updater", "Background check interval set to {1} s.", Seconds)
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

; Strips a leading "v" so "v2.1.2" and "2.1.2" compare equal.
; GitHub tag_name always carries the prefix; BUNDLE_VERSION is stamped without
; it (the CI strips it with `${tag#v}`). Without this normalisation the
; background poller fires a spurious "update available" notification even when
; the user is already on the latest release.
_Updater_NormalizeTag(Tag) {
	return (SubStr(Tag, 1, 1) == "v") ? SubStr(Tag, 2) : Tag
}

; Semver helpers — canonical algorithm in shared/updater/version.js.
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
		Na := _Updater_NormalizeTag(A)
		Nb := _Updater_NormalizeTag(B)
		Cmp := StrCompare(Na, Nb)
		return (Cmp > 0) ? 1 : (Cmp < 0) ? -1 : 0
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
; vectors live in shared/updater/version.js:versionTestVectors().
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
	_UpdaterAsyncRequests.Clear()
	try LoggerDebug("Updater", "Cancelled all in-flight async update checks.")
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
	if Updater_IsLocalSource()
		return
	State := Updater_GetUpdateState()
	if (State == "checking" or State == "downloading")
		return

	; Fast path: update already cached by background poller — install straight away.
	if (State == "available") {
		Updater_DownloadAndInstall(UPDATER_LATEST_RELEASE)
		return
	}

	; Slow path: need to check first. Mark in-progress and rebuild the menu so the
	; item shows "Vérification…" and is disabled while the network call runs.
	_UpdaterCheckInProgress := true
	try SetTimer((*) => initMenu(), -50)

	Current := Updater_CurrentVersion()
	try LoggerStart("Updater", "One-click update check (channel: {1}, current: {2})…", UPDATER_CHANNEL, Current)
	
	_Updater_FetchLatestJsonAsync(UPDATER_CHANNEL, (Json) => _Updater_OneClickUpdateCallback(Json, Current))
}

_Updater_OneClickUpdateCallback(Json, Current) {
	global UPDATER_LATEST_RELEASE, _UpdaterCheckInProgress
	_UpdaterCheckInProgress := false

	; The fetch callback arrives on an AHK pseudo-thread that bypasses native
	; Suspend. Skip all UI and install work while the script is paused.
	if A_IsSuspended
		return

	if (Json == "") {
		try LoggerWarn("Updater", "One-click check: network unreachable.")
		try SetTimer((*) => initMenu(), -50)
		TrayTip(t("updater.no_connection"), t("updater.title_update"))
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "") {
		try LoggerWarn("Updater", "One-click check: tag parse failed.")
		try SetTimer((*) => initMenu(), -50)
		TrayTip(t("updater.parse_failed"), t("updater.title_update"))
		return
	}
	if !_Updater_IsNewerVersion(Latest, Current) {
		try LoggerInfo("Updater", "One-click check: already up to date ({1}).", Current)
		try SetTimer((*) => initMenu(), -50)
		TrayTip(Format(t("updater.up_to_date"), Current), t("updater.title_update"))
		return
	}

	; New version found — cache it, rebuild menu (label becomes "Mettre à jour vers vX"),
	; then install immediately since the user explicitly clicked.
	UPDATER_LATEST_RELEASE := {
		Tag:         Latest,
		Body:        Updater_ParseBody(Json),
		RawJson:     Json,
		HtmlUrl:     _Updater_ParseHtmlUrl(Json),
		PublishedAt: _Updater_ParsePublishedAt(Json),
		Prerelease:  _Updater_ParsePrerelease(Json)
	}
	try LoggerSuccess("Updater", "One-click check: new version {1} found — installing.", Latest)
	try SetTimer((*) => initMenu(), -50)
	Updater_DownloadAndInstall(UPDATER_LATEST_RELEASE)
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

; Internal helper — builds (or rebuilds) the changelog GUI for a given channel.
; The notes pane uses WebView2 (NavigateToString) to render Markdown so the
; user sees formatted headings, bold text, lists and links instead of raw text.
; Falls back to a plain-text Edit when WebView2 is unavailable.
_Updater_OpenChangelogWindow(Channel) {
	global _VendorDir
	Json := Updater_FetchReleasesListJson(Channel)
	if (Json == "") {
		MsgBox(t("updater.no_connection"), t("updater.title_changelog"), "Icon!")
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

	; Decide whether to use WebView2 for Markdown rendering.
	UseWV := IsSet(WebView2) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")

	; Placeholder control that occupies the right-pane slot; the WebView2
	; control will be positioned on top of it after Gui.Show().
	RightPane := G.Add("Text", "x+10 y" . lby . " w" . RightColW . " h" . RightPaneH, "")

	; ── WebView2 controller (created after Show so the Hwnd is valid) ─────────
	WVC := unset   ; controller reference, kept in closure scope

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
			: 0
	)

	OpenSelected := (*) => (
		(Idx := Lb.Value) > 0 ? Run(Releases[Idx].HtmlUrl != ""
			? Releases[Idx].HtmlUrl
			: Updater_ReleasesPageUrl()) : ""
	)

	RefreshBody := (*) => (
		(Idx := Lb.Value) > 0
			? (_Updater_RefreshInstallBtn(BtnInstall, Releases, Lb.Value, IsLocal),
			   ShowBody(Releases[Idx].Body))
			: _Updater_RefreshInstallBtn(BtnInstall, Releases, 0, IsLocal)
	)

	; Capture Idx before G.Destroy() — Lb.Value returns 0 once the window is gone.
	InstallSelected := (*) => (
		((Idx2 := Lb.Value) > 0 and !IsLocal)
			? (G.Destroy(),
			   Updater_ShowUpdatePrompt(Releases[Idx2]))
			: ""
	)

	BtnSwitch.OnEvent("Click", (*) => (
		_Updater_CloseGui(G),
		IsLocal
			? _Updater_OpenChangelogWindow(OtherChannel)
			: Updater_SetChannel(OtherChannel)
	))

	Lb.OnEvent("Change", RefreshBody)
	Lb.OnEvent("DoubleClick", OpenSelected)
	BtnInstall.OnEvent("Click", InstallSelected)
	BtnOpen.OnEvent("Click", OpenSelected)
	G.WVC := 0
	G.Udir := ""
	G.OnEvent("Close",  (*) => _Updater_CloseGui(G))
	G.OnEvent("Escape", (*) => _Updater_CloseGui(G))

	G.Show("w930 AutoSize")

	; Spin up the WebView2 controller now that the window Hwnd is valid.
	if (UseWV) {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		udir   := A_Temp . "\ergopti_changelog_wv_" . A_TickCount
		WebView_SweepStaleProfiles("ergopti_changelog_wv_")
		try DirCreate(udir)
		G.Udir := udir
		try {
			; Parent the WebView2 to the RightPane control directly so Fill()
			; covers exactly that control's client area — no manual coordinate
			; arithmetic needed, and resize is handled automatically by the OS.
			WVC := WebView2.create(RightPane.Hwnd, , 0, udir, "", 0, loader)
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
}

; Escapes a string for safe embedding as a JS string literal (single-quoted).
_Updater_JsStr(s) {
	s := StrReplace(s, "\",  "\\")
	s := StrReplace(s, "'",  "\'")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "")
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
	try SetTimer((*) => initMenu(), -50)
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
	if (lParam == 0x405)
		try Updater_ShowAvailableUpdate()
	return ""
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
	global _VendorDir
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
	G.Udir := ""
	G.OnEvent("Close",  (*) => _Updater_CloseGui(G))
	G.OnEvent("Escape", (*) => _Updater_CloseGui(G))
	G.Show("w740 AutoSize")

	; Spin up WebView2 for Markdown rendering after Show() (Hwnd is valid then).
	UseWV := IsSet(WebView2) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
	if UseWV {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		udir   := A_Temp . "\ergopti_update_wv_" . A_TickCount
		WebView_SweepStaleProfiles("ergopti_update_wv_")
		try DirCreate(udir)
		G.Udir := udir
		WVC := unset
		try {
			WVC := WebView2.create(BodyPane.Hwnd, , 0, udir, "", 0, loader)
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
		BodyText := (Release.Body != "") ? Release.Body : t("updater.changelog_empty")
		G.Add("Edit", "x" . bx . " y" . by . " w" . bw . " h" . bh
			. " ReadOnly +Multi -Wrap +VScroll", BodyText)
	}
}

_Updater_CloseGui(G) {
	if G.HasProp("WVC") && G.WVC
		try G.WVC.Close()
	try G.Destroy()
	if G.HasProp("Udir") && G.Udir != ""
		try DirDelete(G.Udir, true)
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

; Downloads the release asset to a staging folder, writes a tiny swap batch,
; spawns it detached and exits the current process. The batch waits for our
; exe handle to release, moves the new exe over the current one, then
; relaunches. Best-effort: surfaces a single localized error MsgBox on any
; pre-exit failure so the user knows it didn't work.
Updater_DownloadAndInstall(Release) {
	global BUNDLE_RELEASE_ASSET
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
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
	
	global _UpdaterDownloadInProgress
	_UpdaterDownloadInProgress := true
	try SetTimer((*) => initMenu(), -50)
	
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", AssetUrl, true)  ; async mode
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		Req.Send()
	} catch as Err {
		_UpdaterDownloadInProgress := false
		try SetTimer((*) => initMenu(), -50)
		try LoggerError("Updater", "Asset download dispatch failed: {1}.", Err.Message)
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		return
	}
	
	_Updater_PollDownloadAsync(Req, NewExe, SwapBat, CurrentExe, Release.Tag)
}

_Updater_PollDownloadAsync(Req, NewExe, SwapBat, CurrentExe, Tag, Polls := 0) {
	global _UpdaterDownloadInProgress, UPDATER_ASYNC_POLL_MS
	; Give the download up to 120 seconds to complete
	MaxPolls := 120000 / UPDATER_ASYNC_POLL_MS
	ready := false
	failed := false
	try {
		ready := Req.WaitForResponse(0)
	} catch as Err {
		failed := true
		try LoggerDebug("Updater", "Async download failed: {1}.", Err.Message)
	}
	if (!failed and !ready) {
		Polls += 1
		if (Polls > MaxPolls) {
			failed := true
			try LoggerWarn("Updater", "Async download exceeded its poll budget — aborting.")
		} else {
			SetTimer(() => _Updater_PollDownloadAsync(Req, NewExe, SwapBat, CurrentExe, Tag, Polls), -UPDATER_ASYNC_POLL_MS)
			return
		}
	}
	
	_UpdaterDownloadInProgress := false
	try SetTimer((*) => initMenu(), -50)
	
	if (failed or Req.Status != 200) {
		try LoggerError("Updater", "Asset download returned HTTP {1}.", failed ? "FAIL" : Req.Status)
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		return
	}
	
	try {
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
	; Partial-download guard: compare Content-Length to the actual saved size.
	; A CDN truncation, network timeout, or error-page response would leave a
	; file too small to be a valid exe. If sizes disagree, delete the partial
	; file and abort — never swap a corrupted download into the production path.
	ActualSize := 0
	try ActualSize := FileGetSize(NewExe)
	ContentLength := 0
	try ContentLength := Integer(Req.GetResponseHeader("Content-Length"))
	if (ContentLength > 0 and ActualSize != ContentLength) {
		try LoggerError("Updater",
			"Partial-download detected: Content-Length={1}, file={2} bytes — aborting.",
			ContentLength, ActualSize)
		try FileDelete(NewExe)
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		return
	}
	if (ActualSize < UPDATER_MIN_EXE_SIZE_BYTES) {
		try LoggerError("Updater",
			"Downloaded file too small ({1} bytes < {2} minimum) — likely an error page, aborting.",
			ActualSize, UPDATER_MIN_EXE_SIZE_BYTES)
		try FileDelete(NewExe)
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
