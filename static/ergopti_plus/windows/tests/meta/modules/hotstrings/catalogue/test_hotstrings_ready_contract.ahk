; tests/meta/modules/hotstrings/catalogue/test_hotstrings_ready_contract.ahk
#Requires AutoHotkey v2.0

Test_HotstringsReadyMeansCompleteRegistryAndPreview() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Main := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	RegisterAt := InStr(Main, "RegisterAllHotstrings(true, true)")
	ReceiptAt := InStr(Main, '_BootHotstringsReceipt := RegisterAllHotstrings(true, true)')
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
		"every hotstring registers, and the emoji/symbol rank is reserved, before ready")
	Assert(IndexAt > RegisterAt and IndexAt < ReadyAt,
		"the prefix preview index must be complete before ready")
	SlicesAt := InStr(Main, "HSE_DeferredRegistrationStart()")
	Assert(SlicesAt > ReadyAt,
		"the emoji/symbol rows register in slices that start after ready")
	Assert(!InStr(Main, "SetTimer(RegisterEmojisSymbolsDeferred"),
		"boot must not register the emoji/symbol sections as one post-ready block")
	; The rank: the deferral reserves the block between the text expansion and the
	; dynamic hotstrings, where the sections register inline.
	Expansion := _DriverFuncBody("_HS_RegisterTextExpansionAndDynamic")
	DeferAt := InStr(Expansion, "RegisterEmojisSymbolsDeferred()")
	Assert(DeferAt > InStr(Expansion, "_RegisterTextExpansionSections()")
		and DeferAt < InStr(Expansion, "_DynHS_RegisterAll()"),
		"the emoji/symbol rank is reserved after the text expansion and before the dynamic hotstrings and repeat key")
	Assert(InStr(_DriverFuncBody("RegisterEmojisSymbolsDeferred"), "HSE_DeferRegistration("),
		"the boot pass queues the rows behind a reserved sequence block")
}

Test("hotstrings: ready publishes the registry and preview index, emoji/symbol rows at their reserved rank", Test_HotstringsReadyMeansCompleteRegistryAndPreview)
