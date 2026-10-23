; tests/unit/modules/keymap/test_layout_catalogue_refresh_owner.ahk

; ==============================================================================
; MODULE: Layout Catalogue Refresh Ownership Tests
; DESCRIPTION:
; Replays overlapping public refreshes through the real registry request,
; polling and native cache publication. Only transport and scheduling are
; controlled; no HTTP child, elapsed timer or native cancellation is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_LCR_Directory() {
	global DriverPid
	static Sequence := 0
	Loop 32 {
		Sequence += 1
		Dir := A_Temp . "\ergopti_layout_refresh_" . DriverPid . "_" . A_TickCount . "_" . Sequence . "\"
		if DllCall("Kernel32\CreateDirectoryW", "WStr", RTrim(Dir, "\"), "Ptr", 0, "Int")
			return Dir
		if A_LastError != 183
			throw OSError(A_LastError, -1, "Cannot acquire the private refresh directory.")
	}
	throw Error("Cannot acquire a unique refresh directory.")
}

_LCR_Write(Path, Text) {
	File := FileOpen(Path, "w", "UTF-8-RAW")
	try AssertEqual(StrLen(Text), File.Write(Text), "the controlled response is physically written")
	finally File.Close()
	AssertEqual(Text, FileRead(Path, "UTF-8-RAW"), "the physical response equals its independent golden")
}

class _LCR_Request {
	__New(World) {
		this.World := World
		this.Headers := Map()
		this.Path := ""
		this.Status := 0
		this.Etag := ""
		this.Ready := false
		this.Aborted := false
	}
	Open(Method, Url, Async) {
		AssertEqual("GET", Method)
		this.Url := Url
	}
	SetRequestHeader(Name, Value) {
		this.Headers[Name] := Value
	}
	SetProxy(Proxy) {
	}
	SetTimeouts(Resolve, Connect, Send, Receive) {
	}
	SetOutputFile(Path) {
		this.Path := Path
	}
	Send() {
		this.World.Sends += 1
		return true
	}
	WaitForResponse(Timeout := 0) {
		this.World.LastPolled := this
		return this.Ready
	}
	GetResponseHeader(Name) {
		return StrLower(Name) == "etag" ? this.Etag : ""
	}
	Abort() {
		this.Aborted := true
		return true
	}
}

class _LCR_World {
	__New(Dir) {
		this.Dir := Dir
		this.Requests := []
		this.Tasks := []
		this.Results := []
		this.LastPolled := 0
		this.Sends := 0
		this.Bodies := Map()
		for Label in ["A", "B"]
			this.Bodies['"' . Label . '"'] := '{"layouts":[],"witness":"' . Label . '"}'
		this.Transport := Map("request", ObjBindMethod(this, "Create"),
			"resolve_proxy", ObjBindMethod(this, "Resolve"), "schedule", ObjBindMethod(this, "Schedule"))
	}
	Create() {
		Request := _LCR_Request(this)
		this.Requests.Push(Request)
		return Request
	}
	Resolve(Urls, Callback) {
		Resolved := Map()
		for Url in Urls
			Resolved[Url] := ""
		Callback.Call(Resolved)
	}
	Schedule(Fn, Delay) {
		this.Tasks.Push({Request: this.LastPolled, Fn: Fn})
	}
	Refresh() {
		LayoutCatalogue_Refresh(this.Dir, ObjBindMethod(this, "Done"), this.Transport, 0, false)
	}
	Done(Outcome) {
		this.Results.Push(Outcome)
	}
	Complete(Request, Status, Etag) {
		Request.Status := Status
		Request.Etag := Etag
		if Status == 200
			_LCR_Write(Request.Path, this.Bodies[Etag])
		Request.Ready := true
	}
	Poll(Request) {
		for Task in this.Tasks {
			if Task.Request == Request {
				this.Tasks.RemoveAt(A_Index)
				Task.Fn.Call()
				return
			}
		}
		throw Error("The real request poll was not retained by the scheduling boundary.")
	}
	Drain() {
		; A repair may serialize requests or share their result. Neither requires
		; simultaneous children; complete every genuinely admitted request once.
		Loop 16 {
			if this.Results.Length == 2 && this.Tasks.Length == 0
				return
			for Request in this.Requests {
				if !Request.Ready
					this.Complete(Request, 200, '"B"')
			}
			if this.Tasks.Length > 0 {
				Task := this.Tasks.RemoveAt(1)
				Task.Fn.Call()
			}
		}
		throw Error("The two public refresh callbacks did not settle within the controlled poll steps.")
	}
	AssertCoherent() {
		AssertEqual(2, this.Results.Length, "both public refreshes complete exactly once")
		for Result in this.Results {
			AssertEqual(0, Result["error"], "two successful responses cannot lose a private response file")
			AssertTrue(this.Bodies.Has(Result["etag"]), "the result retains a served ETag")
			AssertEqual(this.Bodies[Result["etag"]], Result["text"], "the response body belongs to its ETag")
		}
		Body := FileRead(this.Dir . "index.json", "UTF-8-RAW")
		Etag := FileRead(this.Dir . "index.etag", "UTF-8-RAW")
		AssertTrue(this.Bodies.Has(Etag), "the cache retains a served ETag")
		AssertEqual(this.Bodies[Etag], Body, "the durable cache never pairs one response with another ETag")
	}
	Retire() {
		this.Tasks.Length := 0
		this.LastPolled := 0
		for Request in this.Requests {
			AssertTrue(Request.Abort(), "the private logical transport retires")
			Request.World := 0
		}
		this.Requests.Length := 0
		this.Transport.Clear()
		this.Transport := 0
	}
}

_LCR_Case(Mode) {
	global _LayoutRegistryDefaults, _LayoutRegistryGithub, _LayoutCatalogueLast
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
		World.Refresh()
		AssertEqual(1, World.Requests.Length, "the first public refresh reaches the real request factory")
		First := World.Requests[1]
		if Mode == "sequential-304" || Mode == "http-fallback" {
			World.Complete(First, 200, '"A"')
			World.Poll(First)
			World.Refresh()
			Second := World.Requests[2]
			AssertEqual('"A"', Second.Headers["If-None-Match"], "the second public request uses its actual cache")
			World.Complete(Second, Mode == "sequential-304" ? 304 : 503, '"A"')
			World.Poll(Second)
			AssertEqual(2, World.Results.Length)
			AssertEqual("cache", World.Results[2]["source"])
			AssertEqual(Mode == "sequential-304" ? 0 : "http",
				World.Results[2]["error"] is Map ? World.Results[2]["error"]["code"] : 0)
			AssertEqual(World.Bodies['"A"'], FileRead(Dir . "index.json", "UTF-8-RAW"))
			AssertEqual('"A"', FileRead(Dir . "index.etag", "UTF-8-RAW"))
		} else {
			World.Refresh()
			; Normal transport completion writes before its next caller poll.
			for Request in World.Requests
				World.Complete(Request, 200, A_Index == 1 ? '"A"' : '"B"')
			Chosen := Mode == "older-poll-first" ? First : World.Requests[World.Requests.Length]
			World.Poll(Chosen)
			FirstResult := World.Results.Length > 0 ? World.Results[1] : 0
			FileAppend("RECEIPT layout-refresh " . Mode . " requests=" . World.Requests.Length
				. " callbacks=" . World.Results.Length . " etag=" . (FirstResult is Map ? FirstResult["etag"] : "none")
				. " text=" . (FirstResult is Map ? FirstResult["text"] : "none")
				. " pending_output_exists=" . (FileExist(First.Path) ? 1 : 0) . "`n", "*")
			World.Drain()
			World.AssertCoherent()
		}
		AssertEqual(0, World.Tasks.Length, "no controlled timer remains")
		AssertFalse(FileExist(Dir . "index.json.download"), "the canonical temporary file is retired")
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
				if Dir != ""
					DirDelete(Dir, true)
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





; ========================
; ========================
; ======= 2/ Cases =======
; ========================
; ========================

for _LCR_Mode in ["sequential-304", "http-fallback", "older-poll-first", "newer-poll-first"]
	Test("layout-refresh-owner: cache bytes and ETag stay coherent across " . _LCR_Mode,
		_LCR_Case.Bind(_LCR_Mode))
