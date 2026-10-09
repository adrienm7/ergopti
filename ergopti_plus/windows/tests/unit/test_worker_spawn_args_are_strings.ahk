; tests/unit/test_worker_spawn_args_are_strings.ahk

; ==============================================================================
; MODULE: Worker Spawn Argument Typing (keylogger-worker-timings-must-be-strings)
; DESCRIPTION:
; KLPF_RequestBuild and KLPF_RequestRange each built the metrics worker's
; argument vector from a literal that spliced KLWConst.MAX_KEYSTROKE_DELAY_MS and
; its five neighbours in directly. TimingsGet returns Integer(...), so those six
; elements were Integers, and ShellRunner_SpawnTreeOwned refuses any non-String
; argument before creating a process: "Argument 9 must be a string."
;
; The worker therefore never launched. The dashboard reported "Full metrics build
; exhausted retries" and the retry loop re-attempted the refused spawn about
; twelve times a second -- 6432 refusals in nine minutes of field logs on
; 2026-09-05 -- while every keystroke kept feeding the ingest that re-armed it.
;
; It stayed silent for sixteen days because the ONLY trigger is opening a metrics
; dashboard: nothing else reaches this spawn, so a driver that is never asked for
; typing metrics never refuses anything.
;
; ROOT CAUSE ENCODED: a command line has exactly one element type. One owner,
; KLPF_WorkerTimingArgs, converts the timings to decimal text for both request
; paths, and the spawn boundary's own validator proves the captured vectors are
; admissible. The guard loops BOTH request paths, because the defect was four
; duplicated literals and fixing three of them would look identical here.
; ==============================================================================

#Requires AutoHotkey v2.0

global _WSAS_Captured := []

_WSAS_CaptureStart(*) {
	return true
}

_WSAS_CaptureTerminate(*) {
	return true
}

_WSAS_CaptureSpawn(Executable, Args, Done) {
	global _WSAS_Captured
	_WSAS_Captured.Push(Map("executable", Executable, "args", Args))
	Handle := {}
	Handle.start := _WSAS_CaptureStart
	Handle.terminate := _WSAS_CaptureTerminate
	return Handle
}

_WSAS_RangeQuery(StartDate := "2026-08-01", EndDate := "2026-08-08") {
	return Map("start_date", StartDate, "end_date", EndDate,
		"apps", ["editor.exe"])
}





; ==============================================================
; ==============================================================
; ======= 1/ The timing vector crosses the wire as text  =======
; ==============================================================
; ==============================================================

; KLWConst holds Integers on purpose -- the walker compares them arithmetically.
; Only the spawn crossing needs text, and KLPF_WorkerMain reads them back with
; Integer(A_Args[n]), so the conversion must be exactly reversible.
_WSAS_TimingArgsAreReversibleDecimalStrings() {
	Args := KLPF_WorkerTimingArgs()
	AssertEqual(6, Args.Length,
		"KLPF_WorkerMain reads six timing arguments (A_Args[7]..A_Args[12]); the owner "
		. "must produce exactly that many (keylogger-worker-timings-must-be-strings)")

	Expected := [KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS,
		KLWConst.BURST_GAP_MS, KLWConst.SESSION_GAP_MS,
		KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS]
	for Index, Arg in Args {
		Assert(Type(Arg) = "String",
			"timing argument " . Index . " must be a String, not " . Type(Arg)
			. ": the spawn boundary refuses every other type before any process exists "
			. "(keylogger-worker-timings-must-be-strings)")
		AssertEqual(Expected[Index], Integer(Arg),
			"timing argument " . Index . " must round-trip through Integer() unchanged -- "
			. "KLPF_WorkerMain reconstitutes KLWConst from exactly these strings")
	}
}

Test("worker spawn: the timing arguments are reversible decimal strings (keylogger-worker-timings-must-be-strings)",
	_WSAS_TimingArgsAreReversibleDecimalStrings)





; =========================================================
; =========================================================
; ======= 2/ The boundary refuses a non-String argument ===
; =========================================================
; =========================================================

; This is the assertion that would have caught the original defect. It pins the
; refusal to the argument INDEX, because that index is the only diagnostic the
; field log carried and the only thing that located the bug.
_WSAS_TheSpawnBoundaryRefusesANonStringArgument() {
	Refused := ShellRunner_ValidateSpawnArgs("C:\bin\worker.exe", ["--flag", 1500])
	Assert(InStr(Refused["error"], "Argument 2") > 0,
		"an Integer argument must be refused by index; got '" . Refused["error"] . "' "
		. "(keylogger-worker-timings-must-be-strings)")

	Accepted := ShellRunner_ValidateSpawnArgs("C:\bin\worker.exe", ["--flag", "1500"])
	AssertEqual("", Accepted["error"],
		"the same value as decimal text must be admissible -- otherwise the fix would be "
		. "unreachable and this whole guard vacuous")
}

Test("worker spawn: the boundary refuses a non-String argument by index (keylogger-worker-timings-must-be-strings)",
	_WSAS_TheSpawnBoundaryRefusesANonStringArgument)





; ===============================================================
; ===============================================================
; ======= 3/ Every request path spawns admissible vectors =======
; ===============================================================
; ===============================================================

; The whole class, driven for real: both production request paths are run against
; a capturing spawn seam, and each captured vector is handed to the SAME
; validator the live spawn applies. A vector that the boundary would refuse fails
; here with the identical message the user saw in the log.
_WSAS_EveryRequestPathSpawnsAdmissibleVectors() {
	global _WSAS_Captured
	SavedSpawn := KLPFWorker.spawn_fn
	SavedJobs := KLPFWorker.jobs
	SavedGeneration := KLPFWorker.generation
	_WSAS_Captured := []
	try {
		KLPFWorker.spawn_fn := _WSAS_CaptureSpawn
		KLPFWorker.jobs := Map()
		KLPFWorker.generation := 0
		Assert(KLPF_RequestBuild("typing", A_Temp . "\metrics", "full"),
			"the full-build path must reach the spawn seam")
		AssertTrue(KLPF_CancelBuild("typing"))
		Assert(KLPF_RequestRange("typing", A_Temp . "\metrics", _WSAS_RangeQuery()),
			"the selected-range path must reach the spawn seam")
		AssertTrue(KLPF_CancelBuild("range:typing"))
	} finally {
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.generation := SavedGeneration
	}

	AssertEqual(2, _WSAS_Captured.Length,
		"both request paths must have spawned exactly once -- a zero here would make "
		. "every assertion below vacuous (keylogger-worker-timings-must-be-strings)")
	for Capture in _WSAS_Captured {
		Args := Capture["args"]
		Assert(Args is Array && Args.Length > 0,
			"a captured argument vector must be a non-empty Array")
		for Index, Arg in Args {
			Assert(Type(Arg) = "String",
				"argument " . Index . " of the spawned vector is " . Type(Arg)
				. ", so the worker would be refused before launch and the dashboard "
				. "would never paint (keylogger-worker-timings-must-be-strings)")
		}
		Verdict := ShellRunner_ValidateSpawnArgs(Capture["executable"], Args)
		AssertEqual("", Verdict["error"],
			"the live spawn boundary must admit this vector; it refused with: "
			. Verdict["error"])
	}
}

Test("worker spawn: every request path spawns an admissible vector (keylogger-worker-timings-must-be-strings)",
	_WSAS_EveryRequestPathSpawnsAdmissibleVectors)





; ===============================================================
; ===============================================================
; ======= 4/ Untyped caller data is refused, not coerced  =======
; ===============================================================
; ===============================================================

; start_date and end_date reach the same vector straight from the UI bridge. The
; guard checked only that the keys EXIST, so a numeric date would have reproduced
; the identical silent kill one argument further along. Fail closed at the request
; boundary rather than coercing: a non-String date is a caller bug, not a format.
_WSAS_RangeRefusesNonStringDates() {
	global _WSAS_Captured
	SavedSpawn := KLPFWorker.spawn_fn
	SavedJobs := KLPFWorker.jobs
	SavedGeneration := KLPFWorker.generation
	_WSAS_Captured := []
	try {
		KLPFWorker.spawn_fn := _WSAS_CaptureSpawn
		KLPFWorker.jobs := Map()
		KLPFWorker.generation := 0
		Assert(!KLPF_RequestRange("typing", A_Temp . "\metrics",
			_WSAS_RangeQuery(20260801, "2026-08-08")),
			"a non-String start_date must be refused at the request boundary "
			. "(keylogger-worker-timings-must-be-strings)")
		Assert(!KLPF_RequestRange("typing", A_Temp . "\metrics",
			_WSAS_RangeQuery("2026-08-01", 20260808)),
			"a non-String end_date must be refused at the request boundary")
	} finally {
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.generation := SavedGeneration
	}
	AssertEqual(0, _WSAS_Captured.Length,
		"a refused range request must never reach the spawn seam")
}

Test("worker spawn: the range path refuses non-String dates (keylogger-worker-timings-must-be-strings)",
	_WSAS_RangeRefusesNonStringDates)





; =============================================================
; =============================================================
; ======= 5/ Neither request path may inline the vector =======
; =============================================================
; =============================================================

; The defect was four copies of one literal across two functions; three of them
; could be fixed and the fourth would still ship. Both paths must therefore read
; the timings from the single owner, and neither may name KLWConst directly.
_WSAS_NeitherRequestPathInlinesTheTimings() {
	Checked := 0
	for Name in ["KLPF_RequestBuild", "KLPF_RequestRange"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist -- a renamed function would make this "
			. "whole guard pass vacuously")
		Checked += 1
		Assert(InStr(Body, "KLWConst.") = 0,
			Name . " must not name KLWConst directly: those values are Integers and land "
			. "unconverted in the argument vector (keylogger-worker-timings-must-be-strings)")
		Assert(InStr(Body, "KLPF_WorkerTimingArgs()") > 0,
			Name . " must obtain the timing arguments from KLPF_WorkerTimingArgs, so only "
			. "one answer to their wire format can exist")
	}
	AssertEqual(2, Checked, "both request paths must have been inspected")
}

Test("worker spawn: neither request path inlines the timing vector (keylogger-worker-timings-must-be-strings)",
	_WSAS_NeitherRequestPathInlinesTheTimings)
