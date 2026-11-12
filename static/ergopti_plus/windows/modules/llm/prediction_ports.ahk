; modules/llm/prediction_ports.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine — Ports
; DESCRIPTION:
; The three outside services the prediction engine drives, as the contracts of
; _shared/lua/llm/request_plan/ports.lua: a TimerScheduler that arms the
; debounce and the deferred retries, an HttpClient that sends the remote
; inference requests, and a TooltipRenderer that shows the predictions and
; their info bar. Production runs on the default owners below; a test hands the
; engine recording fakes of them and gets the same decisions out.
;
; FEATURES & RATIONALE:
; 1. One owner per port, checked when it is installed: a missing method raises
;    naming it ("TimerScheduler lacks: Cancel") instead of failing late inside a
;    timer thread or a network callback.
; 2. The default owners make exactly the calls the engine made before the ports
;    existed: SetTimer, LLM_RemoteGenerate_Async and LLM_RemoteCancelAllAsync,
;    and the LLM_Tooltip_* surface. Nothing changes until a caller installs a
;    replacement, and only LLM_Engine_SetPort installs one.
; 3. HTTP injection reaches the remote inference requests only, as on Linux:
;    Ollama's clients and every non-inference request keep their transports.
;
; Included by modules/llm/prediction_engine.ahk before the engine sections.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ The Contracts =======
; ================================
; ================================

; Required methods of each port, in the order the contract lists them. The
; engine relies on these signatures:
;   TimerScheduler.After(Callback, DelayMs): fires Callback once after DelayMs;
;     arming the same callback again replaces its pending firing (SetTimer's rule).
;   TimerScheduler.Cancel(Callback): stops a pending firing; harmless after it.
;   HttpClient.Post(Entry, SystemPrompt, Context, Temperature, OnSuccess, OnFail,
;     Tail, MaxTokens, Kind, TimeoutMs, CurrentFn) -> request id: sends one
;     inference request (LLM_RemoteGenerate_Async's signature); exactly one of the
;     callbacks fires, OnSuccess with the text and its usage.
;   HttpClient.Cancel(SpareKind): abandons every request but those of SpareKind
;     ("" spares none); their callbacks do not fire.
;   TooltipRenderer.SetDisplayOpts(Opts): the footer and info bar of the next paint,
;     with "info_parts", the info bar pieces, and "info_model", their joined text.
;   TooltipRenderer.Show(Slots, Active, IsFinal, Meta) -> receipt: paints the
;     predictions; a positive receipt proves the pixels were committed.
;   TooltipRenderer.ShowLoading(Meta): paints the loading placeholder.
;   TooltipRenderer.IsVisible() / IsLoading(): what is on screen now.
;   TooltipRenderer.PresentedToken(): the presentation on screen, for Hide.
;   TooltipRenderer.Hide(Token): removes that exact presentation, nothing newer.
;   TooltipRenderer.MarkChainStart() / MarkChainTiming(NowTick): the request
;     chain timings the info bar prints.
global LLM_ENGINE_PORT_CONTRACTS := Map(
	"timer", Map("name", "TimerScheduler", "methods", ["After", "Cancel"]),
	"http", Map("name", "HttpClient", "methods", ["Post", "Cancel"]),
	"tooltip", Map("name", "TooltipRenderer", "methods", ["SetDisplayOpts", "Show", "ShowLoading",
		"IsVisible", "IsLoading", "PresentedToken", "Hide", "MarkChainStart", "MarkChainTiming"])
)

/**
 * Checks that an owner offers every method of a port's contract.
 * @param {String} PortName "timer", "http" or "tooltip".
 * @param {Object} Owner The candidate owner.
 * @returns {Object} The same owner, for chaining.
 */
LLM_Engine_CheckPort(PortName, Owner) {
	global LLM_ENGINE_PORT_CONTRACTS
	if !(PortName is String) || !LLM_ENGINE_PORT_CONTRACTS.Has(PortName)
		throw ValueError("Unknown prediction engine port.", -1, String(PortName))
	Contract := LLM_ENGINE_PORT_CONTRACTS[PortName]
	if !IsObject(Owner)
		throw TypeError(Contract["name"] . " must be an object.", -1)
	Missing := ""
	for Method in Contract["methods"] {
		if !HasMethod(Owner, Method)
			Missing .= (Missing == "" ? "" : ", ") . Method
	}
	if Missing != ""
		throw TypeError(Contract["name"] . " lacks: " . Missing, -1)
	return Owner
}





; =====================================
; =====================================
; ======= 2/ The Default Owners =======
; =====================================
; =====================================

; The native one-shot timers the engine always armed.
class LLMEngineNativeTimer {
	After(Callback, DelayMs) {
		SetTimer(Callback, -DelayMs)
	}

	Cancel(Callback) {
		SetTimer(Callback, 0)
	}
}

; The remote inference client: api_remote.ahk's managed transport.
class LLMEngineRemoteHttp {
	Post(Entry, SystemPrompt, Context, Temperature, OnSuccess, OnFail, Tail := "",
			MaxTokens := "", Kind := "", TimeoutMs := 0, CurrentFn := 0) {
		return LLM_RemoteGenerate_Async(Entry, SystemPrompt, Context, Temperature, OnSuccess, OnFail,
			Tail, MaxTokens, Kind, TimeoutMs, CurrentFn)
	}

	Cancel(SpareKind := "") {
		return LLM_RemoteCancelAllAsync(SpareKind)
	}
}

; The prediction tooltip of ui/tooltip/tooltip_llm.ahk.
class LLMEngineTooltip {
	SetDisplayOpts(Opts) {
		return LLM_Tooltip_SetDisplayOpts(Opts)
	}

	Show(Slots, Active, IsFinal, Meta) {
		return LLM_Tooltip_Show(Slots, Active, IsFinal, Meta)
	}

	ShowLoading(Meta) {
		return LLM_Tooltip_ShowLoading(Meta)
	}

	IsVisible() {
		return LLM_Tooltip_IsVisible()
	}

	IsLoading() {
		return LLM_Tooltip_IsLoading()
	}

	PresentedToken() {
		return LLM_Tooltip_GetPresentedToken()
	}

	Hide(Token) {
		return LLM_Tooltip_HideExact(Token)
	}

	MarkChainStart() {
		return LLM_Tooltip_SetChainStart()
	}

	MarkChainTiming(NowTick) {
		return LLM_Tooltip_MarkChainTimingOnly(NowTick)
	}
}

global LLM_ENGINE_DEFAULT_PORTS := Map(
	"timer", LLM_Engine_CheckPort("timer", LLMEngineNativeTimer()),
	"http", LLM_Engine_CheckPort("http", LLMEngineRemoteHttp()),
	"tooltip", LLM_Engine_CheckPort("tooltip", LLMEngineTooltip())
)





; ====================================
; ====================================
; ======= 3/ Port Installation =======
; ====================================
; ====================================

/**
 * The owners installed over the defaults, by port name. Empty in production:
 * only LLM_Engine_SetPort writes it, and the default owners exist from load.
 * @returns {Map}
 */
_LLM_Engine_Installed() {
	static Installed := Map()
	return Installed
}

/**
 * Installs an owner for one port, or puts the default back with 0. The caller
 * that installs an owner restores what this returns once it is done.
 * @param {String} PortName "timer", "http" or "tooltip".
 * @param {Object|Integer} Owner The replacement, checked against the contract,
 *     or 0 for the default owner.
 * @returns {Object|Integer} The owner installed before, 0 for the default.
 */
LLM_Engine_SetPort(PortName, Owner) {
	global LLM_ENGINE_PORT_CONTRACTS
	Installed := _LLM_Engine_Installed()
	if !(PortName is String) || !LLM_ENGINE_PORT_CONTRACTS.Has(PortName)
		throw ValueError("Unknown prediction engine port.", -1, String(PortName))
	if !(Owner is Integer && Owner == 0)
		LLM_Engine_CheckPort(PortName, Owner)
	Previous := Installed.Get(PortName, 0)
	if (Owner is Integer) {
		if Installed.Has(PortName)
			Installed.Delete(PortName)
	} else
		Installed[PortName] := Owner
	return Previous
}

/**
 * The owner a port call goes to now: the installed one, else the default.
 * @param {String} PortName "timer", "http" or "tooltip".
 * @returns {Object}
 */
_LLM_Engine_Port(PortName) {
	global LLM_ENGINE_DEFAULT_PORTS
	Installed := _LLM_Engine_Installed()
	if Installed.Has(PortName)
		return Installed[PortName]
	return LLM_ENGINE_DEFAULT_PORTS[PortName]
}
