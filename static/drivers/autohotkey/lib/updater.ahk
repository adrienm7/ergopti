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
