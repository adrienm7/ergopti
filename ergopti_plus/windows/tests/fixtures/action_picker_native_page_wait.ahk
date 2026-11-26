; tests/fixtures/action_picker_native_page_wait.ahk

; ==============================================================================
; MODULE: Action Picker Installed Engine Page Wait
; DESCRIPTION:
; How the installed-engine child (action_picker_native_engine_body.ahk) waits
; for the delivered page to render: it reads the document until the picker's
; title and its « none » row are there, within ONE page budget. Each script it
; runs waits only for what is left of that budget: a first WebView2 load on a
; fresh profile can take more than 3 s, and a fixed 3 s wait per script once
; failed the whole page with a TimeoutError while its 10 s budget still ran.
; On its own file so a unit test drives it with a fake view.
; ==============================================================================

#Requires AutoHotkey v2.0

; The time the delivered page has to render its host payload and the none row, in ms.
_APNR_PageBudgetMs() => 10000

_APNR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

/**
 * Runs one script in the page and reads its JSON result.
 * @param {Object} View - The WebView2 core (or a test's fake).
 * @param {String} Script - The script.
 * @param {Integer} Budget - How long it may wait, in milliseconds.
 * @returns {Any} The parsed result.
 */
_APNR_Script(View, Script, Budget) {
	global _APNR
	_APNR.ScriptCalls += 1
	_APNR_Phase("script-submit-before")
	Pending := View.ExecuteScriptAsync(Script)
	_APNR_Phase("script-submit-after")
	; Keep a rejecting native Promise observed while its genuine await pumps.
	Pending.onSettled((*) => 0, (*) => 0)
	_APNR_Phase("script-await-before")
	Result := Pending.await(Budget)
	_APNR_Phase("script-await-after")
	return JsonParse(Result)
}

/**
 * Reads the document until it shows Title and the none row, within the page budget.
 * @param {Object} View - The WebView2 core (or a test's fake).
 * @param {String} Title - The picker title the page must show.
 * @param {Func} CheckOwned - Throws when the page's session is no longer the one observed.
 * @returns {Map} The document's {title, none, source}.
 */
_APNR_AwaitDocument(View, Title, CheckOwned) {
	global _APNR
	Started := A_TickCount
	loop {
		if IsObject(_APNR.Failure)
			throw _APNR.Failure
		CheckOwned.Call()
		Remaining := _APNR_PageBudgetMs() - ((A_TickCount - Started) & 0xFFFFFFFF)
		_APNR_Require(Remaining > 0, "The actual frontend must render its host init payload and the none row.")
		Data := _APNR_Script(View, "({title:document.getElementById('title')?.textContent||'',"
			. "none:!!document.querySelector('[data-id=none]'),source:location.href})", Remaining)
		if Data is Map && Data.Get("title", "") == Title && Data.Get("none", false)
			return Data
		Sleep(10)
	}
}
