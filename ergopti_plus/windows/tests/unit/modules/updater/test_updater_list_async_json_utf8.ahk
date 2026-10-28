; tests/unit/modules/updater/test_updater_list_async_json_utf8.ahk

; ==============================================================================
; MODULE: List Async Managed JSON Encoding Tests
; DESCRIPTION:
; Use the actual async request registry, managed byte receipt, completion poll
; and callback. A late poll must remain inert after exact terminal retirement.
; ==============================================================================

#Requires AutoHotkey v2.0

_ULSJ_Observe(Results, Json, Request, Terminal) {
	Results.Push({Json: Json, Request: Request, Terminal: Terminal})
}

_ULSJ_Fetch(State) {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND
	Context := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND)
	Results := []
	Owner := _Updater_FetchReleasesListJsonAsync("main", Context, _ULSJ_Observe.Bind(Results))
	if State.Has("error")
		throw State["error"]
	AssertTrue(IsObject(Owner), "the genuine async API must return its exact registry receipt")
	AssertTrue(Owner.Record["http"] == State["request"], "the actual request record must retain its exact facade")
	AssertEqual(1, Results.Length, "the real completion poll must invoke exactly one current callback")
	AssertTrue(Results[1].Request == Context, "the real callback must carry the exact original request provenance")
	AssertEqual(0, Results[1].Terminal, "a current response must retain its original non-cancellation terminal")
	AssertFalse(_Updater_AsyncRequestOwned(Owner), "the genuine terminal must retire its exact registry owner")
	Late := _Updater_PollReleasesListAsync(Owner.Id)
	FileAppend("RECEIPT updater-json-async consumer=list-async callbacks=" . Results.Length
		. " terminal=" . Results[1].Terminal . " late_return=" . Late
		. " owner_current=" . _Updater_AsyncRequestOwned(Owner) . "`n", "*")
	AssertFalse(Late, "a late poll must refuse the retired record")
	AssertEqual(1, Results.Length, "a late poll must never redeliver the callback")
	AssertFalse(IsObject(Owner.Record.Get("poll_fn", 0)), "the synchronous-ready poll must leave no deferred timer")
	return Results[1].Json
}

for Mode in ["invalid", "valid", "replacement"]
	Test("updater JSON encoding: list-async " . Mode . " (updater-list-async-json-utf8)",
		_UGH_Case.Bind("list-async", _ULSJ_Fetch, true, false, Mode))
