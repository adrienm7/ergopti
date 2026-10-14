; modules/llm/local_model_offer.ahk

; ==============================================================================
; MODULE: Missing Local Model Offer
; DESCRIPTION:
; Offers the existing Ollama download command only after explicit manual consent.
; Automatic typing only posts a native notice; TrayTip has no click callback.
; ==============================================================================

global _LLM_LocalModelAsking := false
global _LLM_LocalModelNotified := Map()
global _LLM_LocalModelOfferPort := 0

_LLM_LocalModelLabel(Key, Model) {
	return StrReplace(t(Key), "{1}", Model)
}

_LLM_LocalModelConfirm(Title, Body) {
	return Ui_MsgBox(Body, Title, "YesNo Default2 Icon?") == "Yes"
}

_LLM_LocalModelNotify(Body, Title) {
	return NotifierSend(Body, Map("title", Title, "level", "warning"))
}

_LLM_LocalModelInstall(BaseUrl, Model) {
	return _LLM_Menu_PullModel(Model, true, BaseUrl)
}

_LLM_LocalModelTrue(Value) {
	return Value is Integer && Value == true
}

; This private receipt captures the actual admitted origin and installer owner
; before any modal/notification callback. It never borrows a successor flow.
_LLM_LocalModelOfferCapture(Failure, CurrentFn) {
	global _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, _LLM_ManagedBootstrap
	Receipt := Map("origin", Failure["base_url"], "model", Failure["model"],
		"generation", LLM_AuxGeneration(), "flow", _LLM_ManagedBootstrap,
		"port", _LLM_LocalModelOfferPort, "notified", _LLM_LocalModelNotified, "current", CurrentFn)
	Port := Receipt["port"]
	Receipt["confirm"] := _LLM_CurlArtifactPortFn(Port, "confirm", _LLM_LocalModelConfirm)
	Receipt["notify"] := _LLM_CurlArtifactPortFn(Port, "notify", _LLM_LocalModelNotify)
	Receipt["install"] := _LLM_CurlArtifactPortFn(Port, "install", _LLM_LocalModelInstall)
	return _LLM_LocalModelOfferCurrent(Receipt) ? Receipt : 0
}

_LLM_LocalModelOfferCurrent(Receipt) {
	global _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, _LLM_ManagedBootstrap
	if !(Receipt is Map) || A_IsSuspended
		return false
	try {
		CurrentFn := Receipt["current"]
		if HasMethod(CurrentFn, "Call") && !_LLM_LocalModelTrue(CurrentFn.Call())
			return false
		Port := Receipt["port"]
		if _LLM_CurlArtifactPortFn(Port, "confirm", _LLM_LocalModelConfirm) != Receipt["confirm"]
				|| _LLM_CurlArtifactPortFn(Port, "notify", _LLM_LocalModelNotify) != Receipt["notify"]
				|| _LLM_CurlArtifactPortFn(Port, "install", _LLM_LocalModelInstall) != Receipt["install"]
			return false
		; RequestOrigin includes the exact managed listener admission. Comparing
		; against configured localhost would reject a valid managed 127.0.0.1.
		if !LLM_OllamaOriginMatches(Receipt["origin"])
			return false
		return Receipt["generation"] == LLM_AuxGeneration()
			&& Receipt["flow"] == _LLM_ManagedBootstrap
			&& Receipt["port"] == _LLM_LocalModelOfferPort
			&& Receipt["notified"] == _LLM_LocalModelNotified
	} catch
		return false
}

_LLM_LocalModelOfferPublished(Receipt, Callback := 0, *) {
	if !_LLM_LocalModelOfferCurrent(Receipt)
		return false
	if HasMethod(Callback, "Call")
		return Callback.Call()
	return LLM_Menu_RequestBuild("managed_post_pull")
}

_LLM_LocalModelOfferSchedule(Receipt, Callback, Delay) {
	if !_LLM_LocalModelOfferCurrent(Receipt)
		return false
	TimerSetCallback(_LLM_LocalModelOfferPublished.Bind(Receipt, Callback), Delay)
	return true
}

_LLM_LocalModelOfferInstall(Receipt) {
	if !_LLM_LocalModelOfferCurrent(Receipt)
		return false
	InstallFn := Receipt["install"]
	if InstallFn != _LLM_LocalModelInstall
		return InstallFn.Call(Receipt["origin"], Receipt["model"])
	Flow := Receipt["flow"]
	if Flow is OllamaManagedBootstrap && Flow.Runtime.HasOwner()
		return Flow.PullModel(Receipt["model"], _LLM_LocalModelOfferPublished.Bind(Receipt),
			_LLM_LocalModelOfferCurrent.Bind(Receipt))
	; Keep the existing external-server command and fence its delayed rebuild.
	return _LLM_Menu_PullModel(Receipt["model"], true, Receipt["origin"], 0,
		_LLM_LocalModelOfferSchedule.Bind(Receipt))
}

; CurrentFn fences a modal callback that outlives its requesting flow.
LLM_LocalModelOffer(Failure, Automatic := false, CurrentFn := 0) {
	global _LLM_LocalModelAsking
	if !LLM_LocalModelIsMissing(Failure)
		return false
	Receipt := _LLM_LocalModelOfferCapture(Failure, CurrentFn)
	if !(Receipt is Map)
		return true
	Title := t("llm.local_model.missing_title")
	Model := Receipt["model"]
	NoticeKey := Receipt["origin"] . "`n" . LLM_LocalModelNormalize(Model)
	NotifyFn := Receipt["notify"]
	if Automatic {
		if Receipt["notified"].Has(NoticeKey)
			return true
		try {
			Accepted := NotifyFn.Call(_LLM_LocalModelLabel("llm.local_model.missing_notice", Model), Title)
			if _LLM_LocalModelTrue(Accepted) && _LLM_LocalModelOfferCurrent(Receipt)
				Receipt["notified"][NoticeKey] := true
		}
		return true
	}
	if _LLM_LocalModelAsking
		return true
	ConfirmFn := Receipt["confirm"]
	_LLM_LocalModelAsking := true
	Accepted := false
	try Accepted := _LLM_LocalModelTrue(ConfirmFn.Call(Title, _LLM_LocalModelLabel("llm.local_model.missing_body", Model)))
	catch {
		if _LLM_LocalModelOfferCurrent(Receipt)
			try NotifyFn.Call(_LLM_LocalModelLabel("llm.local_model.missing_notice", Model), Title)
	} finally _LLM_LocalModelAsking := false
	if !Accepted || !_LLM_LocalModelOfferCurrent(Receipt)
		return true
	Admitted := false
	try Admitted := _LLM_LocalModelTrue(_LLM_LocalModelOfferInstall(Receipt))
	if !Admitted && _LLM_LocalModelOfferCurrent(Receipt)
		try LoggerWarn("LLM", "Requested local-model download was refused: {1}.", Model)
	return true
}
