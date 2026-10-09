; tests/meta/test_hotpath_priority_starvation.ahk

; ==============================================================================
; MODULE: HotPath Priority-Starvation Meta Test
; DESCRIPTION:
; Regression guard for a performance finding discovered by correlating real
; production logs against a live-captured incident: the multi-second
; "Slow OnChar"/"Slow HSE.FeedChar"/"Slow Tooltip.*" HotPath warnings do not
; come from an algorithmic bug in this driver's own code (HSE_FindMatchAtEnd
; is already bounded — a handful of Map lookups per keystroke). Two separate
; pieces of evidence point at OS-level CPU scheduling contention instead:
;   1. In the historical log, several UNRELATED subsystems (hotstring matching
;      AND tooltip GUI rendering) degrade together over the same few-second
;      window with no other driver-internal event to explain it — the
;      signature of external contention, not a single function's bug.
;   2. A live-reproduced 190 ms Tooltip.Build slowdown coincided exactly with
;      another process on the machine spiking to 200-400%+ CPU (multiple
;      cores saturated); the AutoHotkey process itself was never observed at
;      high CPU in the same sampling window.
;
; At the OS's default Normal priority class, Windows can leave a keyboard-hook
; callback waiting behind other processes that are saturating the CPU — even
; though this driver's own per-keystroke work is sub-millisecond. The fix
; raises the driver's own process priority to AboveNormal at the very top of
; boot (before Bundle_Init's RunWait unzip, so that step is covered too),
; mirroring the same technique this codebase already uses for the Ollama
; installer (ollama_deps_checker.ahk boosts to High during a heavy download).
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================================================
; ======================================================================
; ======= 1/ Boot raises process priority before Bundle_Init's RunWait =
; ======================================================================
; ======================================================================

_THPS_CheckPriorityRaisedEarly() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	BootFile := WindowsDir . "\ErgoptiPlus.ahk"

	Body := ""
	try Body := FileRead(BootFile)
	Assert(Body != "", "ErgoptiPlus.ahk must be readable for the priority-starvation meta-test")

	; driver-baseline-priority-reverted-to-normal: the boost now goes through a
	; shared named constant instead of a standalone literal, so both the
	; declaration and the call site must be present.
	Assert(InStr(Body, 'global DRIVER_BASELINE_PRIORITY_CLASS := "AboveNormal"') > 0,
		'ErgoptiPlus.ahk must declare DRIVER_BASELINE_PRIORITY_CLASS := "AboveNormal" as the single source of '
		. 'truth for the driver baseline priority (driver-baseline-priority-reverted-to-normal)')

	PriorityPos := InStr(Body, "ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)")
	Assert(PriorityPos > 0,
		'ErgoptiPlus.ahk must call ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS) at boot so Windows schedules '
		. 'the keyboard-hook/hotstring-engine threads promptly even when another process saturates the CPU '
		. '(hotpath-priority-starvation)')

	; Must be try-wrapped: ProcessSetPriority can fail under restrictive OS
	; policy, and driver boot must never abort because of it (fail-safe, §5.3).
	Before := Trim(SubStr(Body, Max(1, PriorityPos - 10), PriorityPos - Max(1, PriorityPos - 10)))
	Assert(InStr(Before, "try") > 0,
		'The ProcessSetPriority("AboveNormal") call must be try-wrapped so a restrictive OS policy '
		. 'cannot abort driver boot (hotpath-priority-starvation)')

	BundleInitPos := InStr(Body, "Bundle_Init()")
	Assert(BundleInitPos > 0, "ErgoptiPlus.ahk must call Bundle_Init()")
	Assert(PriorityPos < BundleInitPos,
		'ProcessSetPriority("AboveNormal") must run BEFORE Bundle_Init() so the priority boost also '
		. "covers Bundle_Init's own RunWait-based unzip step (hotpath-priority-starvation)")
}
Test("meta boot: process priority raised to AboveNormal before Bundle_Init's RunWait (hotpath-priority-starvation)",
	_THPS_CheckPriorityRaisedEarly)
