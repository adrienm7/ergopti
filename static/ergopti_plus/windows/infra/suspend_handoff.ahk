; infra/suspend_handoff.ahk

; ==============================================================================
; MODULE: Suspend Reload Hand-off
; DESCRIPTION:
; Owns the small, dependency-injected state transition that carries Suspend
; across Reload. Preparation creates only inert pending state. The live marker
; is published at the terminal OnExit commit, after every refusal gate accepts;
; consumption atomically claims it and toggles only after the claim is deleted.
; Keeping the transition free of OS calls makes every failure boundary
; behavioural-testable without loading the live lifecycle.
; ==============================================================================

#Requires AutoHotkey v2.0

; File name of the one-shot marker that carries a pause across a Reload. This
; module is included before boot arms _SuspendStateWatchdog: onboarding pumps
; messages, so the callback can run long before lifecycle.ahk's later include.
global SUSPEND_MARKER_FILENAME := "suspend_restore.marker"





; ==============================================
; ==============================================
; ======= 1/ Preparation and publication =======
; ==============================================
; ==============================================

SuspendHandoffMarkerPath(PathsFile, Filename := "suspend_restore.marker") {
	if !(PathsFile is String) or PathsFile == ""
		return ""
	SplitPath(PathsFile, , &Dir)
	return Dir . "\" . Filename
}

SuspendHandoffPrepare(Path, WriteFn, ReadFn, MoveFn, DeleteFn) {
	if !(HasMethod(WriteFn, "Call") and HasMethod(ReadFn, "Call")
			and HasMethod(MoveFn, "Call") and HasMethod(DeleteFn, "Call"))
		throw TypeError("Suspend hand-off preparation requires filesystem callbacks.")
	if !(Path is String) or Path == ""
		return false
	PendingPath := Path . ".pending"
	StagePath := PendingPath . ".stage"
	Prepared := false
	try {
		if !WriteFn.Call(StagePath, "1")
			return false
		Content := ReadFn.Call(StagePath)
		if !(Content is String) or Content != "1"
			return false
		if !MoveFn.Call(StagePath, PendingPath)
			return false
		Prepared := true
		return true
	} finally {
		if !Prepared
			try DeleteFn.Call(StagePath)
	}
}

SuspendHandoffCommit(Path, ReadFn, MoveFn) {
	if !HasMethod(ReadFn, "Call") or !HasMethod(MoveFn, "Call")
		throw TypeError("Suspend hand-off commit requires read and move callbacks.")
	if !(Path is String) or Path == ""
		return false
	PendingPath := Path . ".pending"
	Content := ReadFn.Call(PendingPath)
	if !(Content is String) or Content != "1"
		return false
	return MoveFn.Call(PendingPath, Path) ? true : false
}

; Idempotently removes only inert preparation artifacts. It never deletes the
; live marker, so even failed cleanup after a refused Reload cannot invent a
; future suspend transition.
SuspendHandoffAbort(Path, ExistsFn, DeleteFn) {
	if !HasMethod(ExistsFn, "Call") or !HasMethod(DeleteFn, "Call")
		throw TypeError("Suspend hand-off abort requires filesystem callbacks.")
	if !(Path is String) or Path == ""
		return true
	Ok := true
	for Candidate in [Path . ".pending.stage", Path . ".pending"] {
		if ExistsFn.Call(Candidate) and !DeleteFn.Call(Candidate)
			Ok := false
		if ExistsFn.Call(Candidate)
			Ok := false
	}
	return Ok
}

; Prepares inert intent before invoking ReloadFn. ReloadTerminalInvoke owns the
; terminal commit callback. If Reload returns, both layers may abort; AbortFn is
; deliberately required to be idempotent.
SuspendHandoffReload(IsSuspended, Path, PrepareFn, ReloadFn, BeforeReloadFn := 0,
		FailureFn := 0, CancelFn := 0) {
	if !HasMethod(PrepareFn, "Call") or !HasMethod(ReloadFn, "Call")
		throw TypeError("Suspend hand-off requires prepare and reload callbacks.")
	if IsSuspended {
		if (Path == "" or !PrepareFn.Call(Path)) {
			if HasMethod(FailureFn, "Call")
				try FailureFn.Call("prepare", Path)
			return false
		}
	}
	if HasMethod(BeforeReloadFn, "Call")
		BeforeReloadFn.Call()
	Reloaded := ReloadFn.Call()
	if (Reloaded is Integer) && Reloaded == 1
		return true
	; A real accepted Reload never returns. A returned refusal cleans only inert
	; pending state; the terminal layer may already have made the same idempotent
	; call while canceling its record.
	if IsSuspended {
		Canceled := false
		if HasMethod(CancelFn, "Call") {
			try CancelResult := CancelFn.Call(Path)
			catch
				CancelResult := false
			Canceled := (CancelResult is Integer) && CancelResult == 1
		}
		if !Canceled && HasMethod(FailureFn, "Call")
			try FailureFn.Call("cancel", Path)
	}
	return false
}

; Pending/stage files have never crossed terminal authority and must never be
; interpreted as pause intent. Boot best-effort removes them before looking for
; a live marker.
SuspendHandoffDiscardPending(Path, ExistsFn, DeleteFn, FailureFn := 0) {
	Ok := SuspendHandoffAbort(Path, ExistsFn, DeleteFn)
	if !Ok and HasMethod(FailureFn, "Call")
		try FailureFn.Call("discard-pending", Path)
	return Ok
}





; ============================================
; ============================================
; ======= 2/ Atomic marker consumption =======
; ============================================
; ============================================

; Claims a marker with one same-volume rename, consumes the claim, then toggles
; once. The claim name is derived here, not supplied by a lifecycle caller, so
; it is necessarily stable across process restarts: when deletion fails, the
; next boot resumes from the retained claim instead of losing ownership with
; the old process identity. A failed claim/delete reports once and leaves
; ToggleFn untouched.
SuspendHandoffConsume(Path, IsSuspended, ExistsFn, MoveFn, DeleteFn, ToggleFn, BeforeToggleFn := 0, FailureFn := 0) {
	if !(HasMethod(ExistsFn, "Call") and HasMethod(MoveFn, "Call")
			and HasMethod(DeleteFn, "Call") and HasMethod(ToggleFn, "Call"))
		throw TypeError("Suspend hand-off requires filesystem and toggle callbacks.")
	if (Path == "")
		return true
	ClaimPath := Path . ".claim"
	Claimed := ExistsFn.Call(ClaimPath)
	SourceExists := ExistsFn.Call(Path)
	if !Claimed {
		if !SourceExists
			return true
		if !MoveFn.Call(Path, ClaimPath, false) {
			if HasMethod(FailureFn, "Call")
				try FailureFn.Call("claim", Path)
			return false
		}
	} else if SourceExists {
		; Both files express the same desired state: the replacement process must
		; be suspended. Coalesce them before toggling so the source cannot replay
		; on a later boot. Source goes first; a later claim-delete failure still
		; leaves the stable claim carrying the unconsumed intent.
		if !DeleteFn.Call(Path) {
			if HasMethod(FailureFn, "Call")
				try FailureFn.Call("coalesce", Path)
			return false
		}
	}
	if !DeleteFn.Call(ClaimPath) {
		if HasMethod(FailureFn, "Call")
			try FailureFn.Call("consume", ClaimPath)
		return false
	}
	if IsSuspended
		return true
	if HasMethod(BeforeToggleFn, "Call")
		BeforeToggleFn.Call()
	ToggleFn.Call()
	return true
}
