; modules/keylogger/keylogger_ui.ahk

; ==============================================================================
; MODULE: Keylogger UI Launcher
; DESCRIPTION:
; Opens / closes / toggles the typing-metrics and apps-time dashboards on
; Windows. Mirrors the role of `ui/metrics_typing` and `ui/metrics_apps` in
; Hammerspoon: a single point of entry the menu and the shortcut bindings
; both call through.
;
; FEATURES & RATIONALE:
; 1. Exact process ownership: each Edge window's process tree is retained so a
;    second call to the same Toggle* function can close the window cleanly
;    without reopening a Windows PID that may already belong to another app.
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
; bound to user-configurable hotkeys via infra/metrics_shortcuts.ahk and
; wired into the tray menu by ErgoptiPlus.ahk.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===============================
; ===============================
; ======= 1/ Module state =======
; ===============================
; ===============================

class KLUI {
		; ShellRunner process-tree owner of each Edge fallback (0 = closed).
		static typing_owner := 0
		static apps_owner := 0

		; Resolved file URLs to the shared HTML assets. Set lazily on first call.
		static typing_url := ""
		static apps_url := ""

		; Edge fallback launches only after its detached projection worker has
		; atomically published the sidecar.  This prevents a first open from
		; silently rendering an empty dashboard while the data is still building.
		static pending := Map()
}





; ========================================
; ========================================
; ======= 2/ Asset path resolution =======
; ========================================
; ========================================

KLUI_ResolveAssetUrl(which) {
		global _SharedDir
		; The shared UI assets live under static/ergopti_plus/_shared/. _SharedDir
		; (compiled), so the same offset works in both modes.
		base := _SharedDir . "\ui\" . which . "\index.html"
		; Resolve to absolute, normalised path.
		loop files, base
				base := A_LoopFileFullPath
		; file:// URL: replace backslashes with forward slashes.
		url := "file:///" . StrReplace(base, "\", "/")
		; Embed the prefetch file path in the hash so the page bootstrap can
		; fetch from %TEMP% instead of the repo directory. Hash fragments are
		; safe on file:// URLs in Chromium (no request, no cache-buster issue).
		prefetch_path := StrReplace(KLPF_PrefetchPath(which), "\", "/")
		url .= "#prefetch=file:///" . prefetch_path
		return url
}

KLUI_EnsureUrls() {
		if (KLUI.typing_url = "")
				KLUI.typing_url := KLUI_ResolveAssetUrl("metrics_typing")
		if (KLUI.apps_url = "")
				KLUI.apps_url := KLUI_ResolveAssetUrl("metrics_apps")
}





; ========================================
; ========================================
; ======= 3/ Launch / kill helpers =======
; ========================================
; ========================================

KLUI_FindMsedge() {
		; Edge ships in two canonical locations on Windows 10/11. Probe both;
		; fall back to Windows executable lookup through ShellRunner.
		candidates := [
				EnvGet("ProgramFiles") . "\Microsoft\Edge\Application\msedge.exe",
				EnvGet("ProgramFiles(x86)") . "\Microsoft\Edge\Application\msedge.exe",
				EnvGet("LOCALAPPDATA") . "\Microsoft\Edge\Application\msedge.exe"
		]
		for _, path in candidates {
				if (path != "" && FileExist(path))
						return path
		}
		return "msedge.exe"
}

KLUI_LaunchWindow(url, title) {
		; Flush today.log → data.sql so the page sees fresh data.
		try KL_IngestOnce()

		; Build the prefetch sidecar before opening the window. The page
		; reads ./prefetch.json on load (B niveau 1 contract — no JS bridge,
		; full client-side filtering on the projected dataset). The which
		; key is recovered from the URL by matching the parent folder name.
		which := ""
		if InStr(url, "metrics_typing")
				which := "typing"
		else if InStr(url, "metrics_apps")
				which := "apps"
		if (which = "")
				return 0
		global _ConfigDir
		KLUI.pending[which] := true
		if !KLPF_RequestBuild(which, _ConfigDir . "metrics", "full", 0,
						KLUI_OnPrefetchTerminal.Bind(which, url, title)) {
				if KLUI.pending.Has(which)
						KLUI.pending.Delete(which)
				return 0
		}
		return 0
}

KLUI_OnPrefetchTerminal(which, url, title, status, *) {
		if !KLUI.pending.Has(which)
				return
		KLUI.pending.Delete(which)
		if (status != "ok") {
				try LoggerError("Keylogger", "Edge metrics prefetch failed for '{1}' (status={2}); dashboard was not launched.", which, status)
				return
		}
		KLUI_LaunchEdge(which, url, title)
}

_KLUI_GetEdgeOwner(which) {
		return which = "typing" ? KLUI.typing_owner : KLUI.apps_owner
}

_KLUI_SetEdgeOwner(which, Owner) {
		if which = "typing"
				KLUI.typing_owner := Owner
		else
				KLUI.apps_owner := Owner
}

_KLUI_RetireEdgeOwner(which, ExpectedOwner) {
		PreviousCritical := Critical("On")
		try {
				if _KLUI_GetEdgeOwner(which) != ExpectedOwner
						return false
				_KLUI_SetEdgeOwner(which, 0)
				return true
		} finally {
				Critical(PreviousCritical)
		}
}

_KLUI_OnEdgeTerminal(which, Owner, ExitCode, Stdout, Stderr) {
		if !_KLUI_RetireEdgeOwner(which, Owner)
				return
		try LoggerInfo("Keylogger", "Edge metrics process tree for '{1}' exited with code {2}.", which, ExitCode)
}

_KLUI_CancelEdgeOwner(which, ExpectedOwner := 0) {
		PreviousCritical := Critical("On")
		try {
				Owner := _KLUI_GetEdgeOwner(which)
				if !IsObject(Owner)
						return true
				if IsObject(ExpectedOwner) && Owner != ExpectedOwner
						return false
				if Owner.Get("state", "") = "cancelling"
						return false
				Owner["state"] := "cancelling"
		} finally {
				Critical(PreviousCritical)
		}

		Terminated := false
		try Terminated := Owner["task"].terminate() == true
		catch as Err
				try LoggerError("Keylogger", "Exact Edge metrics termination for '{1}' threw: {2}.", which, Err.Message)

		PreviousCritical := Critical("On")
		try {
				if _KLUI_GetEdgeOwner(which) == Owner {
						if Terminated
								_KLUI_SetEdgeOwner(which, 0)
						else
								Owner["state"] := "running"
				}
		} finally {
				Critical(PreviousCritical)
		}
		return Terminated
}

KLUI_LaunchEdge(which, url, title) {

		edge := KLUI_FindMsedge()
		; --app=URL launches a chromeless window pinned to URL. --user-data-dir
		; isolates from the user's main Edge session so closing this window
		; does not nuke their tabs. --window-size starts large but resizable.
		; Use a per-launch user-data-dir suffixed with the current tick count.
		; Edge keeps every previous launch's HTML/JS in a Code Cache that even
		; a recursive DirDelete cannot always wipe (the dir stays locked by a
		; lingering helper process for a few seconds after the window closes).
		; Spinning up a fresh dir guarantees the freshest page every time and
		; the orphan ones are cleaned up below on a best-effort basis.
		udir := A_Temp . "\ergopti_metrics_edge_" . A_TickCount
		WebView_SweepStaleProfiles("ergopti_metrics_edge_")
		DirCreate(udir)
		; --allow-file-access-from-files: lift the same-origin restriction that
		; treats every file:// URL as a unique origin. Without it, the page
		; bootstrap's fetch('./prefetch.json') is blocked by Chromium's
		; default policy and the dashboard stays empty. Safe here because
		; --user-data-dir isolates this profile from the user's main Edge
		; session, so the relaxed flag never bleeds into general browsing.
		; --disable-features=msEdgeTrackingPrevention silences the noisy
		; "Tracking Prevention blocked storage" console spam — the dashboard
		; uses no third-party storage anyway.
		args := [
				"--app=" . url,
				"--user-data-dir=" . udir,
				"--window-size=1400,900",
				"--allow-file-access-from-files",
				; Suppress Edge sync entirely so the isolated profile does NOT
				; pull in the user's account extensions, themes, bookmarks, or
				; "installed by sync" notification tabs. The dashboard is a
				; chromeless single-page view; nothing it does benefits from
				; sync, and the auto-installed extensions polluted the launch
				; with a second window full of unwanted tabs.
				"--disable-sync",
				"--disable-extensions",
				"--no-first-run",
				"--no-default-browser-check",
				"--disable-default-apps",
				"--disable-features=msEdgeTrackingPrevention,EdgeSync,MicrosoftEdgeAccountSignedIn"
		]
		try {
				Owner := Map("task", 0, "state", "starting")
				Task := ShellRunner_SpawnTreeOwned(edge, args,
						_KLUI_OnEdgeTerminal.Bind(which, Owner), , , 0, false)
				Owner["task"] := Task
				PreviousCritical := Critical("On")
				try {
						if IsObject(_KLUI_GetEdgeOwner(which))
								throw Error("an Edge metrics owner is already active")
						_KLUI_SetEdgeOwner(which, Owner)
				} finally {
						Critical(PreviousCritical)
				}
				if !Task.start() {
						_KLUI_RetireEdgeOwner(which, Owner)
						throw Error("exact Edge metrics process tree did not start")
				}
				PreviousCritical := Critical("On")
				try {
						if _KLUI_GetEdgeOwner(which) == Owner
								Owner["state"] := "running"
				} finally {
						Critical(PreviousCritical)
				}
		}
		catch as err {
				if IsSet(Owner) && IsObject(Owner)
						_KLUI_CancelEdgeOwner(which, Owner)
				MsgBox(Format(t("keylogger_ui.launch_error"), err.Message),
						t("common.error_title"), "Iconx")
				return false
		}
		return true
}





; ====================================
; ====================================
; ======= 4/ Public toggle API =======
; ====================================
; ====================================

; Bail-out helper. The dashboards are tightly coupled to the keylogger
; storage layer, so opening one while the feature is OFF would only show
; an empty page (and silently signal the user that the keylogger is
; capturing). Better: refuse with a friendly hint pointing to the toggle.
KLUI_RequireEnabled() {
		if MetricsShortcuts.enabled
				return true
		MsgBox(
				t("keylogger_ui.metrics_disabled") . "`n`n" . t("keylogger_ui.metrics_disabled_body"),
				t("keylogger_ui.metrics_title"), "Iconi"
		)
		return false
}

KLUI_ToggleTyping(*) {
		if !KLUI_RequireEnabled()
				return
		KLUI_ToggleDashboard("typing", t("keylogger_ui.typing_metrics"))
}

KLUI_ToggleApps(*) {
		if !KLUI_RequireEnabled()
				return
		KLUI_ToggleDashboard("apps", t("keylogger_ui.app_metrics"))
}

; Shared toggle implementation. Tries WebView2 first (B niveau 2 — live
; push channel + chrome-less Gui). Falls back to Edge --app= when
; WebView2 Runtime / vendored deps are unavailable. Reads / writes the
; KLUI class properties directly because AHK v2's `&` ref syntax does
; not work on object properties.
KLUI_ToggleDashboard(which, title) {
		KLUI_EnsureUrls()
		global _ConfigDir
		metrics_dir := _ConfigDir . "metrics"

		if KLWV_IsAvailable() {
				if KLWV.windows.Has(which) {
						KLWV_Close(which)
						return
				}
				; Availability only proves that the runtime/loader can be discovered.
				; Required setup (controller, asset mapping, bridge, navigation) can still
				; fail. Do not strand the user behind a blank unpublished WebView: fall
				; through exactly once to the proven Edge --app= fallback when Open fails.
				if KLWV_Open(which, metrics_dir)
						return
				try LoggerWarn("Keylogger", "WebView dashboard open failed for '{1}' — using Edge fallback.", which)
		}

		; Fallback: legacy Edge --app= launcher.
		if (which = "typing") {
				if KLUI.pending.Has(which) {
						KLPF_CancelBuild(which)
						KLUI.pending.Delete(which)
						return
				}
				if IsObject(KLUI.typing_owner) {
						_KLUI_CancelEdgeOwner(which)
						return
				}
				KLUI_LaunchWindow(KLUI.typing_url, title)
		} else {
				if KLUI.pending.Has(which) {
						KLPF_CancelBuild(which)
						KLUI.pending.Delete(which)
						return
				}
				if IsObject(KLUI.apps_owner) {
						_KLUI_CancelEdgeOwner(which)
						return
				}
				KLUI_LaunchWindow(KLUI.apps_url, title)
		}
}

KLUI_CloseAll() {
		try KLWV_CloseAll()
		if !_KLUI_CancelEdgeOwner("typing")
				try LoggerError("Keylogger", "Could not confirm typing Edge metrics termination; ownership was retained.")
		if !_KLUI_CancelEdgeOwner("apps")
				try LoggerError("Keylogger", "Could not confirm apps Edge metrics termination; ownership was retained.")
}
