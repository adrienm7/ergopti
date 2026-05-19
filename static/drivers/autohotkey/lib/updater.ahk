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
global UPDATER_INI_KEY   := "UpdateChannel"
global UPDATER_INI_SECTION := "Updater"




; ===================================
; ===== 1.2) Channel persistence =====
; ===================================

; Loads the saved channel from config.toml (via the shared INI cache).
; Falls back to "main" when absent.
Updater_LoadChannel() {
	global _IniCache, UPDATER_CHANNEL, UPDATER_INI_SECTION, UPDATER_INI_KEY
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
	if RegExMatch(Json, '"body"\s*:\s*"((?:[^"\\]|\\.)*)"', &M) {
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
		Channel := " (local source — not a release build)"
	else
		Channel := (UPDATER_CHANNEL == "dev") ? " (pre-release channel)" : " (stable channel)"
	Res := MsgBox(
		"ErgoptiPlus " . Ver . Channel . "`n`nOpen the releases page on GitHub?",
		"ErgoptiPlus — Version",
		"YesNo Iconi"
	)
	if (Res == "Yes")
		Run(Updater_ReleasesPageUrl())
}

; Checks GitHub for a newer release and shows the result.
Updater_CheckForUpdate(*) {
	global UPDATER_CHANNEL
	if Updater_IsLocalSource() {
		MsgBox("Running from local source — update checking is only available for release builds.",
			"ErgoptiPlus — Update", "Iconi")
		return
	}
	Current := Updater_CurrentVersion()
	MsgBox("Checking for updates on the '" . UPDATER_CHANNEL . "' channel…`n(This may take a few seconds.)",
		"ErgoptiPlus — Update", "Iconi T2")
	Json := Updater_FetchLatestJson(UPDATER_CHANNEL)
	if (Json == "") {
		MsgBox("Could not reach GitHub. Check your internet connection and try again.",
			"ErgoptiPlus — Update", "Icon!")
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "") {
		MsgBox("Could not parse the latest release tag from GitHub.",
			"ErgoptiPlus — Update", "Icon!")
		return
	}
	if (Latest == Current) {
		MsgBox("ErgoptiPlus is up to date." . "`n`nCurrent version: " . Current,
			"ErgoptiPlus — Update", "Iconi")
		return
	}
	Res := MsgBox(
		"A new version is available!`n`nCurrent: " . Current . "`nLatest:  " . Latest
		. "`n`nOpen the releases page to download?",
		"ErgoptiPlus — Update available",
		"YesNo Iconi"
	)
	if (Res == "Yes")
		Run(Updater_ReleasesPageUrl())
}

; Fetches and displays the release notes for the latest release on the active channel.
Updater_ShowChangelog(*) {
	global UPDATER_CHANNEL
	; In local-source mode fall back to the "main" channel for changelog browsing
	; (the user has no installed version to compare against anyway).
	EffectiveChannel := Updater_IsLocalSource() ? "main" : UPDATER_CHANNEL
	Json := Updater_FetchLatestJson(EffectiveChannel)
	if (Json == "") {
		MsgBox("Could not reach GitHub. Check your internet connection and try again.",
			"ErgoptiPlus — Changelog", "Icon!")
		return
	}
	Tag  := Updater_ParseTagName(Json)
	Body := Updater_ParseBody(Json)
	if (Tag == "") {
		MsgBox("Could not retrieve release information from GitHub.",
			"ErgoptiPlus — Changelog", "Icon!")
		return
	}
	if (Body == "")
		Body := "(No release notes available for this version.)"
	; Truncate to 2000 chars so the MsgBox stays readable.
	if (StrLen(Body) > 2000)
		Body := SubStr(Body, 1, 2000) . "`n…(truncated)"
	Res := MsgBox(
		"Release notes for " . Tag . ":`n`n" . Body . "`n`nOpen on GitHub?",
		"ErgoptiPlus — Changelog",
		"YesNo Iconi"
	)
	if (Res == "Yes")
		Run(Updater_ReleasesPageUrl())
}
