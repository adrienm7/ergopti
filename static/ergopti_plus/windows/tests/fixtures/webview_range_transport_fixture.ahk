; tests/fixtures/webview_range_transport_fixture.ahk

; ==============================================================================
; MODULE: Native WebView Range Transport Fixture
; DESCRIPTION: Compare file-scheme refusal with the production HTTPS stage mount.
; ==============================================================================

#Requires AutoHotkey v2.0
#Warn All, StdOut
#Include ../../vendor/ComVar.ahk
#Include ../../vendor/Promise.ahk
#Include ../../vendor/WebView2.ahk
#Include ../../infra/json.ahk
#Include ../../infra/text_utils.ahk
#Include ../../modules/keylogger/keylogger_webview_range_script.ahk
#Include ../../modules/keylogger/keylogger_webview_range_mount.ahk

OnError(_NWRT_Error)
global _NWRT_Root := A_Args[1]
if FileExist(_NWRT_Root)
	throw Error("Native range fixture destination already exists.")
DirCreate(_NWRT_Root . "\assets")
DirCreate(_NWRT_Root . "\profile")
FileAppend('{"marker":"synthetic","historical":{},"today":{}}', _NWRT_Root . "\stage.json", "UTF-8-RAW")
FileAppend('{"marker":"control"}', _NWRT_Root . "\assets\control.json", "UTF-8-RAW")
global _NWRT_Gui := Gui("+ToolWindow -Caption")
global _NWRT_Controller := 0, _NWRT_Subscription := 0, _NWRT_Entry := 0
global _NWRT_BrowserHandle := 0
global _NWRT_Owner := Map("token", "native-range-fixture", "stage", _NWRT_Root . "\stage.json")
global _NWRT_Ready := false, _NWRT_Result := false, _NWRT_Finished := false
OnExit(_NWRT_Cleanup)
SetTimer(_NWRT_Timeout, -30000)
_NWRT_Controller := WebView2.create(_NWRT_Gui.Hwnd, , 0, _NWRT_Root . "\profile", "", 0,
	A_ScriptDir . "\..\..\vendor\64bit\WebView2Loader.dll")
_NWRT_Controller.IsVisible := false
_NWRT_Entry := Map("webview", _NWRT_Controller.CoreWebView2)
; This fresh profile belongs exclusively to the fixture. Capture a stable
; process handle while the controller is live; never retire a process by PID later.
_NWRT_BrowserHandle := DllCall("OpenProcess", "UInt", 0x100001, "Int", false,
	"UInt", _NWRT_Entry["webview"].BrowserProcessId, "Ptr")
if !_NWRT_BrowserHandle
	throw OSError(A_LastError, "Cannot supervise the owned WebView browser process.")
global _NWRT_Url := KLWV_PrepareRangeMount(_NWRT_Entry, _NWRT_Owner, 1)
_NWRT_Subscription := _NWRT_Entry["webview"].WebMessageReceived(_NWRT_Message)
_NWRT_Entry["webview"].SetVirtualHostNameToFolderMapping("ergopti.metrics", _NWRT_Root . "\assets", 1)
_NWRT_Html := '<!doctype html><meta charset="utf-8"><script>'
	. 'window.receive_range_data=(p,id)=>chrome.webview.postMessage(JSON.stringify({action:"result",id,marker:p.marker}));'
	. 'window.complete_range_request=(id,status)=>chrome.webview.postMessage(JSON.stringify({action:"failed",id,status}));'
	. '(async()=>{const p=await(await fetch("./control.json")).json();let refused=false;'
	. 'try{await fetch(' . JsonStringLiteral(FilePathToUrl(_NWRT_Owner["stage"])) . ');}catch{refused=true;}'
	. 'chrome.webview.postMessage(JSON.stringify({action:"ready",control:p.marker,refused}));})();</script>'
FileAppend(_NWRT_Html, _NWRT_Root . "\assets\index.html", "UTF-8-RAW")
_NWRT_Entry["webview"].Navigate("https://ergopti.metrics/index.html")
while !_NWRT_Finished
	Sleep(10)
FileDelete(_NWRT_Owner["stage"])
DirDelete(_NWRT_Owner["directory"])
_NWRT_CloseOwnedBrowser()
FileAppend('{"same_host":true,"file_refused":true,"mapped_range":true,"consumed":true,"removed":true}' . "`n", "*", "UTF-8-RAW")
ExitApp(0)

_NWRT_Message(Sender, Args) {
	global _NWRT_Ready, _NWRT_Result, _NWRT_Finished, _NWRT_Entry, _NWRT_Owner, _NWRT_Url
	Message := JsonParse(Args.TryGetWebMessageAsString())
	switch Message["action"] {
		case "ready":
			if Message["control"] != "control" || !Message["refused"]
				throw Error("Native origin controls did not reproduce the expected boundary.")
			_NWRT_Ready := true
			Sender.ExecuteScriptAsync(KLWV_BuildRangeScript(_NWRT_Url, 42, _NWRT_Owner["token"]))
				.catch((Err) => _NWRT_Error(Err))
		case "result":
			if !_NWRT_Ready || Message["id"] != 42 || Message["marker"] != "synthetic"
				throw Error("Native range payload did not retain its request and content.")
			_NWRT_Result := true
		case "range_consumed":
			if !_NWRT_Result || Message["token"] != _NWRT_Owner["token"]
				throw Error("Native range acknowledgement arrived without its owned result.")
			KLWV_ReleaseRangeMount(_NWRT_Entry, _NWRT_Owner)
			_NWRT_Finished := true
		default:
			throw Error("Native range transport reported failure.")
	}
}
_NWRT_Error(Err, *) {
	FileAppend(Err.Message . "`n", "**", "UTF-8-RAW")
	SetTimer(() => ExitApp(2), -1)
	return true
}
_NWRT_Timeout() {
	FileAppend("Native range transport timed out.`n", "**", "UTF-8-RAW")
	ExitApp(2)
}
_NWRT_Cleanup(*) {
	try _NWRT_CloseOwnedBrowser()
	catch as Err
		FileAppend("Owned browser teardown: " . Err.Message . "`n", "**", "UTF-8-RAW")
}
_NWRT_CloseOwnedBrowser() {
	global _NWRT_Subscription, _NWRT_Controller, _NWRT_Gui, _NWRT_Entry, _NWRT_BrowserHandle
	_NWRT_Subscription := 0
	if IsObject(_NWRT_Controller)
		try _NWRT_Controller.Close()
	_NWRT_Controller := 0
	_NWRT_Entry := 0
	try _NWRT_Gui.Destroy()
	if !_NWRT_BrowserHandle
		return
	try {
		State := DllCall("WaitForSingleObject", "Ptr", _NWRT_BrowserHandle, "UInt", 0, "UInt")
		if State = 258 {
			if !DllCall("TerminateProcess", "Ptr", _NWRT_BrowserHandle, "UInt", 0)
				throw OSError(A_LastError, "Owned browser termination failed.")
			State := DllCall("WaitForSingleObject", "Ptr", _NWRT_BrowserHandle, "UInt", 5000, "UInt")
		}
		if State != 0
			throw Error("Owned browser exit was not observed.")
	} finally {
		DllCall("CloseHandle", "Ptr", _NWRT_BrowserHandle)
		_NWRT_BrowserHandle := 0
	}
}
