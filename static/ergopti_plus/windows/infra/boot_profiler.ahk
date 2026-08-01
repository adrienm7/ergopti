; infra/boot_profiler.ahk

; ==============================================================================
; MODULE: Boot Profiler
; DESCRIPTION:
; Lightweight A_TickCount-based phase timing for startup diagnosis. The driver
; loads ~228 source files, registers thousands of hotstrings and builds a large
; tray menu at boot; when a user reports a slow start there was previously no
; way to see WHICH phase dominated. BootProfile_Mark emits one INFO line per
; phase with the delta since the previous mark and the running total, so the
; log alone tells you where boot time goes — no profiler attach, no rebuild.
;
; FEATURES & RATIONALE:
; 1. Zero behavioural impact: pure timing reads plus one INFO log per phase.
; 2. Fail-safe: every log call is wrapped so a profiler glitch can never abort
;    or delay boot — if the logger is not ready yet the mark is simply silent.
; ==============================================================================

global _BOOT_PROFILE_LAST  := 0  ; A_TickCount captured at the previous mark
global _BOOT_PROFILE_START  := 0  ; A_TickCount captured at BootProfile_Begin




; ============================================
; ============================================
; ======= 1/ Boot phase profiler API =========
; ============================================
; ============================================

; Start (or restart) the boot timer. Call once, as early as the logger is
; ready, so subsequent marks measure deltas from a known origin.
BootProfile_Begin() {
	global _BOOT_PROFILE_LAST, _BOOT_PROFILE_START
	_BOOT_PROFILE_START := A_TickCount
	_BOOT_PROFILE_LAST  := _BOOT_PROFILE_START
	try LoggerInfo("BootProfile", "Boot timing started.")
	; Everything BEFORE this line is invisible to the A_TickCount marks below:
	; AHK tokenises every #Include'd file (~228 sources incl. UIA/WebView2/sqlite3)
	; and creates the tray icon BEFORE the first auto-execute line runs. If the user
	; reports "the tray icon takes 1-2s to even appear", the cost is almost always
	; HERE, not in any logged phase — so surface it explicitly as the very first mark.
	try {
		Uptime := BootProfile_ProcessUptimeMs()
		if (Uptime >= 0)
			LoggerInfo("BootProfile",
				"Script parse + load (pre-boot, until tray icon appears): ~{1} ms.", Uptime)
		_BootProfileReplayStamps((Uptime >= 0) ? (_BOOT_PROFILE_START - Uptime) : 0)
	}
}

; Record a phase boundary that happens BEFORE the logger is usable.
;
; Everything up to LoggerInit() — bundle extraction, the whole #Include graph's
; top-level code, the config parse, HotstringEngineInit — used to arrive at
; BootProfile_Begin as a single opaque "script parse + load: ~N ms" number, so a
; user reporting a slow start could be told how much was pre-boot but never
; which part of it. A stamp is two integer writes and no logging, which is the
; only thing that is safe this early; BootProfile_Begin replays them all as
; normal marks once the logger exists.
; @param PhaseName {String} Human-readable label for the phase that just ended.
BootProfile_Stamp(PhaseName) {
	_BootProfileStampStore("push", PhaseName)
}

; Storage for the retroactive stamps.
;
; The buffer and its cap are function statics, NOT file-level globals, and that
; is load-bearing rather than a style choice: a top-level ``global X := []`` is
; an ordinary statement executed at this file's #Include position, whereas the
; earliest stamp is taken in the pre-pump block far above it. A global would
; therefore be unset when the first stamp is pushed and — worse — would be reset
; to an empty array when this file's include position was finally reached,
; silently discarding every stamp taken before it. Function statics are
; initialised before the auto-execute thread starts, so they are valid from the
; very first executable line. Verified against AutoHotkey64 v2 before use.
; @param Op {String} "push" to record, "drain" to take and clear.
; @param PhaseName {String} Label, for "push".
; @returns {Array} For "drain", the recorded stamps; an empty array otherwise.
_BootProfileStampStore(Op, PhaseName := "") {
	; Upper bound on retroactive stamps. The pre-logger window has a handful of
	; meaningful boundaries; a caller wanting more is measuring the wrong thing,
	; and the cap keeps a runaway loop from growing this array unbounded.
	static CAP := 12
	static Stamps := []
	if (Op == "push") {
		if (Stamps.Length < CAP)
			Stamps.Push({ Name: PhaseName, Tick: A_TickCount })
		return []
	}
	Drained := Stamps
	Stamps := []
	return Drained
}

; Emit one line per retroactive stamp, then clear them.
;
; Deliberately does NOT touch _BOOT_PROFILE_START / _BOOT_PROFILE_LAST: the marks
; that follow keep measuring from BootProfile_Begin exactly as before, so the
; existing phase lines stay comparable with logs collected before this existed.
; The replayed lines carry their own "since process start" total instead.
; @param ProcessStartTick {Integer} A_TickCount at process creation, 0 if unknown.
_BootProfileReplayStamps(ProcessStartTick) {
	Stamps := _BootProfileStampStore("drain")
	if (Stamps.Length == 0)
		return
	; Anchor on the first stamp when the process creation time is unavailable —
	; the deltas between stamps stay correct, only the absolute total is lost.
	Origin := (ProcessStartTick > 0) ? ProcessStartTick : Stamps[1].Tick
	Prev := Origin
	for , Stamp in Stamps {
		try LoggerInfo("BootProfile", "(pre-logger) {1}: +{2} ms (at {3} ms since process start).",
			Stamp.Name, Stamp.Tick - Prev, Stamp.Tick - Origin)
		Prev := Stamp.Tick
	}
}

; Log the time since the previous mark and since BootProfile_Begin.
; @param PhaseName {String} Human-readable label for the phase that just ended.
BootProfile_Mark(PhaseName) {
	global _BOOT_PROFILE_LAST, _BOOT_PROFILE_START
	Now := A_TickCount
	; Tolerate a mark that fires before Begin — anchor the origin on first use
	; so the profiler never logs a nonsensical negative or huge total.
	if (_BOOT_PROFILE_START == 0) {
		_BOOT_PROFILE_START := Now
		_BOOT_PROFILE_LAST  := Now
	}
	Delta := Now - _BOOT_PROFILE_LAST
	Total := Now - _BOOT_PROFILE_START
	_BOOT_PROFILE_LAST := Now
	try LoggerInfo("BootProfile", "{1}: +{2} ms (total {3} ms).", PhaseName, Delta, Total)
}

; Milliseconds elapsed since the OS spawned this process, measured against the
; process creation FILETIME from GetProcessTimes. Unlike A_TickCount (which we can
; only read once our own code runs), this captures the entire pre-script window —
; AHK parsing every #Include and creating the tray icon — that precedes the first
; executable line. A large value here pinpoints the parse phase as the slow start.
; @returns {Integer} Elapsed milliseconds since process creation, or -1 on failure.
BootProfile_ProcessUptimeMs() {
	static FILETIME_TICKS_PER_MS := 10000  ; FILETIME is in 100-ns ticks → 10000 per ms
	HProc    := DllCall("GetCurrentProcess", "Ptr")
	Creation := Buffer(8, 0)
	ExitT    := Buffer(8, 0)
	KernelT  := Buffer(8, 0)
	UserT    := Buffer(8, 0)
	; GetProcessTimes returns each time as a FILETIME (UTC, 100-ns ticks since 1601),
	; directly comparable to GetSystemTimeAsFileTime — their difference is wall-clock.
	if !DllCall("GetProcessTimes", "Ptr", HProc,
		"Ptr", Creation, "Ptr", ExitT, "Ptr", KernelT, "Ptr", UserT)
		return -1
	NowFt := Buffer(8, 0)
	DllCall("GetSystemTimeAsFileTime", "Ptr", NowFt)
	Created := NumGet(Creation, 0, "Int64")
	Now     := NumGet(NowFt, 0, "Int64")
	return (Now - Created) // FILETIME_TICKS_PER_MS
}
