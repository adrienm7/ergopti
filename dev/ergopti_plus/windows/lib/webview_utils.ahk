; lib/webview_utils.ahk

#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: WebView Utils
; DESCRIPTION:
; Shared helper functions for WebView2 instances.
; ==============================================================================

; A single WebView2 environment shared by every short-lived UI window for the
; whole session. Creating an environment boots an Edge/Chromium browser process,
; the expensive part (seconds under RAM pressure). Reusing one environment for
; every window means each new window only spins up a cheap controller, all
; windows share ONE browser process (lower peak RAM), and the on-disk cache is
; reused across opens -- so the second and later opens are near-instant even on a
; RAM-starved machine. Booted lazily on the first WebView open, cached for the
; rest of the session.
global _WebView_SharedEnv := 0

; True while a CreateEnvironmentAsync boot is in flight. Promise.await() pumps
; the Windows message queue while it blocks, so a second WebView2 host opened
; during the FIRST caller's await can reach WebView_SharedEnvironment before
; _WebView_SharedEnv is published -- without this flag it would race a second
; CreateEnvironmentAsync against the same locked WEBVIEW_SHARED_UDIR. Set
; BEFORE the await begins (not just around it) and always cleared in a
; ``finally`` so a boot failure cannot leave a waiting caller stuck forever.
global _WebView_SharedEnvCreating := false

; One stable user-data folder for the whole session. Unlike the former per-open
; "<prefix>_<A_TickCount>" folders, this fixed path cannot accumulate (there is
; exactly one and it is reused forever), so it is leak-free by construction.
global WEBVIEW_SHARED_UDIR := A_Temp . "\ergopti_wv_shared"

; Returns the shared WebView2 environment, booting it on first use.
; @param loader {String} Absolute path to WebView2Loader.dll.
; @returns {WebView2.Environment} The cached environment. Throws on boot failure,
;          so the caller's WebView2.create try/catch can degrade gracefully.
WebView_SharedEnvironment(loader) {
	global _WebView_SharedEnv, _WebView_SharedEnvCreating, WEBVIEW_SHARED_UDIR
	; Warm path -- reuse the already-running browser process.
	if _WebView_SharedEnv
		return _WebView_SharedEnv

	; `await()` pumps the message queue. A re-entrant second caller therefore
	; cannot wait here: its Sleep loop runs on AHK's only interpreter and prevents
	; the first await from receiving the completion that would clear this flag.
	; Fail this second open immediately so its normal native/unavailable fallback
	; runs; the first owner publishes the shared environment when it completes.
	if _WebView_SharedEnvCreating {
		throw Error("WebView shared environment is still initializing")
	}

	_WebView_SharedEnvCreating := true
	try DirCreate(WEBVIEW_SHARED_UDIR)
	try {
		; await() blocks until the environment (and its browser process) is ready.
		; Assigned only on success: a boot failure leaves the cache at 0 and lets the
		; exception propagate to the caller for graceful fallback.
		_WebView_SharedEnv := WebView2.CreateEnvironmentAsync(0, WEBVIEW_SHARED_UDIR, "", loader).await()
	} finally {
		_WebView_SharedEnvCreating := false
	}
	return _WebView_SharedEnv
}


; Below this much free physical RAM (MiB), a WebView window that has a native
; equivalent skips the Edge/Chromium cold start and uses that native view
; instead. Chromium needs real headroom to boot; on a thrashing machine the cold
; start costs many seconds, so a plain native view beats a styled WebView that
; takes a minute to appear. Tunable -- raise it to prefer native more often,
; lower it to prefer the richer WebView.
global WEBVIEW_MIN_AVAIL_RAM_MB := 1536

; Returns available physical RAM in MiB, or -1 when the OS query fails.
WebView_AvailRamMb() {
	MemStatus := Buffer(64, 0)
	NumPut("UInt", 64, MemStatus, 0)   ; dwLength -- required before the call
	if !DllCall("GlobalMemoryStatusEx", "Ptr", MemStatus)
		return -1
	return NumGet(MemStatus, 16, "UInt64") / 1048576   ; ullAvailPhys
}

; True when free RAM is too low to comfortably boot Chromium, so a WebView window
; should use its native fallback. An unknown reading never gates (returns false),
; leaving the WebView path to be attempted as before.
WebView_ShouldUseNativeFallback() {
	global WEBVIEW_MIN_AVAIL_RAM_MB
	Avail := WebView_AvailRamMb()
	if Avail < 0
		return false
	return Avail < WEBVIEW_MIN_AVAIL_RAM_MB
}


; Helper to clear stale WebView2 user-data profile directories.
; Call immediately before DirCreate(udir) and after controller.Close()/Gui.Destroy().
WebView_SweepStaleProfiles(prefix) {
    loop files, A_Temp . "\" . prefix . "*", "D" {
        try DirDelete(A_LoopFileFullPath, true)
    }
}


; ==============================================================================
; WebViewHost — factory class that consolidates the WebView2 lifecycle shared by
; every short-lived UI window. Each module that used to reimplement ~200 lines of
; identical boilerplate (Gui creation, show-before-create, WebView2.create +
; fallback, settings hardening, subscriptions, vhost mapping, i18n seed,
; navigation, queue-based eval, resize → Fill, safe teardown) now calls
; WebViewHost.TryOpen(AppId, Opts) and keeps only its business logic.
;
; The factory reads _shared/ui/apps.manifest.json once (lazy, cached) for
; per-app geometry + vhost name. macOS and the future Linux host also consume
; that manifest, so geometry is defined once for all three drivers.
; ==============================================================================

class WebViewHost {
    ; ── Static shared state ──────────────────────────────────────────────────
    ; "" is the "manifest not loaded yet" sentinel; _LoadManifest replaces it
    ; with a Map. Deliberately NOT ``unset``: _ManifestEntry reads the cache
    ; unconditionally via ``is Map``, and reading an ``unset`` property throws a
    ; PropertyError (see project-ahk-v2-static-unset-unreadable). A concrete
    ; sentinel makes both the load-once guard and the ``is Map`` read safe.
    static _ManifestCache := ""
    static _Instances      := Map()   ; AppId → WebViewHost (singleton tracking)

    ; ── Instance fields ──────────────────────────────────────────────────────
    AppId      := ""
    Gui        := 0
    Controller := unset
    WebView    := unset
    MsgSub     := unset
    NavSub     := unset
    Ready      := false
    ReadyFired := false   ; guards against double OnReady ("ready" msg + NavCompleted)
    Queue      := []
    ResetDone  := false
    Epoch      := 0      ; invalidates deferred callbacks after close/reset
    SafetyTimer := 0      ; BoundFunc for the safety flush; cancelled on teardown
    Opts       := unset

    ; --------------------------------------------------------------------------
    ; Factory: opens (or reuses) a WebView2 window for AppId.
    ; Returns a WebViewHost instance on success, or "" (falsy) on fallback.
    ; The caller checks the return value: if falsy, build the native fallback.
    ;
    ; Opts keys (all optional unless noted):
    ;   Title (required)     — window title string
    ;   OnMessage (required) — (Host, Payload) => void; called with parsed JSON
    ;   OnReady              — (Host) => void; called once when page is ready
    ;   MinSize              — override manifest min-size ("WxH"); auto-computed
    ;                          from manifest as "<min_w>x<min_h>" if absent
    ;   BackColor            — default "0x1e1e1e"
    ;   AllowMultiple        — default false; when true, every call creates a
    ;                          new window (no singleton enforcement)
    ;   ExtraVhosts          — Array of {host:"...", path:"..."} for additional
    ;                          virtual-host mappings beyond the primary one
    ;   SkipI18nSeed         — default false; when true the I18nSeed script is
    ;                          NOT injected via AddScriptToExecuteOnDocumentCreated
    ;   CustomHtmlPath       — override the convention "ui/<AppId>/index.html"
    ; --------------------------------------------------------------------------
    static TryOpen(AppId, Opts) {
        ; ── Load manifest if not cached ──────────────────────────────────────
        ; The cache holds "" until loaded, then a Map. AHK v2 ``IsSet`` accepts
        ; only a plain variable (never a property expression), so the not-loaded
        ; state is tested against the concrete "" sentinel, not IsSet.
        if (WebViewHost._ManifestCache == "") {
            WebViewHost._LoadManifest()
        }

        ; ── Singleton: reuse existing window ─────────────────────────────────
        if !(Opts.Has("AllowMultiple") && Opts["AllowMultiple"]) {
            if WebViewHost._Instances.Has(AppId) {
                Existing := WebViewHost._Instances[AppId]
                if (Existing.Gui != 0) {
                    try WinActivate("ahk_id " . Existing.Gui.Hwnd)
                    return Existing
                }
                ; Stale entry — remove and fall through to create a new one
                WebViewHost._Instances.Delete(AppId)
            }
        }

        ; ── Create the host instance ─────────────────────────────────────────
        Host := WebViewHost()
        Host.AppId := AppId
        Host.Opts  := Opts

        ; ── Build the window ─────────────────────────────────────────────────
        if !Host._Build() {
            return ""
        }

        ; ── Register singleton ───────────────────────────────────────────────
        if !(Opts.Has("AllowMultiple") && Opts["AllowMultiple"]) {
            WebViewHost._Instances[AppId] := Host
        }

        return Host
    }

    ; --------------------------------------------------------------------------
    ; Loads and caches the apps manifest (once per session).
    ; --------------------------------------------------------------------------
    static _LoadManifest() {
        WebViewHost._ManifestCache := Map()
        global _SharedDir
        Path := _SharedDir . "\ui\apps.manifest.json"
        if !FileExist(Path) {
            try LoggerWarn("WebViewHost", "apps.manifest.json not found at {1} — geometry will be missing.", Path)
            return
        }
        try {
            Raw := FileRead(Path, "UTF-8")
            Data := JsonParse(Raw)
            if (Data is Map && Data.Has("apps") && Data["apps"] is Map) {
                WebViewHost._ManifestCache := Data["apps"]
            }
        } catch as Err {
            try LoggerWarn("WebViewHost", "Failed to parse apps.manifest.json: {1}", Err.Message)
        }
    }

    ; --------------------------------------------------------------------------
    ; Returns the manifest entry for this app, or an empty Map on miss.
    ; --------------------------------------------------------------------------
    _ManifestEntry() {
        if WebViewHost._ManifestCache is Map && WebViewHost._ManifestCache.Has(this.AppId) {
            Entry := WebViewHost._ManifestCache[this.AppId]
            if Entry is Map
                return Entry
        }
        return Map()
    }

    ; --------------------------------------------------------------------------
    ; Reads the vhost name from the manifest, falling back to a convention.
    ; --------------------------------------------------------------------------
    _VhostName() {
        Entry := this._ManifestEntry()
        if Entry.Has("vhost") && Entry["vhost"] != ""
            return Entry["vhost"]
        return "ergopti." . this.AppId
    }

    ; --------------------------------------------------------------------------
    ; Reads geometry from the manifest. Returns {w, h, min_w, min_h}.
    ; --------------------------------------------------------------------------
    _Geometry() {
        Entry := this._ManifestEntry()
        W := Entry.Has("width")     && IsNumber(Entry["width"])     ? Entry["width"]     : 600
        H := Entry.Has("height")    && IsNumber(Entry["height"])    ? Entry["height"]    : 400
        MW := Entry.Has("min_width") && IsNumber(Entry["min_width"]) ? Entry["min_width"] : W
        MH := Entry.Has("min_height") && IsNumber(Entry["min_height"]) ? Entry["min_height"] : H
        return {w: W, h: H, min_w: MW, min_h: MH}
    }

    ; --------------------------------------------------------------------------
    ; Internal: builds Gui, creates WebView2 controller, hardens settings,
    ; sets up the bridge, maps vhost, seeds i18n, navigates, and fills.
    ; Returns true on success, false on fallback.
    ; --------------------------------------------------------------------------
    _Build() {
        global _VendorDir, _SharedDir, _I18nLocale
        this.Epoch += 1

        Opts  := this.Opts
        Title := Opts.Has("Title") ? Opts["Title"] : "ErgoptiPlus"
        Geo   := this._Geometry()
        Vhost := this._VhostName()
        BackColor := Opts.Has("BackColor") ? Opts["BackColor"] : "0x1e1e1e"
        MinSize   := Opts.Has("MinSize")   ? Opts["MinSize"]   : (Geo.min_w . "x" . Geo.min_h)

        ; ── Gui ──────────────────────────────────────────────────────────────
        g := Gui("+Resize +MinSize" . MinSize, Title)
        g.BackColor := BackColor
        g.MarginX   := 0
        g.MarginY   := 0
        Placeholder := g.Add("Text", "x0 y0 w" . Geo.w . " h" . Geo.h, "")
        g.OnEvent("Close", this._OnClose.Bind(this))
        g.OnEvent("Size",  this._OnResize.Bind(this))

        ; Show BEFORE creating the control — a hidden Gui has a zero client rect
        g.Show("w" . Geo.w . " h" . Geo.h . " Center")
        this.Gui := g

        ; ── WebView2 create ──────────────────────────────────────────────────
        loader := _VendorDir . "\64bit\WebView2Loader.dll"
        if !IsSet(WebView2) || !FileExist(loader) {
            try LoggerWarn("WebViewHost", "WebView2 unavailable for '{1}'.", this.AppId)
            try g.Destroy()
            this.Gui := 0
            return false
        }
        try {
            this.Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
        } catch as Err {
            try LoggerError("WebViewHost", "WebView2 create failed for '{1}': {2} — falling back.", this.AppId, Err.Message)
            try g.Destroy()
            this._Reset(false)
            this.Gui := 0
            return false
        }

        this.WebView   := this.Controller.CoreWebView2
        this.ResetDone := false

        ; ── Harden settings ──────────────────────────────────────────────────
        try {
            s := this.WebView.Settings
            s.AreDevToolsEnabled               := false
            s.AreDefaultContextMenusEnabled    := false
            s.IsStatusBarEnabled               := false
            s.AreBrowserAcceleratorKeysEnabled := false
            s.IsSwipeNavigationEnabled         := false
        }

        ; ── JS ↔ AHK bridge subscriptions ────────────────────────────────────
        this.MsgSub := this.WebView.WebMessageReceived(this._OnWebMessage.Bind(this))
        this.NavSub := this.WebView.NavigationCompleted(this._OnNavigationCompleted.Bind(this))

        ; ── Virtual host mapping ─────────────────────────────────────────────
        try this.WebView.SetVirtualHostNameToFolderMapping(Vhost, _SharedDir, 1)
        ; Extra vhosts (e.g. onboarding maps a second host to _StaticDir)
        if Opts.Has("ExtraVhosts") && Opts["ExtraVhosts"] is Array {
            for _, Ev in Opts["ExtraVhosts"] {
                if (Ev is Map && Ev.Has("host") && Ev.Has("path"))
                    try this.WebView.SetVirtualHostNameToFolderMapping(Ev["host"], Ev["path"], 1)
            }
        }

        ; ── i18n seed ────────────────────────────────────────────────────────
        if !(Opts.Has("SkipI18nSeed") && Opts["SkipI18nSeed"]) {
            Loc := IsSet(_I18nLocale) ? _I18nLocale : "en"
            Seed := "window.__i18n_base='https://" . Vhost . "/data/locales/';"
                . "window._i18n_locale='" . Loc . "';"
            try this.WebView.AddScriptToExecuteOnDocumentCreated(Seed)
        }

        ; ── Navigate ─────────────────────────────────────────────────────────
        HtmlPath := Opts.Has("CustomHtmlPath") ? Opts["CustomHtmlPath"] : ("/ui/" . this.AppId . "/index.html")
        try this.WebView.Navigate("https://" . Vhost . HtmlPath . "?cb=" . A_TickCount)
        try this.Controller.Fill()

        ; ── Safety flush: if the page never posts "ready", flush after 2.5 s ─
        ; Keep the BoundFunc itself: SetTimer RETURNS an empty string, so
        ; storing its return gave a "handle" that could never cancel anything —
        ; and the teardown below silently called SetTimer("", 0) inside a bare
        ; try. SetTimer keys on the callback object, so that is what to hold.
        this.SafetyTimer := this._SafetyFlush.Bind(this)
        SetTimer(this.SafetyTimer, -2500)

        try LoggerSuccess("WebViewHost", "{1} shown via WebView2.", this.AppId)
        return true
    }

    ; ── WebMessageReceived callback (COM) ────────────────────────────────────
    _OnWebMessage(Handler, Args) {
        if A_IsSuspended
            return
        try Msg := Args.TryGetWebMessageAsString()
        if !IsSet(Msg)
            return

        ; Reserved action "ready" — handled internally (bare string, as sent by
        ; chrome.webview.postMessage("ready") — WebView2 returns the raw text)
        if (Msg == "ready") {
            this._FlushQueue()
            this._FireOnReady()
            return
        }

        ; Parse JSON and dispatch to the module's OnMessage callback
        try Payload := JsonParse(Msg)
        if (!IsSet(Payload) || !(Payload is Map))
            return
        if this.Opts.Has("OnMessage") {
            ; Defer out of the COM callback so handlers never run re-entrantly
            SetTimer(this._DispatchMessage.Bind(this, this.Epoch, Payload), -1)
        }
    }

    _DispatchMessage(CallbackEpoch, Payload) {
        if A_IsSuspended || this.ResetDone || (CallbackEpoch != this.Epoch)
            return
        try this.Opts["OnMessage"](this, Payload)
    }

    ; ── NavigationCompleted callback ─────────────────────────────────────────
    _OnNavigationCompleted(Handler, Args) {
        if A_IsSuspended || this.ResetDone
            return
        this._FlushQueue()
        this._FireOnReady()
    }

    ; ── Fires the OnReady callback exactly once (idempotent). Both the page's
    ; "ready" postMessage and NavigationCompleted can trigger this; the
    ; ReadyFired flag guarantees the module's init-data push runs at most once.
    _FireOnReady() {
        if this.ReadyFired
            return
        this.ReadyFired := true
        if this.Opts.Has("OnReady")
            SetTimer(this._DispatchReady.Bind(this, this.Epoch), -1)
    }

    _DispatchReady(CallbackEpoch) {
        if A_IsSuspended || this.ResetDone || (CallbackEpoch != this.Epoch)
            return
        try this.Opts["OnReady"](this)
    }

    ; ── Queue-based eval ─────────────────────────────────────────────────────
    ; Evaluates JS in the page, queuing until the page signals ready.
    Eval(Js) {
        if (this.Ready && this.HasOwnProp("WebView")) {
            SetTimer(this._RunScript.Bind(this, Js), -1)
        } else {
            this.Queue.Push(Js)
            if (this.Queue.Length > 200)
                this.Queue.RemoveAt(1)
        }
    }

    _RunScript(Js) {
        if !this.HasOwnProp("WebView")
            return
        try this.WebView.ExecuteScriptAsync(Js)
    }

    _FlushQueue() {
        this.Ready := true
        for _, Js in this.Queue {
            if this.HasOwnProp("WebView")
                SetTimer(this._RunScript.Bind(this, Js), -1)
        }
        this.Queue := []
    }

    _SafetyFlush() {
        if A_IsSuspended || this.ResetDone
            return
        if (!this.Ready) {
            try LoggerWarn("WebViewHost", "{1}: page did not signal ready within timeout — flushing.", this.AppId)
            this._FlushQueue()
        }
    }

    ; ── Window events ────────────────────────────────────────────────────────
    _OnResize(GuiObj, MinMax, Width, Height) {
        if A_IsSuspended || this.ResetDone || (MinMax == -1)
            return
        if this.HasOwnProp("Controller")
            try this.Controller.Fill()
    }

    _OnClose(*) {
        this.Close()
    }

    ; ── Public: close and destroy the window ─────────────────────────────────
    Close() {
        Saved := (this.Gui != 0) ? this.Gui : 0
        this._Reset(true)
        try {
            if Saved
                Saved.Destroy()
        }
        this.Gui := 0
        ; Remove from singleton registry
        if WebViewHost._Instances.Has(this.AppId)
            WebViewHost._Instances.Delete(this.AppId)
    }

    ; ── Teardown — release subs before Controller.Close, idempotent ──────────
    _Reset(CloseController := true) {
        if this.ResetDone
            return
        this.ResetDone := true
        this.Epoch += 1

        ; Cancel the safety-flush timer so it never fires on a dead window.
        ; Guarded on the BoundFunc existing: passing the old empty-string
        ; "handle" cancelled nothing and kept this host, its Gui and its Opts
        ; graph alive for up to 2.5 s after Close().
        if (this.SafetyTimer)
            try SetTimer(this.SafetyTimer, 0)

        try {
            this.MsgSub := unset
            this.NavSub := unset
            if CloseController && this.HasOwnProp("Controller")
                this.Controller.Close()
        }
        this.Controller := unset
        this.WebView    := unset
        this.Ready      := false
        this.ReadyFired := false
        this.Queue      := []
    }
}


; ── Standalone helpers (used by modules alongside WebViewHost) ───────────────

; Returns a quoted, escaped JS string literal for safe interpolation.
; Centralised here so every module that builds JSON or init-payload JS can reuse
; the same escaping instead of copy-pasting _XxxWeb_JsStr.
WebView_JsStr(s) {
    s := StrReplace(s, "\",  "\\")
    s := StrReplace(s, '"',  '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return '"' . s . '"'
}

; Builds one JSON key/value pair ("key":"value") with the value safely escaped.
WebView_Kv(Key, Value) {
    return '"' . Key . '":' . WebView_JsStr(Value)
}
