; drivers/autohotkey/lib/webview_utils.ahk

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

; One stable user-data folder for the whole session. Unlike the former per-open
; "<prefix>_<A_TickCount>" folders, this fixed path cannot accumulate (there is
; exactly one and it is reused forever), so it is leak-free by construction.
global WEBVIEW_SHARED_UDIR := A_Temp . "\ergopti_wv_shared"

; Returns the shared WebView2 environment, booting it on first use.
; @param loader {String} Absolute path to WebView2Loader.dll.
; @returns {WebView2.Environment} The cached environment. Throws on boot failure,
;          so the caller's WebView2.create try/catch can degrade gracefully.
WebView_SharedEnvironment(loader) {
	global _WebView_SharedEnv, WEBVIEW_SHARED_UDIR
	; Warm path -- reuse the already-running browser process.
	if _WebView_SharedEnv
		return _WebView_SharedEnv
	try DirCreate(WEBVIEW_SHARED_UDIR)
	; await() blocks until the environment (and its browser process) is ready.
	; Assigned only on success: a boot failure leaves the cache at 0 and lets the
	; exception propagate to the caller for graceful fallback.
	_WebView_SharedEnv := WebView2.CreateEnvironmentAsync(0, WEBVIEW_SHARED_UDIR, "", loader).await()
	return _WebView_SharedEnv
}


; Helper to clear stale WebView2 user-data profile directories.
; Call immediately before DirCreate(udir) and after controller.Close()/Gui.Destroy().
WebView_SweepStaleProfiles(prefix) {
    loop files, A_Temp . "\" . prefix . "*", "D" {
        try DirDelete(A_LoopFileFullPath, true)
    }
}
