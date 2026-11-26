; tests/unit/ai/servers/test_local_server_sweep_admission.ahk

; ==============================================================================
; MODULE: Local Server Sweep Admission
; DESCRIPTION:
; A sweep's own ports reuse the registry comparison of its last capture, which is
; what keeps a join off 1,500 deep comparisons; every other source operation still
; compares, so a changed registry is refused there at once.
; ==============================================================================

#Requires AutoHotkey v2.0

_LSSA_Body(World) {
	global ConfigMigrateRegistryDeepCompares
	AssertTrue(FSWriteDurable(World.ConfigPath, World.ConfigImage))
	AssertTrue(ConfigSchemaCanPrepareWrite(World.ConfigPath))
	World.Capture()
	Ports := World.Owner.Ports()
	Before := ConfigMigrateRegistryDeepCompares
	loop 5
		AssertTrue(Ports["admit"].Call(), "a sweep admission holds")
	AssertEqual(Before, ConfigMigrateRegistryDeepCompares, "a sweep's admissions reuse the capture's comparison")
	AssertTrue(World.Owner.Admit())
	Assert(ConfigMigrateRegistryDeepCompares > Before, "a full admission compares the registry again")
	Step := ConfigMigrateShippedRegistry()["steps"][1], Reason := Step["reason"]
	Step["reason"] := Reason . " changed"
	try {
		AssertFalse(World.Owner.Admit(), "a full admission refuses a changed registry")
		AssertFalse(Ports["capture_source"].Call(), "a sweep's capture refuses a changed registry")
	} finally Step["reason"] := Reason
	AssertTrue(World.Owner.Admit(), "the restored registry is admitted again")
}
Test("Local sweep admission: reuses the capture's comparison, and a capture still refuses a changed registry",
	_LSP_WithWorld.Bind(_LSSA_Body))
