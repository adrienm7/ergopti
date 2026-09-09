; static/ergopti_plus/windows/tests/unit/test_metrics_prefetch_orphans.ahk

; ==============================================================================
; MODULE: Metrics Prefetch Orphan Tests
; DESCRIPTION: Reap only proven dead-owner private stages and request receipts.
; ==============================================================================

#Requires AutoHotkey v2.0

_MPO_OnlyDeadOwnersAreReaped() {
	_KLRDC_Reset()
	try {
		Root := RTrim(_KLRDC_Root(), "\")
		DeadPid := 2147483647
		AssertEqual(0, ProcessExist(DeadPid), "fixture PID must be demonstrably absent")
		AssertEqual(KLPFWorker.process_id, ProcessExist(KLPFWorker.process_id),
			"positive control: the current owner must be alive")
		Digest := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
		Canonical := Root . "\ergopti_metrics_prefetch_" . Digest . "_typing.json"
		Guid := KLPF_NewOwnerId()
		DeadStage := Canonical . ".stage." . DeadPid . "." . Guid . ".7"
		LiveStage := Canonical . ".stage." . KLPFWorker.process_id . "." . Guid . ".8"
		CurrentStage := Canonical . ".stage." . KLPFWorker.process_id . "." . KLPFWorker.owner_id . ".9"
		Legacy := Canonical . ".stage." . Guid . ".10"
		Foreign := Root . "\unrelated.stage." . DeadPid . "." . Guid . ".11.request"
		Malformed := Canonical . ".stage.0." . Guid . ".12.request"
		ExtraSuffix := DeadStage . ".request.other"
		AtomicSuffix := "." . A_ScriptHwnd . "-1.tmp"
		Keep := [Canonical, LiveStage, LiveStage . ".request", CurrentStage, CurrentStage . ".request",
			Legacy, Legacy . ".request", Foreign, Malformed, ExtraSuffix,
			LiveStage . AtomicSuffix, LiveStage . ".request" . AtomicSuffix,
			Legacy . AtomicSuffix, DeadStage . ".1-0.tmp", DeadStage . ".1-1.tmp.extra"]
		Orphans := [DeadStage, DeadStage . ".request", DeadStage . AtomicSuffix,
			DeadStage . ".request" . AtomicSuffix]
		for Path in Keep
			AssertTrue(FSWriteCreateDurable(Path, "retained") != 0)
		for Path in Orphans
			AssertTrue(FSWriteCreateDurable(Path, "orphan") != 0)
		AssertTrue(KLPF_ReapOrphanPrefetchStages(Root))
		for Path in Orphans
			AssertFalse(FSExists(Path), "dead-owner payloads, requests and atomic scratch must be removed")
		for Path in Keep
			AssertEqual("retained", FileRead(Path, "UTF-8"), "unproven or live ownership must remain untouched")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("metrics prefetch: startup cleanup preserves live and unproven owners (metrics-prefetch-orphans)",
	_KLRDC_CheckTeardown.Bind(_MPO_OnlyDeadOwnersAreReaped))
