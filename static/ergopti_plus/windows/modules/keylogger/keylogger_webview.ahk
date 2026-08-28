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





; ===============================
; ===============================
; ======= 1/ Module state =======
; ===============================
; ===============================

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

		; A cold first paint gets two replacement workers before falling back to
		; any last-known sidecar and admitting live-tick recovery.
		static FIRST_PAINT_MAX_RETRIES := 2
		static FIRST_PAINT_RETRY_MS := 500
		; The historical projection has a separate recovery budget. Once that
		; budget is exhausted, the next ingest tick retries it instead of letting
		; live-only projections permanently replace the missing history.
		static FULL_BUILD_MAX_RETRIES := 2
		static FULL_BUILD_DELAY_MS := 2000
		static FULL_BUILD_RETRY_MS := 1000
		; Test seams; production uses KLWV_PushPrefetch and SetTimer directly.
		static first_paint_push_fn := 0
		static first_paint_timer_fn := 0
		static full_build_timer_fn := 0
		static ingest_drain_timer_fn := 0
}





; =======================================
; =======================================
; ======= 2/ Probe / availability =======
; =======================================
; =======================================

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





; ==============================
; ==============================
; ======= 3/ Asset paths =======
; ==============================
; ==============================

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





; ===========================================
; ===========================================
; ======= 4/ Lifecycle (open / close) =======
; ===========================================
; ===========================================

KLWV_Open(which, metrics_dir) {
		try LoggerDebug("Keylogger", "KLWV_Open: dashboard={1} begin.", which)

		if !KLWV_IsAvailable() {
				try LoggerWarn("Keylogger", "KLWV_Open: WebView2 is unavailable.")
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
		MonitorGetWorkArea(mon, &work_left, &work_top, &work_right, &work_bottom)
		work_w := work_right - work_left
		work_h := work_bottom - work_top
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
		pos_x := work_left + ((work_w - win_w) // 2)
		pos_y := work_top + ((work_h - win_h) // 2)
		WinMove(pos_x, pos_y, , , "ahk_id " . g.Hwnd)
		try LoggerDebug("Keylogger",
				"KLWV_Open: centered dashboard work={1}x{2} window={3}x{4}.",
				work_w, work_h, win_w, win_h)

		; Spin up WebView2 inside the Gui's HWND. dataDir is unique per
		; launch so cached state from a previous open never bleeds in.
		udir := A_Temp . "\ergopti_webview2_" . A_TickCount
		WebView_SweepStaleProfiles("ergopti_webview2_")
		if !_KLWV_CreateProfileDir(udir) {
				try g.Destroy()
				return false
		}
		loader := _VendorDir . "\64bit\WebView2Loader.dll"

		; thqby's wrapper resolves WebView2 asynchronously through a
		; Promise; we await it inline so the rest of the wiring runs
		; synchronously against a ready controller.
		try LoggerDebug("Keylogger", "KLWV_Open: creating WebView2 controller.")
		try {
				controller := WebView2.create(g.Hwnd, , 0, udir, "", 0, loader)
		} catch as err {
				try LoggerError("Keylogger",
						"KLWV_Open: WebView2 controller create failed ('{1}') at {2}:{3} — dashboard cannot open.",
						err.Message, err.File, err.Line)
				try g.Destroy()
				return false
		}
		try LoggerDebug("Keylogger", "KLWV_Open: WebView2 controller created.")
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
		try LoggerDebug("Keylogger", "KLWV_Open: i18n seed prepared for locale={1}.", locale_code)

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
		try LoggerDebug("Keylogger", "KLWV_Open: navigating dashboard={1}.", which)
		try {
				webview.Navigate(asset)
		} catch as err {
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
				"msg_sub", msg_sub,
				"pending_ingest_mode", "",
				"ingest_drain_armed", false
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





; =========================
; =========================
; ======= 5/ Sizing =======
; =========================
; =========================

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
_KLWV_LogBridgeReceipt(which, msg, LogFn := LoggerTrace) {
		safe_which := (which = "typing" or which = "apps") ? which : "unknown"
		return _KLWV_TryDiagnostic(
				"KLWV_OnWebMessage: dashboard={1}, payload_length={2}.",
				LogFn, safe_which, StrLen(msg))
}

KLWV_OnWebMessage(which, Epoch, sender, args) {
	if !KLWV_IsCurrent(which, Epoch)
		return
	entry := KLWV.windows[which]
	if !entry.Has("webview") || !(sender == entry["webview"])
		return
		msg := ""
		try msg := args.TryGetWebMessageAsString()
		_KLWV_LogBridgeReceipt(which, msg)
		if (msg = "")
				return
		; Tiny ad-hoc parser for the action verb — the only field we need
		; right now is "action". Full payload parsing is deferred until we
		; add filter pushdown commands.
		action := ""
		if RegExMatch(msg, '"action"\s*:\s*"([^"]+)"', &m)
				action := m[1]
		; WebMessageReceived bypasses native Suspend. Most dashboard actions become
		; inert while paused. A range request is the exception only long enough to
		; capture its request id and queue a canceled terminal for resume; it must
		; never start the detached projection while suspended.
		if A_IsSuspended && (action != "range")
				return
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
				KLWV_OnFullBuildTerminal.Bind(which, Epoch, 0))
		case "range":
			; A selected-range projection can be large enough to stall the hook.
			; Build it in a detached worker; the completion asks WebView to fetch
			; the staged JSON directly, so AHK never decodes the large payload.
			normalized := KLWV_NormalizeRangeRequest(msg)
			request_id := normalized["request_id"]
			query := normalized["query"]
			if !request_id
				return
			if A_IsSuspended {
				KLWV_QueueRangeTerminal(which, Epoch, request_id, "canceled")
				return
			}
			if !(query is Map) {
				KLWV_SendRangeTerminal(which, Epoch, request_id, "failed")
				return
			}
			KLPF_RequestRange(which, KLWV.metrics_dir, query, Epoch,
				KLWV_OnRangeBuildTerminal.Bind(which, Epoch, request_id))
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
						if KLWV_IsCurrent(which, Epoch)
								KLWV.windows[which]["full_build_done"] := false
						try LoggerDebug("Keylogger", "KLWV_OnWebMessage: dashboard caches purged.")
						; Projection runs in a detached worker; a late pre-clear result is
						; fenced by the generation held by KLPF_RequestBuild.
						KLPF_RequestBuild(which, KLWV.metrics_dir, "full", Epoch,
								KLWV_OnFullBuildTerminal.Bind(which, Epoch, 0))
		}
}

; Parse and validate the selected-range request emitted by metrics_typing/data.js.
; Date strings are deliberately constrained before reaching KLR_DateFilter, and
; only non-empty string app names make it into the SQLite IN clause.
KLWV_NormalizeRangeRequest(msg) {
		result := Map("request_id", 0, "query", 0)
		try payload := KL_JsonDecode(msg)
		catch {
				try LoggerWarn("Keylogger", "Range request rejected — malformed JSON payload.")
				return result
		}
		if !(payload is Map)
				return result
		if !payload.Has("request_id") || (Type(payload["request_id"]) != "Integer")
						|| (payload["request_id"] <= 0) {
				try LoggerWarn("Keylogger", "Range request rejected — missing or invalid request id.")
				return result
		}
		result["request_id"] := payload["request_id"]

		start_date := payload.Has("start_date") ? String(payload["start_date"]) : ""
		end_date := payload.Has("end_date") ? String(payload["end_date"]) : ""
		; Reject loudly: a bare 0 makes "malformed request" indistinguishable from
		; "no request", which is why the broken date pattern above silently killed
		; every range query with nothing in the log to point at it.
		if !KLWV_IsIsoDate(start_date) || !KLWV_IsIsoDate(end_date) {
				try LoggerWarn("Keylogger", "Range request rejected — non-ISO date(s) '{1}'…'{2}'.", start_date, end_date)
				return result
		}
		if (start_date != "" && end_date != "" && StrCompare(start_date, end_date) > 0) {
				try LoggerWarn("Keylogger", "Range request rejected — start '{1}' is after end '{2}'.", start_date, end_date)
				return result
		}

		apps := []
		seen := Map()
		if payload.Has("apps") && payload["apps"] is Array {
				for _, app_name in payload["apps"] {
						if (Type(app_name) != "String" || app_name = "" || seen.Has(app_name))
								continue
						seen[app_name] := true
						apps.Push(app_name)
				}
		}
		result["query"] := Map("start_date", start_date, "end_date", end_date, "apps", apps)
		return result
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

KLWV_OnRangeBuildTerminal(which, Epoch, request_id, status, stage := "") {
		if !KLWV_IsCurrent(which, Epoch) {
				FSDelete(stage)
				return false
		}
		if A_IsSuspended {
				FSDelete(stage)
				return KLWV_QueueRangeTerminal(which, Epoch, request_id, "canceled")
		}
		if (status != "ok") {
				FSDelete(stage)
				return KLWV_SendRangeTerminal(which, Epoch, request_id, status)
		}
		if (stage = "") || !FSExists(stage)
				return KLWV_SendRangeTerminal(which, Epoch, request_id, "failed")
		; ``ExecuteScriptAsync`` is fire-and-forget: WebView performs the file read,
		; JSON parse and range render in its own process, not on the keyboard thread.
		url := "file:///" . StrReplace(stage, "\", "/")
		js := "fetch(" . KL_JsonEncode(url) . ").then(r=>r.json()).then(p=>window.receive_range_data(p," . request_id
				. ")).catch(()=>window.complete_range_request(" . request_id . ",'failed'));"
		try KLWV.windows[which]["webview"].ExecuteScriptAsync(js)
		catch as err {
				FSDelete(stage)
				try LoggerError("Keylogger", "KLWV_OnRangeBuildTerminal: range delivery failed for '{1}': {2}", which, err.Message)
				return KLWV_SendRangeTerminal(which, Epoch, request_id, "failed")
		}
		; Give the renderer ample time to open the file, then clean the private
		; staged result.  A late timer only removes this generation's unique path.
		SetTimer(KLWV_DeleteRangeStage.Bind(stage), -60000)
		return true
}

KLWV_QueueRangeTerminal(which, Epoch, request_id, status) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		if entry.Has("pending_range_terminal")
				&& entry["pending_range_terminal"]["request_id"] > request_id
				return false
		entry["pending_range_terminal"] := Map(
				"epoch", Epoch, "request_id", request_id, "status", status)
		return true
}

KLWV_SendRangeTerminal(which, Epoch, request_id, status) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		if A_IsSuspended
				return KLWV_QueueRangeTerminal(which, Epoch, request_id, status)

		entry := KLWV.windows[which]
		; This is a WebView bridge envelope, not a keylogger event. Assign its
		; discriminator explicitly so the event-ingest inventory does not mistake
		; the Map for a row destined for today.log/data.sql.
		envelope := Map()
		envelope["type"] := "range_terminal"
		envelope["request_id"] := request_id
		envelope["status"] := status
		msg := KL_JsonEncode(envelope)
		try entry["webview"].PostWebMessageAsString(msg)
		catch as err {
				try LoggerError("Keylogger", "KLWV_SendRangeTerminal: terminal delivery failed for '{1}': {2}", which, err.Message)
				return KLWV_QueueRangeTerminal(which, Epoch, request_id, status)
		}
		if entry.Has("pending_range_terminal")
				&& entry["pending_range_terminal"]["request_id"] = request_id
				entry.Delete("pending_range_terminal")
		return true
}

KLWV_FlushPendingRangeTerminals() {
		if A_IsSuspended
				return
		for which, entry in KLWV.windows.Clone() {
				if !entry.Has("pending_range_terminal")
						continue
				pending := entry["pending_range_terminal"]
				KLWV_SendRangeTerminal(which, pending["epoch"], pending["request_id"], pending["status"])
		}
}

KLWV_DeleteRangeStage(stage) {
		try FileDelete(stage)
}





; ==================================
; ==================================
; ======= 7/ Push (AHK → JS) =======
; ==================================
; ==================================

; Push the contents of the freshly-built prefetch.json to the page as a
; structured WebView2 message. The page bootstrap dispatches it to
; process_manifest just like the initial fetch.
_KLWV_TryDiagnostic(Message, LogFn := LoggerDebug, Args*) {
		try {
				LogFn.Call("Keylogger", Message, Args*)
				return true
		} catch as err {
				try LoggerError("Keylogger", "WebView diagnostic emission failed: {1}", err.Message)
				return false
		}
}

_KLWV_CreateProfileDir(Path, CreateFn := DirCreate, ErrorFn := LoggerError) {
		try {
				CreateFn.Call(Path)
				return true
		} catch as err {
				try ErrorFn.Call("Keylogger",
						"KLWV_Open: cannot create WebView profile directory '{1}': {2}",
						Path, err.Message)
				return false
		}
}

KLWV_PushPrefetch(which, DiagnosticFn := LoggerDebug) {
		if !KLWV.windows.Has(which) {
				_KLWV_TryDiagnostic("KLWV_PushPrefetch: no live dashboard.", DiagnosticFn)
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
						_KLWV_TryDiagnostic(
								"KLWV_PushPrefetch: prefetch is unavailable for dashboard={1}.",
								DiagnosticFn, which)
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
		} catch as err {
				try LoggerError("Keylogger", "KLWV_PushPrefetch: dashboard delivery failed for '{1}': {2}", which, err.Message)
				return false
		}
		_KLWV_TryDiagnostic(
				"KLWV_PushPrefetch: delivered dashboard={1}, payload_length={2}.",
				DiagnosticFn, which, StrLen(msg))
		return true
}

; Inject the active locale strings directly into the WebView via ExecuteScriptAsync.
; fetch() is blocked by CORS on file:// origins in WebView2, so i18n.js cannot
; load locale JSON on its own. We read the file on the AHK side and push the
; pre-parsed strings into window._i18n_strings, then call i18n_apply() to
; populate all data-i18n attributes immediately.
KLWV_InjectI18n(which) {
		global _SharedDir
		try LoggerDebug("Keylogger", "KLWV_InjectI18n: dashboard={1}, has_window={2}.",
				which, KLWV.windows.Has(which) ? 1 : 0)
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
		if !KLWV.windows.Has(which)
				return
		try {
				KLWV.windows[which]["webview"].ExecuteScriptAsync(js)
				try LoggerDebug("Keylogger",
						"KLWV_RunScript: injected locale={1}, script_length={2}.",
						locale_code, StrLen(js))
		} catch as err {
				try LoggerError("Keylogger", "KLWV_RunScript: locale injection failed: {1}", err.Message)
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

KLWV_DelayedFirstPush(which, Epoch, attempt := 0) {
		try LoggerDebug("Keylogger", "KLWV_DelayedFirstPush: dashboard={1}, has_window={2}.",
				which, KLWV.windows.Has(which) ? 1 : 0)
		if !KLWV_IsCurrent(which, Epoch)
				return
		entry := KLWV.windows[which]
		; A canceled predecessor may already have armed this callback before its
		; replacement completed. First-paint ownership is terminal: once the
		; replacement painted, that older retry must not push or schedule phase 2.
		if entry.Has("first_paint_done") && entry["first_paint_done"]
				return false
		if A_IsSuspended {
				KLWV_QueueFirstPaintRetry(which, Epoch, attempt, false)
				return
		}
		; A superseding refresh owns first-paint recovery through its terminal.
		; Never cancel that live replacement merely because this retry timer fired.
		if KLPFWorker.jobs.Has(which)
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
						KLWV_OnFirstBuildTerminal.Bind(which, Epoch, attempt))
				return
		}
		FirstPaintOk := KLWV_FirstPaintPush(which)
		if !FirstPaintOk {
				KLWV_ScheduleFirstPaintRetry(which, Epoch, attempt, "push failed")
				return
		}
		; Mark first paint done so live ticks can fan out from now on.
		if FirstPaintOk && KLWV_IsCurrent(which, Epoch)
				KLWV.windows[which]["first_paint_done"] := true
		; Phase 2 — full historical build in a deferred timer (2 s later).
		; Provides the historical n-gram tables without blocking the first paint.
		if FirstPaintOk
				KLWV_ArmFullBuildTimer(KLWV_DelayedFullBuild.Bind(which, Epoch, 0),
						-KLWV.FULL_BUILD_DELAY_MS)
}

KLWV_DelayedFullBuild(which, Epoch, attempt := 0) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		if entry.Has("full_build_done") && entry["full_build_done"]
				return false
		if A_IsSuspended
				return KLWV_QueueFullBuildRetry(which, Epoch, attempt)
		; A newer projection owns recovery through its terminal. In particular,
		; never let an older retry evict the replacement that canceled it.
		if KLPFWorker.jobs.Has(which)
				return false
		if !KLWV.metrics_dir
				return KLWV_ScheduleFullBuildRetry(which, Epoch, attempt, "missing metrics dir")
		if entry.Has("full_build_retry_exhausted")
				entry.Delete("full_build_retry_exhausted")
		return KLPF_RequestBuild(which, KLWV.metrics_dir, "full", Epoch,
				KLWV_OnFullBuildTerminal.Bind(which, Epoch, attempt))
}

KLWV_OnFirstBuildTerminal(which, Epoch, attempt, status, *) {
		try {
				if !KLWV_IsCurrent(which, Epoch)
						return false
				if A_IsSuspended
						return KLWV_ScheduleFirstPaintRetry(which, Epoch, attempt, status)
				if (status != "ok")
						return KLWV_ScheduleFirstPaintRetry(which, Epoch, attempt, status)
				if !KLWV_FirstPaintPush(which)
						return KLWV_ScheduleFirstPaintRetry(which, Epoch, attempt, "push failed")
				if KLWV_IsCurrent(which, Epoch)
						KLWV.windows[which]["first_paint_done"] := true
				KLWV_ArmFullBuildTimer(KLWV_DelayedFullBuild.Bind(which, Epoch, 0),
						-KLWV.FULL_BUILD_DELAY_MS)
				return true
		} finally {
				KLWV_ScheduleIngestDrain(which, Epoch)
		}
}

KLWV_OnFullBuildTerminal(which, Epoch, attempt, status, *) {
		try {
				if !KLWV_IsCurrent(which, Epoch)
						return false
				if A_IsSuspended || (status != "ok")
						return KLWV_ScheduleFullBuildRetry(which, Epoch, attempt, status)
				if !KLWV_FirstPaintPush(which)
						return KLWV_ScheduleFullBuildRetry(which, Epoch, attempt, "push failed")
				entry := KLWV.windows[which]
				entry["first_paint_done"] := true
				entry["full_build_done"] := true
				if entry.Has("pending_full_build_retry")
						entry.Delete("pending_full_build_retry")
				if entry.Has("full_build_retry_exhausted")
						entry.Delete("full_build_retry_exhausted")
				return true
		} finally {
				KLWV_ScheduleIngestDrain(which, Epoch)
		}
}

KLWV_OnBuildTerminal(which, Epoch, status, *) {
		try {
				if !KLWV_IsCurrent(which, Epoch)
						return false
				entry := KLWV.windows[which]
				first_paint_pending := !entry.Has("first_paint_done") || !entry["first_paint_done"]
				if A_IsSuspended {
						if first_paint_pending
								KLWV_QueueFirstPaintRetry(which, Epoch, 0, false)
						return false
				}
				if (status != "ok") {
						if first_paint_pending
								return KLWV_ScheduleFirstPaintRetry(which, Epoch, 0, status)
						return false
				}
				if !KLWV_FirstPaintPush(which) {
						if first_paint_pending
								return KLWV_ScheduleFirstPaintRetry(which, Epoch, 0, "push failed")
						return false
				}
				if first_paint_pending && KLWV_IsCurrent(which, Epoch)
						KLWV.windows[which]["first_paint_done"] := true
				if first_paint_pending
						KLWV_ArmFullBuildTimer(KLWV_DelayedFullBuild.Bind(which, Epoch, 0),
								-KLWV.FULL_BUILD_DELAY_MS)
				return true
		} finally {
				KLWV_ScheduleIngestDrain(which, Epoch)
		}
}

KLWV_QueueFirstPaintRetry(which, Epoch, attempt, fallback) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		if entry.Has("pending_first_paint_retry") {
				pending := entry["pending_first_paint_retry"]
				if pending["fallback"] || (!fallback && pending["attempt"] > attempt)
						return false
		}
		entry["pending_first_paint_retry"] := Map(
				"epoch", Epoch, "attempt", attempt, "fallback", fallback)
		return true
}

KLWV_FirstPaintPush(which) {
		if IsObject(KLWV.first_paint_push_fn)
				return KLWV.first_paint_push_fn.Call(which)
		return KLWV_PushPrefetch(which)
}

KLWV_ArmFirstPaintTimer(callback, period) {
		if IsObject(KLWV.first_paint_timer_fn)
				return KLWV.first_paint_timer_fn.Call(callback, period)
		; Recovery timers are one-shot by contract, regardless of caller sign.
		SetTimer(callback, -Abs(period))
		return true
}

KLWV_ArmFullBuildTimer(callback, period) {
		if IsObject(KLWV.full_build_timer_fn)
				return KLWV.full_build_timer_fn.Call(callback, period)
		; Recovery timers are one-shot by contract, regardless of caller sign.
		SetTimer(callback, -Abs(period))
		return true
}

KLWV_IngestModePriority(mode) {
		switch mode {
				case "manifest":
						return 1
				case "live":
						return 2
				case "full":
						return 3
		}
		return 0
}

; Collapse an arbitrary ingest cadence into one pending projection per window.
; A richer pending mode wins over a cheaper one, so a later manifest tick cannot
; downgrade live/full work already promised by an earlier ingest.
KLWV_MarkIngestDirty(which, Epoch, mode := "live") {
		if !KLWV_IsCurrent(which, Epoch) || !KLWV_IngestModePriority(mode)
				return false
		entry := KLWV.windows[which]
		pending_mode := entry.Get("pending_ingest_mode", "")
		if KLWV_IngestModePriority(mode) >= KLWV_IngestModePriority(pending_mode)
				entry["pending_ingest_mode"] := mode
		return true
}

KLWV_ArmIngestDrainTimer(callback, period) {
		if IsObject(KLWV.ingest_drain_timer_fn)
				return KLWV.ingest_drain_timer_fn.Call(callback, period)
		SetTimer(callback, -Abs(period))
		return true
}

; Completion callbacks run while KLPF still retains their terminal owner. Defer
; the drain one turn so job retirement happens first, then start at most one
; coalesced successor. The armed flag makes duplicate terminals/ticks harmless.
KLWV_ScheduleIngestDrain(which, Epoch) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		if entry.Get("pending_ingest_mode", "") = ""
				return false
		if entry.Get("ingest_drain_armed", false)
				return true
		entry["ingest_drain_armed"] := true
		try return KLWV_ArmIngestDrainTimer(
				KLWV_DrainPendingIngest.Bind(which, Epoch), -1)
		catch as err {
				entry["ingest_drain_armed"] := false
				try LoggerError("Keylogger", "Could not arm coalesced metrics drain for '{1}': {2}", which, err.Message)
				return false
		}
}

KLWV_DrainPendingIngest(which, Epoch) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		entry["ingest_drain_armed"] := false
		if A_IsSuspended
				return false
		pending_mode := entry.Get("pending_ingest_mode", "")
		if pending_mode = ""
				return false
		if !entry.Get("first_paint_done", false) || KLPFWorker.jobs.Has(which)
				return false

		; Until the historical seed lands, every dirty signal is satisfied by one
		; full build. Only after that owner commits may manifest/live work run.
		mode := entry.Get("full_build_done", false) ? pending_mode : "full"
		entry["pending_ingest_mode"] := ""
		terminal := (mode = "full")
				? KLWV_OnFullBuildTerminal.Bind(which, Epoch, 0)
				: KLWV_OnBuildTerminal.Bind(which, Epoch)
		started := KLPF_RequestBuild(which, KLWV.metrics_dir, mode, Epoch,
				terminal, false)
		if !started
				KLWV_MarkIngestDirty(which, Epoch, pending_mode)
		return started
}

KLWV_ScheduleFirstPaintRetry(which, Epoch, attempt, reason) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		if entry.Has("first_paint_done") && entry["first_paint_done"]
				return false
		if (attempt >= KLWV.FIRST_PAINT_MAX_RETRIES) {
				if A_IsSuspended
						return KLWV_QueueFirstPaintRetry(which, Epoch, attempt, true)
				fallback_ok := KLWV_FirstPaintPush(which)
				; Even without an old sidecar, admitting live ticks is the bounded
				; recovery path: their next terminal can populate the blank window.
				if KLWV_IsCurrent(which, Epoch)
						KLWV.windows[which]["first_paint_done"] := true
				if fallback_ok
						KLWV_ArmFullBuildTimer(KLWV_DelayedFullBuild.Bind(which, Epoch, 0),
								-KLWV.FULL_BUILD_DELAY_MS)
				else
						try LoggerError("Keylogger", "First metrics paint exhausted retries for '{1}' ({2}); waiting for live recovery.", which, reason)
				return fallback_ok
		}
		if A_IsSuspended
				return KLWV_QueueFirstPaintRetry(which, Epoch, attempt + 1, false)
		try LoggerWarn("Keylogger", "First metrics paint retry {1}/{2} for '{3}' after {4}.",
				attempt + 1, KLWV.FIRST_PAINT_MAX_RETRIES, which, reason)
		KLWV_ArmFirstPaintTimer(KLWV_DelayedFirstPush.Bind(which, Epoch, attempt + 1),
				-KLWV.FIRST_PAINT_RETRY_MS)
		return true
}

KLWV_QueueFullBuildRetry(which, Epoch, attempt) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		if entry.Has("full_build_done") && entry["full_build_done"]
				return false
		if entry.Has("pending_full_build_retry") {
				pending := entry["pending_full_build_retry"]
				if pending["attempt"] >= attempt
						return false
		}
		entry["pending_full_build_retry"] := Map("epoch", Epoch, "attempt", attempt)
		return true
}

KLWV_ScheduleFullBuildRetry(which, Epoch, attempt, reason) {
		if !KLWV_IsCurrent(which, Epoch)
				return false
		entry := KLWV.windows[which]
		if entry.Has("full_build_done") && entry["full_build_done"]
				return false
		if (attempt >= KLWV.FULL_BUILD_MAX_RETRIES) {
				; Keep the already-rendered manifest/live payload intact. The next
				; ingest tick sees full_build_done=false and becomes the low-frequency
				; fallback, forcing another non-blocking full worker.
				entry["full_build_retry_exhausted"] := true
				try LoggerError("Keylogger", "Full metrics build exhausted retries for '{1}' ({2}); next ingest will retry.", which, reason)
				return false
		}
		next_attempt := attempt + 1
		if A_IsSuspended
				return KLWV_QueueFullBuildRetry(which, Epoch, next_attempt)
		try LoggerWarn("Keylogger", "Full metrics build retry {1}/{2} for '{3}' after {4}.",
				next_attempt, KLWV.FULL_BUILD_MAX_RETRIES, which, reason)
		KLWV_ArmFullBuildTimer(KLWV_DelayedFullBuild.Bind(which, Epoch, next_attempt),
				-KLWV.FULL_BUILD_RETRY_MS)
		return true
}

KLWV_FlushPendingFirstPaintRetries() {
		if A_IsSuspended
				return
		for which, entry in KLWV.windows.Clone() {
				if !entry.Has("pending_first_paint_retry")
						continue
				pending := entry["pending_first_paint_retry"]
				entry.Delete("pending_first_paint_retry")
				if pending["fallback"]
						KLWV_ScheduleFirstPaintRetry(which, pending["epoch"], pending["attempt"], "suspend")
				else
						KLWV_ArmFirstPaintTimer(
								KLWV_DelayedFirstPush.Bind(which, pending["epoch"], pending["attempt"]), -1)
		}
}

KLWV_FlushPendingFullBuildRetries() {
		if A_IsSuspended
				return
		for which, entry in KLWV.windows.Clone() {
				if !entry.Has("pending_full_build_retry")
						continue
				pending := entry["pending_full_build_retry"]
				entry.Delete("pending_full_build_retry")
				KLWV_ArmFullBuildTimer(
						KLWV_DelayedFullBuild.Bind(which, pending["epoch"], pending["attempt"]), -1)
		}
}

KLWV_OnSuspendResume() {
		KLWV_FlushPendingRangeTerminals()
		KLWV_FlushPendingFirstPaintRetries()
		KLWV_FlushPendingFullBuildRetries()
		for which, entry in KLWV.windows.Clone() {
				if !(entry is Map) || (entry.Get("pending_ingest_mode", "") = "")
						continue
				KLWV_ScheduleIngestDrain(which, entry.Get("epoch", 0))
		}
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
		if !KLWV.metrics_dir || !KLWV_IngestModePriority(mode) {
				return
		}
		n := 0
		for which, entry in KLWV.windows {
				; Skip live ticks until the first visible paint has landed.
				if !(entry is Map && entry.Has("first_paint_done") && entry["first_paint_done"])
						continue
				Epoch := entry.Get("epoch", 0)
				if !KLWV_MarkIngestDirty(which, Epoch, mode)
						continue
				n += 1
				; The active job is never replaced by ingest. Its terminal schedules one
				; deferred drain; an idle window can consume the dirty bit immediately.
				if !KLPFWorker.jobs.Has(which)
						KLWV_DrainPendingIngest(which, Epoch)
		}
		if n
				try LoggerDebug("Keylogger",
						"KLWV_NotifyIngest: mode={1}, coalesced_windows={2}.", mode, n)
}
