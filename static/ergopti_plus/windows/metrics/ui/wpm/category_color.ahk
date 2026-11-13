; metrics/ui/wpm/category_color.ahk

; ==============================================================================
; MODULE: WPM Widget — Category Colour Source
; DESCRIPTION:
; Answers which colour a hotstring category paints the WPM widget. Apart from
; display.ahk so its cache can be run alone: that file owns the keystroke
; pipeline, which the unit suite replaces with a recording stub.
; ==============================================================================

#Requires AutoHotkey v2.0

; Resolve the color for a hotstring category.
;
; The USER OVERRIDE comes first. Reading the TOML file directly — which is all
; this used to do — sees only what is on disk, so a color changed in the config
; window sat in _HotstringsOverrides and never reached the widget until the next
; reload: the tooltip repainted immediately and the widget did not, from the same
; edit. HotstringsResolve owns the full cascade (user section > user category >
; TOML section > TOML category > default) and is the single place that knows
; about overrides at all.
;
; The direct TOML read remains as the FALLBACK, which is the case the bypass was
; written for: during early init _SharedDir may not be resolved yet and the
; resolver would hand back a stale empty entry.
; Returns "" when neither source has a color.
; Only the FALLBACK file read is memoized, in a static Map keyed by
; CategoryName. The resolver is asked on every call and is never memoized here.
_WPMWidget_ReadTomlColor(CategoryName) {
    static _color_cache := Map()

    ; Ask the override-aware resolver FIRST, before any cache lookup. The
    ; cache-hit early return used to sit above this block, so the first call
    ; that fell through to the fallback (resolver not yet available during early
    ; init — the exact window the fallback exists for) cached its answer, often
    ; the empty string, and every later call short-circuited on it. The resolver
    ; was then skipped permanently for that category: a colour changed in the
    ; config window repainted the tooltip and left the widget on the manual blue
    ; until restart, which is the very staleness the resolver was added to fix.
    ; Its result is deliberately NOT memoized — HotstringsResolve owns a
    ; generation-invalidated cache of its own (_HSResolveCache /
    ; HotstringsResolveBumpGen), and a second copy here could only desynchronise
    ; from it.
    if (CategoryName != "" and IsSet(HotstringsResolve)) {
        try {
            Resolved := HotstringsResolve(CategoryName, "")
            if (IsObject(Resolved) and Resolved.HasOwnProp("Color") and Resolved.Color != "")
                return Resolved.Color
        }
    }

    ; Resolver unavailable or empty — serve the memoized file read. The WPM tick
    ; fires every ~100 ms and would otherwise re-read the category TOML dozens of
    ; times per second.
    if _color_cache.Has(CategoryName)
        return _color_cache[CategoryName]

    global _SharedDir, GLOBAL_DEFAULT_COLOR
    FilePath := HotstringsBundledTomlPath(CategoryName)
    if !FileExist(FilePath) {
        LoggerDebug("WPMWidget", "ReadTomlColor: file not found for '{1}': {2}", HotstringCategoryLogName(CategoryName), FilePath)
        _color_cache[CategoryName] := ""
        return ""
    }
    FileContent := FileRead(FilePath, "UTF-8")
    InMeta := false
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#")
            continue
        if (SubStr(Line, 1, 2) == "[[")
            break
        if (Line == "[_meta]") {
            InMeta := true
            continue
        }
        if (SubStr(Line, 1, 1) == "[") {
            InMeta := false
            continue
        }
        if InMeta and RegExMatch(Line, '^color\s*=\s*"([^"]+)"', &M) {
            c := M[1]
            LoggerDebug("WPMWidget", "ReadTomlColor: '{1}' → raw='{2}' default='{3}'", HotstringCategoryLogName(CategoryName), c, GLOBAL_DEFAULT_COLOR)
            ; Skip the global blue fallback — it means "no category color set"
            result := (c != GLOBAL_DEFAULT_COLOR) ? c : ""
            _color_cache[CategoryName] := result
            return result
        }
    }
    LoggerDebug("WPMWidget", "ReadTomlColor: no color key found for '{1}'", HotstringCategoryLogName(CategoryName))
    _color_cache[CategoryName] := ""
    return ""
}
