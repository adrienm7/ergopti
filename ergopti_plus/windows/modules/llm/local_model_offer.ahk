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

; CurrentFn fences a modal callback that outlives its requesting flow.
LLM_LocalModelOffer(Failure, Automatic := false, CurrentFn := 0) {
	global _LLM_LocalModelAsking, _LLM_LocalModelNotified, _LLM_LocalModelOfferPort, LLM_OLLAMA_BASE_URL
	if !LLM_LocalModelIsMissing(Failure)
		return false
	if A_IsSuspended || (HasMethod(CurrentFn, "Call") && !CurrentFn.Call())
		return true
	Port := _LLM_LocalModelOfferPort
	NotifyFn := _LLM_CurlArtifactPortFn(Port, "notify", _LLM_LocalModelNotify)
	Title := t("llm.local_model.missing_title")
	Model := Failure["model"]
	Name := LLM_LocalModelNormalize(Model)
	if Automatic {
		if !LLM_LocalModelShouldNotify(_LLM_LocalModelNotified, Model)
			return true
		try {
			if NotifyFn.Call(_LLM_LocalModelLabel("llm.local_model.missing_notice", Model), Title) == true
				_LLM_LocalModelNotified[Name] := true
		}
		return true
	}
	if _LLM_LocalModelAsking
		return true
	ConfirmFn := _LLM_CurlArtifactPortFn(Port, "confirm", _LLM_LocalModelConfirm)
	InstallFn := _LLM_CurlArtifactPortFn(Port, "install", _LLM_LocalModelInstall)
	Generation := LLM_AuxGeneration()
	_LLM_LocalModelAsking := true
	Accepted := false
	try Accepted := ConfirmFn.Call(Title, _LLM_LocalModelLabel("llm.local_model.missing_body", Model)) == true
	catch {
		try NotifyFn.Call(_LLM_LocalModelLabel("llm.local_model.missing_notice", Model), Title)
	} finally _LLM_LocalModelAsking := false
	if !Accepted || A_IsSuspended || Generation != LLM_AuxGeneration()
			|| Failure["base_url"] != LLM_OLLAMA_BASE_URL
			|| (HasMethod(CurrentFn, "Call") && !CurrentFn.Call())
		return true
	Admitted := false
	try Admitted := InstallFn.Call(Failure["base_url"], Model) == true
	if !Admitted
		try LoggerWarn("LLM", "Requested local-model download was refused: {1}.", Model)
	return true
}
