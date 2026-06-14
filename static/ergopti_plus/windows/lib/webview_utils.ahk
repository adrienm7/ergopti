; drivers/autohotkey/lib/webview_utils.ahk

#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: WebView Utils
; DESCRIPTION:
; Shared helper functions for WebView2 instances.
; ==============================================================================

; Helper to clear stale WebView2 user-data profile directories.
; Call immediately before DirCreate(udir) and after controller.Close()/Gui.Destroy().
WebView_SweepStaleProfiles(prefix) {
    loop files, A_Temp . "\" . prefix . "*", "D" {
        try DirDelete(A_LoopFileFullPath, true)
    }
}
