; tests/unit/gestures/engine/test_worker_result_poll_pause.ahk

; ==============================================================================
; MODULE: Elevated Worker Result Polls Under Pause
; DESCRIPTION:
; The touchpad restart and the onboarding gesture auto-config wait for an
; elevated worker through a one-shot result poll, and timers keep firing under
; native Suspend. A paused poll must keep the job and its published result and
; must not run the completion callback, which presents status; the poll after
; the resume completes it once. Each case owns a fake job whose result file is
; already published, so no worker process is started.
; ==============================================================================

#Requires AutoHotkey v2.0

_WRPP_Case(Kind) {
	global _GestureRestartJob, _OnboardingGestureJob, GESTURE_AUTO_SUCCESS_TOKEN
	IsRestart := Kind = "restart"
	Saved := IsRestart ? _GestureRestartJob : _OnboardingGestureJob
	Poll := IsRestart ? _GestureRestartPoll : _Onboarding_PollGestureAuto
	Stem := A_Temp . "\ergopti_wrpp_" . Kind . "_" . A_TickCount . "_" . Random(1000, 9999)
	Calls := []
	Epoch := Saved["epoch"] + 1000
	Job := Map("epoch", Epoch, "pid", 0x7FFFFFF0, "script", Stem . ".ps1", "result", Stem . ".result",
		"done", (Ok) => Calls.Push(Ok), "starting", false)
	FileAppend(IsRestart ? "0" : GESTURE_AUTO_SUCCESS_TOKEN, Job["result"], "UTF-8-RAW")
	WasSuspended := A_IsSuspended
	try {
		if IsRestart
			_GestureRestartJob := Job
		else
			_OnboardingGestureJob := Job
		Suspend(true)
		Poll.Call(Epoch)
		AssertEqual(0, Calls.Length, "a paused poll must not run the completion callback")
		AssertTrue(Job["pid"] != 0, "a paused poll must keep its job for the resume")
		AssertTrue(FileExist(Job["result"]) != "", "a paused poll must keep the published result")

		Suspend(false)
		Poll.Call(Epoch)
		AssertEqual(1, Calls.Length, "positive control: the poll after the resume completes the job once")
		AssertTrue(Calls[1], "the published success result reaches the callback")
		AssertEqual(0, Job["pid"], "the completed job releases its worker")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		; A retry the paused poll armed meets another epoch and stops.
		Job["epoch"] := -1
		if IsRestart
			_GestureRestartJob := Saved
		else
			_OnboardingGestureJob := Saved
		try FileDelete(Job["result"])
	}
}
Test("gestures: a paused touchpad-restart poll keeps its job until the resume (gesture-restart-nonblocking)",
	_WRPP_Case.Bind("restart"))
Test("onboarding: a paused gesture auto-config poll keeps its job until the resume (onboarding-gesture-async)",
	_WRPP_Case.Bind("onboarding"))
