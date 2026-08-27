; tests/unit/test_keylogger_event_id.ahk

; ==============================================================================
; MODULE: Keylogger Event-ID Recovery Tests
; DESCRIPTION:
; Exercises the production tail parser and monotonic resolver against stale
; state and multiple-device ledger fixtures.
;
; ROOT CAUSE ENCODED:
; A RegExMatch start position does not change the meaning of the subject-start
; anchor. Parsing must therefore operate on the tail substring, or a valid ID
; after the VALUES prefix is reported as zero and can be silently reissued.
; ==============================================================================

#Requires AutoHotkey v2.0+





; =======================================
; =======================================
; ======= 1/ Tail parser behavior =======
; =======================================
; =======================================

_KLEI_ReturnsLastIdForRequestedDevice() {
	sql := "INSERT INTO events_typing VALUES ('other', 91, 'a');`n"
		. "INSERT INTO events_typing VALUES ('device-a', 117, 'b');`n"
		. "INSERT INTO events_hotstring VALUES ('device-a', 203, 'c');`n"
		. "INSERT INTO events_typing VALUES ('other', 999, 'd');"

	AssertEqual(KL_ScanMaxEventId(sql, "'device-a'"), 203,
		"tail recovery must parse the final ID for the requested device")
}
Test("keylogger event id: parses the final device row (event-id-tail-anchor)",
	_KLEI_ReturnsLastIdForRequestedDevice)

_KLEI_ReturnsMaximumAcrossOutOfOrderRows() {
	sql := "INSERT INTO events_typing VALUES ('device-a', 117, 'a');`n"
		. "INSERT INTO events_typing VALUES ('device-a', 204, 'b');`n"
		. "INSERT INTO events_typing VALUES ('other', 999, 'c');`n"
		. "INSERT INTO events_hotstring VALUES ('device-a', 204, 'duplicate');`n"
		. "INSERT INTO events_typing VALUES ('device-a', 203, 'detached-flush');"

	AssertEqual(KL_ScanMaxEventId(sql, "'device-a'"), 204,
		"recovery must compute the maximum even when a detached flush appends an older id last")
	AssertEqual(KL_ResolveStartId(100, KL_ScanMaxEventId(sql, "'device-a'")), 205,
		"restart must advance beyond every durable id instead of colliding with 204")
}
Test("keylogger event id: out-of-order detached flush recovers maximum (event-id-recovery-max)",
	_KLEI_ReturnsMaximumAcrossOutOfOrderRows)

_KLEI_ReturnsZeroWhenDeviceIsAbsent() {
	sql := "INSERT INTO events_typing VALUES ('other', 91, 'a');"
	AssertEqual(KL_ScanMaxEventId(sql, "'missing'"), 0,
		"an absent device must retain the fresh-ledger zero sentinel")
}
Test("keylogger event id: absent device returns zero (event-id-tail-anchor)",
	_KLEI_ReturnsZeroWhenDeviceIsAbsent)





; ========================================
; ========================================
; ======= 2/ Monotonic start value =======
; ========================================
; ========================================

_KLEI_AdvancesStalePersistedState() {
	AssertEqual(KL_ResolveStartId(100, 203), 204,
		"stale state must advance beyond the highest durable identifier")
	AssertEqual(KL_ResolveStartId(300, 203), 300,
		"state already ahead of the ledger must remain authoritative")
}
Test("keylogger event id: stale state advances monotonically (event-id-tail-anchor)",
	_KLEI_AdvancesStalePersistedState)
