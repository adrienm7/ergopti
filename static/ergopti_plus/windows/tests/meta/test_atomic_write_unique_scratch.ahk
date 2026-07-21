; tests/meta/test_atomic_write_unique_scratch.ahk

; ==============================================================================
; MODULE: Atomic-Write Scratch Name Uniqueness Meta Test
; DESCRIPTION:
; Regression guard for the temp+rename writers whose scratch file was a fixed
; ``path . ".tmp"``. A constant name makes the scratch file a SHARED RESOURCE
; between every writer of the same target, and both writers in this class sleep
; between staging and renaming to ride out an antivirus lock. That sleep is a
; yield point, so a second thread can enter, publish its own staged file and
; consume the name out from under the sleeper:
;
;   A: FileAppend(tmp) -> rename fails (AV lock) -> Sleep  …yields…
;   B: FileDelete(tmp) -> FileAppend(tmp) -> rename succeeds, tmp consumed
;   A: wakes, retries the rename on a tmp that is gone -> ERROR_FILE_NOT_FOUND
;
; Field evidence: ErgoptiPlus_errors_2026-07-20.log carries five "(2) file not
; found" and two "(32) sharing violation" failures from KL_SaveState. The worse
; outcome is silent: two interleaved FileAppend calls publish spliced JSON.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE — scratch-name uniqueness — not the symptom. A fix
;    that only added another retry would still fail this test.
; 2. Enumerates the whole CLASS rather than the one site the bug was found at,
;    per project-ahk-guard-tests-must-loop-the-class. Adding a third writer that
;    reuses a constant scratch name fails here immediately.
; 3. Pairs the source assertion with a behavioural round-trip so the uniqueness
;    refactor cannot silently break publishing.
;
; SCOPE: source introspection of the atomic writers, plus one behavioural
; KLPF_WriteAtomic round-trip. KL_WriteAtomic cannot be called here because
; run_all.ahk deliberately loads keylogger_prefetch.ahk WITHOUT keylogger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ================================================
; ======= 1/ Class-wide scratch uniqueness =======
; ================================================
; ===============================================

; Every writer that stages to a sibling scratch file before publishing it over
; the target. They are checked together so the invariant is pinned to the
; class, not to whichever function the bug was last found in.
;
; The first two sleep between staging and renaming to ride out an AV lock, and
; that sleep is the yield point. TOML_BatchWrite has no sleep, but it opens the
; same hazard from the other end: it begins with an unconditional
; ``FileDelete(tmp)``, which on a shared name destroys a concurrent writer's
; live staging file. Its target is config.toml, and it is reached both from
; menu actions and from timer-driven saves, so two writers really can overlap.
_AWU_SleepRetryWriters() {
	return ["KL_WriteAtomic", "KLPF_WriteAtomic", "TOML_BatchWrite"]
}

_AWU_ScratchNamesAreUnique() {
	for Name in _AWU_SleepRetryWriters() {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")

		; The exact defect: a scratch name built only from the destination. The
		; pattern is case-insensitive because the writers spell the destination
		; variable differently (``path`` / ``Path``) and the defect is the same.
		Assert(RegExMatch(Body, 'i)tmp\s*:=\s*path\s*\.\s*"\.tmp"') == 0,
			Name . ' must not stage to a scratch name built only from the destination path — a constant name is shared between concurrent writers of the same target, and the Sleep retry in this function is the yield point that lets them collide')

		; And the positive form, so deleting the fixed name is not enough: the
		; scratch name must actually vary per invocation. A_ScriptHwnd covers the
		; cross-process case (#SingleInstance Force leaves two drivers briefly
		; alive), the counter covers threads inside one process. A_ScriptHwnd is
		; required specifically rather than any uniquifier because the obvious
		; alternative — a GetCurrentProcessId DllCall — would push the OS-call
		; purity ratchet above its baseline.
		Assert(InStr(Body, "A_ScriptHwnd") > 0,
			Name . " must include A_ScriptHwnd in its scratch name so two live driver instances cannot share it, without adding a DllCall the purity ratchet would count")
		Assert(RegExMatch(Body, "WriteSeq\s*\+=\s*1") > 0,
			Name . " must advance a per-invocation counter so two threads in the same process cannot share a scratch name")
	}
}

; Unique names no longer self-clean the way a single reused name did, so each
; writer must reap debris left by a hard kill — otherwise scratch files
; accumulate in the metrics directory forever.
_AWU_StaleScratchIsReaped() {
	Reapers := Map("KL_WriteAtomic", "_KL_ReapStaleTemps",
		"KLPF_WriteAtomic", "_KLPF_ReapStaleTemps",
		"TOML_BatchWrite", "_TOML_ReapStaleTemps")
	for Writer, Reaper in Reapers {
		Body := _DriverFuncBody(Writer)
		Assert(Body != "", Writer . "() must exist in the driver source")
		Assert(InStr(Body, Reaper . "(") > 0,
			Writer . " must reap stale scratch files via " . Reaper . " — per-invocation names do not self-clean after a hard kill")

		ReaperBody := _DriverFuncBody(Reaper)
		Assert(ReaperBody != "", Reaper . "() must exist in the driver source")
		; An unconditional sweep would delete a concurrent writer's live scratch
		; file, turning a tidy-up into the very race this change removes.
		Assert(InStr(ReaperBody, "MaxAgeMs") > 0,
			Reaper . " must only delete scratch files older than an age threshold, or it would reap a concurrent writer's live staging file")
	}
}





; =========================================
; =========================================
; ======= 2/ Behavioural round-trip =======
; =========================================
; =========================================

; Guards the refactor itself: publishing must still work, and must not leave the
; staged file behind now that its name is no longer overwritten by the next call.
_AWU_PrefetchWriteRoundTrip() {
	Dir := A_Temp . "\ergopti_atomic_scratch_test"
	Target := Dir . "\prefetch.json"
	try DirCreate(Dir)
	try FileDelete(Target)

	try {
		Ok := KLPF_WriteAtomic(Target, '{"probe":1}')
		Assert(Ok, "KLPF_WriteAtomic must report success on a writable target")
		Assert(FileExist(Target), "KLPF_WriteAtomic must publish the destination file")
		Assert(InStr(FileRead(Target, "UTF-8"), '"probe":1') > 0,
			"the published file must carry the staged content")

		; A second write must succeed too, and must not trip over the first
		; call's scratch name — the whole point of the change.
		Ok2 := KLPF_WriteAtomic(Target, '{"probe":2}')
		Assert(Ok2, "a second KLPF_WriteAtomic must succeed after the first")
		Assert(InStr(FileRead(Target, "UTF-8"), '"probe":2') > 0,
			"the second write must replace the published content")

		Leftover := 0
		Loop Files, Dir . "\prefetch.json.*.tmp"
			Leftover += 1
		Assert(Leftover == 0,
			"a successful write must leave no scratch file behind (found " . Leftover . ")")
	} finally {
		try FileDelete(Target)
		try DirDelete(Dir, true)
	}
}


Test("atomic-write: sleep-retrying writers use a per-invocation scratch name",
	_AWU_ScratchNamesAreUnique)
Test("atomic-write: each writer reaps stale scratch files by age",
	_AWU_StaleScratchIsReaped)
Test("atomic-write: KLPF_WriteAtomic publishes and leaves no scratch behind",
	_AWU_PrefetchWriteRoundTrip)
