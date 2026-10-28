; tests/unit/modules/keymap/test_layout_refresh_completion.ahk

; ==============================================================================
; MODULE: Layout Refresh Completion Controls
; DESCRIPTION:
; Exercises callback handoff and exceptional dispatch through real public
; refresh/request/cache code. Transport and scheduling ports are logical; all
; catalogue bodies, cache publication and private cleanup use real files.
; ==============================================================================

#Requires AutoHotkey v2.0

_LCRA_ThrowReenter(World, Outcome) {
	World.Done(Outcome)
	World.Refresh()
	throw Error("Expected subscriber failure after reentrant refresh.")
}

_LCRA_ResolveThenThrow(World, Urls, Callback) {
	World.Resolve(Urls, Callback)
	throw Error("Expected resolver failure after dispatch.")
}

_LCRA_ScheduleThenThrow(World, Callback, Delay) {
	World.Schedule(Callback, Delay)
	throw Error("Expected scheduler failure after retaining its callback.")
}

_LCRA_FactoryFailure(*) {
	throw Error("Expected request factory failure.")
}

_LCRA_WaitFailure(*) {
	throw Error("Expected request wait failure.")
}

_LCRA_CreateWaitFailure(World) {
	Request := World.Create()
	Request.DefineProp("WaitForResponse", {Call: _LCRA_WaitFailure})
	return Request
}

_LCRA_Run(World, Mode) {
	if Mode == "new-directory-alias" {
		World.Dir .= "fresh\child\"
		AssertFalse(DirExist(World.Dir), "the first refresh must create its new directory")
		World.Refresh()
		LayoutCatalogue_Refresh(World.Dir . ".\", ObjBindMethod(World, "Done"), World.Transport, 0, false)
		AssertEqual(1, World.Requests.Length, "canonical aliases share one in-flight response")
		World.Complete(World.Requests[1], 200, '"A"')
		World.Poll(World.Requests[1])
		World.AssertCoherent()
		return
	}
	if Mode == "callback-reentry-throw" {
		LayoutCatalogue_Refresh(World.Dir, _LCRA_ThrowReenter.Bind(World), World.Transport, 0, false)
		World.Refresh()
		AssertEqual(1, World.Requests.Length)
		First := World.Requests[1]
		World.Complete(First, 200, '"A"')
		Failure := 0
		try World.Poll(First)
		catch as Err
			Failure := Err
		AssertTrue(IsObject(Failure))
		AssertContains(Failure.Message, "Expected subscriber failure")
		AssertEqual(2, World.Results.Length, "one throwing subscriber cannot strand its admitted sibling")
		AssertEqual(2, World.Requests.Length, "callback reentry admits a fresh request after retirement")
		Second := World.Requests[2]
		AssertTrue(First.Path != Second.Path, "a successor never reuses a late response path")
		World.Complete(Second, 200, '"B"')
		World.Poll(Second)
		AssertEqual(3, World.Results.Length)
		AssertEqual(World.Bodies['"B"'], World.Results[3]["text"])
		AssertEqual('"B"', FileRead(World.Dir . "index.etag", "UTF-8-RAW"))
		return
	}
	Broken := World.Transport.Clone()
	if Mode == "resolve-throw"
		Broken["resolve_proxy"] := _LCRA_ResolveThenThrow.Bind(World)
	else if Mode == "schedule-throw"
		Broken["schedule"] := _LCRA_ScheduleThenThrow.Bind(World)
	else if Mode == "factory-throw"
		Broken["request"] := _LCRA_FactoryFailure
	else {
		AssertEqual("wait-throw", Mode)
		Broken["request"] := _LCRA_CreateWaitFailure.Bind(World)
	}
	LayoutCatalogue_Refresh(World.Dir, ObjBindMethod(World, "Done"), Broken, 0, false)
	AssertEqual(1, World.Results.Length, "the current exceptional dispatch settles once")
	AssertTrue(World.Results[1]["error"] is Map)
	World.Refresh()
	Live := World.Requests[World.Requests.Length]
	World.Complete(Live, 200, '"B"')
	if Mode == "resolve-throw" || Mode == "schedule-throw" {
		Old := World.Requests[1]
		AssertTrue(Old != Live && Old.Path != Live.Path)
		World.Complete(Old, 200, '"A"')
		World.Poll(Old)
		AssertEqual(1, World.Results.Length, "late completion cannot settle the already-retired exchange twice")
		AssertTrue(FileExist(Live.Path), "late old cleanup cannot remove the successor response")
		AssertFalse(FileExist(Old.Path), "late terminal cleans only its own private response")
	}
	World.Poll(Live)
	AssertEqual(2, World.Results.Length)
	AssertEqual(0, World.Results[2]["error"])
	AssertEqual(World.Bodies['"B"'], World.Results[2]["text"])
	AssertEqual('"B"', FileRead(World.Dir . "index.etag", "UTF-8-RAW"))
	AssertEqual(World.Bodies['"B"'], FileRead(World.Dir . "index.json", "UTF-8-RAW"))
}

_LCRA_Case(Mode) {
	global _LayoutRegistryDefaults, _LayoutRegistryGithub, _LayoutCatalogueLast, _LayoutCatalogueRefreshes
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedDefaults := _LayoutRegistryDefaults, SavedGithub := _LayoutRegistryGithub, SavedLast := _LayoutCatalogueLast
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Dir := "", World := 0, Primary := 0, CleanupError := 0
	try {
		AssertFalse(SavedLogger.FlushActive, "no foreign logger flush may be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Dir := _LCR_Directory()
		World := _LCR_World(Dir)
		_LCRA_Run(World, Mode)
		AssertEqual(0, World.Tasks.Length, "every controlled poll is drained")
		for Request in World.Requests
			AssertFalse(FileExist(Request.Path), "each exact private response path is retired")
		Key := StrLower(RTrim(FSResolveDirectoryPath(World.Dir), "\") . "\")
		AssertFalse(_LayoutCatalogueRefreshes.Has(Key), "the completed directory has no retained refresh owner")
	} catch as Err {
		Primary := Err
	} finally {
		try {
			if IsObject(World)
				World.Retire()
		} catch as Err {
			CleanupError := Err
		} finally {
			try {
				if Dir != "" {
					Keys := []
					Prefix := StrLower(RTrim(FSResolveDirectoryPath(Dir), "\") . "\")
					for Key in _LayoutCatalogueRefreshes
						if InStr(Key, Prefix) == 1
							Keys.Push(Key)
					for Key in Keys {
						_LayoutCatalogueRefreshes[Key].Callbacks.Length := 0
						_LayoutCatalogueRefreshes.Delete(Key)
					}
					DirDelete(Dir, true)
				}
			} catch as Err {
				if !IsObject(CleanupError)
					CleanupError := Err
			} finally {
				_LayoutRegistryDefaults := SavedDefaults, _LayoutRegistryGithub := SavedGithub, _LayoutCatalogueLast := SavedLast
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Value in SavedExtra
					%Name% := Value
				for Name, Saved in SavedOptional
					%Name% := Saved.Present ? Saved.Value : unset
				Critical(PreviousCritical)
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}


for _LCRA_Mode in ["new-directory-alias", "callback-reentry-throw", "resolve-throw", "schedule-throw", "factory-throw", "wait-throw"]
	Test("layout-refresh-completion: exact retirement survives " . _LCRA_Mode, _LCRA_Case.Bind(_LCRA_Mode))
