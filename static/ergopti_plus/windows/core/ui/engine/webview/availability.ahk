; core/ui/engine/webview/availability.ahk

; ==============================================================================
; MODULE: WebView Availability And Refusal
; DESCRIPTION:
; Every WebView window asks here before it builds anything, and refuses here
; when WebView2 is missing, too old or fails: one localized message that says
; how to recover. No window has a native substitute (maintainer decisions
; 2026-11-11 and 2026-11-21). Hoisted functions and two constants only, so a
; private test child can include this owner beside its own browser fakes.
; ==============================================================================

#Requires AutoHotkey v2.0

; The oldest Evergreen runtime the pages run on: the first with
; SetVirtualHostNameToFolderMapping (ICoreWebView2_3), which every page needs.
global WEBVIEW_MIN_RUNTIME_VERSION := "87.0.664.8"
; The runtime's EdgeUpdate client, where Microsoft documents its version.
global WEBVIEW_RUNTIME_CLIENT := "Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

; The installed Evergreen runtime's version, per machine then per user.
; @returns {String} "" when none is installed.
WebView_RuntimeVersion() {
	global WEBVIEW_RUNTIME_CLIENT
	for Root in ["HKLM\SOFTWARE\WOW6432Node\", "HKLM\SOFTWARE\", "HKCU\Software\"] {
		Version := RegRead(Root . WEBVIEW_RUNTIME_CLIENT, "pv", "")
		if (Version != "" && Version != "0.0.0.0")
			return Version
	}
	return ""
}

; True for a runtime below the minimum: the pages would break on a missing
; interface. No runtime at all is not decided here: creating the web view
; fails and the window refuses with the WebView2-required message.
; @param VersionFn {Func} Test seam, WebView_RuntimeVersion by default.
; @returns {Boolean} True when the runtime is too old.
WebView_RuntimeIsRefused(VersionFn := 0) {
	global WEBVIEW_MIN_RUNTIME_VERSION
	Version := HasMethod(VersionFn, "Call") ? VersionFn.Call() : WebView_RuntimeVersion()
	return Version != "" && VerCompare(Version, WEBVIEW_MIN_RUNTIME_VERSION) < 0
}

/**
 * Says why no WebView page can open on this machine. Every WebView window asks
 * before it builds anything: there is no native form to open instead
 * (maintainer decision 2026-11-21).
 * @param {Func} VersionFn Test seam, WebView_RuntimeVersion by default.
 * @returns {String} "" when WebView2 can be tried, else the reason, for the log.
 */
WebView_UnavailableReason(VersionFn := 0) {
	global _VendorDir, WEBVIEW_MIN_RUNTIME_VERSION
	if !IsSet(WebView2)
		return "the WebView2 binding is not loaded"
	if !IsSet(_VendorDir) || !FileExist(_VendorDir . "\64bit\WebView2Loader.dll")
		return "WebView2Loader.dll is missing"
	if WebView_RuntimeIsRefused(VersionFn)
		return "the WebView2 Runtime is below " . WEBVIEW_MIN_RUNTIME_VERSION
	return ""
}

/**
 * Admits a WebView window, or refuses it with the WebView2 message.
 * @param {String} Surface English name of the window, for the log.
 * @param {Func} VersionFn Test seam, WebView_RuntimeVersion by default.
 * @returns {Boolean} True when the window may try WebView2.
 */
WebView_RequireAvailable(Surface, VersionFn := 0) {
	Reason := WebView_UnavailableReason(VersionFn)
	return Reason == "" ? true : WebView_RefuseUnavailable(Surface, Reason, VersionFn)
}

/**
 * Refuses a WebView window that could not open: logs the reason at ERROR and
 * tells the user once, in the one localized message that says how to recover
 * (update a runtime that is too old, else install or repair WebView2).
 * No window has a native substitute (maintainer decisions 2026-11-11 and
 * 2026-11-21).
 * @param {String} Surface English name of the window, for the log.
 * @param {String} Reason What failed, for the log.
 * @param {Func} VersionFn Test seam, WebView_RuntimeVersion by default.
 * @returns {Boolean} Always false: nothing opened.
 */
WebView_RefuseUnavailable(Surface, Reason, VersionFn := 0) {
	try LoggerError("WebView", "The {1} cannot open: WebView2 is required ({2}).", Surface, Reason)
	Ui_MsgBox(WebView_RecoveryText(VersionFn), t("common.error_title"), "Iconx")
	return false
}

/**
 * The localized sentence that says how to get WebView2 working: update a
 * runtime that is too old, else install or repair it.
 * @param {Func} VersionFn Test seam, WebView_RuntimeVersion by default.
 * @returns {String}
 */
WebView_RecoveryText(VersionFn := 0) {
	global WEBVIEW_MIN_RUNTIME_VERSION
	Version := HasMethod(VersionFn, "Call") ? VersionFn.Call() : WebView_RuntimeVersion()
	return (Version != "" && VerCompare(Version, WEBVIEW_MIN_RUNTIME_VERSION) < 0)
		? StrReplace(StrReplace(t("webview.runtime_too_old"), "{1}", WEBVIEW_MIN_RUNTIME_VERSION), "{2}", Version)
		: t("webview.required")
}
