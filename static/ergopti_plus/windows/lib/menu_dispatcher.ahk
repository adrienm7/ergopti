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
; recovered click as laggy.
global _MENU_RETRY_DELAY_MS := 150





; ==============================================================
; ===============================
; ======= 2/ Registration =======
; ===============================
; ==============================================================

; Add a menu item that participates in the dispatch bypass. Behaves like
; ``MenuObj.Add(ItemName, Callback)`` but additionally records the
; callback so the OnMessage handler can re-dispatch if AHK drops the
; click. Returns 1 on successful tracking, 0 if the item was added but
; its ID could not be discovered (in which case AHK's native dispatch is
; the only path — same behavior as before the bypass was installed).
RegisterMenuItem(MenuObj, ItemName, Callback) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire

    ; Step 1: placeholder add to let AHK allocate the Win32 item ID.
    PlaceholderCb := (*) => ""
    try {
        MenuObj.Add(ItemName, PlaceholderCb)
    } catch {
        return 0  ; Add itself failed — bail out cleanly.
    }

    ; Step 2: discover the ID via Menu.Handle + GetMenuItemID. Last added
    ; item sits at position Count - 1.
    ItemId := 0
    try {
        HMENU := MenuObj.Handle
        if (HMENU) {
            Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
            if (Count > 0) {
                Raw := DllCall("GetMenuItemID", "ptr", HMENU, "int", Count - 1, "uint")
                ; -1 (0xFFFFFFFF) indicates a separator or popup-only item —
                ; both produce no WM_COMMAND so the bypass isn't applicable.
                if (Raw and Raw != 0xFFFFFFFF) {
                    ItemId := Raw
                }
            }
        }
    } catch {
        ; Menu.Handle may be unavailable on some AHK 2.0 minors. Leave
        ; the item with AHK's native dispatch — exactly the same coverage
        ; as before the bypass was installed.
    }

    if (!ItemId) {
        ; Discovery failed — replace placeholder with the raw user callback
        ; (since the bypass can't help, AHK's native dispatch is the only
        ; path) and report no tracking.
        try MenuObj.Add(ItemName, Callback)
        return 0
    }

    ; Step 3: build the tracking wrapper that stamps the "last fire"
    ; timestamp for THIS specific ItemId on every native-dispatch entry.
    Tracked := _MakeTrackedCallback(ItemId, Callback)
    ; Step 4: re-add under the same name — AHK 2.0 docs guarantee this
    ; modifies the existing item rather than creating a duplicate, so the
    ; ItemId we just read stays valid.
    try MenuObj.Add(ItemName, Tracked)

    _MenuDispatchCallbacks[ItemId] := Callback
    _MenuDispatchLastFire[ItemId]  := 0
    return 1
}

; Returns a Func that stamps _MenuDispatchLastFire[ItemId] before calling
; the user's original Callback. Extracted to a named helper so the closure
; over (ItemId, Callback) is created once per registration, not on every
; click.
_MakeTrackedCallback(ItemId, Callback) {
    return (Args*) => _TrackedDispatch(ItemId, Callback, Args*)
}

_TrackedDispatch(ItemId, Callback, Args*) {
    global _MenuDispatchLastFire
    _MenuDispatchLastFire[ItemId] := A_TickCount
    Callback.Call(Args*)
}

; Variant for items added via ``Menu.Insert(BeforeItem, ItemName, Callback)``.
; AHK's Insert places the new item BEFORE the position named in BeforeItem
; (the "1&" / "2&" notation = 1-based position with literal trailing &) and
; shifts everything else down. We do the same two-step placeholder + replace
; dance, but use Insert for both steps so the position stays consistent.
;
; BeforeItem accepts AHK's standard syntax: "Nname" / "&n" / "Nn&" — see
; AHK 2.0 Menu.Insert docs.
RegisterMenuItemInsert(MenuObj, BeforeItem, ItemName, Callback) {
    global _MenuDispatchCallbacks, _MenuDispatchLastFire

    PlaceholderCb := (*) => ""
    try {
        MenuObj.Insert(BeforeItem, ItemName, PlaceholderCb)
    } catch {
        return 0
    }

    ; Find the just-inserted item via its name — Menu.Handle gives the
    ; HMENU, then we walk positions and match against the item text. Less
    ; clean than the Add helper's "tail of menu" assumption, but Insert
    ; can land anywhere so we have no shortcut.
    ItemId := _FindMenuItemIdByName(MenuObj, ItemName)
    if (!ItemId) {
        try MenuObj.Insert(BeforeItem, ItemName, Callback)
        return 0
    }

    Tracked := _MakeTrackedCallback(ItemId, Callback)
    ; Re-Add (same name) modifies the existing item's callback without
    ; touching its position, matching the Add helper's behavior.
    try MenuObj.Add(ItemName, Tracked)

    _MenuDispatchCallbacks[ItemId] := Callback
    _MenuDispatchLastFire[ItemId]  := 0
    return 1
}

; Walk a Menu's items and return the Win32 ItemId of the entry whose
; visible text matches ItemName. Returns 0 when nothing matches or
; Menu.Handle is unavailable. Length-tolerant: GetMenuString tells us
; how many chars to allocate via its return value when nBuffer is 0.
_FindMenuItemIdByName(MenuObj, ItemName) {
    try {
        HMENU := MenuObj.Handle
        if (!HMENU) {
            return 0
        }
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
                    return Id
                }
            }
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
    Critical
    CurrentLastFire := _MenuDispatchLastFire.Has(ItemId) ? _MenuDispatchLastFire[ItemId] : 0
    if (CurrentLastFire != ExpectedLastFire) {
        return  ; AHK fired the callback — bypass not needed for this click.
    }
    if !_MenuDispatchCallbacks.Has(ItemId) {
        return
    }
    Callback := _MenuDispatchCallbacks[ItemId]
    _MenuDispatchLastFire[ItemId] := A_TickCount
    try LoggerInfo("MenuDispatcher",
        "AHK drop detected for ItemId={1} — firing bypass dispatch.", ItemId)
    try {
        Callback.Call("bypass_dispatch")
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
