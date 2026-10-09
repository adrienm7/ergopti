; tests/meta/test_hse_physical_suppression_provenance.ahk
; MODULE: HSE Physical Suppression Provenance Meta Test
#Requires AutoHotkey v2.0

_HPSP_PhysicalInputBypassesSyntheticSuppress() {
    Engine := _DriverFuncBody("HSE_FeedChar")
    Backspace := _DriverFuncBody("HSE_FeedBackspace")
    Reset := _DriverFuncBody("HSE_FeedReset")
	CharHook := _DriverFuncBody("_OnPrefixChar")
	KeyDownHook := _DriverFuncBody("_OnPrefixKeyDown")
	BackspacePair := _DriverFuncBody("_PrefixFeedBackspace")
	BackspaceCommit := _DriverFuncBody("_PrefixCommitBackspace")
	ResetPair := _DriverFuncBody("_PrefixInvalidateInputContext")
	ResetCommit := _DriverFuncBody("_PrefixCommitInputContext")
    Assert(InStr(Engine, "IsPhysical := false") > 0, "HSE_FeedChar must carry explicit event provenance")
    Assert(InStr(Engine, "HSE_Suppressed and !IsPhysical") > 0, "synthetic suppression must not reject physical input")
    Assert(InStr(CharHook, "HSE_FeedChar(Char, true)") > 0, "InputHook OnChar must mark observed input physical")
    Assert(InStr(Backspace, "IsPhysical := false") > 0 && InStr(Backspace, "HSE_Suppressed and !IsPhysical") > 0,
        "HSE_FeedBackspace must preserve physical backspaces during synthetic suppression")
	Assert(InStr(KeyDownHook, "_PrefixFeedBackspace()") > 0
		and InStr(BackspacePair, "_PrefixCommitBackspace()") > 0
		and InStr(BackspaceCommit, "HSE_FeedBackspace(true)") > 0,
		"InputHook keydown must route Backspace through the paired helper that marks it physical")
    Assert(InStr(Reset, "IsPhysical := false") > 0 && InStr(Reset, "HSE_Suppressed and !IsPhysical") > 0,
        "HSE_FeedReset must preserve physical navigation resets during synthetic suppression")
	Assert(InStr(KeyDownHook, "_PrefixInvalidateInputContext(") > 0
		and InStr(ResetPair, "_PrefixCommitInputContext(FocusToken, KnownBoundary)") > 0
		and InStr(ResetCommit, "HSE_FeedReset(KnownBoundary, true)") > 0,
		"InputHook navigation resets must use the paired helper with physical provenance")
}
Test("HSE: physical input bypasses synthetic suppression by provenance", _HPSP_PhysicalInputBypassesSyntheticSuppress)
