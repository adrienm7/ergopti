; ui/hotstrings_config_window/hcw_mutations.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window — Mutations
; DESCRIPTION:
; Write-path functions for the hotstrings config window. Contains all handlers
; that mutate state: debounce-armed numeric writes, color/tooltip change
; handlers, reset-all and set-all-grey bulk operations, the window-close flush,
; source-aware override dispatch (SetOverride / ClearOverride / Resolve /
; ReadTomlMeta), and the personal TOML [_meta] atomic patcher.
;
; RATIONALE:
; Extracted from init.ahk so the write path is isolated in one file and the
; read/UI path lives in hcw_helpers.ahk. Every function here ultimately calls
; either HotstringsSetOverride / HotstringsClearOverride (for common and
; extension entries) or _HCW_PatchTomlMeta (for personal TOML files).
; ==============================================================================

; Override fields that are BAKED INTO EACH SPEC at registration time rather than
; derived at read time. Persisting one of these only bumps the resolve
; generation, so the window (which reads through HotstringsResolve) shows the new
; value while the live engine keeps gating on the value it was registered with —
; the tooltip advertises an expansion window the engine refuses, or a collision
; resolves by a priority the user has already changed. Both need a live
; re-registration, which is exactly what the tray-menu delay editors already do.
;
; Color and show_tooltip are deliberately absent: they ARE derived at read, and
; a ~1.3 s re-registration on every color pick would be a serious regression in
; a window whose numeric edits already fire on a debounce.
global HCW_REBUILD_ON_WRITE_FIELDS := Map("delay", true, "priority", true)


; Execute every persistence callback and collapse their strict Boolean results
; into one outcome. AHK v2 considers the string "0" equal to false, so accepting
; truthy strings here would turn an adapter protocol violation into a false
; success. Reconciliation always runs once; exactly one terminal callback then
; observes the aggregate result. Outcome["ok"] describes durable writes only;
; callback failures are contained and logged by _HCW_RunOutcomeCallback.
_HCW_RunWriteBatch(WriteFns, ReconcileFn := 0, SuccessFn := 0, FailureFn := 0) {
	Outcome := Map(
		"ok", true,
		"attempted", 0,
		"succeeded", 0,
		"failed", 0,
		"failed_indices", [],
		"failure_reported", false
	)
	for Index, WriteFn in WriteFns {
		Outcome["attempted"] += 1
		WriteOk := false
		try {
			Result := HasMethod(WriteFn, "Call") ? WriteFn.Call() : false
			WriteOk := (Result is Integer) && Result == 1
		} catch as Err {
			try LoggerError("HotstringsConfigWindow",
				"Persistence writer {1} raised an error: {2}.", Index, Err.Message)
		}
		if WriteOk {
			Outcome["succeeded"] += 1
		} else {
			Outcome["failed"] += 1
			Outcome["failed_indices"].Push(Index)
		}
	}
	Outcome["ok"] := Outcome["failed"] == 0
	_HCW_RunOutcomeCallback(ReconcileFn, Outcome, "reconciliation")
	if Outcome["ok"] {
		_HCW_RunOutcomeCallback(SuccessFn, Outcome, "success")
	} else {
		_HCW_RunOutcomeCallback(FailureFn, Outcome, "failure")
	}
	return Outcome
}

; Outcome callbacks are UI/backstop work reached from Gui, timer, and COM event
; threads. A notifier or stale control must not turn an already-contained write
; refusal into an unhandled driver exception.
_HCW_RunOutcomeCallback(CallbackFn, Outcome, Label) {
	if !HasMethod(CallbackFn, "Call")
		return true
	try {
		CallbackFn.Call(Outcome)
		return true
	} catch as Err {
		try LoggerError("HotstringsConfigWindow",
			"Write-batch {1} callback failed: {2}.", Label, Err.Message)
		return false
	}
}

_HCW_ReportWriteFailure(Outcome) {
	if (Outcome is Map)
		Outcome["failure_reported"] := true
	StateUnchanged := !(Outcome is Map) || Outcome.Get("succeeded", 0) == 0
	return ConfigReportPersistenceFailure(
		"the hotstrings configuration change", 0, "", StateUnchanged)
}

_HCW_ReconcileNativeCurrent(Outcome) {
	_HCW_LoadCurrent()
}

_HCW_ReconcileNativeReset(Outcome) {
	; A partial bulk failure can still have durably changed a baked delay or
	; priority. Rebuild before showing canonical state so tooltip and engine agree.
	if Outcome["succeeded"] > 0
		_HCW_RepublishIfBakedField("delay")
	if !Outcome["ok"]
		_HCW_LoadCurrent()
}

_HCW_CompleteNativeReset(Outcome) {
	global _HCWGui, _HCWWidgets
	if (_HCWGui != 0)
		_HCWGui.Destroy()
	; Destroy() does not fire OnEvent('Close'), so clear globals manually to
	; prevent OpenHotstringsConfigWindow from showing a destroyed Gui.
	_HCWGui := 0
	_HCWWidgets := 0
	TrayTip(t("hs_config.notify_reset_all"), t("hs_config.btn_reset_all"), "Iconi Mute")
}




; ============================================================
; ============================================================
; ======= 1/ Mutation handlers ===============================
; ============================================================
; ============================================================

_HCW_OnDelayChanged() {
	global _HCWWidgets
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Ms := _HCWWidgets.DelayEdit.Value + 0
	if (Ms < 0) {
		Ms := 0
	}
	; Coalesce a burst of digits into a single write — see _HCW_ArmNumericWrite.
	_HCW_ArmNumericWrite("delay", Entry, Sec, Ms / 1000)
}

_HCW_OnPriorityChanged() {
	global _HCWWidgets
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Prio := _HCWWidgets.PriorityEdit.Value + 0
	if (Prio < 0) {
		Prio := 0
	} else if (Prio > 100) {
		Prio := 100
	}
	; Coalesce a burst of digits into a single write — see _HCW_ArmNumericWrite.
	_HCW_ArmNumericWrite("priority", Entry, Sec, Prio)
}

; Replace only an edit for the same entry/section/field. Delay and priority have
; independent controls, so one global replaceable slot loses whichever field
; was typed first when both change inside the same debounce window.
_HCW_NumericWriteMatches(Pending, Entry, Sec, Field) {
	; Catalogue rebuilds replace Entry objects even when they describe the same
	; logical source. Key is the stable identity shared by common, personal, and
	; extension entries; object identity would strand old timer payloads.
	return Pending.Entry.Key == Entry.Key && Pending.Sec == Sec
		&& Pending.Field == Field
}

_HCW_QueueNumericWrite(PendingWrites, Pending, ReplaceExisting := true) {
	for Index, Existing in PendingWrites {
		if _HCW_NumericWriteMatches(
			Existing, Pending.Entry, Pending.Sec, Pending.Field) {
			if ReplaceExisting
				PendingWrites[Index] := Pending
			return PendingWrites.Length
		}
	}
	PendingWrites.Push(Pending)
	return PendingWrites.Length
}

; Reinsert only writers that refused or raised. If a newer edit arrived while
; the old batch yielded to I/O, preserve that newer queued value rather than
; overwriting it with the failed snapshot.
_HCW_RequeueFailedNumericWrites(PendingWrites, Outcome) {
	global _HCW_PendingNumericWrites
	Requeued := 0
	for _, Index in Outcome.Get("failed_indices", []) {
		if (Index < 1 || Index > PendingWrites.Length)
			continue
		Before := _HCW_PendingNumericWrites.Length
		_HCW_QueueNumericWrite(
			_HCW_PendingNumericWrites, PendingWrites[Index], false)
		if (_HCW_PendingNumericWrites.Length > Before)
			Requeued += 1
	}
	return Requeued
}

; Remove only the pending value invalidated by a per-field reset. The reverse
; walk is safe if a malformed/re-entrant caller managed to enqueue duplicates.
_HCW_RemoveNumericWrite(PendingWrites, Entry, Sec, Field) {
	Removed := 0
	Index := PendingWrites.Length
	while (Index >= 1) {
		Pending := PendingWrites[Index]
		if _HCW_NumericWriteMatches(Pending, Entry, Sec, Field) {
			PendingWrites.RemoveAt(Index)
			Removed += 1
		}
		Index -= 1
	}
	return Removed
}

_HCW_CancelNumericWrite(Entry, Sec, Field) {
	global _HCW_PendingNumericWrites
	Removed := _HCW_RemoveNumericWrite(_HCW_PendingNumericWrites, Entry, Sec, Field)
	if (_HCW_PendingNumericWrites.Length == 0)
		SetTimer(_HCW_FlushNumericWrite, 0)
	return Removed
}

; Reset All invalidates every queued candidate. Disarm without flushing: writing
; a value immediately before clearing it is redundant, and a refusal of that
; obsolete write must not prevent the reset from reaching its real writes.
_HCW_CancelAllNumericWrites() {
	global _HCW_PendingNumericWrites
	Removed := (_HCW_PendingNumericWrites is Array)
		? _HCW_PendingNumericWrites.Length : 0
	_HCW_PendingNumericWrites := []
	SetTimer(_HCW_FlushNumericWrite, 0)
	return Removed
}

; Convert the captured values into one aggregate persistence batch. Keeping
; this transformation explicit makes the queue contract behaviour-testable:
; every distinct queued field must produce exactly one writer invocation.
_HCW_RunNumericWriteBatch(PendingWrites, WriterFn, ReconcileFn := 0, FailureFn := 0) {
	Writes := []
	for _, Pending in PendingWrites {
		Writes.Push(WriterFn.Bind(
			Pending.Entry, Pending.Sec, Pending.Field, Pending.Value))
	}
	return _HCW_RunWriteBatch(Writes, ReconcileFn, 0, FailureFn)
}

; Arm (or re-arm) the shared debounce timer. Repeated digits in one field
; coalesce, while edits to another field remain queued. The clamped value and
; current selection are captured so navigation cannot retarget the write.
_HCW_ArmNumericWrite(Field, Entry, Sec, Value) {
	global _HCW_PendingNumericWrites, _HCW_NUMERIC_DEBOUNCE_MS
	_HCW_QueueNumericWrite(_HCW_PendingNumericWrites,
		{ Field: Field, Entry: Entry, Sec: Sec, Value: Value })
	SetTimer(_HCW_FlushNumericWrite, -_HCW_NUMERIC_DEBOUNCE_MS)
}

; Fired once the numeric-edit burst settles. Drain snapshots until the queue is
; stable: file I/O may yield, and a new Change event can enqueue another value
; while an earlier snapshot is being persisted. A nested timer/transition sees
; the active owner and blocks instead of declaring that incomplete drain done.
_HCW_FlushNumericWrite(RefreshOnSuccess := true, WriterFn := 0,
	RefreshFn := 0, FailureFn := 0) {
	global _HCW_PendingNumericWrites, _HCW_NumericDrainActive
	if _HCW_NumericDrainActive
		return false
	if !(_HCW_PendingNumericWrites is Array)
		_HCW_PendingNumericWrites := []
	if (_HCW_PendingNumericWrites.Length == 0)
		return true
	if !HasMethod(WriterFn, "Bind")
		WriterFn := _HCW_SetOverride
	if !HasMethod(RefreshFn, "Call")
		RefreshFn := _HCW_LoadCurrent
	if !HasMethod(FailureFn, "Call")
		FailureFn := _HCW_ReportWriteFailure.Bind()

	_HCW_NumericDrainActive := true
	WroteAny := false
	try {
		loop {
			PendingWrites := _HCW_PendingNumericWrites
			if (PendingWrites.Length == 0)
				break
			; Clear before I/O so re-entrant input lands in a fresh queue that the
			; next loop iteration observes.
			_HCW_PendingNumericWrites := []
			SetTimer(_HCW_FlushNumericWrite, 0)
			Outcome := _HCW_RunNumericWriteBatch(
				PendingWrites, WriterFn, 0, FailureFn)
			if !Outcome["ok"] {
				_HCW_RequeueFailedNumericWrites(PendingWrites, Outcome)
				return false
			}
			WroteAny := true
		}
		if (RefreshOnSuccess && WroteAny)
			RefreshFn.Call()
		return true
	} finally {
		_HCW_NumericDrainActive := false
	}
}

_HCW_OnColorChanged() {
	global _HCWWidgets, _HCW_CurrentColorOptions
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Idx := _HCWWidgets.ColorDD.Value
	if (Idx < 1) {
		return
	}
	Hex := _HCW_CurrentColorOptions[Idx].Hex
	WriteFn := (Hex == "")
		? _HCW_ClearOverride.Bind(Entry, Sec, "color")
		: _HCW_SetOverride.Bind(Entry, Sec, "color", Hex)
	Outcome := _HCW_RunWriteBatch([WriteFn], _HCW_ReconcileNativeCurrent.Bind(),
		0, _HCW_ReportWriteFailure.Bind())
	return Outcome["ok"]
}

_HCW_OnTooltipChanged() {
	global _HCWWidgets
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Val := (_HCWWidgets.TooltipChk.Value == 1)
	Outcome := _HCW_RunWriteBatch([
		_HCW_SetOverride.Bind(Entry, Sec, "show_tooltip", Val)
	], _HCW_ReconcileNativeCurrent.Bind(), 0, _HCW_ReportWriteFailure.Bind())
	return Outcome["ok"]
}

_HCW_ClearField(Field) {
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	; A timer armed by the value being reset must not restore it after the clear.
	_HCW_CancelNumericWrite(Entry, Sec, Field)
	Outcome := _HCW_RunWriteBatch([
		_HCW_ClearOverride.Bind(Entry, Sec, Field)
	], _HCW_ReconcileNativeCurrent.Bind(), 0, _HCW_ReportWriteFailure.Bind())
	return Outcome["ok"]
}

; Build backend-neutral reset operations once for both native and WebView
; presentations. Personal TOML requires one write per supported field, while
; the override store clears all fields through its empty-field operation.
_HCW_BuildResetAllPlan(CategoryList, SectionsFn := 0, PersonalFields := 0) {
	if !HasMethod(SectionsFn, "Call")
		SectionsFn := _HCW_GetSections
	if !(PersonalFields is Array)
		PersonalFields := _PersonalTomlOverrideFields()
	Plan := []
	for _, Entry in CategoryList {
		Sections := SectionsFn.Call(Entry)
		if Entry.IsPersonal {
			for _, Field in PersonalFields
				Plan.Push({ Kind: "personal", Path: Entry.Path, Sec: "", Field: Field })
			for _, Sec in Sections {
				for _, Field in PersonalFields {
					Plan.Push({ Kind: "personal", Path: Entry.Path,
						Sec: Sec.Name, Field: Field })
				}
			}
		} else {
			Category := Entry.IsExtension ? "ext." . Entry.ExtId : Entry.Key
			Plan.Push({ Kind: "override", Category: Category, Sec: "", Field: "" })
			for _, Sec in Sections {
				Plan.Push({ Kind: "override", Category: Category,
					Sec: Sec.Name, Field: "" })
			}
		}
	}
	return Plan
}

_HCW_BuildResetAllWrites(CategoryList) {
	Writes := []
	for _, Item in _HCW_BuildResetAllPlan(CategoryList) {
		if (Item.Kind == "personal") {
			Writes.Push(_HCW_PatchTomlMeta.Bind(
				Item.Path, Item.Sec, Item.Field, ""))
		} else {
			Writes.Push(HotstringsClearOverride.Bind(
				Item.Category, Item.Sec, Item.Field))
		}
	}
	return Writes
}

_HCW_ResetAll() {
	global _HCW_CATEGORY_LIST, _HCWGui, _HCWWidgets
	; The reset supersedes every pending numeric candidate. Cancel before the
	; loop so no timer can restore a cleared value and no obsolete write failure
	; can block the reset itself.
	_HCW_CancelAllNumericWrites()
	Writes := _HCW_BuildResetAllWrites(_HCW_CATEGORY_LIST)
	Outcome := _HCW_RunWriteBatch(Writes, _HCW_ReconcileNativeReset.Bind(),
		_HCW_CompleteNativeReset.Bind(), _HCW_ReportWriteFailure.Bind())
	return Outcome["ok"]
}

; Force every category/extension to grey at file level; clear per-section colour
; overrides for a consistent cascade. Personal file TOMLs are patched atomically.
_HCW_SetAllGrey() {
	global _HCW_CATEGORY_LIST
	Grey := "#6e6e73"
	Writes := []
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			Writes.Push(_HCW_PatchTomlMeta.Bind(E.Path, "", "color", Grey))
			for _, Sec in _HCW_GetSections(E) {
				Writes.Push(_HCW_PatchTomlMeta.Bind(E.Path, Sec.Name, "color", ""))
			}
		} else if E.IsExtension {
			Writes.Push(HotstringsSetOverride.Bind("ext." . E.ExtId, "", "color", Grey))
			for _, Sec in _HCW_GetSections(E) {
				Writes.Push(HotstringsClearOverride.Bind("ext." . E.ExtId, Sec.Name, "color"))
			}
		} else {
			Writes.Push(HotstringsSetOverride.Bind(E.Key, "", "color", Grey))
			for _, Sec in _HCW_GetSections(E) {
				Writes.Push(HotstringsClearOverride.Bind(E.Key, Sec.Name, "color"))
			}
		}
	}
	Outcome := _HCW_RunWriteBatch(Writes, _HCW_ReconcileNativeCurrent.Bind(),
		0, _HCW_ReportWriteFailure.Bind())
	return Outcome["ok"]
}

_HCW_OnClose() {
	global _HCWGui, _HCWWidgets, _HCW_LastSelection
	; Commit any numeric edit still inside the debounce window before tearing
	; down the widgets, otherwise the last value the user typed would be lost.
	if !_HCW_DrainBeforeTransition(_HCW_FlushNumericWrite.Bind(false))
		return 1
	_HCWGui := 0
	_HCWWidgets := 0
	_HCW_LastSelection := 0
	return 0
}




; ============================================================
; ============================================================
; ======= 2/ Source-aware read/write dispatch ================
; ============================================================
; ============================================================

; Write an override to the correct backend:
; - personal  → [_meta] in the TOML file
; - extension → hotstrings_config.toml under key "ext.<id>"
; - common    → hotstrings_config.toml under the category key
;
; Every backend reports whether the value reached disk, so the result is passed
; straight through rather than dropped: a caller that announces success must be
; able to tell that the write was refused (a locked personal file) or failed.
; @returns {Boolean} True when the value was persisted.
_HCW_SetOverride(Entry, Sec, Field, Value) {
	if !_HCW_IsOverrideField(Field) {
		try LoggerError("HotstringsConfigWindow",
			"Refusing unknown override field.")
		return false
	}
	if (Field == "priority" and !HotstringsTryPriority(Value, &Priority)) {
		try LoggerError("HotstringsConfigWindow",
			"Refusing priority outside the integer 0..100 domain: '{1}'.", Value)
		return false
	}
	if (Field == "show_tooltip"
			and !HotstringsTryBooleanOverride(Value, &TooltipValue)) {
		try LoggerError("HotstringsConfigWindow",
			"Refusing non-Boolean show_tooltip value: '{1}'.", Value)
		return false
	}
	if (Field == "color" and !(Value is String)) {
		try LoggerError("HotstringsConfigWindow",
			"Refusing non-string color override.")
		return false
	}
	if Entry.IsPersonal {
		Ok := _HCW_PatchTomlMeta(Entry.Path, Sec, Field, Value)
	} else if Entry.IsExtension {
		Ok := HotstringsSetOverride("ext." . Entry.ExtId, Sec, Field, Value)
	} else {
		Ok := HotstringsSetOverride(Entry.Key, Sec, Field, Value)
	}
	Persisted := (Ok is Integer) && Ok != 0
	if Persisted
		_HCW_RepublishIfBakedField(Field)
	return Persisted
}

; @returns {Boolean} True when the cleared state was persisted.
_HCW_ClearOverride(Entry, Sec, Field) {
	if !_HCW_IsOverrideField(Field) {
		try LoggerError("HotstringsConfigWindow",
			"Refusing unknown override field.")
		return false
	}
	if Entry.IsPersonal {
		Ok := _HCW_PatchTomlMeta(Entry.Path, Sec, Field, "")
	} else if Entry.IsExtension {
		Ok := HotstringsClearOverride("ext." . Entry.ExtId, Sec, Field)
	} else {
		Ok := HotstringsClearOverride(Entry.Key, Sec, Field)
	}
	Persisted := (Ok is Integer) && Ok != 0
	if Persisted
		_HCW_RepublishIfBakedField(Field)
	return Persisted
}

; Re-register live when the field just written is one the engine baked at
; registration time. Without this the window and the engine hold two different
; values for the same setting until the next Reload — the window's is the one the
; user is looking at, the engine's is the one that decides.
;
; Failure is contained: a rebuild that throws must not lose the write that
; already succeeded, nor tear down the config window the user is still editing in.
_HCW_RepublishIfBakedField(Field) {
	global HCW_REBUILD_ON_WRITE_FIELDS
	if !HCW_REBUILD_ON_WRITE_FIELDS.Has(Field)
		return
	try {
		RebuildHotstringsLive()
	} catch as Err {
		try LoggerError("HotstringsConfigWindow", "Live re-registration after writing '{1}' failed: {2}. The value is persisted but the running engine still uses the previous one until the next reload.", Field, Err.Message)
	}
}

; Resolve the effective delay, color, and show_tooltip for the current entry.
_HCW_Resolve(Entry, Sec) {
	if Entry.IsPersonal {
		return _HCW_ReadTomlMeta(Entry.Path, Sec)
	}
	if Entry.IsExtension {
		R := HotstringsResolveExt(Entry.ExtId, Entry.Path, Sec)
		return { Delay: R.Delay, Color: R.Color, ShowTooltip: R.ShowTooltip,
			Priority: (R.HasOwnProp("Priority") ? R.Priority : "") }
	}
	return HotstringsResolve(Entry.Key, Sec)
}

; Read effective delay, color, show_tooltip, and priority from [_meta] of a
; personal TOML file, applying the cascade: section → file → default (true for
; ShowTooltip; priority stays empty so the caller can fall back to the source tier).
_HCW_ReadTomlMeta(Path, Sec) {
	FileCfg := ParseTomlGroupConfig("__personal__", Path)
	Result := { Delay: FileCfg.Delay, Color: FileCfg.Color, ShowTooltip: FileCfg.ShowTooltip != "" ? FileCfg.ShowTooltip : true,
		Priority: (FileCfg.HasOwnProp("Priority") ? FileCfg.Priority : "") }
	if (Sec != "" and FileCfg.Sections.Has(StrLower(Sec))) {
		SecCfg := FileCfg.Sections[StrLower(Sec)]
		if (SecCfg.Delay != "") {
			Result.Delay := SecCfg.Delay
		}
		if (SecCfg.Color != "") {
			Result.Color := SecCfg.Color
		}
		if (SecCfg.ShowTooltip != "") {
			Result.ShowTooltip := SecCfg.ShowTooltip
		}
		if (SecCfg.HasOwnProp("Priority") and SecCfg.Priority != "") {
			Result.Priority := SecCfg.Priority
		}
	}
	return Result
}




; ============================================================
; ============================================================
; ======= 3/ Personal TOML [_meta] patcher ==================
; ============================================================
; ============================================================

; Patch or clear a single field (delay or color) in [_meta] or
; [_meta.sections.<sec>] of a personal TOML file. When Value is "" the key
; is removed. The file is rewritten in-place; all other content is preserved.
;
; Strategy: scan lines once, track which "zone" we are in, emit each line
; unchanged except for the target zone where the field is added or removed.
; If the target header was never found, append it at the end.
; @param Path {String} Absolute path of the personal TOML file to patch.
; @param Sec {String} Section name, or "" for the file-level [_meta].
; @param Field {String} "delay", "color", "priority" or "show_tooltip".
; @param Value {String} New value, or "" to remove the key.
; @returns {Boolean} True when the file was rewritten; false when the patch was
;          refused or the write failed — in both cases the file is untouched.
_HCW_PatchTomlMeta(Path, Sec, Field, Value) {
	if !_HCW_IsPersonalMetaTargetValid(Sec, Field) {
		try LoggerError("HotstringsConfigWindow",
			"Refusing invalid personal TOML section or field identifier.")
		return false
	}
	try return _PersonalTomlCommitPatch(Path,
		_HCW_BuildTomlMetaPatch.Bind(Sec, Field, Value))
	catch as Err {
		try LoggerError("HotstringsConfigWindow",
			"Failed to patch TOML meta in '{1}': {2}.", Path, Err.Message)
		return false
	}
}

; Pure transformation used only after _PersonalTomlCommitPatch owns the path
; and has read a fresh durable snapshot. Keeping every filesystem operation in
; that shared helper prevents this window from bypassing the personal editor's
; logical lease or truncating the target before a fallible write completes.
_HCW_BuildTomlMetaPatch(Sec, Field, Value, FileContent) {
	if !_HCW_IsPersonalMetaTargetValid(Sec, Field)
		throw ValueError("Invalid personal TOML section or field identifier.")
	Lines := StrSplit(FileContent, "`n", "`r")
	Field := StrLower(Field)
	Sec   := StrLower(Sec)

	TargetHeader := (Sec == "") ? "[_meta]" : "[_meta.sections." . Sec . "]"

	InTarget  := false
	Found     := false
	FieldDone := false
	Out       := []

	for _, RawLine in Lines {
		Line := Trim(RawLine, " `t`r")

		if RegExMatch(Line, "^\[") {
			if InTarget and !FieldDone and Value != "" {
				Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
				FieldDone := true
			}
			InTarget := (Line == TargetHeader)
			if InTarget {
				Found := true
				FieldDone := false
			}
			Out.Push(RawLine)
			continue
		}

		if InTarget {
			if RegExMatch(Line, "^" . Field . "\s*=", &_) {
				if Value != "" and !FieldDone {
					Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
					FieldDone := true
				}
				continue
			}
		}

		Out.Push(RawLine)
	}

	if InTarget and !FieldDone and Value != "" {
		Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
	}

	if !Found and Value != "" {
		Out.Push("")
		Out.Push(TargetHeader)
		Out.Push(Field . " = " . _HCW_TomlValue(Field, Value))
	}

	NewContent := ""
	for I, L in Out {
		NewContent .= L
		if (I < Out.Length) {
			NewContent .= "`n"
		}
	}
	return NewContent
}

_HCW_IsOverrideField(Field) {
	return Field is String
		&& (Field == "delay" || Field == "color"
			|| Field == "priority" || Field == "show_tooltip")
}

_HCW_IsPersonalMetaTargetValid(Sec, Field) {
	return Sec is String && (Sec == "" || RegExMatch(Sec, "^[a-z0-9_]+$"))
		&& _HCW_IsOverrideField(Field)
}

; Format a value for TOML output.
; delay → bare float (seconds); show_tooltip → bare boolean; priority → bare
; integer; color → quoted string.
_HCW_TomlValue(Field, Value) {
	if (Field == "delay") {
		; Single source of truth shared with the override store so the same
		; logical delay can never serialise to two different strings.
		return HotstringsSerialiseDelay(Value)
	}
	if (Field == "show_tooltip") {
		if !HotstringsTryBooleanOverride(Value, &TooltipValue)
			throw TypeError("show_tooltip must be a Boolean.", -1, Value)
		return TooltipValue ? "true" : "false"
	}
	if (Field == "priority") {
		if !HotstringsTryPriority(Value, &Priority)
			throw ValueError("Priority must be an integer from 0 through 100.", -1, Value)
		return Format("{:d}", Priority)
	}
	if !(Value is String)
		throw TypeError("Color must be a String.", -1, Value)
	return TOML_RenderString(Value)
}
