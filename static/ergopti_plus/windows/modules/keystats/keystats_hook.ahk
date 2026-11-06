; modules/keystats/keystats_hook.ahk

; ==============================================================================
; MODULE: Keystats Input Hook
; DESCRIPTION:
; Wires keystroke capture to the keystats pipeline using AHK v2's
; ``InputHook``. Observes every key the user types — including the
; OUTPUT of the layout's remaps and hotstring expansions — without
; intercepting. The result feeds into Keystats.buffer_events and the
; existing flush / ingest tick handles persistence.
;
; FEATURES & RATIONALE:
; 1. Passive observation: ``InputHook("V L0 I1")`` runs visible (events
;    keep flowing to apps) and accepts every key (``L0`` = no length
;    cutoff). The minimum send level stays at 1 because the layout's
;    remap hotkeys (``*X::Send "y"``) consume the raw key — InputHook
;    only sees the resolved ``Send`` output, sent at level 2. A higher
;    level would filter that out and we would capture nothing at all;
;    level 0 is the driver's own TextSender output, which is not typing.
; 2. Two complementary callbacks:
;    - OnChar(ih, c)            — printable characters AFTER the layout
;                                  has resolved deadkeys / remaps. This
;                                  is what the user actually typed.
;    - OnKeyDown(ih, vk, sc)    — non-character keys: BS, Enter, Tab,
;                                  arrows, F-keys. Mapped to bracket
;                                  markers ``[BS]``, ``[ENTER]``, …
;                                  matching the Hammerspoon side's
;                                  shape (cf. n-gram walker).
; 3. Privacy filters honoured: every event runs through MF_ShouldFilter()
;    BEFORE landing in the buffer. Disabled apps, private browsing,
;    system-auth dialogs and password fields are short-circuited at
;    the source. The cache inside MF_ShouldFilter keeps the per-keystroke
;    cost negligible (≤ 50 ms TTL).
; 4. Optional key metadata: OnKeyDown supplies its actual vk/sc arguments.
;    OnChar may retain only a same-lifecycle cached hint, because its callback
;    has no key identity. A lifecycle barrier removes that hint; no native
;    physical event pairing is inferred from these metadata fields.
; 5. Buffered flush: nothing hits disk on the keystroke path. The
;    buffer accumulates in RAM and a SetTimer (default 2 s) calls
;    KL_FlushBuffer to compose a typing entry and append it to
;    today.log. The ingest tick then drains today.log into data.sql
;    on its own 5 s cadence.
;
; LIFECYCLE:
; - KL_Hook_Start() is called from ErgoptiPlus.ahk right after
;   KL_Init() when the keystats feature is on.
; - KL_Hook_Stop() releases the hook + cancels the flush timer.
;   Called by KL_Stop() and by the explicit metrics OFF toggle.
; ==============================================================================

#Requires Autohotkey v2.0+

; The capture sources below ask KL_CaptureHeld, which the collection module owns.
#Include keystats_collection.ahk





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLHookConst {
		; Hot path → today.log. 500 ms keeps the live dashboard reactive
		; (the user sees their own keystrokes within ~half a second) while
		; still bounding typing entries to ~25-30 events at peak rate.
		static FLUSH_PERIOD_MS := 200

		; Project the shared metrics focus snapshot at most once per second. The
		; acquisition itself belongs exclusively to MetricsFocusCache; this module
		; performs no Win32 query and only emits app/window transition events.
		static CONTEXT_TTL_MS := 1000

		; This SetTimer is resident on the same AHK thread as keyboard dispatch. Its
		; callback is safe because it consumes memory only; treating SetTimer as an
		; off-thread escape hatch was the false premise behind the previous fix.
		static CONTEXT_REFRESH_MS := 250

		; Debounce window for the live dashboard push after a flush. Coalesces
		; rapid typing bursts into a single KLWV_NotifyIngest call so the
		; prefetch rebuild (150-300 ms) is not re-triggered on every keystroke
		; while keeping the dashboard latency under ~2 s during normal use.
		static LIVE_PUSH_DEBOUNCE_MS := 1500
}

; Special-key VK → bracket marker. Mirrors the macOS hs.eventtap codepath
; in modules/keystats/log_manager.lua so the n-gram tables share the
; same token shape regardless of OS.
global KLHOOK_SPECIAL := Map(
		0x08, "[BS]",
		0x09, "[TAB]",
		0x0D, "[ENTER]",
		0x1B, "[ESC]",
		0x25, "[LEFT]",
		0x26, "[UP]",
		0x27, "[RIGHT]",
		0x28, "[DOWN]",
		0x2E, "[DELETE]",
		0x24, "[HOME]",
		0x23, "[END]",
		0x21, "[PAGEUP]",
		0x22, "[PAGEDOWN]"
)





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLHook {
		static capture_queue := []
		static capture_owner := false
		static capture_generation := 1
		static capture_stopping := false
		; A one-use named-key receipt, never an inference from last_vk hints.
		static control_char_echo := false
		static ih := unset           ; the live InputHook object
		static flush_timer := unset  ; bound function reference for SetTimer
		static context_timer := unset  ; bound ref for the memory-only context projection
		static live_push_timer := unset  ; one-shot debounce for KLWV_NotifyIngest
		static last_tick := 0        ; A_TickCount of the last captured event

		; Last admitted OnKeyDown hints within this capture/logger lifecycle.
		; OnChar supplies no native edge identity: these are optional metadata,
		; never authenticated physical pairing or capture/replay permission.
		static last_vk := 0
		static last_sc := 0
		static last_hint_lifecycle := 0

		; Active-window context cache. Avoids hammering Win32 on every
		; keystroke; refreshed at most every CONTEXT_TTL_MS.
		static context_at := 0
		static context_transition := false
		static context_observations := []
		static context_observation_head := 1
		static context_stop := false

		; Previous (app, title) values + their entry tick — used to emit
		; ``app_switch`` / ``window_switch`` events when the focused app or
		; title changes. Mirrors HS init.lua:862 / context_tracker.lua:230.
		; "" / 0 signals « no observation yet », so the first refresh
		; only seeds the values without emitting a spurious switch from
		; the static "Unknown" defaults.
		static prev_app := ""
		static prev_title := ""
		static app_entered_at := 0
		static title_entered_at := 0
		; A_TickCount of the last SUSPENDED context tick, 0 while running. SetTimer
		; keeps firing under native Suspend, so the two watermarks above must be
		; advanced on every paused tick — otherwise the first refresh after resume
		; bills the ENTIRE pause to whichever app was focused when the user paused
		; (KLW_WalkAppSwitch adds duration_ms verbatim to app_time, with no clamp).
		static suspend_tick := 0
}





; ==================================
; ==================================
; ======= 3/ Context refresh =======
; ==================================
; ==================================

; Advance the context watermarks by Elapsed WITHOUT letting them overshoot the
; present.
;
; Two independent compensations exist for the same wall-clock span: this timer's
; suspend branch, and the keystroke-gap branch in KL_Watchers_OnKeystroke. After
; a pause longer than the session timeout BOTH fire and both describe the same
; missing time, so applied one after the other they push app_entered_at PAST
; A_TickCount. The next app_switch then computes `Now - app_entered_at` as a
; NEGATIVE duration, and the walker adds that verbatim to app_time — silently
; subtracting screen time from whichever app was focused.
;
; Clamping here rather than at the consumer keeps the watermark itself honest:
; it can never claim the app was entered in the future.
KL_Hook_AdvanceContextWatermarks(Elapsed, NowTick := unset) {
		; Gap compensation and both exact clock receipts share one RAM claim.
		PreviousCritical := Critical("On")
		try {
			Now := IsSet(NowTick) ? NowTick : A_TickCount
			Pending := KLHook.context_transition
			if IsObject(KLHook.context_stop)
				return ; the first stop endpoint also freezes an unfinished normal transition
			if KLHook.context_observation_head <= KLHook.context_observations.Length {
				; A pause after C was observed belongs to C, not to the still-pending B.
				Last := KLHook.context_observations[-1]
				Last.Shift := Min(Last.Shift + Elapsed, TickElapsed64(Last.EndTick, Now))
				return
			}
			if IsObject(Pending) && Pending.App.Required && !Pending.App.Done
					&& KLHook.app_entered_at = Pending.App.Origin
				Pending.App.Shift := Min(Pending.App.Shift + Elapsed, TickElapsed64(Pending.EndTick, Now))
			else
				KLHook.app_entered_at := Min(KLHook.app_entered_at + Elapsed, Now)
			if IsObject(Pending) && Pending.Title.Required && !Pending.Title.Done
					&& KLHook.title_entered_at = Pending.Title.Origin
				Pending.Title.Shift := Min(Pending.Title.Shift + Elapsed, TickElapsed64(Pending.EndTick, Now))
			else
				KLHook.title_entered_at := Min(KLHook.title_entered_at + Elapsed, Now)
		} finally Critical(PreviousCritical)
}

KL_Hook_RefreshContext(force := false, SnapshotFn := 0) {
		EntryCritical := Critical("On")
		try {
			if KLHook.capture_stopping
				return false
			Generation := KLHook.capture_generation
			; Driven by SetTimer, which bypasses native Suspend — stay silent while
			; the driver is paused so no app/title switch is observed or flushed.
			;
			; A bare return is not enough: the watermarks would freeze while wall-clock
			; keeps running, so the first refresh after resume emits an app_switch whose
			; duration spans the whole pause. KLW_WalkAppSwitch adds that value verbatim
			; to app_time with no upper clamp, so an overnight pause credited hours of
			; screen time to whichever app happened to be focused — landing on the RESUME
			; day. The gap compensation in KL_Watchers_OnKeystroke cannot help: it is
			; driven by the first post-resume KEYSTROKE, and this 250 ms timer always
			; fires first whenever the focused app changed during the pause.
			if KL_CaptureHeld() {
					PausedNow := A_TickCount
					if (KLHook.suspend_tick != 0) {
							Elapsed := TickElapsed64(KLHook.suspend_tick, PausedNow)
							KL_Hook_AdvanceContextWatermarks(Elapsed)
					}
					KLHook.suspend_tick := PausedNow
					return
			}
			KLHook.suspend_tick := 0
			; Guard against the timer firing before KL_Init() has completed — the
			; KL_LogAppSwitch / KL_LogWindowSwitch calls below require an initialized
			; keystats instance; without this guard a fast startup race could crash
			; or write a corrupted switch event (H-16 fix).
			if !Keystats.initialized
					return
			Pending := KLHook.context_transition
		} finally Critical(EntryCritical)
		while IsObject(Pending) {
			if !_KL_ContextDrain(Pending, Generation) {
				; Keep accepting actual later observations even when publication of the
				; previous interval is deferred. The canonical cache remains the owner.
				try Later := HasMethod(SnapshotFn, "Call") ? SnapshotFn.Call() : MF_GetFocusSnapshot()
				catch
					return false
				_KL_ContextStageObserved(Pending, Later, A_TickCount, Generation)
				return false
			}
			PreviousCritical := Critical("On")
			try Pending := KLHook.context_transition
			finally Critical(PreviousCritical)
		}
		if !_KL_ContextEpochCurrent(Generation)
			return false
		if !force && TickElapsed64(KLHook.context_at) < KLHookConst.CONTEXT_TTL_MS
			return false
		; The 50 ms metrics poll is the sole OS acquisition owner. This resident
		; timer reads that already-published object and refuses an invalid snapshot;
		; MF_ShouldFilter independently sees the same invalid marker and drops every
		; payload until acquisition recovers.
		try Snapshot := HasMethod(SnapshotFn, "Call")
			? SnapshotFn.Call() : MF_GetFocusSnapshot()
		catch as Err {
				try LoggerError("keystats_hook",
						"Canonical focus snapshot read failed: {1}.", Err.Message)
				return false
		}
		ProjectionCritical := Critical("On")
		try {
			if !_KL_ContextEpochCurrent(Generation)
				return false
			; A getter can return after a newer focus and word were admitted. ROI
			; may mutate only for the object still owned by the canonical cache;
			; the retained snapshot keeps its existing projection contract below.
			SnapshotCurrent := IsObject(Snapshot) && Snapshot == MetricsFocusCache.state
			if !IsObject(Snapshot) || !Snapshot.HasOwnProp("valid") || !Snapshot.valid {
				if SnapshotCurrent && IsSet(KL_Roi_DiscardWord)
					KL_Roi_DiscardWord()
				return false
			}
			if SnapshotCurrent && IsSet(KL_Roi_AdmitWordContext)
				KL_Roi_AdmitWordContext(Snapshot)
		} finally Critical(ProjectionCritical)
		return _KL_ContextProject(Snapshot, A_TickCount, Generation)
}



; ===================================
; ===== 3.1) Activity watermark =====
; ===================================

; Advances the last_tick watermark and drives the session / idle state machine
; for one physical keypress, returning the inter-keystroke delay in ms relative
; to the PREVIOUS captured key (0 if this is the first).
;
; This must run for EVERY physical key the user presses — including ones whose
; content is privacy-filtered. The key WAS pressed; only its content must be
; dropped, not the timing watermark. If we skipped the watermark on filtered
; keys, the next unfiltered key would compute a giant delay (now - the tick
; before the whole filtered interlude), fabricating a think-pause, breaking the
; walker's burst, and emitting a spurious retroactive idle / session_end.
;
; KL_Watchers_OnKeystroke is driven BEFORE the watermark advances so the watcher
; still reads the gap from the previous keystroke.
;
; @param already_called bool  When true, the shortcut branch already applied
;                             this physical key to the watcher.
; @param authorized bool      Whether privacy classification accepted this key.
; @param Now Integer          Callback-entry tick captured before classification.
KL_Hook_NoteActivity(already_called := false, authorized := true, Now := unset,
	Synthetic := unset, GuardFn := unset) {
	PreviousCritical := Critical("On")
	try {
		if IsSet(GuardFn) && !GuardFn.Call()
			return false
		LastTick := KLHook.last_tick
		now := IsSet(Now) ? Now : A_TickCount
		delay := TickElapsed64(LastTick, now)
		if LastTick = 0
			delay := 0
		IsSynthetic := IsSet(Synthetic) ? Synthetic : Keystats.synth_active
	} finally Critical(PreviousCritical)
	if !IsSynthetic && !already_called {
		if authorized {
			if IsSet(GuardFn) {
				try KL_Watchers_OnKeystroke(0, now, GuardFn)
			} else {
				try KL_Watchers_OnKeystroke(0, now)
			}
		} else {
			try KL_Watchers_OnPrivateKeystroke(now, GuardFn?)
		}
	}
	PreviousCritical := Critical("On")
	try {
		if IsSet(GuardFn) && !GuardFn.Call()
			return false
		KLHook.last_tick := now
	} finally Critical(PreviousCritical)
	return delay
}





; ======================================
; ======================================
; ======= 4/ InputHook callbacks =======
; ======================================
; ======================================

; Serial capture has two phases: enqueue before any query, then classify on the
; original callback thread. A ready nested receipt cannot pass an older head.
KL_Hook_HasPendingInput() {
	PreviousCritical := Critical("On")
	try return KLHook.capture_queue.Length > 0 || IsObject(KLHook.capture_owner)
	finally Critical(PreviousCritical)
}

KL_Hook_InvalidateCapture(Stopping := false) {
	PreviousCritical := Critical("On")
	try {
		Keystats.scalar_fragment := false
		Keystats.scalar_history := false
		Keystats.scalar_epoch += 1
		KLHook.capture_generation += 1
		if IsSet(KL_Roi_DiscardWord)
			KL_Roi_DiscardWord()
		KLHook.last_vk := 0
		KLHook.last_sc := 0
		KLHook.last_hint_lifecycle := 0
		KLHook.control_char_echo := false
		if Stopping
			KLHook.capture_stopping := true
	}
	finally Critical(PreviousCritical)
}

_KL_Hook_CaptureInput(Kind, Character, vk, sc, FilterFn := unset, NowTick := unset, ErgoFn := unset, SourceHook := 0) {
	PreviousCritical := Critical("On")
	try {
		if KL_CaptureHeld()
			return false
		if !Keystats.initialized || Keystats._shutting_down || KLHook.capture_stopping
			return false
		; Shutdown rollback may advance logger ownership without restarting InputHook.
		if KLHook.last_hint_lifecycle != Keystats.lifecycle_generation {
			KLHook.last_vk := 0
			KLHook.last_sc := 0
		}
		KLHook.last_hint_lifecycle := Keystats.lifecycle_generation
		if Kind = "key" {
			if IsNumber(vk)
				KLHook.last_vk := vk
			if IsNumber(sc)
				KLHook.last_sc := sc
		}
		Tick := IsSet(NowTick) ? NowTick : A_TickCount
		TickElapsed64(0, Tick)
		Intent := {
			kind: Kind, character: Character, vk: vk, sc: sc, tick: Tick,
			arrival_vk: KLHook.last_vk, arrival_sc: KLHook.last_sc,
			synth_active: Keystats.synth_active, synth_type: Keystats.synth_type,
			synth_private: Keystats.synth_private,
			lifecycle: Keystats.lifecycle_generation,
			generation: KLHook.capture_generation, scalar_epoch: Keystats.scalar_epoch,
			scalar_backspace: false,
			entry_privacy: _KL_CaptureLlmJournalPrivacy(),
			entry_focus: KLPasswordCache.focus_generation,
			privacy: false, ready: false, cancelled: true, filtered: true,
			shortcut: "", activity: Kind = "char",
			filter_fn: IsSet(FilterFn) ? FilterFn : 0,
			ergo_fn: IsSet(ErgoFn) ? ErgoFn : 0,
			source_hook: SourceHook, echo_of: false, recorded: false
		}
		if Kind = "key" {
			; Every other native keydown revokes an unconsumed named-key echo.
			KLHook.control_char_echo := IsObject(SourceHook) && (vk = 0x0D || vk = 0x09) ? Intent : false
		} else {
			Echo := KLHook.control_char_echo
			KLHook.control_char_echo := false
			if IsObject(Echo) && IsObject(SourceHook) && Echo.source_hook == SourceHook
					&& Echo.lifecycle = Intent.lifecycle && Echo.generation = Intent.generation
					&& ((Echo.vk = 0x0D && (Character = "`n" || Character = "`r"))
						|| (Echo.vk = 0x09 && Character = "`t"))
				Intent.echo_of := Echo
		}
		KLHook.capture_queue.Push(Intent)
		return Intent
	} finally Critical(PreviousCritical)
}

_KL_Hook_InputLifecycleCurrent(Intent) {
	return Keystats.initialized && !Keystats._shutting_down && !KL_CaptureHeld()
		&& !KLHook.capture_stopping
		&& Intent.lifecycle = Keystats.lifecycle_generation
		&& Intent.generation = KLHook.capture_generation
}

; Classification may legitimately publish a new password verdict. The entry
; focus and configuration must remain stable; the final verdict is captured below.
_KL_Hook_PrepareInput(Intent) {
	PreviousCritical := Critical("On")
	try {
		Entry := Intent.entry_privacy
		if !_KL_Hook_InputLifecycleCurrent(Intent)
			return false
		if Intent.entry_focus != KLPasswordCache.focus_generation
				|| Entry["focus_generation"] != MetricsFocusCache.generation
				|| Entry["disabled_apps_ptr"] != ObjPtr(MetricsFilters.disabled_apps)
				|| Entry["private_browsing"] != MetricsFilters.private_browsing
				|| Entry["secure_field"] != MetricsFilters.secure_field
				|| Entry["system_auth"] != MetricsFilters.system_auth
			Intent.filtered := true
		Intent.privacy := _KL_CaptureLlmJournalPrivacy()
		Intent.cancelled := false
		return true
	} finally Critical(PreviousCritical)
}

_KL_Hook_InputCurrent(Intent) {
	return !Intent.cancelled && _KL_Hook_InputLifecycleCurrent(Intent)
		&& (Intent.filtered || _KL_LlmJournalPrivacyStillCurrent(Intent.privacy))
}

; Tab invalidates the source field before this callback returns. Only that exact
; own invalidation may update this receipt; a later focus owner still revokes it.
_KL_Hook_InvalidateTabInput(Intent) {
	PreviousCritical := Critical("On")
	try {
		Current := IsObject(Intent) && _KL_Hook_InputCurrent(Intent)
		KL_InvalidatePasswordFocus()
		if Current
			Intent.privacy["password_generation"] := KLPasswordCache.generation
	} finally Critical(PreviousCritical)
}

_KL_Hook_FinishInput(Intent) {
	PreviousCritical := Critical("On")
	try {
		Intent.ready := true
	} finally Critical(PreviousCritical)
	_KL_Hook_DrainInput()
}

; A failed completion retires only its own receipt; already-ready successors retain
; their admission and can still drain. Failures remain visible through the logger.
_KL_Hook_CompleteInput(Intent) {
	try _KL_Hook_FinishInput(Intent)
	catch as FinishErr {
		try LoggerError("keystats_hook", "Physical input completion failed: {1}.", FinishErr.Message)
		try {
			PreviousCritical := Critical("On")
			try {
				for Index, Queued in KLHook.capture_queue {
					if Queued = Intent {
						KLHook.capture_queue.RemoveAt(Index)
						break
					}
				}
			} finally Critical(PreviousCritical)
			_KL_Hook_DrainInput()
		} catch as RecoveryErr
			try LoggerError("keystats_hook", "Physical input completion retirement failed: {1}.", RecoveryErr.Message)
		return false
	}
	return true
}

_KL_Hook_DrainInput() {
	PreviousCritical := Critical("On")
	try {
		if IsObject(KLHook.capture_owner) || KLHook.capture_queue.Length = 0
				|| !KLHook.capture_queue[1].ready
			return
		Owner := {}
		KLHook.capture_owner := Owner
	} finally Critical(PreviousCritical)
	try {
		loop {
			PreviousCritical := Critical("On")
			try {
				if KLHook.capture_owner != Owner
					throw Error("Physical input drain ownership changed.")
				if KLHook.capture_queue.Length = 0 || !KLHook.capture_queue[1].ready {
					KLHook.capture_owner := false
					return
				}
				Next := KLHook.capture_queue.RemoveAt(1)
			} finally Critical(PreviousCritical)
			try _KL_Hook_CommitInput(Next)
			catch as Err
				try LoggerError("keystats_hook", "Ordered physical input failed: {1}.", Err.Message)
		}
	} finally {
		PreviousCritical := Critical("On")
		try {
			if KLHook.capture_owner = Owner
				KLHook.capture_owner := false
		} finally Critical(PreviousCritical)
	}
}

; The pending unit never authorizes another target, source hook or epoch.
_KL_Hook_ScalarOwnerCurrent(Pending, Intent) {
	return IsObject(Pending) && _KL_Hook_InputCurrent(Pending)
		&& Pending.scalar_epoch = Intent.scalar_epoch && Intent.scalar_epoch = Keystats.scalar_epoch
		&& Pending.source_hook == Intent.source_hook && Pending.entry_focus = Intent.entry_focus
		&& Pending.synth_active = Intent.synth_active && Pending.synth_private = Intent.synth_private
		&& Pending.synth_type == Intent.synth_type
		&& Pending.app == Keystats.session_app && Pending.title == Keystats.session_title
}

; This is the observed chronological stream, not a model of unobserved caret
; or document changes. Cache/synthetic invalidation revokes assembly only. A
; real hook/context/lifecycle change or an attested different field retires the
; numeric omissions as well. No omitted text is retained in this history.
_KL_Hook_ScalarHistory(Intent) {
	History := Keystats.scalar_history
	Field := KLPasswordCache.current_element_id
	if !IsObject(History) || History.lifecycle != Intent.lifecycle
		|| History.generation != Intent.generation || History.hook != Intent.source_hook
		|| !(History.app == Keystats.session_app) || !(History.title == Keystats.session_title)
		|| (History.field != "" && Field != "" && !(History.field == Field)) {
		History := {position: 0, gaps: [], carry_delay: 0, lifecycle: Intent.lifecycle,
			generation: Intent.generation, hook: Intent.source_hook,
			app: Keystats.session_app, title: Keystats.session_title, field: Field}
		Keystats.scalar_history := History
	} else if Field != ""
		History.field := Field
	return History
}

; Adjacent omitted units occupy one run. Publications change one absolute
; position, not every retained gap; storage grows only with interleaved output.
_KL_Hook_ScalarOmit(History) {
	if History.gaps.Length && History.gaps[-1].position = History.position {
		Gap := History.gaps[-1]
		if Gap.units = 0x7FFFFFFFFFFFFFFF
			throw Error("Keystats omitted-unit count exhausted the native integer range.")
		Gap.units += 1
	} else {
		Gap := {position: History.position, units: 1}
		History.gaps.Push(Gap)
	}
	return Gap
}

_KL_Hook_ScalarPublished(History) {
	if !History.gaps.Length {
		History.position := 0
		return
	}
	if History.position = 0x7FFFFFFFFFFFFFFF
		throw Error("Keystats omitted-unit position exhausted the native integer range.")
	History.position += 1
}

_KL_Hook_ScalarConsume(History) {
	Gap := History.gaps[-1]
	if Gap.position != History.position || Gap.units <= 0
		throw Error("Keystats omitted-unit history is out of order.")
	Gap.units -= 1
	if !Gap.units
		History.gaps.Pop()
	if !History.gaps.Length
		History.position := 0
}

; Keep the original [BS] and counters, but never attribute deletion of a
; published scalar to a Backspace which consumed one omitted UTF-16 unit.
_KL_Hook_ScalarBackspace(History) {
	if !History.gaps.Length
		return false
	if History.gaps[-1].position = History.position {
		_KL_Hook_ScalarConsume(History)
		return true
	}
	if History.position < History.gaps[-1].position
		throw Error("Keystats omitted-unit position moved before its newest gap.")
	History.position -= 1
	return false
}

_KL_Hook_ScalarDelay(History, Delay) {
	if Delay > 0x7FFFFFFFFFFFFFFF - History.carry_delay
		throw Error("Keystats omitted-unit delay exhausted the native integer range.")
	return Delay + History.carry_delay
}

; Hold a trailing high outside serializable state under its original receipt.
; Its numeric omission survives loss of assembly permission, until observed
; editing consumes it or a real context/privacy/capture boundary retires it.
_KL_Hook_FrameCharacters(Intent, Token, &Delay) {
	History := _KL_Hook_ScalarHistory(Intent)
	Pending := Keystats.scalar_fragment
	Keystats.scalar_fragment := false
	Paired := false
	if Token != "" && _KL_Hook_ScalarOwnerCurrent(Pending, Intent)
		&& History.gaps.Length && History.gaps[-1] == Pending.gap
		&& Pending.gap.position = History.position {
		First := NumGet(StrPtr(Token), 0, "UShort")
		if First >= 0xDC00 && First <= 0xDFFF {
			_KL_Hook_ScalarConsume(History)
			Token := Pending.text . Token
			; The carry includes the original high delay and earlier omitted
			; arrivals. Low's transport endpoint never adds another key delay.
			Delay := History.carry_delay
			Paired := true
		}
	}
	Complete := ""
	Characters := _TextCodepoints(Token)
	for Index, Character in Characters {
		if _TextCompleteTailScalar(Character) != "" {
			Complete .= Character
			_KL_Hook_ScalarPublished(History)
			continue
		}
		Gap := _KL_Hook_ScalarOmit(History)
		Unit := NumGet(StrPtr(Character), 0, "UShort")
		if Index = Characters.Length && Unit >= 0xD800 && Unit <= 0xDBFF
			&& Intent.scalar_epoch = Keystats.scalar_epoch {
			Keystats.scalar_fragment := {
				text: Character, gap: Gap,
				lifecycle: Intent.lifecycle, generation: Intent.generation,
				cancelled: false, filtered: false, privacy: Intent.privacy,
				source_hook: Intent.source_hook, entry_focus: Intent.entry_focus,
				scalar_epoch: Intent.scalar_epoch, synth_active: Intent.synth_active,
				synth_private: Intent.synth_private, synth_type: Intent.synth_type,
				app: Keystats.session_app, title: Keystats.session_title
			}
		}
	}
	if Complete != "" {
		if !Paired
			Delay := _KL_Hook_ScalarDelay(History, Delay)
		History.carry_delay := 0
	} else
		History.carry_delay := _KL_Hook_ScalarDelay(History, Delay)
	return Complete
}

_KL_Hook_CommitInput(Intent) {
	EntryCritical := Critical("On")
	try {
		if !_KL_Hook_InputLifecycleCurrent(Intent)
			return false
		; VK_PACKET and its Up are transport edges between two UTF-16 units.
		; Every other keydown breaks the pending scalar, even without a token.
		BoundaryCurrent := Intent.scalar_epoch = Keystats.scalar_epoch
			&& Intent.entry_focus = KLPasswordCache.focus_generation
			&& _KL_LlmJournalPrivacyStillCurrent(Intent.entry_privacy)
		if Intent.kind = "key" && Intent.vk != 0xE7 && BoundaryCurrent {
			Keystats.scalar_fragment := false
		}
		if Intent.cancelled || !Intent.activity {
			if Intent.kind = "char" && BoundaryCurrent
				Keystats.scalar_fragment := false
			return false
		}
	} finally Critical(EntryCritical)
	; FIFO commits the named predecessor first. Only its actual canonical
	; publication can consume the matching native control-character echo.
	if Intent.kind = "char" && IsObject(Intent.echo_of) && Intent.echo_of.recorded
			&& _KL_Hook_InputLifecycleCurrent(Intent.echo_of)
		return true
	if !Intent.filtered && !_KL_LlmJournalPrivacyStillCurrent(Intent.privacy)
		Intent.filtered := true
	GuardFn := _KL_Hook_InputCurrent.Bind(Intent)
	delay := KL_Hook_NoteActivity(false, !Intent.filtered, Intent.tick,
		Intent.synth_active, GuardFn)
	if !GuardFn.Call() {
		if !_KL_Hook_InputLifecycleCurrent(Intent)
			return false
		Intent.filtered := true
		delay := KL_Hook_NoteActivity(false, false, Intent.tick,
			Intent.synth_active, GuardFn)
		if !GuardFn.Call()
			return false
	}
	if Intent.filtered {
		PrivacyCritical := Critical("On")
		try {
			PendingScalar := Keystats.scalar_fragment
			if Intent.scalar_epoch = Keystats.scalar_epoch
				&& Intent.entry_focus = KLPasswordCache.focus_generation
				&& _KL_LlmJournalPrivacyStillCurrent(Intent.entry_privacy) {
				Keystats.scalar_fragment := false
				Keystats.scalar_history := false
			} else if IsObject(PendingScalar) && !_KL_Hook_InputCurrent(PendingScalar)
				Keystats.scalar_fragment := false
		} finally Critical(PrivacyCritical)
		if IsSet(KL_Roi_DiscardWord)
			KL_Roi_DiscardWord()
		KL_RecordPrivacyHit()
		return true
	}
	if Intent.shortcut != ""
		try KL_LogShortcut(Intent.shortcut, Keystats.session_app, GuardFn)
	Token := Intent.kind = "char" ? Intent.character
		: (KLHOOK_SPECIAL.Has(Intent.vk) ? KLHOOK_SPECIAL[Intent.vk] : "")
	Recorded := KL_Hook_RecordedChar(Token, Intent.synth_private)
	PreviousCritical := Critical("On")
	try {
		if !GuardFn.Call()
			return false
		if Intent.kind = "key" && !KLHOOK_SPECIAL.Has(Intent.vk)
			return true
		if Intent.kind = "key"
			meta := Map("kc", Intent.vk, "sk", Intent.sc)
		else {
			meta := Map()
			if Intent.arrival_vk > 0
				meta["kc"] := Intent.arrival_vk
			if Intent.arrival_sc > 0
				meta["sk"] := Intent.arrival_sc
		}
		if Intent.synth_active {
			if IsSet(KL_Roi_DiscardWord)
				KL_Roi_DiscardWord()
			meta["s"] := 1
			meta["st"] := Intent.synth_type
		}
		if Intent.kind = "char" {
			Recorded := _KL_Hook_FrameCharacters(Intent, Recorded, &delay)
			if Recorded == ""
				return true
		}
		if Intent.kind = "key" {
			History := _KL_Hook_ScalarHistory(Intent)
			if Intent.vk = 0x08
				Intent.scalar_backspace := _KL_Hook_ScalarBackspace(History)
			else if Intent.vk = 0x0D || Intent.vk = 0x09
				_KL_Hook_ScalarPublished(History)
			; Transfer omitted callback time once, independently of which gap
			; a later correction consumes. Cache/synthetic revocation cannot
			; lose this numeric receipt or charge it to multiple publications.
			delay := _KL_Hook_ScalarDelay(History, delay)
			History.carry_delay := 0
		}
		if Intent.scalar_backspace
			meta["erase"] := 0
		Keystats.buffer_events.Push([Recorded, delay, meta])
		Intent.recorded := true
		if Intent.kind = "char"
			Keystats.buffer_text .= Recorded
		else {
			switch Intent.vk {
				case 0x08:
					if !Intent.scalar_backspace
						Keystats.buffer_text := KLW_PopLast(Keystats.buffer_text)
				case 0x0D: Keystats.buffer_text .= Chr(10)
				case 0x09: Keystats.buffer_text .= Chr(9)
			}
		}
		if Intent.synth_active
			KLHook.last_tick := 0
	} finally Critical(PreviousCritical)
	if !Intent.synth_active {
		if !GuardFn.Call()
			return false
		try {
			ErgoFn := HasMethod(Intent.ergo_fn, "Call") ? Intent.ergo_fn : KL_Ergo_OnKeystroke
			if Intent.kind = "char"
				ErgoFn.Call(delay, Intent.arrival_vk, Intent.arrival_sc)
			else
				ErgoFn.Call(delay, Intent.vk, Intent.sc, Intent.vk = 0x08)
		}
		; Ergonomic publication can yield and revoke this arrival.
		if !GuardFn.Call() {
			if IsSet(KL_Roi_DiscardWord)
				KL_Roi_DiscardWord()
			return false
		}
		if Intent.kind = "char" {
			try KL_Roi_OnChar(Recorded)
			if !GuardFn.Call()
				return false
			try WPMWidget_Push(false, false)
		} else if !Intent.scalar_backspace
			try KL_Roi_OnKey(Intent.vk)
	}
	return true
}

KL_Hook_OnChar(ih, c, FilterFn := unset, NowTick := unset, ErgoFn := unset) {
	if KL_CaptureHeld() || !Keystats.initialized
		return
	Intent := false
	_hpKlIngest := HotPath_Now()
	try {
		Intent := _KL_Hook_CaptureInput("char", c, 0, 0, FilterFn?, NowTick?, ErgoFn?, ih)
		if !IsObject(Intent)
			return
		try Intent.filtered := HasMethod(Intent.filter_fn, "Call")
			? Intent.filter_fn.Call() : MF_ShouldFilter()
		catch as FilterErr
			try LoggerWarn("keystats_hook", "Character privacy classification failed closed: {1}.", FilterErr.Message)
		_KL_Hook_PrepareInput(Intent)
	} catch as kl_err {
		try LoggerError("keystats_hook", "KL_Hook_OnChar unhandled exception — hook kept alive: {1}", kl_err.Message)
	} finally {
		if IsObject(Intent)
			_KL_Hook_CompleteInput(Intent)
		HotPath_LogIfSlow("KL.Ingest", _hpKlIngest, "")
	}
}

KL_Hook_OnKeyDown(ih, vk, sc, FilterFn := unset, NowTick := unset, ShortcutFn := unset, ErgoFn := unset) {
	if KL_CaptureHeld()
		return
	Intent := false
	PotentialFocusMove := vk = 0x09
	try {
		Intent := _KL_Hook_CaptureInput("key", "", vk, sc, FilterFn?, NowTick?, ErgoFn?, ih)
		if !IsObject(Intent)
			return
		try Intent.shortcut := IsSet(ShortcutFn)
			? ShortcutFn.Call(vk, sc) : KL_Watchers_DetectShortcut(vk, sc)
		Intent.activity := Intent.shortcut != "" || KLHOOK_SPECIAL.Has(vk)
		if Intent.activity {
			try Intent.filtered := HasMethod(Intent.filter_fn, "Call")
				? Intent.filter_fn.Call() : MF_ShouldFilter()
			catch as FilterErr
				try LoggerWarn("keystats_hook", "Key/Shortcut privacy classification failed closed: {1}.", FilterErr.Message)
		}
		_KL_Hook_PrepareInput(Intent)
	} catch as kl_err {
		try LoggerError("keystats_hook", "KL_Hook_OnKeyDown unhandled exception — hook kept alive: {1}", kl_err.Message)
	} finally {
		try {
			if PotentialFocusMove
				_KL_Hook_InvalidateTabInput(Intent)
		} catch as FocusErr
			try LoggerError("keystats_hook", "Physical Tab invalidation failed: {1}.", FocusErr.Message)
		if IsObject(Intent)
			_KL_Hook_CompleteInput(Intent)
	}
}


; A released key cannot authorize dropping a later standalone LF/Tab payload.
KL_Hook_OnKeyUp(ih, vk, sc) {
	PreviousCritical := Critical("On")
	try {
		Echo := KLHook.control_char_echo
		if IsObject(Echo) && IsObject(ih) && Echo.source_hook == ih && Echo.vk = vk && Echo.sc = sc
			KLHook.control_char_echo := false
	} finally Critical(PreviousCritical)
}


; What the typing row is allowed to KEEP of a captured token.
;
; This InputHook observes the driver's OWN auto-typed output — that is why
; KL_MarkSynthetic exists — so an @iban★ expansion arrives here character by
; character, exactly like manual typing, roughly 90 ms before the redacted
; hotstring row is written. Stamping those characters s=1 said WHERE they came
; from and still persisted WHAT they were, into the same file, one row earlier.
;
; Length-preserving on purpose: the row's own arithmetic (WPM char counts, the
; walker's per-event alignment with ``events``) is StrLen-based, and Linux's
; recorded_char() makes exactly this trade for exactly this reason.
;
; Bracket markers ([BS], [ENTER], …) are returned untouched. They are the closed
; KLHOOK_SPECIAL token set, they carry no content of the secret, and rewriting
; them would desynchronise the walker's deletion accounting — the same exemption
; Linux states for [BS].
; @param token {String} The character, or the bracket marker, about to be recorded.
; @return {String} The token, or a length-preserving redaction of it.
KL_Hook_RecordedChar(token, Private := unset) {
		; One boolean read on the ordinary keystroke path — nothing else runs
		; unless the driver is mid-expansion of the user's own data.
		if !(IsSet(Private) ? Private : Keystats.synth_private)
				return token
		if (Type(token) != "String" or token == "")
				return token
		if (SubStr(token, 1, 1) == "[" and SubStr(token, -1) == "]")
				return token
		return PersonalInfoRedactForLog(token)
}









; =================================
; =================================
; ======= 5/ Periodic flush =======
; =================================
; =================================

KL_Hook_Tick() {
		if A_IsSuspended
				return
		; Fire only when the buffer has something to commit. KL_IngestOnce is
		; NOT called here — it carries a FileAppend to data.sql that runs on
		; the same AHK thread and would block incoming keystroke callbacks,
		; causing perceptible input lag at high typing speed. The 5 s ingest
		; timer in keystats.ahk handles persistence asynchronously.
		if (Keystats.buffer_events.Length = 0
				&& Keystats.session_clicks = 0
				&& Keystats.session_scrolls = 0 && Keystats.mouse_distance = 0)
				return
		try KL_FlushBuffer()
		; Re-arm the debounce timer so the dashboard sees the flush within
		; LIVE_PUSH_DEBOUNCE_MS after the last keystroke in the burst.
		; Using a negative period turns SetTimer into a one-shot; re-calling
		; it before it fires resets the countdown, coalescing burst activity.
		if !KLHook.HasOwnProp("live_push_timer") || !IsObject(KLHook.live_push_timer)
				KLHook.live_push_timer := KL_Hook_LivePush.Bind()
		SetTimer(KLHook.live_push_timer, -KLHookConst.LIVE_PUSH_DEBOUNCE_MS)
}

KL_Hook_LivePush() {
		if A_IsSuspended
				return
		; Manifest-only rebuild — fast (~20 ms with the manifest cache warm)
		; and enough for the KPI bar and WPM widget to update in near-real time.
		; The full "live" rebuild (heatmaps + top-500 n-grams, ~150-300 ms) is
		; left to the 5 s ingest cycle so it never runs on the flush thread.
		try KLWV_NotifyIngest("manifest")
}





; ============================
; ============================
; ======= 6/ Lifecycle =======
; ============================
; ============================

KL_Hook_Start() {
		if IsObject(KLHook.context_stop)
			return false
		; Idempotent — multiple Start calls are no-ops once subscribed.
		if KLHook.HasOwnProp("registered") && KLHook.registered
				return
		KL_PasswordFocusTrackingStart()

		; Subscribe the keystats's keyboard handlers to the shared HookDispatcher
		; instead of opening a second InputHook. The dispatcher already owns the
		; process-wide InputHook (identical "V L0 I1" + KeyOpt {All} +N + NotifyNonText
		; options) and already carries the keystats's mouse subscribers, so this
		; collapses one per-keystroke hook callback into the shared fan-out.
		; Dispatch gates on A_IsSuspended, so the handlers stay silent under pause
		; exactly as the standalone hook's own guard did.
		; Seed before subscription: an admitted callback must not be overwritten by Start.
		PreviousCritical := Critical("On")
		try {
			Keystats.scalar_fragment := false
			Keystats.scalar_history := false
			Keystats.scalar_epoch += 1
			KLHook.capture_generation += 1
			KLHook.capture_stopping := false
			KLHook.last_vk := 0
			KLHook.last_sc := 0
			KLHook.last_hint_lifecycle := Keystats.lifecycle_generation
			KLHook.control_char_echo := false
			KLHook.last_tick := A_TickCount
		} finally Critical(PreviousCritical)
		KLHook.cb_char := KL_Hook_OnChar.Bind()
		KLHook.cb_down := KL_Hook_OnKeyDown.Bind()
		KLHook.cb_up := KL_Hook_OnKeyUp.Bind()
		HookDispatcher.Register(HookDispatcherConst.EVT_KB_CHAR, KLHook.cb_char)
		HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, KLHook.cb_down)
		HookDispatcher.Register(HookDispatcherConst.EVT_KB_UP, KLHook.cb_up)
		KLHook.registered := true

		; Bind the flush callback once and keep the reference around so
		; SetTimer(…, 0) can stop it cleanly later.
		KLHook.flush_timer := KL_Hook_Tick.Bind()
		SetTimer(KLHook.flush_timer, KLHookConst.FLUSH_PERIOD_MS)

		; Project the canonical focus snapshot from memory on a resident timer. The
		; metrics owner seeds its bounded snapshot before KL_Hook_Start, so the first
		; keystroke has context without any target-window call on this path.
		KL_Hook_RefreshContext(true)
		KLHook.context_timer := KL_Hook_RefreshContext.Bind()
		SetTimer(KLHook.context_timer, KLHookConst.CONTEXT_REFRESH_MS)
}

KL_Hook_Stop(AppendFn := unset) {
		KL_Hook_InvalidateCapture(true)
		Generation := KLHook.capture_generation
		Closed := false
		try Closed := _KL_ContextCloseTail(AppendFn?)
		catch as Failure
			try LoggerError("Keystats", "Context tail close remains pending: {1}.", Failure.Message)
		PreviousCritical := Critical("On")
		try {
			Stop := KLHook.context_stop
			if !_KL_ContextStopCurrent(Stop, Generation)
				return false
			Resources := {}
			for Field in ["flush_timer", "context_timer", "live_push_timer", "cb_char", "cb_down", "cb_up"]
				Resources.%Field% := KLHook.HasOwnProp(Field) ? KLHook.%Field% : false
		} finally Critical(PreviousCritical)
		; Only cancel the exact resources captured by this stop attempt. A nested
		; stop may finish and a successor may start while native teardown returns.
		ResourcesStopped := true
		for Field in ["flush_timer", "context_timer", "live_push_timer"] {
			if !_KL_ContextStopCurrent(Stop, Generation)
				return false
			if IsObject(Resources.%Field%) {
				try SetTimer(Resources.%Field%, 0)
				catch
					ResourcesStopped := false
			}
		}
		for Binding in [["cb_char", HookDispatcherConst.EVT_KB_CHAR], ["cb_down", HookDispatcherConst.EVT_KB_DOWN],
			["cb_up", HookDispatcherConst.EVT_KB_UP]] {
			if !_KL_ContextStopCurrent(Stop, Generation)
				return false
			if IsObject(Resources.%Binding[1]%) {
				try HookDispatcher.Unregister(Binding[2], Resources.%Binding[1]%)
				catch
					ResourcesStopped := false
			}
		}
		PreviousCritical := Critical("On")
		try {
			if !_KL_ContextStopCurrent(Stop, Generation)
				return false
			if ResourcesStopped
				KLHook.registered := false
		} finally Critical(PreviousCritical)
		; Preserve both the close receipt and its classifier through final flush.
		; The gate also protects a detached typing snapshot against a nested stop.
		Flushed := false, PasswordStopped := false
		try Flushed := !Keystats.initialized || KL_FlushBuffer(_KL_ContextStopCurrent.Bind(Stop, Generation))
		if !_KL_ContextStopCurrent(Stop, Generation)
			return false
		if Closed && Flushed && ResourcesStopped
			try PasswordStopped := KL_PasswordFocusTrackingStop()
		PreviousCritical := Critical("On")
		try {
			if !_KL_ContextStopCurrent(Stop, Generation)
				return false
			if Closed && Flushed && ResourcesStopped && PasswordStopped {
				KLHook.context_stop := false
				return true
			}
			return false
		} finally Critical(PreviousCritical)
}


#Include keystats_context_owner.ahk
