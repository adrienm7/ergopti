; tests/meta/test_hotstrings_ready_contract.ahk
#Requires AutoHotkey v2.0

Test_HotstringsReadyMeansCompleteRegistryAndPreview() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Main := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	RegisterAt := InStr(Main, "RegisterAllHotstrings(false, true)")
	ReceiptAt := InStr(Main, '_BootHotstringsReceipt := RegisterAllHotstrings(false, true)')
	GuardAt := InStr(Main, 'if !(_BootHotstringsReceipt is Map) || !_BootHotstringsReceipt.Get("committed", false)', false, ReceiptAt)
	CompleteAt := InStr(Main, 'if _BootHotstringsReceipt["complete"]', false, GuardAt)
	PartialAt := InStr(Main, 'BootProfile_Mark("Hotstrings registered (common autocorrection unavailable)")', false, CompleteAt)
	Assert(ReceiptAt > 0 && GuardAt > ReceiptAt && CompleteAt > GuardAt && PartialAt > CompleteAt,
		"the sole cold call consumes a committed receipt and classifies partial startup before ready")
	Assert(InStr(Main, 'LoggerWarn("Hotstrings", "Common autocorrection is unavailable', false, CompleteAt) > CompleteAt,
		"optional common refusal remains visible without aborting unrelated app startup")
	Assert(RegExMatch(Main, 'if _BootHotstringsReceipt\["complete"\]\s+BootProfile_Mark\("Hotstrings registered \(HSE complete\)"\)'),
		"only a complete cold receipt may announce the complete HSE registry")
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
