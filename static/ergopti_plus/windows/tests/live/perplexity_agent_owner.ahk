; tests/live/perplexity_agent_owner.ahk

; ==============================================================================
; MODULE: Perplexity Agent API Live Fixture
; DESCRIPTION:
; The real http_client and its real managed worker against the local fake Agent
; API: sends the body remote_formats.ahk writes, reads the answer the way the
; driver does, lists the models, and writes what came back. tools/test/
; test-perplexity-agent-e2e.cjs builds the plan and starts the fake. The logger is
; not included: its file sink would write the maintainer's logs.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
; The driver's other modules assign what these adapters read; this fixture omits them.
#Warn VarUnset, Off

global _SharedDir := ""
global _VendorDir := ""
OnError(_AgentOwnerFatal)

LoggerWarn(*) => 0
LoggerError(*) => 0
LoggerInfo(*) => 0
LoggerStart(*) => 0
LoggerSuccess(*) => 0
LoggerDebug(*) => 0
t(Key) => Key

#Include ..\..\core\logger\engine\tick_count.ahk
#Include ..\..\infra\json.ahk
#Include ..\..\core\crypto\crypto.ahk
#Include ..\..\core\fs\adapters\file_system.ahk
#Include ..\..\adapters\process_lifecycle.ahk
#Include ..\..\adapters\shell_runner.ahk
#Include ..\..\adapters\proxy_override.ahk
#Include ..\..\adapters\http_client.ahk
#Include ..\..\modules\llm\remote_formats.ahk

_AgentOwnerMain(A_Args[1])

/** A dialog would hang a headless run: name the failure and leave. */
_AgentOwnerFatal(Err, *) {
	FileAppend("owner fixture failed: " . Err.Message . " at " . Err.What . " " . Err.Line . "`n", "**", "UTF-8")
	ExitApp(3)
}

/**
 * Sends one request through the real transport.
 * @param {String} Method GET or POST.
 * @param {String} Url The address.
 * @param {String} Token The key.
 * @param {String} Body The body, "" for none.
 * @returns {Map} status, text.
 */
_AgentOwnerSend(Method, Url, Token, Body) {
	Settings := Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")
	Http := CurlAsyncRequest()
	Http.SetTimeouts(5000, 5000, 5000, 5000)
	Http.Open(Method, Url, true)
	Http.SetRequestHeader("Authorization", "Bearer " . Token)
	Http.SetRequestHeader("Content-Type", "application/json")
	Http.SetManagedRouting(() => Settings, () => true)
	Http.SetDeadline(A_TickCount, 45000)
	Started := Http.Send(Body)
	Deadline := A_TickCount + 50000
	while Started && !Http.WaitForResponse(0) && A_TickCount < Deadline
		Sleep(20)
	return Map("status", Http.Status, "text", Http.ResponseText)
}

/**
 * Runs the plan and writes the result.
 * @param {String} PlanPath The JSON plan.
 */
_AgentOwnerMain(PlanPath) {
	global _SharedDir, _VendorDir, LLM_AGENT_PATH
	Plan := JsonParse(FileRead(PlanPath, "UTF-8"))
	_SharedDir := Plan["shared"]
	_VendorDir := Plan["vendor"]
	Body := LLM_RemoteFormats_AgentBody("perplexity/sonar", "Reply with OK.", Plan["text"], 16, "0.00")
	Answer := _AgentOwnerSend("POST", Plan["base"] . LLM_AGENT_PATH, Plan["token"], Body)
	Root := JsonParse(Answer["text"])
	Failed := LLM_RemoteFormats_AgentFailed(Root)
	LLM_RemoteFormats_AgentText(Root, &Text)
	Listing := _AgentOwnerSend("GET", Plan["base"] . "/models", Plan["token"], "")
	File := FileOpen(Plan["result"], "w", "UTF-8-RAW")
	File.Write('{"status":' . Answer["status"] . ',"failed":' . (Failed ? "true" : "false")
		. ',"text":' . JsonStringLiteral(Text) . ',"listing_status":' . Listing["status"]
		. ',"listing":' . JsonStringLiteral(Listing["text"]) . '}')
	File.Close()
	ExitApp(0)
}
