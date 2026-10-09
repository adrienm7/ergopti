; infra/timings/timings_config.ahk

; ==============================================================================
; MODULE: Timings Config
; DESCRIPTION:
; Fail-fast reader over the cross-driver timing registry at
; _shared/modules/timings/constants.toml — the single authoritative source for every
; tunable timing in the project (debounces, timeouts, poll intervals, …) that
; even names the AHK + HS constant each value used to duplicate. This module
; exposes those values to the AutoHotkey driver so per-module literals can be
; deleted and the two drivers stay in lock-step (mirrors the macOS infra/timings.lua).
;
; FEATURES & RATIONALE:
; 1. Single source of truth shared with HS — the registry file is read verbatim
;    by both drivers; no driver-side fallback values (rules 5.2 / 5.4).
; 2. Fail fast — a missing file/key THROWS. In production the unhandled error
;    surfaces the fatal dialog and the script exits (rule 5.3); in the headless
;    test runner run_all.ahk's OnError handler turns it into a "not ok 0" line
;    instead of hanging on a modal.
; 3. Reassign-at-boot wiring — AHK v2 runs global/static initializers BEFORE the
;    auto-execute body, so a consumer cannot call TimingsGet() from its own
;    initializer (the registry is not loaded yet). Instead each consumer declares
;    a sentinel and a small loader function reassigns it from the registry; those
;    loaders run from the auto-execute body, after TimingsLoadShared() and before
;    the consuming module arms its hooks/hotkeys.
; ==============================================================================

#Requires AutoHotkey v2.0

; Populated by TimingsLoadShared() at boot. Empty string until then so any read
; before the load fails fast rather than returning a silent default.
global _TimingsCache := ""




; ============================================================
; ============================================================
; ======= 1/ Registry load + accessors ======================
; ============================================================
; ============================================================

; Load the shared timing registry (_shared/modules/timings/constants.toml) into the
; module cache. Must run once at boot BEFORE any consumer reassigns its
; constants from it. A missing/empty file THROWS (fail fast — no fallback).
; @param SharedDir Optional _shared/ root; defaults to the global ``_SharedDir``.
TimingsLoadShared(SharedDir := "") {
		global _SharedDir, _TimingsCache
		Dir  := (SharedDir != "") ? SharedDir : (IsSet(_SharedDir) ? _SharedDir : "")
		Path := Dir . "\modules\timings\constants.toml"
		c    := ParseTomlFile(Path)
		if !c.Count {
				throw Error("_shared/modules/timings/constants.toml introuvable ou vide : " . Path)
		}
		_TimingsCache := c
		try LoggerInfo("Timings", "Shared timings registry loaded ({1} section(s)).", c.Count)
}

; Fetch a required ``[Section] Key`` timing (an integer number of milliseconds)
; from the loaded registry. Throws when the registry is not loaded or the key is
; absent so a typo / truncated registry aborts loudly instead of returning "".
; @param Section TOML section name (e.g. "keylogger").
; @param Key Key within that section (e.g. "think_pause_ms").
; @return Integer The value in milliseconds.
TimingsGet(Section, Key) {
		global _TimingsCache
		if (Type(_TimingsCache) != "Map") {
				throw Error(Format("TimingsGet('{1}','{2}') called before TimingsLoadShared() — registry not loaded.", Section, Key))
		}
		Val := IniCacheGet(_TimingsCache, Section, Key)
		if (Val == "_") {
				throw Error(Format("_shared/modules/timings/constants.toml — clé manquante : [{1}] {2}", Section, Key))
		}
		return Integer(Val)
}

; Same lookup as TimingsGet but converted to seconds, for the APIs that take a
; seconds argument (e.g. an InputHook timeout).
; @param Section TOML section name.
; @param Key Key within that section.
; @return Float The value in seconds.
TimingsGetSec(Section, Key) {
		return TimingsGet(Section, Key) / 1000.0
}
