; tests/unit/test_locale_probe_is_silent.ahk

; ==============================================================================
; MODULE: Locale Probe Silence Regression Test
; DESCRIPTION:
; Regression guard for i18n-probe-warns-about-itself.
;
; ROOT CAUSE ENCODED: one accessor served two callers with opposite contracts.
; t() resolves AND diagnoses — a total miss means the raw dotted key reaches the
; interface, which is a real defect worth a WARNING. But the menu-label resolver
; walks a chain of up to nine candidate keys and EXPECTS all but one to miss, and
; it called t() for each of them. Every menu label therefore emitted several
; warnings stating "the raw key is being displayed to the user" when it was not.
;
; Measured on 2026-07-29 before the fix: 282 unique keys warned per boot, of
; which 281 were probes and exactly ONE was a genuine user-visible miss. The
; errors-only sink — the file a maintainer opens when hunting a bug — was 99.7 %
; noise, and that is how the one real defect (a tray row rendering "i_e_acute")
; survived a full day inside its own alarm.
;
; The invariant: the speculative path must resolve through the SILENT accessor,
; and the display path must keep its warning. Both halves are asserted, because
; deleting the warning would also make this test pass while destroying the signal
; it exists to protect.
;
; SCOPE: behavioural — drives the real accessors and reads the logger ring, so a
; comment mentioning either function cannot satisfy it.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================================
; =============================================================
; ======= 1/ A probe miss is silent, a display miss is not ====
; =============================================================
; =============================================================

_LPS_Reset() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	global _I18nMissWarned
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := []
	_LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	; The miss warning is throttled to one line per key per process, so a key used
	; by an earlier test would make this one pass vacuously.
	_I18nMissWarned := Map()
	_LoggerRefreshFastFlags()
}

_LPS_RingText() {
	global LOGGER_RING_BUFFER
	Out := ""
	for _, Line in LOGGER_RING_BUFFER
		Out .= Line . "`n"
	return Out
}

; A key no locale can ever carry, unique per case so the once-per-key throttle
; cannot mask a second lookup.
_LPS_MissingKey(Suffix) {
	return "lps.definitely.absent." . Suffix
}

_LPS_ProbeMissIsSilent() {
	_LPS_Reset()
	Key := _LPS_MissingKey("probe")
	Value := I18nLookup(Key)

	Assert(Value == "",
		'I18nLookup must return an EMPTY STRING on a total miss, not the raw key. Returning the key would force '
		. 'every caller to re-derive "did this resolve?" by comparing against the key it passed in, which is the '
		. 'comparison the old probe loop had to make')
	Assert(InStr(_LPS_RingText(), Key) == 0,
		"a speculative lookup must emit NOTHING on a miss. Probing through the warning accessor made the menu-label "
		. "resolver report 281 false 'the raw key is being displayed to the user' alarms per boot and buried the one "
		. "genuine miss (i18n-probe-warns-about-itself)")
}

_LPS_DisplayMissStillWarns() {
	_LPS_Reset()
	Key := _LPS_MissingKey("display")
	Value := t(Key)

	Assert(Value == Key,
		"t() must still return the raw key on a total miss — throwing would take the tray menu down over a typo")
	Text := _LPS_RingText()
	Assert(InStr(Text, Key) > 0 and InStr(Text, "No translation for") > 0,
		"t() must STILL warn on a total miss. Silencing the display path would make this test pass while destroying "
		. "the only signal that a stale or mistyped key is reaching the interface — the fix moves the probe off this "
		. "accessor, it does not remove the diagnosis (i18n-probe-warns-about-itself)")
}

_LPS_ResolvedKeyIsSilentOnBothPaths() {
	; A key that DOES resolve must be quiet through either accessor, or the sink
	; fills up again from the other direction.
	_LPS_Reset()
	Hit := t("common.disabled")
	Assert(Hit != "" and Hit != "common.disabled",
		"prerequisite: common.disabled must resolve in the test locale, otherwise the assertions below are vacuous")
	Assert(InStr(_LPS_RingText(), "No translation for") == 0,
		"a key that resolves must never be reported as missing")

	_LPS_Reset()
	Assert(I18nLookup("common.disabled") == Hit,
		"both accessors must return the SAME value for a key that resolves — a second cascade would be a second "
		. "source of truth for what the interface says")
}




; ==============================================================
; ===== 1.1) The label resolver really uses the silent one =====
; ==============================================================

; The behavioural cases above prove the accessors behave; this proves the
; resolver is wired to the right one. Without it, a future edit could route the
; probe back through t() and every case above would still pass.
_LPS_ResolverUsesTheSilentAccessor() {
	Body := _DriverFuncBody("TryMenuLabelFromDescriptionKey")
	Assert(Body != "", "TryMenuLabelFromDescriptionKey() must exist in the driver source")
	Assert(InStr(Body, "I18nLookup(") > 0,
		"the candidate-probe loop must resolve through I18nLookup — it walks up to nine keys expecting all but one "
		. "to miss (i18n-probe-warns-about-itself)")
	Assert(RegExMatch(Body, "[^A-Za-z0-9_]t\(") == 0,
		"the candidate-probe loop must not call t() at all: t() reports a miss as a user-visible defect, and this "
		. "loop's misses are its normal control flow")
}


Test("locale: a speculative lookup miss emits nothing (i18n-probe-warns-about-itself)",
	_LPS_ProbeMissIsSilent)
Test("locale: a display-path miss still warns (i18n-probe-warns-about-itself)",
	_LPS_DisplayMissStillWarns)
Test("locale: a key that resolves is silent through both accessors (i18n-probe-warns-about-itself)",
	_LPS_ResolvedKeyIsSilentOnBothPaths)
Test("locale: the menu-label resolver probes through the silent accessor (i18n-probe-warns-about-itself)",
	_LPS_ResolverUsesTheSilentAccessor)
