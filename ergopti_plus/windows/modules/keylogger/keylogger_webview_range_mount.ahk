; modules/keylogger/keylogger_webview_range_mount.ahk

; ==============================================================================
; MODULE: WebView Private Range Mount
; DESCRIPTION: Serve one completed stage over HTTPS without exposing its parent directory.
; ==============================================================================

#Requires AutoHotkey v2.0

KLWV_PrepareRangeMount(Entry, Owner, AccessKind) {
	Directory := Owner["stage"] . ".mount"
	if FileExist(Directory)
		throw Error("Range mount destination already exists.")
	DirCreate(Directory)
	Owner["directory"] := Directory
	Destination := Directory . "\range.json"
	FileMove(Owner["stage"], Destination, 0)
	Owner["stage"] := Destination
	Owner["host"] := "range-" . StrLower(Owner["token"]) . ".ergopti.metrics"
	; Record the attempted capability before COM can fail or reenter.
	Owner["mounted"] := true
	Entry["webview"].SetVirtualHostNameToFolderMapping(Owner["host"], Directory, AccessKind)
	return "https://" . Owner["host"] . "/range.json"
}

KLWV_ReleaseRangeMount(Entry, Owner) {
	if !Owner.Get("mounted", false)
		return
	Owner["mounted"] := false
	Entry["webview"].ClearVirtualHostNameToFolderMapping(Owner["host"])
}
