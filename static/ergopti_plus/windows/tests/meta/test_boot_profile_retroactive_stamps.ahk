; tests/meta/test_boot_profile_retroactive_stamps.ahk

; ==============================================================================
; MODULE: Retroactive Boot Stamp Meta Test
; DESCRIPTION:
; BootProfile_Mark cannot be used before LoggerInit, and LoggerInit runs late:
; the bundle extraction, the whole #Include graph's top-level initialisers, the
; TOML config parse and HotstringEngineInit all happen first. Every one of them
; therefore arrived at BootProfile_Begin folded into a single opaque number —
; "Script parse + load (pre-boot): ~N ms" — so a user reporting a slow start
; could be told how much of it was pre-boot and nothing more.
;
; BootProfile_Stamp records a tick without logging, and BootProfile_Begin
; replays the stamps as ordinary lines once the logger exists.
;
; ROOT CAUSE ENCODED — the trap that makes this non-obvious:
; the stamp buffer must be a function STATIC, never a file-level global. AHK
; initialises function statics before the auto-execute thread starts, but a
; top-level ``global X := []`` is an ordinary statement executed at that file's
; #Include position. The earliest stamp is taken far above that position, so a
; global would be unset when it is pushed and — worse — would be reset to an
; empty array when the include position was finally reached, silently discarding
; every stamp taken before it. The failure is invisible: boot succeeds, the
; replayed lines are simply missing, and the profiler looks like it was never
; wired up rather than like it lost its data.
;
; SCOPE: source introspection. lib/boot_profiler.ahk is not loaded by the
; headless runner (it has no test-visible entry point and its only observable
; effect is log output), so the invariants are asserted against its source.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Stamps survive the include point =======
; ===================================================
; ===================================================

_BPS_StampsUseAStaticBuffer() {
	Store := _DriverFuncBody("_BootProfileStampStore")
	Assert(Store != "", "_BootProfileStampStore() must exist in the driver source")
	Assert(RegExMatch(Store, "static\s+Stamps\s*:=") > 0,
		"the retroactive stamp buffer must be a function static. A file-level global is assigned at its own #Include position, which is BELOW the first stamp: the buffer would be unset when the first stamp is pushed and then reset to empty when the include point is reached, silently discarding every stamp taken before it")

	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "m)^global\s+_BOOT_PROFILE_STAMP") == 0,
		"the stamp buffer and its cap must not be file-level globals — see _BootProfileStampStore. A top-level global initialiser runs at this file's include position and would wipe the stamps taken above it")

	Stamp := _DriverFuncBody("BootProfile_Stamp")
	Assert(Stamp != "", "BootProfile_Stamp() must exist in the driver source")
	Assert(InStr(Stamp, "Logger") == 0,
		"BootProfile_Stamp must not log: it is called before LoggerInit has resolved the log path, which is the entire reason the stamps are replayed later rather than emitted where they are taken")
}





; =================================================
; =================================================
; ======= 2/ Stamps are taken, and replayed =======
; =================================================
; =================================================

_BPS_StampsAreReplayed() {
	Begin := _DriverFuncBody("BootProfile_Begin")
	Assert(Begin != "", "BootProfile_Begin() must exist in the driver source")
	Assert(InStr(Begin, "_BootProfileReplayStamps(") > 0,
		"BootProfile_Begin must replay the retroactive stamps — a stamp that is recorded and never emitted is dead weight on the boot path")

	Replay := _DriverFuncBody("_BootProfileReplayStamps")
	Assert(Replay != "", "_BootProfileReplayStamps() must exist in the driver source")
	Assert(InStr(Replay, "drain") > 0,
		"the replay must DRAIN the buffer, so a second BootProfile_Begin (the driver reloads itself on layout change) cannot re-emit the previous run's stamps as if they were this one's")
	Assert(InStr(Replay, "_BOOT_PROFILE_START") == 0 and InStr(Replay, "_BOOT_PROFILE_LAST") == 0,
		"the replay must not move the mark origin. Every existing phase line measures from BootProfile_Begin, and re-anchoring them on process creation would silently shift every number in the log, making new boots incomparable with the ones already collected")
}

_BPS_ThePreLoggerWindowIsCovered() {
	Src := _DriverSourceNoComments()
	Sites := 0
	Pos := 1
	while (Pos := InStr(Src, "BootProfile_Stamp(", , Pos)) {
		Sites += 1
		Pos += 1
	}
	; One occurrence is the definition itself; the rest are real stamp sites on
	; the boot path.
	Assert(Sites - 1 >= 5,
		"the pre-logger boot window must be broken into at least five stamped phases (found " . (Sites - 1) . "). Fewer than that and the replay reproduces the same opaque number it exists to decompose")
}


Test("meta boot-stamps: the retroactive stamp buffer survives its own include position",
	_BPS_StampsUseAStaticBuffer)
Test("meta boot-stamps: recorded stamps are drained and replayed without moving the mark origin",
	_BPS_StampsAreReplayed)
Test("meta boot-stamps: the pre-logger boot window is broken into phases",
	_BPS_ThePreLoggerWindowIsCovered)
