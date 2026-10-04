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
HealthCheck_StartProbes(Epoch, Schema, Publish) {
	global _HC_ProbeRun
	HealthCheck_CancelProbes()
	Run := { Epoch: Epoch, Cancelled: false, Requests: [], Publish: Publish }
	_HC_ProbeRun := Run
	Probes := Schema["probes"]
	Github := Probes["github_api"]
	_HC_ProbeHttp(Run, "github_api", Github["url"],
		Map("User-Agent", HC_PROBE_USER_AGENT, "Accept", "application/vnd.github+json"),
		Github["timeout_ms"], _HC_GithubAnswer)
	_HC_ProbeAi(Run, Probes["ai_health"])
	_HC_ProbeCpu(Run, Probes["cpu_load"])
}

; Cancels the current run: its curl children are stopped, its answers dropped.
HealthCheck_CancelProbes() {
	global _HC_ProbeRun
	if !IsObject(_HC_ProbeRun)
		return
	Run := _HC_ProbeRun
	_HC_ProbeRun := 0
	Run.Cancelled := true
	for Request in Run.Requests {
		if !Request.Abort()
			LoggerError("Healthcheck", "A diagnostics probe's curl child refused to stop; its cleanup is retained.")
	}
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
	Result["ms"] := TickElapsed(Started, NowTick?)
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
	; curl ignores the Windows proxy: resolve it first (static settings answer at
	; once, a PAC script in a bounded child) and re-enter with the answer
	SystemProxy_ResolveAsync([Url], (Resolved) => _HC_ProbeSend(Run, Id, Url, Headers, TimeoutMs, Interpret,
		Started, Resolved[Url]))
}

; Sends the request of an HTTP probe through curl and arms its poll.
_HC_ProbeSend(Run, Id, Url, Headers, TimeoutMs, Interpret, Started, Proxy) {
	if Run.Cancelled {
		_HC_ProbeFinish(Run, Id, Started, Map("state", "cancelled"))
		return
	}
	try {
		Request := CurlAsyncRequest()
		Request.Open("GET", Url, true)
		for Name, Value in Headers
			Request.SetRequestHeader(Name, Value)
		Request.SetProxy(Proxy)
		; One budget for the whole request: half to connect, the rest to answer
		Request.SetTimeouts(TimeoutMs // 2, 0, 0, TimeoutMs - TimeoutMs // 2)
		Run.Requests.Push(Request)
		Request.Send()
	} catch as Err {
		_HC_ProbeFinish(Run, Id, Started, Map("state", "error", "detail", Err.Message))
		return
	}
	_HC_ProbeArmPoll(Run, Id, Request, Interpret, Started, TimeoutMs)
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
		_HC_ProbeFinish(Run, Id, Started, Answer["result"], Answer.Get("sections", 0), NowTick?)
		return
	}
	; curl's own max-time ends the child first; this bound only covers a child
	; that never reports back
	if (TickElapsed(Started, NowTick?) > TimeoutMs + 1000) {
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
