; ui/tooltip/llm.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Hotstring Tooltip / LLM Multi-slot Tooltip
; DESCRIPTION:
; The LLM prediction tooltip backed by the shared Gui engine: multi-slot state, show/hide/loading, slot text building, display-option setters, the chain-timing model, footer/info/nav-hint rendering and the LLM Gui builder.
;
; Split out of the former infra/tooltip.ahk (the module split); see ui/tooltip/init.ahk
; for the module overview. Functions and globals are hoisted, so load order
; across the tooltip/*.ahk files is irrelevant.
; ==============================================================================





; =========================================
; =========================================
; ======= 3/ LLM Multi-slot Tooltip =======
; =========================================
; =========================================

; The active surface is the single owner of LLM presentation state. Slots,
; active index, request focus and metric lifecycle live in
; _TooltipActiveSurface.LlmPresented and are published by the same pointer swap
; as the pixels. Keeping parallel globals here previously let a B render expose
; its semantics while A was still visible.
global _LLM_TooltipMetricQueue := []
; Minimum on-screen time (ms) for a freshly-rendered prediction. Within this
; window the prediction is immune to INCIDENTAL dismissals: the shared hotstring
; surface resetting its buffer (ResetBuf / LookupNoMatch / a new lookup NewShow),
; an in-flight keystroke that was already travelling when the slow model finally
; answered, or stray pointer drift. Without it a prediction that lands mid-typing
; is clobbered within tens of milliseconds and never gets seen — the
; "n'a même pas le temps d'apparaître" bug. Unlike macOS, the AHK prediction
; shares one Gui surface with the hotstring autocomplete tooltip, so it is exposed
; to that surface's far more aggressive per-keystroke lifecycle; this window is the
; equaliser. Deliberate user actions (Tab/Enter accept, Escape) and driver suspend
; bypass it. Tunable; 600 ms is comfortably above human reaction time.
global _LLM_TOOLTIP_MIN_DISPLAY_MS := 600
; Spinner label used when the i18n layer is not up yet (t is unset during the
; earliest boot window). It carries NO language on purpose: the previous
; fallback was hardcoded French, so a user on any of the other 20 locales who
; triggered a prediction in that window was shown French. An hourglass says the
; same thing in every one of them.
global _LLM_TOOLTIP_LOADING_FALLBACK := "⏳"
; Footer state — mirrors tooltip_llm.lua info/hint rows.
global _LLM_Tooltip_ShowInfoBar := false
global _LLM_Tooltip_InfoModel   := ""
global _LLM_Tooltip_FooterSlots := 1
global _LLM_Tooltip_NavMods     := ""
global _LLM_Tooltip_PredIndent  := 0
global _LLM_Tooltip_ValMods     := "alt"
global _LLM_Tooltip_Chain := {
	StartTick: 0, FirstShowTick: 0, LastUpdateTick: 0, TtftMs: 0, TtltMs: 0,
}

_LLM_TooltipPresentedFromSurface(Surface) {
	if !IsObject(Surface) or !Surface.HasOwnProp("LlmPresented")
		return 0
	return IsObject(Surface.LlmPresented) ? Surface.LlmPresented : 0
}

_LLM_TooltipCloneAcceptSource(Source) {
	if !(Source is Map)
		return Map("hwnd", 0, "control", 0, "request_id", 0)
	return Map(
		"hwnd", Source.Get("hwnd", 0),
		"control", Source.Get("control", 0),
		"request_id", Source.Get("request_id", 0)
	)
}

; Queue only immutable payloads while the pixel transaction is Critical. The
; actual keylogger/file work is drained later on a fresh timer thread.
_LLM_TooltipQueueMetricUnsafe(Kind, Lifecycle) {
	global _LLM_TooltipMetricQueue
	if !IsObject(Lifecycle)
		return false
	Slots := (Lifecycle.Slots is Array) ? Lifecycle.Slots.Clone() : []
	_LLM_TooltipMetricQueue.Push({
		Kind: Kind,
		AppName: Lifecycle.AppName,
		Slots: Slots,
		Count: Slots.Length
	})
	return true
}

_LLM_TooltipScheduleMetricDrain() {
	SetTimer(_LLM_TooltipDrainMetricQueue, -1)
}

_LLM_TooltipDrainMetricQueue() {
	global _LLM_TooltipMetricQueue
	Batch := []
	PreviousCritical := Critical("On")
	try {
		if (_LLM_TooltipMetricQueue.Length == 0)
			return
		Batch := _LLM_TooltipMetricQueue
		_LLM_TooltipMetricQueue := []
	} finally {
		Critical(PreviousCritical)
	}
	for Event in Batch {
		try {
			if (Event.Kind == "suggested" and IsSet(KL_LogLlmSuggested))
				KL_LogLlmSuggested(Event.AppName, Event.Count)
			else if (Event.Kind == "dismissed" and IsSet(KL_LogLlmDismissed))
				KL_LogLlmDismissed(Event.AppName, Event.Slots)
		} catch Error as Err {
			try LoggerError("LLM.tt", "LLM lifecycle metric '{1}' failed: {2}.",
				Event.Kind, Err.Message)
		}
	}
}

; Retire a surface-owned offer exactly once. A same-offer navigation render
; shares the lifecycle object and therefore does not dismiss/re-suggest it.
_LLM_TooltipRetireSurfaceRecord(Surface, ReplacementLifecycle := 0) {
	Record := _LLM_TooltipPresentedFromSurface(Surface)
	if !IsObject(Record) or !Record.HasOwnProp("Lifecycle")
		return 0
	Lifecycle := Record.Lifecycle
	if (IsObject(ReplacementLifecycle)
		and ObjPtr(Lifecycle) == ObjPtr(ReplacementLifecycle))
		return Record
	if (Lifecycle.Suggested and Lifecycle.Outcome == "") {
		Lifecycle.Outcome := "dismissed"
		_LLM_TooltipQueueMetricUnsafe("dismissed", Lifecycle)
	}
	return Record
}

; Attach the full semantics to the detached candidate BEFORE the one active
; surface assignment. No back-reference is stored, avoiding a ref-count cycle.
_LLM_TooltipRenderGuardIsCurrent(PresentationMeta) {
	Meta := (PresentationMeta is Map) ? PresentationMeta : Map()
	if !Meta.Has("render_guard")
		return true
	Guard := Meta["render_guard"]
	if !HasMethod(Guard, "Call")
		return false
	try Current := Guard.Call()
	catch
		return false
	return (Current is Integer) && Current == true
}

_LLM_TooltipCommitSurfaceState(slots, active_idx, RenderGeneration,
		PresentationMeta, SurfaceToken, RetiredSurface) {
	global _TooltipGeneration
	if !IsObject(SurfaceToken)
		throw TypeError("LLM state commit requires a detached surface.")
	if (RenderGeneration != _TooltipGeneration
		or SurfaceToken.Generation != RenderGeneration)
		throw Error("LLM state commit lost its render owner.")
	if !(slots is Array) or slots.Length == 0
		throw ValueError("LLM prediction state requires at least one slot.")
	Meta := (PresentationMeta is Map) ? PresentationMeta : Map()
	; The engine request may be cancelled while detached GUI/UIA work yields.
	; Recheck its immutable identity under the presenter's Critical transaction,
	; before reading or mutating A's lifecycle and before attaching B.
	if !_LLM_TooltipRenderGuardIsCurrent(Meta)
		throw TooltipLlmStaleRenderError(
			"LLM render request was superseded before pixel publication.")
	; A candidate may have completed its detached GUI build before an external
	; Suspend or lifecycle fence began. The common presenter invokes this commit
	; under Critical, so reject before resolving/reusing the visible lifecycle:
	; BeginSurfaceSwap is a necessary native backstop but is too late to roll back
	; mutations of A's shared acceptance semantics.
	if A_IsSuspended
			|| (IsSet(LLM_NavEventOwner_LifecycleBarrierActive)
				&& LLM_NavEventOwner_LifecycleBarrierActive())
		throw TooltipNavOwnerRetryError(
			"LLM state commit crossed the navigation lifecycle fence.")
	OfferId := Meta.Get("offer_id", 0)
	Previous := _LLM_TooltipPresentedFromSurface(RetiredSurface)
	; A terminal visible prediction owns the surface until its exact hide retires
	; those pixels. This also blocks a different offer which finished building
	; after Tab's native CAS; such a candidate must not recreate native ownership
	; in the acceptance-to-hide window.
	if IsObject(Previous) and Previous.Kind == "prediction" {
		if !Previous.HasOwnProp("Lifecycle")
				or !IsObject(Previous.Lifecycle)
				or !Previous.Lifecycle.HasOwnProp("Outcome")
			throw TypeError("Visible LLM lifecycle is missing its terminal outcome.")
		if Previous.Lifecycle.Outcome != ""
			throw TooltipLlmTerminalOutcomeError(
				"Visible LLM lifecycle already reached a terminal outcome.")
	}
	Lifecycle := Meta.Get("lifecycle", 0)
	if !IsObject(Lifecycle) and IsObject(Previous)
			and Previous.Kind == "prediction"
			and OfferId != 0 and Previous.Lifecycle.OfferId == OfferId
		Lifecycle := Previous.Lifecycle
	if !IsObject(Lifecycle) {
		Lifecycle := {
			OfferId: OfferId,
			AcceptSource: _LLM_TooltipCloneAcceptSource(
				Meta.Get("accept_source", "")),
			AppName: Meta.Get("app_name", ""),
			Slots: slots.Clone(),
			Suggested: false,
			Outcome: "",
			TimeoutOrigin: 0,
			TimeoutDurationMs: 0
		}
	}
	; A Tab claim linearizes acceptance by detaching the native owner before text
	; injection. A same-offer render which was already building may reach this
	; commit afterward; it must lose before it can rewrite lifecycle semantics or
	; attach a fresh native token to its detached surface.
	if !Lifecycle.HasOwnProp("Outcome")
		throw TypeError("LLM lifecycle is missing its terminal outcome.")
	if Lifecycle.Outcome != ""
		throw TooltipLlmTerminalOutcomeError(
			"LLM lifecycle already reached a terminal outcome.")
	; Stage every replacement value before touching a lifecycle which may still
	; describe visible pixels. An expired or malformed same-offer candidate must
	; not rewrite A's acceptance source or metric attribution before it loses.
	NextAcceptSource := _LLM_TooltipCloneAcceptSource(
		Meta.Get("accept_source", Lifecycle.AcceptSource))
	NextAppName := Meta.Get("app_name", Lifecycle.AppName)
	NextLifecycleSlots := slots.Clone()
	NextRecordSlots := slots.Clone()
	IsFinalValue := Meta.Get("is_final", false)
	IsFinal := (IsFinalValue is Integer and IsFinalValue == true)
	TimeoutMs := Meta.Get("timeout_ms", 0)
	if !(TimeoutMs is Number)
		TimeoutMs := 0
	TimeoutMs := Max(0, Round(TimeoutMs))
	NextTimeoutOrigin := Lifecycle.TimeoutOrigin
	NextTimeoutDurationMs := Lifecycle.TimeoutDurationMs
	if (TimeoutMs > 0 and NextTimeoutDurationMs == 0) {
		NextTimeoutOrigin := A_TickCount
		NextTimeoutDurationMs := TimeoutMs
	}
	RemainingMs := NextTimeoutDurationMs > 0
		? TickRemaining(NextTimeoutOrigin, NextTimeoutDurationMs) : 0
	if (NextTimeoutDurationMs > 0 and RemainingMs <= 0)
		throw Error("LLM presentation expired before pixel publication.")
	NextActiveIdx := Max(1, Min(Integer(active_idx), slots.Length))
	ExactIndexValue := Meta.Get("nav_owner_exact_index", false)
	Record := {
		Kind: "prediction",
		Slots: NextRecordSlots,
		ActiveIdx: NextActiveIdx,
		NavOwnerRequireExactIndex:
			(ExactIndexValue is Integer) && ExactIndexValue == true,
		Lifecycle: Lifecycle,
		IsFinal: IsFinal,
		ShownAt: NextTimeoutOrigin,
		Generation: RenderGeneration,
		TimeoutRemainingMs: RemainingMs
	}
	; All candidate validation is complete. Publish the shared lifecycle fields as
	; one final semantic step immediately before attaching the detached surface.
	Lifecycle.AcceptSource := NextAcceptSource
	Lifecycle.AppName := NextAppName
	Lifecycle.Slots := NextLifecycleSlots
	Lifecycle.TimeoutOrigin := NextTimeoutOrigin
	Lifecycle.TimeoutDurationMs := NextTimeoutDurationMs
	SurfaceToken.LlmPresented := Record
	SurfaceToken.RenderedActiveIdx := Record.ActiveIdx
	if IsSet(LLM_NavEventOwner_AttachRecord)
		LLM_NavEventOwner_AttachRecord(Record, SurfaceToken)
	return true
}

; Suggested means the final pixels survived reveal AND the common publication
; oracle. Attaching the candidate record is not enough: a refused publication
; must never contribute a denominator for something the user could not see.
_LLM_TooltipMarkSurfaceSuggested(Surface) {
	Record := _LLM_TooltipPresentedFromSurface(Surface)
	if !IsObject(Record) or Record.Kind != "prediction" or !Record.IsFinal
		return false
	Lifecycle := Record.Lifecycle
	if Lifecycle.Suggested or Lifecycle.Outcome != ""
		return false
	Lifecycle.Suggested := true
	_LLM_TooltipQueueMetricUnsafe("suggested", Lifecycle)
	return true
}

_LLM_TooltipCommitLoadingState(PresentationMeta, SurfaceToken,
		RetiredSurface) {
	global _TooltipGeneration
	Meta := (PresentationMeta is Map) ? PresentationMeta : Map()
	if !_LLM_TooltipRenderGuardIsCurrent(Meta)
		throw TooltipLlmStaleRenderError(
			"LLM loading request was superseded before pixel publication.")
	if A_IsSuspended
			|| (IsSet(LLM_NavEventOwner_LifecycleBarrierActive)
				&& LLM_NavEventOwner_LifecycleBarrierActive())
		throw TooltipNavOwnerRetryError(
			"LLM loading commit crossed the navigation lifecycle fence.")
	if !IsObject(SurfaceToken)
		throw TypeError("LLM loading state requires a detached surface.")
	if (SurfaceToken.Generation != _TooltipGeneration)
		throw Error("LLM loading state lost its render owner.")
	Lifecycle := {
		OfferId: Meta.Get("offer_id", 0),
		AcceptSource: _LLM_TooltipCloneAcceptSource(
			Meta.Get("accept_source", "")),
		AppName: Meta.Get("app_name", ""),
		Slots: [], Suggested: false, Outcome: "",
		TimeoutOrigin: 0, TimeoutDurationMs: 0
	}
	SurfaceToken.LlmPresented := {
		Kind: "loading", Slots: [], ActiveIdx: 0,
		Lifecycle: Lifecycle, IsFinal: false, ShownAt: 0,
		Generation: SurfaceToken.Generation, TimeoutRemainingMs: 0
	}
	return true
}

_LLM_TooltipScheduleReservationDeadlineRetry(ExpectedSurface,
		ScheduleFn := 0) {
	global _TooltipActiveSurface, _TOOLTIP_OWNER_RETRY_MS
	StillOwnsPixels := false
	PreviousCritical := Critical("On")
	try {
		StillOwnsPixels := IsObject(ExpectedSurface)
			&& IsObject(_TooltipActiveSurface)
			&& ObjPtr(ExpectedSurface) == ObjPtr(_TooltipActiveSurface)
	} finally Critical(PreviousCritical)
	if !StillOwnsPixels
		return false
	Callback := _LLM_TooltipReservationDeadlineFn.Bind(
		ExpectedSurface, ScheduleFn)
	if HasMethod(ScheduleFn, "Call")
		ScheduleFn.Call(Callback, -_TOOLTIP_OWNER_RETRY_MS)
	else
		SetTimer(Callback, -_TOOLTIP_OWNER_RETRY_MS)
	return true
}

_LLM_TooltipReservationDeadlineFn(ExpectedSurface, ScheduleFn := 0) {
	if A_IsSuspended
		return _LLM_TooltipScheduleReservationDeadlineRetry(
			ExpectedSurface, ScheduleFn)
	if TooltipHide("TimerFn", true, unset, ExpectedSurface)
		return true
	return _LLM_TooltipScheduleReservationDeadlineRetry(
		ExpectedSurface, ScheduleFn)
}

; The canonical timer is generation-owned and must be cancelled when B reserves
; a new generation. Preserve A's already-published absolute deadline with an
; exact-surface one-shot; it no-ops if B wins and retries only while A still owns
; the pixels. This prevents a later stale-B rejection from making A immortal.
_LLM_TooltipPreserveActiveDeadline() {
	global _TooltipActiveSurface
	Surface := _TooltipActiveSurface
	Record := _LLM_TooltipPresentedFromSurface(Surface)
	if !IsObject(Surface) || !IsObject(Record)
			|| Record.Kind != "prediction"
			|| !Record.HasOwnProp("Lifecycle")
			|| !IsObject(Record.Lifecycle)
		return false
	Lifecycle := Record.Lifecycle
	if !Lifecycle.HasOwnProp("TimeoutDurationMs")
			|| !Lifecycle.HasOwnProp("TimeoutOrigin")
			|| !(Lifecycle.TimeoutDurationMs is Number)
			|| Lifecycle.TimeoutDurationMs <= 0
		return false
	RemainingMs := TickRemaining(
		Lifecycle.TimeoutOrigin, Lifecycle.TimeoutDurationMs)
	SetTimer(_LLM_TooltipReservationDeadlineFn.Bind(Surface),
		-Max(1, RemainingMs))
	return true
}

; Atomically reserves the generation/request owner for one detached LLM paint.
; A lifecycle fence must win before it can cancel the currently visible
; prediction's timer or invalidate its request serial.
_LLM_TooltipReserveLlmRender(PresentationMeta := 0) {
    global _TooltipGeneration, _TooltipTimerGeneration, _TooltipTimerFn
    global _TooltipDequeueItems, _TooltipDequeueActive
    global _TooltipDequeueDeadlineTimer
	global _TooltipPendingRequest, _TooltipRequestSerial
	PreviousCritical := Critical("On")
	try {
		if !_LLM_TooltipRenderGuardIsCurrent(PresentationMeta)
			return 0
		if A_IsSuspended
				|| (IsSet(LLM_NavEventOwner_LifecycleBarrierActive)
					&& LLM_NavEventOwner_LifecycleBarrierActive())
			return 0
		OldRequest := _TooltipPendingRequest
		if (IsObject(OldRequest) and OldRequest.HasOwnProp("TimerFn")
			and IsObject(OldRequest.TimerFn))
			SetTimer(OldRequest.TimerFn, 0)
		_TooltipPendingRequest := 0
		_TooltipRequestSerial += 1
		RenderRequestSerial := _TooltipRequestSerial
		_LLM_TooltipPreserveActiveDeadline()
        RenderGeneration := _TooltipGeneration + 1
        _TooltipGeneration := RenderGeneration
        _TooltipTimerGeneration := RenderGeneration
        SetTimer(_TooltipTimerFn, 0)
        if IsObject(_TooltipDequeueDeadlineTimer)
            SetTimer(_TooltipDequeueDeadlineTimer, 0)
        _TooltipDequeueDeadlineTimer := 0
        _TooltipDequeueItems := 0
        _TooltipDequeueActive := false
		return Map(
			"generation", RenderGeneration,
			"request_serial", RenderRequestSerial)
	} finally {
		Critical(PreviousCritical)
	}
}

; Show the LLM multi-slot tooltip using the shared Gui engine.
; Each slot may be a plain string (streaming) or a diff object:
;   { Text, Chunks: [{type:"equal"|"insert", text}], NextWords, HasCorrections }
; Active slot: equal chunks in green, NextWords in orange, insert in white.
; Inactive slots: full Text in gray.
; @returns {Integer} Positive render generation on committed paint, otherwise 0.
LLM_TooltipShow(payload, active := 1, is_final := false,
		PresentationMeta := 0) {
	; No prediction tooltip while paused — Ergopti_OnSuspendEnter already hid any
	; visible one, this refuses late async renders.
	if A_IsSuspended
		return false

	slots := []
	if (Type(payload) == "Array") {
		for s in payload
			slots.Push(s)
	} else if (Type(payload) == "String") {
		if (payload == "")
			return false
		slots.Push(payload)
	} else {
		return false
	}

	if is_final {
		while (slots.Length > 0 and _LLM_SlotIsEmpty(slots[slots.Length]))
			slots.Pop()
		filtered := []
		for _, s in slots {
			if !_LLM_SlotIsEmpty(s)
				filtered.Push(s)
		}
		slots := filtered
	}
	if (slots.Length == 0) {
		LLM_TooltipHide()
		return false
	}

	; macOS parity: keep the compact violet « Génération en cours… » indicator
	; until at least one slot carries real text. Intermediate placeholder paints
	; (DispatchBatch / variant reveal) used to swap in the full LLM chrome with
	; footer + info-bar width reservation, which stretched a short label across
	; the whole tooltip frame on Windows 11.
	if (!is_final) {
		all_placeholder := true
		for _, s in slots {
			if !_LLM_SlotIsPlaceholder(s) {
				all_placeholder := false
				break
			}
		}
		if all_placeholder {
			LLM_TooltipShowLoading(PresentationMeta)
			return false
		}
	}
	active_idx := Max(1, Min(Integer(active), slots.Length))
	Meta := Map()
	if (PresentationMeta is Map) {
		for Key, Value in PresentationMeta
			Meta[Key] := Value
	}
	Meta["is_final"] := is_final ? true : false
	; Resolve the configured lifetime before any GUI/UIA work. The exact value is
	; attached to the candidate and armed by the common surface commit, so the
	; 3-second generic safety timer is never a prediction's temporary owner.
	if !Meta.Has("timeout_ms") {
		global UI_LLM_TIMEOUT_SEC
		llm_timeout_sec := UI_LLM_TIMEOUT_SEC
		try {
			_llm_ov := HotstringsResolve("llm_prediction", "")
			if _llm_ov.HasOverride
				llm_timeout_sec := _llm_ov.Delay
		}
		Meta["timeout_ms"] := Round(
			Max(0.05, llm_timeout_sec - 0.2) * 1000)
	}
    ; Reserve render ownership and cancel the older hotstring dequeue cycle in
    ; one short transaction. Slots/Visible/ShownAt deliberately remain owned by
    ; the current pixels until the detached replacement wins the common commit.
	Reservation := _LLM_TooltipReserveLlmRender(Meta)
	if !(Reservation is Map)
		return false
	RenderGeneration := Reservation["generation"]
	RenderRequestSerial := Reservation["request_serial"]

	; Detect whether any slot carries diff chunks — if so use the rich Gui path.
	has_chunks := false
	for _, s in slots {
		if IsObject(s) and s.HasOwnProp("Chunks") and s.Chunks.Length > 0 {
			has_chunks := true
			break
		}
	}

	LLM_TooltipRefreshChainTiming()
	; A formatting error must be logged and leave a clean hidden state. The rich
	; builder is detached, so it never destroys the currently active surface; its
	; own catch disposes a partially-built candidate before this outer lifecycle
	; handler clears the prediction flags.
	try {
		if !_TooltipBuildGuiLlm(slots, active_idx, RenderGeneration, Meta,
				RenderRequestSerial) {
			LLM_TooltipHide(false, RenderGeneration, RenderRequestSerial)
            return false
		}
	} catch as _llm_build_err {
		if _llm_build_err is TooltipLlmTerminalOutcomeError
				|| _llm_build_err is TooltipLlmStaleRenderError
			return false
		if _llm_build_err is TooltipNavOwnerRetryError {
			if IsSet(LLM_NavEventOwner_ScheduleDrain)
				LLM_NavEventOwner_ScheduleDrain()
			return false
		}
		try LoggerError("LLM.tt", "Prediction render failed — hiding cleanly: {1} | file={2} line={3}.",
			_llm_build_err.Message,
			(_llm_build_err.HasOwnProp("File") ? _llm_build_err.File : "?"),
			(_llm_build_err.HasOwnProp("Line") ? _llm_build_err.Line : "?"))
		LLM_TooltipHide(false, RenderGeneration, RenderRequestSerial)
        return false
    }

	try LoggerDebug("LLM.tt", "SHOW prediction: {1} slot(s), is_final={2}, auto-hide in {3}ms (gen {4}).",
		slots.Length, (is_final ? "true" : "false"),
		Meta["timeout_ms"], RenderGeneration)
	return RenderGeneration
}

; A caller that attaches state to a paint must compare the returned generation
; under its own short Critical transaction. The Gui build itself stays outside
; Critical because caret/UIA resolution may block or pump messages.
LLM_TooltipRenderGenerationIsCurrent(RenderGeneration) {
	global _TooltipGeneration
	return (RenderGeneration is Integer and RenderGeneration > 0
		and RenderGeneration == _TooltipGeneration)
}

; Purple in-flight indicator — macOS ``show_loading`` parity (ai_loading tint).
; Stays visible until replaced by ``LLM_TooltipShow`` or ``LLM_TooltipHide``.
LLM_TooltipShowLoading(PresentationMeta := 0) {
	if A_IsSuspended
		return false
	label := (IsSet(t)) ? t("llm.generating") : _LLM_TOOLTIP_LOADING_FALLBACK
	accent := _TooltipResolveAccent("ai_loading")
	; DurationSec 0 + ArmSafety false: the spinner must live until the prediction
	; lands or LLM_TooltipHide runs — inference legitimately outlasts the 3 s
	; _TOOLTIP_SAFETY_SEC deadline (Ollama cold start alone is granted 8 s).
	; This MUST be an argument: rendering is deferred by TOOLTIP_RENDER_DEBOUNCE_MS,
	; so cancelling _TooltipTimerFn here would run 75 ms before the timer is armed
	; and silently do nothing, letting the spinner vanish mid-inference.
	Meta := (PresentationMeta is Map) ? PresentationMeta : Map()
	CommitFn := _LLM_TooltipCommitLoadingState.Bind(Meta)
	; Every loading ingress, including an all-placeholder streaming partial, must
	; preserve the real prediction which already owns the pixels. Keep this guard
	; in the same short transaction as TooltipShow's request publication so the
	; loading candidate cannot win between an earlier policy check and its timer.
	PreviousCritical := Critical("On")
	try {
		if !_LLM_TooltipRenderGuardIsCurrent(Meta)
			return false
		if A_IsSuspended
				|| (IsSet(LLM_NavEventOwner_LifecycleBarrierActive)
					&& LLM_NavEventOwner_LifecycleBarrierActive())
				|| LLM_TooltipOwnsSurface()
			return false
		Shown := TooltipShow([{
			Text: label, ColorHex: accent, IsDimmed: false, DurationSec: 0
		}], 0, false, CommitFn)
	} finally Critical(PreviousCritical)
	if !Shown
		return false
	try LoggerDebug("LLM.tt", "SHOW loading (no auto-hide).")
	return true
}

LLM_TooltipHide(accepted := false, ExpectedGeneration := unset,
		ExpectedRequestSerial := unset, ExpectedRecord := 0) {
	Presentation := _LLM_TooltipGetCurrentPresentation()
	Record := IsObject(Presentation) ? Presentation.Record : 0
	if IsObject(ExpectedRecord) {
		if !IsObject(Record)
			return false
		SameRecord := ObjPtr(Record) == ObjPtr(ExpectedRecord)
		SameLifecycle := (Record.HasOwnProp("Lifecycle")
			and ExpectedRecord.HasOwnProp("Lifecycle")
			and IsObject(Record.Lifecycle)
			and IsObject(ExpectedRecord.Lifecycle)
			and ObjPtr(Record.Lifecycle) == ObjPtr(ExpectedRecord.Lifecycle))
		if !SameRecord and !SameLifecycle
			return false
	}
	WasVisible := IsObject(Record)
	WasLoading := WasVisible and Record.Kind == "loading"
	if (accepted and WasVisible)
		LLM_TooltipFinalizeAcceptance(Record.Lifecycle, true)
	Hidden := false
	if IsObject(ExpectedRecord) {
		Hidden := TooltipHide("LLM", true, Record.Generation,
			Presentation.Surface)
	} else if (IsSet(ExpectedGeneration) and IsSet(ExpectedRequestSerial)) {
		Hidden := TooltipHide("LLM", true, ExpectedGeneration,
			unset, ExpectedRequestSerial)
	} else if IsSet(ExpectedGeneration) {
		Hidden := TooltipHide("LLM", true, ExpectedGeneration)
	} else {
		Hidden := TooltipHide("LLM", true)
	}
	if !Hidden
		return false
	_LLM_TooltipResetChain()
	_LLM_TooltipScheduleMetricDrain()
	if WasVisible
		try LoggerDebug("LLM.tt", "HIDE prediction via LLM_TooltipHide (accepted={1}, was visible={2} loading={3}).",
			(accepted ? "true" : "false"),
			(WasVisible ? "true" : "false"), (WasLoading ? "true" : "false"))
	return true
}

_LLM_TooltipGetCurrentPresentation() {
	global _TooltipActiveSurface
	if !IsSet(_TooltipActiveSurface)
		return 0
	PreviousCritical := Critical("On")
	try {
		Surface := _TooltipActiveSurface
		Record := _LLM_TooltipPresentedFromSurface(Surface)
		if !IsObject(Record) or !IsObject(Surface)
			return 0
		; _TooltipGeneration reserves detached work before GUI/UIA yields. It may
		; already belong to candidate B while active surface A is still the only
		; visible/acceptable owner. The active pointer — plus record/surface
		; identity — is the presentation fence; comparing it to the build counter
		; would make Tab silently stop working for A during every B build.
		if (Record.Generation != Surface.Generation)
			return 0
		return { Surface: Surface, Record: Record }
	} finally {
		Critical(PreviousCritical)
	}
}

_LLM_TooltipGetCurrentRecord() {
	Presentation := _LLM_TooltipGetCurrentPresentation()
	return IsObject(Presentation) ? Presentation.Record : 0
}

_LLM_TooltipPresentationIndexIsPainted(Presentation) {
	if !IsObject(Presentation) || !IsObject(Presentation.Record)
			|| !IsObject(Presentation.Surface)
			|| !Presentation.Surface.HasOwnProp("RenderedActiveIdx")
		return false
	RenderedIdx := Presentation.Surface.RenderedActiveIdx
	return (RenderedIdx is Integer)
		&& (Presentation.Record.ActiveIdx is Integer)
		&& RenderedIdx == Presentation.Record.ActiveIdx
}

LLM_TooltipGetText() {
	; Reachable from a PARSE-TIME #HotIf (`Tab::` in menu_llm/tab_accept.ahk),
	; which can run before the active surface exists. A missing/loading surface
	; is deliberately non-acceptable even if a retired prediction still owns
	; objects waiting for deferred destruction.
	Presentation := _LLM_TooltipGetCurrentPresentation()
	Record := IsObject(Presentation) ? Presentation.Record : 0
	if !IsObject(Record) or Record.Kind != "prediction"
		return ""
	if IsSet(LLM_NavEventOwner_SyncRecord)
			&& !LLM_NavEventOwner_SyncRecord(Record)
		return ""
	if !_LLM_TooltipPresentationIndexIsPainted(Presentation)
		return ""
	if (Record.ActiveIdx < 1 or Record.ActiveIdx > Record.Slots.Length)
		return ""
	return _LLM_SlotGetText(Record.Slots[Record.ActiveIdx])
}

LLM_TooltipGetSlots() {
	Record := _LLM_TooltipGetCurrentRecord()
	if IsObject(Record) && IsSet(LLM_NavEventOwner_SyncRecord)
		LLM_NavEventOwner_SyncRecord(Record)
	return IsObject(Record) ? Record.Slots.Clone() : []
}

LLM_TooltipGetActiveIdx() {
	Record := _LLM_TooltipGetCurrentRecord()
	if IsObject(Record) && IsSet(LLM_NavEventOwner_SyncRecord)
		LLM_NavEventOwner_SyncRecord(Record)
	return IsObject(Record) ? Record.ActiveIdx : 1
}

LLM_TooltipIsVisible() {
	return IsObject(_LLM_TooltipGetCurrentRecord())
}

; True whenever a real prediction occupies the shared surface (NOT the loading
; spinner), for the WHOLE time it is displayed. While true, the hotstring
; autocomplete lifecycle (TooltipShow lookups, ResetBuf / LookupNoMatch hides)
; must leave the surface alone — only the user, the prediction's own auto-hide
; timer, or suspend may tear it down. Distinct from the grace window, which is the
; brief minimum-display span the BRIDGE consults to debounce user dismissal.
LLM_TooltipOwnsSurface() {
	Record := _LLM_TooltipGetCurrentRecord()
	return IsObject(Record) and Record.Kind == "prediction"
}

; True while a real prediction is still inside its minimum-display window. The
; bridge's keystroke / pointer dismissal consults this so a prediction is never
; dismissed by the user the instant it appears. False during loading and once the
; window has elapsed, so normal dismiss behaviour resumes afterwards.
LLM_TooltipInGracePeriod() {
	global _LLM_TOOLTIP_MIN_DISPLAY_MS
	Record := _LLM_TooltipGetCurrentRecord()
	if !IsObject(Record) or Record.Kind != "prediction" or Record.ShownAt == 0
		return false
	return (A_TickCount - (Record.ShownAt) & 0xFFFFFFFF)
		< _LLM_TOOLTIP_MIN_DISPLAY_MS
}

LLM_TooltipIsLoading() {
	Record := _LLM_TooltipGetCurrentRecord()
	return IsObject(Record) and Record.Kind == "loading"
}

LLM_TooltipSetActiveIdx(idx) {
	Record := _LLM_TooltipGetCurrentRecord()
	if !IsObject(Record) or Record.Kind != "prediction"
		return false
	NextIdx := Max(1, Min(idx, Record.Slots.Length))
	Meta := Map(
		"offer_id", Record.Lifecycle.OfferId,
		"lifecycle", Record.Lifecycle,
		"accept_source", Record.Lifecycle.AcceptSource,
		"app_name", Record.Lifecycle.AppName,
		"timeout_ms", Record.Lifecycle.TimeoutDurationMs
	)
	; Active A remains the sole visible/acceptable record during B's detached
	; build. The index changes only with B's surface pointer publication.
	return LLM_TooltipShow(Record.Slots, NextIdx, Record.IsFinal, Meta)
}

; A native receipt has already committed the semantic index against
; ExpectedRecord before the digit was suppressed. This function is therefore
; repaint-only: it may lose to a newer surface generation, but it must never
; fall back to whichever record happens to be current when the wake is drained.
_LLM_TooltipRenderOwnedNavigation(ExpectedRecord, ExpectedSurface) {
	global _TooltipActiveSurface
	if !IsObject(ExpectedRecord) || !IsObject(ExpectedSurface)
		return false
	PreviousCritical := Critical("On")
	try {
		Current := _LLM_TooltipPresentedFromSurface(_TooltipActiveSurface)
		if !IsObject(Current)
				|| ObjPtr(Current) != ObjPtr(ExpectedRecord)
				|| !IsObject(_TooltipActiveSurface)
				|| ObjPtr(_TooltipActiveSurface) != ObjPtr(ExpectedSurface)
			return false
		if !(ExpectedRecord.Slots is Array)
				|| ExpectedRecord.ActiveIdx < 1
				|| ExpectedRecord.ActiveIdx > ExpectedRecord.Slots.Length
			return false
		Slots := ExpectedRecord.Slots.Clone()
		ActiveIdx := ExpectedRecord.ActiveIdx
		IsFinal := ExpectedRecord.IsFinal
		Meta := Map(
			"offer_id", ExpectedRecord.Lifecycle.OfferId,
			"lifecycle", ExpectedRecord.Lifecycle,
			"accept_source", ExpectedRecord.Lifecycle.AcceptSource,
			"app_name", ExpectedRecord.Lifecycle.AppName,
			"timeout_ms", ExpectedRecord.Lifecycle.TimeoutDurationMs,
			"nav_owner_exact_index", true)
	} finally Critical(PreviousCritical)
	return LLM_TooltipShow(Slots, ActiveIdx, IsFinal, Meta)
}

LLM_TooltipGetPresentedToken() {
	return _LLM_TooltipGetCurrentRecord()
}

LLM_TooltipGetAcceptSnapshot() {
	Presentation := _LLM_TooltipGetCurrentPresentation()
	Record := IsObject(Presentation) ? Presentation.Record : 0
	if !IsObject(Record) or Record.Kind != "prediction"
		return 0
	if IsSet(LLM_NavEventOwner_SyncRecord)
			&& !LLM_NavEventOwner_SyncRecord(Record)
		return 0
	if !_LLM_TooltipPresentationIndexIsPainted(Presentation)
		return 0
	if (Record.ActiveIdx < 1 or Record.ActiveIdx > Record.Slots.Length)
		return 0
	Text := _LLM_SlotGetText(Record.Slots[Record.ActiveIdx])
	if (Text == "" or Record.Lifecycle.Outcome != "")
		return 0
	return {
		Record: Record,
		Surface: Presentation.Surface,
		Lifecycle: Record.Lifecycle,
		Text: Text,
		Slots: Record.Slots.Clone(),
		ActiveIdx: Record.ActiveIdx,
		AcceptSource: _LLM_TooltipCloneAcceptSource(
			Record.Lifecycle.AcceptSource),
		AppName: Record.Lifecycle.AppName
	}
}

LLM_TooltipClaimAcceptance(ExpectedRecord, ExpectedSurface := 0,
		ExpectedActiveIdx := 0) {
	global _TooltipActiveSurface
	if !IsObject(ExpectedRecord) || !IsObject(ExpectedSurface)
			|| !(ExpectedActiveIdx is Integer)
		return 0
	PreviousCritical := Critical("On")
	try {
		Current := _LLM_TooltipPresentedFromSurface(_TooltipActiveSurface)
		if !IsObject(Current) || ObjPtr(Current) != ObjPtr(ExpectedRecord)
				|| !IsObject(_TooltipActiveSurface)
				|| ObjPtr(_TooltipActiveSurface) != ObjPtr(ExpectedSurface)
			return 0
		if (Current.Kind != "prediction"
				|| Current.Lifecycle.Outcome != ""
				|| !(Current.Slots is Array)
				|| ExpectedActiveIdx < 1
				|| ExpectedActiveIdx > Current.Slots.Length)
			return 0
		if !ExpectedSurface.HasOwnProp("RenderedActiveIdx")
				|| !(ExpectedSurface.RenderedActiveIdx is Integer)
				|| ExpectedSurface.RenderedActiveIdx != ExpectedActiveIdx
			return 0
		if IsSet(LLM_NavEventOwner_ClaimAcceptance)
				&& !LLM_NavEventOwner_ClaimAcceptance(
					ExpectedRecord, ExpectedSurface, ExpectedActiveIdx)
			return 0
		Current.Lifecycle.Outcome := "claimed"
		return Current.Lifecycle
	} finally {
		Critical(PreviousCritical)
	}
}

LLM_TooltipFinalizeAcceptance(Lifecycle, Accepted) {
	if !IsObject(Lifecycle)
		return false
	PreviousCritical := Critical("On")
	try {
		if (Lifecycle.Outcome != "claimed")
			return false
		if Accepted {
			Lifecycle.Outcome := "accepted"
		} else {
			Lifecycle.Outcome := "dismissed"
			if Lifecycle.Suggested
				_LLM_TooltipQueueMetricUnsafe("dismissed", Lifecycle)
		}
	} finally {
		Critical(PreviousCritical)
	}
	_LLM_TooltipScheduleMetricDrain()
	return true
}



; =================================
; ===== 3.1) LLM slot helpers =====
; =================================

_LLM_SlotIsPlaceholder(slot) {
	global UI_LLM_SLOT_PLACEHOLDER, LLM_TOOLTIP_PLACEHOLDER
	ph := UI_LLM_SLOT_PLACEHOLDER != "" ? UI_LLM_SLOT_PLACEHOLDER : LLM_TOOLTIP_PLACEHOLDER
	txt := _LLM_SlotGetText(slot)
	if (txt = "")
		return true
	if (ph != "" and txt = ph)
		return true
	; HS streaming reserve char and common ellipsis variants.
	if (txt = "…" or txt = "...")
		return true
	return !!(txt ~= "^\s+$")
}

_LLM_AllSlotsPlaceholder(slots) {
	for s in slots {
		if !_LLM_SlotIsPlaceholder(s)
			return false
	}
	return slots.Length > 0
}

_LLM_SlotIsEmpty(slot) {
	return _LLM_SlotIsPlaceholder(slot)
}

_LLM_SlotGetText(slot) {
	if (Type(slot) == "String")
		return slot
	if IsObject(slot) and slot.HasOwnProp("Text")
		return slot.Text
	return ""
}

_LLM_RepeatChar(ch, count) {
	if (count <= 0)
		return ""
	out := ""
	loop count
		out .= ch
	return out
}

; Prefixes for active/inactive rows — mirrors tooltip_llm.lua assemble_blocks.
_LLM_GetActivePrefix(slotCount) {
	global _LLM_Tooltip_PredIndent, UI_LLM_ACTIVE_PREFIX
	sparkle := UI_LLM_ACTIVE_PREFIX
	indent := Integer(_LLM_Tooltip_PredIndent)
	if (slotCount >= 2 and indent > 0)
		return _LLM_RepeatChar(" ", indent) . sparkle
	return sparkle
}

_LLM_GetInactivePrefix(slotCount) {
	global _LLM_Tooltip_PredIndent, UI_LLM_INACTIVE_ALIGN_CHAR
	indent := Integer(_LLM_Tooltip_PredIndent)
	if (indent < 0 and indent > -3)
		return _LLM_RepeatChar(" ", -indent)
	if (indent <= -3)
		return _LLM_GetActivePrefix(slotCount) . _LLM_RepeatChar(" ", Max(0, -indent - 3))
	align := UI_LLM_INACTIVE_ALIGN_CHAR
	return (indent > -3) ? align : ""
}

_LLM_FormatValModifiers(valMods) {
	if (valMods = "" or valMods = "none")
		return ""
	sym := valMods
	; NOTE: a 4th positional value here lands on StrReplace's &OutputVarCount param,
	; which must be a VariableRef — passing an Integer (e.g. ``true``) throws
	; "Parameter #5 of StrReplace requires a variable reference". The replacement is
	; case-insensitive by default, which also tolerates "Alt"/"ALT" from config.
	sym := StrReplace(sym, "cmd", "⌘")
	sym := StrReplace(sym, "ctrl", "⌃")
	sym := StrReplace(sym, "alt", "⌥")
	sym := StrReplace(sym, "shift", "⇧")
	return StrReplace(sym, "+", "")
}

_LLM_BuildShortcutSuffix(idx, slotCount, valMods := "") {
	global UI_LLM_SHORTCUT_LABEL_GAP
	if (slotCount <= 1)
		return ""
	sym := _LLM_FormatValModifiers(valMods)
	if (sym = "")
		return ""
	gap := UI_LLM_SHORTCUT_LABEL_GAP
	if (idx <= 9)
		return gap . sym . idx
	if (idx = 10)
		return gap . sym . "0"
	return ""
}

; Build the display string for a slot row (used by the plain-string path).
_LLM_SlotBuildText(slot, is_active, slotIdx := 1, slotCount := 1) {
	global LLM_TOOLTIP_PLACEHOLDER, LLM_TOOLTIP_TAB_SUFFIX, _LLM_Tooltip_ValMods
	prefix := is_active ? _LLM_GetActivePrefix(slotCount) : _LLM_GetInactivePrefix(slotCount)
	shortcut := _LLM_BuildShortcutSuffix(slotIdx, slotCount, _LLM_Tooltip_ValMods)
	if _LLM_SlotIsEmpty(slot)
		return prefix . LLM_TOOLTIP_PLACEHOLDER . shortcut
	txt    := _LLM_SlotGetText(slot)
	suffix := is_active ? LLM_TOOLTIP_TAB_SUFFIX : ""
	return prefix . txt . suffix . shortcut
}

LLM_TooltipSetDisplayOpts(opts) {
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel
	global _LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods
	global _LLM_Tooltip_PredIndent, _LLM_Tooltip_ValMods
	if !(opts is Map)
		return
	_LLM_Tooltip_ShowInfoBar := !!(opts.Has("show_info_bar") and opts["show_info_bar"])
	_LLM_Tooltip_InfoModel := (opts.Has("info_model") and opts["info_model"] != "")
		? opts["info_model"] : ""
	_LLM_Tooltip_FooterSlots := (opts.Has("slot_count") and opts["slot_count"] > 0)
		? Integer(opts["slot_count"]) : 1
	_LLM_Tooltip_NavMods := (opts.Has("nav_modifiers") and opts["nav_modifiers"] != "")
		? opts["nav_modifiers"] : ""
	if opts.Has("pred_indent")
		_LLM_Tooltip_PredIndent := Integer(opts["pred_indent"])
	if opts.Has("val_modifiers")
		_LLM_Tooltip_ValMods := opts["val_modifiers"]
}

LLM_TooltipSetChainStart() {
	global _LLM_Tooltip_Chain
	_LLM_Tooltip_Chain.StartTick := A_TickCount
	_LLM_Tooltip_Chain.FirstShowTick := 0
	_LLM_Tooltip_Chain.LastUpdateTick := 0
	_LLM_Tooltip_Chain.TtftMs := 0
	_LLM_Tooltip_Chain.TtltMs := 0
}

LLM_TooltipRefreshChainTiming() {
	global _LLM_Tooltip_Chain
	if !_LLM_Tooltip_Chain.StartTick
		return
	now := A_TickCount
	_LLM_Tooltip_Chain.LastUpdateTick := now
	if !_LLM_Tooltip_Chain.FirstShowTick {
		_LLM_Tooltip_Chain.FirstShowTick := now
		_LLM_Tooltip_Chain.TtftMs := now - _LLM_Tooltip_Chain.StartTick
	}
}

; Freezes the chain timings WITHOUT repainting. Callers invoke it just before the
; render that should display those timings, so the info bar picks TTLT up on that
; render instead of costing a second full rebuild.
;
; This is where AHK and macOS legitimately diverge. The Hammerspoon renderer's
; set_timing() rewrites a single canvas element, so re-rendering after the fact is
; nearly free there. AHK has no partial-update path: _TooltipBuildGuiLlm tears the
; windows down and rebuilds them, measures every row, repaints the border DIB and
; pushes a layered-window update. Doing that twice back to back — once for the
; prediction, once only to print a duration — doubled the cost of the most visible
; moment in the whole LLM flow.
;
; NowTick is supplied by the caller rather than read here so the instant that
; counts as "chain finished" belongs to the caller, not to this helper.
LLM_TooltipMarkChainTimingOnly(NowTick) {
	global _LLM_Tooltip_Chain
	if !_LLM_Tooltip_Chain.StartTick
		return
	final := _LLM_Tooltip_Chain.LastUpdateTick ? _LLM_Tooltip_Chain.LastUpdateTick : NowTick
	_LLM_Tooltip_Chain.TtltMs := final - _LLM_Tooltip_Chain.StartTick
	if !_LLM_Tooltip_Chain.TtftMs {
		_LLM_Tooltip_Chain.TtftMs := _LLM_Tooltip_Chain.TtltMs
		; Claim the first-show slot as well, and do NOT drop this line. On the
		; batch path every intermediate render is a placeholder, so LLM_TooltipShow
		; bails into its loading branch before it ever refreshes the chain:
		; FirstShowTick is still 0 at this point. The render that FOLLOWS this call
		; would then take the first-show branch in LLM_TooltipRefreshChainTiming and
		; overwrite TtftMs with a later value — printing an info bar whose TTFT is
		; greater than the TTLT frozen here.
		if !_LLM_Tooltip_Chain.FirstShowTick
			_LLM_Tooltip_Chain.FirstShowTick := final
	}
}

_LLM_TooltipResetChain() {
	global _LLM_Tooltip_Chain
	_LLM_Tooltip_Chain.StartTick := 0
	_LLM_Tooltip_Chain.FirstShowTick := 0
	_LLM_Tooltip_Chain.LastUpdateTick := 0
	_LLM_Tooltip_Chain.TtftMs := 0
	_LLM_Tooltip_Chain.TtltMs := 0
}

_LLM_FormatInfoLine(modelInfo, ttftMs := "", ttltMs := "", forSizing := false) {
	hasModel := (modelInfo != "")
	hasTtft := (IsNumber(ttftMs) and ttftMs > 0)
	hasTtlt := (IsNumber(ttltMs) and ttltMs > 0)
	if forSizing {
		if !hasTtft
			ttftMs := 9999, hasTtft := true
		if !hasTtlt
			ttltMs := 9999, hasTtlt := true
	}
	if (!hasModel and !hasTtft and !hasTtlt)
		return ""
	pieces := []
	if hasModel
		pieces.Push(modelInfo)
	if hasTtft {
		timing := Format("⏱ {:.2f} s", ttftMs / 1000)
		if hasTtlt
			timing .= Format(" — {:.2f} s", ttltMs / 1000)
		pieces.Push(timing)
	} else if hasTtlt
		pieces.Push(Format("⏱ {:.2f} s", ttltMs / 1000))
	out := ""
	for i, p in pieces
		out .= (i = 1) ? p : " — " . p
	return out
}

_LLM_BuildNavHint(slotCount, navMods := "") {
	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_HINT_ACCEPT_SINGLE, UI_LLM_HINT_NAV_LEFT
	global UI_LLM_HINT_NAV_RIGHT, UI_LLM_HINT_ACCEPT_CENTER, UI_LLM_HINT_ARROW_LEFT
	global UI_LLM_HINT_ARROW_RIGHT, UI_LLM_HINT_OR, UI_LLM_HINT_ARROW_SEP_LEFT
	global UI_LLM_HINT_ARROW_SEP_RIGHT
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	acceptSingle := UI_LLM_HINT_ACCEPT_SINGLE
	if (slotCount <= 1)
		return acceptSingle
	navStr := navMods
	if (navStr = "" or navStr = "none")
		navStr := ""
	else
		navStr := _LLM_FormatValModifiers(navStr)
	hintLeft := UI_LLM_HINT_NAV_LEFT
	hintRight := UI_LLM_HINT_NAV_RIGHT
	hintOr := UI_LLM_HINT_OR
	arrL := UI_LLM_HINT_ARROW_LEFT
	arrR := UI_LLM_HINT_ARROW_RIGHT
	if (navStr != "") {
		hintLeft .= hintOr . navStr . " + " . arrL
		hintRight .= hintOr . navStr . " + " . arrR
	}
	sepL := UI_LLM_HINT_ARROW_SEP_LEFT
	sepR := UI_LLM_HINT_ARROW_SEP_RIGHT
	acceptCenter := UI_LLM_HINT_ACCEPT_CENTER
	return hintLeft . spaceDiv . sepL . spaceDiv . acceptCenter . spaceDiv . sepR . spaceDiv . hintRight
}

_LLM_TooltipAppendFooter(G, &TotalH, TotalW, bgHex) {
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel, _LLM_Tooltip_FooterSlots
	global _LLM_Tooltip_NavMods, _LLM_Tooltip_Chain
	global _TOOLTIP_FONT_NAME, _TOOLTIP_HINT_COLOR_HEX, _TOOLTIP_INFO_COLOR_HEX
	global _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_INFO_FONT_SIZE, _TOOLTIP_PADDING_Y
	global _TOOLTIP_PADDING_X, _TOOLTIP_LINE_SPACING, _TOOLTIP_HINT_SPACING, _TOOLTIP_SEP_COLOR_HEX

	hintText := _LLM_BuildNavHint(_LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods)
	infoText := ""
	if _LLM_Tooltip_ShowInfoBar {
		ttft := _LLM_Tooltip_Chain.TtftMs
		ttlt := _LLM_Tooltip_Chain.TtltMs
		infoText := _LLM_FormatInfoLine(_LLM_Tooltip_InfoModel, ttft, ttlt, false)
	}
	if (hintText == "" and infoText == "")
		return

	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_FOOTER_COMBINED_SEP
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	combinedSep := UI_LLM_FOOTER_COMBINED_SEP
	isCombined := false
	combinedText := ""
	combinedSz := { W: 0, H: 0 }
	if (hintText != "" and infoText != "") {
		combinedText := hintText . spaceDiv . combinedSep . spaceDiv . infoText
		combinedSz := _TooltipMeasureTextSize(combinedText, _TOOLTIP_LABEL_FONT_SIZE)
		if (combinedSz.W <= TotalW - 2 * _TOOLTIP_PADDING_X)
			isCombined := true
	}

	; HS layout: preds → line_spacing → sep → line_spacing → hint/info.
	if _TOOLTIP_LINE_SPACING > 0
		TotalH += _TOOLTIP_LINE_SPACING
	sepY := TotalH
	G.SetFont("s1", _TOOLTIP_FONT_NAME)
	G.Add("Text", Format("Background{1} x0 y{2} w{3} h1", _TOOLTIP_SEP_COLOR_HEX, sepY, TotalW), "")
	TotalH += 1
	if _TOOLTIP_LINE_SPACING > 0
		TotalH += _TOOLTIP_LINE_SPACING

	if isCombined {
		rowH := _TOOLTIP_PADDING_Y + combinedSz.H + _TOOLTIP_PADDING_Y
		textY := TotalH + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, rowH), "")
		G.SetFont("norm c" . _TOOLTIP_HINT_COLOR_HEX . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
		textX := Max(_TOOLTIP_PADDING_X, (TotalW - combinedSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			textX, textY, combinedSz.W + 4, combinedSz.H), combinedText)
		TotalH += rowH
		return
	}

	if (hintText != "") {
		hintSz := _TooltipMeasureTextSize(hintText, _TOOLTIP_LABEL_FONT_SIZE)
		hintY := TotalH + _TOOLTIP_PADDING_Y
		hintRowH := _TOOLTIP_PADDING_Y + hintSz.H + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, hintRowH), "")
		G.SetFont("norm c" . _TOOLTIP_HINT_COLOR_HEX . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
		hintX := Max(_TOOLTIP_PADDING_X, (TotalW - hintSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			hintX, hintY, hintSz.W + 4, hintSz.H), hintText)
		TotalH += hintRowH
	}

	if (infoText != "") {
		if (hintText != "")
			TotalH += _TOOLTIP_HINT_SPACING
		infoSz := _TooltipMeasureTextSize(infoText, _TOOLTIP_INFO_FONT_SIZE)
		infoY := TotalH + _TOOLTIP_PADDING_Y
		infoRowH := _TOOLTIP_PADDING_Y + infoSz.H + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, infoRowH), "")
		G.SetFont("norm c" . _TOOLTIP_INFO_COLOR_HEX . " s" . _TOOLTIP_INFO_FONT_SIZE, _TOOLTIP_FONT_NAME)
		infoX := Max(_TOOLTIP_PADDING_X, (TotalW - infoSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			infoX, infoY, infoSz.W + 4, infoSz.H), infoText)
		TotalH += infoRowH
	}
}



; ======================================
; ===== 3.2) Rich Gui LLM renderer =====
; ======================================

; Build a single Gui that renders all LLM slots with per-chunk coloring.
; Active slot: equal chunks in corr_sel (green), insert/NextWords in nw_sel
; (orange). Inactive slots: full text in unsel_gray. Each slot is one row;
; within a row, segment coloring is achieved by multiple Text controls placed
; side-by-side (same Y, X incremented by measured segment width).
_TooltipBuildGuiLlm(slots, active_idx, RenderGeneration,
		PresentationMeta, RequestSerial) {
	global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE, _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y
	global _TOOLTIP_DEFAULT_BG_HEX, _TOOLTIP_SEP_COLOR_HEX, _TOOLTIP_LABEL_FONT_SIZE
	global _TOOLTIP_INFO_FONT_SIZE, _LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel, _LLM_Tooltip_ValMods
	global LLM_TOOLTIP_PLACEHOLDER, LLM_TOOLTIP_TAB_SUFFIX
	global UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX, UI_LLM_UNSEL_GRAY_HEX, UI_LLM_LOADING_HEX
	global UI_LLM_CURSOR_HEX, UI_LLM_CMD_SEL_HEX, UI_LLM_CMD_DIM_HEX
	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_FOOTER_COMBINED_SEP

	G := 0
	CandidateHandedOff := false
	try {
	DpiScale := A_ScreenDPI / 96
	SEP_H    := 1
	Count    := slots.Length

	; ── Measure all row texts to find max width ──────────────────────────────
	; Each row's text = prefix + full slot text + suffix (for width budget).
	Sizes := []
	MaxW  := 0
	slotCount := slots.Length
	all_placeholder := _LLM_AllSlotsPlaceholder(slots)
	loading_label := (IsSet(t)) ? t("llm.generating") : _LLM_TOOLTIP_LOADING_FALLBACK
	for i, slot in slots {
		is_active := (i == active_idx)
		display := all_placeholder ? loading_label : _LLM_SlotBuildText(slot, is_active, i, slotCount)
		S := _TooltipMeasureText(display)
		Sizes.Push(S)
		if (S.W > MaxW)
			MaxW := S.W
	}
	hintText := _LLM_BuildNavHint(_LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods)
	infoSizing := ""
	if _LLM_Tooltip_ShowInfoBar
		infoSizing := _LLM_FormatInfoLine(_LLM_Tooltip_InfoModel, 9999, 9999, true)
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	combinedSep := UI_LLM_FOOTER_COMBINED_SEP
	if (hintText != "" and infoSizing != "") {
		combinedW := _TooltipMeasureTextSize(
			hintText . spaceDiv . combinedSep . spaceDiv . infoSizing, _TOOLTIP_LABEL_FONT_SIZE).W
		if (combinedW > MaxW)
			MaxW := combinedW
	} else {
		if (hintText != "") {
			hintW := _TooltipMeasureTextSize(hintText, _TOOLTIP_LABEL_FONT_SIZE).W
			if (hintW > MaxW)
				MaxW := hintW
		}
		if (infoSizing != "") {
			infoW := _TooltipMeasureTextSize(infoSizing, _TOOLTIP_INFO_FONT_SIZE).W
			if (infoW > MaxW)
				MaxW := infoW
		}
	}

	TotalW := _TOOLTIP_PADDING_X + MaxW + _TOOLTIP_PADDING_X
	RowMeta := []
	TotalH  := 0
	for Idx, slot in slots {
		RowH := _TOOLTIP_PADDING_Y + Sizes[Idx].H + _TOOLTIP_PADDING_Y
		RowMeta.Push({ H: RowH, Y: TotalH })
		TotalH += RowH
		if (Idx < Count)
			TotalH += SEP_H
	}

	inflight_bg := _TooltipMixTintHex(_TooltipResolveAccent("ai_loading"))
	has_loading := false
	for , slot in slots {
		if _LLM_SlotIsPlaceholder(slot) {
			has_loading := true
			break
		}
	}
	cursorHex := UI_LLM_CURSOR_HEX
	cmdSelHex := UI_LLM_CMD_SEL_HEX
	cmdDimHex := UI_LLM_CMD_DIM_HEX
	G := Gui("+AlwaysOnTop -Caption +E0x20 +E0x80 +LastFound")
	G.BackColor := has_loading ? inflight_bg : _TOOLTIP_DEFAULT_BG_HEX
	G.MarginX := 0
	G.MarginY := 0

	for Idx, slot in slots {
		is_active := (Idx == active_idx)
		Meta := RowMeta[Idx]
		RowY := Meta.Y
		RowH := Meta.H
		S    := Sizes[Idx]
		TextY := RowY + _TOOLTIP_PADDING_Y
		row_bg := _LLM_SlotIsPlaceholder(slot) ? inflight_bg : _TOOLTIP_DEFAULT_BG_HEX
		activePrefix := _LLM_GetActivePrefix(slotCount)
		inactivePrefix := _LLM_GetInactivePrefix(slotCount)
		shortcut := _LLM_BuildShortcutSuffix(Idx, slotCount, _LLM_Tooltip_ValMods)

		; Full-width background band.
		G.SetFont("norm s1", _TOOLTIP_FONT_NAME)
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", row_bg, RowY, TotalW, RowH), "")

		if _LLM_SlotIsEmpty(slot) {
			; In-flight slot — full « Génération en cours… » copy when the whole
			; stack is still waiting; otherwise sparkle + ellipsis per slot (HS).
			color := UI_LLM_LOADING_HEX
			prefix := is_active ? activePrefix : inactivePrefix
			loading_label := (IsSet(t)) ? t("llm.generating") : _LLM_TOOLTIP_LOADING_FALLBACK
			display := _LLM_AllSlotsPlaceholder(slots) ? loading_label : (prefix . LLM_TOOLTIP_PLACEHOLDER)
			G.SetFont("italic c" . color . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				_TOOLTIP_PADDING_X, TextY, MaxW, S.H), display)
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				scColor := is_active ? cmdSelHex : cmdDimHex
				G.SetFont("norm c" . scColor . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		} else if !is_active {
			; Inactive slot: plain gray.
			G.SetFont("norm c" . UI_LLM_UNSEL_GRAY_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			display := inactivePrefix . _LLM_SlotGetText(slot)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				_TOOLTIP_PADDING_X, TextY, MaxW, S.H), display)
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				G.SetFont("norm c" . cmdDimHex . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		} else {
			; Active slot with per-chunk coloring.
			CurX := _TOOLTIP_PADDING_X
			PrefixSz := _TooltipMeasureText(activePrefix)
			G.SetFont("norm c" . cursorHex . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				CurX, TextY, PrefixSz.W + 2, S.H), activePrefix)
			CurX += PrefixSz.W

			has_chunks := IsObject(slot) and slot.HasOwnProp("Chunks") and slot.Chunks.Length > 0
			if has_chunks {
				for , chunk in slot.Chunks {
					chunk_txt := chunk.HasOwnProp("text") ? chunk.text : ""
					if (chunk_txt == "")
						continue
					chunk_color := (chunk.HasOwnProp("type") and chunk.type == "insert") ? UI_LLM_CORR_SEL_HEX : UI_LLM_UNSEL_GRAY_HEX
					CSz := _TooltipMeasureText(chunk_txt)
					G.SetFont("norm c" . chunk_color . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
					G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
						CurX, TextY, CSz.W + 4, S.H), chunk_txt)
					CurX += CSz.W
				}
				nw := slot.HasOwnProp("NextWords") ? slot.NextWords : ""
				has_insert := false
				for , chunk in slot.Chunks {
					if (chunk.HasOwnProp("type") and chunk.type == "insert")
						has_insert := true
				}
				if (nw != "" and !has_insert) {
					CSz := _TooltipMeasureText(nw)
					G.SetFont("norm c" . UI_LLM_NW_SEL_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
					G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
						CurX, TextY, CSz.W + 4, S.H), nw)
					CurX += CSz.W
				}
			} else {
				; Plain text active slot (streaming).
				plain := _LLM_SlotGetText(slot)
				G.SetFont("norm cFFFFFF s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					CurX, TextY, MaxW, S.H), plain)
				CurX += _TooltipMeasureText(plain).W
			}

			if (LLM_TOOLTIP_TAB_SUFFIX != "") {
				G.SetFont("norm c" . _TOOLTIP_LABEL_COLOR_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					CurX, TextY, _TooltipMeasureText(LLM_TOOLTIP_TAB_SUFFIX).W + 4, S.H), LLM_TOOLTIP_TAB_SUFFIX)
			}
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				G.SetFont("norm c" . cmdSelHex . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		}

		; Separator.
		if (Idx < Count) {
			SepY := RowY + RowH
			G.SetFont("s1", _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", _TOOLTIP_SEP_COLOR_HEX, SepY, TotalW, SEP_H), "")
		}
	}

	row_bg_final := _TOOLTIP_DEFAULT_BG_HEX
	_LLM_TooltipAppendFooter(G, &TotalH, TotalW, row_bg_final)

	; Detached candidate: shared surface globals remain untouched until the final
	; generation-fenced commit in _TooltipPresentStack.
	Row := { Gui: G, H: TotalH, W: TotalW, IsSep: false }
	CandidateSurface := _TooltipCreateDetachedSurface(Row, RenderGeneration)
	; A newer show/hide can take ownership while this renderer performs GUI
	; work. Dispose only this detached candidate; never consult active globals.
	global _TooltipGeneration
    if (RenderGeneration != _TooltipGeneration) {
		_TooltipQueueSurfaceDisposal(CandidateSurface)
        return false
    }

	; AHK-34: mirror core.ahk — UIA COM must be profiled on the LLM path too
	_hpResolve := HotPath_Now()
    Pos := _TooltipResolvePosition()
    HotPath_LogIfSlow("Tooltip.ResolvePos", _hpResolve, "")
    if (RenderGeneration != _TooltipGeneration) {
		_TooltipQueueSurfaceDisposal(CandidateSurface)
        return false
	}
    ; The LLM path presents the same stack as the hotstring path but had no
    ; Present segment of its own, so a slow prediction render was invisible while
    ; the identical work on the preview path was reported. Draining the sub-step
    ; attribution here is also what stops _TooltipPresentStack's marks leaking
    ; into whichever segment happens to be measured next.
    _hpLlmPresent := HotPath_Now()
	Presented := false
	CandidateHandedOff := true
	; The direct rich renderer shares the same final owner/deadline/oracle commit
	; as ordinary and destack renders. Empty decision items retire a hotstring
	; snapshot when the LLM surface replaces it. Let presentation exceptions reach
	; LLM_TooltipShow, whose generation+request-fenced cleanup owns failure.
	StateCommit := _LLM_TooltipCommitSurfaceState.Bind(
		slots, active_idx, RenderGeneration, PresentationMeta)
	Presented := _TooltipPresentStack(Pos, Row, false, [],
		RenderGeneration, true, RequestSerial, 0, StateCommit)
    HotPath_LogIfSlow("Tooltip.LlmPresent", _hpLlmPresent, HotPath_BreakdownDetail())
	if !Presented
		return false
    if (RenderGeneration != _TooltipGeneration)
        return false
    return true
	} catch Error as Err {
		; Before presentation, this function alone owns the partially built Gui.
		; Once handed off, the common presenter owns candidate/retired disposal and
		; the lifecycle caller owns fail-closed hiding, so never queue it twice here.
		if (!CandidateHandedOff and IsObject(G)) {
			try {
				CleanupRow := (IsSet(Row) and IsObject(Row)) ? Row
					: { Gui: G, H: 0, W: 0, IsSep: false }
				_TooltipQueueSurfaceDisposal(
					_TooltipCreateDetachedSurface(CleanupRow,
						RenderGeneration))
			} catch {
				; Best effort after the original rich-build exception.
			}
		}
		throw Err
	}
}
