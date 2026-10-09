; modules/keymap/layout_poll_helper.ahk

; ==============================================================================
; MODULE: Layout Poll Helper
; DESCRIPTION:
; Pure decision helper for the foreground keyboard-layout poll. The 1 s timer in
; ErgoptiPlus.ahk used to Reload() the moment the HKL differed, which discarded
; any in-flight typing on a transient flicker (layout-poll-blind-reload).
;
; _ShouldReloadForHkl isolates the "should we reload now?" logic so it is exercised
; headlessly by tests/meta/test_layout_quiescence.ahk. It has no OS dependency and
; never reloads — it only reports the decision and advances the caller's tracking
; refs. Reloading is deferred until the new layout is stable across two consecutive
; polls AND the user is physically idle AND no expansion is in flight, turning a
; transient flicker into a no-op while still adapting to a genuine layout switch.
;
; LayoutPollTick runs one poll through that decision and reloads through the
; terminal hand-off, with every lifecycle call behind a port so the retry policy
; is tested headlessly too: a refused reload is retried with a doubling wait, a
; few times per layout, and never when its refusal would be forced through.
;
; Only a layout the boot registrations do not fit reloads: without the Ergopti
; emulation, the magic key's source key is registered at load on the key that
; types its character on one layout (LayoutRemapSignature). The AltGr family
; (infra/altgr_family.ahk) and the digit-row swap (DigitRowIsSwapped) follow the
; foreground layout live instead, so with the emulation on (the default) no
; switch reloads, as with Windows' per-window input methods.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Reload quiescence decision ===========
; =================================================
; =================================================

; Returns true only when a genuine, sustained layout switch warrants a Reload().
; @param curHkl        Current foreground HKL (0 when unknown).
; @param lastHkl       ByRef tracker of the last layout we reloaded for; advanced on a true result.
; @param pendingHkl    ByRef debounce tracker; holds the candidate HKL awaiting a second confirming poll.
; @param suspended     True when the driver is paused (A_IsSuspended) — must never reload.
; @param isBlacklisted True when the foreground app is blacklisted (game / private) — must never reload.
; @param hseSuppressed Hotstring-engine suppression depth (>0 means an expansion is in flight).
; @param pwSuppressed  Prefix-watcher suppression depth (>0 means an expansion is in flight).
; @param idleMs        Physical idle time in ms (A_TimeIdlePhysical) — must clear the typing threshold.
; @returns True if the caller should Reload() now, false otherwise.
_ShouldReloadForHkl(curHkl, &lastHkl, &pendingHkl, suspended, isBlacklisted, hseSuppressed, pwSuppressed, idleMs, inputTransactionActive := false) {
	; A paused driver or a blacklisted app must never auto-reload.
	if suspended
		return false
	if isBlacklisted
		return false
	; Adopt the first observed real layout as the baseline. lastHkl == 0 means the
	; baseline is UNKNOWN, NOT that we booted on layout 0: the boot probe seeds it
	; with the layout it decided the AltGr family on, through a cascade that falls
	; back from the foreground window to the AHK thread's own layout, so 0 means
	; no layout could be read at all (logged as an AltGrDetect error). The first
	; non-zero layout we see is then the baseline, never a switch to reload for —
	; otherwise the driver spuriously Reload()s a few seconds after boot.
	if (lastHkl == 0 && curHkl != 0) {
		lastHkl := curHkl
		pendingHkl := 0
		return false
	}
	; No change from the last reloaded layout — clear any stale pending candidate and bail
	if (curHkl == lastHkl) {
		pendingHkl := 0
		return false
	}
	; Layout momentarily unreadable — preserve any pending candidate for the next poll
	if (curHkl == 0)
		return false
	; First sighting of a changed layout — record it and wait for a confirming poll.
	if (pendingHkl != curHkl) {
		pendingHkl := curHkl
		return false
	}
	; Confirmed across two polls — require full quiescence before disrupting typing.
	if (idleMs < 400)
		return false
	if (hseSuppressed > 0)
		return false
	if (pwSuppressed > 0)
		return false
	if inputTransactionActive
		return false
	lastHkl := curHkl
	return true
}





; =================================================
; =================================================
; ======= 2/ Reload through the hand-off ==========
; =================================================
; =================================================

; Automatic reload attempts for one stay on a foreground layout. Each refused
; attempt launches and stops a whole successor, and one an OnExit gate refuses
; spends one of the process's LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS vetoes, so a
; refusal that persists (a malformed trigger WAL keeps every reload strict) must
; not be retried for ever: after this many the poll gives up on that layout.
global LAYOUT_POLL_RELOAD_MAX_ATTEMPTS := 3
; Wait after the first refused attempt before the next; each refusal doubles it.
global LAYOUT_POLL_RELOAD_RETRY_BASE_MS := 5000
; The retry state of the foreground layout: its "hkl", the "attempts" started
; for it, the tick count of the last refusal ("refused_at") and the wait after
; it ("wait_ms"), and whether the poll "gave_up" on it. A new one starts when
; the layout changes.
global _LayoutPollRetry := _LayoutPollNewRetry(0)

; One tick of the layout poll: decides whether a confirmed, quiet layout switch
; warrants a reload and starts it through the terminal hand-off. The arguments
; after Hkl are _ShouldReloadForHkl's; the tracking refs are the entry file's
; _LAST_KEYBOARD_HKL and _PENDING_KEYBOARD_HKL.
; @param Port {Map} The lifecycle seams: "needs_reload"(Hkl) says whether the
;   boot registrations do not fit layout Hkl (LayoutRemapNeedsReload);
;   "reload"(RefusedFn) starts the poll's own reload and returns whether it
;   launched; "pending"() returns the pending reload record or false;
;   "veto_honored"() says whether OnExit could still refuse one more exit;
;   "now"() returns the tick count; "notify"() tells the user a reload failed.
; @returns {Boolean} True when this tick started a reload.
LayoutPollTick(Hkl, Suspended, IsBlacklisted, HseSuppressed, PwSuppressed, IdleMs,
		InputBusy, Port) {
	global _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL
	_LayoutPollObserve(Hkl)
	; A layout the boot registrations already fit becomes the baseline at once:
	; the AltGr family follows it without a reload, and nothing else would
	; change. An unknown baseline (0) is still adopted by _ShouldReloadForHkl.
	if (Hkl != 0 && _LAST_KEYBOARD_HKL != 0 && Hkl != _LAST_KEYBOARD_HKL
			&& !Port["needs_reload"].Call(Hkl)) {
		_LAST_KEYBOARD_HKL := Hkl
		_PENDING_KEYBOARD_HKL := 0
		return false
	}
	PreviousHkl := _LAST_KEYBOARD_HKL
	if !_ShouldReloadForHkl(Hkl, &_LAST_KEYBOARD_HKL, &_PENDING_KEYBOARD_HKL,
			Suspended, IsBlacklisted, HseSuppressed, PwSuppressed, IdleMs, InputBusy)
		return false
	return _LayoutPollReload(Hkl, PreviousHkl, Port)
}

; Reports a reload stage that refused before any successor launched, for the
; poll's reload only. The default reporter shows a "save failed" notice that
; means nothing to a user who only switched layouts, and would repeat on every
; retry; the poll tells the user once, when it gives up.
LayoutPollStageRefused(Stage, Path) {
	try LoggerWarn("ErgoptiPlus", "Layout reload stage '{1}' refused for '{2}'.", Stage, Path)
}

; Starts a new retry state when the foreground layout is no longer the one being
; retried: switching away and back is a new request with a fresh attempt budget.
_LayoutPollObserve(Hkl) {
	global _LayoutPollRetry
	if (Hkl != 0 && Hkl != _LayoutPollRetry["hkl"])
		_LayoutPollRetry := _LayoutPollNewRetry(Hkl)
}

_LayoutPollNewRetry(Hkl) {
	return Map("hkl", Hkl, "attempts", 0, "refused_at", 0, "wait_ms", 0, "gave_up", false)
}

; Reloads for a confirmed layout switch through the terminal hand-off, like
; every other reload: a bare Reload left a successor whose close request was
; refused on "Could not close the previous instance", and one fired while a
; hand-off reload was pending let that successor claim the pending record, so
; two drivers started. _ShouldReloadForHkl has advanced the tracker to Hkl;
; every path that leaves no reload of the poll's own under way puts it back, so
; a later quiet poll decides again.
_LayoutPollReload(Hkl, PreviousHkl, Port) {
	global _LayoutPollRetry, LAYOUT_POLL_RELOAD_MAX_ATTEMPTS
	Retry := _LayoutPollRetry
	; A reload someone else launched restarts on whatever layout its successor
	; boots on. Joining it would count as this switch's reload, and nothing would
	; tell the poll if it were refused: wait for it to end either way.
	if (Port["pending"].Call() is Map)
		return _LayoutPollRestore(PreviousHkl)
	if Retry["gave_up"]
		return _LayoutPollRestore(PreviousHkl)
	; Capture the refused attempt before the clock port can dispatch a callback.
	RefusedAt := Retry["refused_at"]
	WaitMs := Retry["wait_ms"]
	if TickElapsed64(RefusedAt, Port["now"].Call()) < WaitMs
		return _LayoutPollRestore(PreviousHkl)
	; Past the last honored veto, OnExit lets the exit through whatever gate
	; refuses it. A user's quit may cross it; an automatic reload never does.
	if !Port["veto_honored"].Call()
		return _LayoutPollGiveUp(Retry, PreviousHkl, Port,
			"one more refusal would exhaust the shutdown veto budget")
	Retry["attempts"] += 1
	; The one reload nobody clicks: without this line a layout switch looked like
	; a spontaneous restart in the log.
	try LoggerInfo("ErgoptiPlus", "Keyboard layout changed to HKL 0x{1:X}, which types the magic key's source character on another key; reloading to register it again (attempt {2}/{3}).",
		Hkl, Retry["attempts"], LAYOUT_POLL_RELOAD_MAX_ATTEMPTS)
	Refused := _LayoutPollRefused.Bind(Retry, PreviousHkl, Port)
	if Port["reload"].Call(Refused)
		return true
	Refused.Call("the reload could not start")
	return false
}

; A refused layout reload did not happen, so the driver still runs on the probe
; of PreviousHkl: restore the tracker, then wait twice as long as after the
; previous refusal, or give up once the attempts are spent. A refusal that
; lands after the user left that layout only restores the tracker.
_LayoutPollRefused(Retry, PreviousHkl, Port, Reason) {
	global _LayoutPollRetry, LAYOUT_POLL_RELOAD_MAX_ATTEMPTS
	global LAYOUT_POLL_RELOAD_RETRY_BASE_MS
	_LayoutPollRestore(PreviousHkl)
	if (Retry != _LayoutPollRetry) {
		try LoggerWarn("ErgoptiPlus", "Reload for keyboard layout HKL 0x{1:X} refused ({2}) after the layout changed again.",
			Retry["hkl"], Reason)
		return
	}
	if (Retry["attempts"] >= LAYOUT_POLL_RELOAD_MAX_ATTEMPTS)
		return _LayoutPollGiveUp(Retry, PreviousHkl, Port, Format(
			"{1} attempts were refused, the last because {2}", Retry["attempts"], Reason))
	Retry["refused_at"] := Port["now"].Call()
	Retry["wait_ms"] := LAYOUT_POLL_RELOAD_RETRY_BASE_MS * (2 ** (Retry["attempts"] - 1))
	try LoggerWarn("ErgoptiPlus", "Reload for keyboard layout HKL 0x{1:X} refused ({2}); retrying in {3} ms.",
		Retry["hkl"], Reason, Retry["wait_ms"])
}

; Stops retrying Retry's layout until the foreground layout changes. The driver
; keeps the previous layout's probe, so the user is told once.
_LayoutPollGiveUp(Retry, PreviousHkl, Port, Reason) {
	_LayoutPollRestore(PreviousHkl)
	Retry["gave_up"] := true
	try LoggerError("ErgoptiPlus", "Reload for keyboard layout HKL 0x{1:X} abandoned: {2}. The driver keeps the previous layout until the layout changes again or a manual reload.",
		Retry["hkl"], Reason)
	Port["notify"].Call()
	return false
}

; Puts the tracker back on the layout the driver probed, so the next confirmed
; quiet poll decides again.
_LayoutPollRestore(PreviousHkl) {
	global _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL
	_LAST_KEYBOARD_HKL := PreviousHkl
	_PENDING_KEYBOARD_HKL := 0
	return false
}





; ===============================================
; ===============================================
; ======= 3/ What a layout switch reloads =======
; ===============================================
; ===============================================

; What the boot registrations read from keyboard layout Hkl, as one comparable
; string: while the Ergopti emulation is off, the key the magic-key scan finds
; for the magic key's source character (ErgoptiPlus.ahk), or the default one
; when it finds none. That key's hotkeys are registered at load on that scan
; code, so a switch that moves it still reloads. The AltGr family, the
; digit-row swap and the accented-letter shortcuts follow the foreground layout
; live instead.
; @param Hkl {Integer} Keyboard layout handle; 0 (none read) probes nothing.
; @param Port {Map} Test seam, _LayoutRemapPort() by default: "emulated"(),
;        "magic_char"() and "magic_scan"(Hkl, Char), 0 when not found.
; @returns {String}
LayoutRemapSignature(Hkl, Port := 0) {
	if !(Port is Map)
		Port := _LayoutRemapPort()
	if Port["emulated"].Call()
		return "magic=emulated"
	Scan := (Hkl != 0) ? Port["magic_scan"].Call(Hkl, Port["magic_char"].Call()) : 0
	return "magic=" . (Scan ? Format("SC{:03X}", Scan) : "default")
}

; Whether a switch to layout Hkl needs a reload: the boot registrations were
; built for _LAYOUT_REMAP_HKL and do not fit Hkl.
; @param Hkl {Integer} The foreground layout.
; @param Port {Map} As for LayoutRemapSignature.
; @returns {Boolean}
LayoutRemapNeedsReload(Hkl, Port := 0) {
	global _LAYOUT_REMAP_HKL
	if !(Port is Map) && MagicEditorNeedsLayoutReload(Hkl)
		return true
	return LayoutRemapSignature(Hkl, Port) != LayoutRemapSignature(_LAYOUT_REMAP_HKL, Port)
}

_LayoutRemapPort() {
	static Port := Map(
		"emulated", _LayoutRemapEmulated,
		"magic_char", _LayoutRemapMagicChar,
		"magic_scan", _LayoutRemapMagicScan)
	return Port
}

; Whether no boot registration follows the OS layout: the Ergopti emulation
; types every key itself, and a magic key the user chose, the active layout
; declared or an emulated layout fixed never moves with the OS layout.
_LayoutRemapEmulated() {
	global Features, ScriptInformation
	return Features["layout"]["ergopti_base"] || !ScriptInformation["MagicKeySourceFollowsOsLayout"]
}

_LayoutRemapMagicChar() {
	global ScriptInformation
	return ScriptInformation["MagicKeySourceChar"]
}

_LayoutRemapMagicScan(Hkl, Char) {
	return KS_ScanScancodeForChar(Hkl, Char)["scan"]
}
