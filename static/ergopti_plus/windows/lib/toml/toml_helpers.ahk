; lib/toml_helpers.ahk

; ==============================================================================
; MODULE: TOML Helpers
; DESCRIPTION:
; Single-source-of-truth configuration backend. The driver used to spread its
; settings across an INI file (``ErgoptiPlus_Configuration.ini``) read via
; Win32 ``IniRead``/``IniWrite`` plus a hand-rolled TOML parser for the
; metrics-specific ``[shortcuts]`` section. Both files now live as one
; ``config.toml`` with section-scoped reads, writes and a batched mutator
; that mirrors the old ``IniBatchWrite`` semantics.
;
; FEATURES & RATIONALE:
; 1. Drop-in for IniRead/IniWrite: ``TOML_Read``/``TOML_Write`` keep the same
;    ``(value, path, section, key)`` argument order (with the path as second
;    arg for write, identical to the Win32 API) so the migration was a
;    near-mechanical search-and-replace.
; 2. Dotted-key tolerant: keys carrying a literal dot (``Foo.Enabled``) are
;    rendered as TOML quoted keys (``"Foo.Enabled" = true``) and unquoted
;    on read. The driver historically uses ``Feature.Enabled`` /
;    ``Feature.Letter`` strings that we keep untouched at call sites.
; 3. Cached parser: ``TOML_Parse`` reads the full file once into a nested
;    ``Map<Section, Map<Key, Value>>`` so that a startup with hundreds of
;    lookups never reopens the file. Mirrors ``ParseIniFile``'s shape so the
;    cache-aware accessor (``IniCacheGet``) keeps working.
; 4. Section-scoped batch write: ``TOML_BatchWrite`` rewrites every section
;    in one go (read once, modify in memory, write once). Comments are not
;    preserved because the file is fully driver-managed; section ORDER is
;    stable across writes.
; ==============================================================================

#Requires Autohotkey v2.0+





; ==========================================
; ============================
; ======= 1/ Utilities =======
; ============================
; ==========================================

; In-place alphabetical sort of a simple Array of strings via bubble sort.
; The arrays are at most a few hundred entries; O(n²) is fine.
SortArray(arr) {
    n := arr.Length
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index
            if (StrCompare(arr[j], arr[j + 1]) > 0) {
                tmp := arr[j]
                arr[j] := arr[j + 1]
                arr[j + 1] := tmp
            }
        }
    }
    return arr
}





; ===================================
; =========================
; ======= 2/ Reader =======
; =========================
; ===================================

; Parse result cache: keyed by file path, invalidated by TOML_BatchWrite.
global _ParseTomlCache := Map()

; Parse a TOML file into Map<Section, Map<Key, Value>>. Values are coerced
; to AHK booleans / integers / strings / arrays of strings — anything more
; exotic falls through as a raw string. Returns an empty Map when the file
; is missing so callers can rely on ``.Has`` checks without a prior
; ``FileExist``.
; Multi-line arrays ( key = [\n  "a",\n  "b"\n] ) are fully supported.
ParseTomlFile(Path) {
    global _ParseTomlCache
    if _ParseTomlCache.Has(Path)
        return _ParseTomlCache[Path]
    Sections := Map()
    if !FileExist(Path)
        return Sections
    Content := ""
    try Content := FileRead(Path, "UTF-8")
    if (Content = "")
        return Sections

    Section     := ""
    PendingKey  := ""   ; key whose value spans multiple lines
    PendingVal  := ""   ; accumulated raw characters of the multi-line value

    loop parse, Content, "`n", "`r" {
        Line := Trim(A_LoopField)

        ; --- Continuation of a multi-line array ---
        if (PendingKey != "") {
            PendingVal .= " " . Line
            ; Once the closing ] is on a line by itself (or at end of val),
            ; the accumulation is done
            if InStr(Line, "]") {
                if !Sections.Has(Section)
                    Sections[Section] := Map()
                Sections[Section][PendingKey] := TOML_CoerceValue(Trim(PendingVal))
                PendingKey := ""
                PendingVal := ""
            }
            continue
        }

        if (Line = "" || SubStr(Line, 1, 1) = "#")
            continue

        ; Section header [name] — skip [[table-array]] headers (hotstrings TOML)
        if (SubStr(Line, 1, 1) = "[") {
            ; Strip leading/trailing brackets, ignoring double-bracket variant
            inner := RegExReplace(Line, "^\[+|\]+$", "")
            Section := Trim(inner)
            if !Sections.Has(Section)
                Sections[Section] := Map()
            continue
        }

        eq := InStr(Line, "=")
        if !eq
            continue
        key := Trim(SubStr(Line, 1, eq - 1))
        val := Trim(SubStr(Line, eq + 1))
        ; Quoted key: "Foo.Enabled" → Foo.Enabled
        if (StrLen(key) >= 2 && SubStr(key, 1, 1) = '"' && SubStr(key, -1) = '"')
            key := SubStr(key, 2, StrLen(key) - 2)
        if (Section = "")
            continue

        ; Strip inline comments (# …) unless the value is a quoted string.
        ; Must scan character-by-character to skip # inside quoted strings.
        if (SubStr(val, 1, 1) != '"') {
            hash_pos := InStr(val, "#")
            if (hash_pos > 0)
                val := Trim(SubStr(val, 1, hash_pos - 1))
        }

        ; Detect opening of a multi-line array: value starts with [ but has no ]
        if (SubStr(val, 1, 1) = "[" && !InStr(val, "]")) {
            PendingKey := key
            PendingVal := val
            continue
        }

        Sections[Section][key] := TOML_CoerceValue(val)
    }
    _ParseTomlCache[Path] := Sections
    return Sections
}

TOML_CoerceValue(raw) {
    raw := Trim(raw)
    if (raw = "")
        return ""
    if (StrLower(raw) = "true")
        return true
    if (StrLower(raw) = "false")
        return false
    ; Quoted string.
    if (SubStr(raw, 1, 1) = '"' && SubStr(raw, -1) = '"')
        return TOML_Unescape(SubStr(raw, 2, StrLen(raw) - 2))
    ; Array of strings: [ "a", "b", ... ]
    if (SubStr(raw, 1, 1) = "[" && SubStr(raw, -1) = "]") {
        body := Trim(SubStr(raw, 2, StrLen(raw) - 2))
        out := []
        if (body = "")
            return out
        in_str := false
        cur := ""
        loop parse, body {
            c := A_LoopField
            if (c = '"' && SubStr(cur, -1) != "\")
                in_str := !in_str
            if (!in_str && c = ",") {
                out.Push(TOML_CoerceValue(Trim(cur)))
                cur := ""
                continue
            }
            cur .= c
        }
        if (Trim(cur) != "")
            out.Push(TOML_CoerceValue(Trim(cur)))
        return out
    }
    if RegExMatch(raw, "^-?\d+$")
        return Integer(raw)
    ; Float literals: 0.25, -1.5, 3.14, etc.
    if RegExMatch(raw, "^-?\d+\.\d+$")
        return Float(raw)
    return raw
}

TOML_Unescape(s) {
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, "\\", "\")
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, "\r", "`r")
    return s
}





; ===================================
; =================================
; ======= 3/ Single-key API =======
; =================================
; ===================================

; Read a single key. Returns ``Default`` when the file, the section, or the
; key is missing. Coerces back to the closest AHK type — booleans become
; integers (1 / 0) so legacy callers that compare against ``true`` / ``1``
; keep working without changes.
TOML_Read(Path, Section, Key, Default := "") {
    Sections := ParseTomlFile(Path)
    if !Sections.Has(Section) || !Sections[Section].Has(Key)
        return Default
    v := Sections[Section][Key]
    if (v = true)
        return 1
    if (v = false)
        return 0
    return v
}

; Write a single (Section, Key, Value) triple. Atomic via .tmp + rename.
; Order matches Win32 ``IniWrite(Value, Path, Section, Key)`` so existing
; call sites stay symmetrical.
TOML_Write(Value, Path, Section, Key) {
    updates := [{ Section: Section, Key: Key, Value: Value }]
    return TOML_BatchWrite(Path, updates)
}





; ===================================
; ===============================
; ======= 4/ Batch writer =======
; ===============================
; ===================================

; Apply every (Section, Key, Value) update in one read-modify-write cycle.
; Preserves keys we did not touch; sections appear in the original order
; followed by any newly introduced section. Returns true on success.
TOML_BatchWrite(Path, Updates) {
    if (Updates.Length = 0)
        return true

    Sections := ParseTomlFile(Path)
    ; Track section order so the on-disk layout stays stable across writes.
    ; ``ParseTomlFile`` already iterates the file in declaration order, so
    ; ``for`` over the resulting Map preserves it; we rebuild the order
    ; explicitly to make new sections deterministic.
    order := []
    for sec in Sections
        order.Push(sec)

    for _, U in Updates {
        Sec := U.Section
        K := U.Key
        V := U.Value
        if !Sections.Has(Sec) {
            Sections[Sec] := Map()
            order.Push(Sec)
        }
        ; Sentinel value "_DELETE_" removes the key rather than writing it
        if (V == "_DELETE_") {
            if Sections[Sec].Has(K)
                Sections[Sec].Delete(K)
        } else {
            Sections[Sec][K] := V
        }
    }

    body := ""

    EnsureTrailingBlankLines(count) {
        newline_run := 0
        i := StrLen(body)
        while (i > 0 && SubStr(body, i, 1) = "`n") {
            newline_run += 1
            i -= 1
        }
        current := newline_run > 0 ? (newline_run - 1) : 0
        while (current < count) {
            body .= "`n"
            newline_run += 1
            current += 1
        }
        while (current > count) {
            body := SubStr(body, 1, StrLen(body) - 1)
            newline_run -= 1
            current -= 1
        }
    }

    ; Sort sections alphabetically for stable, readable output
    SortedSections := []
    for sec in order
        SortedSections.Push(sec)
    SortedSections := SortArray(SortedSections)
    FirstSection := true
    for _, sec in SortedSections {
        if !FirstSection {
            EnsureTrailingBlankLines(5)
        }
        FirstSection := false
        body .= "[" . sec . "]`n"
        ; Sort keys alphabetically within each section
        SortedKeys := []
        for k, v in Sections[sec]
            SortedKeys.Push(k)
        SortedKeys := SortArray(SortedKeys)
        for _, k in SortedKeys
            body .= TOML_RenderKey(k) . " = " . TOML_RenderValue(Sections[sec][k]) . "`n"
    }

    tmp := Path . ".tmp"
    try FileDelete(tmp)
    try {
        f := FileOpen(tmp, "w", "UTF-8")
        if !f
            return false
        f.Write(body)
        f.Close()
    } catch {
        return false
    }
    if FileExist(Path)
        try FileDelete(Path)
    try FileMove(tmp, Path)
    catch
        return false

    ; Invalidate the parse cache so the next ParseTomlFile call re-reads
    ; the updated file rather than returning a stale snapshot.
    global _ParseTomlCache
    if _ParseTomlCache.Has(Path)
        _ParseTomlCache.Delete(Path)

    TOML_RunStrictCanonicalization(Path)
    return true
}

; Reformat a TOML file using the centralized Python formatter (format_toml.py).
; Ensures consistent === headers ===, sorted sections and keys across all config files.
; Mirrors the pattern used by toml_writer.lua on the Hammerspoon side.
TOML_FormatViaScript(Path) {
    RepoRoot := RegExReplace(A_ScriptDir, "\\?static\\drivers\\autohotkey$", "") . "\"
    FormatScript := RepoRoot . "tools\format_toml.py"
    if FileExist(FormatScript)
        RunWait(Format('python "{}" "{}"', FormatScript, Path), , "Hide")
}

; Enforce a strict schema on the unified driver config: after any successful
; TOML write targeting ConfigurationFile, rebuild the file from the in-memory
; state via SaveFullConfig so stale sections/keys are dropped.
TOML_RunStrictCanonicalization(Path) {
    global _TOML_STRICT_CANON_IN_PROGRESS, ConfigurationFile, _SaveFullConfigReady

    if (_TOML_STRICT_CANON_IN_PROGRESS = true)
        return
    if !IsSet(ConfigurationFile)
        return
    if (Path != ConfigurationFile)
        return
    if !IsSet(_SaveFullConfigReady)
        return

    _TOML_STRICT_CANON_IN_PROGRESS := true
    try SaveFullConfig()
    finally _TOML_STRICT_CANON_IN_PROGRESS := false
}

TOML_RenderKey(k) {
    ; Bare key: only A-Z / a-z / 0-9 / _ / -. Otherwise quote.
    if RegExMatch(k, "^[A-Za-z0-9_\-]+$")
        return k
    esc := StrReplace(k, "\", "\\")
    esc := StrReplace(esc, '"', '\"')
    return '"' . esc . '"'
}

TOML_RenderValue(v) {
    ; Numbers before booleans: in AHK, ``false`` is integer 0, so ``0 = false``
    ; is true and would serialize pred_indent=0 as ``false``.
    if (v is Array) {
        parts := []
        for s in v
            parts.Push(TOML_RenderString(String(s)))
        out := "["
        for i, p in parts
            out .= (i = 1 ? "" : ", ") . p
        out .= "]"
        return out
    }
    if IsNumber(v) {
        ; Use %g format to strip floating-point noise (0.20000000000000001 → 0.2)
        if v is Float
            return Format("{:.10g}", v)
        return String(v)
    }
    if (v = true)
        return "true"
    if (v = false)
        return "false"
    return TOML_RenderString(String(v))
}

TOML_RenderString(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return '"' . s . '"'
}





; ===================================
; =================================
; ======= 5/ Cache accessor =======
; =================================
; ===================================

; Look up Section/Key in a parsed cache (the Map produced by
; ``ParseTomlFile``). Returns ``Default`` (defaulting to the underscore
; sentinel) when either the section or the key is absent. Callers compare
; against ``"_"`` to detect missing entries cheaply.
IniCacheGet(Cache, Section, Key, Default := "_") {
    if Cache.Has(Section) and Cache[Section].Has(Key) {
        return Cache[Section][Key]
    }
    return Default
}

; Resolve a configured path: trim whitespace, treat empty / underscore as
; "use the default", otherwise return the trimmed value.
ResolveConfigPath(RawValue, DefaultPath) {
    Trimmed := Trim(RawValue)
    if (Trimmed == "" or Trimmed == "_") {
        return DefaultPath
    }
    return Trimmed
}





; =============================================
; ====================================
; ======= 6/ paths.toml reader =======
; ====================================
; =============================================

; Reads a simple flat TOML file (Key = "value" pairs, ignores comments).
; Auto-generates the file with a header comment if it does not exist.
; Returns a Map of all parsed key-value pairs.
ReadPathsToml(FilePath) {
    Result := Map()

    if !FileExist(FilePath) {
        ; Ensure the parent directory exists — in compiled mode FilePath lives in
        ; %APPDATA%\Ergopti\ which may not exist yet on a fresh install.
        try DirCreate(SubStr(FilePath, 1, InStr(FilePath, "\", , -1) - 1))

        ; Migration: the previous compiled location was inside the bundle dir
        ; (%LocalAppData%\Ergopti\bundle\paths.toml) which is wiped on every update.
        ; If the new stable location is empty but the old bundle-dir copy is still
        ; present (race window before the next bundle wipe), carry it over so the
        ; user's ConfigDirPath is not silently lost.
        LegacyPath := A_AppData . "\..\Local\Ergopti\bundle\paths.toml"
        if (A_IsCompiled and FileExist(LegacyPath)) {
            try FileCopy(LegacyPath, FilePath)
            ; Fall through — if the copy succeeded FilePath now exists and we read it below
        }

        if !FileExist(FilePath) {
            try {
                f := FileOpen(FilePath, "w", "UTF-8")
                if f {
                    DefaultDir := StrReplace(EnvGet("USERPROFILE"), "\", "/") . "/.config/ergopti_plus/"
                    f.Write("# Custom paths — auto-generated by ErgoptiPlus.`r`n")
                    f.Write("# Edit this file to point to your personal configuration folder.`r`n")
                    f.Write("# If absent or commented out, files are looked up in: " . DefaultDir . "`r`n")
                    f.Write("`r`n")
                    f.Write('# ConfigDirPath = "' . DefaultDir . '"`r`n')
                    f.Close()
                }
            }
            return Result
        }
    }

    loop parse, FileRead(FilePath), "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        if RegExMatch(Line, '^(\S+)\s*=\s*"(.*)"$', &Match) {
            Result[Match[1]] := StrReplace(Match[2], "/", "\")
        }
    }
    return Result
}
