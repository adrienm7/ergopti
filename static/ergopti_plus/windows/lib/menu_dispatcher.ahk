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

; Every rebuild advances the dispatcher epoch.  A fallback timer is bound to
; the epoch and registration token it observed, never to a recyclable native
; command ID alone.
global _MenuDispatcherEpoch := 0
global _MenuDispatchTokens := Map()
global _MenuDispatchTokenCounter := 0
global _MenuDispatchClickSequences := Map()

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
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatcherEpoch, _MenuDispatchTokens, _MenuDispatchClickSequences
    _MenuDispatcherEpoch += 1
    _MenuDispatchCallbacks := Map()
    _MenuDispatchLastFire  := Map()
    _MenuDispatchTokens    := Map()
    _MenuDispatchClickSequences := Map()
}

; Advance the retry epoch before replacing the tray tree, without clearing the
; registrations belonging to detached submenus that are about to be published.
; A full Reset() is only safe before *any* new menu item has been registered;
; staged rebuilds intentionally register their child menus while the old tray
; remains live.  Clearing those Maps here would make every staged callback a
; silent native-dispatch-only item after publication.
MenuDispatcher_BeginReplacement() {
    global _MenuDispatcherEpoch, _MenuDispatchClickSequences
    _MenuDispatcherEpoch += 1
    _MenuDispatchClickSequences := Map()
}

; Per-menu prune for rebuilders that delete + repopulate a SINGLE menu in place
; (e.g. LLM_Menu_Build), as opposed to a full tray rebuild that can call
; MenuDispatcher_Reset(). Call this right AFTER MenuObj.Delete(): the deleted
; items' IDs are gone from the live HMENU, so any _MenuDispatchCallbacks /
; _MenuDispatchLastFire / retry-sequence entry NOT in the current GetMenuItemID set for THIS
; menu is dead and is dropped. A global reset cannot be used here because the
; other live menus (main tray, language submenu) keep their registered items
; and must retain their dispatch entries. Without this prune the two Maps grow
; without bound across the very frequent LLM-menu rebuilds (each rebuild adds
; fresh IDs and the previous pass's IDs are never re-added once the item count
; shrinks). Reuses freed IDs are still re-added by RegisterMenuItem during the
; same rebuild, so live items keep their tracking.
MenuDispatcher_PruneMenu(MenuObj) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens, _MenuDispatchClickSequences

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

    ; Fold in EVERY ID live anywhere in the tray, collected in a SINGLE recursive
    ; walk. An ID owned by ANOTHER menu has no entry in this menu's LiveIds, so
    ; without this it would look dead and be wrongly pruned. The previous code
    ; asked _MenuDispatchIdIsLiveAnywhere(Id) PER tracked ID — each a full
    ; recursive descent of the whole tray — making the prune O(tracked x tray):
    ; with hundreds of tracked items it cost ~0.6 s warm and up to ~6 s at boot
    ; (the dominant term in LLM_Menu_Build latency). One walk + O(1) lookups is
    ; O(tray + tracked) (menu-prune-quadratic-tray-walk).
    TrayWalked := false
    try {
        TrayHandle := A_TrayMenu.Handle
        if (TrayHandle) {
            _MenuDispatchCollectLiveIds(TrayHandle, LiveIds, Map())
            TrayWalked := true
        }
    } catch {
        ; Tray handle unavailable — fall through to the guard below.
    }
    ; Without a reliable whole-tray live set we cannot tell an ID owned by another
    ; live menu from a freed one, so skip the prune rather than drop a live entry.
    if (!TrayWalked)
        return

    ; Drop every tracked ID no longer live in this menu OR anywhere in the tray.
    ; Collect dead IDs first to avoid mutating the Map during enumeration.
    DeadIds := []
    for Id in _MenuDispatchCallbacks {
        if !LiveIds.Has(Id) {
            DeadIds.Push(Id)
        }
    }
    for Id in DeadIds {
        _MenuDispatchCallbacks.Delete(Id)
        if _MenuDispatchLastFire.Has(Id) {
            _MenuDispatchLastFire.Delete(Id)
        }
        if _MenuDispatchTokens.Has(Id) {
            _MenuDispatchTokens.Delete(Id)
        }
        if _MenuDispatchClickSequences.Has(Id) {
            _MenuDispatchClickSequences.Delete(Id)
        }
    }
    if (DeadIds.Length > 0) {
        try LoggerDebug("MenuDispatcher",
            "Pruned {1} dead menu-item ID(s) after a single-menu rebuild.", DeadIds.Length)
    }
}

; Collects every live menu-item ID reachable from HMENU into LiveSet, descending
; into every popup submenu recursively (depth-unlimited — items live at depth 2-3,
; e.g. Shortcuts → modifier_combos → items, must be collected or PruneMenu would
; wrongly drop their tracking; F07 deep-liveness). Seen guards against cyclic
; HMENU references. One pass replaces the old per-ID _MenuDispatchIdIsLiveAnywhere
; search that made the prune O(tracked x tray) (menu-prune-quadratic-tray-walk).
_MenuDispatchCollectLiveIds(HMENU, LiveSet, Seen) {
    if (Seen.Has(HMENU))
        return
    Seen[HMENU] := true
    try {
        Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
        Loop Count {
            Pos := A_Index - 1
            Id := DllCall("GetMenuItemID", "ptr", HMENU, "int", Pos, "uint")
            if (Id and Id != 0xFFFFFFFF)
                LiveSet[Id] := true
            Sub := DllCall("GetSubMenu", "ptr", HMENU, "int", Pos, "ptr")
            if (Sub)
                _MenuDispatchCollectLiveIds(Sub, LiveSet, Seen)
        }
    } catch {
        ; Probe failure mid-walk — stop descending this branch. Same exposure as the
        ; prior per-ID probe: an unreachable live ID may then be treated as dead.
    }
}

; Add a menu item that participates in the dispatch bypass. Behaves like
; ``MenuObj.Add(ItemName, Callback)`` but additionally records the
; callback so the OnMessage handler can re-dispatch if AHK drops the
; click. Returns 1 on successful tracking, 0 if the item was added but
; its ID could not be discovered (in which case AHK's native dispatch is
; the only path — same behavior as before the bypass was installed).
RegisterMenuItem(MenuObj, ItemName, Callback) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatcherEpoch, _MenuDispatchTokens, _MenuDispatchTokenCounter

    ; To avoid the double-Add penalty (placeholder then replace), we use a
    ; mutable object to capture the ItemId AFTER the Add call, while the
    ; closure is already registered.
    TrackedObj := { ItemId: 0, Callback: Callback, Epoch: _MenuDispatcherEpoch, Token: 0 }
    Wrapper    := (Args*) => _TrackedDispatch(TrackedObj, Args*)

    ; A new label appends exactly one native item. Record the count on both sides
    ; so the common path resolves its ID in O(1); only a duplicate-label update
    ; keeps the count unchanged and needs the defensive unique-name scan.
    CountBefore := _MenuItemCount(MenuObj)
    try {
        MenuObj.Add(ItemName, Wrapper)
    } catch as Err {
        ; No caller checks this return — the item simply never appears. Without
        ; a log the only symptom is a missing tray entry with no trace at all.
        try LoggerError("MenuDispatcher", "Menu.Add failed for '{1}': {2}", ItemName, Err.Message)
        return 0
    }
    CountAfter := _MenuItemCount(MenuObj)
    ItemId := (CountBefore >= 0 and CountAfter = CountBefore + 1)
        ? _MenuItemIdAtPosition(MenuObj, CountAfter - 1)
        : 0
    ; AHK Menu.Add with an already-present label modifies in place and does not
    ; grow the menu. Fall back to a uniqueness-checked scan only for that rare
    ; path; binding CountAfter-1 after an in-place update would target another row.
    if (!ItemId)
        ItemId := _FindUniqueMenuItemIdByName(MenuObj, ItemName)
    if (!ItemId) {
        try LoggerWarn("MenuDispatcher", "Ambiguous or unresolvable menu label '{1}' - degrading to native dispatch (no bypass).", ItemName)
        return 0
    }

    ; Update the mutable object so the already-registered closure knows its ID
    TrackedObj.ItemId := ItemId
    _MenuDispatchTokenCounter += 1
    TrackedObj.Token := _MenuDispatchTokenCounter
    _MenuDispatchCallbacks[ItemId] := Callback
    _MenuDispatchLastFire[ItemId]  := 0
    _MenuDispatchTokens[ItemId]    := TrackedObj.Token
    return 1
}

_TrackedDispatch(TrackedObj, Args*) {
    global _MenuDispatchLastFire, _MenuDispatcherEpoch, _MenuDispatchTokens
    ; Fenced on ItemId + TOKEN. The registration-time epoch used to be part of
    ; this test and had to come out, because it contradicted the intent
    ; TrayMenuStage_Publish states in its own comment: "retain dispatcher entries
    ; for detached child menus that were registered during staging".
    ;
    ; A_TrayMenu.Delete() clears only the TOP level. Child Menu objects survive a
    ; publish with their native IDs and their token entries intact — deliberately,
    ; which is why BeginReplacement does not clear the token maps. But every
    ; submenu item is registered BEFORE the epoch bump (RebuildTrayMenu calls
    ; InitSubMenus, then initMenu reaches Publish), and initMenu is also called
    ; ALONE from the updater's tray refresh and from lifecycle. So those items sat
    ; at the previous epoch and this guard rejected their native dispatch.
    ;
    ; They still fired — the 60 ms retry rescued them — so the symptom was not a
    ; dead menu but a corrupted signal: every submenu click paid that delay and
    ; logged "AHK drop detected", which is the one diagnostic this module exists
    ; to produce. A real AHK drop became indistinguishable from an epoch-fenced
    ; no-op.
    ;
    ; Token identity carries the staleness guarantee on its own: a replacement
    ; registration on the same native ItemId writes a NEW token, so a stale
    ; TrackedObj can never match. The epoch remains meaningful in
    ; _DispatchIfMissed, where it is captured at CLICK time rather than at
    ; registration time and correctly voids a retry that spans a rebuild.
    if (TrackedObj.ItemId
        and _MenuDispatchTokens.Has(TrackedObj.ItemId)
        and _MenuDispatchTokens[TrackedObj.ItemId] = TrackedObj.Token) {
        _MenuDispatchLastFire[TrackedObj.ItemId] := A_TickCount
        TrackedObj.Callback.Call(Args*)
    }
}

; Variant for items added via ``Menu.Insert(BeforeItem, ItemName, Callback)``.
; AHK's Insert places the new item BEFORE the position named in BeforeItem
; (the "1&" / "2&" notation = 1-based position with literal trailing &) and
; shifts everything else down.
;
; BeforeItem accepts AHK's standard syntax: "Nname" / "&n" / "Nn&" — see
; AHK 2.0 Menu.Insert docs.
RegisterMenuItemInsert(MenuObj, BeforeItem, ItemName, Callback) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatcherEpoch, _MenuDispatchTokens, _MenuDispatchTokenCounter

    ; Keep the same registration identity as RegisterMenuItem. _TrackedDispatch
    ; atomically fences wrappers from obsolete menu generations; omitting either
    ; field here made a click on an inserted item dereference a missing property.
    TrackedObj := { ItemId: 0, Callback: Callback, Epoch: _MenuDispatcherEpoch, Token: 0 }
    Wrapper    := (Args*) => _TrackedDispatch(TrackedObj, Args*)

    try {
        MenuObj.Insert(BeforeItem, ItemName, Wrapper)
    } catch as Err {
        try LoggerError("MenuDispatcher", "Menu.Insert failed for '{1}' before '{2}': {3}", ItemName, BeforeItem, Err.Message)
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
        ; Degrades to native dispatch, which AHK drops 30-50% of the time — the
        ; exact failure this module exists to prevent. Its sibling
        ; RegisterMenuItem warns here; this path said nothing.
        try LoggerWarn("MenuDispatcher", "Could not resolve an item id for '{1}' — falling back to native dispatch, which AHK drops intermittently.", ItemName)
        return 0
    }

    ; Update the mutable object so the already-registered closure knows its ID
    TrackedObj.ItemId := ItemId
    _MenuDispatchTokenCounter += 1
    TrackedObj.Token := _MenuDispatchTokenCounter
    _MenuDispatchCallbacks[ItemId] := Callback
    _MenuDispatchLastFire[ItemId]  := 0
    _MenuDispatchTokens[ItemId]    := TrackedObj.Token
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

; Returns the current item count, or -1 when the native handle cannot be read.
; Kept separate from _MenuItemIdAtPosition so RegisterMenuItem can detect an
; append without enumerating every sibling label.
_MenuItemCount(MenuObj) {
    try {
        HMENU := MenuObj.Handle
        if (!HMENU)
            return -1
        return DllCall("GetMenuItemCount", "ptr", HMENU, "int")
    }
    return -1
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
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MENU_RETRY_DELAY_MS, _MenuDispatcherEpoch, _MenuDispatchTokens, _MenuDispatchClickSequences

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
    if !_MenuDispatchTokens.Has(ItemId) {
        return
    }
    LastFire := _MenuDispatchLastFire.Has(ItemId) ? _MenuDispatchLastFire[ItemId] : 0
    ClickSequence := _MenuDispatchClickSequences.Has(ItemId) ? _MenuDispatchClickSequences[ItemId] + 1 : 1
    _MenuDispatchClickSequences[ItemId] := ClickSequence
    ; Single-shot timer: negative ms = "fire once, auto-remove".
    SetTimer(_DispatchIfMissed.Bind(ItemId, LastFire, _MenuDispatcherEpoch, _MenuDispatchTokens[ItemId], ClickSequence), -_MENU_RETRY_DELAY_MS)
}

; Fires after _MENU_RETRY_DELAY_MS. If LastFire hasn't moved since the
; click, AHK's dispatcher dropped the call and we run the callback
; ourselves. The bypass dispatch also updates LastFire so a follow-on
; OnMessage retry for the same item won't double-fire.
;
; The epoch, token and per-item click sequence together fence stale retries:
; a recycled native ID, a rebuilt menu, or a newer click can never make an
; older timer dispatch the current callback.
_DispatchIfMissed(ItemId, ExpectedLastFire, ExpectedEpoch := 0, ExpectedToken := 0, ExpectedClickSequence := 0) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatcherEpoch, _MenuDispatchTokens, _MenuDispatchClickSequences
    ; Critical is held only for the brief atomic gate — reading/updating state and
    ; extracting the callback reference. Releasing it before Callback.Call() is
    ; mandatory: holding Critical across an arbitrary menu action risks starving the
    ; keyboard hook thread past the LowLevelHooksTimeout (~300 ms), causing Windows
    ; to silently drop physical keystrokes.
    Critical "On"
    ; A rebuild can recycle ItemId before this timer fires.  Require the exact
    ; registration identity captured at WM_COMMAND time so an old retry can
    ; neither invoke the newly registered callback nor duplicate a native fire.
    if (ExpectedEpoch and ExpectedEpoch != _MenuDispatcherEpoch) {
        Critical "Off"
        return
    }
    if (ExpectedToken and (!_MenuDispatchTokens.Has(ItemId) or _MenuDispatchTokens[ItemId] != ExpectedToken)) {
        Critical "Off"
        return
    }
    if (ExpectedClickSequence and (!_MenuDispatchClickSequences.Has(ItemId) or _MenuDispatchClickSequences[ItemId] != ExpectedClickSequence)) {
        Critical "Off"
        return
    }
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
        throw Err
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
