; ui/hotstrings_config_window/hcw_mutations.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window — Mutations
; DESCRIPTION:
; Write-path functions for the hotstrings config window. Contains all handlers
; that mutate state: debounce-armed numeric writes, color/tooltip change
; handlers, reset-all and set-all-grey bulk operations, the window-close flush,
; source-aware override dispatch (SetOverride / ClearOverride / Resolve /
; ReadTomlMeta), and the personal TOML [_meta] in-place patcher.
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

; Arm (or re-arm) the debounce timer for a numeric field. Each new keystroke
; cancels the previous one-shot timer and starts a fresh window, so the
; expensive _HCW_SetOverride / _HCW_LoadCurrent runs once when the user pauses
; rather than on every digit. The clamped value AND the current selection are
; captured here so the write lands on the right entry even if the user switches
; selection or closes the window before the timer fires.
_HCW_ArmNumericWrite(Field, Entry, Sec, Value) {
	global _HCW_PendingNumericWrite, _HCW_NUMERIC_DEBOUNCE_MS
	_HCW_PendingNumericWrite := { Field: Field, Entry: Entry, Sec: Sec, Value: Value }
	SetTimer(_HCW_FlushNumericWrite, -_HCW_NUMERIC_DEBOUNCE_MS)
}

; Fired once the numeric-edit burst settles. Persists the single captured
; override and refreshes the controls. Safe to call eagerly (e.g. on selection
; change or window close) to commit an in-flight edit; it is a no-op when no
; write is pending.
_HCW_FlushNumericWrite() {
	global _HCW_PendingNumericWrite
	Pending := _HCW_PendingNumericWrite
	if !IsObject(Pending) {
		return
	}
	; Clear the pending slot AND cancel the armed one-shot timer first so an
	; eager flush followed by the timer firing cannot persist the same write
	; twice.
	_HCW_PendingNumericWrite := 0
	SetTimer(_HCW_FlushNumericWrite, 0)
	_HCW_SetOverride(Pending.Entry, Pending.Sec, Pending.Field, Pending.Value)
	_HCW_LoadCurrent()
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
	if (Hex == "") {
		_HCW_ClearOverride(Entry, Sec, "color")
	} else {
		_HCW_SetOverride(Entry, Sec, "color", Hex)
	}
	_HCW_LoadCurrent()
}

_HCW_OnTooltipChanged() {
	global _HCWWidgets
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	Val := (_HCWWidgets.TooltipChk.Value == 1)
	_HCW_SetOverride(Entry, Sec, "show_tooltip", Val)
	_HCW_LoadCurrent()
}

_HCW_ClearField(Field) {
	Entry := _HCW_SelectedEntry()
	Sec := _HCW_SelectedSection(Entry)
	_HCW_ClearOverride(Entry, Sec, Field)
	_HCW_LoadCurrent()
}

_HCW_ResetAll() {
	global _HCW_CATEGORY_LIST, _HCWGui, _HCWWidgets
	; Commit any debounced numeric edit BEFORE the reset loop runs. Flushing
	; AFTER the loop (the previous order) let a still-pending edit — armed by
	; _HCW_ArmNumericWrite up to _HCW_NUMERIC_DEBOUNCE_MS ago — persist on top
	; of the override the reset loop just cleared, silently un-resetting that
	; one field. Flushing first makes the loop's Clear/PatchTomlMeta calls the
	; genuinely last write for every field.
	_HCW_FlushNumericWrite()
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			_HCW_PatchTomlMeta(E.Path, "", "delay", "")
			_HCW_PatchTomlMeta(E.Path, "", "color", "")
			_HCW_PatchTomlMeta(E.Path, "", "priority", "")
			for _, Sec in _HCW_GetSections(E) {
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "delay", "")
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "priority", "")
			}
		} else if E.IsExtension {
			HotstringsClearOverride("ext." . E.ExtId, "", "")
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride("ext." . E.ExtId, Sec.Name, "")
			}
		} else {
			HotstringsClearOverride(E.Key, "", "")
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride(E.Key, Sec.Name, "")
			}
		}
	}
	; The loop above clears delay and priority through the storage primitives
	; DIRECTLY, so it never passes the _HCW_SetOverride / _HCW_ClearOverride choke
	; point where the republish lives. Both fields are baked into every Spec at
	; registration: clearing them only bumps the resolve generation, so the window
	; and the tooltip would advertise the default delay while the engine kept
	; gating on the value the user had set. One rebuild for the whole reset rather
	; than one per entry — the reset is a single user action, not N of them.
	_HCW_RepublishIfBakedField("delay")
	if (_HCWGui != 0) {
		_HCWGui.Destroy()
	}
	; Destroy() does not fire OnEvent('Close'), so clear globals manually to
	; prevent OpenHotstringsConfigWindow from trying to Show() a destroyed Gui
	_HCWGui := 0
	_HCWWidgets := 0
	TrayTip(t("hs_config.notify_reset_all"), t("hs_config.btn_reset_all"), "Iconi Mute")
}

; Force every category/extension to grey at file level; clear per-section colour
; overrides for a consistent cascade. Personal file TOMLs are patched in-place.
_HCW_SetAllGrey() {
	global _HCW_CATEGORY_LIST
	Grey := "#6e6e73"
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			_HCW_PatchTomlMeta(E.Path, "", "color", Grey)
			for _, Sec in _HCW_GetSections(E) {
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
			}
		} else if E.IsExtension {
			HotstringsSetOverride("ext." . E.ExtId, "", "color", Grey)
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride("ext." . E.ExtId, Sec.Name, "color")
			}
		} else {
			HotstringsSetOverride(E.Key, "", "color", Grey)
			for _, Sec in _HCW_GetSections(E) {
				HotstringsClearOverride(E.Key, Sec.Name, "color")
			}
		}
	}
	_HCW_LoadCurrent()
}

_HCW_OnClose() {
	global _HCWGui, _HCWWidgets
	; Commit any numeric edit still inside the debounce window before tearing
	; down the widgets, otherwise the last value the user typed would be lost.
	_HCW_FlushNumericWrite()
	_HCWGui := 0
	_HCWWidgets := 0
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
	if Entry.IsPersonal {
		Ok := _HCW_PatchTomlMeta(Entry.Path, Sec, Field, Value)
	} else if Entry.IsExtension {
		Ok := HotstringsSetOverride("ext." . Entry.ExtId, Sec, Field, Value)
	} else {
		Ok := HotstringsSetOverride(Entry.Key, Sec, Field, Value)
	}
	_HCW_RepublishIfBakedField(Field)
	return Ok
}

; @returns {Boolean} True when the cleared state was persisted.
_HCW_ClearOverride(Entry, Sec, Field) {
	if Entry.IsPersonal {
		Ok := _HCW_PatchTomlMeta(Entry.Path, Sec, Field, "")
	} else if Entry.IsExtension {
		Ok := HotstringsClearOverride("ext." . Entry.ExtId, Sec, Field)
	} else {
		Ok := HotstringsClearOverride(Entry.Key, Sec, Field)
	}
	_HCW_RepublishIfBakedField(Field)
	return Ok
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
	if !FileExist(Path) {
		return false
	}

	FileContent := ReadTomlFile(Path)
	; ReadTomlFile returns "" for an EXISTING file it could not open (a sync
	; client's exclusive handle, an AV scan, another editor) and records the path
	; in the shared unreadable sentinel precisely so writers of this shape refuse
	; — the same guard ApplyConfigToml, WritePersonalToml and TOML_BatchWrite
	; already carry. Without it "I could not read it" is indistinguishable from
	; "it was empty": the scan below finds nothing, and the rewrite serialises
	; that emptiness over the original — "Réinitialiser tout" truncates
	; personal_hotstrings.toml to zero bytes and every personal hotstring in it
	; is gone, under a success notification.
	if TOML_UnreadableFile(Path) {
		try LoggerError("HotstringsConfigWindow", "Refusing to patch '{1}': its current contents could not be read, and rewriting from an unread file discards every hotstring it holds.", Path)
		return false
	}
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

	_ParseTomlGroupConfig_InvalidatePath(Path)

	NewContent := ""
	for I, L in Out {
		NewContent .= L
		if (I < Out.Length) {
			NewContent .= "`n"
		}
	}
	try {
		F := FileOpen(Path, "w", "UTF-8")
		; FileOpen throws in v2 rather than returning falsy, so this is belt and
		; braces — but it turns any future falsy return into a loud error instead
		; of a skipped write against a file that has already been truncated.
		if !IsObject(F) {
			throw Error("FileOpen returned no handle for '" . Path . "'.")
		}
		F.Write(NewContent)
		; Close explicitly rather than leaving it to the collector: the config
		; window rewrites the same file several times in a row, and a handle still
		; open on the previous pass makes the next one fail for no visible reason.
		F.Close()
	} catch as Err {
		try LoggerError("HotstringsConfigWindow", "Failed to write TOML meta to '{1}': {2}.", Path, Err.Message)
		return false
	}
	return true
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
		return Value ? "true" : "false"
	}
	if (Field == "priority") {
		return Format("{:d}", Round(Value))
	}
	Escaped := StrReplace(Value, "\", "\\")
	Escaped := StrReplace(Escaped, '"', '\"')
	return '"' . Escaped . '"'
}
