; tests/meta/modules/keystats/test_keystats_webview_epoch.ahk

; ============================================================================== 
; MODULE: Keystats WebView ownership-epoch regression test
; DESCRIPTION:
; A delayed first/full dashboard build must belong to the exact WebView instance
; that armed it. Reopening the same "typing" or "apps" key must make the old
; timer and old bridge callback inert rather than targeting the replacement.
; ============================================================================== 

#Requires AutoHotkey v2.0

_KLWVE_OldTimersAndBridgeCallbacksCannotReachReplacement() {
    Open := _DriverFuncBody("KLWV_Open")
    First := _DriverFuncBody("KLWV_DelayedFirstPush")
    Full := _DriverFuncBody("KLWV_DelayedFullBuild")
    Bridge := _DriverFuncBody("KLWV_OnWebMessage")
    Range := _DriverFuncBody("KLWV_OnRangeBuildTerminal")
    Current := _DriverFuncBody("KLWV_IsCurrent")

    Assert(InStr(Open, "Epoch := ++KLWV.epoch") > 0,
        "each KLWV_Open must allocate a monotonic instance epoch")
    Assert(InStr(Open, '"epoch", Epoch') > 0,
        "the published KLWV window entry must retain its owning epoch")
    Assert(InStr(Open, "KLWV_DelayedFirstPush.Bind(which, Epoch)") > 0,
        "the delayed first-push timer must capture the owner epoch")
    Assert(InStr(First, "KLWV_IsCurrent(which, Epoch)") > 0
            && InStr(First, "KLWV_DelayedFullBuild.Bind(which, Epoch, 0)") > 0,
        "first-push must validate and propagate the owner epoch to full build")
    Assert(InStr(Full, "KLWV_IsCurrent(which, Epoch)") > 0,
        "full build must reject a timer from a closed/reopened host")
    Identity := _DriverFuncBody("WebView_SameCore")
    OwnsMessage := _DriverFuncBody("_KLWV_OwnsMessage")
    Ollama := _DriverFuncBody("OllamaWV_OnWebMessage")
    Assert(_KLWVE_SenderIdentityContract(Bridge, Identity, OwnsMessage, Ollama),
        "WebMessage callbacks must authenticate native Core identity and retain pure RAM session fences")
	Assert(InStr(Bridge, 'KLPF_RequestRange(which, entry["metrics_dir"], query, Epoch') > 0
			&& InStr(Range, "KLWV_IsCurrent(which, Epoch)") > 0,
		"range worker completion must capture and validate its originating dashboard epoch")
    Assert(InStr(Current, 'entry["epoch"] = Epoch') > 0,
        "KLWV_IsCurrent must compare against the live entry epoch")
}

Test("keystats WebView: old timers and messages cannot mutate a reopened dashboard",
    _KLWVE_OldTimersAndBridgeCallbacksCannotReachReplacement)


_KLWVE_SenderIdentityContract(Bridge, Identity, OwnsMessage, Ollama) {
	if Bridge == "" || Identity == "" || OwnsMessage == "" || Ollama == ""
		return false
	BridgeCode := _DriverMaskNonCode(&Bridge)
	IdentityCode := _DriverMaskNonCode(&Identity)
	OwnsCode := _DriverMaskNonCode(&OwnsMessage)
	OllamaCode := _DriverMaskNonCode(&Ollama)
	; No unconditional positive return can bypass native identity admission.
	TrueReturns := 0, Position := 1
	while RegExMatch(IdentityCode, "\breturn[ `t]+true\b", &Found, Position) {
		TrueReturns += 1
		Position := Found.Pos + Found.Len
	}
	UnknownDeclaration := 'IUnknown := "{00000000-0000-0000-C000-000000000046}"'
	UnknownPosition := InStr(IdentityCode, "IUnknown :=")
	SenderCheck := InStr(BridgeCode, "if !WebView_SameCore(sender, View)")
	CapturedView := InStr(Bridge, 'View := entry["webview"]')
	SourceRead := InStr(Bridge, "Source := args.Source")
	Recheck := InStr(Bridge, "if !_KLWV_OwnsMessage(", , SenderCheck + 1)
	OllamaCheck := InStr(OllamaCode, "if !WebView_SameCore(sender, captured_view)")
	OllamaRead := InStr(Ollama, "args.TryGetWebMessageAsString()")
	OllamaFence := InStr(Ollama, "captured_epoch != _OllamaWV_Epoch", , OllamaCheck + 1)
	return InStr(Bridge, "KLWV_IsCurrent(which, Epoch)") > 0
		&& CapturedView > 0 && SenderCheck > CapturedView
		&& Recheck > SenderCheck && SourceRead > Recheck
		&& TrueReturns == 0
		&& RegExMatch(IdentityCode, "m)^[ `t]*if !SenderIsCore && !ExpectedIsCore\R[ `t]+return Sender == Expected[ `t]*$")
		&& InStr(IdentityCode, "Sender is WebView2.Core") > 0
		&& InStr(IdentityCode, "Expected is WebView2.Core") > 0
		&& InStr(IdentityCode, "if !SenderIsCore || !ExpectedIsCore || !Sender.Ptr || !Expected.Ptr") > 0
		&& UnknownPosition > 0
		&& SubStr(Identity, UnknownPosition, StrLen(UnknownDeclaration)) == UnknownDeclaration
		&& InStr(IdentityCode, "SenderUnknown := ComObjQuery(Sender, IUnknown)") > 0
		&& InStr(IdentityCode, "ExpectedUnknown := ComObjQuery(Expected, IUnknown)") > 0
		&& InStr(IdentityCode, "ComObjValue(SenderUnknown) == ComObjValue(ExpectedUnknown)") > 0
		&& InStr(OwnsMessage, "_KLWV_OwnsDelivery(which, Entry, Epoch)") > 0
		&& InStr(OwnsMessage, 'Entry.Get("webview", 0) == View') > 0
		&& InStr(OwnsCode, "ComObjQuery(") == 0
		&& InStr(OwnsCode, "WebView_SameCore(") == 0
		&& InStr(Ollama, "captured_view := _OllamaWV_WebView") < OllamaCheck
		&& OllamaCheck > 0 && OllamaFence > OllamaCheck && OllamaRead > OllamaFence
		&& InStr(Ollama, "captured_view == _OllamaWV_WebView") > 0
}

_KLWVE_SenderIdentityMutants() {
	Bridge := _DriverFuncBody("KLWV_OnWebMessage")
	Identity := _DriverFuncBody("WebView_SameCore")
	OwnsMessage := _DriverFuncBody("_KLWV_OwnsMessage")
	Ollama := _DriverFuncBody("OllamaWV_OnWebMessage")
	AssertTrue(_KLWVE_SenderIdentityContract(Bridge, Identity, OwnsMessage, Ollama))
	for BrokenBridge in ["", StrReplace(Bridge, "if !WebView_SameCore(sender, View)", "if false"),
		StrReplace(Bridge, "WebView_SameCore(sender, View)", "WebView_SameCore(sender, sender)"),
		StrReplace(Bridge, "KLWV_IsCurrent(which, Epoch)", "true")]
		AssertFalse(_KLWVE_SenderIdentityContract(BrokenBridge, Identity, OwnsMessage, Ollama))
	for BrokenIdentity in ["", "return true`n" . Identity, StrReplace(Identity, "Sender is WebView2.Core", "IsObject(Sender)"),
		StrReplace(Identity, "ComObjQuery(Sender, IUnknown)", "Sender.Ptr"),
		StrReplace(Identity, "{00000000-0000-0000-C000-000000000046}", "not-IUnknown"),
		StrReplace(Identity, "if !SenderIsCore && !ExpectedIsCore", "if Sender == Expected"),
		StrReplace(Identity, " || !Sender.Ptr || !Expected.Ptr", "")]
		AssertFalse(_KLWVE_SenderIdentityContract(Bridge, BrokenIdentity, OwnsMessage, Ollama))
	AssertFalse(_KLWVE_SenderIdentityContract(Bridge, Identity,
		StrReplace(OwnsMessage, 'Entry.Get("webview", 0) == View', "true"), Ollama))
	AssertFalse(_KLWVE_SenderIdentityContract(Bridge, Identity, OwnsMessage,
		StrReplace(Ollama, "WebView_SameCore(sender, captured_view)", "WebView_SameCore(sender, sender)")))
}
Test("WebView identity: sender ownership guard rejects independent mutants (webview-core-identity)",
	_KLWVE_SenderIdentityMutants)
