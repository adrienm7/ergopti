; infra/config_shortcuts.ahk

; ==============================================================================
; MODULE: Config Shortcuts (TOML section)
; DESCRIPTION:
; UI-shortcut preferences and per-feature privacy toggles, persisted as a
; ``[Metrics]`` section inside the unified AHK config at
; ``<config_dir>/ahk/config.toml``. All driver configuration (features,
; script settings, gestures, expert overrides) lives in this single file.
;
; SECTION LAYOUT inside autohotkey/config.toml:
;
;   [metrics]
;   metrics_enabled            = true
;   metrics_shortcut_typing    = "ctrl+alt+m"
;   metrics_shortcut_apps      = "ctrl+alt+t"
;   private_filter_enabled     = true
;   system_auth_filter_enabled = true
;   metrics_disabled_apps      = ["chrome.exe", "firefox.exe"]
;
; FEATURES & RATIONALE:
; 1. Per-driver subfolder: ``<config_dir>/ahk/`` is auto-created on first
;    save. Disjoint from ``<config_dir>/hammerspoon/`` so the two drivers
;    never touch the same file.
; 2. Single writer: this file parses config.toml and routes targeted metrics
;    updates through ConfigCommitUpdates → TOML_BatchWrite. The canonical
;    writer preserves every untouched section and refuses to rebuild a file it
;    could not read.
; ==============================================================================

#Requires Autohotkey v2.0+





; ==================================
; ==================================
; ======= 1/ Path resolution =======
; ==================================
; ==================================

CS_GetTomlPath() {
		; Driver-specific subfolder under the user's resolved config dir.
		; Auto-created here so callers can read/write straight away without
		; worrying about ENOENT on a fresh install.
		global _ConfigDir
		base := (IsSet(_ConfigDir) && _ConfigDir != "") ? _ConfigDir : A_ScriptDir . "\"
		global _AhkSubDir
		dir := base . _AhkSubDir
		try DirCreate(dir)
		return dir . "config.toml"
}

; The single section we own inside config.toml. Other sections
; ([Script], [Shortcuts.ScriptControl], [Gestures], feature sections …) belong
; to other readers and are never touched from here.
global CS_SECTION := "metrics"





; =========================
; =========================
; ======= 2/ Reader =======
; =========================
; =========================

; Returns a Map of { section_name => Map(key => value) }. Values are
; strings, integers, booleans (1/0), or Arrays of strings.
; Comments (lines starting with #) and blank lines are skipped.
CS_Read() {
		out := Map()
		path := CS_GetTomlPath()
		if !FileExist(path)
				return out
		content := ""
		ReadFailed := false
		try {
				content := FileRead(path, "UTF-8")
		} catch as Err {
				ReadFailed := true
				try LoggerError("ConfigShortcuts", "Cannot read '{1}': {2}. Metrics settings stay at their in-memory defaults, and persistence is blocked so those defaults cannot be written over the real file.", path, Err.Message)
		}
		if (ReadFailed) {
				; Latch the SAME sentinel SaveFullConfig already honours. This reader
				; feeds the metrics settings, and a swallowed read left them at their
				; in-memory DEFAULTS — indistinguishable from a user who never changed
				; them — which the next full save then wrote over the user's real
				; values. The file here is config.toml, so reusing the boot latch keeps
				; one owner for "the in-memory config is not the user's".
				global _ConfigBootReadFailed
				_ConfigBootReadFailed := true
				return out
		}
		if (content = "")
				return out

		section := ""
		loop parse, content, "`n", "`r" {
				line := Trim(A_LoopField)
				if (line = "" || SubStr(line, 1, 1) = "#")
						continue
				; Section header: [name]
				if (SubStr(line, 1, 1) = "[" && SubStr(line, -1) = "]") {
						section := Trim(SubStr(line, 2, StrLen(line) - 2))
						if !out.Has(section)
								out[section] := Map()
						continue
				}
				; Key = value
				eq := InStr(line, "=")
				if !eq
						continue
				key := Trim(SubStr(line, 1, eq - 1))
				val := Trim(SubStr(line, eq + 1))
				if (section = "")
						continue
				out[section][key] := CS_CoerceValue(val)
		}
		return out
}

; Truncate a value at the first '#' that sits OUTSIDE a quoted string, so an
; inline TOML comment (metrics_enabled = false # off) does not become part of the
; value. Quote/escape state is tracked from the raw character stream (same
; discipline as the array tokenizer below), so a '#' inside a quoted value or an
; escaped quote is preserved. Without this, "false # x" fell through to the bare-
; string fallback and coerced to a TRUTHY string, inverting the user's opt-out.
CS_StripInlineComment(s) {
		in_str := false
		escaped := false
		loop parse, s {
				c := A_LoopField
				if escaped {
						escaped := false
				} else if (c = "\") {
						escaped := true
				} else if (c = '"') {
						in_str := !in_str
				} else if (!in_str && c = "#") {
						return Trim(SubStr(s, 1, A_Index - 1))
				}
		}
		return s
}

CS_CoerceValue(raw) {
		raw := Trim(raw)
		; Drop any inline comment first so `false # note` coerces to boolean false and
		; `[ "a" ] # note` is still recognised as an array (the trailing comment would
		; otherwise break the "]"-suffix check below and fall through to a bare string).
		raw := Trim(CS_StripInlineComment(raw))
		if (raw = "")
				return ""
		; Booleans.
		if (StrLower(raw) = "true")
				return true
		if (StrLower(raw) = "false")
				return false
		; Quoted string.
		if (SubStr(raw, 1, 1) = '"' && SubStr(raw, -1) = '"')
				return CS_Unescape(SubStr(raw, 2, StrLen(raw) - 2))
		; Array of strings: [ "a", "b", ... ]
		if (SubStr(raw, 1, 1) = "[" && SubStr(raw, -1) = "]") {
				body := Trim(SubStr(raw, 2, StrLen(raw) - 2))
				out := []
				if (body = "")
						return out
				; Split on commas that sit OUTSIDE a quoted string. Array elements may
				; legitimately contain commas inside quotes (title-based window filters)
				; or escaped quotes, so a naive split would corrupt them.
				;
				; The escape state is tracked from the RAW character stream via a
				; dedicated `escaped` flag — never from the accumulated `cur`, whose
				; last char is unreliable as a lookbehind (e.g. an escaped backslash
				; ``\\`` right before a closing quote would fool an accumulator probe
				; into treating the quote as escaped and never closing the string).
				in_str := false
				escaped := false
				cur := ""
				loop parse, body {
						c := A_LoopField
						if escaped {
								; Previous raw char was a backslash — this char is literal.
								escaped := false
						} else if (c = "\") {
								escaped := true
						} else if (c = '"') {
								in_str := !in_str
						} else if (!in_str && c = ",") {
								out.Push(CS_CoerceElement(Trim(cur)))
								cur := ""
								continue
						}
						cur .= c
				}
				if (Trim(cur) != "")
						out.Push(CS_CoerceElement(Trim(cur)))
				return out
		}
		; Integer.
		if RegExMatch(raw, "^-?\d+$")
				return Integer(raw)
		; Bare string fallback.
		return raw
}

; Coerce a single array element that the tokenizer already extracted. A
; quoted element is unescaped EXACTLY ONCE here — we deliberately do NOT
; recurse into CS_CoerceValue for quoted strings, which would re-run the
; quote-detection + CS_Unescape pass and risk a second unescape. Non-quoted
; elements (bools, integers, bare strings) still flow through CS_CoerceValue.
CS_CoerceElement(token) {
		token := Trim(token)
		if (SubStr(token, 1, 1) = '"' && SubStr(token, -1) = '"')
				return CS_Unescape(SubStr(token, 2, StrLen(token) - 2))
		return CS_CoerceValue(token)
}

CS_Unescape(s) {
	; AHK-22: single left-to-right pass, mirroring TOML_Unescape (toml_helpers.ahk:251).
	; The old sequential StrReplace(s,"\\","\") BEFORE StrReplace(s,"\n",newline)
	; freed a backslash that then recombined on the next pass: "ctrl+\\n" → "ctrl+\n"
	; → "ctrl+<newline>" instead of the correct "ctrl+\n".
	if !InStr(s, "\")
		return s
	Result := "", i := 1, n := StrLen(s)
	while (i <= n) {
		c := SubStr(s, i, 1)
		if (c == "\" and i < n) {
			nc := SubStr(s, i + 1, 1)
			if (nc == "\") {
				Result .= "\"
			} else if (nc == '"') {
				Result .= '"'
			} else if (nc == "n") {
				Result .= "`n"
			} else if (nc == "t") {
				Result .= "`t"
			} else if (nc == "r") {
				Result .= "`r"
			} else {
				Result .= nc
			}
			i += 2
		} else {
			Result .= c
			i += 1
		}
	}
	return Result
}






; =========================================
; =========================================
; ======= 4/ Public load + save API =======
; =========================================
; =========================================

; Populate MetricsShortcuts + MetricsFilters from disk. Safe to call once
; at boot — missing file or missing keys leave the in-memory defaults
; untouched.
CS_Load() {
		global CS_SECTION
		; Manifest first, disk second. Doing it here rather than in the class body
		; keeps the ordering explicit: a class static initialiser would run at an
		; unspecified point relative to the manifest include, and a privacy default
		; that depends on include order is one refactor away from flipping.
		MetricsFiltersApplyManifestDefaults()
		data := CS_Read()
		if !data.Has(CS_SECTION) {
				return
		}
		s := data[CS_SECTION]

		if s.Has("metrics_enabled")
				MetricsShortcuts.enabled := s["metrics_enabled"] ? true : false
		if s.Has("metrics_shortcut_typing")
				MetricsShortcuts.typing_str := String(s["metrics_shortcut_typing"])
		if s.Has("metrics_shortcut_apps")
				MetricsShortcuts.apps_str := String(s["metrics_shortcut_apps"])

		if s.Has("metrics_wpm_menubar_colors")
				MetricsShortcuts.wpm_menubar_colors := s["metrics_wpm_menubar_colors"] ? true : false
		; Canonical ids, shared with the macOS driver, which reads the same four
		; through Manifest.default_for("metrics.<id>").
		if s.Has("private_filter_enabled")
				MetricsFilters.private_browsing := s["private_filter_enabled"] ? true : false
		if s.Has("secure_filter_enabled")
				MetricsFilters.secure_field := s["secure_filter_enabled"] ? true : false
		if s.Has("system_auth_filter_enabled")
				MetricsFilters.system_auth := s["system_auth_filter_enabled"] ? true : false
		if s.Has("encrypt") {
				MetricsFilters.encrypt := s["encrypt"] ? true : false
				; Drive the real cipher so a restart with encryption on keeps encrypting.
				KL_Enc_SetEnabled(MetricsFilters.encrypt)
		}

		if s.Has("metrics_disabled_apps") && (s["metrics_disabled_apps"] is Array) {
				MetricsFilters.disabled_apps := Map()
				for name in s["metrics_disabled_apps"] {
						t := Trim(String(name))
						if (t != "")
								MetricsFilters.disabled_apps[StrLower(t)] := true
				}
		}
}

; Commit an explicit metrics candidate through the one atomic config.toml
; writer. PublishFn is invoked by the gateway before config ownership is
; released; callers must never perform the matching live swap after return.
CS_Save(Updates := unset, Context := "the metrics settings", WriterFn := 0,
		NotifyFn := 0, PublishFn := 0,
		FinalizeFn := 0, CompensateFn := 0) {
		global _SaveFullConfigReady, ConfigurationFile
		if !(IsSet(_SaveFullConfigReady) && _SaveFullConfigReady
				&& IsSet(ConfigurationFile) && ConfigurationFile != "") {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
						"the full-config writer is not initialized")
		}
		; Compatibility for callers migrated in the following subsystem commits.
		; SaveFullConfig is tri-state, so DEFERRED must be accepted explicitly.
		if !IsSet(Updates) {
				global CONFIG_SAVE_OK, CONFIG_SAVE_DEFERRED
				Result := SaveFullConfig()
				return Result = CONFIG_SAVE_OK || Result = CONFIG_SAVE_DEFERRED
		}

		return ConfigCommitUpdates(ConfigurationFile, Updates, Context, WriterFn, NotifyFn,
				PublishFn, FinalizeFn, CompensateFn)
}

CS_SaveBuilt(Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
		global _SaveFullConfigReady, ConfigurationFile
		if !(IsSet(_SaveFullConfigReady) && _SaveFullConfigReady
				&& IsSet(ConfigurationFile) && ConfigurationFile != "") {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
						"the full-config writer is not initialized")
		}
		return ConfigCommitBuilt(ConfigurationFile, Context, BuildFn,
				WriterFn, NotifyFn)
}
