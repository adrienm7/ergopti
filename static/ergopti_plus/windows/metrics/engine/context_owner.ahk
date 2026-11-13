; metrics/engine/context_owner.ahk
; Independent context-clock receipts. Publication guards and acknowledgements
; are RAM-only; preparation/classification stays outside their Critical sections.
#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\journal\buffer_snapshot.ahk

_KL_ContextConfigStamp() {
	return [ObjPtr(MetricsFilters.disabled_apps), MetricsFilters.private_browsing,
		MetricsFilters.secure_field, MetricsFilters.system_auth]
}

_KL_ContextConfigCurrent(Stamp) {
	return Stamp[1] = ObjPtr(MetricsFilters.disabled_apps)
		&& Stamp[2] = MetricsFilters.private_browsing && Stamp[3] = MetricsFilters.secure_field
		&& Stamp[4] = MetricsFilters.system_auth
}

_KL_ContextPrivacyStamp() {
	return {Config: _KL_ContextConfigStamp(), Focus: MetricsFocusCache.generation,
		Password: MetricsFilters.secure_field ? KLPasswordCache.generation : 0}
}

_KL_ContextPrivacyCurrent(Stamp) {
	return _KL_ContextConfigCurrent(Stamp.Config) && Stamp.Focus = MetricsFocusCache.generation
		&& (!MetricsFilters.secure_field || Stamp.Password = KLPasswordCache.generation)
}

_KL_ContextEpochCurrent(Generation, Stopped := false) {
	return Keystats.initialized && KLHook.capture_generation = Generation
		&& (Stopped ? KLHook.capture_stopping : !KLHook.capture_stopping)
		&& (Stopped || !KL_CaptureHeld())
}

_KL_ContextFrameCurrent(Frame) {
	if Frame.Mode = "transition"
		return KLHook.context_transition == Frame
	return IsObject(KLHook.context_stop) && KLHook.context_stop.Tail == Frame
}

_KL_ContextNewFrame(Mode, NewApp, NewTitle, EndTick) {
	AppNeeded := Mode = "tail" ? KLHook.prev_app != ""
		: NewApp != "" && NewApp != KLHook.prev_app
	TitleNeeded := Mode = "tail" ? KLHook.prev_title != ""
		: NewTitle !== KLHook.prev_title || AppNeeded
	return {Mode: Mode, OldApp: KLHook.prev_app, OldTitle: KLHook.prev_title,
		NewApp: NewApp, NewTitle: NewTitle, EndTick: EndTick, Config: _KL_ContextConfigStamp(),
		Prepared: false, BufferStaged: false, PrepareToken: false, Completed: false,
		App: {Required: AppNeeded, Done: !AppNeeded, Filtered: false, Writer: false,
			Origin: KLHook.app_entered_at, Shift: 0},
		Title: {Required: TitleNeeded, Done: !TitleNeeded, Filtered: false, Writer: false,
			Origin: KLHook.title_entered_at, Shift: 0}}
}

_KL_ContextClockCurrent(Frame, Name, Token, Generation, Stopped) {
	if !_KL_ContextFrameCurrent(Frame) || !_KL_ContextEpochCurrent(Generation, Stopped)
		return false
	Clock := Frame.%Name%
	if Clock.Done || Clock.Writer != Token
		return false
	if Name = "App"
		return KLHook.prev_app == Frame.OldApp && KLHook.app_entered_at = Clock.Origin
	return KLHook.prev_title == Frame.OldTitle && KLHook.title_entered_at = Clock.Origin
}

_KL_ContextAppendCurrent(Frame, Name, Token, Generation, Stopped, Privacy) {
	return _KL_ContextClockCurrent(Frame, Name, Token, Generation, Stopped)
		&& _KL_ContextConfigCurrent(Frame.Config) && _KL_ContextPrivacyCurrent(Privacy)
}

_KL_ContextAdvanceClock(Frame, Name, Token, Generation, Stopped, Filtered := false) {
	PreviousCritical := Critical("On")
	try {
		if !_KL_ContextFrameCurrent(Frame)
			return false
		Clock := Frame.%Name%
		if Clock.Writer != Token || Clock.Done
			return false
		; A committed privacy refusal is monotone. A later owner cannot retry it
		; under a friendlier focus or settings; only RAM context may still advance.
		if Filtered
			Clock.Filtered := true
		if !_KL_ContextClockCurrent(Frame, Name, Token, Generation, Stopped)
			return false
		Origin := Frame.Mode = "tail" ? 0 : _KL_ContextClockOrigin(Frame.EndTick, Clock.Shift)
		if Name = "App" {
			KLHook.prev_app := Frame.NewApp
			KLHook.app_entered_at := Origin
		} else {
			KLHook.prev_title := Frame.NewTitle
			KLHook.title_entered_at := Origin
		}
		Clock.Done := true
		Clock.Writer := false
		return true
	} finally Critical(PreviousCritical)
}

_KL_ContextPrepareCurrent(Frame, Token, Generation, Stopped) {
	return _KL_ContextFrameCurrent(Frame) && Frame.PrepareToken == Token
		&& _KL_ContextEpochCurrent(Generation, Stopped)
}

_KL_ContextPrepare(Frame, Generation, Stopped) {
	PreviousCritical := Critical("On")
	try {
		if !_KL_ContextFrameCurrent(Frame) || !_KL_ContextEpochCurrent(Generation, Stopped)
			return false
		if Frame.Prepared
			return true
		Token := {}
		Frame.PrepareToken := Token
		if Frame.Mode = "transition" && !Frame.BufferStaged && (Frame.App.Required || Frame.Title.Required) {
			; New input can arrive while the old payload's privacy classification
			; yields. Detach A and name the empty live buffer B in this same claim,
			; even when another flush is already publishing an older snapshot.
			Snapshot := _KL_DetachBufferSnapshot()
			if IsObject(Snapshot)
				Keystats._retry_snapshots.Push(Snapshot)
			Keystats.session_app := Frame.NewApp
			Keystats.session_title := Frame.NewTitle
			Frame.BufferStaged := true
		}
	} finally Critical(PreviousCritical)
	if Frame.App.Required || Frame.Title.Required {
		Guard := _KL_ContextPrepareCurrent.Bind(Frame, Token, Generation, Stopped)
		try Flushed := KL_FlushBuffer(Guard, &Deferred)
		catch as Failure {
			try LoggerError("Keystats", "Context buffer preparation remains pending: {1}.", Failure.Message)
			return false
		}
		if Deferred || (!Flushed && Keystats._retry_snapshots.Length > 0)
			return false
	}
	PreviousCritical := Critical("On")
	try {
		if !_KL_ContextPrepareCurrent(Frame, Token, Generation, Stopped)
			return false
		if Frame.Mode = "transition" && !Frame.BufferStaged {
			Keystats.session_app := Frame.NewApp
			Keystats.session_title := Frame.NewTitle
		}
		Frame.Prepared := true
		return true
	} finally Critical(PreviousCritical)
}

_KL_ContextPublishClock(Frame, Name, Generation, Stopped, AppendFn := unset) {
	; A refreshed password verdict may revoke the first publication attempt.
	; Both attempts still use the same immutable interval and real append owner.
	Loop 2 {
		PreviousCritical := Critical("On")
		try {
			if !_KL_ContextFrameCurrent(Frame) || !_KL_ContextEpochCurrent(Generation, Stopped)
				return false
			Clock := Frame.%Name%
			if Clock.Done
				return true
			Token := {}
			Clock.Writer := Token
			HasRow := Frame.OldApp != ""
				&& (Name = "App" || Frame.OldTitle != "")
		} finally Critical(PreviousCritical)
		Commit := _KL_ContextAdvanceClock.Bind(Frame, Name, Token, Generation, Stopped)
		Refuse := _KL_ContextAdvanceClock.Bind(Frame, Name, Token, Generation, Stopped, true)
		if !HasRow
			return Commit.Call()
		if Clock.Filtered || !_KL_ContextConfigCurrent(Frame.Config)
			return Refuse.Call()
		if Frame.Mode = "transition" {
			DestinationFiltered := true
			try DestinationFiltered := MF_ShouldFilterFor(Frame.NewApp, Frame.NewTitle)
			catch as Failure
				try LoggerWarn("Keystats", "Captured context destination could not be classified: {1}.", Failure.Message)
			if DestinationFiltered
				return Refuse.Call()
		}
		Privacy := _KL_ContextPrivacyStamp()
		Guard := _KL_ContextAppendCurrent.Bind(Frame, Name, Token, Generation, Stopped, Privacy)
		Rejected := false
		try {
			Duration := TickElapsed64(Clock.Origin, Frame.EndTick)
			Accepted := Name = "App"
				? KL_LogAppSwitch(Frame.OldApp, Frame.NewApp, Duration, Frame.OldTitle,
					Guard, Commit, Refuse, &Rejected, AppendFn?)
				: KL_LogWindowSwitch(Frame.OldApp, Frame.OldTitle, Frame.NewTitle, Duration,
					Guard, Commit, Refuse, &Rejected, AppendFn?)
		} catch as Failure {
			; An acknowledged row remains consumed even if a returning observer
			; throws. An unacknowledged row retains its exact frozen interval.
			if Clock.Done && _KL_ContextEpochCurrent(Generation, Stopped)
				return true
			try LoggerError("Keystats", "Context {1} publication remains pending: {2}.", Name, Failure.Message)
			return false
		}
		if !_KL_ContextEpochCurrent(Generation, Stopped)
			return false
		if Clock.Done
			return true
		if !_KL_ContextClockCurrent(Frame, Name, Token, Generation, Stopped)
			return false
		if !Accepted && !Rejected
			return false ; only the central privacy receipt may consume a refused interval
		if Accepted {
			try LoggerError("Keystats", "Context {1} writer returned success without its exact clock acknowledgement.", Name)
			return false
		}
	}
	return false
}

_KL_ContextDrain(Frame, Generation, Stopped := false, AppendFn := unset) {
	if Frame.Completed
		return _KL_ContextFrameCurrent(Frame) && _KL_ContextEpochCurrent(Generation, Stopped)
	if !_KL_ContextPrepare(Frame, Generation, Stopped)
		return false
	for Name in ["App", "Title"]
		if !_KL_ContextPublishClock(Frame, Name, Generation, Stopped, AppendFn?)
			return false
	PreviousCritical := Critical("On")
	try {
		if !_KL_ContextFrameCurrent(Frame) || !_KL_ContextEpochCurrent(Generation, Stopped)
			return false
		if Frame.Mode = "transition" {
			KLHook.context_at := Frame.EndTick
			if KLHook.context_observation_head <= KLHook.context_observations.Length {
				Observed := KLHook.context_observations[KLHook.context_observation_head++]
				Next := _KL_ContextNewFrame("transition", Observed.App, Observed.Title, Observed.EndTick)
				Next.Config := Observed.Config
				Next.BufferStaged := true
				; Shift belongs to time after this observed destination, not the
				; preceding interval whose endpoint was frozen earlier.
				PromotionNow := A_TickCount
				if Next.App.Required
					Next.App.Shift := Observed.Shift
				else
					KLHook.app_entered_at := Min(KLHook.app_entered_at + Observed.Shift, PromotionNow)
				if Next.Title.Required
					Next.Title.Shift := Observed.Shift
				else
					KLHook.title_entered_at := Min(KLHook.title_entered_at + Observed.Shift, PromotionNow)
				KLHook.context_transition := Next
				if KLHook.context_observation_head > KLHook.context_observations.Length {
					KLHook.context_observations := []
					KLHook.context_observation_head := 1
				}
			} else
				KLHook.context_transition := false
		} else {
			KLHook.prev_app := "", KLHook.prev_title := ""
			KLHook.app_entered_at := 0, KLHook.title_entered_at := 0
			KLHook.context_at := 0
			; Keep Stop owned until its actual hooks, final flush and classifier retire.
		}
		Frame.Completed := true
		return true
	} finally Critical(PreviousCritical)
}

; Admit only an actual, still-current canonical focus object. Detach its
; predecessor and label the new live buffer in the same indivisible RAM claim.
_KL_ContextStageObserved(Pending, Snapshot, EndTick, Generation) {
	PreviousCritical := Critical("On")
	try {
		if !_KL_ContextEpochCurrent(Generation)
			return false
		if !IsObject(Snapshot) || Snapshot != MetricsFocusCache.state
			return false
		if !Snapshot.HasOwnProp("valid") || !Snapshot.valid {
			if IsSet(KL_Roi_DiscardWord)
				KL_Roi_DiscardWord()
			return false
		}
		if IsSet(KL_Roi_AdmitWordContext)
			KL_Roi_AdmitWordContext(Snapshot)
		; A nested timer may have finished or replaced the frame while focus was
		; acquired. Join the current owner and stage its destination first.
		Current := KLHook.context_transition
		if IsObject(Current) && !Current.BufferStaged {
			PriorBuffer := _KL_DetachBufferSnapshot()
			if IsObject(PriorBuffer)
				Keystats._retry_snapshots.Push(PriorBuffer)
			Keystats.session_app := Current.NewApp
			Keystats.session_title := Current.NewTitle
			Current.BufferStaged := true
		}
		if Snapshot.process_name == Keystats.session_app && Snapshot.title == Keystats.session_title
			return true
		OldBuffer := _KL_DetachBufferSnapshot()
		if IsObject(OldBuffer)
			Keystats._retry_snapshots.Push(OldBuffer)
		if !IsObject(Current) {
			Current := _KL_ContextNewFrame("transition", Snapshot.process_name, Snapshot.title, EndTick)
			Current.BufferStaged := true
			KLHook.context_transition := Current
		} else
			KLHook.context_observations.Push({App: Snapshot.process_name, Title: Snapshot.title,
				EndTick: EndTick, Config: _KL_ContextConfigStamp(), Shift: 0})
		Keystats.session_app := Snapshot.process_name
		Keystats.session_title := Snapshot.title
		return true
	} finally Critical(PreviousCritical)
}

_KL_ContextProject(Snapshot, EndTick, Generation) {
	PreviousCritical := Critical("On")
	try {
		if !_KL_ContextEpochCurrent(Generation)
			return false
		if !IsObject(KLHook.context_transition)
			KLHook.context_transition := _KL_ContextNewFrame("transition", Snapshot.process_name, Snapshot.title, EndTick)
		Frame := KLHook.context_transition
	} finally Critical(PreviousCritical)
	return _KL_ContextDrain(Frame, Generation)
}

_KL_ContextCloseTail(AppendFn := unset) {
	PreviousCritical := Critical("On")
	try {
		if !Keystats.initialized
			return true
		Generation := KLHook.capture_generation
		if !KLHook.capture_stopping
			return false
		if !IsObject(KLHook.context_stop) {
			if KL_CaptureHeld() && KLHook.suspend_tick > 0 {
				KL_Hook_AdvanceContextWatermarks(TickElapsed64(KLHook.suspend_tick))
				KLHook.suspend_tick := A_TickCount
			}
			KLHook.context_stop := {EndTick: A_TickCount, Tail: false}
		}
		Stop := KLHook.context_stop
		Pending := KLHook.context_transition
	} finally Critical(PreviousCritical)
	while IsObject(Pending) {
		if !_KL_ContextDrain(Pending, Generation, true, AppendFn?)
			return false
		PreviousCritical := Critical("On")
		try Pending := KLHook.context_transition
		finally Critical(PreviousCritical)
	}
	PreviousCritical := Critical("On")
	try {
		if KLHook.context_stop != Stop || !_KL_ContextEpochCurrent(Generation, true)
			return false
		if !IsObject(Stop.Tail)
			Stop.Tail := _KL_ContextNewFrame("tail", "", "", Stop.EndTick)
		Tail := Stop.Tail
	} finally Critical(PreviousCritical)
	return _KL_ContextDrain(Tail, Generation, true, AppendFn?)
}


_KL_ContextStopCurrent(Stop, Generation) {
	return KLHook.capture_stopping && KLHook.capture_generation = Generation
		&& (IsObject(Stop) ? KLHook.context_stop == Stop : !IsObject(KLHook.context_stop))
}


; Both inputs belong to the untruncated native A_TickCount domain. This pure
; scalar helper also keeps that domain explicit for deterministic contract tests.
_KL_ContextClockOrigin(EndTick, Shift) {
	TickElapsed64(0, EndTick)
	TickElapsed64(0, Shift)
	return EndTick + Shift
}
