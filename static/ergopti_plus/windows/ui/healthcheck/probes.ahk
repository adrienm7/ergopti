; ui/healthcheck/probes.ahk

; ==============================================================================
; MODULE: Healthcheck / Probes
; DESCRIPTION:
; The asynchronous half of the diagnostics snapshot: the facts that need the
; network, and the processor load, which needs two samples. Each network probe
; is a curl child owned by the process tree (CurlAsyncRequest), reached
; through the Windows proxy the browser uses, harvested by a SetTimer poll and
; bounded by its timeout in _shared/modules/diagnostics/schema.json; every
; probe answers exactly once.
;
; FEATURES & RATIONALE:
; 1. github_api asks api.github.com for its rate limit, the host every update
;    check talks to; the endpoint does not count against that limit.
; 2. ai_health asks the local Ollama for its version when the AI is on; a
;    remote backend is not probed (it would need the user's key).
; 3. cpu_load samples the system and process times twice, sample_ms apart on
;    a timer: the thread keeps serving the keyboard hook between the samples.
; 4. No network phase runs on the AHK thread: WinHttp's asynchronous mode
;    still blocks its caller during DNS and connect.
; 5. A run belongs to one window epoch; a new run or a closed window cancels
;    it, and a late answer of a cancelled run publishes nothing.
; ==============================================================================

#Requires AutoHotkey v2.0

; The User-Agent GitHub requires on every API request
global HC_PROBE_USER_AGENT := "ErgoptiPlus-Diagnostics"

; How often a probe asks its curl child whether it answered
global HC_PROBE_POLL_MS := 100

; The current run: { Epoch, Cancelled, Requests, Publish } (0 when none)
global _HC_ProbeRun := 0





; ================================
; ================================
; ======= 1/ Run Lifecycle =======
; ================================
; ================================

; Starts every probe of a window's snapshot.
; @param Epoch {Integer} The window the answers belong to.
; @param Schema {Map} The diagnostics schema.
; @param Publish {Func} (Epoch, Id, Result, Sections) receives each answer once.
; @param LocalOnly {Boolean} Start only the probes that read local files.
; @param CurrentFn {Func|Integer} Optional pure predicate for the initiating window.
HealthCheck_StartProbes(Epoch, Schema, Publish, LocalOnly := false, Overrides := 0, CurrentFn := 0) {
	global _HC_ProbeRun
	HasOwner := !(CurrentFn is Integer && CurrentFn == 0)
	if HasOwner && !HasMethod(CurrentFn, "Call")
		throw TypeError("The diagnostics probe owner must be callable or zero.")
	if HasOwner && !CurrentFn.Call()
		return false
	HealthCheck_CancelProbes(CurrentFn)
	Run := { Epoch: Epoch, Cancelled: false, Requests: [], Publish: Publish }
	; Abort and terminal retirement can dispatch native messages. Publish only
	; while the initiating window still owns the request, never over its successor.
	PreviousCritical := Critical("On")
	try {
		if HasOwner && !CurrentFn.Call()
			return false
		_HC_ProbeRun := Run
	} finally Critical(PreviousCritical)
	Probes := Schema["probes"]
	_HC_ProbeConfiguration(Run, Probes["configuration"], Overrides)
	if LocalOnly
		return true
	Github := Probes["github_api"]
	_HC_ProbeHttp(Run, "github_api", Github["url"],
		Map("User-Agent", HC_PROBE_USER_AGENT, "Accept", "application/vnd.github+json"),
		Github["timeout_ms"], _HC_GithubAnswer)
	_HC_ProbePac(Run, Probes["proxy_pac"])
	_HC_ProbeAi(Run, Probes["ai_health"])
	_HC_ProbeCpu(Run, Probes["cpu_load"])
	return true
}

; Cancels the current run: its curl children are stopped, its answers dropped.
; @param CurrentFn {Func|Integer} Optional pure predicate for the requesting page.
HealthCheck_CancelProbes(CurrentFn := 0) {
	HasOwner := !(CurrentFn is Integer && CurrentFn == 0)
	if HasOwner && !HasMethod(CurrentFn, "Call")
		throw TypeError("The diagnostics probe owner must be callable or zero.")
	if HasOwner && !CurrentFn.Call()
		return false
	ManagedNetworkTerminalFailure.Retire("diagnostics")
	global _HC_ProbeRun
	PreviousCritical := Critical("On")
	try {
		if HasOwner && !CurrentFn.Call()
			return false
		if !IsObject(_HC_ProbeRun)
			return true
		Run := _HC_ProbeRun
		_HC_ProbeRun := 0
		Run.Cancelled := true
	} finally Critical(PreviousCritical)
	for Request in Run.Requests {
		if !Request.Abort()
			LoggerError("Healthcheck", "A diagnostics probe's curl child refused to stop; its cleanup is retained.")
	}
	return true
}

; Logs a probe's start: the one TRACE that _HC_ProbeFinish's DONE closes.
; @param Id {String}
; @param Detail {String} What the probe waits for, such as its timeout.
_HC_ProbeStarted(Id, Detail) {
	LoggerTrace("Healthcheck", "Probe '{1}' started ({2})…", Id, Detail)
}

; Publishes one probe's single answer, unless its run was cancelled.
; @param Run {Object}
; @param Id {String}
; @param Started {Integer} A_TickCount at the start.
; @param Result {Map} { state, detail? }
; @param Sections {Map} Values the probe filled, by section.
_HC_ProbeFinish(Run, Id, Started, Result, Sections := 0, NowTick := unset) {
	Result["ms"] := TickElapsed64(Started, NowTick?)
	LoggerDone("Healthcheck", "Probe '{1}' answered: {2} ({3} ms).", Id, Result["state"], Result["ms"])
	if Run.Cancelled
		return
	; A timer thread: an exception here would reach the global error handler
	try Run.Publish.Call(Run.Epoch, Id, Result, (Sections is Map) ? Sections : Map())
	catch as Err
		LoggerError("Healthcheck", "The answer of probe '{1}' could not be published: {2}", Id, Err.Message)
}





; ==============================
; ==============================
; ======= 2/ HTTP Probes =======
; ==============================
; ==============================

; Starts one HTTP GET probe: resolves the proxy, then hands the request to curl.
; @param Run {Object}
; @param Id {String}
; @param Url {String}
; @param Headers {Map}
; @param TimeoutMs {Integer}
; @param Interpret {Func} (Status, Body) → Map { result, sections? }
_HC_ProbeHttp(Run, Id, Url, Headers, TimeoutMs, Interpret) {
	Started := A_TickCount
	_HC_ProbeStarted(Id, "timeout " . TimeoutMs . " ms")
	_HC_ProbeSend(Run, Id, Url, Headers, TimeoutMs, Interpret, Started)
}

; Sends the request of an HTTP probe through curl and arms its poll.
_HC_ProbeSend(Run, Id, Url, Headers, TimeoutMs, Interpret, Started, Port := 0) {
	Request := 0
	if Run.Cancelled {
		_HC_ProbeFinish(Run, Id, Started, Map("state", "cancelled"))
		return
	}
	try {
		CreateFn := Port is Map ? Port.Get("create_http", 0) : 0
		Request := IsObject(CreateFn) ? CreateFn.Call() : CurlAsyncRequest()
		Run.Requests.Push(Request)
		if Id == "proxy_pac"
			Interpret := _HC_PacBindRequest(Request, Interpret)
		Request.SetManagedRouting(Port is Map ? Port.Get("managed_settings", 0) : 0, () => _HC_ManagedRunCurrent(Run))
		Request.SetDeadline(Started, TimeoutMs)
		Request.Open("GET", Url, true)
		for Name, Value in Headers
			Request.SetRequestHeader(Name, Value)
		; One budget for the whole request: half to connect, the rest to answer
		Request.SetTimeouts(TimeoutMs // 2, 0, 0, TimeoutMs - TimeoutMs // 2)
		if !_HC_ManagedRunCurrent(Run) {
			Request.Abort()
			return
		}
		if !Request.Send()
			throw Error("The exact managed diagnostics request refused dispatch.")
	} catch as Err {
		if IsObject(Request)
			Request.Abort()
		_HC_ProbeFinish(Run, Id, Started, Map("state", "error", "detail", "managed probe refused"))
		return
	}
	ArmFn := Port is Map ? Port.Get("arm_poll", 0) : 0
	if IsObject(ArmFn)
		ArmFn.Call(Run, Id, Request, Interpret, Started, TimeoutMs)
	else
		_HC_ProbeArmPoll(Run, Id, Request, Interpret, Started, TimeoutMs)
}

_HC_ManagedRunCurrent(Run) {
	global _HC_ProbeRun
	return IsObject(_HC_ProbeRun) && IsObject(Run) && ObjPtr(_HC_ProbeRun) == ObjPtr(Run) && !Run.Cancelled
}

; Asks an HTTP probe's curl child again after one poll interval.
_HC_ProbeArmPoll(Run, Id, Request, Interpret, Started, TimeoutMs) {
	SetTimer(_HC_ProbePoll.Bind(Run, Id, Request, Interpret, Started, TimeoutMs), -HC_PROBE_POLL_MS)
}

; Harvests an HTTP probe's answer without waiting for it.
_HC_ProbePoll(Run, Id, Request, Interpret, Started, TimeoutMs, NowTick := unset, ArmPollFn := unset) {
	if Run.Cancelled {
		_HC_ProbeFinish(Run, Id, Started, Map("state", "cancelled"), 0, NowTick?)
		return
	}
	if Request.WaitForResponse(0) {
		Answer := Interpret.Call(Request.Status, Request.ResponseText)
		if Answer["result"].Get("state", "") != "ok" {
			Report := ManagedNetworkFailureWindows_FromTransport(Request, () => _HC_ManagedRunCurrent(Run))
			Key := ManagedNetworkFailureWindows_MessageKey(Report)
			if Key != "" {
				Answer["result"]["detail"] := t(Key)
				Answer["result"]["network_report"] := Report
			}
		}
		_HC_ProbeFinish(Run, Id, Started, Answer["result"], Answer.Get("sections", 0), NowTick?)
		return
	}
	; curl's own max-time ends the child first; this bound only covers a child
	; that never reports back
	if (TickElapsed64(Started, NowTick?) > TimeoutMs + 1000) {
		if !Request.Abort()
			LoggerError("Healthcheck", "The timed-out probe '{1}' refused to stop; its cleanup is retained.", Id)
		_HC_ProbeFinish(Run, Id, Started, Map("state", "timeout"), 0, NowTick?)
		return
	}
	if IsSet(ArmPollFn)
		ArmPollFn.Call(Run, Id, Request, Interpret, Started, TimeoutMs)
	else
		_HC_ProbeArmPoll(Run, Id, Request, Interpret, Started, TimeoutMs)
}

; The failure of an HTTP answer, from its status.
; @param Status {Integer}
; @returns {Map}
_HC_HttpFailure(Status) {
	return Map("state", "error", "detail", (Status > 0) ? "HTTP " . Status : "no HTTP response (network, proxy or timeout)")
}

; api.github.com's rate limit: reachable, and how many calls are left.
; @returns {Map} { result, sections? }
_HC_GithubAnswer(Status, Body) {
	if (Status != 200)
		return Map("result", _HC_HttpFailure(Status))
	Value := "HTTP 200"
	try {
		Core := JsonParse(Body)["resources"]["core"]
		Value := "HTTP 200, " . Core["remaining"] . "/" . Core["limit"]
	} catch as Err {
		LoggerWarn("Healthcheck", "GitHub's rate limit answer could not be read: {1}.", Err.Message)
	}
	return Map("result", Map("state", "ok"), "sections", Map("network", Map("github_api", Value)))
}

; The system proxy auto-config (PAC): configured, downloadable and usable by the
; managed downloader. The URL is read and fetched here but never reported.
; @param Run {Object}
; @param Config {Map} The schema's proxy_pac probe.
_HC_ProbePac(Run, Config) {
	Url := _HC_PacUrl()
	if (Url == "") {
		Started := A_TickCount
		_HC_ProbeStarted("proxy_pac", "no PAC configured")
		_HC_ProbeFinish(Run, "proxy_pac", Started, Map("state", "ok"), Map("network", Map("proxy_pac", "No PAC configured")))
		return
	}
	_HC_ProbeHttp(Run, "proxy_pac", Url, Map("User-Agent", HC_PROBE_USER_AGENT), Config["timeout_ms"], _HC_PacAnswer)
}

; The PAC URL the user's Windows settings name, "" when none is set.
; @returns {String}
_HC_PacUrl() {
	try return Trim(RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "AutoConfigURL"))
	return ""
}

; Judges normalized PAC text after its request has admitted the actual bytes.
; A String alone cannot prove encoding validity or the original byte count.
; @param Status {Integer}
; @param Body {String}
; @returns {Map} { result, sections? }
_HC_PacAnswer(Status, Body) {
	if (Status != 200)
		return Map("result", Map("state", "error", "detail", Status > 0 ? "PAC download: HTTP " . Status : "PAC download failed"))
	if (Body == "")
		return Map("result", Map("state", "error", "detail", "PAC is empty"))
	if !InStr(Body, "FindProxyForURL")
		return Map("result", Map("state", "error", "detail", "PAC does not define FindProxyForURL"))
	Value := "HTTP 200, " . StrLen(Body) . " characters, FindProxyForURL found"
	return Map("result", Map("state", "ok"), "sections", Map("network", Map("proxy_pac", Value)))
}

; Adapt only the real PAC request, including one created by an existing test
; factory. Other HTTP probes retain their two-argument interpreter and transport.
_HC_PacBindRequest(Request, Interpret) {
	if !(Request is CurlAsyncRequest) || Request.HasOwnProp("_HC_PacSource")
		|| Request.HasOwnProp("_OnManagedDone")
		throw Error("The PAC request completion already has another owner.")
	Request._HC_PacSource := 0
	Request.DefineProp("_OnManagedDone", {Call: _HC_PacManagedDone})
	return _HC_PacInterpret.Bind(Request, Interpret)
}

; The exact Job has settled before this callback. Capture its private RAW image
; before the superclass deletes it, then always delegate real settlement once.
; No transport prototype, decoding policy, response property or port is changed.
_HC_PacManagedDone(Request, ExitCode, Stdout, Stderr) {
	if ExitCode == 0 && Stderr == "" && !Request.Completed && !Request.Aborted
		&& Request.ManagedTransport && Request.OutputPath == "" {
		try Source := _HC_PacReadSource(Request.BodyPath)
		catch
			Source := Map("error", "PAC source bytes could not be read")
		if !Request.Completed && !Request.Aborted
			Request._HC_PacSource := Source
	}
	return CurlAsyncRequest.Prototype._OnManagedDone.Call(Request, ExitCode, Stdout, Stderr)
}

_HC_PacInterpret(Request, Interpret, Status, Body) {
	if Status != 200
		return Interpret.Call(Status, Body)
	Source := Request._HC_PacSource
	if !Request.Completed || Request.Aborted || !(Source is Map)
		return Map("result", Map("state", "error", "detail", "PAC source bytes were not admitted"))
	if Source.Has("error")
		return Map("result", Map("state", "error", "detail", Source["error"]))
	Answer := Interpret.Call(Status, Source["body"])
	if Answer["result"].Get("state", "") == "ok" {
		Value := "HTTP 200, " . Source["raw_bytes"] . " source bytes, " . Source["encoding"]
			. ", " . Source["normalized_bytes"] . " UTF-8 bytes, FindProxyForURL found"
		Answer["sections"]["network"]["proxy_pac"] := Value
	}
	return Answer
}

; The existing PAC limit counts source bytes including BOM, not UTF16 units.
; The source worker also bounds the UTF8 normalization of a UTF16 script.
_HC_PacReadSource(Path) {
	Maximum := 1048576
	Size := FileGetSize(Path)
	if Size > Maximum
		return Map("error", "PAC is over the 1048576 byte limit")
	Raw := FSReadBytesStrict(Path)
	if Raw.Size != Size
		return Map("error", "PAC source changed during validation")
	return _HC_PacDecodeSource(Raw, Maximum)
}

; Match Fetch's strict BOM handling on this same bounded RAW image. Generic
; ResponseEncodingValid remains a UTF8-only fact, including for valid UTF16 PAC.
_HC_PacDecodeSource(Raw, Maximum) {
	Count := Raw.Size
	if Count == 0
		return Map("error", "PAC is empty")
	if Count > Maximum
		return Map("error", "PAC is over the 1048576 byte limit")
	Offset := 0, Encoding := "UTF-8", BigEndian := false
	if Count >= 3 && NumGet(Raw, 0, "UChar") == 0xEF
		&& NumGet(Raw, 1, "UChar") == 0xBB && NumGet(Raw, 2, "UChar") == 0xBF
		Offset := 3
	else if Count >= 2 {
		First := NumGet(Raw, 0, "UChar"), Second := NumGet(Raw, 1, "UChar")
		if (First == 0xFF && Second == 0xFE) || (First == 0xFE && Second == 0xFF) {
			Offset := 2, BigEndian := First == 0xFE
			Encoding := BigEndian ? "UTF-16BE" : "UTF-16LE"
		}
	}
	Bytes := Count - Offset
	if Bytes == 0
		return Map("error", "PAC is empty")
	if Encoding == "UTF-8" {
		if !HTTPIsValidUtf8(Raw.Ptr + Offset, Bytes)
			return Map("error", "PAC encoding is invalid")
		Body := StrGet(Raw.Ptr + Offset, -Bytes, "UTF-8")
		NormalizedBytes := Bytes
	} else {
		if Mod(Bytes, 2)
			return Map("error", "PAC UTF-16 has an incomplete code unit")
		Units := Bytes // 2
		WidePtr := Raw.Ptr + Offset
		if BigEndian {
			Wide := Buffer(Bytes, 0)
			Loop Units {
				At := (A_Index - 1) * 2
				Unit := (NumGet(Raw, Offset + At, "UChar") << 8) | NumGet(Raw, Offset + At + 1, "UChar")
				NumPut("UShort", Unit, Wide, At)
			}
			WidePtr := Wide.Ptr
		}
		; Explicit UTF16 unit count and WC_ERR_INVALID_CHARS reject unpaired
		; surrogates before StrGet, which otherwise copies them unchanged.
		NormalizedBytes := DllCall("Kernel32\WideCharToMultiByte", "UInt", 65001, "UInt", 0x80,
			"Ptr", WidePtr, "Int", Units, "Ptr", 0, "Int", 0, "Ptr", 0, "Ptr", 0, "Int")
		if NormalizedBytes == 0
			return Map("error", "PAC encoding is invalid")
		if NormalizedBytes > Maximum
			return Map("error", "PAC is over the 1048576 byte limit")
		Body := StrGet(WidePtr, -Units, "UTF-16")
	}
	if RegExMatch(Body, "\x00")
		return Map("error", "PAC contains a null character")
	return Map("body", Body, "raw_bytes", Count, "normalized_bytes", NormalizedBytes, "encoding", Encoding)
}

; The local AI backend answers its version endpoint.
; @param Run {Object}
; @param Config {Map} The schema's ai_health probe.
_HC_ProbeAi(Run, Config) {
	global LLM_OLLAMA_BASE_URL
	Started := A_TickCount
	LoggerTrace("Healthcheck", "Probe 'ai_health' started…")
	Owner := _HealthCheck_LlmOwner()
	if !(Owner is Map) || !Owner["enabled"] {
		_HC_ProbeFinish(Run, "ai_health", Started, Map("state", "disabled"))
		return
	}
	Backend := String(Owner["backend"])
	if !Config["paths"].Has(Backend) || (Backend != "ollama") || !IsSet(LLM_OLLAMA_BASE_URL) {
		_HC_ProbeFinish(Run, "ai_health", Started, Map("state", "unsupported"))
		return
	}
	LoggerDone("Healthcheck", "Probe 'ai_health' handed to its HTTP request.")
	_HC_ProbeHttp(Run, "ai_health", LLM_OLLAMA_BASE_URL . Config["paths"][Backend], Map(),
		Config["timeout_ms"], _HC_AiAnswer)
}

; The AI backend's version answer.
; @returns {Map} { result, sections? }
_HC_AiAnswer(Status, Body) {
	if (Status < 200 || Status >= 300)
		return Map("result", _HC_HttpFailure(Status))
	Value := "HTTP " . Status
	try Value := "ollama " . JsonParse(Body)["version"]
	catch as Err
		LoggerDebug("Healthcheck", "The AI backend's answer carries no version: {1}.", Err.Message)
	return Map("result", Map("state", "ok"), "sections", Map("ai", Map("ai_health", Value)))
}





; =================================
; =================================
; ======= 3/ Processor Load =======
; =================================
; =================================

; The processor's load and this process's share of it, from two samples of
; the system and process times taken sample_ms apart.
; @param Run {Object}
; @param Config {Map} The schema's cpu_load probe.
_HC_ProbeCpu(Run, Config) {
	Started := A_TickCount
	_HC_ProbeStarted("cpu_load", "sampling " . Config["sample_ms"] . " ms")
	try {
		Before := _HC_CpuTimes()
	} catch as Err {
		_HC_ProbeFinish(Run, "cpu_load", Started, Map("state", "error", "detail", Err.Message))
		return
	}
	SetTimer(_HC_ProbeCpuSample.Bind(Run, Before, Started), -Config["sample_ms"])
}

; Takes the second sample and publishes the shares.
; @param Run {Object}
; @param Before {Map} The first sample.
; @param Started {Integer} A_TickCount at the start.
_HC_ProbeCpuSample(Run, Before, Started) {
	if Run.Cancelled {
		_HC_ProbeFinish(Run, "cpu_load", Started, Map("state", "cancelled"))
		return
	}
	try {
		Shares := HealthCheck_CpuShares(Before, _HC_CpuTimes())
	} catch as Err {
		_HC_ProbeFinish(Run, "cpu_load", Started, Map("state", "error", "detail", Err.Message))
		return
	}
	_HC_ProbeFinish(Run, "cpu_load", Started, Map("state", "ok"),
		Map("system", Map("cpu_usage", Shares["system"], "process_cpu", Shares["process"])))
}

; The machine's and this process's processor times, in 100 ns units.
; @returns {Map} { idle, kernel, user, process }
; @throws {OSError} When Windows refuses either query.
_HC_CpuTimes() {
	Idle := 0, Kernel := 0, User := 0
	if !DllCall("GetSystemTimes", "Int64*", &Idle, "Int64*", &Kernel, "Int64*", &User)
		throw OSError(A_LastError, -1, "GetSystemTimes")
	Created := 0, Exited := 0, OwnKernel := 0, OwnUser := 0
	if !DllCall("GetProcessTimes", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "Int64*", &Created
		, "Int64*", &Exited, "Int64*", &OwnKernel, "Int64*", &OwnUser)
		throw OSError(A_LastError, -1, "GetProcessTimes")
	return Map("idle", Idle, "kernel", Kernel, "user", User, "process", OwnKernel + OwnUser)
}

; The machine's load and this process's share of it between two samples, in
; percent of the whole machine and to a tenth. Windows counts the idle time
; inside the kernel time.
; @param Before {Map} From _HC_CpuTimes().
; @param After {Map}
; @returns {Map} { system, process }
; @throws {ValueError} When no processor time elapsed between the samples.
HealthCheck_CpuShares(Before, After) {
	Total := (After["kernel"] - Before["kernel"]) + (After["user"] - Before["user"])
	if (Total <= 0)
		throw ValueError("No processor time elapsed between the two samples.")
	Busy := Total - (After["idle"] - Before["idle"])
	return Map(
		"system",  Round(Busy * 1000 / Total) / 10,
		"process", Round((After["process"] - Before["process"]) * 1000 / Total) / 10)
}





; ==============================
; ==============================
; ======= 4/ Local Files =======
; ==============================
; ==============================

; Starts the configuration probe: the user's files are read and parsed on a
; timer after the snapshot is out, so phase A never pays for them. The answer
; is the two configuration sections, or a timeout when the collection outlasts
; the probe's deadline.
; @param Run {Object}
; @param Config {Map} The probe's schema entry.
; @param Overrides {Map|Integer} Replacements for tests: path_of, clock.
_HC_ProbeConfiguration(Run, Config, Overrides := 0) {
	Started := A_TickCount
	_HC_ProbeStarted("configuration", "timeout " . Config["timeout_ms"] . " ms")
	SetTimer(_HC_ProbeConfigurationRun.Bind(Run, Started, Overrides), -1)
}

; Runs the collection of the configuration probe and publishes its answer.
_HC_ProbeConfigurationRun(Run, Started, Overrides) {
	if Run.Cancelled {
		_HC_ProbeFinish(Run, "configuration", Started, Map("state", "cancelled"))
		return
	}
	try {
		Answer := HealthCheck_ConfigurationProbe(HealthCheck_Config()["schema"], Overrides)
	} catch as Err {
		LoggerWarn("Healthcheck", "The configuration probe failed: {1}", Err.Message)
		_HC_ProbeFinish(Run, "configuration", Started, Map("state", "error", "cleanup", "settled"))
		return
	}
	_HC_ProbeFinish(Run, "configuration", Started, Answer["result"], Answer["sections"])
}
