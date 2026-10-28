; tests/unit/modules/keymap/test_layout_registry_download_custody.ahk

; ==============================================================================
; MODULE: Layout Registry Native Download Custody Controls
; DESCRIPTION:
; Exercises real staged files and native handles through public registry calls
; and domain capabilities. Fault observers never perform the ownership work:
; successful close, disposition and rename always use the real Win32 boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRDC_Wire() => '{"layouts":[],"witness":"réel"}' . "`r`n"

; Read activity is keyed lexically by the owner's resolved long path, while the
; fixture directory may be a short alias such as RUNNER~1 under A_Temp. Busy
; queries therefore use the authoritative Owner.Path, never the requested name.
_LRDC_OwnerPath(Owner, Directory) {
	if IsObject(Owner)
		return Owner.Path
	return FSResolveDirectoryPath(RTrim(Directory, "\")) . "\response.download"
}

; Proves that the requested stage name and the resolved owner path open the
; same native file, so querying Owner.Path keeps the same physical coordinate.
_LRDC_AssertSameNativeFile(Owner, Stage) {
	Probe := DllCall("kernel32\CreateFileW", "Str", Stage, "UInt", 0x80000000,
		"UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
	AssertTrue(Probe != -1, "the requested stage name must open the owned native file")
	try {
		Expected := FSHandleSnapshot(Owner.Pin.Handle), Actual := FSHandleSnapshot(Probe)
		AssertTrue(Expected.Get("ok", false) && Actual.Get("ok", false))
		for Key in ["volume", "index_high", "index_low"]
			AssertEqual(Expected[Key], Actual[Key], "the requested and resolved stage names must denote one native file")
	} finally AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Probe, "Int") != 0)
}

_LRDC_Finish(Owner, Directory) {
	if IsObject(Owner) {
		Owner.Retired := true
		AssertTrue(Owner.Remove(), "the exact fixture download must retire before directory cleanup")
	}
	AssertFalse(FileReadActivityBusy(_LRDC_OwnerPath(Owner, Directory)))
	DirDelete(Directory, true)
}

_LRDC_PublishExact(Bom) {
	Dir := _LCR_Directory(), Stage := Dir . "response.download", Destination := Dir . "cache.json", Owner := 0
	Wire := (Bom ? Chr(0xFEFF) : "") . _LRDC_Wire()
	try {
		Owner := _LayoutRegistryDownload(Stage)
		_LRDC_AssertSameNativeFile(Owner, Stage)
		AssertTrue(FileReadActivityBusy(Owner.Path), "creation owns real cleanup before transport dispatch")
		AssertThrows(() => Owner.ReadText(4096), "an active transfer cannot be consumed")
		AssertFalse(LayoutRegistry_PrepareShutdown(), "an active transfer must refuse terminal admission")
		_LCT_WriteRaw(Stage, Wire)
		Owner.Retired := true
		AssertEqual(_LRDC_Wire(), Owner.ReadText(4096), "text decoding keeps the established BOM semantics")
		AssertFalse(Owner.ReadText(2), "a native output read still enforces its exact byte bound")
		AssertTrue(Owner.Publish(Destination), "publication must rename the verified native object")
		AssertEqual(Wire, FSReadUtf8Exact(Destination), "publication retains the original BOM, CRLF and UTF-8 bytes")
		AssertFalse(FileExist(Stage))
		AssertTrue(Owner.Removed)
		AssertTrue(LayoutRegistry_PrepareShutdown())
	} finally _LRDC_Finish(Owner, Dir)
}

for _LRDC_Bom in [false, true]
	Test("layout registry custody: native publication retains wire bytes with BOM=" . _LRDC_Bom
		. " (layout-registry-download-custody)", _LRDC_PublishExact.Bind(_LRDC_Bom))

_LRDC_Debt(Mode) {
	Dir := _LCR_Directory(), Stage := Dir . "response.download", Destination := Dir . "cache.json"
	Owner := 0, ForeignHandle := -1, Injected := false, Calls := 0, NativeCalls := 0, ReentrantReady := true
	CloseMode := InStr(Mode, "close-") == 1
	MetadataMode := Mode == "metadata-refused"
	PublishMode := InStr(Mode, "publish-") == 1
	ThrowAfter := InStr(Mode, "-throw") > 0
	Boundary := MetadataMode ? FileReadActivityLeave : CloseMode ? _LayoutRegistryDownloadCloseNative
		: PublishMode ? _LayoutRegistryDownloadPublishNative : _LayoutRegistryDownloadDiscardNative
	AssertFalse(Boundary.HasOwnProp("Call"), "a foreign native observer cannot be replaced")
	Observe(Self, Params*) {
		Target := !MetadataMode || Params[1] == Owner.Pin.Activity
		if Target
			Calls += 1
		if Target && !Injected && !ThrowAfter {
			Injected := true
			ReentrantReady := LayoutRegistry_RetireDownloads()
			return false
		}
		Self.DeleteProp("Call")
		try Result := Self.Call(Params*)
		finally Self.DefineProp("Call", {Call: Observe})
		if Target
			NativeCalls += 1
		if Target && !Injected && ThrowAfter {
			Injected := true
			if CloseMode {
				AssertEqual(-1, Owner.Pin.Handle, "the actual close ACK must be recorded before returning to an observer")
				ForeignHandle := DllCall("kernel32\CreateFileW", "Str", Dir . "foreign.bin", "UInt", 0xC0000000,
					"UInt", 0, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
				AssertTrue(ForeignHandle != -1)
			} else
				AssertTrue(Owner.DispositionCommitted, "the native mutation receipt must precede any observer throw")
			throw Error("Expected throw after the actual registry native ACK.")
		}
		return Result
	}
	try {
		_LCT_WriteRaw(Destination, "previous-cache")
		Owner := _LayoutRegistryDownload(Stage)
		_LCT_WriteRaw(Stage, _LRDC_Wire())
		Owner.Retired := true
		if !CloseMode && !MetadataMode
			AssertEqual(_LRDC_Wire(), Owner.ReadText(4096))
		Boundary.DefineProp("Call", {Call: Observe})
		Failure := 0, Result := false
		try Result := (CloseMode || MetadataMode) ? Owner.ReadText(4096)
			: PublishMode ? Owner.Publish(Destination) : Owner.Remove()
		catch as Err
			Failure := Err
		AssertTrue(Injected, "the actual ownership operation must reach the controlled boundary")
		AssertEqual(ThrowAfter, IsObject(Failure), "only the explicit after-ACK throw may raise")
		if !ThrowAfter {
			AssertFalse(Result)
			AssertFalse(ReentrantReady, "reentrant cleanup cannot claim an in-progress native transition")
		}
		if MetadataMode {
			AssertEqual(-1, Owner.Pin.Handle, "metadata refusal cannot resurrect an acknowledged native handle")
			ForeignHandle := DllCall("kernel32\CreateFileW", "Str", Dir . "foreign.bin", "UInt", 0xC0000000,
				"UInt", 0, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
			AssertTrue(ForeignHandle != -1)
		}
		AssertTrue(_LayoutRegistryDownloadOwners().Has(Owner), "refused cleanup keeps its exact domain capability")
		AssertTrue(FileReadActivityBusy(Owner.Path), "unacknowledged cleanup still blocks terminal admission")
		Boundary.DeleteProp("Call")
		AssertTrue(LayoutRegistry_RetireDownloads(), "a later admission retries the retained native owner")
		AssertTrue(Owner.Removed)
		AssertFalse(_LayoutRegistryDownloadOwners().Has(Owner))
		AssertFalse(FileReadActivityBusy(Owner.Path))
		AssertFalse(FileExist(Stage))
		AssertEqual(PublishMode && ThrowAfter ? _LRDC_Wire() : "previous-cache", FSReadUtf8Exact(Destination))
		if ForeignHandle != -1
			AssertTrue(FSHandleSnapshot(ForeignHandle).Get("ok", false), "cleanup cannot close an unrelated handle after an earlier numeric handle was retired")
		if ThrowAfter
			AssertEqual(1, NativeCalls, "a completed native mutation is never reissued after its observer throws")
	} finally {
		if Boundary.HasOwnProp("Call")
			Boundary.DeleteProp("Call")
		if ForeignHandle != -1
			AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", ForeignHandle, "Int") != 0)
		_LRDC_Finish(Owner, Dir)
	}
}

for _LRDC_Mode in ["close-refused", "close-throw", "discard-refused", "discard-throw", "publish-refused", "publish-throw", "metadata-refused"]
	Test("layout registry custody: " . _LRDC_Mode . " retains and retries the exact native owner (layout-registry-download-custody)",
		_LRDC_Debt.Bind(_LRDC_Mode))

_LRDC_Rebound() {
	Dir := _LCR_Directory(), Stage := Dir . "response.download", Original := Dir . "original-retained.bin"
	Foreign := Dir . "foreign-retained.bin", Owner := 0, Rebound := false
	Boundary := _LayoutRegistryDownloadCloseNative
	AssertFalse(Boundary.HasOwnProp("Call"))
	Observe(Self, Slot) {
		Self.DeleteProp("Call")
		try Ack := Self.Call(Slot)
		finally Self.DefineProp("Call", {Call: Observe})
		if Ack && Slot == Owner.Pin && !Rebound {
			Rebound := true
			FileMove(Stage, Original, 0)
			AssertTrue(FSWriteCreateDurable(Stage, "foreign replacement é`r`n"))
		}
		return Ack
	}
	try {
		Owner := _LayoutRegistryDownload(Stage)
		_LCT_WriteRaw(Stage, _LRDC_Wire())
		Owner.Retired := true
		Boundary.DefineProp("Call", {Call: Observe})
		AssertFalse(Owner.ReadText(4096), "a rebound pathname never grants authority to its replacement")
		AssertTrue(Rebound)
		Boundary.DeleteProp("Call")
		AssertFalse(Owner.ReadText(4096), "a failed claim cannot become admitted on a second call")
		AssertFalse(Owner.Publish(Dir . "forbidden-cache.json"))
		AssertFalse(Owner.Remove(), "cleanup cannot dispose a foreign file at the old name")
		AssertFalse(LayoutRegistry_PrepareShutdown(), "a refused capability remains explicit recovery debt")
		AssertEqual("foreign replacement é`r`n", FSReadUtf8Exact(Stage))
		AssertFalse(FileExist(Dir . "forbidden-cache.json"))
		; Restore the exact original object, preserving the independently owned
		; replacement. Retry now proves native identity, not a guessed pathname.
		FileMove(Stage, Foreign, 0)
		FileMove(Original, Stage, 0)
		AssertTrue(LayoutRegistry_RetireDownloads())
		AssertFalse(FileExist(Stage))
		AssertEqual("foreign replacement é`r`n", FSReadUtf8Exact(Foreign))
		AssertTrue(LayoutRegistry_PrepareShutdown())
	} finally {
		if Boundary.HasOwnProp("Call")
			Boundary.DeleteProp("Call")
		if Rebound && FileExist(Original) {
			if FileExist(Stage)
				FileMove(Stage, Foreign, 1)
			FileMove(Original, Stage, 0)
		}
		_LRDC_Finish(Owner, Dir)
	}
}
Test("layout registry custody: a replaced path cannot be read published or deleted (layout-registry-download-custody)", _LRDC_Rebound)

_LRDC_DispatchFailure(Mode) {
	Dir := _LCR_Directory(), Results := [], Factories := 0
	Factory() {
		Factories += 1
		throw Error("Expected request-construction failure.")
	}
	Resolve(Urls, Callback) {
		if Mode == "resolver"
			throw Error("Expected registry resolver failure.")
		Callback.Call(_LCT_NoProxy(Urls))
	}
	try {
		Transport := Map("request", Factory, "resolve_proxy", Resolve, "schedule", (Fn, Delay) => Fn.Call())
		LayoutCatalogue_Refresh(Dir, (Outcome) => Results.Push(Outcome), Transport, 0, false)
		AssertEqual(1, Results.Length, "a pre-dispatch exception still completes the public refresh once")
		AssertTrue(Results[1]["error"] is Map)
		AssertEqual(Mode == "resolver" ? 0 : 1, Factories)
		AssertTrue(LayoutRegistry_PrepareShutdown(), "no constructor or resolver failure may leak a native stage owner")
		Loop Files Dir . "*.download*", "F"
			throw Error("A failed dispatch retained a native response file: " . A_LoopFileName)
	} finally DirDelete(Dir, true)
}
for _LRDC_FailureMode in ["resolver", "constructor"]
	Test("layout registry custody: public " . _LRDC_FailureMode . " failure retires its creation stage (layout-registry-download-custody)",
		_LRDC_DispatchFailure.Bind(_LRDC_FailureMode))

_LRDC_PublicBomIndex() {
	Dir := _LCR_Directory(), Results := [], Log := []
	Wire := Chr(0xFEFF) . _LRDC_Wire()
	Served := Map(LayoutRegistry_RawUrl(LayoutRegistry_Settings()["index_file"]),
		Map("status", 200, "body", Wire, "etag", ""))
	try {
		LayoutCatalogue_Refresh(Dir, (Outcome) => Results.Push(Outcome), _LCT_Transport(Served, Log), 0, false)
		AssertEqual(1, Results.Length)
		AssertEqual("network", Results[1]["source"])
		AssertEqual(0, Results[1]["error"])
		AssertEqual(Wire, FSReadUtf8Exact(Dir . LayoutRegistry_Settings()["index_file"]),
			"the public index path decodes JSON but publishes the exact BOM-bearing wire bytes")
		AssertTrue(LayoutRegistry_PrepareShutdown())
	} finally DirDelete(Dir, true)
}
Test("layout registry custody: the public index preserves BOM-bearing wire bytes (layout-registry-download-custody)",
	_LRDC_PublicBomIndex)

; The public call really loses both schedule attempts after a refused Abort.
; Its real Curl facade then acknowledges the exact controlled process Job.
; Native files prove late/stale cleanup; no native WinHTTP wire is claimed.
_LRDC_RequestRetirement(ResumeMode) {
	global _HTTP_CURL_ABORT_TIMER, _HTTP_CURL_CLEANUP_TIMER, _LayoutCatalogueLast
	PreviousCritical := Critical("On")
	SavedAbortTimer := _HTTP_CURL_ABORT_TIMER, SavedCleanupTimer := _HTTP_CURL_CLEANUP_TIMER
	SavedLast := _LayoutCatalogueLast
	Dir := _LCR_Directory(), State := _ManagedCurlControlState(), Captured := [], Queue := []
	FirstResults := [], NextResults := [], ScheduleCalls := 0, Log := []
	State["retire"] := false
	Schedule(Fn, Delay) {
		ScheduleCalls += 1
		Captured.Push(Fn)
		if ScheduleCalls <= 2
			throw Error("Expected registry poll scheduling refusal.")
		Queue.Push(Fn)
	}
	Transport := Map("managed", true, "request", _LRR_Factory.Bind(State), "schedule", Schedule)
	try {
		LayoutCatalogue_Refresh(Dir, (Outcome) => FirstResults.Push(Outcome), Transport, 0, false)
		AssertEqual(1, FirstResults.Length, "the public refresh must visibly retire its business admission")
		AssertTrue(FirstResults[1]["error"] is Map)
		AssertEqual(2, ScheduleCalls, "the actual poll and abort-retirement schedules must both be refused")
		Request := State["request"]
		AssertTrue(Request.Aborted && !Request.Completed && IsObject(Request.Handle))
		AssertTrue(FileReadActivityBusy(Request.OutputPath), "the still-live request keeps its physical stage pin")
		_LCR_Write(Request.OutputPath, _LRDC_Wire())
		_LRR_Terminal(State, false)
		AssertTrue(Request.Completed && !IsObject(Request.Handle))
		NextWire := '{"layouts":[],"witness":"successor"}'
		Served := Map(LayoutRegistry_RawUrl(LayoutRegistry_Settings()["index_file"]),
			Map("status", 200, "body", NextWire, "etag", ""))
		LayoutCatalogue_Refresh(Dir, (Outcome) => NextResults.Push(Outcome), _LCT_Transport(Served, Log), 0, false)
		AssertEqual(1, NextResults.Length)
		AssertEqual("network", NextResults[1]["source"])
		if ResumeMode == "late-poll"
			Captured[1].Call()
		AssertFalse(FileExist(Request.OutputPath), "a successor admission must recover the exact prior registry retirement even when its timer was lost")
		AssertFalse(FileReadActivityBusy(Request.OutputPath))
		AssertEqual(NextWire, FSReadUtf8Exact(Dir . LayoutRegistry_Settings()["index_file"]),
			"a late old response cannot publish or remove its successor's native index")
		AssertEqual(1, FirstResults.Length, "the stale business callback is never delivered twice")
		AssertEqual(1, NextResults.Length)
		AssertTrue(LayoutRegistry_PrepareShutdown(), "recovered request retirement must release every stage owner")
	} finally {
		try {
			State["retire"] := true
			if State.Has("request")
				AssertTrue(State["request"].Abort())
			for Callback in Captured
				Callback.Call()
			Queue.Length := 0
			AssertTrue(LayoutRegistry_RetireDownloads())
			_ManagedCurlControlRelease(State)
			DirDelete(Dir, true)
		} finally {
			if !IsObject(SavedAbortTimer) && IsObject(_HTTP_CURL_ABORT_TIMER)
				SetTimer(_HTTP_CURL_ABORT_TIMER, 0)
			if !IsObject(SavedCleanupTimer) && IsObject(_HTTP_CURL_CLEANUP_TIMER)
				SetTimer(_HTTP_CURL_CLEANUP_TIMER, 0)
			_HTTP_CURL_ABORT_TIMER := SavedAbortTimer, _HTTP_CURL_CLEANUP_TIMER := SavedCleanupTimer
			_LayoutCatalogueLast := SavedLast
			Critical(PreviousCritical)
		}
	}
}
for _LRDC_ResumeMode in ["late-poll", "admission"]
	Test("layout registry custody: " . _LRDC_ResumeMode . " fences the retired request after scheduling failure (layout-registry-request-recovery)",
		_LRDC_RequestRetirement.Bind(_LRDC_ResumeMode))

; These public controls deliberately use no new custody API, so they can run
; unchanged on the original driver as well as the owned-output implementation.
_LRDC_SiblingCollision(Kind, Foreign) {
	global _LayoutCatalogueRefreshSequence, _LayoutCatalogueLast
	PreviousCritical := Critical("On"), SavedLast := _LayoutCatalogueLast
	Dir := _LCR_Directory(), Results := [], Log := [], Factories := 0
	Wire := "foreign registry source é`r`n", Stage := ""
	if Kind == "index" {
		Stage := Dir . LayoutRegistry_Settings()["index_file"] . LAYOUT_REGISTRY_PARTIAL_SUFFIX
			. "." . A_ScriptHwnd . "_" . (_LayoutCatalogueRefreshSequence + 1)
		Served := Map(LayoutRegistry_RawUrl(LayoutRegistry_Settings()["index_file"]),
			Map("status", 200, "body", '{"layouts":[]}', "etag", ""))
	} else {
		Entry := LayoutCatalogue_Entry(_LCT_Index(), "ergol")
		AssertTrue(Entry.Has("extension"), "the real shared entry must exercise the extension transport")
		Stage := Dir . Entry["id"] . ".extension.download"
		Served := Map(LayoutRegistry_RawUrl(LayoutRegistry_Settings()["index_file"]),
			Map("status", 200, "body", _LayoutCatalogueJson(Map("layouts", [Entry])), "etag", ""),
			LayoutRegistry_RawUrl(Entry["file"]), Map("status", 200, "body", _LCT_LayoutText("ergol"), "etag", ""))
		for Item in Entry["extension"]["files"]
			Served[LayoutRegistry_RawUrl(Item["file"])] := Map("status", 200,
				"body", _LCT_Read(_LCT_RegistryDir() . StrReplace(Item["file"], "/", "\")), "etag", "")
	}
	Factory() {
		Factories += 1
		return _LCT_FakeRequest(Served, Log, false)
	}
	try {
		if Foreign
			AssertTrue(FSWriteCreateDurable(Stage, Wire))
		Before := _LCT_StageSnapshot(Stage)
		Transport := Map("request", Factory,
			"resolve_proxy", (Urls, Callback) => Callback.Call(_LCT_NoProxy(Urls)),
			"schedule", (Fn, Delay) => Fn.Call())
		if Kind == "index"
			LayoutCatalogue_Refresh(Dir, (Outcome) => Results.Push(Outcome), Transport, 0, false)
		else
			LayoutCatalogue_Install("ergol", Dir, (Params*) => Results.Push(Params), Transport, 0, "", false)
		AssertEqual(1, Results.Length, "each actual public operation must complete exactly once")
		AssertEqual(0, LayoutCatalogue_Busy())
		if Foreign
			AssertEqual(Before, _LCT_StageSnapshot(Stage), "the actual " . Kind . " consumer cannot delete a foreign native stage")
		else
			AssertFalse(FileExist(Stage), "a completed public transfer retires its own exact stage")
		if Kind == "index" {
			AssertEqual(Foreign ? 0 : 1, Factories, "collision admission precedes the actual request factory")
			if Foreign {
				AssertTrue(Results[1]["error"] is Map)
				AssertFalse(FileExist(Dir . LayoutRegistry_Settings()["index_file"]))
			} else {
				AssertEqual("network", Results[1]["source"])
				AssertEqual('{"layouts":[]}', FSReadUtf8Exact(Dir . LayoutRegistry_Settings()["index_file"]))
			}
		} else {
			AssertEqual(!Foreign, Results[1][1], "ordinary extension installation succeeds and a foreign stage visibly refuses")
			if Foreign {
				AssertEqual(2, Factories, "extension collision is refused after only the real index and layout requests")
				AssertTrue(Results[1].Length >= 3 && Results[1][2] != "")
				AssertFalse(FileExist(Dir . "ergol.keylayout"))
				AssertFalse(FileExist(Dir . LayoutRegistry_Settings()["installed_file"]))
			} else {
				LayoutRegistry_Verify(Entry, FSReadUtf8Exact(Dir . "ergol.keylayout"))
				AssertTrue(LayoutCatalogue_ReadInstalled(Dir).Has("ergol"))
			}
		}
	} finally {
		try DirDelete(Dir, true)
		finally {
			_LayoutCatalogueLast := SavedLast
			Critical(PreviousCritical)
		}
	}
}
for _LRDC_Sibling in ["index", "extension"]
	for _LRDC_Foreign in [false, true]
		Test("layout registry sibling: " . _LRDC_Sibling . " foreign=" . _LRDC_Foreign
			. " preserves native stage ownership (layout-registry-sibling-stage)",
			_LRDC_SiblingCollision.Bind(_LRDC_Sibling, _LRDC_Foreign))

_LRDC_SnapshotRetry() {
	Dir := _LCR_Directory(), Stage := Dir . "response.download", Owner := 0, Captured := 0
	Boundary := FSHandleSnapshot, Injected := false
	AssertFalse(Boundary.HasOwnProp("Call"))
	Observe(Self, Handle) {
		if Handle == Owner.Pin.Handle && !Injected {
			Injected := true
			return Map("ok", false)
		}
		Self.DeleteProp("Call")
		try return Self.Call(Handle)
		finally Self.DefineProp("Call", {Call: Observe})
	}
	try {
		Owner := _LayoutRegistryDownload(Stage)
		_LCT_WriteRaw(Stage, _LRDC_Wire())
		Captured := FSHandleSnapshot(Owner.Pin.Handle)
		AssertTrue(Captured.Get("ok", false))
		Owner.Retired := true
		Boundary.DefineProp("Call", {Call: Observe})
		AssertFalse(Owner.ReadText(4096), "a real metadata refusal cannot admit a readable claim")
		AssertTrue(Injected)
		AssertTrue(FSHandleSnapshot(Owner.Pin.Handle).Get("ok", false), "the initial refusal must retain the actual creation pin")
		Boundary.DeleteProp("Call")
		AssertEqual(_LRDC_Wire(), Owner.ReadText(4096), "a transient snapshot failure must be retried before caching its receipt")
		AssertTrue(Owner.Remove())
		AssertFalse(FileReadActivityBusy(Owner.Path))
	} finally {
		if Boundary.HasOwnProp("Call")
			Boundary.DeleteProp("Call")
		; An unfixed failed comparison may already have closed the pin and opened
		; an unvalidated claim. Restore only this fixture's independently captured
		; identity for terminal cleanup, after the behavioral oracle has failed.
		if IsObject(Owner) && IsObject(Captured) && Captured.Get("ok", false)
				&& IsObject(Owner.Expected) && !Owner.Expected.Get("ok", false)
			Owner.Expected := Captured
		_LRDC_Finish(Owner, Dir)
	}
}
Test("layout registry custody: a transient failed snapshot does not poison native retry (layout-registry-custody-review)",
	_LRDC_SnapshotRetry)

_LRDC_CallbackReentry(Kind) {
	global _LayoutCatalogueLast
	SavedLast := _LayoutCatalogueLast
	OuterDir := _LCR_Directory(), InnerDir := _LCR_Directory(), OuterResults := [], InnerResults := [], Log := []
	OuterPrefix := StrLower(RTrim(FSResolveDirectoryPath(OuterDir), "\") . "\")
	InnerWire := '{"layouts":[],"witness":"inner"}'
	InnerServed := Map(LayoutRegistry_RawUrl(LayoutRegistry_Settings()["index_file"]),
		Map("status", 200, "body", InnerWire, "etag", ""))
	if Kind == "index" {
		OuterWire := '{"layouts":[],"witness":"outer"}'
		OuterServed := Map(LayoutRegistry_RawUrl(LayoutRegistry_Settings()["index_file"]),
			Map("status", 200, "body", OuterWire, "etag", ""))
		StageNeedle := LayoutRegistry_Settings()["index_file"] . LAYOUT_REGISTRY_PARTIAL_SUFFIX . "."
	} else {
		Entry := JsonParse(_LayoutCatalogueJson(LayoutCatalogue_Entry(_LCT_Index(), "ergol")))
		if Kind == "layout"
			Entry.Delete("extension")
		OuterWire := _LayoutCatalogueJson(Map("layouts", [Entry]))
		OuterServed := Map(LayoutRegistry_RawUrl(LayoutRegistry_Settings()["index_file"]),
			Map("status", 200, "body", OuterWire, "etag", ""),
			LayoutRegistry_RawUrl(Entry["file"]), Map("status", 200, "body", _LCT_LayoutText("ergol"), "etag", ""))
		if Kind == "extension"
			for Item in Entry["extension"]["files"]
				OuterServed[LayoutRegistry_RawUrl(Item["file"])] := Map("status", 200,
					"body", _LCT_Read(_LCT_RegistryDir() . StrReplace(Item["file"], "/", "\")), "etag", "")
		StageNeedle := Kind == "layout" ? ".keylayout.download" : ".extension.download"
	}
	Boundary := LayoutRegistry_Settings, Injected := false
	AssertFalse(Boundary.HasOwnProp("Call"))
	Observe(Self) {
		Trigger := false
		if !Injected {
			for Current in _LayoutRegistryDownloadOwners() {
				if Current.Retired && !Current.Removed && !Current.Operating
						&& InStr(StrLower(Current.Path), OuterPrefix) == 1 && InStr(Current.Path, StageNeedle) {
					Injected := true
					Trigger := true
					break
				}
			}
		}
		if Trigger
			LayoutCatalogue_Refresh(InnerDir, (Outcome) => InnerResults.Push(Outcome),
				_LCT_Transport(InnerServed, Log), 0, false)
		Self.DeleteProp("Call")
		try return Self.Call()
		finally Self.DefineProp("Call", {Call: Observe})
	}
	try {
		Boundary.DefineProp("Call", {Call: Observe})
		if Kind == "index"
			LayoutCatalogue_Refresh(OuterDir, (Outcome) => OuterResults.Push(Outcome),
				_LCT_Transport(OuterServed, Log), 0, false)
		else
			LayoutCatalogue_Install("ergol", OuterDir, (Params*) => OuterResults.Push(Params),
				_LCT_Transport(OuterServed, Log), 0, "", false)
		Boundary.DeleteProp("Call")
		AssertTrue(Injected, "the actual " . Kind . " consumer must admit reentry after transfer retirement and before its read")
		AssertEqual(1, InnerResults.Length)
		AssertEqual("network", InnerResults[1]["source"], "the independent directory's reentrant request really succeeds")
		AssertEqual(InnerWire, FSReadUtf8Exact(InnerDir . LayoutRegistry_Settings()["index_file"]))
		AssertEqual(1, OuterResults.Length)
		if Kind == "index" {
			AssertEqual("network", OuterResults[1]["source"], "another directory cannot dispose the current callback's response")
			AssertEqual(0, OuterResults[1]["error"])
			AssertEqual(OuterWire, FSReadUtf8Exact(OuterDir . LayoutRegistry_Settings()["index_file"]))
		} else {
			AssertTrue(OuterResults[1][1], "the current callback retains its actual layout or extension output through consumption")
			LayoutRegistry_Verify(Entry, FSReadUtf8Exact(OuterDir . "ergol.keylayout"))
			AssertTrue(LayoutCatalogue_ReadInstalled(OuterDir).Has("ergol"))
		}
		AssertEqual(0, LayoutCatalogue_Busy())
		AssertTrue(LayoutRegistry_PrepareShutdown())
	} finally {
		if Boundary.HasOwnProp("Call")
			Boundary.DeleteProp("Call")
		try {
			AssertTrue(LayoutRegistry_RetireDownloads())
			DirDelete(OuterDir, true)
			DirDelete(InnerDir, true)
		} finally _LayoutCatalogueLast := SavedLast
	}
}
for _LRDC_ReentryKind in ["index", "layout", "extension"]
	Test("layout registry custody: reentrant " . _LRDC_ReentryKind . " callback retains its consumed response (layout-registry-custody-review)",
		_LRDC_CallbackReentry.Bind(_LRDC_ReentryKind))
