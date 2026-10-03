; infra/menu_population.ahk

; ==============================================================================
; MODULE: Native Menu Population
; DESCRIPTION:
; Publish leaf pickers with a real first row, prewarm them in small batches, and
; finish a requested picker before Windows paints it. Ownership follows HMENU
; reachability across root replacements; native callbacks keep their tokens.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MenuPopulationBuilding := false
global _MenuPopulationPublished := false
global MENU_POPULATION_TICK_MS := 10
; Native flag decoding measured ~6 ms per row. Background work must not
; interrupt a foreground WebView Promise wait; navigation still completes inline.
global MENU_POPULATION_THREAD_PRIORITY := -1
; A 384-choice native fixture took 17–23 ms in one critical section. Sixteen
; rows keep ordinary batches near 1 ms while retaining synchronous before-paint
; completion for navigation; this bounds work, not native-call wall time.
global MENU_POPULATION_BATCH_ROWS := 16

class MenuPopulationReentryError extends Error {
}

/** Owns the unpublished remainder of native leaf menus for one root build. */
class MenuPopulation {
	__New() {
		; Install before a seeded menu can be attached, separately from timers.
		OnMessage(0x117, MenuPopulation_OnInitPopup)
		this.Pending := Map()
		this.Timer := 0
		this.Started := false
		this.Eligible := false
		this.Failed := false
		this.Completed := 0
	}

	/** Builds a real first row; the remaining leaf choices stay build-local. */
	Create(Rows, ListId, Depth) {
		MenuObj := Menu()
		this.Fill(MenuObj, Rows, ListId, Depth)
		return MenuObj
	}

	/** Seeds an existing detached picker without replacing its native identity. */
	Fill(MenuObj, Rows, ListId, Depth) {
		global MR_MAX_LIST_DEPTH
		if Depth > MR_MAX_LIST_DEPTH {
			_MR_RenderRows(MenuObj, Rows, ListId, Depth, 0)
			return MenuObj
		}
		Remainder := []
		Seeded := false
		for Row in Rows {
			if Seeded {
				Remainder.Push(Row)
				continue
			}
			if _MR_RenderRows(MenuObj, [Row], ListId, Depth, 0, true) > 0
				Seeded := true
		}
		_MR_NormalizeSeparators(MenuObj)
		if Remainder.Length > 0
			this.Pending[MenuObj.Handle] := { MenuObj: MenuObj, Rows: Remainder,
				ListId: ListId, Depth: Depth, NextRow: 1, Busy: false, Failure: "" }
		return MenuObj
	}

	/** Appends an owned prefix, or completes all remaining rows before paint. */
	Complete(Handle, Reason := "navigation", RenderFn := 0, MaxRows := 0) {
		if !(MaxRows is Integer) || MaxRows < 0
			throw ValueError("Native population row limit must be a nonnegative integer")
		PreviousCritical := Critical("On")
		StartedAt := HotPath_Now()
		OwnBusy := false
		Appended := 0
		Remaining := 0
		Finished := false
		try {
			if !this.Pending.Has(Handle)
				return false
			Entry := this.Pending[Handle]
			if Entry.Busy
				throw MenuPopulationReentryError("Native leaf population reentered")
			if Entry.Failure != ""
				throw Error("Native leaf population previously failed: " . Entry.Failure)
			Entry.Busy := true
			OwnBusy := true
			LastRow := MaxRows ? Min(Entry.Rows.Length, Entry.NextRow + MaxRows - 1) : Entry.Rows.Length
			Batch := []
			loop LastRow - Entry.NextRow + 1
				Batch.Push(Entry.Rows[Entry.NextRow + A_Index - 1])
			; Only prepared rows are appended here: no file discovery or provider
			; invocation. Leaf menus retain their own remaining rows. Tray requests wait;
			; unexpected synchronous 0x117 reentry is refused before partial paint.
			if HasMethod(RenderFn, "Call")
				RenderFn.Call(Entry.MenuObj, Batch, Entry.ListId, Entry.Depth)
			else
				_MR_RenderRows(Entry.MenuObj, Batch, Entry.ListId, Entry.Depth, 0, true)
			Appended := Batch.Length
			Entry.NextRow := LastRow + 1
			Remaining := Entry.Rows.Length - LastRow
			if Remaining == 0 {
				; Normalize once, across every batch boundary. Intermediate trailing
				; separators belong to the unpublished remainder, never a painted menu.
				_MR_NormalizeSeparators(Entry.MenuObj)
				this.Pending.Delete(Handle)
				this.Completed += 1
				Finished := true
			}
		} catch as Err {
			if IsSet(Entry) && !(Err is MenuPopulationReentryError) {
				Entry.Failure := Err.Message
				this.Failed := true
				this.Stop()
			}
			try LoggerError("MenuPopulation", "Native leaf could not be completed for {1}: {2}.", Reason, Err.Message)
			throw Err
		} finally {
			if OwnBusy
				Entry.Busy := false
			Critical(PreviousCritical)
			HotPath_LogIfSlow("Menu.populate_leaf", StartedAt,
				Format("{1}; list={2}; rows={3}; remaining={4}",
					Reason, IsSet(Entry) ? Entry.ListId : "unowned", Appended, Remaining))
		}
		if Finished
			try LoggerDebug("MenuPopulation", "Leaf '{1}' completed for {2}; {3} pending.",
				Entry.ListId, Reason, this.Pending.Count)
		if this.Pending.Count == 0
			this.Stop(true)
		return true
	}

	/** Arms bounded background preparation after the actual root is published. */
	Start() {
		global MENU_POPULATION_TICK_MS, MENU_POPULATION_THREAD_PRIORITY
		this.Eligible := true
		if A_IsSuspended || this.Failed
			return false
		if this.Started || this.Pending.Count == 0
			return false
		this.Started := true
		this.Timer := ObjBindMethod(this, "Pump")
		try LoggerStart("MenuPopulation", "Prewarming {1} native leaf menu(s)…", this.Pending.Count)
		SetTimer(this.Timer, -MENU_POPULATION_TICK_MS, MENU_POPULATION_THREAD_PRIORITY)
		return true
	}

	/** Appends one bounded row batch, then yields to input and tray requests. */
	Pump(*) {
		global MENU_POPULATION_TICK_MS, MENU_POPULATION_BATCH_ROWS, MENU_POPULATION_THREAD_PRIORITY
		if A_IsSuspended {
			this.Stop()
			return
		}
		for Handle in this.Pending {
			this.Complete(Handle, "background", 0, MENU_POPULATION_BATCH_ROWS)
			if this.Pending.Count > 0 && HasMethod(this.Timer, "Call")
				SetTimer(this.Timer, -MENU_POPULATION_TICK_MS, MENU_POPULATION_THREAD_PRIORITY)
			return
		}
		this.Stop(true)
	}

	/** Releases timer ownership and closes the prewarming lifecycle. */
	Stop(Succeeded := false) {
		if HasMethod(this.Timer, "Call") {
			SetTimer(this.Timer, 0)
			this.Timer := 0
		}
		if this.Started {
			this.Started := false
			if Succeeded {
				try LoggerSuccess("MenuPopulation", "Native leaf prewarming completed: {1} menu(s).", this.Completed)
			} else {
				try LoggerWarn("MenuPopulation", "Native leaf prewarming retired with {1} pending menu(s).", this.Pending.Count)
			}
		}
	}
}

/** Accepts only leaf row arrays; nested trees retain their ordinary renderer. */
MenuPopulation_IsLeaf(Rows) {
	for Row in Rows {
		if Row is Map && (Row.Has("items") || Row.Has("submenu"))
			return false
	}
	return true
}

/** Completes an owned popup in the synchronous message sent before its paint. */
MenuPopulation_OnInitPopup(Handle, *) {
	; Native configuration navigation remains available while paused. This only
	; prepares rows: feature commands remain fenced by root pause greying.
	global _MenuPopulationPublished
	if IsSet(_MenuPopulationPublished) && _MenuPopulationPublished is MenuPopulation {
		try _MenuPopulationPublished.Complete(Handle)
		catch as Err {
			TrayMenuCancelNavigation()
			throw Err
		}
	}
}

/** Retains deferred leaves only when their native menus survive publication. */
MenuPopulation_Publish(RootMenu) {
	global _MenuPopulationBuilding, _MenuPopulationPublished
	NextOwner := _MenuPopulationBuilding is MenuPopulation
		? _MenuPopulationBuilding : _MenuPopulationPublished
	if !(NextOwner is MenuPopulation)
		return
	LiveHandles := Map()
	_MenuDispatchCollectLiveIds(RootMenu.Handle, Map(), LiveHandles)
	Previous := _MenuPopulationPublished
	if Previous is MenuPopulation && Previous != NextOwner {
		Previous.Stop()
		for Handle, Entry in Previous.Pending {
			if LiveHandles.Has(Handle)
				NextOwner.Pending[Handle] := Entry
		}
		Previous.Pending.Clear()
	}
	Retired := []
	for Handle in NextOwner.Pending {
		if !LiveHandles.Has(Handle)
			Retired.Push(Handle)
	}
	for Handle in Retired
		NextOwner.Pending.Delete(Handle)
	_MenuPopulationPublished := NextOwner
	if NextOwner.Pending.Count == 0
		NextOwner.Stop(true)
}

/** Resumes preparation after pause; a new boot owner starts after its stage ends. */
MenuPopulation_Resume() {
	global _MenuPopulationPublished
	if !A_IsSuspended && IsSet(_MenuPopulationPublished)
			&& _MenuPopulationPublished is MenuPopulation && _MenuPopulationPublished.Eligible
		_MenuPopulationPublished.Start()
}

/** Retires timer and native-menu references when the driver exits. */
MenuPopulation_Shutdown() {
	global _MenuPopulationPublished
	if IsSet(_MenuPopulationPublished) && _MenuPopulationPublished is MenuPopulation {
		_MenuPopulationPublished.Stop()
		_MenuPopulationPublished.Pending.Clear()
		_MenuPopulationPublished := false
	}
}
