; modules/keylogger/keylogger_hotstring_log.ahk

; ==============================================================================
; MODULE: Keylogger — Fired-Hotstring Record
; DESCRIPTION:
; The single sink for a hotstring that actually fired: it flushes the typing
; buffer, appends one ``hotstring`` row to today.log, feeds the ROI accumulator
; and pushes one WPM sample per replacement character.
;
; WHY IT IS ITS OWN FILE:
; This row is the one place in the driver where a personal-info expansion could
; be written out verbatim, and it writes the replacement TWICE — once as a
; field, once inside the ``tag`` marker. That contract needs a regression test
; that inspects the row itself, and the rest of modules/keylogger/keylogger.ahk
; installs OS hooks at load, so the headless suite cannot include it. Splitting
; the record out is what lets tests/unit/test_hotstring_fire_log_privacy.ahk
; drive the real function against a recording KL_AppendLog instead of asserting
; on a copy of it.
;
; FEATURES & RATIONALE:
; 1. Privacy without losing the metric. A private mapping is redacted, never
;    dropped: the WPM widget and the ROI counter need LENGTHS, not text, so the
;    arithmetic is computed from the real strings and only what is PERSISTED is
;    replaced. Skipping the call outright would trade a privacy bug for a
;    metrics bug — macOS forwards its is_private flag for the same reason.
; 2. Both columns are withheld, not just the replacement. The trigger of a
;    personal mapping is a fragment of the same secret, and "@iban★" tells a
;    reader which secret followed it.
; 3. Mirrors hammerspoon/modules/keylogger/init.lua (M.log_hotstring)
;    byte-for-byte for the non-private case: buffer flushed FIRST so the fire is
;    ordered after the trigger characters that produced it, ``net_saved_chars``
;    auto-computed from StrLen (HS uses utf8.len), the session app as the
;    fallback, and the same ``tag`` marker.
; ==============================================================================

#Requires Autohotkey v2.0+





; =========================================
; =========================================
; ======= 1/ Fired-hotstring record =======
; =========================================
; =========================================

/**
 * Logs a hotstring expansion event.
 *
 * ``is_private`` is set by the fire path from the matched Spec (see
 * _MakeHotstringMeta). When it is true the persisted row keeps the SHAPE of the
 * expansion — same field count, same string lengths, so net_saved_chars and the
 * WPM pushes are unchanged — and none of its content. today.log is ingested
 * into the metrics store, replicated to every other device and kept for
 * fourteen days, which is why "it is only a local scratch file" was never a
 * reason to write an IBAN into it.
 *
 * @param {String} trigger - The abbreviation that fired.
 * @param {String} replacement - The resolved expansion.
 * @param {String} h_type - Category tag ("star", "endchar", or the TOML group).
 * @param {String} app_name - Overrides the session app when non-empty.
 * @param {String} category - TOML category, for the WPM widget's colouring.
 * @param {String} section - TOML section, for the WPM widget's colouring.
 * @param {Boolean} is_private - True when trigger and replacement are the
 *     user's own personal data.
 */
KL_LogHotstring(trigger, replacement, h_type := "unknown", app_name := "", category := "", section := "", is_private := false) {
	; The diagnostic line reaches the same rotating log as the row below, and
	; DEBUG is the level a user is asked to switch on when reporting a bug — so
	; a private trigger is withheld here exactly as it is withheld from the row.
	if is_private {
		LoggerDebug("WPMWidget", "KL_LogHotstring: private mapping cat='{1}' sec='{2}' init={3} (trigger withheld).", category, section, Keylogger.initialized)
	} else {
		LoggerDebug("WPMWidget", "KL_LogHotstring: trigger='{1}' cat='{2}' sec='{3}' init={4}", trigger, category, section, Keylogger.initialized)
	}
	if !Keylogger.initialized
		return
	KL_FlushBuffer()
	app := (app_name != "") ? app_name : Keylogger.session_app
	; Measured on the REAL strings, before any redaction: this is the number the
	; ROI counter accumulates and it must not change because the mapping is
	; private. PersonalInfoRedactForLog preserves StrLen, so the row stays
	; internally consistent with it either way.
	net_saved := StrLen(replacement) - StrLen(trigger)
	logged_trigger := is_private ? PersonalInfoRedactForLog(trigger) : trigger
	logged_replacement := is_private ? PersonalInfoRedactForLog(replacement) : replacement
	KL_AppendLog(Map(
		"type",            "hotstring",
		"app",             app,
		"trigger",         logged_trigger,
		"replacement",     logged_replacement,
		"h_type",          h_type,
		"net_saved_chars", net_saved,
		; The SECOND place the replacement is written. A fix that redacts the
		; field above and forgets this marker leaves the value in the log in
		; full, one column to the right.
		"tag",             "<hotstring>" . logged_replacement . "</hotstring>"
	))
	Keylogger.last_flush_time := A_TickCount
	; The ROI accumulator gets the REDACTED trigger and is told why. It does not
	; "only need net_saved": KL_Roi_OnHotstring stores the trigger as a key of
	; trigger_last_use and KL_Roi_HalflifeTick writes that key back out into a
	; trigger_halflife row — so handing it the redaction alone would collapse
	; every private trigger of the same length onto one key (@cb★, @cc★ and @ss★
	; are all four bullets), and one of them being used today would keep the other
	; two looking fresh forever. The flag makes it skip the half-life map instead,
	; which is the honest answer: the savings still accumulate, and "this trigger
	; is stale, consider pruning it" was never advice anyone would take about
	; their own IBAN.
	try KL_Roi_OnHotstring(logged_trigger, net_saved, is_private)
	; Feed the real-time WPM widget — pass the TOML category so the widget
	; can resolve the correct color and skip coloring for neutral groups.
	; Counted from the real replacement: the widget measures keystrokes saved,
	; and a private expansion saved exactly as many as a public one.
	repl_len := StrLen(replacement)
	Loop repl_len
		try WPMWidget_Push(true, false, false, category, section)
}
