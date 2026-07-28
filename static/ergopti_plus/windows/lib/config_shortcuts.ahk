; lib/config_shortcuts.ahk

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
;   [Metrics]
;   metrics_enabled                 = true
;   metrics_shortcut_typing         = "ctrl+alt+m"
;   metrics_shortcut_apps           = "ctrl+alt+t"
;   metrics_filter_private_browsing = true
;   metrics_filter_system_auth      = true
;   metrics_disabled_apps           = ["chrome.exe", "firefox.exe"]
;
; FEATURES & RATIONALE:
; 1. Per-driver subfolder: ``<config_dir>/ahk/`` is auto-created on first
;    save. Disjoint from ``<config_dir>/hammerspoon/`` so the two drivers
;    never touch the same file.
; 2. Section-preserving writer: CS_Save merges back into the existing
;    file without touching other sections, so any future hand-written
;    sections survive a shortcut change.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ==================================
; ======= 1/ Path resolution =======
; ==================================
; ===================================

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
; ([Script], [Shortcuts.ScriptControl], [Gestures], feature sections …) are
; preserved verbatim by the section-aware writer below.
global CS_SECTION := "ahk.metrics"





; ===================================
; =========================
; ======= 2/ Reader =======
; =========================
; ===================================

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





; ===================================
; =========================
; ======= 3/ Writer =======
; =========================
; ===================================

; Replaces the [Metrics] section in the on-disk config.toml without
; touching any other section. Atomic via .tmp + rename. ``new_kv`` is a
; Map of key → value pairs that becomes the new contents of the section.
CS_WriteShortcutsSection(new_kv) {
    global CS_SECTION
    path := CS_GetTomlPath()
    body := ""
    if FileExist(path)
        try body := FileRead(path, "UTF-8")

    rendered := CS_RenderSection(CS_SECTION, new_kv)
    new_body := CS_ReplaceSection(body, CS_SECTION, rendered)

    tmp := path . ".tmp"
    try {
        try FileDelete(tmp)
        FileAppend(new_body, tmp, "UTF-8")
        FileMove(tmp, path, 1)   ; overwrite=1 is atomic on NTFS — no bare FileDelete(path) needed
    } catch as Err {
        try FileDelete(tmp)
        try LoggerError("ConfigShortcuts", "Could not write config.toml: {1}.", Err.Message)
    }
}

; Render a single section to its [section]\nkey = value\n… form. A
; trailing blank line keeps the file readable when more sections follow.
CS_RenderSection(name, kv) {
    out := "[" . name . "]`n"
    for k, v in kv
        out .= k . " = " . CS_RenderValue(v) . "`n"
    return out
}

; Take an existing TOML body and either replace the named section in
; place (preserving its blank-line surroundings) or append it at the
; end when the section is missing.
CS_ReplaceSection(body, section_name, replacement) {
    if (body = "")
        return replacement . "`n"

    lines := StrSplit(body, "`n", "`r")
    out_before := []
    out_after := []
    in_target := false
    seen := false
    loop lines.Length {
        line := lines[A_Index]
        trimmed := Trim(line)
        is_section := (SubStr(trimmed, 1, 1) = "[" && SubStr(trimmed, -1) = "]")
        if is_section {
            sec_name := Trim(SubStr(trimmed, 2, StrLen(trimmed) - 2))
            if (sec_name = section_name) {
                in_target := true
                seen := true
                continue
            }
            if in_target {
                in_target := false
                ; fallthrough — this section header belongs to the « after » bucket
            }
        }
        if in_target
            continue
        if !seen
            out_before.Push(line)
        else
            out_after.Push(line)
    }

    head := CS_Join(out_before, "`n")
    tail := CS_Join(out_after, "`n")
    if (head != "" && SubStr(head, -1) != "`n")
        head .= "`n"
    if (tail = "")
        return head . replacement
    return head . replacement . "`n" . tail
}

CS_RenderValue(v) {
    if (v = true)
        return "true"
    if (v = false)
        return "false"
    if (v is Array) {
        parts := []
        for s in v
            parts.Push(CS_RenderString(s))
        return "[" . CS_Join(parts, ", ") . "]"
    }
    if IsNumber(v)
        return String(v)
    return CS_RenderString(String(v))
}

CS_RenderString(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return '"' . s . '"'
}

CS_Join(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i = 1 ? "" : sep) . v
    return out
}





; ============================================
; =========================================
; ======= 4/ Public load + save API =======
; =========================================
; ============================================

; Populate MetricsShortcuts + MetricsFilters from disk. Safe to call once
; at boot — missing file or missing keys leave the in-memory defaults
; untouched.
CS_Load() {
    global CS_SECTION
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
    if s.Has("metrics_filter_private_browsing")
        MetricsFilters.private_browsing := s["metrics_filter_private_browsing"] ? true : false
    if s.Has("metrics_filter_secure_field")
        MetricsFilters.secure_field := s["metrics_filter_secure_field"] ? true : false
    if s.Has("metrics_filter_system_auth")
        MetricsFilters.system_auth := s["metrics_filter_system_auth"] ? true : false

    if s.Has("metrics_disabled_apps") && (s["metrics_disabled_apps"] is Array) {
        MetricsFilters.disabled_apps := Map()
        for name in s["metrics_disabled_apps"] {
            t := Trim(String(name))
            if (t != "")
                MetricsFilters.disabled_apps[StrLower(t)] := true
        }
    }
}

; Serialise the in-memory state back to disk. Only the [Metrics]
; section is rewritten; every other section in config.toml stays put.
CS_Save() {
    global _SaveFullConfigReady
    if IsSet(_SaveFullConfigReady) {
        SaveFullConfig()
        return
    }

    apps := []
    for proc, _ in MetricsFilters.disabled_apps
        apps.Push(proc)

    kv := Map(
        "metrics_enabled", MetricsShortcuts.enabled,
        "metrics_shortcut_typing", MetricsShortcuts.typing_str,
        "metrics_shortcut_apps", MetricsShortcuts.apps_str,
        "metrics_wpm_menubar_colors", MetricsShortcuts.wpm_menubar_colors,
        "metrics_filter_private_browsing", MetricsFilters.private_browsing,
        "metrics_filter_secure_field", MetricsFilters.secure_field,
        "metrics_filter_system_auth", MetricsFilters.system_auth,
        "metrics_disabled_apps", apps
    )
    CS_WriteShortcutsSection(kv)
}
