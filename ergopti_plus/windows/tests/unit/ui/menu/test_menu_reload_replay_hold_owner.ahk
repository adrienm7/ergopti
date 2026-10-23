; tests/unit/ui/menu/test_menu_reload_replay_hold_owner.ahk

; ==============================================================================
; MODULE: Reload Hold Receipt Ownership
; DESCRIPTION:
; A second selection can interrupt the diagnostic after the first path is retained.
; Each retry must keep its own key even when the later selection returns first.
; ==============================================================================

/** Delivers another real registered menu action from an interrupting timer. */
_MRRHO_Interrupt(State, *) {
	try {
		Second := State.Second
		State.Result := MenuCommandRun(Second.Command, ["Toggle", 2, Second.Sub],
			0, () => false, _MRR_Arm.Bind(State.Fixture), Second.Identity)
	} catch as Err {
		State.Error := Err
	} finally State.Done := true
}

/** Pumps the actual logger boundary while the native one-shot interrupts it. */
_MRRHO_Log(State, Line) {
	if State.Started || !InStr(Line, "waits for the reload successor;")
		return
	State.Started := true
	try {
		SetTimer(State.Timer, -1)
		StartedAt := A_TickCount
		while !State.Done && TickElapsed(StartedAt) < 5000
			Sleep(1)
		AssertTrue(State.Done, "the second selection must finish inside the first hold diagnostic")
	} catch as Err {
		State.Error := Err
	}
}

/** Asserts delivery against the actual retained native row, once per selection. */
_MRRHO_AssertRuns(Fixture, First, Second) {
	AssertEqual(2, Fixture.Runs.Length, "neither selected command may be lost or duplicated")
	Seen := Map()
	for Run in Fixture.Runs {
		AssertFalse(Seen.Has(Run.Who), "a hold receipt may deliver its own selection only once")
		Seen[Run.Who] := true
		Expected := Run.Who == "first" ? First : Second
		AssertEqual(Expected.Sub.Handle, Run.Handle, "delivery carries that selection's actual native menu")
		AssertEqual("Toggle", Run.Name)
		AssertEqual(2, Run.Position)
	}
	AssertTrue(Seen.Has("first") && Seen.Has("second"))
}

_MRRHO_Body(Outcome, Fixture) {
	global _MenuReloadReplayRoot, _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_REPEAT_ENABLED
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	AssertEqual(0, A_IsCritical, "the interruption must run on an ordinary menu thread")
	First := _MRR_BuildTray(Fixture, "first")
	Second := _MRR_BuildTray(Fixture, "second")
	; One live root owns both distinct paths; the old standalone roots are detached.
	First.Root.Delete(), Second.Root.Delete()
	Root := Menu()
	Root.Add("First", First.Sub), Root.Add("Second", Second.Sub)
	Fixture.Menus.Push(Root)
	_MenuReloadReplayRoot := Root
	_MRR_ReloadPending()
	State := {Fixture: Fixture, Second: Second, Started: false, Done: false,
		Error: 0, Result: false, Timer: 0}
	State.Timer := _MRRHO_Interrupt.Bind(State)
	Saved := {Sink: _LOGGER_TEST_SINK, Info: _LOGGER_INFO_ENABLED, Repeat: _LOGGER_REPEAT_ENABLED,
		DedupKey: _LOGGER_DEDUP_KEY, DedupLevel: _LOGGER_DEDUP_LEVEL,
		DedupCount: _LOGGER_DEDUP_COUNT, Last: _LastErrTime}
	try {
		_LOGGER_INFO_ENABLED := true
		_LOGGER_REPEAT_ENABLED := false
		_LOGGER_DEDUP_KEY := "", _LOGGER_DEDUP_COUNT := 0
		LoggerSetTestSink(_MRRHO_Log.Bind(State))
		AssertEqual("", MenuCommandRun(First.Command, ["Toggle", 2, First.Sub],
			0, () => false, _MRR_Arm.Bind(Fixture), First.Identity))
		if IsObject(State.Error)
			throw State.Error
		AssertTrue(State.Started && State.Done,
			"a real native timer must retain the later selection before the first receipt returns")
		AssertEqual("", State.Result)
		AssertEqual(2, MenuReloadReplay_HeldCount())
		AssertEqual(2, Fixture.Armed.Length, "each click schedules its own normal dispatch retry")
		AssertEqual(0, Fixture.Runs.Length, "neither action runs against the pending terminal barrier")
		if Outcome == "refused" {
			_MRR_ReloadEnded()
			_MRR_RunArmed(Fixture)
			AssertEqual(0, MenuReloadReplay_HeldCount(), "both exact hold keys are released without an orphan")
		} else {
			AssertTrue(MenuReloadReplay_Publish(Fixture.File))
			_MRR_RunArmed(Fixture)
			AssertEqual(0, Fixture.Runs.Length, "published receipts are retired in the predecessor")
			AssertEqual(0, MenuReloadReplay_HeldCount())
			_MRR_ReloadEnded()
			Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
			AssertEqual(2, Paths.Length)
			AssertEqual("First", Paths[1][1], "publication retains original click order")
			AssertEqual("Second", Paths[2][1])
			_MRR_SuccessorDrains(Fixture, Paths)
		}
		_MRRHO_AssertRuns(Fixture, First, Second)
		_MRR_RunArmed(Fixture)
		AssertEqual(2, Fixture.Runs.Length, "later timer drains cannot replay a receipt again")
		AssertEqual(0, Fixture.Armed.Length)
		AssertEqual(0, Fixture.Notices.Length)
		AssertFalse(FileExist(Fixture.File), "no hand-off image remains after either terminal outcome")
	} finally {
		SetTimer(State.Timer, 0)
		State.Timer := 0
		_LOGGER_TEST_SINK := Saved.Sink
		_LOGGER_INFO_ENABLED := Saved.Info
		_LOGGER_REPEAT_ENABLED := Saved.Repeat
		_LOGGER_DEDUP_KEY := Saved.DedupKey, _LOGGER_DEDUP_LEVEL := Saved.DedupLevel
		_LOGGER_DEDUP_COUNT := Saved.DedupCount, _LastErrTime := Saved.Last
	}
}

Test("menu reload replay: an interrupting click retains its own receipt after a refused reload (menu-reload-hold-key-owner)",
	(*) => _MRR_Run(_MRRHO_Body.Bind("refused")))
Test("menu reload replay: interrupted hold receipts transfer once in click order (menu-reload-hold-key-owner)",
	(*) => _MRR_Run(_MRRHO_Body.Bind("accepted")))
