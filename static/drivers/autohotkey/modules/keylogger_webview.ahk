; modules/keylogger_webview.ahk

; ==============================================================================
; MODULE: Keylogger WebView2 Host (B niveau 2)
; DESCRIPTION:
; AHK Gui that embeds Microsoft Edge WebView2 to host the metrics
; dashboards. Replaces the standalone Edge --app= launcher of B niveau 1
; with an in-process WebView2 control so the AHK script can push live
; updates to the page (and conversely receive filter/query requests
; from JS) via the WebView2 message bridge.
;
; FEATURES & RATIONALE:
; 1. In-process bridge: ``WebView2.WebMessageReceived`` lets JS call
;    ``window.chrome.webview.postMessage(obj)`` and that lands directly
;    in our AHK callback — no file polling, no IPC.
; 2. Push side: ``CoreWebView2.PostWebMessageAsString(json)`` shoves a
;    payload into the page, which dispatches a ``message`` event the
;    bootstrap listens for. Used by the ingest tick to deliver fresh
;    prefetch blobs without reloading the page.
; 3. Per-dashboard window: each dashboard (typing / apps) gets its own
;    Gui so opening one doesn't yank focus from the other. State is
;    tracked per-key in the KLWV.windows Map.
; 4. Edge fallback retained: KLUI keeps the Edge --app= path as a
;    documented fallback when WebView2 Runtime is missing — the
;    initialiser sets KLWV.available to false in that case.
; ==============================================================================

#Requires Autohotkey v2.0+




; ===================================
; ===================================
; ======= 1/ Module state =======
; ===================================
; ===================================

class KLWV {
    ; Whether WebView2 Runtime + the vendored wrapper are loadable.
    ; Probed once on first call; KLUI checks this before deciding
    ; between WebView2 and Edge --app=.
    static available := unset

    ; windows[key] := { which, gui, controller, webview, hwnd_host }
    ; key is "typing" or "apps".
    static windows := Map()

    ; Last metrics_dir we built a prefetch for. Used by the ingest tick
    ; refresh path so callers don't have to re-pass the dir.
    static metrics_dir := ""
}




; =====================================
; =====================================
; ======= 2/ Probe / availability =======
; =====================================
; =====================================

KLWV_IsAvailable() {
    ; Probe once: does the wrapper class load + does WebView2Loader.dll
    ; sit in the expected vendor path? We don't try to instantiate the
    ; control here (that would spawn a runtime probe and slow startup);
    ; that happens lazily on first KLWV_Open.
    if KLWV.HasOwnProp("available") && KLWV.available != ""
        return KLWV.available
    KLWV.available := false
    loader := A_ScriptDir . "\vendor\64bit\WebView2Loader.dll"
    if !FileExist(loader)
        return false
    if !IsSet(WebView2)
        return false
    KLWV.available := true
    return true
}




; ===================================
; ===================================
; ======= 3/ Asset paths =======
; ===================================
; ===================================

; Resolve the absolute file:// URL of a dashboard's index.html.
KLWV_AssetUrl(which) {
    base := A_ScriptDir . "\..\_shared\ui\metrics_" . which . "\index.html"
    Loop Files, base
        base := A_LoopFileFullPath
    return "file:///" . StrReplace(base, "\", "/")
}




; ============================================
; ============================================
; ======= 4/ Lifecycle (open / close) =======
; ============================================
; ============================================

KLWV_Open(which, metrics_dir) {
    global _ConfigDir
    log := _ConfigDir . "logs\webview.log"
    try DirCreate(_ConfigDir . "logs")
    try FileAppend("[" . A_Now . "] KLWV_Open(" . which . ") begin`r`n", log, "UTF-8")

    if !KLWV_IsAvailable() {
        try FileAppend("[" . A_Now . "] FAIL: WebView2 not available`r`n", log, "UTF-8")
        return false
    }
    if KLWV.windows.Has(which) && KLWV_IsAlive(KLWV.windows[which])
        return true   ; Already open; caller should foreground via KLWV_Focus.

    KLWV.metrics_dir := metrics_dir

    ; Generate a fresh prefetch.json before navigating so the page's
    ; bootstrap fetch always sees the freshest data.
    try KLPF_BuildAndWrite(which, metrics_dir)

    title := (which = "typing") ? "Métriques de frappe" : "Temps sur les applications"
    g := Gui("+Resize +MinSize800x600", title)
    g.MarginX := 0
    g.MarginY := 0

    ; Pick the monitor under the mouse cursor (where the user just
    ; clicked the tray menu) — defaulting to the primary monitor stuck
    ; the window on the wrong screen on multi-monitor setups. From
    ; there, take 70 % of the work area (taskbar already excluded by
    ; MonitorGetWorkArea) so the window comfortably fits with both
    ; the title bar AND a bit of breathing room around it.
    MouseGetPos(&mx, &my)
    mon := KLWV_MonitorFromPoint(mx, my)
    if !mon
        mon := MonitorGetPrimary()
    MonitorGetWorkArea(mon, &L, &T, &R, &B)
    work_w := R - L
    work_h := B - T
    initial_w := Min(Round(work_w * 0.70), 1300)
    initial_h := Min(Round(work_h * 0.70), 800)

    g.OnEvent("Size",  KLWV_OnGuiSize.Bind(which))
    g.OnEvent("Close", KLWV_OnGuiClose.Bind(which))
    ; Show first with the requested size, read the real outer-window
    ; rectangle, then WinMove to the centred position. Doing it in
    ; this order — instead of computing the centre from the client
    ; size up-front — accounts for the title bar + borders properly,
    ; and unlike Gui.GetPos on a hidden window it always returns the
    ; actual on-screen dimensions. The brief unmoved frame between
    ; the Show and the WinMove is imperceptible in practice.
    g.Show("w" . initial_w . " h" . initial_h)
    WinGetPos(, , &win_w, &win_h, "ahk_id " . g.Hwnd)
    pos_x := L + ((work_w - win_w) // 2)
    pos_y := T + ((work_h - win_h) // 2)
    WinMove(pos_x, pos_y, , , "ahk_id " . g.Hwnd)
    try FileAppend("[" . A_Now . "] center: mon work=" . work_w . "x" . work_h . " win=" . win_w . "x" . win_h . " pos=(" . pos_x . "," . pos_y . ")`r`n", log, "UTF-8")

    ; Spin up WebView2 inside the Gui's HWND. dataDir is unique per
    ; launch so cached state from a previous open never bleeds in.
    udir := A_Temp . "\ergopti_webview2_" . A_TickCount
    DirCreate(udir)
    loader := A_ScriptDir . "\vendor\64bit\WebView2Loader.dll"

    ; thqby's wrapper resolves WebView2 asynchronously through a
    ; Promise; we await it inline so the rest of the wiring runs
    ; synchronously against a ready controller.
    try FileAppend("[" . A_Now . "] creating controller hwnd=" . g.Hwnd . " udir=" . udir . " loader=" . loader . "`r`n", log, "UTF-8")
    try {
        controller := WebView2.create(g.Hwnd, , 0, udir, "", 0, loader)
    } catch as err {
        try FileAppend("[" . A_Now . "] FAIL controller create: " . err.Message . " | " . err.File . ":" . err.Line . "`r`n", log, "UTF-8")
        try g.Destroy()
        return false
    }
    try FileAppend("[" . A_Now . "] controller created OK`r`n", log, "UTF-8")
    webview := controller.CoreWebView2

    ; Disable Edge UI surfaces we don't want bleeding through —
    ; the dashboard is a chromeless single-page app.
    settings := webview.Settings
    ; Keep DevTools accelerators (F12, Ctrl+Shift+I) AND right-click
    ; "Inspect" available — they're the only way to triage live-update
    ; problems in a chromeless --app= window. Other Edge UI surfaces
    ; (status bar etc.) stay off; the dashboard is single-page and
    ; doesn't benefit from them.
    try settings.AreDevToolsEnabled := true
    try settings.AreDefaultContextMenusEnabled := true
    try settings.IsStatusBarEnabled := false
    try settings.AreBrowserAcceleratorKeysEnabled := true

    ; Bridge: JS → AHK. Page sends `chrome.webview.postMessage(obj)`;
    ; we receive a string here.
    webview.WebMessageReceived := KLWV_OnWebMessage.Bind(which)

    asset := KLWV_AssetUrl(which)
    try FileAppend("[" . A_Now . "] navigating to " . asset . "`r`n", log, "UTF-8")
    try {
        webview.Navigate(asset)
    } catch as err {
        try FileAppend("[" . A_Now . "] FAIL navigate: " . err.Message . "`r`n", log, "UTF-8")
    }
    ; The chrome.webview.postMessage('ready') handshake from JS goes
    ; through ICoreWebView2WebMessageReceived which thqby's wrapper
    ; binds via add_WebMessageReceived(TypedHandler) — a binding we
    ; haven't wired up yet. Instead, push the freshest blob a beat
    ; after navigation: 1.5 s is enough for a local file:// page +
    ; CDN-backed scripts to be ready to receive a postMessage.
    SetTimer(KLWV_DelayedFirstPush.Bind(which), -1500)

    KLWV.windows[which] := Map(
        "which",      which,
        "gui",        g,
        "controller", controller,
        "webview",    webview,
        "udir",       udir
    )
    KLWV_FitWebView(which)
    return true
}

KLWV_IsAlive(entry) {
    if !(entry is Map) || !entry.Has("gui")
        return false
    try return WinExist("ahk_id " . entry["gui"].Hwnd) ? true : false
    return false
}

KLWV_Focus(which) {
    if !KLWV.windows.Has(which)
        return
    try KLWV.windows[which]["gui"].Show()
}

KLWV_Close(which) {
    if !KLWV.windows.Has(which)
        return
    entry := KLWV.windows[which]
    try entry["controller"].Close()
    try entry["gui"].Destroy()
    KLWV.windows.Delete(which)
}

KLWV_CloseAll() {
    for which, _ in KLWV.windows.Clone()
        KLWV_Close(which)
}




; ===================================
; ===================================
; ======= 5/ Sizing =======
; ===================================
; ===================================

KLWV_FitWebView(which) {
    if !KLWV.windows.Has(which)
        return
    ; thqby's wrapper provides Fill() which reads the parent window's
    ; GetClientRect and assigns the RECT to Bounds — exactly what we
    ; want every time the host Gui is resized.
    try KLWV.windows[which]["controller"].Fill()
}

KLWV_OnGuiSize(which, gui, minMax, w, h) {
    if (minMax = -1)
        return
    KLWV_FitWebView(which)
}

KLWV_OnGuiClose(which, *) {
    KLWV_Close(which)
}




; ====================================
; ====================================
; ======= 6/ Bridge (JS → AHK) =======
; ====================================
; ====================================

; Receive a message posted by the page via chrome.webview.postMessage.
; The wrapper exposes the payload as a UTF-16 string; we treat it as a
; JSON command of the form {"action":"...", ...}.
KLWV_OnWebMessage(which, sender, args) {
    global _ConfigDir
    log := _ConfigDir . "logs\webview.log"
    msg := ""
    try msg := args.TryGetWebMessageAsString()
    try FileAppend("[" . A_Now . "] OnWebMessage(" . which . "): " . SubStr(msg, 1, 100) . "`r`n", log, "UTF-8")
    if (msg = "")
        return
    ; Tiny ad-hoc parser for the action verb — the only field we need
    ; right now is "action". Full payload parsing is deferred until we
    ; add filter pushdown commands.
    action := ""
    if RegExMatch(msg, '"action"\s*:\s*"([^"]+)"', &m)
        action := m[1]
    switch action {
        case "ready":
            ; Page just finished loading and signals it's ready to
            ; receive pushes. Send the latest prefetch immediately so
            ; the dashboard renders without waiting for the next ingest
            ; tick.
            KLWV_PushPrefetch(which)
        case "request_refresh":
            try KLPF_BuildAndWrite(which, KLWV.metrics_dir)
            KLWV_PushPrefetch(which)
    }
}




; ====================================
; ====================================
; ======= 7/ Push (AHK → JS) =======
; ====================================
; ====================================

; Push the contents of the freshly-built prefetch.json to the page as a
; structured WebView2 message. The page bootstrap dispatches it to
; process_manifest just like the initial fetch.
KLWV_PushPrefetch(which) {
    global _ConfigDir
    log := _ConfigDir . "logs\webview.log"
    if !KLWV.windows.Has(which) {
        try FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): no window`r`n", log, "UTF-8")
        return
    }
    path := KLPF_PrefetchPath(which)
    if !FileExist(path) {
        try FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): prefetch.json missing at " . path . "`r`n", log, "UTF-8")
        return
    }
    body := FileRead(path, "UTF-8")
    if (body = "")
        return
    msg := '{"type":"prefetch","blob":' . body . '}'
    entry := KLWV.windows[which]
    try {
        entry["webview"].PostWebMessageAsString(msg)
        FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): pushed " . StrLen(msg) . " bytes`r`n", log, "UTF-8")
    } catch as err {
        FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): FAIL " . err.Message . "`r`n", log, "UTF-8")
    }
}

; Resolve which AHK monitor index contains the (x, y) point. Walks the
; monitor list and returns the first match. AHK v2 has no built-in
; helper for this; a Win32 MonitorFromPoint call would return an HMONITOR
; we'd then have to map back to an index — easier to iterate ourselves.
KLWV_MonitorFromPoint(x, y) {
    Loop MonitorGetCount() {
        try {
            MonitorGet(A_Index, &L, &T, &R, &B)
            if (x >= L && x < R && y >= T && y < B)
                return A_Index
        }
    }
    return 0
}

KLWV_DelayedFirstPush(which) {
    if !KLWV.windows.Has(which)
        return
    ; First paint after navigation: do a single FULL projection so the
    ; n-gram tables, KPIs and charts all get populated. After that,
    ; the live updates flow through KLWV_NotifyIngest() in 'manifest'
    ; mode (the default) which is ~50 ms and fires on every flush
    ; tick. The slow ~3 s n-gram projection no longer runs on a
    ; periodic timer because each iteration would block AHK long
    ; enough to swallow several manifest pushes' worth of latency.
    if KLWV.metrics_dir
        try KLPF_BuildAndWrite(which, KLWV.metrics_dir, , "full")
    KLWV_PushPrefetch(which)
}

; Called by the ingest tick after data.sql has new rows. Rebuilds the
; prefetch blob and pushes it to every open dashboard.
;
; mode:
;   "manifest" — KPIs only, ~50 ms total. Omits _prefetch_data so the
;                page keeps the existing n-gram tables.
;   "live"     — manifest + today's top-500 n-grams (chars/bg/tg/qg/
;                words/word_bigrams) + kc heatmap + shortcuts. ~150-
;                300 ms. Default for the live tick so the keycode
;                heatmap, SFB heatmap and tables all track typing.
;   "full"     — full projection including historical. Used at first
;                paint to seed the cached historical block.
KLWV_NotifyIngest(mode := "live") {
    global _ConfigDir
    log := _ConfigDir . "logs\webview.log"
    if !KLWV.metrics_dir {
        return
    }
    n := 0
    for which, _ in KLWV.windows {
        n += 1
        try KLPF_BuildAndWrite(which, KLWV.metrics_dir, , mode)
        KLWV_PushPrefetch(which)
    }
    if n
        try FileAppend("[" . A_Now . "] NotifyIngest(" . mode . ") fanned out to " . n . " window(s)`r`n", log, "UTF-8")
}
