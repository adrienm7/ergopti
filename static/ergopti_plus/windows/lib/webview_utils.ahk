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

; Poll cadence (ms) for a second caller waiting on an in-flight environment
; boot. Short enough that the second WebView2 window does not feel stalled once
; the first caller's CreateEnvironmentAsync resolves.
global WEBVIEW_SHARED_ENV_WAIT_POLL_MS := 20

; Returns the shared WebView2 environment, booting it on first use.
; @param loader {String} Absolute path to WebView2Loader.dll.
; @returns {WebView2.Environment} The cached environment. Throws on boot failure,
;          so the caller's WebView2.create try/catch can degrade gracefully.
WebView_SharedEnvironment(loader) {
	global _WebView_SharedEnv, _WebView_SharedEnvCreating, WEBVIEW_SHARED_UDIR, WEBVIEW_SHARED_ENV_WAIT_POLL_MS
	; Warm path -- reuse the already-running browser process.
	if _WebView_SharedEnv
		return _WebView_SharedEnv

	; A second caller arriving while the first's await() below is pumping the
	; message queue must wait for that boot to finish instead of racing it with
	; its own CreateEnvironmentAsync against the same locked user-data folder.
	if _WebView_SharedEnvCreating {
		while _WebView_SharedEnvCreating
			Sleep(WEBVIEW_SHARED_ENV_WAIT_POLL_MS)
		if _WebView_SharedEnv
			return _WebView_SharedEnv
		; The first caller's boot failed -- fall through and attempt our own,
		; exactly as if we had arrived first.
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
