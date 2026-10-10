; tests/meta/test_config_recovery_gateway.ahk

; ==============================================================================
; MODULE: Config recovery gateway structural guard
; DESCRIPTION:
; Pins the complete causal order for every staged native consumer: durable write,
; activation, reverse-or-cleanup, retention, atomic publication, then release.
; ==============================================================================

#Requires AutoHotkey v2.0

_CRG_GatewayOwnsEveryRecoveryStage() {
	Built := _DriverFuncBody("ConfigCommitBuilt")
	Body := _DriverFuncBody("_ConfigCommitOwned")
	Writer := _DriverFuncBody("_ConfigInvokeCommitWriter")
	NativeWriter := _DriverFuncBody("TOML_ConfigBatchWrite")
	Assert(Built != "", "ConfigCommitBuilt source must be discoverable")
	Assert(Body != "", "_ConfigCommitOwned source must be discoverable")
	Assert(Writer != "", "_ConfigInvokeCommitWriter source must be discoverable")
	WriterPos := InStr(Body, "_ConfigInvokeCommitWriter(Path, Updates")
	FinalizePos := InStr(Body, "FinalizeFn.Call(", true, WriterPos)
	RollbackPos := InStr(Body,
		"_ConfigInvokeCommitWriter(Path, RollbackUpdates", true, FinalizePos)
	CleanupPos := InStr(Body, "CleanupFn.Call()", true, RollbackPos)
	RetainPos := InStr(Body,
		'_ConfigRunRecoveryRetention(RetainFn, "cleanup_failed"', true, CleanupPos)
	PublishPos := InStr(Body, "PublishFn.Call(", true, RetainPos)
	ReleasePos := InStr(Body, "_ConfigWriteLeaseRelease(", true, PublishPos)
	Assert(WriterPos > 0 && FinalizePos > WriterPos && RollbackPos > FinalizePos
		&& CleanupPos > RollbackPos && RetainPos > CleanupPos
		&& PublishPos > RetainPos && ReleasePos > PublishPos,
		"write -> activate -> reverse/cleanup -> retain -> publish -> release must stay causal")
	for Field in ["rollback_updates", "cleanup", "retain"]
		Assert(InStr(Built, '_ConfigPlanGet(Plan, "' . Field . '"') > 0,
			"built plans must resolve " . Field . " while the lease is held")
	Assert(InStr(Writer, "WriterFn.Call(Path, Updates)") > 0
		&& InStr(Writer, "TOML_ConfigBatchWrite(Path, Updates, [], NativeAdmission)") > 0,
		"forward and reverse writes must share the strict writer gateway")
	Assert(NativeWriter != "", "the actual configuration gateway must retain its shared writer")
	Assert(InStr(NativeWriter,
		'_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write", , , true, NativeAdmission)') > 0,
		"the forward and reverse default writer must reach the same canonical implementation with source admission")
	Assert(InStr(NativeWriter, "_ConfigWriteLeaseOwns(Owner, Path)") > 0
		&& InStr(NativeWriter, "_FSNativeAdmissionAccepted(AdmissionFn)") > 0,
		"the strict shared writer must retain exact path ownership and supplied native admission")
}
Test("config recovery gateway owns every stage before lease release "
	. "(config-recovery-gateway-order)", _CRG_GatewayOwnsEveryRecoveryStage)
