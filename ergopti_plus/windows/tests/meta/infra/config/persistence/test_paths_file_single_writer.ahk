; tests/meta/infra/config/persistence/test_paths_file_single_writer.ahk

; ==============================================================================
; MODULE: paths.toml Single-Writer Meta Test
; DESCRIPTION:
; paths.toml decides where the ENTIRE driver reads and writes its config, so a
; write that fails silently is expensive: the user picks a new directory, the
; write is discarded, and the Reload() drops them straight back into the old one
; with nothing reported anywhere. The change simply appears not to have happened.
;
; There were two copies of that writer — the WebView2 editor's, which was
; hardened, and a verbatim pre-hardening twin in the action picker's
; ConfirmPath, still carrying the unprotected FileOpen and an `if f` with no
; else. The duplication is the ROOT CAUSE: hardening one copy could never fix
; the other, and nothing made them fail together.
;
; FEATURES & RATIONALE:
; 1. Asserts there is exactly ONE writer, rather than asserting both writers are
;    hardened — the latter is satisfiable by re-duplicating the hardened block,
;    which leaves the drift mechanism fully intact.
; 2. Pins the writer's failure contract, so it cannot regress to a silent skip.
;
; SCOPE: source introspection of ui/ via the move-resilient helper.
; ==============================================================================

#Requires AutoHotkey v2.0


; ==============================================
; ==============================================
; ======= 1/ Exactly one writer exists =========
; ==============================================
; ==============================================

_PFSW_OnlyOneWriter() {
	Src := _DriverDirConcat("ui")
	Assert(Src != "", "the ui/ source must be readable")

	; No UI site may publish locator bytes directly. The crash-recoverable
	; transition owns the only durable publication path and captures old bytes
	; before either config or locator authority can change.
	Needle := 'FileOpen(_PathsFile, "w"'
	Count := 0
	Pos := 1
	while (Pos := InStr(Src, Needle, , Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	Assert(Count == 0,
		"UI code must have zero raw paths.toml writers (found " . Count . "). Direct publication bypasses the multi-file WAL and can split config authority from its locator after a crash.")

	Assert(InStr(Src, "_PathsFile_Write(") > 0,
		"the shared writer _PathsFile_Write must exist and be the site both editors call")
}

; The writer must fail loudly. A silent skip here is indistinguishable from
; success to every caller, because the Reload() that follows hides the evidence.
_PFSW_WriterFailsLoudly() {
	Body := _DriverFuncBody("_PathsFile_Write")
	Assert(Body != "", "_PathsFile_Write() must exist")

	Assert(InStr(Body, "ConfigTransitionAcquireLifecycleBundle(") > 0,
		"_PathsFile_Write must acquire the process-wide transition owner before capturing old locator bytes")
	Assert(InStr(Body, "ConfigTransitionCommitOwned(") > 0,
		"_PathsFile_Write must publish paths.toml through the crash-recoverable transition")
	Assert(InStr(Body,
		'ConfigTransitionResultIs(CommitResult, "committed_new")') > 0,
		"the journal commit result must be checked with the strict typed predicate")
	Assert(InStr(Body, "ConfigTransitionLogFailure") > 0,
		"a failed paths.toml transition must reach the log")
	Assert(InStr(Body, "MsgBox") > 0,
		"a failed paths.toml write must be shown to the user — they are standing in front of the dialog, and the following Reload() erases the evidence")
	Assert(InStr(Body, "return false") > 0,
		"_PathsFile_Write must report failure to its caller so the Reload() is skipped")
	ReloadPos := InStr(Body, "ReloadPreservingSuspend(0, OwnerBundle,")
	; One rollback helper serves a refused launch and a later refusal alike.
	RollbackPos := InStr(Body, "_PathsFile_RollbackRefusedReload(OwnerBundle)")
	ReleasePos := InStr(Body, "_ConfigWriteTerminalRelease(OwnerBundle)")
	Assert(ReloadPos > 0 && RollbackPos > ReloadPos && ReleasePos > RollbackPos
		&& InStr(_DriverFuncBody("_PathsFile_RollbackRefusedReload"),
			"ConfigTransitionRollbackOwned(") > 0,
		"a refused Reload must restore all-old while the same terminal owner is still held")
	Assert(InStr(Body, "FileOpen(") == 0,
		"the shared writer must not bypass its WAL with a raw FileOpen")
}

; Both callers must honour that contract: reloading after a failed write is what
; puts the user back in the old directory with no explanation.
_PFSW_CallersSkipReloadOnFailure() {
	Src := _DriverDirConcat("ui")
	Pos := 1
	Checked := 0
	while (Pos := InStr(Src, "_PathsFile_Write(", , Pos)) {
		; Skip the definition itself.
		LineStart := InStr(Src, "`n", , Pos - 120) + 1
		Head := SubStr(Src, (Pos > 120) ? Pos - 120 : 1, 120)
		; The definition is the one occurrence followed by its parameter list and
		; an opening brace, whatever its parameters are named.
		if !RegExMatch(SubStr(Src, Pos, 120), "^_PathsFile_Write\([^)]*\)\s*\{") {
			Checked += 1
			Window := SubStr(Src, (Pos > 40) ? Pos - 40 : 1, 200)
			Assert(InStr(Window, "if !_PathsFile_Write") > 0,
				"every caller must branch on the writer's return value — reloading after a failed write drops the user back into the old config directory with nothing reported")
		}
		Pos += StrLen("_PathsFile_Write(")
	}
	Assert(Checked >= 2,
		"expected at least two call sites to police (found " . Checked . ") — both the WebView2 editor and the action picker must go through the shared writer")
}


Test("meta paths: paths.toml has exactly one writer",
	_PFSW_OnlyOneWriter)
Test("meta paths: the shared writer fails loudly rather than skipping",
	_PFSW_WriterFailsLoudly)
Test("meta paths: every caller skips the reload when the write failed",
	_PFSW_CallersSkipReloadOnFailure)

; via SetTimer(-1), as ui/onboarding/webview.ahk already documents.
; F-29  _PathsEdWeb_Save left FileOpen unprotected with no else on `if f`, so a
; failed write was silent, the log claimed success, and Reload() dropped
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
; tests/meta/infra/config/persistence/test_paths_file_single_writer.ahk, which pins that exactly one
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
	ReloadPos := InStr(Writer, "ReloadPreservingSuspend(0, OwnerBundle,")
	; One rollback helper serves a refused launch and a later refusal alike.
	RollbackPos := InStr(Writer, "_PathsFile_RollbackRefusedReload(OwnerBundle)")
	RollbackBody := _DriverFuncBody("_PathsFile_RollbackRefusedReload")
	Assert(ReloadPos > 0,
		"the shared writer must own the success-path reload so its config lease cannot be released between paths.toml and Reload")
	Assert(CommitPos > 0 && StrictPos > CommitPos && ReloadPos > StrictPos
		&& RollbackPos > ReloadPos
		&& InStr(RollbackBody, "ConfigTransitionRollbackOwned(") > 0,
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
