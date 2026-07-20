; modules/keylogger/keylogger_webview.ahk

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
; ===============================
; ======= 1/ Module state =======
; ===============================
; ===================================

class KLWV {
    ; Whether WebView2 Runtime + the vendored wrapper are loadable.
    ; Probed once on first call; KLUI checks this before deciding
    ; between WebView2 and Edge --app=.
    static available := unset

    ; windows[key] := { which, gui, controller, webview, hwnd_host }
    ; key is "typing" or "apps".
    static windows := Map()

    ; Every open receives an ownership epoch. Timers and bridge callbacks bind
    ; it so an old host cannot target a dashboard reopened under the same key.
    static epoch := 0

    ; Last metrics_dir we built a prefetch for. Used by the ingest tick
    ; refresh path so callers don't have to re-pass the dir.
    static metrics_dir := ""
}





; =====================================
; =======================================
; ======= 2/ Probe / availability =======
; =======================================
; =====================================

KLWV_IsAvailable() {
    ; Probe once: does the wrapper class load + does WebView2Loader.dll
    ; sit in the expected vendor path? We don't try to instantiate the
    ; control here (that would spawn a runtime probe and slow startup);
    ; that happens lazily on first KLWV_Open.
    if KLWV.HasOwnProp("available") && KLWV.available != ""
        return KLWV.available
    KLWV.available := false
    loader := _VendorDir . "\64bit\WebView2Loader.dll"
    if !FileExist(loader)
        return false
    if !IsSet(WebView2)
        return false
    KLWV.available := true
    return true
}





; ===================================
; ==============================
; ======= 3/ Asset paths =======
; ==============================
; ===================================

; Resolve the local index.html of a dashboard before constructing its URL.
; Callers need the path as a postcondition: a syntactically valid file:/// URL
; for a missing asset only produces a blank WebView and loses the dashboard click.
KLWV_AssetPath(which) {
    global _SharedDir
    base := _SharedDir . "\ui\metrics_" . which . "\index.html"
    loop files, base
        base := A_LoopFileFullPath
    return base
}

; Virtual host mapped onto _SharedDir. `file://` is an OPAQUE origin: Chromium
; treats every file:// document as a unique security origin, and the
; window.chrome.webview message channel does not reliably deliver from it —
; postMessage returns undefined (so the page looks healthy) while nothing ever
; arrives host-side. Every interactive control on the dashboard was therefore
; dead: changing the date range or app filter posted a message that never landed,
; and the loader spinner span forever. The ui/ hosts were all migrated to a
; virtual host; these two modules/ hosts were missed.
global KLWV_VHOST := "ergopti.metrics"        ; -> _SharedDir
global KLWV_HOST_ACCESS_ALLOW := 1

; Resolve the https:// URL of a dashboard's index.html, served from the virtual
; host. Cache-busted: WebView2 caches virtual-host sub-resources by URL, so an
; edited frontend would otherwise be served stale.
KLWV_AssetUrl(which) {
    global KLWV_VHOST
    return "https://" . KLWV_VHOST . "/ui/metrics_" . which . "/index.html?cb=" . A_TickCount
}

; Resolve the https:// URL of the shared locales directory, same virtual host.
KLWV_LocalesUrl() {
    global KLWV_VHOST
    return "https://" . KLWV_VHOST . "/data/locales/"
}





; ============================================
; ===========================================
; ======= 4/ Lifecycle (open / close) =======
; ===========================================
; ============================================

KLWV_Open(which, metrics_dir) {
    global _ConfigDir, _AhkSubDir
    log := _ConfigDir . _AhkSubDir . "logs\webview.log"
    try DirCreate(_ConfigDir . _AhkSubDir . "logs")
    try FileAppend("[" . A_Now . "] KLWV_Open(" . which . ") begin`r`n", log, "UTF-8")

    if !KLWV_IsAvailable() {
        try FileAppend("[" . A_Now . "] FAIL: WebView2 not available`r`n", log, "UTF-8")
        return false
    }
    if KLWV.windows.Has(which) && KLWV_IsAlive(KLWV.windows[which])
        return true   ; Already open; caller should foreground via KLWV_Focus.

    asset_path := KLWV_AssetPath(which)
    if !FileExist(asset_path) {
        try LoggerError("Keylogger", "KLWV_Open: dashboard asset is missing: '{1}'.", asset_path)
        return false
    }

    KLWV.metrics_dir := metrics_dir

    ; Do NOT build here — on a cold DB the full build takes 30-75 s and
    ; blocks the window from appearing at all. The window navigates first;
    ; KLWV_DelayedFirstPush (1.5 s after nav) pushes the freshest available
    ; blob from KLPF_LAST_JSON, which live ticks keep warm.
    ; If no live-tick blob exists yet (very first open after reload), the
    ; delayed push triggers a fast manifest-only build so the user sees
    ; KPIs within 2 s, and the first live tick (≤30 s) fills in n-grams.

    title := (which = "typing") ? t("keylogger_ui.typing_metrics") : t("metrics_apps.window_title")
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

    g.OnEvent("Size", KLWV_OnGuiSize.Bind(which))
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
    try FileAppend("[" . A_Now . "] center: mon work=" . work_w . "x" . work_h . " win=" . win_w . "x" . win_h .
        " pos=(" . pos_x . "," . pos_y . ")`r`n", log, "UTF-8")

    ; Spin up WebView2 inside the Gui's HWND. dataDir is unique per
    ; launch so cached state from a previous open never bleeds in.
    udir := A_Temp . "\ergopti_webview2_" . A_TickCount
    WebView_SweepStaleProfiles("ergopti_webview2_")
    DirCreate(udir)
    loader := _VendorDir . "\64bit\WebView2Loader.dll"

    ; thqby's wrapper resolves WebView2 asynchronously through a
    ; Promise; we await it inline so the rest of the wiring runs
    ; synchronously against a ready controller.
    try FileAppend("[" . A_Now . "] creating controller hwnd=" . g.Hwnd . " udir=" . udir . " loader=" . loader .
        "`r`n", log, "UTF-8")
    try {
        controller := WebView2.create(g.Hwnd, , 0, udir, "", 0, loader)
    } catch as err {
        try FileAppend("[" . A_Now . "] FAIL controller create: " . err.Message . " | " . err.File . ":" . err.Line .
            "`r`n", log, "UTF-8")
        ; Surface to the central logger too — webview.log is invisible to the
        ; standard diagnostics, so a half-installed WebView2 Runtime would
        ; otherwise fail silently (rule 5.3: never swallow without LoggerError).
        try LoggerError("Keylogger",
            "KLWV_Open: WebView2 controller create failed ('{1}') at {2}:{3} — dashboard cannot open.",
            err.Message, err.File, err.Line)
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
    ; we receive a string here. Must be a METHOD CALL, not a property
    ; assignment -- vendor WebView2.ahk's base class has no __Set
    ; meta-method, so `webview.WebMessageReceived := handler` is a silent
    ; no-op and the bridge never actually subscribes. The subscription
    ; handle is stored in KLWV.windows[which] (not discarded) so AHK's
    ; refcounting does not __Delete it and unsubscribe near-immediately.
    Epoch := ++KLWV.epoch
    msg_sub := webview.WebMessageReceived(KLWV_OnWebMessage.Bind(which, Epoch))

    ; Inject i18n base URL and locale code before page scripts run so
    ; i18n.js can resolve locale files without relying on currentScript
    ; path heuristics (which are unreliable across WebView2 versions).
    locales_url := KLWV_LocalesUrl()
    locale_code := I18nGetLocale()
    seed_script := "window.__i18n_base='" . locales_url . "';window._i18n_locale='" . locale_code . "';"
    try webview.AddScriptToExecuteOnDocumentCreated(seed_script)
    catch as err {
        try LoggerError("Keylogger",
            "KLWV_Open: WebView2 i18n bridge setup failed ('{1}') — dashboard cannot open.", err.Message)
        KLWV_AbortOpen(g, controller, udir)
        return false
    }
    try FileAppend("[" . A_Now . "] i18n seed: base=" . locales_url . " locale=" . locale_code . "`r`n", log, "UTF-8")

    ; Map the virtual host BEFORE navigating — the mapping must exist when the
    ; document is created or the https:// URL cannot resolve.
    global KLWV_VHOST, KLWV_HOST_ACCESS_ALLOW, _SharedDir
    try webview.SetVirtualHostNameToFolderMapping(KLWV_VHOST, _SharedDir, KLWV_HOST_ACCESS_ALLOW)
    catch as err {
        try LoggerError("Keylogger",
            "KLWV_Open: virtual-host mapping failed ('{1}') — the JS bridge would be dead, aborting.", err.Message)
        KLWV_AbortOpen(g, controller, udir)
        return false
    }

    asset := KLWV_AssetUrl(which)
    try FileAppend("[" . A_Now . "] navigating to " . asset . "`r`n", log, "UTF-8")
    try {
        webview.Navigate(asset)
    } catch as err {
        try FileAppend("[" . A_Now . "] FAIL navigate: " . err.Message . "`r`n", log, "UTF-8")
        ; Navigation failure leaves a blank window; mirror it to the central
        ; logger so the failure is diagnosable without trawling webview.log.
        try LoggerWarn("Keylogger",
            "KLWV_Open: WebView2 navigate to '{1}' failed ('{2}').",
            asset, err.Message)
        KLWV_AbortOpen(g, controller, udir)
        return false
    }
    ; Belt-and-suspenders alongside the "ready" handshake wired above:
    ; push the freshest blob a beat after navigation too, in case the page's
    ; own chrome.webview.postMessage('ready') races the subscription above
    ; (e.g. fires before AddScriptToExecuteOnDocumentCreated has run). 1.5 s
    ; is enough for a local file:// page + CDN-backed scripts to be ready.
    KLWV.windows[which] := Map(
        "which", which,
		"epoch", Epoch,
        "gui", g,
        "controller", controller,
        "webview", webview,
        "udir", udir,
        "msg_sub", msg_sub
    )
	SetTimer(KLWV_DelayedFirstPush.Bind(which, Epoch), -1500)
    KLWV_FitWebView(which)
    return true
}

; Unwind an unpublished WebView setup transaction. No KLWV.windows entry exists
; yet, so KLWV_Close cannot be used; releasing it here guarantees the caller can
; safely choose the Edge fallback without leaking an invisible controller/profile.
KLWV_AbortOpen(gui, controller, udir) {
    try controller.Close()
    try gui.Destroy()
    if (udir != "")
        SetTimer(KLWV_DeferredDirDelete.Bind(udir), -1000)
}

KLWV_IsCurrent(which, Epoch := 0) {
	if !KLWV.windows.Has(which)
		return false
	entry := KLWV.windows[which]
	return (Epoch = 0 || (entry.Has("epoch") && entry["epoch"] = Epoch))
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
    ; Remove the live lookup before releasing COM. Delayed timers and callbacks
    ; resolve by ``which``; deleting this generation first makes every stale
    ; callback inert instead of allowing it to target a just-reopened dashboard.
    KLWV.windows.Delete(which)
    udir := entry.Has("udir") ? entry["udir"] : ""
    ; A subscription removes itself through the still-live controller. Releasing
    ; it after Close() raises against an invalid COM pointer and leaks the sink.
    if entry.Has("msg_sub")
        entry.Delete("msg_sub")
    try entry["controller"].Close()
    try entry["gui"].Destroy()
    ; Edge child processes commonly retain the profile lock briefly after
    ; controller shutdown. Never synchronously sweep the profile on the UI
    ; callback; retry a bounded deferred cleanup instead.
    if (udir != "")
        SetTimer(KLWV_DeferredDirDelete.Bind(udir), -1000)
}

KLWV_DeferredDirDelete(udir, attempts := 0) {
    if !DirExist(udir)
        return
    try {
        DirDelete(udir, true)
        return
    } catch as e {
        if (attempts < 3) {
            SetTimer(KLWV_DeferredDirDelete.Bind(udir, attempts + 1), -1000)
            return
        }
        LoggerWarn("Keylogger", "Could not delete WebView profile '{1}' after retries: {2}", udir, e.Message)
    }
}

KLWV_CloseAll() {
    for which, _ in KLWV.windows.Clone()
        KLWV_Close(which)
}





; ===================================
; =========================
; ======= 5/ Sizing =======
; =========================
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
KLWV_OnWebMessage(which, Epoch, sender, args) {
    global _ConfigDir, _AhkSubDir
    ; WebMessageReceived is a COM callback and therefore bypasses native
    ; Suspend. A paused dashboard must not rebuild caches, project SQL, or
    ; push UI state from a late Refresh/Clear/Range click.
    if A_IsSuspended
        return
	if !KLWV_IsCurrent(which, Epoch)
		return
	entry := KLWV.windows[which]
	if !entry.Has("webview") || !(sender == entry["webview"])
		return
    log := _ConfigDir . _AhkSubDir . "logs\webview.log"
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
            ; receive pushes. Inject i18n strings first (fetch() is
            ; blocked by CORS on file:// origins in WebView2), then
            ; send the latest prefetch so the dashboard renders.
            KLWV_InjectI18n(which)
            KLWV_PushPrefetch(which)
		case "request_refresh":
			KLPF_RequestBuild(which, KLWV.metrics_dir, "full", Epoch,
				KLWV_OnBuildReady.Bind(which, Epoch))
		case "range":
			; A selected-range projection can be large enough to stall the hook.
			; Build it in a detached worker; the completion asks WebView to fetch
			; the staged JSON directly, so AHK never decodes the large payload.
			query := KLWV_NormalizeRangeRequest(msg)
			if query
				KLPF_RequestRange(which, KLWV.metrics_dir, query, Epoch,
					KLWV_OnRangeBuildReady.Bind(which, Epoch))
		case "clear_cache":
            ; Purge every layer of cache so the next rebuild is a full cold read:
            ; - KLPF_MANIFEST_CACHE: manifest projection (historical days)
            ; - KLPF_LAST_JSON:      in-memory JSON blob for the push path
            ; - KLRCache:            in-memory SQLite DB (force reload from data.sql)
            ; The on-disk prefetch is also deleted so a stale file isn't served
            ; if the page reloads before the new push arrives.
            global KLPF_MANIFEST_CACHE, KLPF_LAST_JSON
            KLPF_MANIFEST_CACHE := unset
            KLR_ResetCache()
            if IsSet(KLPF_LAST_JSON) && KLPF_LAST_JSON.Has(which)
                KLPF_LAST_JSON.Delete(which)
            try FileDelete(KLPF_PrefetchPath(which))
            try FileAppend("[" . A_Now . "] clear_cache(" . which . "): caches purged`r`n", log, "UTF-8")
            ; Projection runs in a detached worker; a late pre-clear result is
            ; fenced by the generation held by KLPF_RequestBuild.
            KLPF_RequestBuild(which, KLWV.metrics_dir, "full", Epoch,
                KLWV_OnBuildReady.Bind(which, Epoch))
    }
}

; Parse and validate the selected-range request emitted by metrics_typing/data.js.
; Date strings are deliberately constrained before reaching KLR_DateFilter, and
; only non-empty string app names make it into the SQLite IN clause.
KLWV_NormalizeRangeRequest(msg) {
    try query := KL_JsonDecode(msg)
    catch
        return 0
    if !(query is Map)
        return 0

    start_date := query.Has("start_date") ? String(query["start_date"]) : ""
    end_date := query.Has("end_date") ? String(query["end_date"]) : ""
    ; Reject loudly: a bare 0 makes "malformed request" indistinguishable from
    ; "no request", which is why the broken date pattern above silently killed
    ; every range query with nothing in the log to point at it.
    if !KLWV_IsIsoDate(start_date) || !KLWV_IsIsoDate(end_date) {
        try LoggerWarn("Keylogger", "Range request rejected — non-ISO date(s) '{1}'…'{2}'.", start_date, end_date)
        return 0
    }
    if (start_date != "" && end_date != "" && StrCompare(start_date, end_date) > 0) {
        try LoggerWarn("Keylogger", "Range request rejected — start '{1}' is after end '{2}'.", start_date, end_date)
        return 0
    }

    apps := []
    seen := Map()
    if query.Has("apps") && query["apps"] is Array {
        for _, app_name in query["apps"] {
            if (Type(app_name) != "String" || app_name = "" || seen.Has(app_name))
                continue
            seen[app_name] := true
            apps.Push(app_name)
        }
    }
    return Map("start_date", start_date, "end_date", end_date, "apps", apps)
}

; ISO-8601 calendar date, exactly YYYY-MM-DD. NOTE: AHK v2 escapes with a
; BACKTICK, not a backslash — "\\d" reaches PCRE as a literal backslash plus a
; literal "d", so the pattern only ever matched the text \dddd-\dd-\dd and no
; real date could pass. Every dashboard range request was then rejected with a
; bare 0 and dropped without a log.
global KLWV_ISO_DATE_PATTERN := "^\d{4}-\d{2}-\d{2}$"

KLWV_IsIsoDate(value) {
    return value = "" || RegExMatch(value, KLWV_ISO_DATE_PATTERN)
}

KLWV_OnRangeBuildReady(which, Epoch, stage, *) {
    if A_IsSuspended || !KLWV_IsCurrent(which, Epoch) || !FileExist(stage) {
        try FileDelete(stage)
        return
    }
    ; ``ExecuteScriptAsync`` is fire-and-forget: WebView performs the file read,
    ; JSON parse and range render in its own process, not on the keyboard thread.
    url := "file:///" . StrReplace(stage, "\", "/")
    js := "fetch('" . url . "').then(r=>r.json()).then(p=>window.receive_range_data(p)).catch(()=>{});"
    try KLWV.windows[which]["webview"].ExecuteScriptAsync(js)
    catch as err {
        try LoggerError("Keylogger", "KLWV_OnRangeBuildReady: range delivery failed for '{1}': {2}", which, err.Message)
    }
    ; Give the renderer ample time to open the file, then clean the private
    ; staged result.  A late timer only removes this generation's unique path.
    SetTimer(KLWV_DeleteRangeStage.Bind(stage), -60000)
}

KLWV_DeleteRangeStage(stage) {
    try FileDelete(stage)
}





; ====================================
; ==================================
; ======= 7/ Push (AHK → JS) =======
; ==================================
; ====================================

; Push the contents of the freshly-built prefetch.json to the page as a
; structured WebView2 message. The page bootstrap dispatches it to
; process_manifest just like the initial fetch.
KLWV_PushPrefetch(which) {
    global _ConfigDir, _AhkSubDir
    log := _ConfigDir . _AhkSubDir . "logs\webview.log"
    if !KLWV.windows.Has(which) {
        try FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): no window`r`n", log, "UTF-8")
        return false
    }
    ; Prefer the in-memory JSON cache populated by KLPF_BuildAndWrite —
    ; saves a 300 KB FileRead per push. Fall back to disk if the cache is
    ; empty (e.g. dashboard opened from a stale prefetch.json).
    global KLPF_LAST_JSON
    body := ""
    if IsSet(KLPF_LAST_JSON) && KLPF_LAST_JSON.Has(which)
        body := KLPF_LAST_JSON[which]
    if (body = "") {
        path := KLPF_PrefetchPath(which)
        if !FileExist(path) {
            try FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): prefetch.json missing at " . path . "`r`n",
                log, "UTF-8")
            return false
        }
        try body := FileRead(path, "UTF-8")
        catch as err {
            try LoggerError("Keylogger", "KLWV_PushPrefetch: cannot read '{1}': {2}", path, err.Message)
            return false
        }
    }
    if (body = "")
        return false
    msg := '{"type":"prefetch","blob":' . body . '}'
    entry := KLWV.windows[which]
    try {
        entry["webview"].PostWebMessageAsString(msg)
        FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): pushed " . StrLen(msg) . " bytes`r`n", log, "UTF-8")
        return true
    } catch as err {
        FileAppend("[" . A_Now . "] PushPrefetch(" . which . "): FAIL " . err.Message . "`r`n", log, "UTF-8")
        try LoggerError("Keylogger", "KLWV_PushPrefetch: dashboard delivery failed for '{1}': {2}", which, err.Message)
        return false
    }
}

; Inject the active locale strings directly into the WebView via ExecuteScriptAsync.
; fetch() is blocked by CORS on file:// origins in WebView2, so i18n.js cannot
; load locale JSON on its own. We read the file on the AHK side and push the
; pre-parsed strings into window._i18n_strings, then call i18n_apply() to
; populate all data-i18n attributes immediately.
KLWV_InjectI18n(which) {
    global _SharedDir, _ConfigDir, _AhkSubDir
    log := _ConfigDir . _AhkSubDir . "logs\webview.log"
    try FileAppend("[" . A_Now . "] InjectI18n(" . which . "): called, has_window=" . (KLWV.windows.Has(which) ? "1" : "0") . "`r`n", log, "UTF-8")
    if !KLWV.windows.Has(which)
        return
    locale_code := I18nGetLocale()
    json_path := _SharedDir . "\data\locales\" . locale_code . ".json"
    json_str := "{}"
    if FileExist(json_path)
        try json_str := FileRead(json_path, "UTF-8")
    ; Strip UTF-8 BOM if present — FileRead may leave it in.
    if (SubStr(json_str, 1, 1) = Chr(0xFEFF))
        json_str := SubStr(json_str, 2)
    js := "window._i18n_strings=" . json_str . ";if(typeof window.i18n_apply==='function')window.i18n_apply(window._i18n_strings);"
    ; Run OUTSIDE the current call stack via a one-shot timer. ExecuteScript is
    ; ExecuteScriptAsync().await(), which spins a NESTED message loop; calling it
    ; synchronously from inside the WebMessageReceived STA callback (as the
    ; "ready" handler does) re-enters the STA apartment and wedges further
    ; WebView2 message delivery -- see project_webview2_bridge_gotchas. Deferring
    ; via SetTimer(-1) lets the callback return first, keeping event delivery
    ; alive; KLWV_RunScript then fires ExecuteScriptAsync fire-and-forget.
    SetTimer(KLWV_RunScript.Bind(which, js, locale_code), -1)
}

; Executes a queued script on a fresh call stack (scheduled by KLWV_InjectI18n via
; a -1 timer). Fire-and-forget ExecuteScriptAsync (no .await()) -- we do not need
; the return value, and awaiting a large locale-string payload can otherwise fail
; to complete and wedge the AHK thread under live WebView2 traffic (see
; project_webview2_bridge_gotchas).
KLWV_RunScript(which, js, locale_code) {
    global _ConfigDir, _AhkSubDir
    log := _ConfigDir . _AhkSubDir . "logs\webview.log"
    if !KLWV.windows.Has(which)
        return
    try {
        KLWV.windows[which]["webview"].ExecuteScriptAsync(js)
        try FileAppend("[" . A_Now . "] InjectI18n(" . which . "): injected locale='" . locale_code . "' len=" . StrLen(js) . "`r`n", log, "UTF-8")
    } catch as err {
        try FileAppend("[" . A_Now . "] InjectI18n(" . which . "): FAIL " . err.Message . "`r`n", log, "UTF-8")
    }
}

; Resolve which AHK monitor index contains the (x, y) point. Walks the
; monitor list and returns the first match. AHK v2 has no built-in
; helper for this; a Win32 MonitorFromPoint call would return an HMONITOR
; we'd then have to map back to an index — easier to iterate ourselves.
KLWV_MonitorFromPoint(x, y) {
    loop MonitorGetCount() {
        try {
            MonitorGet(A_Index, &L, &T, &R, &B)
            if (x >= L && x < R && y >= T && y < B)
                return A_Index
        }
    }
    return 0
}

KLWV_DelayedFirstPush(which, Epoch) {
    global _ConfigDir, _AhkSubDir
    log := _ConfigDir . _AhkSubDir . "logs\webview.log"
    try FileAppend("[" . A_Now . "] DelayedFirstPush(" . which . "): fired, has_window=" . (KLWV.windows.Has(which) ? "1" : "0") . "`r`n", log, "UTF-8")
    if A_IsSuspended || !KLWV_IsCurrent(which, Epoch)
        return
    global KLPF_LAST_JSON
    ; Inject i18n first — must happen before any DB build which can block
    ; for tens of seconds on a cold cache.
    KLWV_InjectI18n(which)
    ; Only build if we have no cached blob yet.  Even a cold cache is safe:
    ; KLPF_RequestBuild starts a detached /force worker, never SQLite work on
    ; this timer or the keyboard thread.
    need_manifest_build := !IsSet(KLPF_LAST_JSON) || !KLPF_LAST_JSON.Has(which)
    if need_manifest_build && KLWV.metrics_dir {
        KLPF_RequestBuild(which, KLWV.metrics_dir, "manifest", Epoch,
            KLWV_OnFirstBuildReady.Bind(which, Epoch))
        return
    }
    FirstPaintOk := KLWV_PushPrefetch(which)
    ; Mark first paint done so live ticks can fan out from now on.
    if FirstPaintOk && KLWV_IsCurrent(which, Epoch)
        KLWV.windows[which]["first_paint_done"] := true
    ; Phase 2 — full historical build in a deferred timer (2 s later).
    ; Provides the historical n-gram tables without blocking the first paint.
    if FirstPaintOk
		SetTimer(KLWV_DelayedFullBuild.Bind(which, Epoch), -2000)
}

KLWV_DelayedFullBuild(which, Epoch) {
    if A_IsSuspended || !KLWV_IsCurrent(which, Epoch)
        return
    if KLWV.metrics_dir
        KLPF_RequestBuild(which, KLWV.metrics_dir, "full", Epoch,
            KLWV_OnBuildReady.Bind(which, Epoch))
}

KLWV_OnFirstBuildReady(which, Epoch, *) {
    if A_IsSuspended || !KLWV_IsCurrent(which, Epoch)
        return
    if !KLWV_PushPrefetch(which)
        return
    if KLWV_IsCurrent(which, Epoch)
        KLWV.windows[which]["first_paint_done"] := true
    SetTimer(KLWV_DelayedFullBuild.Bind(which, Epoch), -2000)
}

KLWV_OnBuildReady(which, Epoch, *) {
    if A_IsSuspended || !KLWV_IsCurrent(which, Epoch)
        return
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
    global _ConfigDir, _AhkSubDir
    log := _ConfigDir . _AhkSubDir . "logs\webview.log"
    if !KLWV.metrics_dir {
        return
    }
    n := 0
    for which, entry in KLWV.windows {
        ; Skip live ticks until the first FULL paint has landed —
        ; otherwise an empty-historical live blob would race the full
        ; one and leave the dashboard with wiped n-gram tables.
        if !(entry is Map && entry.Has("first_paint_done") && entry["first_paint_done"])
            continue
        n += 1
        KLPF_RequestBuild(which, KLWV.metrics_dir, mode, entry["epoch"],
            KLWV_OnBuildReady.Bind(which, entry["epoch"]))
    }
    if n
        try FileAppend("[" . A_Now . "] NotifyIngest(" . mode . ") fanned out to " . n . " window(s)`r`n", log, "UTF-8"
        )
}
