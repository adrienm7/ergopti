; tests/meta/test_hotstrings_ready_contract.ahk
#Requires AutoHotkey v2.0

Test_HotstringsReadyMeansCompleteRegistryAndPreview() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Main := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	RegisterAt := InStr(Main, "RegisterAllHotstrings(false)")
	IndexAt := InStr(Main, "HotstringPrefixWatcherRebuildIndex()", false, RegisterAt)
	ReadyAt := InStr(Main, 'LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")')
	Assert(RegisterAt > 0 and RegisterAt < ReadyAt,
		"all emoji/symbol hotstrings must register before ready, not on a post-ready timer")
	Assert(IndexAt > RegisterAt and IndexAt < ReadyAt,
		"the prefix preview index must be complete before ready")
	Assert(!InStr(Main, "SetTimer(RegisterEmojisSymbolsDeferred"),
		"boot must not arm an emoji/symbol registration timer after ready")
}

Test("hotstrings: ready publishes a complete emoji/symbol registry and preview index", Test_HotstringsReadyMeansCompleteRegistryAndPreview)
