; lib/hotstrings/hotstring_inputhook.ahk

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
; Included by lib/hotstrings/hotstring_prefix_watcher.ahk.
; ==============================================================================

; The prefix index built at boot. Map(lowerPrefix -> Array of entries), where
; each entry is { Trigger, Output, Category, Section, Length }.
global _PrefixIndex := Map()

; Flat set of all known trigger strings (lower-cased) → entry object.
; Used by the near-miss detector in _ResetPrefixBuffer so it can check
; exact trigger equality and Levenshtein-1 neighbours without re-walking
; the prefix tree.
global _TriggerSet := Map()

; Live keystroke buffer with original casing preserved — the index now holds
; one entry per case variant (``ct`` / ``Ct`` / ``CT`` for non-strict
; triggers, exactly mirroring CreateCaseSensitiveHotstrings), so the lookup
; is a byte-for-byte match against this buffer. Trimmed to MAX_BUFFER_LEN
; whenever it would overflow so memory and lookup cost stay bounded.
global _PrefixBuffer := ""

; Reference to the running InputHook (kept global so the GC does not collect
; it and so that the watcher can be reset / stopped at shutdown).
global _PrefixInputHook := 0

; Set when HotstringPrefixWatcherRebuildIndex is asked to rebuild while the driver
; is suspended (a live section toggle during pause). The rebuild is deferred and
; replayed by Ergopti_OnSuspendResume, mirroring LLM_Menu_OnResume — otherwise the
; preview index stays permanently diverged from the engine after resume.
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

; The preview boundary set. NOT a cached copy any more: it delegates to the
; matcher's own derivation so the tooltip and the engine cannot answer the
; word-boundary question differently. A cache here was tried twice — first a
; compile-time snapshot, then a refreshed copy built from a WIDER expression
; than the matcher used — and both drifted, each time producing suggestions the
; engine then refused to fire.
_PrefixWordBoundaries() {
    return _HSE_WordBoundarySet()
}

; Would the ENGINE actually fire this trigger right now? Asked of the engine's own
; Spec and its own buffer, never re-derived here.
;
; The preview used to infer "am I at a word start?" from its own anchor — the
; suffix after the last boundary character in _PrefixBuffer. That is a DIFFERENT
; question from the one the engine answers, and it rests on a DIFFERENT buffer.
; The two diverge after any expansion, because _PrefixBuffer is rebuilt by the
; sync block below (strip + replacement + suffix truncation) while HSE_Buffer
; keeps the real typed context. Measured case: typing "at" then the magic key
; fired the repeat (t★ → tt); _PrefixBuffer became "tt" while HSE_Buffer still
; ended "...att". The preview saw "tt" as word-initial and offered tt★ →
; télétravail; the engine, holding "att", refused it. The user got a tooltip that
; could not be validated — the tooltip lied about what the engine would do.
;
; Fails OPEN: a trigger the engine does not know is left visible rather than
; silently dropped, so a registry gap degrades to the old behaviour instead of
; emptying the tooltip.
; @param Trigger The candidate trigger, exactly as registered.
; @return true when the engine would fire it against its current buffer.
_PreviewEngineWouldFire(Trigger) {
    global HSE_RegistryByLastChar, HSE_Buffer
    if (Trigger == "")
        return false
    LastChar := SubStr(Trigger, -1)
    if (!IsSet(HSE_RegistryByLastChar) or !HSE_RegistryByLastChar.Has(LastChar))
        return true
    for _, Spec in HSE_RegistryByLastChar[LastChar] {
        if (Spec.Trigger != Trigger)
            continue
        ; A star trigger is evaluated against the buffer as it will be ONE
        ; keystroke from now — the magic key has not been typed yet at preview
        ; time, but it is the trigger's last character, so appending it
        ; reconstructs exactly what the engine will match against.
        EvalBuf := HSE_Buffer
        if (Spec.HasOwnProp("Star") and Spec.Star)
            EvalBuf .= LastChar
        CaseSensitive := (Spec.HasOwnProp("CaseSensitive") and Spec.CaseSensitive)
        if !HSE_SuffixMatches(EvalBuf, Trigger, CaseSensitive)
            return false
        return _HSE_WordBoundaryAllows(EvalBuf, Spec)
    }
    return true
}

; Categories scanned at boot. The order matches Hammerspoon's default load
; order so a tie on the prefix index returns the same first-match across
; both drivers.
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

; Build the prefix index from every category TOML and start the InputHook.
; Idempotent — calling it twice is a no-op (the second call only logs).
HotstringPrefixWatcherInit() {
	global _PrefixInputHook, _PrefixIndex, _PREFIX_WATCHER_CATEGORIES
	if _PrefixInputHook {
		LoggerWarn("PrefixWatcher", "Init called twice — ignoring duplicate.")
		return
	}
	LoggerStart("PrefixWatcher", "Initializing prefix watcher…")

	; The trigger index (~3180 entries) is too heavy for the boot critical path, so
	; start the InputHook with an EMPTY index here (cheap). It is built ONCE, off the
	; critical path, at the end of RegisterEmojisSymbolsDeferred — by then the boot has
	; settled and HotstringsResolve is memoised for every section, so the single
	; HotstringPrefixWatcherRebuildIndex (now a fast in-memory cache build, not a TOML
	; rescan) runs reliably in ~220 ms. That function requires the InputHook to already
	; exist — it does, created just below. _LookupAndRender hides the tooltip gracefully
	; while the index is empty, so the only visible effect is no live preview for the
	; brief window between "ready" and that deferred build.
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
                                HSE_FeedReset(true, true)
		_ResetPrefixBuffer()
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
_NotifySuggestionShown(Trigger, Output, Category) {
	global _KLLastShownSuggestion
	Prev := _KLLastShownSuggestion
	if (IsObject(Prev) and Prev.Trigger == Trigger and Prev.Output == Output) {
		return
	}
	if IsObject(Prev) {
		try KL_LogHotstringDismissed(Prev.Trigger, Prev.Output, Prev.Category)
	}
	_KLLastShownSuggestion := { Trigger: Trigger, Output: Output, Category: Category }
	try KL_LogHotstringSuggested(Trigger, Output, Category)
}

_NotifySuggestionDismissed() {
	global _KLLastShownSuggestion
	Prev := _KLLastShownSuggestion
	if !IsObject(Prev) {
		return
	}
	_KLLastShownSuggestion := ""
	try KL_LogHotstringDismissed(Prev.Trigger, Prev.Output, Prev.Category)
}

; Silent clear — used by the fire path so a single user action emits
; ``hotstring`` (fired) without a paired ``hotstring_dismissed``.
_NotifySuggestionConsumed() {
	global _KLLastShownSuggestion
	_KLLastShownSuggestion := ""
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
_HSE_QueueFireLog(Trigger, Replacement, HType, Category, Section) {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled, HSE_FIRE_LOG_DEFER_MS
	_HSE_FireLogQueue.Push({ Trigger: Trigger, Replacement: Replacement,
		HType: HType, Category: Category, Section: Section })
	if !_HSE_FireLogScheduled {
		_HSE_FireLogScheduled := true
		; Negative period = run once after the delay. The delay exceeds the
		; suppress release so this drain is always scheduled to fire AFTER it,
		; never delaying it even though both run on the single AHK thread.
		SetTimer(_HSE_DrainFireLog, -HSE_FIRE_LOG_DEFER_MS)
	}
}

; Drain every queued fired-hotstring record through KL_LogHotstring. Runs off the
; keystroke path (armed by _HSE_QueueFireLog). Swaps the queue out first so fires
; that land while we drain accumulate into a fresh batch and re-arm the timer.
_HSE_DrainFireLog() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	_HSE_FireLogScheduled := false
	Batch := _HSE_FireLogQueue
	_HSE_FireLogQueue := []
	for _, Rec in Batch {
		try KL_LogHotstring(Rec.Trigger, Rec.Replacement, Rec.HType, "", Rec.Category, Rec.Section)
	}
}

; Rebuild the prefix index from the CURRENT Features state without restarting
; the InputHook. Called after a live section toggle (ui/tray_menu.ahk
; _HS_TryLiveToggle) so the preview tooltip stops/starts in lockstep with the
; HSE expansion: _RegisterCategoryTriggers only indexes sections whose Features
; "enabled" flag is set, so a freshly disabled section's triggers disappear from
; the index and a freshly enabled one's appear — exactly what a full Reload did.
; No-op when the watcher is not running (the index is intentionally empty then).
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
	; section toggle made during pause must not leave the preview index diverged from
	; the engine after resume (deferred-replay pattern, like LLM_Menu_OnResume).
	if A_IsSuspended {
		global _PrefixIndexRebuildPending := true
		return
	}
	; Build-then-swap so a concurrent OnChar preview lookup never observes an
	; empty or partially-populated index mid-rebuild. The fresh maps are built
	; in locals and assigned to the live globals in a single statement each at
	; the end — the reader always sees either the old index or the complete new
	; one, never the transient empty Map() that an in-place clear would expose.
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
	_ensureMs := A_TickCount - _ensureStart
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
	_buildMs := A_TickCount - _buildStart
	_PrefixIndex := NewIndex
	_TriggerSet := NewSet
	; Bundled categories now rebuild from memory (no FileRead, no regex); only
	; personal still parses TOML. Permanent instrumentation: the trigger count +
	; wall time catch a regression that reintroduces the cold-disk cost, while the
	; ensure/build split + cache/toml tally localise any residual wall-clock
	; (cache-load vs the in-memory build loop) and confirm the fast path stays live
	; (cache=0 toml=6 would mean the cache path silently broke).
	try LoggerInfo("PrefixWatcher",
		"Index rebuilt: {1} trigger(s) in {2} ms (ensure={3}ms build={4}ms cache={5} toml={6} rows={7}).",
		NewSet.Count, A_TickCount - _rebuildStart, _ensureMs, _buildMs, _cachedCats, _tomlCats,
		(IsSet(_HS_CACHE_ROWS) ? _HS_CACHE_ROWS.Count : "unset"))
	; A just-disabled section may still have a tooltip on screen — hide it so the
	; preview cannot outlive the expansion it was advertising.
	TooltipHide("LiveToggleRebuild", true)
}

; Stop the InputHook and clear the index. Useful when the user disables the
; preview from the tray menu or before reloading.
HotstringPrefixWatcherStop() {
	global _PrefixInputHook, _PrefixIndex, _PrefixBuffer
	if _PrefixInputHook {
		try _PrefixInputHook.Stop()
		_PrefixInputHook := 0
	}
	_PrefixIndex := Map()
	_PrefixBuffer := ""
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
; the threshold (see lib/hotpath_profiler.ahk). The InputHook binds here rather
; than directly to _OnPrefixChar so the timing wraps every one of the hot
; function's return paths without touching the function itself. Char is passed
; raw so the log string is built only when a keystroke is actually slow.
_OnPrefixCharProfiled(IH, Char) {
	_HotStart := HotPath_Now()
	_OnPrefixChar(IH, Char)
	HotPath_LogIfSlow("OnChar", _HotStart, Char)
}

; OnChar — called for every printable character produced by the active
; keyboard layout. We keep this fast: append, trim, lookup, render. Anything
; heavy belongs out of the hot path.
; Wrapped in try so that any exception from _LookupAndRender / TooltipShow
; does not silently kill the InputHook callback chain — AHK v2 stops invoking
; the OnChar callback permanently if an unhandled error propagates out of it.
_OnPrefixChar(IH, Char) {
	global _PrefixBuffer, _MAX_BUFFER_LEN, _PrefixWatcherSuppressed, HSE_Suppressed, _PrefixIndex, HSE_Buffer
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
					Pair  := _ActivePairsSnap[Char]
					Left  := Pair["left"]
					Right := Pair["right"]
					; Erase the character already delivered by the pass-through hook,
					; then send the wrapped replacement without re-triggering hotstrings.
					; Release the suppression in a finally: a throwing SendEvent/SendInstant
					; would otherwise leave the depth counter latched at >=1, silently killing
					; the whole hotstring engine + preview for the session (uia-wrap-suppress-latch).
					PrefixWatcherSuppress(true)
					try {
						SendEvent("{BackSpace}")
						SendInstant(Left . UIASel . Right)
					} finally {
						PrefixWatcherSuppress(false)
						_ResetPrefixBuffer()
					}
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
		if LoggerIsDebugEnabled()
			LoggerDebug("PrefixWatcher", "DBG OnChar: char='{1}' prefixBuf='{2}' hseBuf='{3}' suppressed={4}/{5}.", Char, _PrefixBuffer, HSE_Buffer, _PrefixWatcherSuppressed, HSE_Suppressed)
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
			_HseFired := HSE_DispatchMatch(HSEMatch, HSE_LastEndChar)
			HotPath_LogIfSlow("HSE.Dispatch", _HseDispatchTick, HSEMatch.Trigger)
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
				_HSE_QueueFireLog(HSEMatch.Trigger, HotstringRepl, HotstringHType, HotstringCategory, HotstringSection)
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
			; End-char fires are the original "word is done" case: the user
			; pressed a terminator, the trigger fired, the cursor is now at
			; a fresh word boundary. The old wipe behaviour is correct there.
			if (HSE_LastEndChar == "") {
				StripLen := (HSEMatch.HasOwnProp("Length") ? HSEMatch.Length : 0) - 1
				if (StripLen > 0 and StrLen(_PrefixBuffer) >= StripLen) {
					_PrefixBuffer := SubStr(_PrefixBuffer, 1, StrLen(_PrefixBuffer) - StripLen)
				} else if (StripLen > 0) {
					_PrefixBuffer := ""
				}
				if HSEMatch.HasOwnProp("Replacement") and Type(HSEMatch.Replacement) == "String" {
					_PrefixBuffer .= HSEMatch.Replacement
				}
				if (StrLen(_PrefixBuffer) > _MAX_BUFFER_LEN) {
					_PrefixBuffer := SubStr(_PrefixBuffer, -_MAX_BUFFER_LEN)
				}
				; Trim the buffer to only the suffix that could be a live trigger
				; prefix. The suffix after the last boundary is what _LookupAndRender
				; would use as its SearchKey. If that SearchKey has no entry in the
				; index the replacement is not a cascade seed — wipe to empty so the
				; next keystroke starts fresh rather than accumulating "maism" etc.
				Suffix := _SuffixAfterLastBoundary(_PrefixBuffer)
				_PrefixBuffer := (Suffix != "" and _PrefixIndex.Has(Suffix)) ? Suffix : ""
				; The roll/cascade injected new text into the buffer — check
				; if it prefixes a registered trigger and show the tooltip
				; immediately. This handles « p'★ → c'était »: the roll fires
				; p' → ct, the buffer becomes "ct", and the tooltip for ct★
				; should appear right away so the user knows to press ★.
				; Without this call, TooltipHide() would clear the display and
				; the next keystroke (★) would look up "ct★" instead of "ct".
				_PrefixScheduleRender()
				_NotifySuggestionConsumed()
			} else {
				_ResetPrefixBuffer(true)
			}
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
	global _PrefixWatcherSuppressed, HSE_Suppressed
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
		CtrlHeld := GetKeyState("Control", "P")
		if CtrlHeld {
			if (VK == 0x41) {
				; Ctrl+A — select-all. The next typed char replaces the
				; entire selection, landing at a fresh word-start.
				; IsPhysical=true so a real Ctrl+A landing inside the post-expansion
				; suppress window is honoured instead of being filtered as engine output.
				HSE_FeedReset(true, true)
				_ResetPrefixBuffer()
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
                                HSE_FeedReset(false, true)
				_ResetPrefixBuffer()
				return
			}
		}

		; Feed HSE with the appropriate buffer mutation. Backspace
		; decrements its buffer (preserving word context, the whole point
		; of the rewrite); Tab/Enter/arrows/Escape/mouse-click all declare
		; a word boundary — the cursor lands somewhere unknown but the next
		; typed run always starts fresh. Space is already handled by
		; HSE_FeedChar via OnChar's terminator path, but we also reset here
		; so a Space whose char event was swallowed (e.g. layered on
		; tap-hold) still flips the boundary flag.
		if (VK == 0x08) {
			HSE_FeedBackspace(true)
			; The preview must shrink by exactly one character too. It used to be
			; WIPED here (VK_BACK sat in ResetVKs) while the engine merely
			; decremented — preserving in-word context is the whole point of
			; HSE_FeedBackspace. So after a single backspace the engine would
			; still fire a hotstring the tooltip had stopped offering: the same
			; tooltip-versus-engine divergence as the boundary-set bug, skewed
			; the other way.
			_PrefixFeedBackspace()
			if (IsSet(LLM_Bridge_FeedKeyDownIfActive))
				LLM_Bridge_FeedKeyDownIfActive(VK)
		} else if (VK == 0x09 or VK == 0x0D) {
			if (VK == 0x09 and IsSet(LLM_Tooltip_TryAcceptTab) and LLM_Tooltip_TryAcceptTab())
				return
                        HSE_FeedReset(true, true)
			; Flush the rolling LLM context on Tab (when no suggestion was
			; accepted above) and Enter, mirroring the macOS reset_on_nav
			; contract. Previously the Enter flush lived in an unreachable
			; trailing else-if and silently never ran on this hook path.
			if (IsSet(LLM_Bridge_FeedKeyDownIfActive))
				LLM_Bridge_FeedKeyDownIfActive(VK)
		} else if (VK == 0x1B
				or VK == 0x25 or VK == 0x26
				or VK == 0x27 or VK == 0x28) {
			; Arrow keys and Escape move the cursor to an unknown position,
			; but the next typed run starts fresh — treat as word boundary.
                        HSE_FeedReset(true, true)
			if (IsSet(LLM_Bridge_FeedKeyDownIfActive))
				LLM_Bridge_FeedKeyDownIfActive(VK)
		}
		if ResetVKs.Has(VK) {
			_ResetPrefixBuffer()
		}
	} catch as Err {
		LoggerError("PrefixWatcher", "OnKeyDown error for VK {1}: {2}.", VK, Err.Message)
	}
}

; Shrink the watcher buffer by one character, mirroring HSE_FeedBackspace on the
; engine side so the tooltip keeps describing the same text the matcher will
; gate on. The tooltip is re-rendered from the shortened buffer rather than
; merely hidden: after deleting a typo the user is usually back on a live
; trigger prefix, and that suggestion should reappear.
;
; An empty buffer stays empty — there is nothing on screen to step back over,
; and the engine's own buffer is equally unable to go negative.
_PrefixFeedBackspace() {
	global _PrefixBuffer
	if (_PrefixBuffer == "") {
		TooltipHide("Backspace", true)
		_NotifySuggestionDismissed()
		return
	}
	_PrefixBuffer := SubStr(_PrefixBuffer, 1, StrLen(_PrefixBuffer) - 1)
	; The suggestion that was showing described the pre-backspace text, so it is
	; stale the moment the character disappears. Drop it before re-rendering so a
	; stale tooltip is never left standing if the new buffer matches nothing.
	TooltipHide("Backspace", true)
	_NotifySuggestionDismissed()
	if (_PrefixBuffer != "")
		_PrefixScheduleRender()
}

; Record a character that is now on screen into the watcher buffer. The ONE
; place that grows the preview buffer, shared by the plain no-match path and by
; a match that declined to fire — those two cases leave the screen in exactly
; the same state, so they must leave the buffer in the same state too. Handling
; them separately is how the declined case came to rewrite the buffer with a
; replacement that was never typed.
_PrefixAppendTypedChar(Char) {
	global _PrefixBuffer, _MAX_BUFFER_LEN, _PrefixIndex
	; A boundary character ends the word: nothing typed before it can still be a
	; live trigger prefix. HSE_Buffer deliberately keeps the terminator (triggers
	; may contain one as a non-final char); the preview only tracks the current
	; word, so it starts fresh here.
	if InStr(_PrefixWordBoundaries(), Char) {
		_ResetPrefixBuffer(false)
		return
	}
	_PrefixBuffer .= Char
	if (StrLen(_PrefixBuffer) > _MAX_BUFFER_LEN) {
		_PrefixBuffer := SubStr(_PrefixBuffer, -_MAX_BUFFER_LEN)
	}
	if LoggerIsDebugEnabled()
		LoggerDebug("PrefixWatcher", "DBG about to _LookupAndRender: buf='{1}' indexSize={2}.", _PrefixBuffer, _PrefixIndex.Count)
	_PrefixScheduleRender()
}

; Return the suffix of Buf that follows the last word-boundary character.
; Uses _PrefixWordBoundaries() so the result is the same SearchKey that
; _LookupAndRender would compute. Returns Buf unchanged when no boundary
; is present (the whole string is one word).
_SuffixAfterLastBoundary(Buf) {
	Idx := StrLen(Buf)
	while (Idx >= 1) {
		if (InStr(_PrefixWordBoundaries(), SubStr(Buf, Idx, 1)) > 0) {
			return SubStr(Buf, Idx + 1)
		}
		Idx -= 1
	}
	return Buf
}

; ConsumedByFire ─ true when the reset is the consequence of a hotstring
; firing. The currently-suggested entry is then cleared silently so the
; logger does not emit a ``hotstring_dismissed`` event paired with the
; ``hotstring`` (fired) one — HS treats the fire as the resolution of the
; suggestion, never a parallel dismissal. Every other caller (word
; terminator, mouse click, navigation key, prefix lost) leaves the default
; in place so the tooltip's disappearance is properly logged.
_ResetPrefixBuffer(ConsumedByFire := false) {
	global _PrefixBuffer, _TriggerSet, _TooltipDequeueActive
	Buf := _PrefixBuffer
	_PrefixBuffer := ""
	; Tooltips must disappear immediately upon hotstring firing.
	TooltipHide("ResetBuf", true)
	if ConsumedByFire {
		_NotifySuggestionConsumed()
	} else {
		_NotifySuggestionDismissed()
		; Near-miss / manual-trigger detection is pure keylogger analytics with no
		; ordering requirement, so (a) skip it entirely when the keylogger is inactive
		; — the default case pays zero — and (b) defer the O(n) trigger-set scan off the
		; synchronous, Critical keystroke thread to the next idle tick, so a logging
		; session never pays it on the typing path (near-miss-on-hotpath-scan). Buf is a
		; value copy, so the deferred scan sees the buffer as it was at reset time.
		if (StrLen(Buf) >= 2 and Keylogger.initialized)
			SetTimer(_CheckNearMiss.Bind(Buf), -1)
	}
}

; Checks whether the typed buffer (at word boundary) is a known trigger
; typed manually (manual_typed_known_trigger) or within edit distance 1
; of a known trigger (hotstring_near_miss).
_CheckNearMiss(Buf) {
	global _TriggerSet
	; Defense in depth: the sole consumer (KL_LogHotstringNearMiss) is inert when the
	; keylogger is off, so the whole O(n) scan is dead work then. _ResetPrefixBuffer
	; already gates + defers this, but guard here too in case the keylogger stopped
	; between the deferred schedule and this firing (near-miss-on-hotpath-scan).
	if !Keylogger.initialized
		return
	key := StrLower(Buf)
	; Exact match → user typed a known trigger without using the expansion
	if _TriggerSet.Has(key) {
		Entry := _TriggerSet[key]
		try KL_LogHotstringNearMiss("manual_typed_known_trigger",
			Entry.Trigger, Entry.Output, Entry.Category)
		return
	}
	; Edit-distance-1 check — scan triggers of same length ± 1
	BufLen := StrLen(Buf)
	for trig, Entry in _TriggerSet {
		tLen := StrLen(trig)
		if (Abs(tLen - BufLen) > 1)
			continue
		if (_EditDistance1(key, trig)) {
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

; Look up the current buffer in the prefix index and update the tooltip.
;
; ── Word-anchored lookup ──
; The buffer holds every keystroke since the last reset (word-breaker, mouse
; click, arrow key…), so for a mid-word context like ``l'ia`` the literal
; buffer is "l'ia" but the trigger the user is reaching for is the substring
; AFTER the last word-boundary char — here ``ia``. Looking up the full buffer
; means we miss every trigger whose context includes an in-word terminator
; (apostrophes for French contractions, punctuation, …) even though the
; HSE engine itself fires those triggers correctly via suffix matching.
;
; We slide a cursor across _PrefixWordBoundaries() to find the rightmost
; boundary in the buffer; everything to its right is the effective "word
; under typing", and that is what we look up. When no boundary is present
; we fall back to the full buffer.
; Debounced render scheduler — see _PREFIX_RENDER_DEBOUNCE_MS. Each keystroke
; re-arms a one-shot timer (negative period), so a burst of keystrokes collapses
; into ONE trailing render once typing pauses. The flush re-runs the lookup
; against the CURRENT buffer, so the coalesced render always reflects the latest
; typed state. Only the visual preview is deferred — the expansion/fire path
; (HSE_DispatchMatch) stays fully synchronous, and _ResetPrefixBuffer keeps its
; immediate hide so a fired hotstring's tooltip vanishes at once.
_PrefixScheduleRender() {
	global _PREFIX_RENDER_DEBOUNCE_MS
	SetTimer(_PrefixRenderFlush, -_PREFIX_RENDER_DEBOUNCE_MS)
}
; Cancel any pending debounced render. Called the instant a hotstring fires:
; the preview armed for the PRE-expansion buffer is now obsolete, and leaving
; the timer armed lets it fire reentrantly inside HSE_DispatchMatch's SendInput
; message pump — drawing a throwaway tooltip in the middle of the magic-key
; expansion (~35 ms added to that keystroke at speed). The fire path schedules a
; fresh render for the POST-expansion state itself, so nothing wanted is lost.
_PrefixCancelRender() {
	SetTimer(_PrefixRenderFlush, 0)
}
_PrefixRenderFlush() {
	global _PrefixWatcherSuppressed, HSE_Suppressed
	SetTimer(_PrefixRenderFlush, 0)   ; belt-and-suspenders: never re-fire on its own
	; A render queued just before suspend must not paint a preview while paused —
	; timer callbacks bypass native Suspend, so guard it explicitly.
	if A_IsSuspended
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

; True when candidate A outranks candidate B under the engine's collision
; tie-break: a longer trigger wins (the engine fires the longest match), then a
; higher priority, then — when both are equal — a false return preserves the
; original registration order (the engine's final ``Seq`` tiebreak). HasOwnProp
; guards keep it safe against entries built before the Priority field existed.
_PrefixCandidateBeats(A, B) {
	AL := A.HasOwnProp("Length") ? A.Length : 0
	BL := B.HasOwnProp("Length") ? B.Length : 0
	if (AL != BL) {
		return AL > BL
	}
	AP := A.HasOwnProp("Priority") ? A.Priority : 0
	BP := B.HasOwnProp("Priority") ? B.Priority : 0
	return AP > BP
}

; Return a NEW array of the candidates ordered by _PrefixCandidateBeats. A stable
; insertion sort (swap only on a strict beat) keeps equal-rank candidates in their
; original order, so the first item is exactly the mapping the engine would fire.
; The source array (the live prefix-index bucket) is never mutated.
_PrefixSortCandidates(Candidates) {
	Sorted := []
	for _, E in Candidates {
		Sorted.Push(E)
	}
	N := Sorted.Length
	I := 2
	while (I <= N) {
		Pivot := Sorted[I]
		J := I - 1
		while (J >= 1 and _PrefixCandidateBeats(Pivot, Sorted[J])) {
			Sorted[J + 1] := Sorted[J]
			J -= 1
		}
		Sorted[J + 1] := Pivot
		I += 1
	}
	return Sorted
}

_LookupAndRender() {
	global _PrefixBuffer, _PrefixIndex, _MIN_PREFIX_LEN, ScriptInformation
	PrefixSnapshot := _PrefixBuffer
	Len := StrLen(PrefixSnapshot)
	if LoggerIsDebugEnabled()
		LoggerDebug("PrefixWatcher", "DBG _LookupAndRender: buf='{1}' len={2} indexSize={3}.", PrefixSnapshot, Len, _PrefixIndex.Count)
	; Short buffers are only skipped when they have no entry in the index.
	; A 1-char buffer may validly match a magic-key trigger body (e.g. "c"
	; is the body of "c★"), so we let the lookup below decide — the early
	; exit here only avoids the Map lookup for guaranteed-empty cases.
	if (Len < 1) {
		TooltipHide("LookupLen0", true)
		_NotifySuggestionDismissed()
		return
	}

	; Walk the buffer from the right edge backwards; the first character we
	; meet that appears in ``HSE_WORD_TERMINATORS`` marks the boundary of
	; the leading context, and everything to its right is the current word
	; under typing. The straightforward ``InStr(..., , 1, -1)`` form does
	; NOT do this: with a positive StartingPos and a negative Occurrence,
	; AHK v2 essentially returns the first match from the left, not the
	; last from the right — verified by direct probe, which is why ``a'ia``
	; used to return ``a'ia`` (no terminator found) instead of ``ia``.
	LastTermPos := 0
	BufScanIdx := StrLen(PrefixSnapshot)
	while (BufScanIdx >= 1) {
		ScanChar := SubStr(PrefixSnapshot, BufScanIdx, 1)
		if (InStr(_PrefixWordBoundaries(), ScanChar) > 0) {
			LastTermPos := BufScanIdx
			break
		}
		BufScanIdx -= 1
	}
	SearchKey := (LastTermPos > 0) ? SubStr(PrefixSnapshot, LastTermPos + 1) : PrefixSnapshot
	if (SearchKey == "") {
		TooltipHide("LookupKeyEmpty", true)
		_NotifySuggestionDismissed()
		return
	}
	; AHK v2's Map is case-sensitive by default, so this lookup distinguishes
	; ``ct`` from ``CT`` — the index registers each case variant separately
	; with its pre-cased output, exactly mirroring CreateCaseSensitiveHotstrings.
	if !_PrefixIndex.Has(SearchKey) {
		if LoggerIsDebugEnabled()
			LoggerDebug("PrefixWatcher", "DBG no prefix match for '{1}'.", SearchKey)
		TooltipHide("LookupNoMatch", true)
		_NotifySuggestionDismissed()
		return
	}
	if LoggerIsDebugEnabled()
		LoggerDebug("PrefixWatcher", "DBG prefix MATCH for '{1}' ({2} candidates).", SearchKey, _PrefixIndex[SearchKey].Length)
	PrefixSnapshot := SearchKey

	; Collect candidates per group and lay them out as the user requested:
	; end-char (↵) triggers FIRST (top), then magic-key (★) triggers below.
	; End-char triggers usually have a shorter delay (the user types
	; space/tab/enter quickly) so they need maximum visibility on top.
	; Within each group, the FIRST surviving candidate is the one the engine
	; will actually fire — it is rendered normally. Every subsequent candidate
	; of the same group is rendered dimmed + strikethrough (IsDimmed flag,
	; consumed by tooltip.ahk's _TooltipBuildGui).
	; Rank colliding candidates by the engine's tie-break (longer trigger first,
	; then higher priority, then registration order) BEFORE splitting into display
	; groups. The split is stable, so the FIRST item in each group is the candidate
	; the engine would actually fire — it is rendered normally while the losers are
	; dimmed. Without this the non-dimmed preview was just the first-scanned trigger
	; (category load order), which made a personal trigger that the engine fires show
	; up dimmed beneath a common one it loses to.
	Candidates := _PrefixSortCandidates(_PrefixIndex[PrefixSnapshot])
	MK := ScriptInformation["MagicKey"]
	EndItems := []
	StarItems := []
	for _, Entry in Candidates {
		Cfg := HotstringsResolve(Entry.Category, Entry.Section)
		if !Cfg.ShowTooltip {
			continue
		}
		; Only offer what the engine would actually fire. The SearchKey scan above
		; decides WHICH candidates to consider; it is not a word-boundary verdict,
		; and treating it as one is what let a mid-word "tt" be advertised as a
		; word-initial trigger the engine then refused.
		if !_PreviewEngineWouldFire(Entry.Trigger) {
			if LoggerIsDebugEnabled()
				LoggerDebug("PrefixWatcher", "DBG candidate '{1}' skipped — the engine would not fire it here.", Entry.Trigger)
			continue
		}
		Color := (Cfg.Color != "") ? Cfg.Color : ""
		; The tooltip must stay visible as long as the expansion is still
		; armed — so the display duration equals the expansion window exactly.
		; When Delay = 0 the hotstring has no expiry window (DurationSec = 0
		; leaves the tooltip up until the safety timer fires), mirroring the
		; HS INFINITE_TOOLTIP_SEC convention. Each row carries its own delay
		; so rows with distinct delays activate the dequeue path in TooltipShow,
		; which removes each row individually as its deadline passes.
		ExpansionDelay := (Cfg.Delay != "") ? Cfg.Delay : 0
		TooltipDuration := ExpansionDelay
		; Only triggers whose LAST chars ARE the magic key qualify as star
		; triggers — a trigger containing MK in its body (but not as a suffix)
		; must be classified as an end-char trigger, otherwise it lands in the
		; wrong display bucket and shows the wrong completion key label
		MkLen := StrLen(MK)
		IsMagic := (MkLen > 0 and StrLen(Entry.Trigger) > MkLen and SubStr(Entry.Trigger, -MkLen) == MK)
		; Trigger label shown on the right side of the row:
		;   ★ (or the configured magic key) for star triggers,
		;   ↵  for end-char-gated triggers (space / punctuation / enter).
		TriggerLabel := IsMagic ? MK : "↵"
		Bucket := IsMagic ? StarItems : EndItems
		Item := { Text: Entry.Output, TriggerLabel: TriggerLabel,
		          ColorHex: Color, DurationSec: TooltipDuration,
		          Trigger: Entry.Trigger, Category: Entry.Category,
		          IsDimmed: Bucket.Length > 0 }
		Bucket.Push(Item)
	}
	Items := []
	for _, Item in EndItems {
		Items.Push(Item)
	}
	for _, Item in StarItems {
		Items.Push(Item)
	}
	if (Items.Length == 0) {
		if LoggerIsDebugEnabled()
			LoggerDebug("PrefixWatcher", "DBG all candidates have ShowTooltip=false, hiding.")
		TooltipHide("LookupNoItems", true)
		_NotifySuggestionDismissed()
		return
	}
	if LoggerIsDebugEnabled()
		LoggerDebug("PrefixWatcher", "DBG calling TooltipShow: {1} item(s), first='{2}'.", Items.Length, Items[1].Text)
	TooltipShow(Items)
	if IsSet(LLM_Bridge_ScheduleAfterHotstring)
		try LLM_Bridge_ScheduleAfterHotstring(Items)
	; Log the suggestion based on the first (top) item only.
	Primary := Items[1]
	_NotifySuggestionShown(Primary.Trigger, Primary.Text, Primary.Category)
}
