; lib/menu_dispatcher.ahk

; ==============================================================================
; MODULE: Menu Dispatcher Bypass
; DESCRIPTION:
; Works around the pre-existing AHK 2.0 issue where tray-menu callbacks are
; silently dropped on a random ~30-50% of clicks. Full diagnosis lives in
; the project memory file ``project_ahk_menu_dispatcher_drop.md``: WM_COMMAND
; arrives at AHK's hidden window but AHK's internal WM_COMMAND -> callback
; dispatcher fails to fire the registered callback, with no error or warning.
; Bumping ``A_MaxThreads``, adding ``Critical``, and deferring with
; ``SetTimer(-1)`` all failed to fix it in earlier attempts.
;
; FEATURES & RATIONALE:
; 1. Parallel dispatch table: every menu callback registered through
;    ``RegisterMenuItem(MenuObj, ItemName, Callback)`` is recorded in a
;    global Map keyed by the Win32 menu-item ID (read back from
;    ``MenuObj.Handle`` via ``GetMenuItemID`` right after ``Menu.Add``).
; 2. Dispatch retry on WM_COMMAND: an ``OnMessage(0x0111)`` handler
;    schedules a delayed check after every menu click; if AHK's own
;    dispatcher hasn't fired the callback within 150 ms, we call it
;    ourselves from a fresh ``SetTimer`` thread (which has its own pseudo-
;    thread slot and is therefore not subject to whatever queue saturation
;    is causing AHK's drop).
; 3. No double-fire: the wrapped callback bumps a per-ItemId "last fire"
;    timestamp on entry. The delayed check compares the pre-click value
;    captured in the OnMessage handler against the post-delay one — if
;    they differ, AHK did dispatch and the retry is a no-op.
; 4. Opt-in: only callbacks registered via ``RegisterMenuItem`` get the
;    bypass treatment. Ad-hoc ``Menu.Add(...)`` calls keep AHK's native
;    (sometimes-flaky) dispatch — fine for items that aren't user-facing
;    toggles or that the user can re-click without consequence.
;
; ID DISCOVERY: AHK 2.0 exposes the Win32 HMENU on ``Menu.Handle``. We do
; a two-step add — first a placeholder to let AHK allocate the item ID,
; read the ID via ``GetMenuItemID``, then a second ``Menu.Add`` with the
; same item name to replace the placeholder's callback with the tracked
; wrapper. Repeating ``Menu.Add`` with the same name modifies the
; existing item (per AHK 2.0 docs) rather than creating a duplicate, so
; the ID stays stable across the two calls.
;
; DEPENDENCIES: ``A_MaxThreads`` should already be bumped well above the
; default 10 in ErgoptiPlus.ahk so the retry SetTimer can actually find a
; free slot to run on (otherwise the bypass itself would get dropped).
;
; ─────────────────────────────────────────────────────────────────────────────
; WHEN TO USE WHICH
; ─────────────────────────────────────────────────────────────────────────────
;
; Use ``RegisterMenuItem(Menu, Label, Callback)`` for EVERY menu item that
; carries a real user-actionable callback. The dispatcher drop bug is silent
; and intermittent, so even items that "feel safe to lose a click on" should
; go through the wrapper — the cost is one Map entry per item, the upside is
; "no clicks ever vanish."
;
; Keep raw ``Menu.Add(...)`` for the three cases where the drop has no
; observable effect:
;
;   1. **Separator** — ``Menu.Add()`` with no args. No callback at all.
;   2. **Container submenu** — ``Menu.Add("Title", SubMenu)`` where SubMenu
;      is a Menu object. Clicking just opens the child; nothing to dispatch.
;   3. **Display-only header** — ``Menu.Add(Label, (*) => 0)`` or
;      ``(*) => NoAction()``. Decorative label, usually immediately followed
;      by ``Menu.Disable(Label)`` so the user can't click it anyway.
;
; Quick decision: "does this Add carry a user-visible action behind it?"
; Yes → ``RegisterMenuItem``. No → raw ``Menu.Add`` is fine.
;
; The day AHK 2.0 fixes its dispatcher drop, ``RegisterMenuItem`` can be
; aliased to a thin pass-through to ``Menu.Add`` and the whole bypass
; (callbacks Map + OnMessage handler + SetTimer retry) can be deleted
; without changing a single call site.
; ==============================================================================





; ==============================================================
; ========================
; ======= 1/ State =======
; ========================
; ==============================================================

; Maps Win32 menu-item ID (LOWORD of WM_COMMAND wParam) to the ORIGINAL
; user callback. Populated by RegisterMenuItem at menu-build time, read by
; the OnMessage retry handler when it needs to bypass AHK's drop.
global _MenuDispatchCallbacks := Map()

; Maps menu-item ID to the timestamp of its most recent dispatch (whether
; via AHK's native path or our bypass). Used by _DispatchIfMissed to
; detect whether AHK's own dispatcher beat the retry timer.
global _MenuDispatchLastFire := Map()

; Hard ceiling on retry delay (ms) — long enough for any reasonable AHK
; dispatch latency, short enough that the user doesn't perceive the
; recovered click as laggy. 60ms is sufficient: AHK always dispatches
; within the first few ms when it does so; anything above ~20ms means a
; drop has already occurred. The original 150ms was overly conservative.
global _MENU_RETRY_DELAY_MS := 60





; ==============================================================
; ===============================
; ======= 2/ Registration =======
; ===============================
; ==============================================================

; Clear both dispatch Maps. MUST be called at the very start of any tray
; rebuild (RebuildTrayMenu / BuildTrayMenuDeferred) BEFORE A_TrayMenu.Delete()
; and the InitSubMenus()/initMenu() re-registration pass. AHK allocates menu
; command IDs from an internal pool and REUSES freed IDs after Menu.Delete().
; If the stale entries survive a rebuild, a reused ID can map to a DIFFERENT
; item's callback: _DispatchIfMissed's double-fire guard compares an
; ExpectedLastFire snapshotted at click time (often 0 for a first click)
; against _MenuDispatchLastFire[ItemId], which RegisterMenuItem resets to 0 for
; the reused ID — so the 0 == 0 guard passes and the WRONG callback fires.
; Resetting here guarantees a reused ID always maps to the current item or is
; absent (so _DispatchIfMissed's Has() guard no-ops). Also prevents the
; unbounded growth of both Maps when a rebuild shrinks the menu and never
; re-registers the dropped IDs.
MenuDispatcher_Reset() {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire
    _MenuDispatchCallbacks := Map()
    _MenuDispatchLastFire  := Map()
}

; Per-menu prune for rebuilders that delete + repopulate a SINGLE menu in place
; (e.g. LLM_Tray_Build), as opposed to a full tray rebuild that can call
; MenuDispatcher_Reset(). Call this right AFTER MenuObj.Delete(): the deleted
; items' IDs are gone from the live HMENU, so any _MenuDispatchCallbacks /
; _MenuDispatchLastFire entry NOT in the current GetMenuItemID set for THIS
; menu is dead and is dropped. A global reset cannot be used here because the
; other live menus (main tray, language submenu) keep their registered items
; and must retain their dispatch entries. Without this prune the two Maps grow
; without bound across the very frequent LLM-menu rebuilds (each rebuild adds
; fresh IDs and the previous pass's IDs are never re-added once the item count
; shrinks). Reuses freed IDs are still re-added by RegisterMenuItem during the
; same rebuild, so live items keep their tracking.
MenuDispatcher_PruneMenu(MenuObj) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire

    ; Collect the IDs currently live in this menu's HMENU.
    LiveIds := Map()
    try {
        HMENU := MenuObj.Handle
        if (HMENU) {
            Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
            Loop Count {
                Id := DllCall("GetMenuItemID", "ptr", HMENU, "int", A_Index - 1, "uint")
                if (Id and Id != 0xFFFFFFFF) {
                    LiveIds[Id] := true
                }
            }
        }
    } catch {
        ; Menu.Handle may be unavailable — without a reliable live set we cannot
        ; tell live IDs from dead ones, so skip the prune rather than risk
        ; dropping a still-registered item's tracking.
        return
    }

    ; Drop every tracked ID that no longer corresponds to a live item in THIS
    ; menu. An ID owned by ANOTHER menu also has no entry in LiveIds, so we must
    ; only prune IDs that were registered for the menu being rebuilt. We cannot
    ; know an ID's owning menu from the Maps alone, so we restrict the prune to
    ; IDs absent from LiveIds AND whose item is gone from EVERY tracked menu —
    ; in practice the rebuilder calls this immediately after deleting its own
    ; items, and a freed Win32 ID is no longer reported by GetMenuItemID for any
    ; menu until re-added. Collect dead IDs first to avoid mutating during
    ; enumeration.
    DeadIds := []
    for Id in _MenuDispatchCallbacks {
        if !LiveIds.Has(Id) and !_MenuDispatchIdIsLiveAnywhere(Id) {
            DeadIds.Push(Id)
        }
    }
    for Id in DeadIds {
        _MenuDispatchCallbacks.Delete(Id)
        if _MenuDispatchLastFire.Has(Id) {
            _MenuDispatchLastFire.Delete(Id)
        }
    }
    if (DeadIds.Length > 0) {
        try LoggerDebug("MenuDispatcher",
            "Pruned {1} dead menu-item ID(s) after a single-menu rebuild.", DeadIds.Length)
    }
}

; Reports whether a Win32 menu-item ID is still present in ANY currently
; registered tray menu. Used by MenuDispatcher_PruneMenu to avoid dropping an
; entry that belongs to a DIFFERENT live menu than the one being rebuilt: a
; freed ID is reported by GetMenuItemID for no menu, while a live ID owned by
; another submenu still shows up there. We probe the tray root and descend
; recursively with cycle protection to reach items at any depth (depth 2-3 is
; reachable through Shortcuts → modifier_combos → items). Returns true on any
; match.
_MenuDispatchIdIsLiveAnywhere(ItemId) {
    try {
        TrayHandle := A_TrayMenu.Handle
        if (TrayHandle and _MenuDispatchHandleHasId(TrayHandle, ItemId, Map()))
            return true
    } catch {
        ; Tray menu may not exist yet (very early boot) — treat as not live.
    }
    return false
}

; Walks HMENU for ItemId, descending into every popup submenu recursively.
; Seen guards against cycles (circular HMENU references) by tracking every
; handle already visited. Returns true on first match.
_MenuDispatchHandleHasId(HMENU, ItemId, Seen) {
    if (Seen.Has(HMENU))
        return false
    Seen[HMENU] := true
    try {
        Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
        Loop Count {
            Pos := A_Index - 1
            Id := DllCall("GetMenuItemID", "ptr", HMENU, "int", Pos, "uint")
            if (Id == ItemId and Id != 0xFFFFFFFF)
                return true
            Sub := DllCall("GetSubMenu", "ptr", HMENU, "int", Pos, "ptr")
            if (Sub and _MenuDispatchHandleHasId(Sub, ItemId, Seen))
                return true
        }
    } catch {
        ; Probe failure — report not found so the conservative path keeps the
        ; entry only if PruneMenu's own LiveIds set claims it.
    }
    return false
}

; Add a menu item that participates in the dispatch bypass. Behaves like
; ``MenuObj.Add(ItemName, Callback)`` but additionally records the
; callback so the OnMessage handler can re-dispatch if AHK drops the
; click. Returns 1 on successful tracking, 0 if the item was added but
; its ID could not be discovered (in which case AHK's native dispatch is
; the only path — same behavior as before the bypass was installed).
RegisterMenuItem(MenuObj, ItemName, Callback) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire

    ; To avoid the double-Add penalty (placeholder then replace), we use a
    ; mutable object to capture the ItemId AFTER the Add call, while the
    ; closure is already registered.
    TrackedObj := { ItemId: 0, Callback: Callback }
    Wrapper    := (Args*) => _TrackedDispatch(TrackedObj, Args*)

    try {
        MenuObj.Add(ItemName, Wrapper)
    } catch {
        return 0  ; Add itself failed — bail out cleanly.
    }

    ; Discover the ID via Menu.Handle + GetMenuItemID. Last added item
    ; sits at position Count - 1.
    ItemId := 0
    try {
        HMENU := MenuObj.Handle
        if (HMENU) {
            Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
            if (Count > 0) {
                Raw := DllCall("GetMenuItemID", "ptr", HMENU, "int", Count - 1, "uint")
                if (Raw and Raw != 0xFFFFFFFF) {
                    ItemId := Raw
                }
            }
        }
    } catch {
        ; Menu.Handle may be unavailable.
    }

    if (!ItemId) {
        return 0
    }

    ; Update the mutable object so the already-registered closure knows its ID
    TrackedObj.ItemId := ItemId
    _MenuDispatchCallbacks[ItemId] := Callback
    _MenuDispatchLastFire[ItemId]  := 0
    return 1
}

_TrackedDispatch(TrackedObj, Args*) {
    global _MenuDispatchLastFire
    if (TrackedObj.ItemId) {
        _MenuDispatchLastFire[TrackedObj.ItemId] := A_TickCount
    }
    TrackedObj.Callback.Call(Args*)
}

; Variant for items added via ``Menu.Insert(BeforeItem, ItemName, Callback)``.
; AHK's Insert places the new item BEFORE the position named in BeforeItem
; (the "1&" / "2&" notation = 1-based position with literal trailing &) and
; shifts everything else down.
;
; BeforeItem accepts AHK's standard syntax: "Nname" / "&n" / "Nn&" — see
; AHK 2.0 Menu.Insert docs.
RegisterMenuItemInsert(MenuObj, BeforeItem, ItemName, Callback) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire

    TrackedObj := { ItemId: 0, Callback: Callback }
    Wrapper    := (Args*) => _TrackedDispatch(TrackedObj, Args*)

    try {
        MenuObj.Insert(BeforeItem, ItemName, Wrapper)
    } catch {
        return 0
    }

    ; Resolve the inserted item's ID by POSITION first. Insert places the new
    ; item BEFORE the 1-based position named in BeforeItem ("N&"), so the new
    ; item itself lands AT that position (index N-1). Position is unambiguous;
    ; the text-match fallback below binds the wrong ID when two items in the
    ; same HMENU share a label.
    InsertPos := _ParseInsertPosition(BeforeItem)
    ItemId := 0
    if (InsertPos > 0) {
        ItemId := _MenuItemIdAtPosition(MenuObj, InsertPos - 1)
    }
    ; Fall back to a UNIQUE text match only when the position cannot be derived
    ; (BeforeItem given as a name, not "N&"). A non-unique label degrades to
    ; native dispatch (returns 0) rather than binding the wrong ID.
    if (!ItemId) {
        ItemId := _FindUniqueMenuItemIdByName(MenuObj, ItemName)
    }
    if (!ItemId) {
        return 0
    }

    ; Update the mutable object so the already-registered closure knows its ID
    TrackedObj.ItemId := ItemId
    _MenuDispatchCallbacks[ItemId] := Callback
    _MenuDispatchLastFire[ItemId]  := 0
    return 1
}

; Parse the leading 1-based position out of AHK's "N&" Insert notation
; (e.g. "1&" -> 1, "2&" -> 2). Returns 0 for the name form ("SomeLabel") or
; any string that does not start with a positive integer followed by "&", so
; the caller falls back to a (unique) text match.
_ParseInsertPosition(BeforeItem) {
    if (Type(BeforeItem) != "String") {
        return 0
    }
    if !RegExMatch(BeforeItem, "^(\d+)&$", &M) {
        return 0
    }
    Pos := Integer(M[1])
    return (Pos >= 1) ? Pos : 0
}

; Read the Win32 ItemId of the entry at a 0-based position via GetMenuItemID.
; Position-based discovery is unambiguous, unlike text matching — two items
; sharing a label cannot collide. Returns 0 when the menu has no handle, the
; index is out of range, or the id is the GetMenuItemID failure sentinel.
_MenuItemIdAtPosition(MenuObj, Index) {
    try {
        HMENU := MenuObj.Handle
        if (!HMENU) {
            return 0
        }
        Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
        if (Index < 0 or Index >= Count) {
            return 0
        }
        Id := DllCall("GetMenuItemID", "ptr", HMENU, "int", Index, "uint")
        if (Id and Id != 0xFFFFFFFF) {
            return Id
        }
    } catch {
        ; Menu.Handle may be unavailable — degrade to native dispatch.
    }
    return 0
}

; Walk a Menu's items and return the Win32 ItemId of the entry whose visible
; text matches ItemName, but ONLY when that text is UNIQUE in the menu. If two
; or more items share the label the match is ambiguous, so this returns 0 —
; the caller then degrades to AHK's native dispatch rather than binding the
; wrong (typically the first-occurrence) ID. Returns 0 when nothing matches or
; Menu.Handle is unavailable. Length-tolerant: GetMenuString tells us how many
; chars to allocate via its return value when nBuffer is 0.
_FindUniqueMenuItemIdByName(MenuObj, ItemName) {
    try {
        HMENU := MenuObj.Handle
        if (!HMENU) {
            return 0
        }
        FoundId := 0
        Matches := 0
        Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
        Loop Count {
            Pos := A_Index - 1
            ; Probe the required buffer size — first call with nBuffer=0
            ; returns the char count (no terminator).
            Required := DllCall("GetMenuStringW", "ptr", HMENU, "uint", Pos,
                "ptr", 0, "int", 0, "uint", 0x0400, "int")
            if (Required <= 0) {
                continue
            }
            Buf := Buffer((Required + 1) * 2, 0)
            DllCall("GetMenuStringW", "ptr", HMENU, "uint", Pos,
                "ptr", Buf, "int", Required + 1, "uint", 0x0400)
            Text := StrGet(Buf, "UTF-16")
            if (Text == ItemName) {
                Id := DllCall("GetMenuItemID", "ptr", HMENU, "int", Pos, "uint")
                if (Id and Id != 0xFFFFFFFF) {
                    Matches++
                    FoundId := Id
                }
            }
        }
        if (Matches == 1) {
            return FoundId
        }
        if (Matches > 1) {
            try LoggerWarn("MenuDispatcher",
                "Ambiguous insert label (matched {1} items) — degrading to native dispatch.", Matches)
        }
    } catch {
        ; Same fallback policy as RegisterMenuItem — bypass coverage
        ; silently degrades to AHK's native dispatch.
    }
    return 0
}





; ==============================================================
; ==========================================
; ======= 3/ OnMessage retry handler =======
; ==========================================
; ==============================================================

; Catches WM_COMMAND for every tray menu click. Snapshots the per-ItemId
; "last fire" timestamp and schedules a delayed check; if AHK's native
; dispatcher beats us to firing the callback, the check sees an updated
; timestamp and is a no-op. Otherwise we dispatch ourselves from the
; SetTimer thread (which gets its own pseudo-thread slot, bypassing
; whatever saturation drops the WM_COMMAND callback).
_OnMenuCommandWmCommand(wParam, lParam, msg, hwnd) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MENU_RETRY_DELAY_MS

    ItemId := wParam & 0xFFFF
    NotifyCode := (wParam >> 16) & 0xFFFF
    ; Menu-item selections arrive with NotifyCode = 0. Keyboard
    ; accelerators (1) and control notifications (other) get AHK's
    ; native handling and are not part of the bypass.
    if (NotifyCode != 0) {
        return
    }
    if !_MenuDispatchCallbacks.Has(ItemId) {
        return
    }
    LastFire := _MenuDispatchLastFire.Has(ItemId) ? _MenuDispatchLastFire[ItemId] : 0
    ; Single-shot timer: negative ms = "fire once, auto-remove".
    SetTimer(_DispatchIfMissed.Bind(ItemId, LastFire), -_MENU_RETRY_DELAY_MS)
}

; Fires after _MENU_RETRY_DELAY_MS. If LastFire hasn't moved since the
; click, AHK's dispatcher dropped the call and we run the callback
; ourselves. The bypass dispatch also updates LastFire so a follow-on
; OnMessage retry for the same item won't double-fire.
_DispatchIfMissed(ItemId, ExpectedLastFire) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire
    ; Critical is held only for the brief atomic gate — reading/updating state and
    ; extracting the callback reference. Releasing it before Callback.Call() is
    ; mandatory: holding Critical across an arbitrary menu action risks starving the
    ; keyboard hook thread past the LowLevelHooksTimeout (~300 ms), causing Windows
    ; to silently drop physical keystrokes.
    Critical "On"
    CurrentLastFire := _MenuDispatchLastFire.Has(ItemId) ? _MenuDispatchLastFire[ItemId] : 0
    if (CurrentLastFire != ExpectedLastFire) {
        Critical "Off"
        return  ; AHK fired the callback — bypass not needed for this click.
    }
    if !_MenuDispatchCallbacks.Has(ItemId) {
        Critical "Off"
        return
    }
    Callback := _MenuDispatchCallbacks[ItemId]
    _MenuDispatchLastFire[ItemId] := A_TickCount
    Critical "Off"   ; Release before the callback so the keyboard hook is never starved.
    try LoggerInfo("MenuDispatcher",
        "AHK drop detected for ItemId={1} — firing bypass_dispatch.", ItemId)
    try {
        Callback.Call("", 0, 0)
    } catch as Err {
        try LoggerError("MenuDispatcher",
            "Bypass dispatch for ItemId={1} threw: {2}.", ItemId, Err.Message)
    }
}





; ==============================================================
; =======================
; ======= 4/ Init =======
; =======================
; ==============================================================

; Install the OnMessage hook for WM_COMMAND (0x0111). Called once at
; module include time below.
_MenuDispatcherInit() {
    OnMessage(0x0111, _OnMenuCommandWmCommand)
    try LoggerInfo("MenuDispatcher",
        "WM_COMMAND retry hook installed (retry delay: {1} ms).",
        _MENU_RETRY_DELAY_MS)
}
_MenuDispatcherInit()
