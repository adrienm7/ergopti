; infra/hotstrings/hotstring_inputhook.ahk

; ==============================================================================
; MODULE: Hotstring Prefix Watcher — Input Hook & Public API
; DESCRIPTION:
; Globals, public lifecycle API (HotstringPrefixWatcherInit / Stop /
; RebuildIndex), and InputHook callbacks that implement the live prefix preview.
; Registry-construction helpers live in hotstring_registry.ahk.
;
; FEATURES & RATIONALE:
; 1. Single InputHook in pass-through mode (V flag) so the watcher observes
;    every keystroke without intercepting it.
; 2. Debounced render (_PREFIX_RENDER_DEBOUNCE_MS = 150 ms) — continuous
;    typing produces no tooltip rebuild; the preview surfaces on the
;    deliberate pause before the magic-key press.
; 3. Suppression depth counter (_PrefixWatcherSuppressed) — refcount semantics
;    so nested suppress/release pairs from concurrent paths balance correctly.
; 4. Deferred fire-log drain — KL_LogHotstring runs off the synchronous
;    keystroke path to prevent a logging spike from stretching the suppress
;    window and swallowing typed characters.
;
; Included by infra/hotstrings/hotstring_prefix_watcher.ahk.
; ==============================================================================

; Auxiliary file catalogue built at boot. Map(lowerPrefix -> Array of entries),
; where each entry is { Trigger, Output, Category, Section, Length }. It is kept
; for catalogue diagnostics/tests only; visible candidate selection belongs to
; HSE_PreviewNextDecision and never reads this Map.
global _PrefixIndex := Map()

; Flat set of all known trigger strings (lower-cased) → entry object.
; Used by the near-miss detector in _ResetPrefixBuffer so it can check
; exact trigger equality and Levenshtein-1 neighbours without re-walking
; the prefix tree.
global _TriggerSet := Map()

; Live display buffer with original casing preserved. Candidate selection reads
; the engine's HSE_Buffer; this sibling tracks the same screen context for
; lifecycle invalidation, analytics and post-fire rendering. Trimmed to
; MAX_BUFFER_LEN whenever it would overflow so memory stays bounded.
global _PrefixBuffer := ""
; Monotonic owner for the exact text represented by _PrefixBuffer. Lifecycle
; generation is intentionally separate: ordinary physical typing stays in one
; lifecycle but must still invalidate a render that yielded in GUI/UIA work.
global _PrefixContentGeneration := 0

; The control identity and monotonically increasing generation to which BOTH
; HSE_Buffer and _PrefixBuffer belong. A top-level window can host several input
; controls, so foreground-window identity alone is not sufficient: Ctrl+F and
; Ctrl+L routinely move focus without producing an OnChar event. Every physical
; character verifies this token before the engine can consume it.
global _PrefixFocusedControlToken := 0
global _PrefixInputContextGeneration := 0

; Set when a PRIVATE expansion has written its resolved value into the buffers.
; After a star fire the watcher takes the engine's buffer verbatim, so
; _PrefixBuffer then holds the IBAN itself rather than the six characters the
; user typed — and the render that follows needs no further keystroke to print
; it. The diagnostic lines consult this through _PrefixLogSafe.
global _PrefixPrivateResidue := false

; Reference to the running InputHook (kept global so the GC does not collect
; it and so that the watcher can be reset / stopped at shutdown).
global _PrefixInputHook := 0

; Set when HotstringPrefixWatcherRebuildIndex is asked to rebuild while the driver
; is suspended. The rebuild is deferred and replayed by Ergopti_OnSuspendResume,
; mirroring LLM_Menu_OnResume, so near-miss analytics do not stay stale.
global _PrefixIndexRebuildPending := false

; When True, OnChar / OnKeyDown callbacks short-circuit. Toggled by the
; hotstring engine while it is replaying characters via SendEvent so the
; InputHook does not mistake AHK's own output for fresh user input. After
; an expansion fires, the buffer would otherwise drift into ``c'était`` and
; surface unrelated triggers like ``taiwan`` (Taïwan) on the next refresh.
global _PrefixWatcherSuppressed := 0  ; depth counter — mirrors HSE_Suppressed refcount semantics

; Currently-suggested hotstring — populated when a tooltip transitions
; from hidden to visible, cleared when the tooltip hides (and a dismissed
; event is logged) or when a fire consumes the suggestion (silent clear).
; Object shape: { Trigger, Output, Category } or "" when no tooltip is up.
; Used to mirror Hammerspoon's M.log_hotstring_suggested / dismissed pair
; logging — HS pairs every "suggested" with exactly one "dismissed" or one
; "fired", never both, so we track state here to enforce the same contract.
global _KLLastShownSuggestion := ""

; Canonical engine decisions currently represented by visible tooltip pixels.
; They are published only after the renderer reveals the surface and cleared by
; every authorised hide. A dynamic replacement may therefore be resolved once
; for the preview and claimed by dispatch without a second, divergent call.
global _PrefixVisibleFireDecisions := []

; Configuration constants.
global _MIN_PREFIX_LEN := 2
; Mirrors the shared cap _shared/lua/hotstring_engine/init.lua BUFFER_MAX_CHARS
; (256) so a long trigger matches identically on all three drivers — Windows was
; 64, which silently failed to match triggers of 65-256 chars that macOS/Linux
; matched. Pinned equal by tools/test/test-hotstring-buffer-cap-parity.cjs.
global _MAX_BUFFER_LEN := 256

; Per-keystroke tooltip renders are coalesced through this debounce window so the
; ~60 ms TooltipShow rebuild (Gui destroy + recreate + layered border + DWM, per
; the HotPath profiler) never lands on the synchronous keystroke path. Must exceed
; a fast typist's inter-keystroke gap (~120-150 ms) so continuous typing produces
; NO render at all; the preview then appears on the deliberate pause that precedes
; a magic-key press. Lowered once the render itself is made cheap (GUI reuse).
global _PREFIX_RENDER_DEBOUNCE_MS := 150

; Hotstring-fired metrics logging (KL_LogHotstring: buffer flush + JSONL append +
; per-char WPM pushes) is analytics, NOT user-facing, yet it ran synchronously on
; the fire keystroke. A disk/app-lookup spike there pushes OnChar past the engine's
; 60 ms suppress window, which then stretches (the deferred release can only fire
; once OnChar returns — AHK is single-threaded) and SWALLOWS the keys typed during
; it ("abcd"->"acd"). So the fire enqueues a lightweight record (O(1)) and a
; one-shot timer drains it. The delay is deliberately GREATER than the suppress
; release (HSE_SUPPRESS_RELEASE_DELAY_MS, 60 ms) so the drain can never run before —
; and thus never delay — that release. Margin keeps it clear of timer jitter.
global HSE_FIRE_LOG_DEFER_MS := 90
global _HSE_FireLogQueue := []
global _HSE_FireLogScheduled := false
global _HSE_FireLogScheduledGeneration := -1
global _HSE_FireLogTimer := 0

; Every timer carrying captured hotstring state belongs to one lifecycle
; generation. Suspend/stop invalidates that generation before any teardown, so
; an already-dispatched callback can no longer publish a pre-transition buffer.
; Fired records are deliberately retained and transferred to a fresh owner on
; resume; near-miss/render work is derived state and is simply recomputed.
global _PrefixDeferredGeneration := 0
global _PrefixRenderScheduledGeneration := -1
global _PrefixRenderTimer := 0

; What a diagnostic line may print of a keystroke buffer.
;
; The buffers are ordinarily the user's own typing and printing them is the
; whole point of the DEBUG trace — a hotstring that fails to match is diagnosed
; from exactly these two strings. What they must never print is the value a
; private expansion put INTO them, which is not typed by the user at all.
;
; The residue is cleared lazily rather than at the fire site because neither a
; word terminator nor a backspace empties the engine's buffer (it deliberately
; keeps terminators so a trigger may contain one), so there is no single later
; event that means « the replacement is gone from both buffers ». Asking the
; buffers themselves is the only answer that cannot be wrong in the unsafe
; direction.
; @param Text {String} The buffer about to be interpolated into a log line.
; @return {String} Text, or a length-preserving redaction of it.
_PrefixLogSafe(Text) {
	global _PrefixPrivateResidue, _PrefixBuffer, HSE_Buffer
	if !_PrefixPrivateResidue
		return Text
	if (_PrefixBuffer == "" and HSE_Buffer == "") {
		_PrefixPrivateResidue := false
		return Text
	}
	return PersonalInfoRedactForLog(Text)
}

; The preview boundary set. NOT a cached copy any more: it delegates to the
; matcher's own derivation so the tooltip and the engine cannot answer the
; word-boundary question differently. A cache here was tried twice — first a
; compile-time snapshot, then a refreshed copy built from a WIDER expression
; than the matcher used — and both drifted, each time producing suggestions the
; engine then refused to fire.
_PrefixWordBoundaries() {
    return _HSE_WordBoundarySet()
}

; Categories scanned into the auxiliary near-miss catalogue at boot. Collision
; ordering for visible rows is owned exclusively by the live engine registry.
global _PREFIX_WATCHER_CATEGORIES := [
    "distancesreduction", "sfbsreduction", "rolls",
    "autocorrection", "magickey", "personal"
]

; _UIA_WRAP_PAIRS is no longer the runtime lookup table.
; The PrefixWatcher now delegates to WrapSymbols_GetActivePairs() (wrap_symbols_config.ahk)
; so the user can enable/disable individual symbols from the menu without a Reload.
; This global is kept as a compile-time constant for the legacy WrapTextIfSelected()
; call in modules/keymap/layout.ahk (Win+O gesture) which does not use the active-pairs path.
global _UIA_WRAP_PAIRS := Map(
    "(", Map("left", "(", "right", ")"),
    ")", Map("left", "(", "right", ")"),
    "[", Map("left", "[", "right", "]"),
    "]", Map("left", "[", "right", "]"),
    "{", Map("left", "{", "right", "}"),
    "}", Map("left", "{", "right", "}"),
    "<", Map("left", "<", "right", ">"),
    ">", Map("left", "<", "right", ">"),
    Chr(0x22), Map("left", Chr(0x22), "right", Chr(0x22)),
    "'", Map("left", "'", "right", "'"),
    Chr(0x60), Map("left", Chr(0x60), "right", Chr(0x60)),
    "*",  Map("left", "*",  "right", "*" ),
    "_",  Map("left", "_",  "right", "_" ),
    "~",  Map("left", "~",  "right", "~" ),
    "|",  Map("left", "|",  "right", "|" ),
    "/",  Map("left", "/",  "right", "/" ),
    Chr(0x5C), Map("left", Chr(0x5C), "right", Chr(0x5C)),
    "@",  Map("left", "@",  "right", "@" ),
    "#",  Map("left", "#",  "right", "#" ),
    "%",  Map("left", "%",  "right", "%" ),
    "$",  Map("left", "$",  "right", "$" ),
    "&",  Map("left", "&",  "right", "&" ),
    "!",  Map("left", "!",  "right", "!" ),
    "?",  Map("left", "?",  "right", "?" ),
    "+",  Map("left", "+",  "right", "+" ),
    "=",  Map("left", "=",  "right", "=" ),
    ";",  Map("left", ";",  "right", ";" ),
    ":",  Map("left", ":",  "right", ":" ),
    Chr(0xAB) . " ", Map("left", Chr(0xAB) . " ", "right", " " . Chr(0xBB)),
    " " . Chr(0xBB), Map("left", Chr(0xAB) . " ", "right", " " . Chr(0xBB))
)




; ============================================================
; ============================================================
; ======= 1/ Public API =====================================
; ============================================================
; ============================================================

; Start the InputHook. The auxiliary catalogue is built later for analytics.
; Idempotent — calling it twice is a no-op (the second call only logs).
HotstringPrefixWatcherInit() {
	global _PrefixInputHook
	if _PrefixInputHook {
		LoggerWarn("PrefixWatcher", "Init called twice — ignoring duplicate.")
		return
	}
	LoggerStart("PrefixWatcher", "Initializing prefix watcher…")

	; The ~3180-entry analytics catalogue is deferred to the boot tail. Preview is
	; already complete during that window because it asks the live engine directly.
	_StartInputHook()
	_InstallMouseClickResetHooks()
	LoggerSuccess("PrefixWatcher", "Watcher started (index build deferred off the boot path).")
	; LLM bridge must attach to this InputHook — Ollama bootstrap often
	; completes before we exist; honour a deferred start request here.
	if (IsSet(LLM_Menu_TryStartBridge))
		LLM_Menu_TryStartBridge()
	else if (IsSet(LLM_Bridge_OnPrefixWatcherReady))
		LLM_Bridge_OnPrefixWatcherReady()
}

; Mouse clicks move the cursor to a position we cannot observe — the
; InputHook never sees them. Register pass-through hotkeys on the three
; primary buttons so HSE can wipe its buffer and refuse to assume a
; word boundary on the new cursor's left. ``~`` keeps the click going
; through to the active window unchanged.
_InstallMouseClickResetHooks() {
	; Subscribe via HookDispatcher — a bare Hotkey("~LButton", …) would replace
	; the dispatcher's handler, silencing every other mouse subscriber including
	; the LLM pointer-dismiss watcher (mouse-hotkey-clobber).
	HookDispatcher.Register(HookDispatcherConst.EVT_MS_LDOWN, _OnMouseClickReset.Bind())
	HookDispatcher.Register(HookDispatcherConst.EVT_MS_MDOWN, _OnMouseClickReset.Bind())
	HookDispatcher.Register(HookDispatcherConst.EVT_MS_RDOWN, _OnMouseClickReset.Bind())
}

_OnMouseClickReset(*) {
	try {
		; A click places the cursor at an unknown position, but the next
		; keystroke will start a fresh run — treat it as a word boundary so
		; is_word triggers (e.g. "c★ → c'est") fire immediately.
		_PrefixInvalidateInputContext(0, true)
		if IsSet(LLM_Bridge_ResetPredictions)
			LLM_Bridge_ResetPredictions()
	} catch as Err {
		LoggerError("PrefixWatcher", "Mouse-click reset failed: {1}.", Err.Message)
	}
}

; ─── Suggestion lifecycle helpers ────────────────────────────────────────
; Suggested / dismissed events are written from a single state machine so
; the JSONL never contains an unmatched dismissed event, nor two suggested
; events back-to-back for the same trigger. The state lives in
; ``_KLLastShownSuggestion``: "" when no tooltip is up, an object otherwise.
;
; ``_NotifySuggestionShown`` fires when a tooltip is rendered. If the same
; trigger is re-displayed (the user kept typing characters that all map to
; the same suggested expansion), we do NOT re-emit a suggested event — HS
; only logs once per visibility cycle. When a different trigger replaces
; the previous one, we emit a dismissed for the old one then a suggested
; for the new one.
;
; ``_NotifySuggestionDismissed`` fires when the tooltip hides for any
; reason other than a fire (buffer reset, prefix lost, word terminator,
; mouse click). The fire path uses the silent-clear variant below so the
; suggestion is not double-counted as both fired and dismissed.
_NotifySuggestionShown(Trigger, Output, Category, IsPrivate := false) {
	global _KLLastShownSuggestion
	Prev := _KLLastShownSuggestion
	if (IsObject(Prev) and Prev.Trigger == Trigger and Prev.Output == Output) {
		return
	}
	if IsObject(Prev) {
		_KLEmitSuggestionDismissed(Prev)
	}
	; The flag travels ON the record: the dismissal fires from a different
	; function, long after this one returned, so it cannot look the answer up
	; again.
	_KLLastShownSuggestion := { Trigger: Trigger, Output: Output, Category: Category,
	                            IsPrivate: IsPrivate ? true : false }
	; A private mapping is withheld WHOLE, exactly as macOS withholds it: both
	; columns are secrets — the replacement IS the IBAN and the trigger is a
	; fragment of it — so redacting one and keeping the other still leaks. The
	; state machine above still ran, so a non-private suggestion this one
	; replaces is still paired with its dismissal.
	if IsPrivate {
		return
	}
	try KL_LogHotstringSuggested(Trigger, Output, Category)
}

; Emit the dismissal for a previously-shown suggestion — unless it was private,
; in which case the suggested/dismissed pair is withheld whole and writing only
; the second half would put the value in the log by the back door.
_KLEmitSuggestionDismissed(Rec) {
	if (Rec.HasOwnProp("IsPrivate") and Rec.IsPrivate) {
		return
	}
	; A token-aware post-present callback may be invalidated while the keylogger
	; performs privacy checks. In that case no suggested row reached the queue, so
	; emitting its dismissed half would corrupt the lifecycle pair.
	if (Rec.HasOwnProp("SuggestedPublished") and !Rec.SuggestedPublished)
		return
	try KL_LogHotstringDismissed(Rec.Trigger, Rec.Output, Rec.Category)
}

; A record is detached from shared state before this phase, so deferring its
; logger work cannot clear or otherwise affect a newer suggestion owner.
_PrefixEmitDetachedSuggestionDismissal(Rec) {
	if !IsObject(Rec)
		return false
	if A_IsCritical {
		SetTimer(_PrefixEmitDetachedSuggestionDismissal.Bind(Rec), -1)
		return true
	}
	_KLEmitSuggestionDismissed(Rec)
	return true
}

_NotifySuggestionDismissed() {
	global _KLLastShownSuggestion
	Prev := 0
	PreviousCritical := Critical("On")
	try {
		Prev := _KLLastShownSuggestion
		if !IsObject(Prev)
			return false
		_KLLastShownSuggestion := ""
	} finally {
		Critical(PreviousCritical)
	}
	_PrefixEmitDetachedSuggestionDismissal(Prev)
	return true
}

; A direct (LLM/notification) surface replaces hotstring pixels by publishing
; zero FireDecisions. Close the old metric owner only while that replacement's
; immutable surface token is still current; logging happens after the pure
; detach and cannot mutate a newer owner.
_NotifySuggestionDismissedForSurfaceReplacement(SurfaceToken) {
	global _KLLastShownSuggestion
	Prev := 0
	PreviousCritical := Critical("On")
	try {
		if !TooltipSurfaceTokenIsCurrent(SurfaceToken)
			return false
		Prev := _KLLastShownSuggestion
		_KLLastShownSuggestion := ""
	} finally {
		Critical(PreviousCritical)
	}
	_PrefixEmitDetachedSuggestionDismissal(Prev)
	return true
}

; Silent clear — used by the fire path so a single user action emits
; ``hotstring`` (fired) without a paired ``hotstring_dismissed``.
_NotifySuggestionConsumed() {
	global _KLLastShownSuggestion
	PreviousCritical := Critical("On")
	try _KLLastShownSuggestion := ""
	finally Critical(PreviousCritical)
}

; A fire resolves the suggestion instead of dismissing it. Detach that metric
; owner before TooltipHide clears the visible decisions, otherwise the hide
; callback can emit a dismissed row for the same suggestion that just fired.
_PrefixRetireConsumedSuggestion(DbgTag, HideFn := 0) {
	PreviousCritical := Critical("On")
	try {
		_NotifySuggestionConsumed()
		if HasMethod(HideFn, "Call")
			return HideFn.Call(DbgTag, true)
		return TooltipHide(DbgTag, true)
	} finally {
		Critical(PreviousCritical)
	}
}

_PrefixSuggestionMarkPublished(Record) {
	Record.SuggestedPublished := true
}

; A same-text surface may reuse a metric record only after its suggested row
; actually reached the keylogger queue. An unpublished record is still owned by
; the yielded publisher that created it; lending it to another surface creates
; an ABA cleanup race when the first publisher resumes.
_PrefixSuggestionRecordIsPublished(Record) {
	return IsObject(Record)
		and (!Record.HasOwnProp("SuggestedPublished")
			or Record.SuggestedPublished)
}

_PrefixSuggestionRecordOwnsSurface(Record, SurfaceToken) {
	return IsObject(Record) and Record.HasOwnProp("SurfaceToken")
		and IsObject(Record.SurfaceToken) and IsObject(SurfaceToken)
		and ObjPtr(Record.SurfaceToken) == ObjPtr(SurfaceToken)
}

; Clear only the exact record + surface pair installed by this publisher. Object
; identity alone is insufficient because the historical same-text fast path
; mutated SurfaceToken in place while the original guarded log call had yielded.
_PrefixClearSuggestionIfOwned(Record, SurfaceToken) {
	global _KLLastShownSuggestion
	PreviousCritical := Critical("On")
	try {
		if (IsObject(Record) and IsObject(_KLLastShownSuggestion)
			and ObjPtr(_KLLastShownSuggestion) == ObjPtr(Record)
			and _PrefixSuggestionRecordOwnsSurface(Record, SurfaceToken)) {
			_KLLastShownSuggestion := ""
			return true
		}
	} finally {
		Critical(PreviousCritical)
	}
	return false
}

; Atomically bind the metric state to the surface that actually won the pixel
; commit, while leaving privacy checks and keylogger work outside Critical. The
; keylogger's final queue mutation rechecks the same token and marks the record
; published in that transaction, preserving suggested/dismissed pairing even if
; OnChar invalidates the surface during privacy filtering.
_NotifySuggestionShownForSurface(Trigger, Output, Category, IsPrivate,
	SurfaceToken) {
	global _KLLastShownSuggestion
	Prev := 0
	Record := 0
	PreviousCritical := Critical("On")
	try {
		if !TooltipSurfaceTokenIsCurrent(SurfaceToken)
			return false
		Prev := _KLLastShownSuggestion
		if (IsObject(Prev) and _PrefixSuggestionRecordIsPublished(Prev)
			and Prev.Trigger == Trigger
			and Prev.Output == Output) {
			Prev.SurfaceToken := SurfaceToken
			return true
		}
		Record := { Trigger: Trigger, Output: Output, Category: Category,
			IsPrivate: IsPrivate ? true : false, SurfaceToken: SurfaceToken,
			SuggestedPublished: false }
		_KLLastShownSuggestion := Record
	} finally {
		Critical(PreviousCritical)
	}

	; Replacement dismissed the old visible suggestion at the atomic surface
	; commit. This log is about that old owner and is independent of whether the
	; new surface survives its guarded suggested publication below.
	if IsObject(Prev)
		_KLEmitSuggestionDismissed(Prev)
	if IsPrivate
		return true

	Published := false
	if IsSet(KL_LogHotstringSuggestedGuarded) {
		try Published := KL_LogHotstringSuggestedGuarded(Trigger, Output,
			Category, TooltipSurfaceTokenIsCurrent.Bind(SurfaceToken),
			_PrefixSuggestionMarkPublished.Bind(Record))
	} else if TooltipSurfaceTokenIsCurrent(SurfaceToken) {
		; Headless unit harnesses do not include the production keylogger. Preserve
		; their recording stub while production always uses the guarded queue path.
		try {
			KL_LogHotstringSuggested(Trigger, Output, Category)
			Record.SuggestedPublished := true
			Published := true
		} catch {
			Published := false
		}
	}
	if Published
		return true

	; Guard rejection means the surface changed during privacy/context work.
	; Remove only this record; a newer callback may already own the global.
	_PrefixClearSuggestionIfOwned(Record, SurfaceToken)
	return false
}

; Decide which ``h_type`` value to log for a fired hotstring. The richest
; source is the matching active suggestion: its TOML Category names the
; group ("autocorrection", "personal", "magickey"…) and is far more
; informative than HS's generic "unknown". When the fire happens without
; a preceding suggestion (single-char-after-magic-key triggers that fire
; below the prefix watcher's MIN_PREFIX_LEN, or fires that race the
; tooltip render), fall back to a basic star/endchar tag derived from
; ``Spec.Star`` so the field is never empty.
_ResolveFireHType(Spec) {
	global _KLLastShownSuggestion
	Prev := _KLLastShownSuggestion
	if (IsObject(Prev) and Prev.Trigger == Spec.Trigger) {
		return Prev.Category
	}
	return (Spec.HasOwnProp("Star") and Spec.Star) ? "star" : "endchar"
}

; Toggle the render/depth guard around an output transaction.  Synthetic
; provenance is enforced by the InputHook's I1 input level, so this guard must
; never suppress a physical character merely because it arrives near a send.
; The buffer reset is now done synchronously by HSE_DispatchMatch's finally
; block (via _ResetPrefixBuffer) before this deferred release fires, so we
; must NOT wipe _PrefixBuffer here — doing so would erase the first
; keystrokes of the next word if the user types quickly after the expansion.
PrefixWatcherSuppress(YesNo) {
	global _PrefixWatcherSuppressed
	if YesNo
		_PrefixWatcherSuppressed += 1
	else
		_PrefixWatcherSuppressed := Max(0, _PrefixWatcherSuppressed - 1)
	; Deliberately does NOT call HSE_Suppress. The render guard and the engine's
	; own suppression are separate on purpose: the engine window exists to filter
	; its OWN SendInput output, and physical input declares itself with
	; IsPhysical=true instead (F46). Delegating here would drop a physical
	; character typed inside a nearby output transaction — pinned by
	; tests/meta/test_hse_physical_input_provenance.ahk, which asserts this call
	; is absent. Any comment elsewhere claiming this function holds both counters
	; is stale; HSE_Suppressed is not part of this contract.
}

; Enqueue a fired-hotstring metrics record and (once) arm the drain timer. O(1)
; and allocation-light so the fire keystroke returns immediately — the heavy
; KL_LogHotstring work (buffer flush, JSONL append, WPM pushes) runs later, off
; the keystroke path, via _HSE_DrainFireLog. Called from _OnPrefixChar on every
; fire in place of a synchronous KL_LogHotstring.
;
; ``IsPrivate`` travels ON the record rather than being applied here: the drain
; is what reaches the sink, and the sink owns the redaction because it is the
; sink that writes the replacement TWICE (once as a field, once inside the
; ``tag`` marker). Redacting at the enqueue would also destroy the exact strings
; the sink measures net_saved_chars and the WPM pushes from.
_HSE_QueueFireLog(Trigger, Replacement, HType, Category, Section, IsPrivate := false) {
	global _HSE_FireLogQueue
	; InputHook callbacks and timers survive native Suspend. A fire reaching this
	; funnel after the lifecycle boundary is not owned by the active generation
	; and must not create deferred work for a paused driver.
	if A_IsSuspended
		return false
	; Dynamic hotstrings (@dt, @date, the phone/SSN/IBAN prefixes…) store a
	; CALLABLE in Spec.Replacement and resolve it at fire time. HSE_DispatchMatch
	; resolves it into a local and never writes it back, so the fire paths read
	; the raw property and would hand the Func object straight to the drain —
	; where KL_LogHotstring opens with StrLen(replacement) and throws. That throw
	; lands inside the drain's try, so every date / phone / SSN / IBAN expansion
	; simply vanished from the JSONL and the WPM widget with nothing logged.
	; Neutralise here, at the one funnel every fire path shares, rather than at
	; each call site: the metric records the trigger, never the resolved PII.
	if HasMethod(Replacement)
		Replacement := ""
	_HSE_FireLogQueue.Push({ Trigger: Trigger, Replacement: Replacement,
		HType: HType, Category: Category, Section: Section,
		IsPrivate: IsPrivate ? true : false })
	_HSE_ArmFireLogDrain()
	return true
}

; Whether a deferred callback still owns the current lifecycle and may publish.
; PausedOverride is a deterministic test seam; production callers omit it and
; always read native A_IsSuspended at every mutation boundary.
_PrefixDeferredCanPublish(Generation, PausedOverride := unset) {
	global _PrefixDeferredGeneration
	if (Generation != _PrefixDeferredGeneration)
		return false
	if IsSet(PausedOverride)
		return !PausedOverride
	return !A_IsSuspended
}

; Arm exactly one fire-log owner for the current generation. ArmTimer=false is
; used only by the headless behavior test, which invokes the callback directly.
_HSE_ArmFireLogDrain(ArmTimer := true) {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration
	global HSE_FIRE_LOG_DEFER_MS
	if (_HSE_FireLogQueue.Length == 0 or _HSE_FireLogScheduled or A_IsSuspended)
		return false
	PreviousCritical := Critical("On")
	try {
		if (_HSE_FireLogQueue.Length == 0 or _HSE_FireLogScheduled or A_IsSuspended)
			return false
		_HSE_FireLogScheduled := true
		_HSE_FireLogScheduledGeneration := _PrefixDeferredGeneration
		if ArmTimer {
			; Negative period = run once after the delay. The delay exceeds the
			; suppress release so this drain is always scheduled to fire AFTER it.
			; Bind freezes the owner: a pre-suspend message already in the queue
			; cannot impersonate a new resume timer by reading mutable globals.
			try _HSE_FireLogTimer := TimerAfter(HSE_FIRE_LOG_DEFER_MS / 1000,
				_HSE_DrainFireLog.Bind(_PrefixDeferredGeneration))
			catch {
				; TimerAfter already emitted the OS failure. Relinquish ownership so
				; the next fire/resume can retry; the durable records stay queued.
				_HSE_FireLogScheduled := false
				_HSE_FireLogScheduledGeneration := -1
				_HSE_FireLogTimer := 0
				return false
			}
		} else {
			_HSE_FireLogTimer := 0
		}
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

; Retire all callbacks carrying captured state. The fired records themselves
; stay queued across suspend; resume transfers them to one fresh generation.
_PrefixInvalidateDeferredEffects() {
	global _PrefixDeferredGeneration, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixRenderScheduledGeneration, _PrefixRenderTimer
	PreviousCritical := Critical("On")
	try {
		_PrefixDeferredGeneration += 1
		_HSE_FireLogScheduled := false
		_HSE_FireLogScheduledGeneration := -1
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogTimer := 0
		TimerCancel(_PrefixRenderTimer)
		_PrefixRenderTimer := 0
		_PrefixRenderScheduledGeneration := -1
	} finally {
		Critical(PreviousCritical)
	}
	return _PrefixDeferredGeneration
}

; Lifecycle hooks called by infra/lifecycle.ahk. Suspend retains the fire batch;
; resume re-arms it exactly once; shutdown drains it before KL_Stop closes the
; durable keylogger sinks and then invalidates every remaining timer owner.
HotstringPrefixWatcherOnSuspend() {
	_PrefixInvalidateDeferredEffects()
	HotstringPrefixWatcherClearVisibleDecisions()
}

HotstringPrefixWatcherOnResume(ArmTimer := true) {
	return _HSE_ArmFireLogDrain(ArmTimer)
}

; Drains the terminal fire batch without stopping the InputHook, invalidating
; render callbacks, or clearing visible decisions. OnExit is non-interruptible,
; so a successful drain is a reversible refusal gate; permanent teardown runs
; only after every terminal commit has accepted.
HotstringPrefixWatcherPrepareShutdown() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration
	if (_HSE_FireLogQueue.Length == 0)
		return true
	OwnerGeneration := _PrefixDeferredGeneration
	PreviousCritical := Critical("On")
	try {
		_HSE_FireLogScheduled := true
		_HSE_FireLogScheduledGeneration := OwnerGeneration
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogTimer := 0
	} finally {
		Critical(PreviousCritical)
	}
	Drained := _HSE_DrainFireLog(OwnerGeneration, false)
	if !Drained and !A_IsSuspended
		_HSE_ArmFireLogDrain()
	return Drained
}

HotstringPrefixWatcherOnShutdown() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _PrefixDeferredGeneration
	_PrefixInvalidateDeferredEffects()
	HotstringPrefixWatcherClearVisibleDecisions()
	if (_HSE_FireLogQueue.Length == 0)
		return true
	_HSE_FireLogScheduled := true
	_HSE_FireLogScheduledGeneration := _PrefixDeferredGeneration
	; The process is already terminating, so there is no future idle tick. The
	; keylogger shutdown lease permits durable pre-pause rows, while its realtime
	; ROI/WPM sinks remain pause-gated.
	return _HSE_DrainFireLog(_PrefixDeferredGeneration, false)
}

; Put an unprocessed suffix back ahead of records queued by a newer callback.
; The reference swap is atomic and preserves chronological order.
_HSE_RestoreFireLogSuffix(Batch, StartIndex) {
	global _HSE_FireLogQueue
	PreviousCritical := Critical("On")
	try {
		Restored := []
		Loop Batch.Length - StartIndex + 1
			Restored.Push(Batch[StartIndex + A_Index - 1])
		for _, Rec in _HSE_FireLogQueue
			Restored.Push(Rec)
		_HSE_FireLogQueue := Restored
	} finally {
		Critical(PreviousCritical)
	}
}

; Drain every queued fired-hotstring record through KL_LogHotstring. Ownership
; and pause are checked BEFORE the queue swap and again before every sink call.
; A stale/paused callback leaves the batch untouched for one resumed owner.
_HSE_DrainFireLog(Generation := unset, PausedOverride := unset) {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration
	OwnerGeneration := IsSet(Generation)
		? Generation
		: _HSE_FireLogScheduledGeneration
	CanPublish := IsSet(PausedOverride)
		? _PrefixDeferredCanPublish(OwnerGeneration, PausedOverride)
		: _PrefixDeferredCanPublish(OwnerGeneration)
	if (!_HSE_FireLogScheduled or !CanPublish) {
		; A paused attempt relinquishes its timer lease but never its records.
		if (OwnerGeneration == _HSE_FireLogScheduledGeneration) {
			PreviousCritical := Critical("On")
			try {
				if (OwnerGeneration == _HSE_FireLogScheduledGeneration) {
					_HSE_FireLogScheduled := false
					_HSE_FireLogScheduledGeneration := -1
					TimerCancel(_HSE_FireLogTimer)
					_HSE_FireLogTimer := 0
				}
			} finally {
				Critical(PreviousCritical)
			}
		}
		return false
	}
	PreviousCritical := Critical("On")
	try {
		CanPublish := IsSet(PausedOverride)
			? _PrefixDeferredCanPublish(OwnerGeneration, PausedOverride)
			: _PrefixDeferredCanPublish(OwnerGeneration)
		if (!_HSE_FireLogScheduled or !CanPublish)
			return false
		_HSE_FireLogScheduled := false
		_HSE_FireLogScheduledGeneration := -1
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogTimer := 0
		Batch := _HSE_FireLogQueue
		_HSE_FireLogQueue := []
	} finally {
		Critical(PreviousCritical)
	}
	PublishGuard := IsSet(PausedOverride)
		? _PrefixDeferredCanPublish.Bind(OwnerGeneration, PausedOverride)
		: _PrefixDeferredCanPublish.Bind(OwnerGeneration)
	for Index, Rec in Batch {
		CanPublish := PublishGuard.Call()
		if !CanPublish {
			_HSE_RestoreFireLogSuffix(Batch, Index)
			return false
		}
		; A bare try here swallowed a TypeError for weeks with no trace at all.
		; The drain is the last stop before the metrics pipeline, so a failure
		; must at least name itself instead of silently dropping the record.
		try {
			Consumed := KL_LogHotstring(Rec.Trigger, Rec.Replacement, Rec.HType,
				"", Rec.Category, Rec.Section, Rec.IsPrivate, PublishGuard)
			; A false return caused by lifecycle loss means none of this fire is
			; owned any more. Put it and the untouched suffix back for resume.
			if (Consumed is Integer and !Consumed) {
				_HSE_RestoreFireLogSuffix(Batch, Index)
				; A non-lifecycle refusal means an older typing snapshot still owns
				; publication. Re-arm the retained suffix; suspend itself leaves the
				; queue dormant until the explicit resume transfer.
				if !IsSet(PausedOverride)
					_HSE_ArmFireLogDrain()
				return false
			}
		} catch as Err {
			; The failure line names the trigger so the dropped record is
			; identifiable — but a private trigger is itself a fragment of the
			; secret ("@iban★" says which secret followed), and this log rotates
			; alongside the one the redaction exists to protect.
			Named := Rec.IsPrivate ? PersonalInfoRedactForLog(Rec.Trigger) : Rec.Trigger
			try LoggerError("PrefixWatcher", "Fire-log drain failed for trigger '{1}': {2}.", Named, Err.Message)
			; The row has no durable owner yet. Retain it and the untouched suffix;
			; shutdown consumes the false result and refuses process teardown rather
			; than turning a sink exception into silent telemetry loss.
			_HSE_RestoreFireLogSuffix(Batch, Index)
			if !IsSet(PausedOverride)
				_HSE_ArmFireLogDrain()
			return false
		}
	}
	; A fire can arrive while the detached batch drains. Its enqueue normally
	; arms the next owner; this fallback closes the re-entrancy edge if lifecycle
	; invalidation landed between that push and its arm.
	_HSE_ArmFireLogDrain()
	return true
}

; Rebuild the auxiliary file catalogue from CURRENT Features without restarting
; the InputHook. _TriggerSet feeds deferred near-miss analytics; _PrefixIndex is
; retained for catalogue diagnostics and compatibility tests. Neither selects a
; tooltip row — HSE_PreviewNextDecision owns that live answer. No-op when the
; watcher is not running (both catalogues are intentionally empty then).
HotstringPrefixWatcherRebuildIndex() {
	global _PrefixInputHook, _PrefixIndex, _TriggerSet, _PREFIX_WATCHER_CATEGORIES
	global _HS_CACHE_ROWS
	if !_PrefixInputHook {
		return
	}
	; Pause invariant: SetTimer callbacks bypass native Suspend, and the sibling
	; InputHook callbacks (_OnPrefixChar / _OnPrefixKeyDown) all early-return on
	; A_IsSuspended. Mirror that here so a rebuild armed before Pause does not
	; quietly churn the index while the user expects the watcher to be silent.
	; Record the deferred request so Ergopti_OnSuspendResume can replay it — a live
	; section toggle made during pause must not leave near-miss analytics stale after
	; resume (deferred-replay pattern, like LLM_Menu_OnResume).
	if A_IsSuspended {
		global _PrefixIndexRebuildPending := true
		return
	}
	; Build-then-swap so a deferred near-miss scan never observes an empty or
	; partially-populated catalogue mid-rebuild. The reader sees either the old
	; complete maps or the new complete maps.
	NewIndex := Map()
	NewSet := Map()
	_rebuildStart := A_TickCount
	; Make sure the precompiled cache is loaded BEFORE we decide per category which
	; path to take. HotstringsCacheEnsure is idempotent (a no-op after the first
	; call, which normally happens during boot HSE registration), but the boot-tail
	; warm-up rebuild is armed by its own SetTimer and could, on an unlucky ordering,
	; fire before any LoadHotstringsSection has loaded the cache — in which case
	; _PrefixWatcherCategoryIsCached would wrongly fall back to the cold-disk TOML
	; scan (the 6422 ms boot-tail rebuild seen in the logs). Ensuring it here makes
	; the in-memory path the guaranteed choice for every bundled category.
	_ensureStart := A_TickCount
	if IsSet(HotstringsCacheEnsure)
		try HotstringsCacheEnsure()
	_ensureMs := TickElapsed(_ensureStart)
	; Build each category from the in-memory precompiled cache when available
	; (_HS_CACHE_ROWS, populated once at boot for the HSE fast path) instead of
	; re-reading + regex-parsing its TOML from disk. The disk rescan was the cost
	; of the multi-second deferred rebuild: the SAME 3180-trigger index measured
	; 157 ms once the OS file cache was warm but 3031 ms on the cold read right
	; after a reload (magickey.toml alone is ~2119 entries), and that 3 s monopolised
	; the thread so the tray menu could not open. Personal (never cached — its TOML
	; is user-relocatable) and any cache-miss still take the TOML path; both feed the
	; identical _AddTriggerVariants pipeline so the index is byte-identical to the
	; old behaviour (pinned by test_prefix_index_cache_equiv).
	_cachedCats := 0
	_tomlCats := 0
	_buildStart := A_TickCount
	for _, Category in _PREFIX_WATCHER_CATEGORIES {
		if _PrefixWatcherCategoryIsCached(Category) {
			_RegisterCategoryTriggersFromCache(Category, NewIndex, NewSet)
			_cachedCats += 1
		} else {
			_RegisterCategoryTriggers(Category, NewIndex, NewSet)
			_tomlCats += 1
		}
	}
	; Extension packs. The six categories above enumerate FILES the driver ships;
	; the engine additionally registers every other *.toml under
	; PersonalHotstringsDir. Indexing only the six meant a pack expanded correctly
	; and could never be previewed — and the config window still offered it a
	; per-pack tooltip colour, a setting with nothing behind it.
	_extPacks := 0
	for _, Pack in HS_EnumeratePersonalExtFiles() {
		_RegisterExtPackTriggers(Pack["Path"], Pack["Label"], NewIndex, NewSet)
		_extPacks += 1
	}
	_buildMs := TickElapsed(_buildStart)
	_PrefixIndex := NewIndex
	_TriggerSet := NewSet
	; Bundled categories now rebuild from memory (no FileRead, no regex); only
	; personal still parses TOML. Permanent instrumentation: the trigger count +
	; wall time catch a regression that reintroduces the cold-disk cost, while the
	; ensure/build split + cache/toml tally localise any residual wall-clock
	; (cache-load vs the in-memory build loop) and confirm the fast path stays live
	; (cache=0 toml=6 would mean the cache path silently broke).
	try LoggerInfo("PrefixWatcher",
		"Index rebuilt: {1} trigger(s) in {2} ms (ensure={3}ms build={4}ms cache={5} toml={6} ext={7} rows={8}).",
		NewSet.Count, TickElapsed(_rebuildStart), _ensureMs, _buildMs, _cachedCats, _tomlCats, _extPacks,
		(IsSet(_HS_CACHE_ROWS) ? _HS_CACHE_ROWS.Count : "unset"))
	; A just-disabled section may still have a tooltip on screen — hide it so the
	; preview cannot outlive the expansion it was advertising.
	TooltipHide("LiveToggleRebuild", true)
}

; Stop the InputHook and clear the index. Useful when the user disables the
; preview from the tray menu or before reloading.
HotstringPrefixWatcherStop() {
	global _PrefixInputHook, _PrefixIndex
	; Stop is a terminal lifecycle boundary (the sole production caller is the
	; global shutdown handler). Retire every timer owner before clearing state so
	; no captured callback can publish after teardown.
	_PrefixInvalidateDeferredEffects()
	if _PrefixInputHook {
		try _PrefixInputHook.Stop()
		_PrefixInputHook := 0
	}
	_PrefixIndex := Map()
	_PrefixSetBuffer("")
	TooltipHide("WatcherStop")
	; Close out any tooltip that was on screen — the user disabling the
	; watcher mid-suggestion is functionally a dismissal, not a fire.
	_NotifySuggestionDismissed()
}




; ============================================================
; ============================================================
; ======= 2/ InputHook & buffer logic =======================
; ============================================================
; ============================================================

; Configure and start the pass-through InputHook. Visible mode (``V``) means
; every keystroke also reaches its normal destination — the watcher only
; observes. ``L0 I0`` disables length-based termination; the hook stays alive
; until HotstringPrefixWatcherStop is called.
_StartInputHook() {
	global _PrefixInputHook
	; I1 filters only low-level synthetic input (the driver's SendInput/Event
	; bursts use the default SendLevel 0) while preserving every physical key.
	; This is event provenance, unlike the former 60-ms time window that also
	; discarded real typing after a hotstring expansion.
	Hook := InputHook("V L0 I1")
	Hook.KeyOpt("{All}", "+N")            ; notify OnKeyDown for every key
	Hook.OnChar    := _OnPrefixCharProfiled
	Hook.OnKeyDown := _OnPrefixKeyDown
	Hook.Start()
	_PrefixInputHook := Hook
}

; Profiling shim around _OnPrefixChar: times the entire per-keystroke match +
; render path with sub-millisecond precision and logs only keystrokes slower than
; the threshold (see infra/hotpath_profiler.ahk). The InputHook binds here rather
; than directly to _OnPrefixChar so the timing wraps every one of the hot
; function's return paths without touching the function itself. Char is passed
; raw so the log string is built only when a keystroke is actually slow.
_OnPrefixCharProfiled(IH, Char) {
	_HotStart := HotPath_Now()
	_OnPrefixChar(IH, Char)
	HotPath_LogIfSlow("OnChar", _HotStart, Char)
}

; Snapshot the exact tooltip owner alongside a RAM mutation. Generations alone
; are not sufficient: an active surface can be replaced without the buffer text
; changing, and the request serial closes the pending-request half of that ABA.
_PrefixCaptureTooltipOwner() {
	global _TooltipGeneration, _TooltipActiveSurface, _TooltipRequestSerial
	return {
		Generation: _TooltipGeneration,
		Surface: _TooltipActiveSurface,
		RequestSerial: _TooltipRequestSerial
	}
}

_PrefixTooltipOwnerStillCurrent(Owner) {
	global _TooltipGeneration, _TooltipActiveSurface, _TooltipRequestSerial
	if !(IsObject(Owner) and Owner.HasOwnProp("Generation")
		and Owner.HasOwnProp("Surface")
		and Owner.HasOwnProp("RequestSerial"))
		return false
	if (!(Owner.Generation is Integer)
		or !(Owner.RequestSerial is Integer)
		or Owner.Generation != _TooltipGeneration
		or Owner.RequestSerial != _TooltipRequestSerial)
		return false
	if IsObject(Owner.Surface) {
		return IsObject(_TooltipActiveSurface)
			and ObjPtr(Owner.Surface) == ObjPtr(_TooltipActiveSurface)
	}
	return !IsObject(_TooltipActiveSurface)
}

; Commit the in-memory half of an input-context invalidation. The caller owns
; serialization: production callers enter Critical before invoking this helper.
; Keeping the state transition separate from its tooltip/analytics effects lets
; a synthetic sender commit BOTH buffers and its OS keystroke in one short
; transaction without dragging GUI or file-backed logging under Critical.
; @param FocusToken {Integer} New focused-control identity, or 0 while unknown.
; @param KnownBoundary {Boolean} Whether the new run starts at a word boundary.
; @return {Object} Immutable state needed by the post-commit effects phase.
_PrefixCommitInputContext(FocusToken := 0, KnownBoundary := true) {
	global _PrefixBuffer, _PrefixFocusedControlToken, _PrefixInputContextGeneration
	ClearedBuffer := _PrefixBuffer
	HSE_FeedReset(KnownBoundary, true)
	ContentGeneration := _PrefixSetBuffer("")
	_PrefixFocusedControlToken := FocusToken
	_PrefixInputContextGeneration += 1
	return {
		ClearedBuffer: ClearedBuffer,
		Generation: _PrefixInputContextGeneration,
		ContentGeneration: ContentGeneration,
		TooltipOwner: _PrefixCaptureTooltipOwner()
	}
}

; Run the side effects for a committed context transition. This stays separate
; from _PrefixCommitInputContext so a synthetic sender can emit its OS key first,
; then enters one short Critical transaction to validate and retire the exact
; tooltip owner. TooltipHide detaches pixels synchronously and defers disposal.
_PrefixFinishInputContext(Commit) {
	PreviousCritical := Critical("On")
	try {
		if !_PrefixInputCommitStillCurrent(Commit)
			return false
		_ResetPrefixBuffer(false, Commit.ClearedBuffer)
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

; A RAM commit and its presentation work are separated specifically to keep GUI
; and analytics outside Critical. That creates an async boundary: a newer input
; can publish another context before the old finalizer runs. Both generations
; are required because text can return to the same value (ABA) while focus or
; boundary knowledge changes independently. The tooltip owner additionally
; rejects a new surface/request published without another text mutation.
_PrefixInputCommitStillCurrent(Commit) {
	global _PrefixInputContextGeneration, _PrefixContentGeneration
	if !IsObject(Commit)
		return false
	if !Commit.HasOwnProp("Generation") or !(Commit.Generation is Integer)
			or !Commit.HasOwnProp("ContentGeneration")
			or !(Commit.ContentGeneration is Integer)
		return false
	if (Commit.Generation != _PrefixInputContextGeneration
		or Commit.ContentGeneration != _PrefixContentGeneration)
		return false
	return Commit.HasOwnProp("TooltipOwner")
		and _PrefixTooltipOwnerStillCurrent(Commit.TooltipOwner)
}

; Clear the engine and preview as one input-context transaction. The RAM commit
; stays separate from its finalizer so a synthetic sender can emit atomically;
; the finalizer then uses its own short Critical owner-check + pure pixel detach.
; Logging and retired-Gui disposal remain deferred off the keyboard transaction.
; @param FocusToken {Integer} New focused-control identity, or 0 while unknown.
; @param KnownBoundary {Boolean} Whether the new run starts at a word boundary.
; @return {Integer} Published input-context generation.
_PrefixInvalidateInputContext(FocusToken := 0, KnownBoundary := true) {
	PreviousCritical := Critical("On")
	try {
		Commit := _PrefixCommitInputContext(FocusToken, KnownBoundary)
	} finally {
		Critical(PreviousCritical)
	}
	_PrefixFinishInputContext(Commit)
	return Commit.Generation
}

; Verify that the next character still targets the control which owns the two
; buffers. An explicit token is a deterministic test seam; production callers
; omit it and use the WindowInfo adapter. Failure to resolve focus is fail-closed:
; discard any armed expansion and ignore this character rather than backspacing
; against an unverifiable target.
; @param FocusToken {Integer} Optional focused-control token override.
; @return {Boolean} True when the character may safely enter the buffers.
_PrefixEnsureInputContext(FocusToken := unset) {
	global _PrefixBuffer, _PrefixFocusedControlToken, HSE_Buffer, HSE_StartIsWordBoundary
	if !IsSet(FocusToken)
		FocusToken := WIGetFocusedControlToken()
	if !FocusToken {
		if (_PrefixFocusedControlToken or _PrefixBuffer != "" or HSE_Buffer != "")
			_PrefixInvalidateInputContext(0, false)
		return false
	}
	if (_PrefixFocusedControlToken != FocusToken) {
		; An unresolved probe deliberately marks the left context unknown. Preserve
		; that verdict when focus becomes observable again; otherwise ignored text
		; could be mistaken for a word boundary and a suffix could backspace it.
		KnownBoundary := (_PrefixFocusedControlToken == 0) ? HSE_StartIsWordBoundary : true
		_PrefixInvalidateInputContext(FocusToken, KnownBoundary)
	}
	return true
}

; Handle the two genuine Ctrl chords proven to relocate focus without OnChar.
; AltGr synthesizes Ctrl on Windows, so RAlt/SC138 ownership is resolved by the
; caller and explicitly excludes that path.
; @return {Boolean} True when the chord consumed the context-reset decision.
_PrefixHandleCtrlContextChord(VK, CtrlHeld, AltGrHeld) {
	static RelocatingVKs := Map(
		0x46, true,  ; F — Find box
		0x4C, true   ; L — browser address/location control
	)
	if (!CtrlHeld or AltGrHeld or !RelocatingVKs.Has(VK))
		return false
	; Focus usually moves only after this keydown callback returns. Publish an
	; unknown token now; the next OnChar binds the new control generation.
	_PrefixInvalidateInputContext(0, true)
	return true
}

; Replace the physical wrapping symbol with a selection wrapper as one
; status-bearing transaction. SendInstant prepares the clipboard before its Prefix
; is injected, so a failed preparation leaves the already-visible symbol intact.
; Both buffers are invalidated only after the wrapped text was actually emitted.
_PrefixTryWrapSelection(Selection, Pair) {
	global _PrefixFocusedControlToken
	Left := Pair["left"]
	Right := Pair["right"]
	Wrapped := false
	PrefixWatcherSuppress(true)
	try {
		; The pass-through InputHook already delivered Char. Keeping its erase in
		; SendInstant's Prefix prevents a clipboard failure from deleting the only
		; output that still truthfully represents the user's keystroke.
		Wrapped := SendInstant(Left . Selection . Right, "{BackSpace}")
		; A physical InputHook callback can interrupt TooltipHide. Resetting the
		; preview first and the engine second therefore exposed a window where the
		; next key entered only one buffer. Publish the new input context through
		; the shared atomic pair, while retaining ownership of the focused control.
		if Wrapped
			_PrefixInvalidateInputContext(_PrefixFocusedControlToken, true)
	} finally {
		PrefixWatcherSuppress(false)
	}
	return Wrapped
}

; Decide the watcher state from the engine's already-committed screen effect.
; The completion key is not itself proof of a boundary: a consumed delimiter is
; absent from the screen, so its replacement can immediately prefix a cascade.
_PrefixPostFireDecision(Effect, EngineBuffer, MaxBufferLen) {
	if !(IsObject(Effect) and Effect.HasOwnProp("ClearAll")
		and Effect.HasOwnProp("KnownBoundaryAfter"))
		return { Reset: true, Buffer: "", Schedule: false }
	if Effect.ClearAll or Effect.KnownBoundaryAfter
		return { Reset: true, Buffer: "", Schedule: false }
	NextBuffer := EngineBuffer
	if StrLen(NextBuffer) > MaxBufferLen
		NextBuffer := SubStr(NextBuffer, -MaxBufferLen)
	return {
		Reset: NextBuffer == "",
		Buffer: NextBuffer,
		Schedule: NextBuffer != ""
	}
}

_PrefixCommitPostFireEffect(Effect) {
	global HSE_Buffer, _MAX_BUFFER_LEN
	Decision := _PrefixPostFireDecision(Effect, HSE_Buffer, _MAX_BUFFER_LEN)
	if Decision.Reset {
		_ResetPrefixBuffer(true)
		return false
	}
	; Retire the pre-fire pixels and decision owner before publishing the cascade
	; buffer. Leaving them visible through the render/UIA debounce window made the
	; old answer claimable after its trigger had already fired.
	_PrefixRetireConsumedSuggestion("PostFire")
	_PrefixSetBuffer(Decision.Buffer)
	if Decision.Schedule
		_PrefixScheduleRender()
	return Decision.Schedule
}

; OnChar — called for every printable character produced by the active
; keyboard layout. We keep this fast: append, trim, lookup, render. Anything
; heavy belongs out of the hot path.
; Wrapped in try so that any exception from _LookupAndRender / TooltipShow
; does not silently kill the InputHook callback chain — AHK v2 stops invoking
; the OnChar callback permanently if an unhandled error propagates out of it.
_OnPrefixChar(IH, Char) {
	global _PrefixBuffer, _MAX_BUFFER_LEN, _PrefixWatcherSuppressed, HSE_Suppressed, HSE_Buffer
	global _PrefixPrivateResidue
	; No hotstring preview tooltip and no expansion dispatch while the script is
	; paused or the Hotstrings master gate is off — this watcher uses its OWN
	; InputHook, so the HookDispatcher guard does not cover it.
	if A_IsSuspended
		return
	; I1 excludes this driver's synthetic output before OnChar.  Keep the HSE
	; fallback guard for standalone/manual HSE suppression, but do not treat the
	; prefix render guard as evidence that this physical character is synthetic.
	; LLM predictions stay on even when the Hotstrings master gate is off.
	if (IsSet(LLM_Bridge_FeedCharIfActive))
		LLM_Bridge_FeedCharIfActive(Char)
	if !IsCategoryGated("Hotstrings")
		return
	; The pass-through character is already on screen. Before it can participate
	; in a match, prove that the screen target still owns the buffered prefix. This
	; guard sits before the main dispatch try, so contain it independently: an
	; unhandled InputHook callback error permanently silences later characters.
	try {
		if !_PrefixEnsureInputContext()
			return
	} catch as ContextErr {
		try LoggerError("PrefixWatcher", "Input-context verification failed: {1}.", ContextErr.Message)
		return
	}
	; UIA selection-wrap: when the user types a symbol while text is selected,
	; wrap the selection instead of inserting the bare symbol.
	; Active pairs come from WrapSymbols_GetActivePairs() so the user's enabled/
	; disabled choices and custom symbols are respected without a Reload.
	; IsSet(_WS_ACTIVE_PAIRS) guards against loading order issues — the global
	; is defined in wrap_symbols_config.ahk which is #Include'd before this file.
	if (IsSet(Features) and Features.Has("shortcuts")
		and Features["shortcuts"].Has("wrap_text_if_selected")
		and Features["shortcuts"]["wrap_text_if_selected"]
		and IsSet(_WS_ACTIVE_PAIRS)
	) {
		; Snapshot the active-pairs map once so the pair lookup is consistent
		; with the membership check even if WrapSymbols_Rebuild() runs concurrently.
		_ActivePairsSnap := WrapSymbols_GetActivePairs()
		; A physical character after a selection has collapsed it, even when the
		; UIA poll has not run again yet.  Preserve the snapshot only for the
		; wrapping symbol itself; any other printable input invalidates it.
		if (IsSet(_UIA_SelectionCache) and IsObject(_UIA_SelectionCache) and !_ActivePairsSnap.Has(Char))
			_UIA_SelectionCache := 0
		if _ActivePairsSnap.Has(Char) {
			try {
				UIASel := GetUIASelection()
				if (UIASel != "") {
					Pair := _ActivePairsSnap[Char]
					if _PrefixTryWrapSelection(UIASel, Pair)
						return
				}
			} catch as _UIAErr {
				LoggerError("PrefixWatcher", "UIA wrap error for char '{1}': {2}.", Char, _UIAErr.Message)
			}
		}
	}
	try {
		; Serialize the whole match -> fire -> buffer-sync region: Critical makes
		; this keystroke uninterruptible, so AHK cannot start the NEXT physical
		; key's layout-remap SendEvent thread (nor a render/suppress timer) until
		; this keystroke — including the synchronous HSE_DispatchMatch expansion
		; burst below — has fully completed. That guarantees the expansion is
		; emitted IN FULL before any following keystroke (no interleave / lost key
		; / "outpubct"). Set AFTER the UIA-wrap branch above (which Sleeps via
		; SendInstant) so Critical never spans a Sleep. The Notepad clipboard path
		; does NOT release Critical — it takes its own on top (hotstring_dispatch)
		; and holds it across the whole clipboard transaction, which is why that
		; transaction is now gated on a contention probe rather than allowed to
		; retry for #ClipboardTimeout with the keyboard hook starved behind it.
		Critical("On")
		; Char is printed raw and the two buffers are not. Nothing here knows yet
		; whether this keystroke completes a private trigger — HSE_FeedChar has not
		; run, so there is no match and no flag to read — and pretending otherwise
		; would be a guard that only looks like one. What IS known is the other
		; direction: a private expansion that already fired put its resolved value
		; into both buffers, and that is what _PrefixLogSafe withholds.
		if LoggerIsDebugEnabled()
			LoggerDebug("PrefixWatcher", "DBG OnChar: char='{1}' prefixBuf='{2}' hseBuf='{3}' suppressed={4}/{5}.", Char, _PrefixLogSafe(_PrefixBuffer), _PrefixLogSafe(HSE_Buffer), _PrefixWatcherSuppressed, HSE_Suppressed)
		; Feed HSE — when HSE_FeedChar reports a match, fire the
		; expansion right here. HSE_LastEndChar is the authoritative end
		; character: empty for star (immediate) triggers, the just-typed
		; terminator for end-char-gated triggers. We can no longer derive
		; it from « is Char a terminator? » alone because the new HSE
		; keeps terminators in its buffer, which means a terminator may
		; trigger a STAR match (e.g. a personal ``,a → ja`` rule fires
		; on the « a », not on the comma).
		_HseFeedTick := HotPath_Now()
                HSEMatch := HSE_FeedChar(Char, true)
		HotPath_LogIfSlow("HSE.FeedChar", _HseFeedTick, Char)
		; When no registered hotstring matched, try the engine-level repeat
		; fallback: <x><MagicKey> repeats <x> when x is at least the 2nd
		; letter of the current word. This replaces the now-removed [[repeat]]
		; TOML entries and fires at the lowest priority (only on no-match).
		if (HSEMatch == "" and IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
			; The @-combo resolver first: it is the more specific of the two
			; fallbacks (it requires a leading "@" and letters that all alias a
			; personal_info field), so letting the repeat fallback see @nn★ before
			; it would double the "n" instead of expanding two fields.
			HSEMatch := HSE_TryPersonalInfoCombo(ScriptInformation["MagicKey"])
		}
		if (HSEMatch == "" and IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
			HSEMatch := HSE_TryRepeatKey(ScriptInformation["MagicKey"])
		}
		if (HSEMatch != "") {
			; Kill the obsolete pre-expansion preview before the send burst so it
			; cannot fire reentrantly inside HSE_DispatchMatch's message pump.
			_PrefixCancelRender()
			_HseDispatchTick := HotPath_Now()
			; A match is not necessarily a FIRE: a raw callback may decline (the
			; E-circumflex deadkey and ellipsis guards refuse in the wrong context), and
			; the time-activation / mixed-case gates bail too. HSE_DispatchMatch reports
			; which happened so we do not log an expansion the user never saw.
			; A personal-info mapping carries the user's IBAN / card / SSN in its
			; replacement AND a fragment of it in its trigger. The flag rides the
			; Spec from registration so this path never has to recognise the value.
			; Read BEFORE the profiler line below, not after it: the profiler logs at
			; WARNING, which is ABOVE the default INFO level, so its detail reaches
			; the driver's rotating log with no user action at all — unlike the DEBUG
			; sites, which at least need the user to switch the level on.
			HotstringIsPrivate := HSEMatch.HasOwnProp("IsPrivate") && HSEMatch.IsPrivate
			_HseFired := HSE_DispatchMatch(
				HSEMatch, HSE_LastEndChar, &CommittedScreenEffect)
			; The trigger is the profiler's only context here, and a slow-dispatch
			; warning without it cannot be attributed to a mapping — so it is
			; redacted, not dropped. The redaction preserves length, which is the
			; part that actually correlates with dispatch cost.
			HotPath_LogIfSlow("HSE.Dispatch", _HseDispatchTick,
				HotstringIsPrivate ? PersonalInfoRedactForLog(HSEMatch.Trigger) : HSEMatch.Trigger)
			; Log the fired hotstring. ``h_type`` is taken from the
			; preceding suggestion when available (richest categorisation —
			; "autocorrection", "personal", …) and falls back to a basic
			; star/endchar tag so dispatch paths that bypass the tooltip
			; (single-char-after-magic-key triggers that fire below
			; _MIN_PREFIX_LEN) still carry meaningful metadata.
			HotstringHType := _ResolveFireHType(HSEMatch)
			HotstringRepl := HSEMatch.HasOwnProp("Replacement") ? HSEMatch.Replacement : HSEMatch.Trigger
			; IsRepeat matches have no Category property — pass "repeat_key" explicitly
			; so the WPM widget knows to stay at the default color.
			HotstringCategory := HSEMatch.HasOwnProp("IsRepeat") && HSEMatch.IsRepeat
				? "repeat_key"
				: (HSEMatch.HasOwnProp("Category") ? HSEMatch.Category : "")
			HotstringSection := HSEMatch.HasOwnProp("Section") ? HSEMatch.Section : ""
			; Metrics logging is analytics — enqueue it and return; the heavy
			; KL_LogHotstring work runs off the keystroke path (see
			; _HSE_QueueFireLog) so a disk/lookup spike can never stall the fire
			; keystroke and stretch the suppress window into a key-swallow.
			; Only a real expansion is a fire. A declined match must not reach the
			; metrics/WPM pipeline as one — it inflated the hotstring counters and the
			; per-section stats with expansions that never appeared on screen.
			if _HseFired
				_HSE_QueueFireLog(HSEMatch.Trigger, HotstringRepl, HotstringHType, HotstringCategory, HotstringSection, HotstringIsPrivate)
			; From here on the two keystroke buffers may hold the resolved value:
			; the engine already applied the expansion to HSE_Buffer, and the sync
			; below copies it into the watcher's. Raised for BOTH fire shapes — the
			; end-char branch wipes the preview buffer but leaves the engine's.
			if (_HseFired and HotstringIsPrivate)
				_PrefixPrivateResidue := true
			; The same rule the metrics pipeline above already follows, applied to
			; the buffer: a match that did not FIRE changed nothing on screen. The
			; trigger characters and the just-typed char are all still there, so
			; rewriting the watcher buffer as though the replacement had been
			; inserted made the tooltip describe text that does not exist — and
			; every later lookup anchored on that fiction. Take the same path an
			; outright no-match takes instead.
			if !_HseFired {
				_PrefixAppendTypedChar(Char)
				return
			}
			; ── Sync the watcher buffer to the post-expansion screen state ──
			; The naive "wipe to empty" used to drop the in-word context the
			; user is still typing inside of. After a STAR fire (no end-char),
			; the cursor sits IMMEDIATELY after the replacement and the user
			; usually keeps typing the same word — so the next keystroke
			; needs the post-expansion prefix as its lookup context. Without
			; this sync, typing ``l`` then the apostrophe trigger (``l'``)
			; would erase the watcher's memory of the ``l'`` boundary, and
			; subsequent ``ia`` would never surface the ``ia`` trigger
			; preview because the word-anchored lookup had no terminator to
			; anchor against.
			;
			; The engine effect owns whether the screen now ends at a boundary.
			; A consumed end character is absent from that screen, so it follows
			; the same cascade path as a star fire. Send-key payloads and emitted
			; terminators remain conservative resets.
			_PrefixCommitPostFireEffect(CommittedScreenEffect)
			return
		}

		; Word-terminator characters: the trigger index only contains
		; word-internal sequences, and a leading terminator would prevent any
		; match. OnKeyDown handles VK-only keys (arrows, Escape…); this guard
		; covers printable terminators (space, punctuation, …) that produce a
		; char event — including those arriving via tap-hold or AltGr layers
		; whose VK event may be swallowed before reaching the InputHook.
		;
		; The terminator was ALREADY fed to HSE by the single HSE_FeedChar at
		; the top of this function — that is where end-char hotstrings fire
		; (e.g. "ia"+space → "IA", handled above when HSEMatch != ""). Reaching
		; here means nothing matched, so we must NOT feed the terminator a
		; second time: re-feeding doubled it in HSE_Buffer (e.g. "nnbsp::e"),
		; which silently broke every trigger that CONTAINS a terminator as a
		; non-final char — the nnbsp/nbsp + ';'/':' + vowel "J" triggers. We
		; only reset the UI prefix buffer here; HSE_Buffer keeps the single
		; terminator so such triggers still match on the next keystroke.
		_PrefixAppendTypedChar(Char)
	} catch as Err {
		LoggerError("PrefixWatcher", "OnChar error for char '{1}': {2}.", Char, Err.Message)
	}
}

; OnKeyDown — handles word-breaking / navigation keys that should reset the
; buffer regardless of whether they produce a visible character. The VK list
; covers Space/Enter/Tab/Escape/Backspace and the four arrows. Mouse clicks
; are not handled here; the InputHook does not see them. We rely on the
; tooltip's auto-hide timer for that case.
_OnPrefixKeyDown(IH, VK, SC) {
	global _PrefixWatcherSuppressed, HSE_Suppressed, _PrefixFocusedControlToken
	; The prefix watcher is the newest InputHook and normally authorizes Tab
	; acceptance before HookDispatcher sees the same physical down. Record it
	; here; the shared key-state owner deduplicates the later dispatcher callback.
	KS_RecordPhysicalKeyDown(VK, SC, "prefix")
	; Inert while paused — pairs with the _OnPrefixChar guard so this watcher's
	; private InputHook is fully silent during suspend.
	if A_IsSuspended
		return
	; Synthetic key events are rejected by InputHook I1.  Only an explicit
	; engine-level suppression (used by standalone/manual callers) blocks a
	; physical keydown from updating the buffer.
	static ResetVKs := Map(
		; VK_BACK is deliberately ABSENT: backspace decrements both buffers
		; rather than wiping the preview — see the VK == 0x08 branch below.
		0x09, true,  ; VK_TAB
		0x0D, true,  ; VK_RETURN
		0x1B, true,  ; VK_ESCAPE
		0x20, true,  ; VK_SPACE
		0x25, true,  ; VK_LEFT
		0x26, true,  ; VK_UP
		0x27, true,  ; VK_RIGHT
		0x28, true,  ; VK_DOWN
		; The rest of the navigation cluster. The engine's own contract lists
		; these as buffer-invalidating, but only the arrows were ever enumerated
		; here — so typing "bonjour ia", pressing Home and typing "." fired
		; ia -> IA with {BackSpace 3} at line start and ate three characters of
		; unrelated text. Delete and Insert belong with them: both rewrite the
		; document by an amount this watcher cannot observe.
		0x21, true,  ; VK_PRIOR  (PgUp)
		0x22, true,  ; VK_NEXT   (PgDn)
		0x23, true,  ; VK_END
		0x24, true,  ; VK_HOME
		0x2D, true,  ; VK_INSERT
		0x2E, true,  ; VK_DELETE
	)
	; Same try guard as _OnPrefixChar — an unhandled error here permanently
	; silences the OnKeyDown callback for all subsequent keystrokes.
	try {
		; Detect Ctrl-modified combos that mutate the document context but
		; do not produce a printable char observable by OnChar. Held Ctrl
		; is read off the live keyboard state since the InputHook does
		; not surface modifier flags. Done before the plain-VK branches
		; so Ctrl+A/X/V/Z/Y do not also fall through to (e.g.) the « no
		; printable » case.
		CtrlHeld := KS_IsDown("Control")
		AltGrHeld := KS_IsDown("RAlt") or KS_IsDown("SC138")
		if _PrefixHandleCtrlContextChord(VK, CtrlHeld, AltGrHeld)
			return
		if (CtrlHeld and !AltGrHeld) {
			if (VK == 0x41) {
				; Ctrl+A — select-all. The next typed char replaces the
				; entire selection, landing at a fresh word-start.
				; IsPhysical=true so a real Ctrl+A landing inside the post-expansion
				; suppress window is honoured instead of being filtered as engine output.
				_PrefixInvalidateInputContext(_PrefixFocusedControlToken, true)
				return
			}
			if (VK == 0x58 or VK == 0x56 or VK == 0x5A or VK == 0x59 or VK == 0x08) {
				; Ctrl+X (cut) / Ctrl+V (paste) / Ctrl+Z (undo) /
				; Ctrl+Y (redo) / Ctrl+Backspace (delete-word) — document
				; content rewritten by an unknown amount (a whole word for
				; Ctrl+Backspace), cursor lands somewhere we cannot observe.
				; Wipe the buffer and refuse to assume a word boundary on its
				; left. Falling through to the plain VK==0x08 branch below would
				; chop only ONE char, leaving the buffer ahead of the screen and
				; later firing an expansion with backspaces into unrelated text.
				_PrefixInvalidateInputContext(_PrefixFocusedControlToken, false)
				return
			}
		}

		; Publish every context mutation to HSE_Buffer and _PrefixBuffer as one
		; transaction. A hook/timer callback may interrupt this keydown thread;
		; separate engine and preview writes exposed a window where the next
		; physical character entered only one side. Space is the deliberate
		; exception: HSE_FeedChar must keep its terminator and left context for
		; triggers that contain a boundary internally, while the preview starts a
		; fresh word.
		if (VK == 0x08) {
			; The preview must shrink by exactly one character too. It used to be
			; WIPED here (VK_BACK sat in ResetVKs) while the engine merely
			; decremented — preserving in-word context is the whole point of
			; HSE_FeedBackspace. So after a single backspace the engine would
			; still fire a hotstring the tooltip had stopped offering: the same
			; tooltip-versus-engine divergence as the boundary-set bug, skewed
			; the other way.
			_PrefixFeedBackspace()
			if (IsSet(LLM_Bridge_FeedKeyDownIfActive))
				LLM_Bridge_FeedKeyDownIfActive(VK, true)
		} else if (VK == 0x20) {
			_ResetPrefixBuffer()
		} else if ResetVKs.Has(VK) {
			; Insert/Delete rewrite text without promising a boundary. Tab/Enter
			; and Escape may move or destroy the focused control, so publish an
			; unknown focus token; cursor movers and Space retain the current owner.
			KnownBoundary := !(VK == 0x2D or VK == 0x2E)
			FocusToken := (VK == 0x09 or VK == 0x0D or VK == 0x1B)
				? 0
				: _PrefixFocusedControlToken
			_PrefixInvalidateInputContext(FocusToken, KnownBoundary)
			if IsSet(LLM_Bridge_FeedKeyDownIfActive)
				LLM_Bridge_FeedKeyDownIfActive(VK, true)
		}
	} catch as Err {
		LoggerError("PrefixWatcher", "OnKeyDown error for VK {1}: {2}.", VK, Err.Message)
	}
}

; The trailing word of the ENGINE buffer, using the same boundary set the
; preview uses. The two buffers deliberately hold different things: the engine
; keeps the terminator and everything before it (a trigger may contain a
; terminator as a non-final character), while the preview tracks only the word
; being typed. Deriving one from the other is how they are reconciled without
; the preview having to remember anything the engine already knows.
_PrefixWordTailFromEngine() {
	global HSE_Buffer
	return IsSet(HSE_Buffer) ? _PrefixWordTail(HSE_Buffer) : ""
}

; The trailing word of an arbitrary buffer, using the shared boundary set. One
; definition of "the word currently being typed", so every consumer agrees on
; where it starts.
_PrefixWordTail(Buf) {
	global _MAX_BUFFER_LEN
	if (Buf == "")
		return ""
	Boundaries := _PrefixWordBoundaries()
	Tail := ""
	Loop StrLen(Buf) {
		Ch := SubStr(Buf, -A_Index, 1)
		if InStr(Boundaries, Ch)
			break
		Tail := Ch . Tail
	}
	if (StrLen(Tail) > _MAX_BUFFER_LEN)
		Tail := SubStr(Tail, -_MAX_BUFFER_LEN)
	return Tail
}

; Commit one backspace to both in-memory buffers. The caller owns serialization;
; the physical wrapper and synthetic transaction both hold Critical here.
; @return {Object} The preview value plus immutable content/tooltip owners.
_PrefixCommitBackspace() {
	global _PrefixBuffer
	HSE_FeedBackspace(true)
	if (_PrefixBuffer == "") {
		; Empty does not always mean "nothing to step back over". Typing a
		; terminator resets the preview while the engine keeps it, so deleting
		; that terminator re-exposes the previous word. Recover the authoritative
		; engine tail after its decrement.
		NextPrefixBuffer := _PrefixWordTailFromEngine()
	} else {
		NextPrefixBuffer := SubStr(_PrefixBuffer, 1, StrLen(_PrefixBuffer) - 1)
	}
	ContentGeneration := _PrefixSetBuffer(NextPrefixBuffer)
	return {
		Buffer: NextPrefixBuffer,
		ContentGeneration: ContentGeneration,
		TooltipOwner: _PrefixCaptureTooltipOwner()
	}
}

_PrefixBackspaceCommitStillCurrent(Commit) {
	global _PrefixContentGeneration
	if !IsObject(Commit) or !Commit.HasOwnProp("Buffer")
			or !Commit.HasOwnProp("ContentGeneration")
			or !(Commit.ContentGeneration is Integer)
			or Commit.ContentGeneration != _PrefixContentGeneration
		return false
	return Commit.HasOwnProp("TooltipOwner")
		and _PrefixTooltipOwnerStillCurrent(Commit.TooltipOwner)
}

; Validate and retire the exact pre-backspace surface in one transaction. The
; RAM commit remains separate so synthetic senders can preserve their shorter
; engine+preview+OS-send Critical span without giving an old finalizer authority
; over pixels published after that span.
_PrefixFinishBackspace(Commit) {
	PreviousCritical := Critical("On")
	try {
		if !_PrefixBackspaceCommitStillCurrent(Commit)
			return false
		; The suggestion that was showing described the pre-backspace text, so it is
		; stale the moment the character disappears. Drop it before re-rendering so a
		; stale tooltip is never left standing if the new buffer matches nothing.
		TooltipHide("Backspace", true)
		_NotifySuggestionDismissed()
		if (Commit.Buffer != "")
			_PrefixScheduleRender()
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

; Shrink the engine and watcher buffers by one character as one input-context
; transaction. The tooltip is re-rendered from the shortened buffer rather than
; merely hidden: after deleting a typo the user is usually back on a live
; trigger prefix, and that suggestion should reappear.
;
; An empty buffer stays empty — there is nothing on screen to step back over,
; and the engine's own buffer is equally unable to go negative.
_PrefixFeedBackspace() {
	PreviousCritical := Critical("On")
	try {
		Commit := _PrefixCommitBackspace()
	} finally {
		Critical(PreviousCritical)
	}
	_PrefixFinishBackspace(Commit)
}

; Record a character that is now on screen into the watcher buffer. The ONE
; place that grows the preview buffer, shared by the plain no-match path and by
; a match that declined to fire — those two cases leave the screen in exactly
; the same state, so they must leave the buffer in the same state too. Handling
; them separately is how the declined case came to rewrite the buffer with a
; replacement that was never typed.
_PrefixAppendTypedChar(Char) {
	global _PrefixBuffer, _MAX_BUFFER_LEN
	; A boundary character ends the word: nothing typed before it can still be a
	; live trigger prefix. HSE_Buffer deliberately keeps the terminator (triggers
	; may contain one as a non-final char); the preview only tracks the current
	; word, so it starts fresh here.
	if InStr(_PrefixWordBoundaries(), Char) {
		_ResetPrefixBuffer(false)
		; The boundary itself may be the body of a boundary-leading star trigger
		; (for example " ★"). HSE_Buffer retains it, so ask the canonical oracle
		; after the normal reset instead of assuming no next action can start here.
		_PrefixScheduleRender()
		return
	}
	; A visible or already-requested row describes the text BEFORE Char. Hide and
	; invalidate it synchronously through TooltipHide's Win32-only fast teardown;
	; the replacement remains debounced, so GUI/UIA work never moves onto OnChar.
	_PrefixDismissStaleSuggestion("PrefixChanged")
	NextPrefixBuffer := _PrefixBuffer . Char
	if (StrLen(NextPrefixBuffer) > _MAX_BUFFER_LEN)
		NextPrefixBuffer := SubStr(NextPrefixBuffer, -_MAX_BUFFER_LEN)
	_PrefixSetBuffer(NextPrefixBuffer)
	if LoggerIsDebugEnabled()
		LoggerDebug("PrefixWatcher", "DBG render scheduled for buf='{1}'.", _PrefixLogSafe(_PrefixBuffer))
	_PrefixScheduleRender()
}

; ConsumedByFire ─ true when the reset is the consequence of a hotstring
; firing. The currently-suggested entry is then cleared silently so the
; logger does not emit a ``hotstring_dismissed`` event paired with the
; ``hotstring`` (fired) one — HS treats the fire as the resolution of the
; suggestion, never a parallel dismissal. Every other caller (word
; terminator, mouse click, navigation key, prefix lost) leaves the default
; in place so the tooltip's disappearance is properly logged.
_ResetPrefixBuffer(ConsumedByFire := false, AlreadyClearedBuffer := unset) {
	global _PrefixBuffer, _TriggerSet, _TooltipDequeueActive
	global _PrefixDeferredGeneration
	if IsSet(AlreadyClearedBuffer) {
		Buf := AlreadyClearedBuffer
	} else {
		Buf := _PrefixBuffer
		_PrefixSetBuffer("")
	}
	if ConsumedByFire {
		; Consume first: TooltipHide clears visible decisions and would otherwise
		; publish a dismissal for the suggestion resolved by this same fire.
		_PrefixRetireConsumedSuggestion("ResetBuf")
	} else {
		TooltipHide("ResetBuf", true)
		_NotifySuggestionDismissed()
		; Near-miss / manual-trigger detection is pure keylogger analytics with no
		; ordering requirement, so (a) skip it entirely when the keylogger is inactive
		; — the default case pays zero — and (b) defer the O(n) trigger-set scan off the
		; synchronous, Critical keystroke thread to the next idle tick, so a logging
		; session never pays it on the typing path (near-miss-on-hotpath-scan). Buf is a
		; value copy, so the deferred scan sees the buffer as it was at reset time.
		if (StrLen(Buf) >= 2 and Keylogger.initialized)
			SetTimer(_CheckNearMiss.Bind(Buf, _PrefixDeferredGeneration), -1)
	}
}

; The only writer for preview text. Every mutation receives a new immutable
; generation so an older render cannot pass an ABA buffer comparison after a
; type/backspace pair restores the same characters.
_PrefixSetBuffer(Value) {
	global _PrefixBuffer, _PrefixContentGeneration
	_PrefixBuffer := Value
	_PrefixContentGeneration += 1
	return _PrefixContentGeneration
}

; Hide only when a suggestion lifecycle is actually armed. This keeps the
; ordinary no-match keystroke path allocation-free while immediately removing
; pixels that stopped describing the engine's next outcome.
_PrefixDismissStaleSuggestion(DbgTag := "PrefixChanged", HideFn := 0) {
	global _KLLastShownSuggestion, _PrefixVisibleFireDecisions
	HasVisibleDecision := IsObject(_PrefixVisibleFireDecisions)
		and _PrefixVisibleFireDecisions.Length > 0
	if !IsObject(_KLLastShownSuggestion) and !HasVisibleDecision
		return false
	if HasMethod(HideFn, "Call")
		HideFn.Call(DbgTag, true)
	else
		TooltipHide(DbgTag, true)
	_NotifySuggestionDismissed()
	return true
}

_PrefixRenderStillCurrent(PrefixSnapshot, ContentGeneration) {
	global _PrefixBuffer, _PrefixContentGeneration
	return ContentGeneration == _PrefixContentGeneration
		&& PrefixSnapshot == _PrefixBuffer
}

_PrefixFireDecisionStillCurrent(Decision, CompletedBuffer := unset,
		ExpectedEndChar := unset) {
	global HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	global HSE_RegistryTransitionDepth
	global HSE_RebuildInProgress, HSE_Buffer
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	if !(IsObject(Decision)
		and Decision.HasOwnProp("RegistryGeneration")
		and Decision.HasOwnProp("BufferBefore")
		and Decision.HasOwnProp("BufferAfterCompletion")
		and Decision.HasOwnProp("EndChar")
		and Decision.HasOwnProp("RuntimeDecisionGeneration")
		and Decision.HasOwnProp("PrefixContentGeneration")
		and Decision.HasOwnProp("PrefixInputContextGeneration"))
		return false
	; Text equality alone is not an owner: reset/Home followed by retyping the
	; same characters is an ABA transition and can change the engine's word-start
	; context. The decision must retain both epochs through pixel publication and
	; the later dispatch claim.
	if (Decision.PrefixContentGeneration != _PrefixContentGeneration
		or Decision.PrefixInputContextGeneration
			!= _PrefixInputContextGeneration)
		return false
	if (HSE_RebuildInProgress or HSE_RegistryTransitionDepth > 0
		or Decision.RuntimeDecisionGeneration
			!= HSE_RuntimeDecisionGeneration
		or Decision.RegistryGeneration != HSE_RegistryGeneration)
		return false
	if IsSet(CompletedBuffer) {
		if Decision.BufferAfterCompletion !== CompletedBuffer
			return false
		if IsSet(ExpectedEndChar) and Decision.EndChar !== ExpectedEndChar
			return false
		return true
	}
	return Decision.BufferBefore == HSE_Buffer
}

; Renderer callback: every FireDecision row must still describe the exact live
; engine buffer and registry generation. Non-hotstring surfaces carry no such
; rows and are valid; presenting one will clear the prior snapshot at publish.
HotstringPrefixWatcherDecisionItemsStillCurrent(Items) {
	if !IsObject(Items)
		return true
	PreviousCritical := Critical("On")
	try {
		for _, Item in Items {
			if (IsObject(Item) and Item.HasOwnProp("FireDecision")
				and !_PrefixFireDecisionStillCurrent(Item.FireDecision))
				return false
		}
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

; Renderer callback invoked at the pixel commit point. Publish only decisions
; that were revalidated in the same Critical span as reveal; otherwise clear the
; old owner and make the renderer tear the just-revealed stale surface down.
HotstringPrefixWatcherPublishVisibleDecisions(Items) {
	global _PrefixVisibleFireDecisions
	Next := []
	PreviousCritical := Critical("On")
	try {
		if IsObject(Items) {
			for _, Item in Items {
				if !(IsObject(Item) and Item.HasOwnProp("FireDecision"))
					continue
				if !_PrefixFireDecisionStillCurrent(Item.FireDecision) {
					_PrefixVisibleFireDecisions := []
					return false
				}
				Next.Push(Item.FireDecision)
			}
		}
		_PrefixVisibleFireDecisions := Next
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

HotstringPrefixWatcherClearVisibleDecisions(EmitDismissed := true) {
	global _PrefixVisibleFireDecisions, _KLLastShownSuggestion
	DismissedRecord := 0
	PreviousCritical := Critical("On")
	try {
		_PrefixVisibleFireDecisions := []
		DismissedRecord := _KLLastShownSuggestion
		_KLLastShownSuggestion := ""
	} finally {
		Critical(PreviousCritical)
	}
	if EmitDismissed
		_PrefixEmitDetachedSuggestionDismissal(DismissedRecord)
	return DismissedRecord
}

; TooltipHide uses the pure clear mode inside its pixel transaction, then calls
; this only after restoring interruptibility. Kept public so the renderer never
; reaches into the watcher's private metric state.
HotstringPrefixWatcherEmitDismissedRecord(DismissedRecord) {
	return _PrefixEmitDetachedSuggestionDismissal(DismissedRecord)
}

; Renderer post-commit callback, intentionally outside its Critical pixel swap.
; TooltipShow is asynchronous, so scheduling/logging at request time produced
; phantom suggestion rows and LLM timers when UIA later rejected the render.
HotstringPrefixWatcherOnSurfacePresented(Items, SurfaceToken) {
	global _PrefixVisibleFireDecisions
	if !IsObject(Items) or !IsObject(SurfaceToken)
		return false
	PrimaryItem := 0
	ClosesHotstringSuggestion := false
	PreviousCritical := Critical("On")
	try {
		if !TooltipSurfaceTokenIsCurrent(SurfaceToken)
			return false
		if (_PrefixVisibleFireDecisions.Length == 0) {
			ClosesHotstringSuggestion := true
		} else {
		for _, Item in Items {
			if !(IsObject(Item) and Item.HasOwnProp("FireDecision"))
				continue
			if Item.FireDecision !== _PrefixVisibleFireDecisions[1]
				return false
			PrimaryItem := Item
			break
		}
		}
	} finally {
		Critical(PreviousCritical)
	}
	if ClosesHotstringSuggestion
		return _NotifySuggestionDismissedForSurfaceReplacement(SurfaceToken)
	if !IsObject(PrimaryItem)
		return false
	; This callback is deliberately outside the renderer Critical span. The metric
	; helper binds its state + final keylogger queue push to SurfaceToken without
	; running privacy work under Critical.
	if !_NotifySuggestionShownForSurface(PrimaryItem.Trigger, PrimaryItem.Text,
		PrimaryItem.Category, PrimaryItem.IsPrivate, SurfaceToken)
		return false
	if IsSet(LLM_Bridge_ScheduleAfterHotstring)
		try LLM_Bridge_ScheduleAfterHotstring(Items, SurfaceToken)
	return true
}

; Dispatch callback. Registered Specs match by object identity; transient
; repeat/personal fallbacks are recreated on every probe, so they match by their
; engine-owned kind + trigger. Exact completed-buffer and end-char equality
; prevents an old visible row from donating its frozen dynamic value elsewhere.
HotstringPrefixWatcherClaimVisibleDecision(Spec, EndChar, BufferAfterCompletion) {
	global _PrefixVisibleFireDecisions
	if !IsObject(Spec) or !IsObject(_PrefixVisibleFireDecisions)
		return 0
	PreviousCritical := Critical("On")
	try {
		for _, Decision in _PrefixVisibleFireDecisions {
			if !_PrefixFireDecisionStillCurrent(
				Decision, BufferAfterCompletion, EndChar)
				continue
			IdentityMatches := false
			if (Decision.HasOwnProp("SpecIdentity") and Decision.SpecIdentity != 0) {
				IdentityMatches := ObjPtr(Spec) == Decision.SpecIdentity
			} else if (Decision.HasOwnProp("TransientKind")
				and Spec.HasOwnProp("TransientKind")
				and Decision.HasOwnProp("Spec")
				and IsObject(Decision.Spec)
				and Decision.Spec.HasOwnProp("Trigger")
				and Spec.HasOwnProp("Trigger")) {
				IdentityMatches := Spec.TransientKind == Decision.TransientKind
					and Spec.Trigger == Decision.Spec.Trigger
			}
			if IdentityMatches
				return Decision
		}
	} finally {
		Critical(PreviousCritical)
	}
	return 0
}

; A batch registry writer calls this after raising its transition fence. The
; existing pixels and queued render belong to the old generation and are torn
; down synchronously; no matcher/index reconstruction is performed here.
HotstringPrefixWatcherInvalidateRegistryProjection() {
	global _PrefixBuffer, _PrefixInputHook, _PrefixVisibleFireDecisions
	if !_PrefixInputHook and (!IsObject(_PrefixVisibleFireDecisions)
		or _PrefixVisibleFireDecisions.Length == 0)
		return false
	_PrefixSetBuffer(_PrefixBuffer)
	_PrefixCancelRender()
	TooltipHide("RegistryProjection", true)
	_NotifySuggestionDismissed()
	return true
}

; Once the outermost registry transition commits, recompute the current answer
; without waiting for another physical key. The render remains debounced and
; runs only while the watcher lifecycle is active.
HotstringPrefixWatcherRefreshRegistryProjection() {
	global _PrefixInputHook, HSE_Buffer
	if A_IsSuspended or !_PrefixInputHook or HSE_Buffer == ""
		return false
	return _PrefixScheduleRender()
}

; Whether a near-miss record must be withheld whole rather than written.
;
; The near-miss row is PERSISTED — it reaches today.log, the metrics store and
; every replicated device — and it carries both columns, so the rule is the one
; the suggested/dismissed pair already follows: a private mapping is withheld
; entirely, because redacting the trigger while keeping the replacement (which
; IS the IBAN) leaks anyway.
;
; HONEST SCOPE: this guard is defence in depth, not a fix for a demonstrated
; leak. Today _TriggerSet is built only by _AddTriggerToIndex from the TOML /
; cache pipeline, whose rows carry no private values; imperative personal-info
; registrations live only in the engine registry and never enter this analytics
; set. The guard exists because that is one registration change away and every
; sibling persisted sink already honours the same flag.
; @param Entry {Object} A _TriggerSet entry.
; @return {Boolean} True when the row must not be written.
_NearMissIsWithheld(Entry) {
	return (IsObject(Entry) and Entry.HasOwnProp("IsPrivate") and Entry.IsPrivate) ? true : false
}

; Checks whether the typed buffer (at word boundary) is a known trigger
; typed manually (manual_typed_known_trigger) or within edit distance 1
; of a known trigger (hotstring_near_miss).
_CheckNearMiss(Buf, Generation := unset, PausedOverride := unset) {
	global _TriggerSet, _PrefixDeferredGeneration
	if !IsSet(Generation)
		Generation := _PrefixDeferredGeneration
	CanPublish := IsSet(PausedOverride)
		? _PrefixDeferredCanPublish(Generation, PausedOverride)
		: _PrefixDeferredCanPublish(Generation)
	if !CanPublish
		return
	; Defense in depth: the sole consumer (KL_LogHotstringNearMiss) is inert when the
	; keylogger is off, so the whole O(n) scan is dead work then. _ResetPrefixBuffer
	; already gates + defers this, but guard here too in case the keylogger stopped
	; between the deferred schedule and this firing (near-miss-on-hotpath-scan).
	if !Keylogger.initialized
		return
	; Compare the last WORD, not the whole buffer. Since the star-fire path
	; re-seeds the preview from HSE_Buffer, this buffer can hold several words
	; plus the replacement that was just inserted — and every registered trigger
	; is a single word, so a whole-buffer comparison could never match anything
	; again after the first star fire of a sentence. The near-miss analytics went
	; quiet without a single error.
	Word := _PrefixWordTail(Buf)
	if (StrLen(Word) < 2)
		return
	key := StrLower(Word)
	; Exact match → user typed a known trigger without using the expansion
	if _TriggerSet.Has(key) {
		Entry := _TriggerSet[key]
		if _NearMissIsWithheld(Entry)
			return
		CanPublish := IsSet(PausedOverride)
			? _PrefixDeferredCanPublish(Generation, PausedOverride)
			: _PrefixDeferredCanPublish(Generation)
		if !CanPublish
			return
		try KL_LogHotstringNearMiss("manual_typed_known_trigger",
			Entry.Trigger, Entry.Output, Entry.Category)
		return
	}
	; Edit-distance-1 check — scan triggers of same length ± 1
	BufLen := StrLen(Word)
	for trig, Entry in _TriggerSet {
		tLen := StrLen(trig)
		if (Abs(tLen - BufLen) > 1)
			continue
		if (_EditDistance1(key, trig)) {
			if _NearMissIsWithheld(Entry)
				return
			CanPublish := IsSet(PausedOverride)
				? _PrefixDeferredCanPublish(Generation, PausedOverride)
				: _PrefixDeferredCanPublish(Generation)
			if !CanPublish
				return
			try KL_LogHotstringNearMiss("hotstring_near_miss",
				Entry.Trigger, Entry.Output, Entry.Category)
			; Only report the first near-miss per reset to avoid spam
			return
		}
	}
}

; Returns true when the Levenshtein distance between a and b is exactly 1.
; Only evaluates strings whose lengths differ by at most 1 (pre-filtered).
_EditDistance1(a, b) {
	la := StrLen(a)
	lb := StrLen(b)
	if (la = lb) {
		; Same length — must be exactly one substitution
		diffs := 0
		loop la {
			if (SubStr(a, A_Index, 1) != SubStr(b, A_Index, 1))
				diffs += 1
			if (diffs > 1)
				return false
		}
		return diffs = 1
	}
	; Length differs by 1 — one insertion or deletion
	longer  := (la > lb) ? a : b
	shorter := (la > lb) ? b : a
	llong   := (la > lb) ? la : lb
	lshort  := (la > lb) ? lb : la
	i := 1
	j := 1
	skipped := false
	while (i <= llong and j <= lshort) {
		if (SubStr(longer, i, 1) != SubStr(shorter, j, 1)) {
			if skipped
				return false
			skipped := true
			i += 1
		} else {
			i += 1
			j += 1
		}
	}
	return true
}

KL_LogHotstringNearMiss(kind, trigger, replacement, h_type) {
	if !Keylogger.initialized
		return
	KL_AppendLog(Map(
		"type",        kind,
		"app",         Keylogger.session_app,
		"trigger",     trigger,
		"replacement", replacement,
		"h_type",      h_type
	))
}

; Ask the canonical engine oracle for the current completion decisions and
; project them into tooltip rows. The file catalogue is deliberately absent.
; Debounced render scheduler — see _PREFIX_RENDER_DEBOUNCE_MS. Each keystroke
; re-arms a one-shot timer (negative period), so a burst of keystrokes collapses
; into ONE trailing render once typing pauses. The flush re-runs the lookup
; against the CURRENT buffer, so the coalesced render always reflects the latest
; typed state. Only the visual preview is deferred — the expansion/fire path
; (HSE_DispatchMatch) stays fully synchronous, and _ResetPrefixBuffer keeps its
; immediate hide so a fired hotstring's tooltip vanishes at once.
_PrefixScheduleRender() {
	global _PREFIX_RENDER_DEBOUNCE_MS
	global _PrefixRenderScheduledGeneration, _PrefixRenderTimer
	global _PrefixDeferredGeneration
	PreviousCritical := Critical("On")
	try {
		; Reuse one adapter handle and BoundFunc throughout a lifecycle so the
		; per-keystroke debounce stays allocation-free. A new lifecycle gets a
		; new immutable owner.
		if (!(_PrefixRenderTimer is Map)
			or _PrefixRenderScheduledGeneration != _PrefixDeferredGeneration) {
			TimerCancel(_PrefixRenderTimer)
			_PrefixRenderScheduledGeneration := _PrefixDeferredGeneration
			try _PrefixRenderTimer := TimerAfter(_PREFIX_RENDER_DEBOUNCE_MS / 1000,
				_PrefixRenderFlush.Bind(_PrefixDeferredGeneration))
			catch {
				_PrefixRenderTimer := 0
				_PrefixRenderScheduledGeneration := -1
				return false
			}
		} else {
			try TimerRestartAfter(_PrefixRenderTimer, _PREFIX_RENDER_DEBOUNCE_MS / 1000)
			catch {
				_PrefixRenderTimer := 0
				_PrefixRenderScheduledGeneration := -1
				return false
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
	return true
}
; Cancel any pending debounced render. Called the instant a hotstring fires:
; the preview armed for the PRE-expansion buffer is now obsolete, and leaving
; the timer armed lets it fire reentrantly inside HSE_DispatchMatch's SendInput
; message pump — drawing a throwaway tooltip in the middle of the magic-key
; expansion (~35 ms added to that keystroke at speed). The fire path schedules a
; fresh render for the POST-expansion state itself, so nothing wanted is lost.
_PrefixCancelRender() {
	global _PrefixRenderScheduledGeneration, _PrefixRenderTimer
	PreviousCritical := Critical("On")
	try {
		TimerCancel(_PrefixRenderTimer)
		_PrefixRenderTimer := 0
		_PrefixRenderScheduledGeneration := -1
	} finally {
		Critical(PreviousCritical)
	}
}
_PrefixRenderFlush(Generation := unset) {
	global _PrefixWatcherSuppressed, HSE_Suppressed
	global _PrefixRenderScheduledGeneration, _PrefixRenderTimer
	if !IsSet(Generation)
		Generation := _PrefixRenderScheduledGeneration
	; Belt-and-suspenders: retire only this exact owner. A stale callback must
	; never cancel the fresh timer that resume installed in the same global slot.
	PreviousCritical := Critical("On")
	try {
		if (Generation == _PrefixRenderScheduledGeneration) {
			TimerCancel(_PrefixRenderTimer)
			_PrefixRenderTimer := 0
			_PrefixRenderScheduledGeneration := -1
		}
	} finally {
		Critical(PreviousCritical)
	}
	; A render queued before suspend/stop belongs to the previous lifecycle even
	; if it happens to dispatch after resume. Gate on both generation and native
	; pause so the old state can never repaint itself into the new context.
	if !_PrefixDeferredCanPublish(Generation)
		return
	; Skip while a send burst is in flight: TooltipShow is a ~20-55 ms Gui rebuild
	; (Build + Present + DWM border) that pumps the message loop, so running it
	; during an expansion could let the preview straddle the burst. The fire path
	; schedules a fresh render for the post-expansion state once suppression clears.
	if (_PrefixWatcherSuppressed or HSE_Suppressed)
		return
	; Runs from a timer (outside _OnPrefixChar's try), so guard it — an unhandled
	; exception in a timer callback would surface a blocking error dialog.
	try
		_LookupAndRender()
	catch as Err
		try LoggerError("PrefixWatcher", "Deferred render failed: {1}.", Err.Message)
}

; Project one immutable engine decision into a display row. Candidate discovery,
; collision ordering and all fire gates stay owned by HSE_PreviewNextDecision;
; this layer only formats what that oracle already decided.
_PrefixDecisionDisplayText(Decision) {
	if !(IsObject(Decision) and Decision.HasOwnProp("Spec")
		and IsObject(Decision.Spec))
		return ""
	Spec := Decision.Spec
	; Personal values carry an immutable field/value snapshot on the same Spec
	; that will fire. Mask that snapshot for display without re-reading mutable
	; personal state or changing the complete value frozen for dispatch.
	if (Spec.HasOwnProp("PreviewFields") and Spec.HasOwnProp("PreviewValues")) {
		if !IsSet(_PIPreviewMaskedText)
			return ""
		try return _PIPreviewMaskedText(Spec.PreviewFields, Spec.PreviewValues)
		catch
			return ""
	}
	; Send-key syntax is not literal screen text: showing `""{Left}` as five
	; printable characters would be another prediction engine. Such mappings may
	; opt in later with an explicit, engine-owned PreviewOutput snapshot.
	if !(Decision.HasOwnProp("OnlyText") and Decision.OnlyText) {
		return (Spec.HasOwnProp("PreviewOutput") and Spec.PreviewOutput is String)
			? Spec.PreviewOutput : ""
	}
	return (Decision.HasOwnProp("Replacement") and Decision.Replacement is String)
		? Decision.Replacement : ""
}

_PrefixDecisionCategory(Spec) {
	if (Spec.HasOwnProp("Category") and Spec.Category != "")
		return Spec.Category
	if Spec.HasOwnProp("PreviewFields")
		return "personal"
	if (Spec.HasOwnProp("IsRepeat") and Spec.IsRepeat)
		return "magickey"
	return ""
}

_PrefixCandidateFromDecision(Decision, ContentGeneration,
		InputContextGeneration) {
	if !(IsObject(Decision) and Decision.HasOwnProp("Spec")
		and IsObject(Decision.Spec))
		return ""
	; The HSE answer is local to this lookup. Clone it before adding the preview
	; owner's epochs so no renderer mutation leaks back into engine state.
	Decision := Decision.Clone()
	Decision.PrefixContentGeneration := ContentGeneration
	Decision.PrefixInputContextGeneration := InputContextGeneration
	Text := _PrefixDecisionDisplayText(Decision)
	if !(Text is String) or Text == ""
		return ""
	Spec := Decision.Spec
	Category := _PrefixDecisionCategory(Spec)
	Section := Spec.HasOwnProp("Section") ? Spec.Section : ""
	return {
		Trigger: Spec.HasOwnProp("Trigger") ? Spec.Trigger : "",
		Output: Text,
		Category: Category,
		Section: Section,
		Length: Spec.HasOwnProp("Length") ? Spec.Length : 0,
		Priority: Spec.HasOwnProp("Priority") ? Spec.Priority : "",
		GroupOrder: Spec.HasOwnProp("GroupOrder") ? Spec.GroupOrder : 0,
		Seq: Spec.HasOwnProp("Seq") ? Spec.Seq : 0,
		Delay: Decision.HasOwnProp("GateDurationMs")
			? Decision.GateDurationMs / 1000 : 0,
		IsPrivate: (Spec.HasOwnProp("IsPrivate") and Spec.IsPrivate) ? true : false,
		Completion: Decision.HasOwnProp("Completion") ? Decision.Completion : "",
		FireDecision: Decision
	}
}

; Ask the engine the only two questions represented by the bubble: what fires
; on a normal end character, and what fires on the configured magic key. The
; old collector walked a second file-derived index, ranked its own candidate
; union, then asked the matcher whether the chosen row happened to be valid.
; That could never discover a different live winner or a same-trigger reload.
_PrefixCollectCandidates(ContentGeneration := unset,
		InputContextGeneration := unset) {
	global HSE_Buffer, HSE_WORD_TERMINATORS, ScriptInformation
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	Candidates := []
	if !IsSet(HSE_Buffer) or HSE_Buffer == ""
		return Candidates
	if !IsSet(ContentGeneration)
		ContentGeneration := _PrefixContentGeneration
	if !IsSet(InputContextGeneration)
		InputContextGeneration := _PrefixInputContextGeneration

	EndCompletion := SubStr(HSE_WORD_TERMINATORS, 1, 1)
	if EndCompletion != "" {
		EndDecision := HSE_PreviewNextDecision(HSE_Buffer, EndCompletion)
		EndCandidate := _PrefixCandidateFromDecision(EndDecision,
			ContentGeneration, InputContextGeneration)
		if IsObject(EndCandidate)
			Candidates.Push(EndCandidate)
	}

	MagicKey := (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey"))
		? ScriptInformation["MagicKey"] : ""
	if MagicKey != "" and MagicKey !== EndCompletion {
		MagicDecision := HSE_PreviewNextDecision(HSE_Buffer, MagicKey)
		MagicCandidate := _PrefixCandidateFromDecision(MagicDecision,
			ContentGeneration, InputContextGeneration)
		if IsObject(MagicCandidate)
			Candidates.Push(MagicCandidate)
	}
	return Candidates
}

_LookupAndRender() {
	global _PrefixBuffer
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	; Capture text and both ownership epochs as one in-memory context. Candidate
	; resolution may yield in a callable; these immutable values follow every
	; FireDecision through the renderer's final commit oracle.
	PreviousCritical := Critical("On")
	try {
		PrefixSnapshot := _PrefixBuffer
		ContentGeneration := _PrefixContentGeneration
		InputContextGeneration := _PrefixInputContextGeneration
	} finally {
		Critical(PreviousCritical)
	}
	Len := StrLen(PrefixSnapshot)
	; This render is scheduled by the post-fire buffer sync, so it prints the
	; resolved replacement without the user typing anything further — the one
	; DEBUG site that fires on the expansion itself rather than on a keystroke.
	if LoggerIsDebugEnabled()
		LoggerDebug("PrefixWatcher", "DBG _LookupAndRender: buf='{1}' len={2}.", _PrefixLogSafe(PrefixSnapshot), Len)
	Candidates := _PrefixCollectCandidates(
		ContentGeneration, InputContextGeneration)
	if (Candidates.Length == 0) {
		if LoggerIsDebugEnabled()
			LoggerDebug("PrefixWatcher", "DBG no prefix match for '{1}'.", _PrefixLogSafe(PrefixSnapshot))
		TooltipHide("LookupNoMatch", true)
		_NotifySuggestionDismissed()
		return
	}
	if LoggerIsDebugEnabled()
		LoggerDebug("PrefixWatcher", "DBG prefix MATCH for '{1}' ({2} candidates).", _PrefixLogSafe(PrefixSnapshot), Candidates.Length)

	; Candidate collection already returns the engine's one canonical winner for
	; each completion key, ordered end-char then magic. There are no speculative
	; losers to dim and no trigger-suffix heuristic to classify.
	Items := []
	for _, Entry in Candidates {
		Cfg := HotstringsResolve(Entry.Category, Entry.Section)
		if !Cfg.ShowTooltip
			continue
		Color := (Cfg.Color != "") ? Cfg.Color : ""
		Decision := Entry.FireDecision
		GateDurationMs := Decision.HasOwnProp("GateDurationMs")
			? Decision.GateDurationMs : 0
		RemainingMs := Decision.HasOwnProp("RemainingMs")
			? Decision.RemainingMs : 0
		; Equality is technically fireable in the dispatch gate, but a row with no
		; remaining interaction window cannot be honestly painted after a debounce.
		if (GateDurationMs > 0 and RemainingMs <= 0)
			continue
		TriggerLabel := (Decision.EndChar == "") ? Decision.Completion : "↵"
		Item := { Text: Entry.Output, TriggerLabel: TriggerLabel,
		          ColorHex: Color, DurationSec: GateDurationMs / 1000,
		          Trigger: Entry.Trigger, Category: Entry.Category,
		          IsDimmed: false, FireDecision: Decision,
		          IsPrivate: (Entry.HasOwnProp("IsPrivate") and Entry.IsPrivate) ? true : false }
		if GateDurationMs > 0 {
			Item.ExpireOriginTick := Decision.GateOriginTick
			Item.ExpireDurationMs := GateDurationMs
		}
		Items.Push(Item)
	}
	if (Items.Length == 0) {
		if LoggerIsDebugEnabled()
			LoggerDebug("PrefixWatcher", "DBG all candidates have ShowTooltip=false, hiding.")
		TooltipHide("LookupNoItems", true)
		_NotifySuggestionDismissed()
		return
	}
	if LoggerIsDebugEnabled() {
		; A private row's TEXT is the user's own IBAN, card number or SSN, and
		; DEBUG is exactly the level a user is asked to switch on when reporting a
		; bug — so the count is logged and the content is not. The bubble itself is
		; unaffected: showing the user their own data on their own screen is the
		; whole feature.
		if Items[1].IsPrivate
			LoggerDebug("PrefixWatcher", "DBG calling TooltipShow: {1} item(s), first is a private mapping (content withheld).", Items.Length)
		else
			LoggerDebug("PrefixWatcher", "DBG calling TooltipShow: {1} item(s), first='{2}'.", Items.Length, Items[1].Text)
	}
	; Candidate collection and config resolution can yield to a physical OnChar.
	; Refuse the old answer at the last boundary before it becomes a tooltip
	; request; comparing the content generation also closes ABA mutations.
	if !_PrefixRenderStillCurrent(PrefixSnapshot, ContentGeneration)
		return
	if !HotstringPrefixWatcherDecisionItemsStillCurrent(Items)
		return
	TooltipShow(Items)
}
