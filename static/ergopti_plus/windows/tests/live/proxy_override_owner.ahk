; tests/live/proxy_override_owner.ahk

; ==============================================================================
; MODULE: Proxy Override Live Fixture
; DESCRIPTION:
; The real http_client and its real managed worker under one stored proxy
; override: publishes a detached route value, sends one real request, asks
; each route owner of the adapter what it would do, runs the menu row over the
; plan's typed values, and writes what came back. tools/test/
; test-windows-proxy-override-e2e.cjs builds the plan and reads the fake network.
;
; FEATURES & RATIONALE:
; 1. The logger is not included: its file sink would write the maintainer's
;    %LOCALAPPDATA%\Ergopti logs, which a test must never touch.
; 2. The texts are the shipped English locale, so "refused in words" is asserted
;    on what a user would read.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
; The driver's other modules assign what these adapters read; this fixture omits them.
#Warn VarUnset, Off

global _OwnerTexts := 0
global _SharedDir := ""
global _VendorDir := ""
global _OwnerLogs := []
OnError(_OwnerFatal)

LoggerWarn(Tag, Message, Values*) => _OwnerLogs.Push("warn: " . Message)
LoggerError(Tag, Message, Values*) => _OwnerLogs.Push("error: " . Message)
LoggerInfo(Tag, Message, Values*) => _OwnerLogs.Push("info: " . Message)
LoggerStart(*) => 0
LoggerSuccess(*) => 0
LoggerDebug(*) => 0
t(Key) => _OwnerTexts[Key]

global ConfigurationFile := ""
global _OwnerCommitted := []
global Features := Map()
; config_io is not part of this fixture's closure: the commit records what reaches the file.
ConfigCommitUpdates(Path, Updates, Context, WriterFn := 0, NotifyFn := 0, PublishFn := 0) {
	_OwnerCommitted.Push(Updates[1].Value)
	PublishFn.Call()
	return true
}

#Include ..\..\infra\tick_count.ahk
#Include ..\..\infra\json.ahk
#Include ..\..\adapters\crypto.ahk
#Include ..\..\adapters\file_system.ahk
#Include ..\..\adapters\process_lifecycle.ahk
#Include ..\..\adapters\shell_runner.ahk
#Include ..\..\adapters\http_client.ahk
#Include ..\..\ui\proxy_override.ahk

_OwnerMain(A_Args[1])

/** A dialog would hang a headless run: name the failure and leave. */
_OwnerFatal(Err, *) {
	FileAppend("owner fixture failed: " . Err.Message . " at " . Err.What . " " . Err.Line . "`n", "**", "UTF-8")
	ExitApp(3)
}

/**
 * Runs the plan and writes the result.
 * @param {String} PlanPath The JSON plan.
 */
_OwnerMain(PlanPath) {
	global _SharedDir, _VendorDir, _OwnerTexts, Features
	Plan := JsonParse(FileRead(PlanPath, "UTF-8"))
	_SharedDir := Plan["shared"]
	_VendorDir := Plan["vendor"]
	_OwnerTexts := JsonParse(FileRead(_SharedDir . "\core\i18n\data\locales\en.json", "UTF-8"))
	Declaration := ProxyOverride_Declaration()
	Features := Map(Declaration["section"], Map(Declaration["key"], Plan["stored"] is String ? Plan["stored"] : ""))
	Result := Map("published", ProxyOverride_Publish(Plan["stored"]))
	; Direct publication has no authenticated bootstrap source and cannot start
	; an automatic migration. Positive boot sealing uses the native unit owner.
	if Plan.Get("seal_at_start", false) {
		Result["sealed_now"] := ProxyOverride_SealStoredAtStart() ? 1 : 0
		Result["committed"] := _OwnerCommitted
		Result["runtime_sealed"] := _ProxyOverrideSealed ? 1 : 0
		Result["unchanged_unsealed"] := !_ProxyOverrideSealed
			&& StrCompare(_ProxyOverrideStored, Plan["stored"], true) == 0
	}
	; A separate real DPAPI sample qualifies encrypted route transport only;
	; it neither publishes a bootstrap receipt nor claims a configuration write.
	if Plan.Get("sample_envelope", false)
		Result["sample_envelope"] := ProxyOverride_Seal(Plan["stored"])
	Settings := Map("auto_detect", false, "pac_url", Plan.Get("pac_url", ""), "proxy", Plan.Get("system_proxy", ""), "bypass", "")

	Http := CurlAsyncRequest()
	Http.SetTimeouts(5000, 5000, 5000, 5000)
	Http.Open("GET", Plan["url"], true)
	Http.SetManagedRouting(() => Settings, () => true)
	Http.SetDeadline(A_TickCount, 45000)
	Started := Http.Send("")
	Deadline := A_TickCount + 50000
	while Started && !Http.WaitForResponse(0) && A_TickCount < Deadline
		Sleep(20)
	Result["request_started"] := Started ? true : false
	Result["status"] := Http.Status
	Result["receipt"] := Http.NativeReceipt

	Reader := () => Settings
	Result["curl_route"] := _OwnerCurlRoute(Plan["url"], Reader)
	Result["for_url"] := _OwnerForUrl(Plan["url"], Reader)
	Answer := 0
	SystemProxy_ResolveAsync([Plan["url"]], (Resolved) => (Answer := Resolved), Reader)
	Deadline := A_TickCount + 30000
	while !IsObject(Answer) && A_TickCount < Deadline
		Sleep(20)
	Result["async_resolved"] := IsObject(Answer) && Answer["_proxy_resolved"] ? true : false
	Result["async_proxy"] := IsObject(Answer) ? Answer[Plan["url"]] : "no-answer"

	Rows := []
	for Typed in Plan.Get("typed", [])
		Rows.Push(_OwnerRow(Typed))
	Result["rows"] := Rows
	if Plan.Get("children", false)
		_OwnerChildren(Plan, Result)
	Result["logs"] := _OwnerLogs

	File := FileOpen(Plan["result"], "w", "UTF-8-RAW")
	File.Write(_OwnerJson(Result))
	File.Close()
	ExitApp(0)
}

; What the driver, a network worker and a program started with Run each see.
_OwnerChildren(Plan, Result) {
	Result["driver_environment"] := EnvGet(PROXY_OVERRIDE_ENVIRONMENT)
	Script := "[Console]::Out.Write((Get-Acl -LiteralPath $env:SystemRoot -ErrorAction Stop).GetType().Name"
		. " + '|' + $env:ERGOPTI_PROXY_OVERRIDE + '|' + $env:PSModulePath)"
	Answer := 0
	Task := ProxyOverride_SpawnWorker(ShellRunner_WinPsPath(), ShellRunner_WinPsArgs("-Command", Script),
		(Code, Stdout, *) => (Answer := Map("code", Code, "stdout", Stdout)))
	if !Task.start()
		throw Error("The worker probe did not start.")
	Deadline := A_TickCount + 30000
	while !IsObject(Answer) && A_TickCount < Deadline
		Sleep(20)
	Result["worker"] := IsObject(Answer) ? Answer : Map("code", -1, "stdout", "")
	Path := Plan["result"] . ".set"
	RunWait('"' . A_ComSpec . '" /d /c set > "' . Path . '"', , "Hide")
	Result["run_child"] := FileRead(Path)
	FileDelete(Path)
}

_OwnerCurlRoute(Url, Reader) {
	Route := 0
	SystemProxy_ResolveCurlAsync(Url, (Selection) => (Route := Selection), Reader)
	Deadline := A_TickCount + 30000
	while !IsObject(Route) && A_TickCount < Deadline
		Sleep(20)
	if !IsObject(Route)
		return Map("ok", false, "proxy", "", "source", "no-answer")
	return Map("ok", Route["ok"] ? true : false, "proxy", Route["proxy"], "source", Route["source"])
}

_OwnerForUrl(Url, Reader) {
	try return SystemProxy_ForUrl(Url, Reader)
	catch as Err
		return "refused: " . Err.Message
}

; One menu row run: what the user typed, what was shown and what was stored.
_OwnerRow(Typed) {
	Shown := []
	Stored := []
	Ports := Map("get", () => "", "set", (Value) => (Stored.Push(Value), true),
		"prompt", (*) => Typed,
		"error", (Title, Text) => Shown.Push("error: " . Text),
		"info", (Title, Text) => Shown.Push("info: " . Text))
	Saved := ProxyOverride_Edit(Ports)
	return Map("typed", Typed, "saved", Saved ? true : false, "shown", Shown, "stored", Stored)
}

; A small writer: JsonStringify is not part of this fixture's closure.
_OwnerJson(Value) {
	if Value is Map {
		Text := ""
		for Name, Item in Value
			Text .= (Text == "" ? "" : ",") . JsonStringLiteral(String(Name)) . ":" . _OwnerJson(Item)
		return "{" . Text . "}"
	}
	if Value is Array {
		Text := ""
		for Item in Value
			Text .= (Text == "" ? "" : ",") . _OwnerJson(Item)
		return "[" . Text . "]"
	}
	if Value is Integer
		return String(Value)
	return JsonStringLiteral(String(Value))
}
