; tests/unit/test_crash_mapping_drain_reentry.ahk

; ==============================================================================
; MODULE: Crash Mapping Drain Reentry Tests
; DESCRIPTION: Pending native cleanup must continue to block mapping admission.
; ==============================================================================

#Requires AutoHotkey v2.0

class _CMDR_Native {
	__New(Phase) {
		this.Phase := Phase
		this.Accept := false
		this.Probe := false
		this.Probed := false
		this.Refused := false
		this.NewMapping := 0
	}

	UnmapView(View) => this.Attempt("unmap")
	CloseHandle(Handle) => this.Attempt("close")

	Attempt(Phase) {
		global _CrashReportWorkerSerial
		if Phase != this.Phase
			return true
		if this.Probe && !this.Probed {
			this.Probed := true
			try this.NewMapping := _CrashReportWorkerCreateMapping("{}", ++_CrashReportWorkerSerial)
			catch Error as Failure
				this.Refused := Failure.Message == "Previous crash-report mapping cleanup is still pending"
		}
		return this.Accept
	}
}

_CMDR_PendingCleanupBlocksAdmission(Phase) {
	global _CrashReportWorkerMappingCleanupDebt, _CrashReportWorkerSerial
	Mapping := _CRWT_TestMapping(Phase == "unmap" ? 1302 : 0)
	Native := _CMDR_Native(Phase)
	Recovered := 0
	PreviousCritical := A_IsCritical
	try {
		AssertFalse(_CrashReportWorkerCloseMapping(Mapping, Native))
		AssertEqual(1, _CrashReportWorkerMappingCleanupDebt.Length)
		Native.Probe := true
		AssertFalse(_CrashReportWorkerDrainMappingDebt(Native))
		AssertEqual(PreviousCritical, A_IsCritical, "a refused drain must restore interruptibility")
		AssertTrue(Native.Probed, "the admission attempt must occur during native cleanup")
		AssertFalse(IsObject(Native.NewMapping),
			"a new mapping must not be admitted while an earlier cleanup receipt is pending")
		AssertTrue(Native.Refused, "admission must fail specifically because cleanup remains owned")
		AssertEqual(1, _CrashReportWorkerMappingCleanupDebt.Length)
		AssertEqual(1301, Mapping["handle"])
		AssertFalse(Mapping["closed"])
		Native.Accept := true
		AssertTrue(_CrashReportWorkerDrainMappingDebt(Native), "cleanup must remain retryable")
		AssertTrue(Mapping["closed"])
		AssertEqual(PreviousCritical, A_IsCritical, "a successful drain must restore interruptibility")
		Recovered := _CrashReportWorkerCreateMapping("{}", ++_CrashReportWorkerSerial)
		AssertTrue(IsObject(Recovered), "confirmed cleanup must allow a new native mapping")
	} finally {
		try {
			for Owned in [Native.NewMapping, Recovered]
				if IsObject(Owned)
					AssertTrue(_CrashReportWorkerCloseMapping(Owned),
						"the fixture must release its exact native mapping")
		} finally {
			Native.Accept := true
			AssertTrue(_CrashReportWorkerDrainMappingDebt(Native))
		}
	}
}

for Phase in ["unmap", "close"]
	Test("crash mapping: " . Phase . " retry blocks nested admission (crash-mapping-drain-reentry)",
		_CRWT_WithMappingDebtIsolated.Bind(_CMDR_PendingCleanupBlocksAdmission.Bind(Phase)))
