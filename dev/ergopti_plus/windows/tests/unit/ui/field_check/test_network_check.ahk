; tests/unit/ui/field_check/test_network_check.ahk

; ==============================================================================
; MODULE: Network Check Tests (Windows)
; DESCRIPTION:
; The Debug menu's « Test network (PAC, proxy, download) »
; (ui/field_check/network_check.ahk) over scripted collaborators:
; 1. the kinds of proxy configured are named from the Windows settings and the
;    proxy environment, and the PAC verdict follows the managed download's
;    (HTTP 200, one mebibyte, strict UTF-8, FindProxyForURL);
; 2. a run reports the seven steps in the order macOS and Linux report them,
;    a failing step names itself with a closed token, and a missing PAC skips
;    both PAC steps;
; 3. no step, log line or window text can carry the PAC address, a host or PAC
;    content;
; 4. a second click while a check runs is refused, and a collaborator that
;    raises is a failed step, not a lost run.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

global _TNC_PacUrl := "http://pac.intranet.example/proxy.pac"
global _TNC_FeedUrl := "https://feed.example.test/releases.atom"

; The UTF-8 bytes of a text, as a Buffer (no terminator).
_TNC_Bytes(Text) {
	Size := StrPut(Text, "UTF-8") - 1
	Bytes := Buffer(Size)
	StrPut(Text, Bytes, Size, "UTF-8")
	return Bytes
}

; Collaborators that complete synchronously, with overrides.
_TNC_Deps(Overrides := 0) {
	global _TNC_PacUrl, _TNC_FeedUrl
	Deps := Map(
		"settings", () => Map("kinds", "pac", "pac_url", _TNC_PacUrl),
		"fetch_pac", (Url, Callback) => Callback.Call(200, _TNC_Bytes("function FindProxyForURL(url, host) { return 'DIRECT'; }")),
		"feed_url", () => _TNC_FeedUrl,
		"route", (Url, Callback) => (Callback.Call(Map("ok", true, "source", "system_static")), true),
		"request", (Url, Callback) => Callback.Call(Map("ok", true, "status", 200)))
	if (Overrides is Map)
		for Key, Value in Overrides
			Deps[Key] := Value
	return Deps
}

; Runs the check and returns its report.
_TNC_Run(Deps) {
	Box := {Report: 0}
	AssertTrue(NetworkCheck_Run((Report) => Box.Report := Report, Deps), "the check starts")
	Assert(Box.Report is Map, "the check delivers its report")
	return Box.Report
}

; "id=state:value" of every step, in order.
_TNC_Steps(Report) {
	Out := ""
	for Step in Report["steps"]
		Out .= (Out != "" ? " " : "") . Step["id"] . "=" . Step["state"] . (Step["value"] != "" ? ":" . Step["value"] : "")
	return Out
}

; Step values by identity.
_TNC_ByIdentity(Report) {
	Steps := Map()
	for Step in Report["steps"]
		Steps[Step["id"]] := Step
	return Steps
}





; ============================
; ============================
; ======= 2/ The kinds =======
; ============================
; ============================

_TNC_Kinds() {
	NoEnv := (Name) => ""
	AssertEqual("none", NetworkCheck_ProxyKinds(Map("auto_detect", false, "pac_url", "", "proxy", ""), NoEnv))
	AssertEqual("pac", NetworkCheck_ProxyKinds(Map("auto_detect", false, "pac_url", "http://x/p.pac", "proxy", ""), NoEnv))
	AssertEqual("pac+discovery+fixed", NetworkCheck_ProxyKinds(
		Map("auto_detect", true, "pac_url", "http://x/p.pac", "proxy", "p:8080"), NoEnv))
	AssertEqual("env+fixed", NetworkCheck_ProxyKinds(Map("auto_detect", false, "pac_url", "", "proxy", "p:8080"),
		(Name) => Name = "https_proxy" ? "http://proxy.example:3128" : ""))
}

Test("NetworkCheck: the proxy kinds are named from the settings and the environment (network-check)", _TNC_Kinds)


_TNC_PacVerdict() {
	Good := _TNC_Bytes("function FindProxyForURL(url, host) { return 'DIRECT'; }")
	AssertEqual("ok", NetworkCheck_JudgePac(200, Good))
	for WrongName in ["findproxyforurl", "FINDPROXYFORURL", "FindProxyForUrl"] {
		Script := "function " . WrongName . "(){return 'DIRECT';}"
		AssertEqual("error", NetworkCheck_JudgePac(200, _TNC_Bytes(Script)),
			"PAC entry point is case sensitive: " . WrongName)
		AssertEqual("error", _HC_PacAnswer(200, Script)["result"]["state"],
			"health diagnostics use the same exact entry point")
	}
	AssertEqual("ok", _HC_PacAnswer(200, "function FindProxyForURL(){return 'DIRECT';}")["result"]["state"])

	AssertEqual("error", NetworkCheck_JudgePac(404, Good), "a non-200 answer is an error")
	AssertEqual("error", NetworkCheck_JudgePac(0, ""), "a failed request is an error")
	AssertEqual("error", NetworkCheck_JudgePac(200, Buffer(0)), "an empty PAC is an error")
	AssertEqual("error", NetworkCheck_JudgePac(200, _TNC_Bytes("<html>login</html>")), "a page without FindProxyForURL")
	; A script that would pass, followed by an overlong encoding of NUL (C0 80)
	Invalid := Buffer(Good.Size + 2)
	DllCall("RtlMoveMemory", "Ptr", Invalid, "Ptr", Good, "UPtr", Good.Size)
	NumPut("UChar", 0xC0, Invalid, Good.Size)
	NumPut("UChar", 0x80, Invalid, Good.Size + 1)
	AssertEqual("error", NetworkCheck_JudgePac(200, Invalid), "an overlong UTF-8 form is refused like the download does")
	Marked := Buffer(Good.Size + 3)
	NumPut("UChar", 0xEF, Marked, 0), NumPut("UChar", 0xBB, Marked, 1), NumPut("UChar", 0xBF, Marked, 2)
	DllCall("RtlMoveMemory", "Ptr", Marked.Ptr + 3, "Ptr", Good, "UPtr", Good.Size)
	AssertEqual("ok", NetworkCheck_JudgePac(200, Marked), "a UTF-8 byte-order mark is accepted")
	Wide := Buffer(4, 0)
	NumPut("UChar", 0xFF, Wide, 0), NumPut("UChar", 0xFE, Wide, 1)
	AssertEqual("error", NetworkCheck_JudgePac(200, Wide), "a BOM with NUL is not a PAC")
	for BigEndian in [false, true] {
		Text := "// é " . Chr(0x1F600) . " " . Chr(0xFFFD) . "`nfunction FindProxyForURL(){return 'DIRECT';}"
		Units := StrLen(Text)
		Storage := Buffer(2 + (Units + 1) * 2, 0)
		Valid := Buffer(2 + Units * 2, 0)
		NumPut("UShort", 0xFEFF, Storage)
		StrPut(Text, Storage.Ptr + 2, Units + 1, "UTF-16")
		DllCall("RtlMoveMemory", "Ptr", Valid, "Ptr", Storage, "UPtr", Valid.Size)
		if BigEndian {
			Loop Valid.Size // 2 {
				At := (A_Index - 1) * 2
				Word := NumGet(Valid, At, "UShort")
				NumPut("UShort", ((Word & 0xFF) << 8) | (Word >> 8), Valid, At)
			}
		}
		AssertEqual("ok", NetworkCheck_JudgePac(200, Valid), "real UTF-16 PAC survives strict decoding")
	}
	for Hex in ["FFFE", "FEFF", "FFFE41", "FEFF00", "FFFE00D8", "FEFFDC00", "FFFE4100", "FEFF0041"] {
		Bad := Buffer(StrLen(Hex) // 2)
		Loop Bad.Size
			NumPut("UChar", Integer("0x" . SubStr(Hex, A_Index * 2 - 1, 2)), Bad, A_Index - 1)
		AssertEqual("error", NetworkCheck_JudgePac(200, Bad), "malformed or absent UTF-16 script: " . Hex)
	}
	Expanded := Buffer(Valid.Size + 800000, 0)
	DllCall("RtlMoveMemory", "Ptr", Expanded, "Ptr", Storage, "UPtr", Valid.Size)
	Loop 400000
		NumPut("UShort", 0x0800, Expanded, Valid.Size + (A_Index - 1) * 2)
	AssertTrue(Expanded.Size < NetworkCheck_PacMaxBytes(), "raw UTF-16 is within the byte bound")
	AssertEqual("error", NetworkCheck_JudgePac(200, Expanded), "normalized UTF-8 exceeds the byte bound")
	WithNul := Buffer(Good.Size + 1, 0)
	DllCall("RtlMoveMemory", "Ptr", WithNul, "Ptr", Good, "UPtr", Good.Size)
	AssertEqual("error", NetworkCheck_JudgePac(200, WithNul), "valid script followed by NUL is refused")
	; A valid script padded past the limit, so only the size can refuse it
	Big := Buffer(NetworkCheck_PacMaxBytes() + 1, 0x20)
	DllCall("RtlMoveMemory", "Ptr", Big, "Ptr", Good, "UPtr", Good.Size)
	AssertEqual("error", NetworkCheck_JudgePac(200, Big), "over the size limit")
}

Test("NetworkCheck: the PAC verdict follows the managed download's rules (network-check)", _TNC_PacVerdict)

; The ceiling is the shared policy's, not a copy: a different value there moves it.
_TNC_PacCeilingIsThePolicys() {
	global _SharedDir
	Policy := JsonParse(FileRead(_SharedDir . "\modules\network\proxy_policy.json", "UTF-8"))
	Maximum := Policy["native_pac"]["max_script_bytes"]
	AssertTrue(Maximum > 0, "the policy names a PAC ceiling")
	AssertEqual(Maximum, NetworkCheck_PacMaxBytes())
	Body := _DriverFuncBody("NetworkCheck_PacMaxBytes")
	AssertTrue(InStr(Body, "max_script_bytes") > 0, "the ceiling is read from the policy")
}
Test("NetworkCheck: the PAC ceiling is the shared policy's (PAR-71)", _TNC_PacCeilingIsThePolicys)





; ========================================
; ========================================
; ======= 3/ The run and its steps =======
; ========================================
; ========================================

_TNC_CleanRun() {
	global NETWORK_CHECK_STEPS
	Report := _TNC_Run(_TNC_Deps())
	AssertTrue(ComposerCheck_Passed(Report), "every step passed")
	Order := []
	for Step in Report["steps"]
		Order.Push(Step["id"])
	AssertEqual(NETWORK_CHECK_STEPS.Length, Order.Length)
	for Index, Id in NETWORK_CHECK_STEPS
		AssertEqual(Id, Order[Index], "step " . Index . " is reported in the order macOS and Linux use")
	Steps := _TNC_ByIdentity(Report)
	AssertEqual("pac", Steps["proxy_settings"]["value"])
	AssertEqual("http_200", Steps["pac_download"]["value"])
	AssertEqual("valid", Steps["pac_script"]["value"])
	AssertEqual("selected_proxy", Steps["route_lookup"]["value"])
	AssertEqual("trusted", Steps["tls"]["value"])
	AssertEqual("http_200", Steps["transfer"]["value"])
	AssertEqual("skip", Steps["digest"]["state"])
}

Test("NetworkCheck: a clean run reports the seven steps in the shared order (network-check)", _TNC_CleanRun)


_TNC_NoPac() {
	Report := _TNC_Run(_TNC_Deps(Map("settings", () => Map("kinds", "none", "pac_url", ""))))
	Steps := _TNC_ByIdentity(Report)
	AssertEqual("skip", Steps["pac_download"]["state"])
	AssertEqual("no_pac", Steps["pac_download"]["value"])
	AssertEqual("skip", Steps["pac_script"]["state"])
	AssertTrue(ComposerCheck_Passed(Report), "a skipped PAC never fails the run")
}

Test("NetworkCheck: a missing PAC skips both PAC steps (network-check)", _TNC_NoPac)


; Under an override the PAC decides nothing, and a relay override forbids any other
; route: the probe stays silent even though the system names a PAC.
_TNC_OverrideSkipsPac() {
	Fetched := 0
	Report := _TNC_Run(_TNC_Deps(Map("override_routes", () => true,
		"fetch_pac", (Url, Callback) => (Fetched += 1, Callback.Call(200, "")))))
	Steps := _TNC_ByIdentity(Report)
	AssertEqual(0, Fetched, "no request may leave outside the chosen route")
	AssertEqual("skip", Steps["pac_download"]["state"])
	AssertEqual("override", Steps["pac_download"]["value"])
	AssertEqual("override", Steps["pac_script"]["value"])
	AssertEqual("selected_proxy", Steps["route_lookup"]["value"], "the check goes on with the route")
	Fetched := 0
	_TNC_Run(_TNC_Deps(Map("override_routes", () => false,
		"fetch_pac", (Url, Callback) => (Fetched += 1, Callback.Call(0, "")))))
	AssertEqual(1, Fetched, "automatic still probes the PAC")
}

Test("NetworkCheck: an override leaves the PAC alone (network-check)", _TNC_OverrideSkipsPac)


; The object's default is the machine's WinHTTP proxy; the policy's route is direct.
_TNC_PacFetchIsDirect() {
	Calls := []
	Request := {}
	Request.DefineProp("SetProxy", { Call: (Self, Setting) => Calls.Push("proxy:" . Setting) })
	Request.DefineProp("SetTimeouts", { Call: (Self, *) => Calls.Push("timeouts") })
	Request.DefineProp("Open", { Call: (Self, Verb, Url, Async) => Calls.Push("open") })
	Request.DefineProp("Send", { Call: (Self) => (Calls.Push("send"), 0) })
	Request.DefineProp("WaitForResponse", { Call: (Self, Timeout) => false })
	Request.DefineProp("Abort", { Call: (Self) => 0 })
	_NetworkCheck_FetchPac("https://pac.invalid/proxy.pac", (*) => 0, () => Request)
	AssertEqual("proxy:1", Calls[1], "the route is set before the request opens")
	AssertEqual("open", Calls[3])
}

Test("NetworkCheck: the PAC download is direct (network-check)", _TNC_PacFetchIsDirect)


_TNC_PacFailures() {
	Down := _TNC_Run(_TNC_Deps(Map("fetch_pac", (Url, Callback) => Callback.Call(404, ""))))
	Steps := _TNC_ByIdentity(Down)
	AssertFalse(ComposerCheck_Passed(Down))
	AssertEqual("fail", Steps["pac_download"]["state"])
	AssertEqual("http_404", Steps["pac_download"]["value"])
	AssertEqual("invalid", Steps["pac_script"]["value"])
	Page := _TNC_Run(_TNC_Deps(Map("fetch_pac", (Url, Callback) => Callback.Call(200, _TNC_Bytes("<html>login</html>")))))
	Steps := _TNC_ByIdentity(Page)
	AssertEqual("pass", Steps["pac_download"]["state"])
	AssertEqual("fail", Steps["pac_script"]["state"])
	Gone := _TNC_Run(_TNC_Deps(Map("fetch_pac", (Url, Callback) => Callback.Call(0, ""))))
	AssertEqual("failed", _TNC_ByIdentity(Gone)["pac_download"]["value"])
}

Test("NetworkCheck: a PAC that cannot be downloaded or is not a script names its own step (network-check)", _TNC_PacFailures)


_TNC_RouteRefused() {
	Report := _TNC_Run(_TNC_Deps(Map("route", (Url, Callback) => (Callback.Call(Map("ok", false, "source", "native_refused")), true))))
	Steps := _TNC_ByIdentity(Report)
	AssertFalse(ComposerCheck_Passed(Report))
	AssertEqual("fail", Steps["route_lookup"]["state"])
	AssertEqual("native_refused", Steps["route_lookup"]["value"])
	AssertEqual("pass", Steps["transfer"]["state"], "the request still runs after a refused lookup")
}

Test("NetworkCheck: a refused route lookup fails its step and the request still runs (network-check)", _TNC_RouteRefused)


_TNC_RequestFailures() {
	Cases := [
		[Map("ok", false, "stage", "tls"), "fail", "certificate", "certificate"],
		[Map("ok", false, "stage", "proxy_connect"), "skip", "not_reached", "proxy_connect"],
		[Map("ok", false, "stage", "proxy_resolve"), "skip", "not_reached", "proxy_resolve"],
		[Map("ok", false, "stage", "connect"), "skip", "not_reached", "connect"],
		[Map("ok", false, "timed_out", true), "skip", "not_reached", "timeout"],
		[Map("ok", false, "status", 503), "skip", "not_reached", "http_503"],
		[Map("ok", false), "skip", "not_reached", "failed"]]
	for Scenario in Cases {
		Result := Scenario[1]
		Report := _TNC_Run(_TNC_Deps(Map("request", (Url, Callback) => Callback.Call(Result))))
		Steps := _TNC_ByIdentity(Report)
		AssertFalse(ComposerCheck_Passed(Report))
		AssertEqual(Scenario[2], Steps["tls"]["state"])
		AssertEqual(Scenario[3], Steps["tls"]["value"])
		AssertEqual("fail", Steps["transfer"]["state"])
		AssertEqual(Scenario[4], Steps["transfer"]["value"])
	}
	Refused := _TNC_Run(_TNC_Deps(Map("request", (Url, Callback) => Callback.Call(Map("ok", true, "status", 407)))))
	AssertEqual("fail", _TNC_ByIdentity(Refused)["transfer"]["state"], "an HTTP error status fails the transfer")
}

Test("NetworkCheck: each way the request fails is a closed token on the TLS and transfer steps (network-check)", _TNC_RequestFailures)


; A collaborator that raises with text that must never reach the record.
_TNC_Raise(*) {
	throw Error("PRIVATE /Users/PrivateUser")
}

_TNC_Raises() {
	Report := _TNC_Run(_TNC_Deps(Map("settings", _TNC_Raise)))
	Steps := _TNC_ByIdentity(Report)
	AssertEqual("fail", Steps["proxy_settings"]["state"])
	AssertEqual("unreadable", Steps["proxy_settings"]["value"])
	AssertEqual("skip", Steps["pac_download"]["state"], "unreadable settings leave no PAC to fetch")
	NoFeed := _TNC_Run(_TNC_Deps(Map("feed_url", () => "")))
	AssertEqual("no_target", _TNC_ByIdentity(NoFeed)["transfer"]["value"])
	AssertFalse(ComposerCheck_Passed(NoFeed))
}

Test("NetworkCheck: a collaborator that raises is a failed step, never a lost run (network-check)", _TNC_Raises)





; ============================================
; ============================================
; ======= 4/ Privacy and the one click =======
; ============================================
; ============================================

_TNC_NoAddressEscapes() {
	global _TNC_PacUrl, _TNC_FeedUrl
	Report := _TNC_Run(_TNC_Deps(Map(
		"fetch_pac", (Url, Callback) => Callback.Call(200, _TNC_Bytes("function FindProxyForURL(u,h){return 'PROXY secret.corp.example:8080';}")))))
	Line := ComposerCheck_LogLine(Report, "network")
	Text := ComposerCheck_Text(Report, (Key) => Key)
	for Needle in [_TNC_PacUrl, _TNC_FeedUrl, "intranet", "secret.corp", "feed.example"] {
		AssertFalse(InStr(Line, Needle), "the evidence line carries " . Needle)
		AssertFalse(InStr(Text, Needle), "the window text carries " . Needle)
	}
	AssertContains(Line, "check=network verdict=pass steps=7")
}

Test("NetworkCheck: no address, host or PAC content reaches the record or the window (network-check)", _TNC_NoAddressEscapes)


_TNC_OneAtATime() {
	Pending := {Callback: 0}
	Deps := _TNC_Deps(Map("request", (Url, Callback) => Pending.Callback := Callback))
	Box := {Report: 0}
	AssertTrue(NetworkCheck_Run((Report) => Box.Report := Report, Deps), "the first click starts")
	AssertFalse(NetworkCheck_Run((Report) => 0, _TNC_Deps()), "a second click while a check runs is refused")
	Pending.Callback.Call(Map("ok", true, "status", 200))
	Assert(Box.Report is Map, "the first check finishes")
	AssertTrue(NetworkCheck_Run((Report) => 0, _TNC_Deps()), "and a new one can start afterwards")
}

Test("NetworkCheck: a second click while a check runs is refused (network-check)", _TNC_OneAtATime)


_TNC_FailureTokens() {
	AssertEqual("timeout", NetworkCheck_FailureToken(Map("timed_out", true, "stage", "connect")))
	AssertEqual("certificate", NetworkCheck_FailureToken(Map("stage", "tls")))
	AssertEqual("http_502", NetworkCheck_FailureToken(Map("status", 502)))
	AssertEqual("failed", NetworkCheck_FailureToken(Map()))
}

Test("NetworkCheck: the failure token is a closed vocabulary (network-check)", _TNC_FailureTokens)
