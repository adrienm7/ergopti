; tests/meta/test_menu_reload_preserves_suspend.ahk

; ==============================================================================
; MODULE: Menu Reload Preserves Suspend Meta Test
; DESCRIPTION:
; Regression guard for menu-reload-drops-suspend.
;
; AHK's Reload starts a fresh process that is never suspended, and the driver had
; no suspend persistence at all. The tray menu is the ONE surface that stays
; fully interactive while paused -- native Suspend disarms hotkeys and hotstrings
; but never a tray WM_COMMAND -- so it is also the only surface that can reach a
; Reload from the paused state. Every menu action that persists a setting and
; reloads (feature toggles, letter pickers, gesture slots, metrics filters,
; tap-hold options) therefore brought the driver back FULLY ARMED, with the
; « Suspendre » checkmark gone and not one line in the log to explain it.
;
; ROOT CAUSE ENCODED: no function in the tray-menu layer may call a bare Reload;
; they must all route through ReloadPreservingSuspend, which persists the pause
; before reloading, and the boot restore must CONSUME the marker before applying
; it so a crash cannot wedge the driver paused forever.
;
; The offender class is derived from the source tree via _DriverDirConcat, so a
; new action that reaches for a bare Reload fails here without anyone having to
; remember to add it to a list.
;
; WIDENED 2026-07-29 (reload-drops-suspend-outside-the-menu-layer). The original
; scan covered ui/menu ONLY — the directory the fix touched — while the guarantee
; is transitive: ANY path reachable while paused that reloads must carry the
; pause. Twenty-one bare Reload sites existed; fourteen were outside ui/menu, in
; infra/config_io.ahk (ten), infra/i18n.ahk, modules/updater/core.ahk, ui/editors.ahk
; (three), ui/action_picker, ui/paths_editor, ui/personal_info_editor,
; ui/onboarding (two) and modules/gestures/actions.ahk. Changing the interface
; language while paused, or saving from any editor, silently brought the driver
; back ARMED. A test scoped to the directory of the fix cannot see that, which is
; the failure shape recorded as project-ahk-invariant-incomplete-application.
;
; TWO SITES ARE DELIBERATELY OUT OF SCOPE, both in the entry file:
;   * ErgoptiPlus.ahk's keyboard-layout poll. _ShouldReloadForHkl returns false
;     when `suspended` is true (modules/keymap/layout_poll_helper.ahk), so that
;     Reload is provably unreachable while paused; routing it through the helper
;     would be dead code. Section 4 pins that guard, so the exemption stays tied
;     to the code that justifies it.
;   * ErgoptiPlus.ahk's personal-shortcuts chain reload, which runs in the boot
;     auto-execute thread before the marker restore timer has fired, i.e. before
;     the process can be suspended at all. (Its runtime caller opts out of
;     reloading entirely.)
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================================
; =====================================================================
; ======= 1/ No bare Reload anywhere a paused user can reach it =======
; =====================================================================
; =====================================================================

; Count lines that are nothing but a bare Reload / Reload().
_MRS_CountBareReload(Src, &Offenders) {
	Offenders := ""
	Count := 0
	for Line in StrSplit(Src, "`n", "`r") {
		if RegExMatch(Line, "^\s*Reload\s*(\(\s*\))?\s*$") {
			Count += 1
			Offenders .= (Offenders == "" ? "" : ", ") . Trim(Line)
		}
	}
	return Count
}

_MRS_CountRouted(Src) {
	Routed := 0
	for Line in StrSplit(Src, "`n", "`r")
		; Production calls are indented; the sole column-zero match is the
		; ReloadPreservingSuspend declaration and must not inflate the canary.
		if RegExMatch(Line, "^\s+.*\bReloadPreservingSuspend\s*\(")
			Routed += 1
	return Routed
}

_MRS_NoBareReloadAnywhereReachable() {
	; Every tree a user action can reach. The entry file is deliberately excluded
	; — see the two documented exemptions in the header — and it is not a
	; directory, so scanning by directory excludes it structurally rather than by
	; a name this test would have to keep in step.
	Src := ""
	for Dir in ["infra", "ui", "modules", "platform", "adapters"]
		Src .= "`n" . _StripFullLineComments(_DriverDirConcat(Dir))
	Assert(StrLen(Src) > 200000,
		"the driver source trees must be readable for this scan to mean anything (read " . StrLen(Src) . " chars)")

	Offenders := ""
	Count := _MRS_CountBareReload(Src, &Offenders)

	; Reload is now injected into the tested hand-off core, so no production
	; function needs a direct call. Pin both halves: zero bare calls and the real
	; callback passed by the lifecycle wrapper.
	Wrapper := _DriverFuncBody("ReloadPreservingSuspend")
	Helper := _DriverFuncBody("_ReloadPreservingSuspendNonCritical")
	Assert(Wrapper != "" && Helper != "",
		"ReloadPreservingSuspend() and its non-Critical core must exist")
	Assert(InStr(Wrapper,
		"_ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle)") > 0
		and InStr(Helper, "SuspendHandoffReload(") > 0
		and InStr(Helper, "ReloadTerminalInvoke.Bind(") > 0,
		"ReloadPreservingSuspend must pass the real Reload callback to the tested hand-off core")

	Assert(Count == 0,
		"no code a paused user can reach may call a bare Reload: native Suspend leaves the tray, every editor "
		. "window and the language switch fully interactive, and Reload starts a fresh UNSUSPENDED process, so "
		. "the pause is dropped with nothing in the log. Route it through ReloadPreservingSuspend() "
		. "(reload-drops-suspend-outside-the-menu-layer) -- found " . Count . " bare Reload(s): " . Offenders)

	Routed := _MRS_CountRouted(Src)
	Assert(Routed >= 24,
		"the driver must still reload through ReloadPreservingSuspend at its persist-and-restart sites -- a scan "
		. "that found none would pass the assertion above vacuously (found " . Routed . ")")
}
Test("menu: no reachable action calls a bare Reload (reload-drops-suspend-outside-the-menu-layer)",
	_MRS_NoBareReloadAnywhereReachable)




; =============================================================
; ===== 1.1) The layout-poll exemption is still justified =====
; =============================================================

; The keyboard-layout poll keeps a bare Reload in the entry file. That is only
; acceptable because its decision function refuses while suspended, so the site
; is unreachable from the paused state. Pin that guard here: if it is ever
; removed, the exemption must not survive it silently.
_MRS_LayoutPollDeclinesWhileSuspended() {
	Body := _DriverFuncBody("_ShouldReloadForHkl")
	Assert(Body != "", "_ShouldReloadForHkl() must exist in the driver source")
	SuspendPos := InStr(Body, "if suspended")
	Assert(SuspendPos > 0,
		'_ShouldReloadForHkl must still test "suspended" — the entry file keyboard-layout Reload is exempted '
		. 'from section 1 ONLY because this function refuses while paused')
	ReturnPos := InStr(Body, "return false", , SuspendPos)
	Assert(ReturnPos > SuspendPos,
		"_ShouldReloadForHkl must return false when suspended. Without that, the entry file's bare Reload becomes "
		. "reachable from the paused state and must be routed through ReloadPreservingSuspend() instead")
}
Test("menu: the layout poll still refuses to reload while suspended (reload-drops-suspend-outside-the-menu-layer)",
	_MRS_LayoutPollDeclinesWhileSuspended)





; ===========================================================
; ===========================================================
; ======= 2/ The hand-off actually persists the pause =======
; ===========================================================
; ===========================================================

_MRS_HelperPersistsBeforeReloading() {
	Wrapper := _DriverFuncBody("ReloadPreservingSuspend")
	Body := _DriverFuncBody("_ReloadPreservingSuspendNonCritical")
	Core := _DriverFuncBody("SuspendHandoffReload")
	CommitWrapper := _DriverFuncBody("ReloadTerminalHandoffCommit")
	Commit := _DriverFuncBody("_ReloadTerminalHandoffCommitNonCritical")
	MarkerPath := _DriverFuncBody("_SuspendMarkerPath")
	Restore := _DriverFuncBody("_SuspendRestoreFromMarker")
	Assert(Wrapper != "" && Body != "",
		"ReloadPreservingSuspend() and its non-Critical core must exist")
	Assert(Core != "", "SuspendHandoffReload() must exist in the driver source")
	Assert(InStr(Wrapper,
		"_ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle)") > 0,
		"the public reload entry must delegate after dropping inherited Critical")

	GuardPos  := InStr(Body, "A_IsSuspended")
	MarkerPos := InStr(Body, "_SuspendMarkerPath()")
	Assert(GuardPos > 0 and MarkerPos > GuardPos and InStr(Body, "SuspendHandoffReload(") > MarkerPos,
		"ReloadPreservingSuspend must pass the resolved suspended state and marker to the tested hand-off core")
	PreparePos := InStr(Core, "PrepareFn.Call")
	ReloadPos := InStr(Core, "ReloadFn.Call")
	Assert(PreparePos > 0 and ReloadPos > PreparePos
		and InStr(Core, "return false") > PreparePos,
		"the hand-off core must prepare inert state before ReloadFn and return without Reload on failure")
	Assert(InStr(Body, "_SuspendHandoffCommitMarker.Bind(Path)") > 0
		and InStr(Body, "_SuspendHandoffCancelMarker.Bind(Path)") > 0
		and InStr(CommitWrapper,
			"_ReloadTerminalHandoffCommitNonCritical(Record)") > 0
		and InStr(Commit, "CommitFn.Call()") > 0,
		"only the terminal OnExit commit may promote pending pause intent")
	Assert(InStr(MarkerPath, "_PathsFile") > 0
		and InStr(MarkerPath, "ConfigurationFile") == 0,
		"the marker must follow the stable paths.toml locator across config relocation")
	Assert(InStr(Restore, "SuspendHandoffDiscardPending(") > 0
		and InStr(Restore, "SuspendHandoffConsume(")
			> InStr(Restore, "SuspendHandoffDiscardPending("),
		"boot must discard inert preparation debris before consuming live intent")
}
Test("menu: ReloadPreservingSuspend terminally publishes pause after acceptance (menu-reload-drops-suspend)",
	_MRS_HelperPersistsBeforeReloading)

_MRS_SuspendProtocolUsesStrictFilesystemPrimitives() {
	Prepare := _DriverFuncBody("_SuspendHandoffPrepareMarker")
	Cancel := _DriverFuncBody("_SuspendHandoffCancelMarker")
	Restore := _DriverFuncBody("_SuspendRestoreFromMarker")
	Assert(Prepare != "" and Cancel != "" and Restore != "",
		"every lifecycle wrapper for the suspend hand-off must exist")
	Assert(InStr(Prepare, "FSDeleteStrict") > 0,
		"preparation cleanup must not hide filesystem errors as absence")
	Assert(InStr(Cancel, "FSStrictExists") > 0 and InStr(Cancel, "FSDeleteStrict") > 0,
		"cancellation must probe and delete inert intent through strict adapters")
	Assert(InStr(Restore, "FSStrictExists") > 0 and InStr(Restore, "FSDeleteStrict") > 0,
		"boot restore must preserve probe and delete errors for retry")
}
Test("AHK-006: suspend hand-off lifecycle wrappers use strict filesystem adapters",
	_MRS_SuspendProtocolUsesStrictFilesystemPrimitives)





; ==========================================================
; ==========================================================
; ======= 3/ The boot restore consumes then applies ========
; ==========================================================
; ==========================================================

_MRS_BootRestoreConsumesTheMarkerFirst() {
	Restore := _DriverFuncBody("_SuspendRestoreFromMarker")
	Core := _DriverFuncBody("SuspendHandoffConsume")
	Assert(Restore != "", "_SuspendRestoreFromMarker() must exist in the driver source")
	Assert(Core != "", "SuspendHandoffConsume() must exist in the driver source")

	MovePos := InStr(Core, "MoveFn.Call")
	DeletePos := InStr(Core, "DeleteFn.Call")
	SuspendPos := InStr(Core, "ToggleFn.Call")
	Assert(MovePos > 0 and DeletePos > MovePos and SuspendPos > DeletePos,
		"the marker must be atomically claimed and consumed before pause is re-applied")
	Assert(InStr(Restore, "SuspendHandoffConsume(") > 0,
		"the lifecycle wrapper must route restoration through the tested claim/delete/toggle core")
	Assert(!InStr(Restore, "Suspend(1)"),
		"the restore must re-enter the pause through ToggleSuspend, the one path that runs the "
		. "custom-combination prefix drain: a Reload can land while a prefix key is still physically "
		. "held, which is the exact state that drain exists for")

	Watchdog := _DriverFuncBody("_SuspendStateWatchdog")
	Assert(Watchdog != "", "_SuspendStateWatchdog must exist in the driver source")
	Assert(InStr(Watchdog, "_SuspendRestoreFromMarker") > 0,
		"the boot restore must be wired into the suspend watchdog, otherwise the marker is written on "
		. "every menu-driven Reload and never consumed -- the pause would still be lost, and now with "
		. "a stale file left behind")
}
Test("menu: the boot restore consumes the suspend marker before applying it (menu-reload-drops-suspend)",
	_MRS_BootRestoreConsumesTheMarkerFirst)
