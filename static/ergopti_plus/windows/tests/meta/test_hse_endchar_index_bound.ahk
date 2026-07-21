; tests/meta/test_hse_endchar_index_bound.ahk
#Requires AutoHotkey v2.0

Test_HSE_EndCharMatchUsesBoundedFullTriggerIndex() {
	MatchBody := _DriverFuncBody("HSE_FindMatchAtEnd")
	Engine := _DriverDirConcat("lib/hotstrings")
	; _DriverFuncBody returns "" for an unknown name, which would make the
	; ABSENCE assertion below pass against a driver that no longer has this
	; function at all — a guard that cannot fail is worse than none.
	Assert(MatchBody != "", "HSE_FindMatchAtEnd() must exist in the driver source for this guard to mean anything")
	Assert(InStr(MatchBody, "HSE_EndByTriggerCI.Has") > 0 and InStr(MatchBody, "HSE_EndByTriggerCS.Has") > 0,
		"end-char matching must probe full-trigger maps")
	Assert(InStr(MatchBody, "Min(StrLen(EffBody), HSE_MaxEndTriggerLen)") > 0,
		"end-char probes must be bounded by maximum trigger length, not corpus size")
	; _HSE_BucketsFor was deleted, so asserting its ABSENCE could never fail
	; again — the guard outlived the thing it guarded. What actually matters is
	; the invariant that helper stood for: end-char matching must not WALK the
	; same-tail registry, which is the O(n)-per-keystroke shape the bounded
	; full-trigger index replaced.
	;
	; The check is on iteration, not on mention: the function still declares
	; HSE_RegistryByLastChar in its `global` line, so asserting the identifier is
	; absent would fail against correct code. Other functions in this file build
	; and prune that registry by index, which is legitimate — only walking a
	; bucket from the per-keystroke match path is the defect.
	Assert(RegExMatch(MatchBody, "for\s+[^\r\n]*\s+in\s+HSE_RegistryByLastChar") == 0,
		"end-char matching must not iterate a same-tail registry bucket — that is the unbounded per-keystroke scan the bounded full-trigger index exists to avoid")
	Assert(InStr(Engine, "global HSE_EndByTriggerCI := Map()") > 0
		and InStr(Engine, "_HSE_RebuildEndTriggerIndex()") > 0,
		"full-trigger end index must be owned and rebuilt across live group changes")
}
Test("HSE: end-char matching probes a bounded full-trigger index", Test_HSE_EndCharMatchUsesBoundedFullTriggerIndex)

; The trigger-body slice is the only buffer-SIZED work on the per-keystroke match
; path: SubStr(HSE_Buffer, 1, BufLen - 1) copies up to HSE_MAX_BUFFER_LEN chars.
; Only the END-CHAR block reads it, and that block runs on word terminators alone
; (~15-20 % of keystrokes), so computing it up front billed the whole buffer to
; every ordinary letter. Pin the ordering rather than the absence: the slice must
; sit AFTER the terminator guard, which is what makes the common keystroke O(1).
Test_HSE_BodySliceIsDeferredToTerminators() {
	MatchBody := _DriverFuncBody("HSE_FindMatchAtEnd")
	Assert(MatchBody != "", "HSE_FindMatchAtEnd() must exist in the driver source")
	GuardPos := InStr(MatchBody, "if IsTerminator {")
	SlicePos := InStr(MatchBody, "SubStr(HSE_Buffer, 1, BufLen - 1)")
	Assert(GuardPos > 0, "HSE_FindMatchAtEnd must gate the trigger-body slice behind a terminator check")
	Assert(SlicePos > 0, "HSE_FindMatchAtEnd must still derive the trigger-body slice for the end-char path")
	Assert(GuardPos < SlicePos,
		"the buffer-sized trigger-body slice must be derived INSIDE the terminator guard — computing it up front copies the whole buffer on every non-terminator keystroke")
}
Test("HSE: the trigger-body slice is only derived on terminators (perf-2026-07-21)", Test_HSE_BodySliceIsDeferredToTerminators)
