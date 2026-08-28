; static/ergopti_plus/windows/tests/meta/test_audit_2026_07_20_webview.ahk

; ==============================================================================
; MODULE: Audit 2026-07-20 (second pass) — WebView2 host findings
; DESCRIPTION:
; Guards for F-25, F-26, F-27, F-28 and F-29.
;
; The whole cluster has ONE mechanism behind it: infra/webview_utils.ahk defines a
; WebViewHost factory that handles every documented gotcha correctly — and has
; zero consumers. All 14 windows are hand-rolled copies, so each cross-cutting
; guard was applied only to the sites its regression test happened to name.
;
; These tests are therefore written as CLASS LOOPS over every host, not as
; assertions about the sites that were broken. That shape is the actual fix:
; it makes the next hand-rolled window fail the suite instead of silently
; inheriting the omission.
;
; F-25  Only 2 of 9 WebMessageReceived handlers enforced suspend policy. COM
;       callbacks bypass native Suspend, so a paused driver still let a page
;       click write config, re-register hotstrings, or (onboarding) launch an
;       elevated UAC driver install. Most handlers use a direct guard; the
;       changelog captures immutable AHK-14 provenance before its yielding COM
;       read and revalidates actions afterward. Both deliberately exempt
;       `ready`: gating page-lifecycle signals strands the safety fallback.
; F-26  _PromptEdWeb_TryOpen captured the open context BELOW its singleton
;       early-return, so re-opening for a different profile kept the previous
;       _PromptEdWeb_EditId and saving overwrote the WRONG profile.
; F-27/ Teardown ran synchronously on the WebMessageReceived stack: the
; F-28  subscription currently dispatching was released, then the controller
;       closed and the Gui destroyed. Uncatchable SEH class; must be deferred
;       via SetTimer(-1), as ui/onboarding/webview.ahk already documents.
; F-29  _PathsEdWeb_Save left FileOpen unprotected with no else on `if f`, so a
;       failed write was silent, the log claimed success, and Reload() dropped
;       the user back into the old directory.
; ==============================================================================

#Requires AutoHotkey v2.0

; Every WebMessageReceived handler in the driver, DERIVED from source.
;
; This was a hardcoded list of nine names guarded by "Checked >= 9" — an
; assertion that can only ever compare the list against itself, so it was
; tautological. It missed two of the eleven handlers actually registered, which
; is the exact failure this whole file was written to prevent: an invariant
; applied to the sites a list happens to name rather than to the class.
;
; Both registration spellings are matched: the direct
; `.WebMessageReceived(Handler)` form and the `.Bind(...)` form KLWV uses.
_A0720WV_MessageHandlers() {
	Src := _DriverSourceNoComments()
	Seen := Map()
	Out := []
	Pos := 1
	while (Pos := RegExMatch(Src, "WebMessageReceived\(\s*([A-Za-z0-9_]+)", &m, Pos)) {
		Name := m[1]
		; infra/webview_utils.ahk's WebViewHost registers a BOUND METHOD
		; (this._OnWebMessage.Bind(this)), which resolves to the token "this" and
		; has no top-level function body to look up. That factory has zero
		; consumers — every window is a hand-rolled copy, which is the whole
		; reason this file exists — so skipping it loses no coverage.
		if (Name = "this")
			Name := ""
		if (Name != "" and !Seen.Has(Name)) {
			Seen[Name] := true
			Out.Push(Name)
		}
		Pos += StrLen(m[0])
	}
	return Out
}

_A0720WV_ChangelogHasSuspendPolicy(Body) {
	ReadPos := InStr(Body, "_Updater_ReadManualBridgeMessage(")
	BornPos := InStr(Body, "Request.BornSuspended")
	PolicyPos := InStr(Body, "_Updater_RequestMayPublish(Request)")
	FetchPos := InStr(Body, "_CLW_FetchAndInject(")
	UrlPos := InStr(Body, "_Updater_OpenManualUrl(")
	Assert(ReadPos > 0 and BornPos > ReadPos and PolicyPos > BornPos,
		"_CLW_OnWebMessage must preserve entry-time suspend provenance across its yielding COM read and revalidate it before actions")
	Assert(FetchPos > PolicyPos and UrlPos > PolicyPos,
		"_CLW_OnWebMessage must apply the shared suspend policy before every mutating bridge action")

	Reader := _DriverFuncBody("_Updater_ReadManualBridgeMessage")
	Assert(Reader != "",
		"_Updater_ReadManualBridgeMessage must exist — it is the changelog bridge's suspend-policy owner")
	CapturePos := InStr(Reader, "_Updater_NewRequestContext(")
	YieldPos := InStr(Reader, "ReadFn.Call()")
	Assert(CapturePos > 0 and YieldPos > CapturePos,
		"the changelog bridge must capture AHK-14 provenance before the COM message read can yield")
}

_A0720WV_EveryHandlerIsSuspendGuarded() {
	Checked := 0
	for _, Fn in _A0720WV_MessageHandlers() {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist — if a host was renamed, update this list rather than dropping the handler from the invariant")
		if (Fn == "_CLW_OnWebMessage")
			_A0720WV_ChangelogHasSuspendPolicy(Body)
		else
			Assert(InStr(Body, "A_IsSuspended") > 0,
				Fn . " must gate on A_IsSuspended: WebMessageReceived is a COM callback and bypasses native Suspend, which only disarms hotkeys, so a paused driver would still let a page click write config, re-register hotstrings or launch an elevated install")
		Checked += 1
	}
	; A floor, not a tautology: the previous ">= 9" compared a hardcoded list
	; against its own length and could never fail. Eleven handlers are registered
	; today, so a drop below that means a host lost its registration.
	Assert(Checked >= 11,
		"every WebView2 message handler must be covered by this invariant (found " . Checked . ") — the cluster this guards exists precisely because each guard was applied only to the sites its test named")
}
Test("webview: every message handler honours the suspend invariant (F-25)",
	_A0720WV_EveryHandlerIsSuspendGuarded)


; The guard must not swallow page-lifecycle signals. Dropping `ready` is how the
; model browser ended up with a permanently empty table (F-32's class).
_A0720WV_ReadyIsNotGatedAway() {
	for _, Fn in ["_OnbWeb_OnWebMessage", "_HCWWeb_OnWebMessage", "_PathsEdWeb_OnWebMessage"
	            , "_PiEdWeb_OnWebMessage", "_ActPickWeb_OnWebMessage"] {
		Body := _DriverFuncBody(Fn)
		if (Body == "" or InStr(Body, "ready") = 0)
			continue
		Assert(RegExMatch(Body, 'A_IsSuspended\s*&&\s*Action\s*!=\s*"ready"') > 0,
			Fn . " must exempt the `ready` page-lifecycle signal from its suspend guard — gating it strands the SafetyFlush and leaves the page permanently un-initialised, which is a different bug than the one the guard fixes")
	}
}
Test("webview: the suspend guard exempts page-lifecycle signals (F-25)",
	_A0720WV_ReadyIsNotGatedAway)


_A0720WV_PromptEditorCapturesContextBeforeSingleton() {
	Body := _DriverFuncBody("_PromptEdWeb_TryOpen")
	Assert(Body != "", "_PromptEdWeb_TryOpen must exist in ui/prompt_editor/init.ahk")

	CapturePos := InStr(Body, "_PromptEdWeb_EditId")
	ActivatePos := InStr(Body, "WinActivate(")
	Assert(CapturePos > 0 and ActivatePos > 0, "prerequisite: both the context capture and the singleton activate must be present")
	Assert(CapturePos < ActivatePos,
		"_PromptEdWeb_TryOpen must capture the open context BEFORE the singleton early-return — otherwise re-opening the editor for a different profile keeps the previous _PromptEdWeb_EditId, the window merely gains focus still bound to the old profile, and saving overwrites the WRONG profile with the new one's edits")
}
Test("prompt-editor: the singleton re-points at the new profile (F-26)",
	_A0720WV_PromptEditorCapturesContextBeforeSingleton)


; Class loop: no message handler may tear its own host down synchronously.
_A0720WV_TeardownIsDeferredOutOfTheCallback() {
	Cases := Map(
		"_LLM_MBW_OnWebMessage", ["_LLM_MBW_OnClose(", "_LLM_MBW_Reset("],
		"_HsEdWeb_OnWebMessage", ["_HsEdWeb_Close(", "_HsEdWeb_Save("],
		"_OnbWeb_OnWebMessage", ["_OnbWeb_Finish(", "_Onboarding_Commit(", "_OnbWeb_Reset("]
	)
	for Fn, Forbidden in Cases {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist")
		for _, Call in Forbidden {
			Assert(InStr(Body, Call) = 0,
				Fn . " must not call " . Call . " directly — it runs on the WebMessageReceived stack, where releasing the subscription currently dispatching and then closing the controller / destroying the Gui is an uncatchable access-violation class. Hand off with SetTimer(-1), as ui/onboarding/webview.ahk documents")
		}
		Assert(InStr(Body, "SetTimer(") > 0,
			Fn . " must defer its side-effecting work out of the COM callback with SetTimer(-1)")
	}
}
Test("webview: hosts never tear down from inside the COM callback (F-27, F-28, AHK-055)",
	_A0720WV_TeardownIsDeferredOutOfTheCallback)


; Every deferred callback must carry the session that scheduled it. Otherwise a
; one-shot timer from a closed session can resolve the replacement host's mutable
; globals and close it, inject JS into it, or persist the old payload through it.
_A0720WV_DeferredActionsOwnTheirSession() {
	Cases := Map(
		"ActPickWeb", ["_ActPickWeb_TryOpen", "_ActPickWeb_OnWebMessage", "_ActPickWeb_Reset"],
		"OnbWeb", ["_Onboarding_TryWeb", "_OnbWeb_OnWebMessage", "_OnbWeb_Reset"],
		"HsEdWeb", ["_HsEdWeb_TryOpen", "_HsEdWeb_OnWebMessage", "_HsEdWeb_Reset"],
		"PiEdWeb", ["_PiEdWeb_TryOpen", "_PiEdWeb_OnWebMessage", "_PiEdWeb_Reset"],
		"PathsEdWeb", ["_PathsEdWeb_TryOpen", "_PathsEdWeb_OnWebMessage", "_PathsEdWeb_Reset"],
		"HCWWeb", ["_HCWWeb_TryOpen", "_HCWWeb_OnWebMessage", "_HCWWeb_Reset"]
	)
	for Prefix, Fns in Cases {
		TryOpenBody := _DriverFuncBody(Fns[1])
		HandlerBody := _DriverFuncBody(Fns[2])
		ResetBody := _DriverFuncBody(Fns[3])
		SessionCallBody := _DriverFuncBody("_" . Prefix . "_SessionCall")
		Assert(InStr(TryOpenBody, ".Bind(SessionEpoch)") > 0,
			Prefix . " must allocate and bind a session epoch when opening")
		Assert(InStr(HandlerBody, "SessionCall.Bind(SessionEpoch") > 0,
			Prefix . " must reject messages and defer work with the captured session epoch")
		Assert(InStr(ResetBody, "SessionEpoch += 1") > 0,
			Prefix . " reset must revoke every callback queued by the closing session")
		Assert(InStr(SessionCallBody, "SessionCurrent(SessionEpoch)") > 0
			&& InStr(SessionCallBody, "Callback(Params*)") > 0,
			Prefix . " must validate ownership immediately before invoking the deferred effect")
	}
}
Test("webview: deferred actions cannot cross singleton sessions (AHK-054)",
	_A0720WV_DeferredActionsOwnTheirSession)


; The guarantee is unchanged — a failed config-directory write must be surfaced,
; and must not be followed by a Reload() that hides it. Only its LOCATION moved:
; the write block was extracted into the shared _PathsFile_Write after an
; unhardened verbatim TWIN was found in the action picker's ConfirmPath, still
; carrying the original unprotected FileOpen. Scoping this assertion to one
; function body was what let that twin exist unnoticed.
;
; So this now follows the guarantee transitively, and asserts strictly MORE than
; before: the caller must branch on the writer's result and skip the reload, AND
; the writer itself must catch and log. See also
; tests/meta/test_paths_file_single_writer.ahk, which pins that exactly one
; writer exists — re-duplicating the hardened block would satisfy this test but
; fail that one.
_A0720WV_PathsEditorSurfacesWriteFailure() {
	Body := _DriverFuncBody("_PathsEdWeb_Save")
	Assert(Body != "", "_PathsEdWeb_Save must exist in ui/paths_editor/init.ahk")

	GuardPos := InStr(Body, "if !_PathsFile_Write")
	Assert(GuardPos > 0,
		"_PathsEdWeb_Save must branch on the shared writer's result — a write that failed must not fall through")

	; The original assertions, re-pointed at the code that now performs the write.
	Writer := _DriverFuncBody("_PathsFile_Write")
	Assert(Writer != "", "_PathsFile_Write must exist — it is the single writer both editors call")
	CommitPos := InStr(Writer, "ConfigTransitionCommitOwned(")
	StrictPos := InStr(Writer,
		'ConfigTransitionResultIs(CommitResult, "committed_new")')
	ReloadPos := InStr(Writer, "ReloadPreservingSuspend(0, OwnerBundle)")
	RollbackPos := InStr(Writer, "ConfigTransitionRollbackOwned(")
	Assert(ReloadPos > 0,
		"the shared writer must own the success-path reload so its config lease cannot be released between paths.toml and Reload")
	Assert(CommitPos > 0 && StrictPos > CommitPos && ReloadPos > StrictPos
		&& RollbackPos > ReloadPos,
		"the paths editor must strictly commit its WAL before Reload and roll all-old on a refused Reload")
	Assert(InStr(Writer, "ConfigTransitionLogFailure") > 0,
		"a refused transition must be logged with its typed evidence")
	Assert(InStr(Writer, "FileOpen(") == 0,
		"the paths.toml writer must not bypass the crash-recoverable transition with raw I/O")
	Assert(InStr(Writer, "return false") > 0,
		"the writer must report failure to its callers, or the branch above cannot work")
}
Test("paths-editor: a failed config-directory write is surfaced (F-29)",
	_A0720WV_PathsEditorSurfacesWriteFailure)
