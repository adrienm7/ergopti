; modules/keylogger_ui.ahk

; ==============================================================================
; MODULE: Keylogger UI Launcher
; DESCRIPTION:
; Opens / closes / toggles the typing-metrics and apps-time dashboards on
; Windows. Mirrors the role of `ui/metrics_typing` and `ui/metrics_apps` in
; Hammerspoon: a single point of entry the menu and the shortcut bindings
; both call through.
;
; FEATURES & RATIONALE:
; 1. PID tracking: each window's launching process PID is stored so that a
;    second call to the same Toggle* function can close the window cleanly
;    instead of opening a second copy.
; 2. msedge --app=file:// fallback: Edge ships with every Windows 10/11
;    install and the --app flag opens a chromeless WebView pointing at any
;    file URL. No vendor library required for a usable v1.
;    A future iteration can swap to a proper WebView2 control via
;    vendor/Webview2.ahk; the rest of this module stays unchanged.
; 3. Pre-launch ingest: KL_IngestOnce() flushes today.log to data.sql so
;    the page reads the freshest possible snapshot.
;
; INTEGRATION:
; The two public toggles ``KLUI_ToggleTyping`` / ``KLUI_ToggleApps`` are
; registered in lib/dispatchers.ahk SIMPLE_ACTIONS so any feature gate
; (TapHolds, AltGr, personal shortcuts) can fire them. The tray menu in
; ErgoptiPlus.ahk wires them as menu items + accepts a user-defined hotkey
; via lib/metrics_shortcuts.ahk.
; ==============================================================================

#Requires Autohotkey v2.0+




; ===================================
; ===================================
; ======= 1/ Module state =======
; ===================================
; ===================================

class KLUI {
    ; PID of the currently-open dashboard process (0 = closed).
    static typing_pid := 0
    static apps_pid   := 0

    ; Resolved file URLs to the shared HTML assets. Set lazily on first call.
    static typing_url := ""
    static apps_url   := ""
}




; ============================================
; ============================================
; ======= 2/ Asset path resolution =======
; ============================================
; ============================================

KLUI_ResolveAssetUrl(which) {
    ; A_ScriptDir = …/autohotkey/
    ; The shared UI assets live in the sibling _shared/ folder.
    base := A_ScriptDir . "\..\_shared\ui\" . which . "\index.html"
    ; Resolve to absolute, normalised path.
    Loop Files, base
        base := A_LoopFileFullPath
    ; file:// URL: replace backslashes with forward slashes.
    url := "file:///" . StrReplace(base, "\", "/")
    return url
}

KLUI_EnsureUrls() {
    if (KLUI.typing_url = "")
        KLUI.typing_url := KLUI_ResolveAssetUrl("metrics_typing")
    if (KLUI.apps_url = "")
        KLUI.apps_url := KLUI_ResolveAssetUrl("metrics_apps")
}




; =========================================
; =========================================
; ======= 3/ Launch / kill helpers =======
; =========================================
; =========================================

KLUI_FindMsedge() {
    ; Edge ships in two canonical locations on Windows 10/11. Probe both;
    ; fall back to PATH-resolution via Run().
    candidates := [
        EnvGet("ProgramFiles") . "\Microsoft\Edge\Application\msedge.exe",
        EnvGet("ProgramFiles(x86)") . "\Microsoft\Edge\Application\msedge.exe",
        EnvGet("LOCALAPPDATA") . "\Microsoft\Edge\Application\msedge.exe"
    ]
    for path in candidates {
        if (path != "" && FileExist(path))
            return path
    }
    return "msedge.exe"  ; let Run() resolve via PATH.
}

KLUI_LaunchWindow(url, title) {
    ; Flush today.log → data.sql so the page sees fresh data.
    try KL_IngestOnce()

    edge := KLUI_FindMsedge()
    ; --app=URL launches a chromeless window pinned to URL. --user-data-dir
    ; isolates from the user's main Edge session so closing this window
    ; does not nuke their tabs. --window-size starts large but resizable.
    udir := A_Temp . "\ergopti_metrics_edge"
    DirCreate(udir)
    args := "--app=" . url
        . " --user-data-dir=" . '"' . udir . '"'
        . " --window-size=1400,900"
    pid := 0
    try Run('"' . edge . '" ' . args, , , &pid)
    catch as err {
        MsgBox("Impossible de lancer le tableau de bord : " . err.Message,
            "Erreur — " . title, "Iconx")
        return 0
    }
    return pid
}

KLUI_KillWindow(pid) {
    if (pid = 0)
        return
    try ProcessClose(pid)
}

KLUI_IsRunning(pid) {
    if (pid = 0)
        return false
    return ProcessExist(pid) != 0
}




; =========================================
; =========================================
; ======= 4/ Public toggle API =======
; =========================================
; =========================================

; Bail-out helper. The dashboards are tightly coupled to the keylogger
; storage layer, so opening one while the feature is OFF would only show
; an empty page (and silently signal the user that the keylogger is
; capturing). Better: refuse with a friendly hint pointing to the toggle.
KLUI_RequireEnabled() {
    if MetricsShortcuts.enabled
        return true
    MsgBox(
        "Les métriques sont désactivées.`n`n"
        . "Pour les activer : icône de la zone de notification → 📊 Métriques → "
        . "« ❌ Métriques désactivées (cliquer pour activer) ».",
        "📊 Métriques", "Iconi"
    )
    return false
}

KLUI_ToggleTyping(*) {
    if !KLUI_RequireEnabled()
        return
    KLUI_EnsureUrls()
    if KLUI_IsRunning(KLUI.typing_pid) {
        KLUI_KillWindow(KLUI.typing_pid)
        KLUI.typing_pid := 0
        return
    }
    KLUI.typing_pid := KLUI_LaunchWindow(KLUI.typing_url, "Métriques de frappe")
}

KLUI_ToggleApps(*) {
    if !KLUI_RequireEnabled()
        return
    KLUI_EnsureUrls()
    if KLUI_IsRunning(KLUI.apps_pid) {
        KLUI_KillWindow(KLUI.apps_pid)
        KLUI.apps_pid := 0
        return
    }
    KLUI.apps_pid := KLUI_LaunchWindow(KLUI.apps_url, "Temps sur les applications")
}

KLUI_OpenTyping(*) {
    KLUI_EnsureUrls()
    if !KLUI_IsRunning(KLUI.typing_pid)
        KLUI.typing_pid := KLUI_LaunchWindow(KLUI.typing_url, "Métriques de frappe")
}

KLUI_OpenApps(*) {
    KLUI_EnsureUrls()
    if !KLUI_IsRunning(KLUI.apps_pid)
        KLUI.apps_pid := KLUI_LaunchWindow(KLUI.apps_url, "Temps sur les applications")
}

KLUI_CloseAll() {
    KLUI_KillWindow(KLUI.typing_pid)
    KLUI.typing_pid := 0
    KLUI_KillWindow(KLUI.apps_pid)
    KLUI.apps_pid := 0
}
