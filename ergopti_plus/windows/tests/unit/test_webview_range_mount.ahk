; tests/unit/test_webview_range_mount.ahk

; ==============================================================================
; MODULE: WebView Range Mount Tests
; DESCRIPTION: HTTPS preparation preserves exact stage ownership across failures.
; ==============================================================================

#Requires AutoHotkey v2.0

_WRM_Prepare(Mode, View, Lines, Unhandled, Failure) {
	Stage := _CTU_NewPath()
	Directory := Stage . ".mount"
	Entry := Map("epoch", 51, "webview", View)
	KLWV.windows := Map("typing", Entry)
	try {
		AssertTrue(FSWrite(Stage, "synthetic stage"))
		if Mode = "collision" {
			DirCreate(Directory)
			AssertTrue(FSWrite(Directory . "\foreign.txt", "preserve"))
		} else if Mode = "mapping-failure"
			View.MappingFailure := Error("synthetic mapping refusal")
		else if Mode = "reentry"
			View.OnMap := (*) => KLWV_Close("typing")
		else if Mode = "pause"
			View.OnMap := (*) => Suspend(true)
		Accepted := KLWV_OnRangeBuildTerminal("typing", 51, 42, "ok", Stage)
		AssertEqual(Mode = "success" || Mode = "pause", Accepted)
		if Mode = "success" {
			Owner := Entry["range_stage"]
			AssertFalse(FSExists(Stage), "the completed stage must move, not be copied")
			AssertEqual("synthetic stage", FileRead(Owner["stage"], "UTF-8"))
			AssertEqual(Directory, View.Mappings[Owner["host"]]["directory"])
			AssertEqual(KLWV_HOST_ACCESS_ALLOW, View.Mappings[Owner["host"]]["access"])
			AssertContains(View.Scripts[1], "https://" . Owner["host"] . "/range.json")
			KLWV_RetireRangeStage(Entry)
		} else {
			AssertEqual(0, View.Scripts.Length)
			AssertFalse(Entry.Has("range_stage"))
			AssertFalse(FSExists(Stage))
			if Mode = "pause" {
				AssertEqual(0, View.Messages.Length)
				AssertEqual("canceled", Entry["pending_range_terminal"]["status"])
				Suspend(false)
				KLWV_FlushPendingRangeTerminals()
				AssertEqual("canceled", KL_JsonDecode(View.Messages[1])["status"])
			} else if Mode != "reentry"
				AssertEqual("failed", KL_JsonDecode(View.Messages[1])["status"])
		}
		AssertEqual(0, View.Mappings.Count)
		if Mode = "collision"
			AssertEqual("preserve", FileRead(Directory . "\foreign.txt", "UTF-8"))
		else
			AssertFalse(DirExist(Directory), "owned mount cleanup must leave no directory")
	} finally {
		KLWV_RetireRangeStage(Entry)
		FSDelete(Stage)
		if Mode = "collision" {
			FSDelete(Directory . "\foreign.txt")
			DirDelete(Directory)
		}
	}
}
for Mode in ["success", "collision", "mapping-failure", "reentry", "pause"]
	Test("WebView range mount: " . Mode . " preserves ownership (range-mount)",
		_WVSO_WithFixture.Bind(_WRM_Prepare.Bind(Mode)))

_WRM_Orphans() {
	Root := _CTU_NewPath() . ".dir"
	DeadPid := 2147483647
	AssertEqual(0, ProcessExist(DeadPid))
	Suffix := "." . KLPF_NewOwnerId() . ".1.json.mount"
	DirCreate(Root)
	Paths := []
	try {
		for Pid in [DeadPid, KLPFWorker.process_id, "0", "4294967296"] {
			Directory := Root . "\ergopti_metrics_range_typing.stage." . Pid . Suffix
			DirCreate(Directory)
			FSWrite(Directory . "\range.json", "owned synthetic stage")
			Paths.Push(Directory)
		}
		Unknown := Root . "\ergopti_metrics_range_typing.stage." . DeadPid . ".unknown.1.json.mount"
		DirCreate(Unknown)
		FSWrite(Unknown . "\range.json", "unknown ownership")
		Paths.Push(Unknown)
		AssertTrue(KLPF_ReapOrphanRangeMounts(Root))
		AssertFalse(DirExist(Paths[1]), "a proven dead process must release its mount")
		for Index, Directory in Paths {
			if Index > 1
				AssertTrue(FSExists(Directory . "\range.json"), "live or invalid ownership must survive")
		}
	} finally {
		for Directory in Paths {
			FSDelete(Directory . "\range.json")
			if DirExist(Directory)
				DirDelete(Directory)
		}
		DirDelete(Root)
	}
}
Test("WebView range mount: startup cleanup requires a dead owner (range-mount)", _WRM_Orphans)
