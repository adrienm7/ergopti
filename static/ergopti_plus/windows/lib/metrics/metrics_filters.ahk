; lib/metrics_filters.ahk

; ==============================================================================
; MODULE: Metrics Privacy Filters
; DESCRIPTION:
; Persists and evaluates the privacy filters that gate the keylogger hot
; path: private browsing detection, system-auth dialogs, and a per-app
; exclusion list. Mirrors the « FILTRES DE CONFIDENTIALITÉ » section of
; the Hammerspoon menu_metrics.lua.
;
; FEATURES & RATIONALE:
; 1. INI persistence: settings live alongside metrics_shortcuts.ini under
;    the [filters] / [disabled_apps] sections so they survive restarts.
; 2. Defaults safe: private + system-auth filters default to ON. Users
;    have to explicitly turn them OFF, never the other way around — same
;    contract as the global keylogger toggle.
; 3. Single chokepoint: KL_AppendLog() in modules/keylogger.ahk calls
;    MF_ShouldFilter() before any disk I/O, so every event source
;    (typing flush, shortcuts, hotstrings, system events, …) inherits
;    the filter for free.
;
; STORAGE FORMAT (metrics_shortcuts.ini):
;   [filters]
;   private_browsing = 1
;   system_auth      = 1
;
;   [disabled_apps]
;   list = Notepad.exe|chrome.exe|...
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ===============================
; ======= 1/ Module state =======
; ===============================
; ===================================

class MetricsFilters {
    ; Privacy filters — all three default ON. They only matter when the
    ; keylogger itself is enabled; KL_AppendLog short-circuits anyway
    ; when off.
    static private_browsing  := true
    static secure_field      := true   ; Ignorer les champs mot de passe (UIA)
    static system_auth       := true

    ; Per-app exclusion list. Keys are process names (e.g. "chrome.exe");
    ; presence of the key means « do not log this app ». Map for O(1)
    ; lookup on the hot path.
    static disabled_apps := Map()
}





; ============================================
; ==================================
; ======= 2/ INI load / save =======
; ==================================
; ============================================

; Persistence is delegated to lib/config_shortcuts.ahk (CS_Load / CS_Save)
; which owns the [shortcuts] section inside <config_dir>/config.toml.
; MF_LoadFromIni / MF_SaveToIni are kept as thin shims.
MF_LoadFromIni() {
    CS_Load()
}

MF_SaveToIni() {
    CS_Save()
}





; ===================================================
; =================================================
; ======= 3/ Window / process introspection =======
; =================================================
; ===================================================

; Cached focused-window probe. UIA-style filters can be expensive to run
; on every keystroke; we cache the (process_name, title, class) of the
; focused window for MF_FOCUS_TTL_MS so the per-call cost stays near-zero.
global MF_FOCUS_TTL_MS := 250

class MetricsFocusCache {
    ; Build-then-swap pattern for atomic state updates: multiple properties
    ; are gathered into a local object first, then published via a single
    ; reference swap. This ensures readers (MF_ShouldFilter) never see an
    ; inconsistent mix of old and new data (metrics-focus-cache-atomic).
    static state := {
        last_at:      0,
        hwnd:         0,
        process_name: "",
        title:        "",
        class:        ""
    }
}

MF_RefreshFocus() {
    if (A_TickCount - MetricsFocusCache.state.last_at) < MF_FOCUS_TTL_MS
        return
    hwnd := 0
    try hwnd := WinGetID("A")
    if !hwnd {
        ; Atomic swap: publish empty context
        MetricsFocusCache.state := {
            last_at:      A_TickCount,
            hwnd:         0,
            process_name: "",
            title:        "",
            class:        ""
        }
        return
    }
    
    pn := "", t := "", c := ""
    try pn := WinGetProcessName("ahk_id " . hwnd)
    try t  := WinGetTitle("ahk_id " . hwnd)
    try c  := WinGetClass("ahk_id " . hwnd)

    ; Atomic swap: readers always see a consistent snapshot.
    MetricsFocusCache.state := {
        last_at:      A_TickCount,
        hwnd:         hwnd,
        process_name: pn,
        title:        t,
        class:        c
    }
}





; ============================================
; ====================================
; ======= 4/ Filter predicates =======
; ====================================
; ============================================

; Heuristic patterns for private browsing windows. The match is on the
; window title and is intentionally generous — false positives mean
; "we logged a bit less than we could have", which is the safe direction.
global MF_PRIVATE_TITLE_PATTERNS := [
    "i)\bInPrivate\b",
    "i)\bIncognito\b",
    "i)\bPrivate Browsing\b",
    "i)\(Private\)",
    "i)Navigation privée",
    "i)Privé",
    "i)Privater Modus"
]

; System-auth windows. Both process names AND class names — UAC consent
; runs in consent.exe but the credential prompt that shows up for sudo-
; like operations runs as a XAML host with a stable class name.
global MF_SYSTEM_AUTH_PROCESSES := Map(
    "consent.exe",                 true,    ; UAC
    "logonui.exe",                 true,    ; lock screen
    "credentialuibroker.exe",      true,    ; modern credential prompts
    "credui.exe",                  true,    ; legacy credential prompts
    "winlogon.exe",                true
)
global MF_SYSTEM_AUTH_CLASSES := Map(
    "Credential Dialog Xaml Host", true,
    "ConsentUI",                   true,
    "LogonUI",                     true
)

; Returns true when the keylogger should DROP the current event because
; one of the privacy filters matches the focused window.
MF_ShouldFilter() {
    MF_RefreshFocus()
    
    ; Capture the reference once so all subsequent property reads are
    ; consistent with each other even if a background refresh occurs.
    s := MetricsFocusCache.state
    proc  := StrLower(s.process_name)
    title := s.title
    cls   := s.class

    ; 1. Disabled-apps list — fastest check.
    if (proc != "" && MetricsFilters.disabled_apps.Has(proc))
        return true

    ; 2. Password field — relies on the UIA-backed detector in
    ;    modules/keylogger.ahk §13. Wrapped in try because the function
    ;    is loaded later in the include order and an early caller (e.g.
    ;    boot-time metrics) might race ahead of it.
    if MetricsFilters.secure_field {
        is_pw := false
        try is_pw := KL_IsFocusedFieldPassword()
        if is_pw
            return true
    }

    ; 3. System-auth dialogs.
    if MetricsFilters.system_auth {
        if (proc != "" && MF_SYSTEM_AUTH_PROCESSES.Has(proc))
            return true
        if (cls != "" && MF_SYSTEM_AUTH_CLASSES.Has(cls))
            return true
    }

    ; 4. Private browsing (title pattern match).
    if MetricsFilters.private_browsing && title != "" {
        for _, pat in MF_PRIVATE_TITLE_PATTERNS {
            if RegExMatch(title, pat)
                return true
        }
    }
    return false
}





; ===================================================
; =================================================
; ======= 5/ Disabled-apps mutation helpers =======
; =================================================
; ===================================================

; Add or remove an app (process name) from the exclusion list. Persists
; immediately. Returns the new state (true = excluded).
MF_ToggleDisabledApp(process_name) {
    if (process_name = "")
        return false
    key := StrLower(process_name)
    if MetricsFilters.disabled_apps.Has(key) {
        MetricsFilters.disabled_apps.Delete(key)
        MF_SaveToIni()
        return false
    }
    MetricsFilters.disabled_apps[key] := true
    MF_SaveToIni()
    return true
}

MF_DisabledCount() {
    n := 0
    for _, _ in MetricsFilters.disabled_apps
        n += 1
    return n
}

MF_DisabledList() {
    out := []
    for name, _ in MetricsFilters.disabled_apps
        out.Push(name)
    return out
}
