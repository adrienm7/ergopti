; modules/llm/request_plan.ahk

; ==============================================================================
; MODULE: LLM Request Plan — Debounce, Rate Floor and Batching
; DESCRIPTION:
; The AutoHotkey twin of _shared/lua/llm/request_plan/debounce.lua and
; batching.lua: the pure decisions of the prediction orchestration. The engine
; feeds it events and the clock, and owns the native timers and the backend calls.
;
; FEATURES & RATIONALE:
; 1. No IO and no clock: a transcript of events replays identically on every
;    driver (_shared/tests/corpus/llm/request_plan_debounce_vectors.json and
;    request_plan_batching_vectors.json).
; 2. One token per armed timer: a timer that fired after a newer arm or a cancel
;    answers stale and is dropped, so a superseded keystroke never sends.
; 3. "Never" is a negative debounce, an explicit request is never held by the
;    floor, a word end is instant in live mode too, and the last request time is
;    one value. A difference between drivers is a red vector, not an option.
; 4. The floor is a port: the plan asks FloorMsFn (the user's
;    llm.trigger.min_request_interval_ms) and never reads the configuration.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk

; The debounce that turns the automatic trigger off: the stored value of
; llm.trigger.debounce_ms. Any negative number given to the plan means the same.
global LLM_REQUEST_PLAN_NEVER_MS := -1

/** Throws unless Value is a non-negative number. AHK numbers are always finite. */
_LLM_RequestPlanRequireDelay(Value, Name) {
	if !(Value is Number) || Value < 0
		throw ValueError(Name . " must be a non-negative finite number")
}

/** Throws unless Value is the 0 or 1 of an AutoHotkey boolean. */
_LLM_RequestPlanRequireBool(Value, Name) {
	if !(Value is Integer) || (Value != 0 && Value != 1)
		throw ValueError(Name . " must be a boolean")
}

class LLMRequestPlan {
	; Closed causes an input event may carry, and the log label of every arm,
	; shared so that every driver logs the same words.
	static CAUSES := Map("typing", true, "explicit_trigger", true, "expiry", true, "override", true)
	static REASON := Map("inactivity", "Inactivity", "word_end", "Word-end", "live", "Live",
		"explicit_trigger", "Explicit-trigger", "expiry", "Hotstring-expiry",
		"live_expiry", "Live hotstring-expiry", "override", "Override")

	/** @param {Func} FloorMsFn Returns the user's minimum interval, read at each dispatch. */
	__New(FloorMsFn) {
		if !HasMethod(FloorMsFn, "Call")
			throw TypeError("the request plan needs a floor_ms function")
		this.FloorMsFn := FloorMsFn
		this.DebounceMs := ""
		this.InstantOnWordEnd := false
		this.Enabled := false
		this.LiveDebounceMs := ""
		this.Pending := 0
		this.NextToken := 1
		this.LastSentMs := ""
	}

	/**
	 * Applies runtime settings; a key left out keeps its value.
	 * @param {Map} Settings enabled, debounce_ms, instant_on_word_end and
	 *     live_debounce_ms. A live_debounce_ms of false (0) turns live mode off:
	 *     no driver accepts 0 as a live debounce, live.json requires the debounce range.
	 */
	Configure(Settings) {
		if !(Settings is Map)
			throw TypeError("configure needs a settings table")
		if Settings.Has("enabled") {
			_LLM_RequestPlanRequireBool(Settings["enabled"], "enabled")
			this.Enabled := Settings["enabled"]
		}
		if Settings.Has(ConfigLeaf.DEBOUNCE_MS) {
			if !(Settings[ConfigLeaf.DEBOUNCE_MS] is Number)
				throw ValueError("debounce_ms must be a number")
			this.DebounceMs := Settings[ConfigLeaf.DEBOUNCE_MS]
		}
		if Settings.Has(ConfigLeaf.INSTANT_ON_WORD_END) {
			_LLM_RequestPlanRequireBool(Settings[ConfigLeaf.INSTANT_ON_WORD_END], ConfigLeaf.INSTANT_ON_WORD_END)
			this.InstantOnWordEnd := Settings[ConfigLeaf.INSTANT_ON_WORD_END]
		}
		if Settings.Has("live_debounce_ms") {
			_LLM_RequestPlanRequireDelay(Settings["live_debounce_ms"], "the live debounce")
			this.LiveDebounceMs := Settings["live_debounce_ms"] == 0 ? "" : Settings["live_debounce_ms"]
		}
		return []
	}

	_Arm(Decisions, DelayMs, Why) {
		if IsObject(this.Pending)
			Decisions.Push(Map("action", "cancel", "token", this.Pending["token"]))
		Token := this.NextToken
		this.NextToken += 1
		this.Pending := Map("token", Token, "why", Why)
		Decisions.Push(Map("action", "arm", "token", Token, "delay_ms", DelayMs, "why", Why))
		return Decisions
	}

	/**
	 * Decides what one input event does to the debounce timer.
	 * @param {Map} Event cause, ends_word (typing) and delay_ms (override).
	 * @returns {Array} An arm (after a cancel of the pending one) or a skip.
	 */
	OnInput(Event) {
		Reason := LLMRequestPlan.REASON
		if !(Event is Map) || !LLMRequestPlan.CAUSES.Has(Event.Get("cause", ""))
			throw ValueError("input event needs a known cause")
		Cause := Event["cause"]
		Live := this.LiveDebounceMs != ""
		if !this.Enabled
			return [Map("action", "skip", "why", "disabled")]
		if Cause == "expiry"
			return this._Arm([], 0, Live ? Reason["live_expiry"] : Reason["expiry"])
		if this.DebounceMs == ""
			throw ValueError("debounce_ms was never configured")
		if Cause == "explicit_trigger"
			return this._Arm([], Max(0, this.DebounceMs), Reason["explicit_trigger"])
		; "Never" turns the automatic trigger off; live mode is an explicit request for it.
		if this.DebounceMs < 0 && !Live
			return [Map("action", "skip", "why", "automatic trigger off")]
		if Cause == "override" {
			_LLM_RequestPlanRequireDelay(Event.Get("delay_ms", ""), "the override delay")
			return this._Arm([], Event["delay_ms"], Reason["override"])
		}
		EndsWord := Event.Get("ends_word", false) == true
		if Live && !(EndsWord && this.InstantOnWordEnd)
			return this._Arm([], this.LiveDebounceMs, Reason["live"])
		if EndsWord && this.InstantOnWordEnd
			return this._Arm([], 0, Reason["word_end"])
		return this._Arm([], this.DebounceMs, Reason["inactivity"])
	}

	/** @returns {Array} One cancel of the pending timer, or none. */
	OnCancel() {
		if !IsObject(this.Pending)
			return []
		Token := this.Pending["token"]
		this.Pending := 0
		return [Map("action", "cancel", "token", Token)]
	}

	/**
	 * Answers a native timer that fired.
	 * @param {Integer} Token The token its arm decision carried.
	 * @returns {Array} One fire when it is the pending timer, else one stale.
	 */
	OnTimer(Token) {
		if IsObject(this.Pending) && this.Pending["token"] == Token {
			Why := this.Pending["why"]
			this.Pending := 0
			return [Map("action", "fire", "token", Token, "why", Why)]
		}
		return [Map("action", "stale", "token", Token)]
	}

	/**
	 * Decides whether a request may go to its backend now. An explicit request
	 * is never held, and neither are the later variants of one request: only
	 * the first call of an automatic request waits.
	 * @param {Map} Request explicit, and variant (1-based).
	 * @param {Number} NowMs The caller's monotonic clock in milliseconds.
	 * @returns {Array} One send, or one defer with the milliseconds to wait.
	 */
	OnDispatch(Request, NowMs) {
		if !(Request is Map)
			throw TypeError("a dispatch needs a request table")
		if !(NowMs is Number)
			throw TypeError("a dispatch needs the clock")
		if Request.Get("explicit", false) == true || Request.Get("variant", 1) > 1
			return [Map("action", "send")]
		if this.LastSentMs == ""
			return [Map("action", "send")]
		Interval := this.FloorMsFn.Call()
		_LLM_RequestPlanRequireDelay(Interval, "the request floor")
		Wait := this.LastSentMs + Interval - NowMs
		if Wait > 0
			return [Map("action", "defer", "delay_ms", Wait, "why", "rate floor")]
		return [Map("action", "send")]
	}

	/**
	 * Decides what pressing an explicit shortcut does while its previous request
	 * may be in flight: that one is superseded and the new one is never delayed.
	 * @param {Map} Request key (the shortcut's identity) and in_flight.
	 * @returns {Array} A supersede of the key when in flight, then one send.
	 */
	OnExplicit(Request) {
		if !(Request is Map) || !(Request.Get("key", "") is String) || Request.Get("key", "") == ""
			throw ValueError("an explicit request needs a shortcut key")
		if !Request.Has("in_flight") || !(Request["in_flight"] is Integer)
				|| (Request["in_flight"] != 0 && Request["in_flight"] != 1)
			throw ValueError("an explicit request needs in_flight")
		if Request["in_flight"]
			return [Map("action", "supersede", "key", Request["key"]), Map("action", "send")]
		return [Map("action", "send")]
	}

	/** Records that a request went to its backend. */
	OnSent(NowMs) {
		if !(NowMs is Number)
			throw TypeError("a sent request needs the clock")
		this.LastSentMs := NowMs
		return []
	}

	/** Forgets every request time and the pending timer (engine re-initialisation). */
	Reset() {
		this.Pending := 0
		this.LastSentMs := ""
		return []
	}
}

/**
 * Plans the backend calls of one prediction request: a batch profile asks once
 * for every variant, any other asks once per variant.
 * @param {Boolean} BatchProfile Whether the profile asks for a batch.
 * @param {Integer} Requested Predictions the request asks for (at least 1).
 * @returns {Map} mode ("batch" or "sequential"), calls and per_call.
 */
LLM_RequestPlanBatching(BatchProfile, Requested) {
	_LLM_RequestPlanRequireBool(BatchProfile, "batch_profile")
	if !(Requested is Integer) || Requested < 1
		throw ValueError("requested must be a whole number from 1")
	if BatchProfile && Requested > 1
		return Map("mode", "batch", "calls", 1, "per_call", Requested)
	return Map("mode", "sequential", "calls", Requested, "per_call", 1)
}
