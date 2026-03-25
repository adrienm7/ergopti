-- modules/gestures.lua

-- ===========================================================================
-- Multitouch Gestures Module.
--
-- Utilizes the undocumented macOS touchdevice API to capture raw trackpad
-- inputs. Maps various multi-finger taps and swipes to custom actions.
-- Manages macOS system gesture conflicts to prevent double-triggering.
-- Each gesture slot is independently assignable to an action.
-- "Axis" slots (←/→ or /\) → actions with prev/next direction.
-- "Single" slots (tap, ↑↓)  → actions without direction.
-- ===========================================================================

local notifications = require("lib.notifications")

local ok_td, touchdevice = pcall(require, "hs._asm.undocumented.touchdevice")
if not ok_td then touchdevice = nil end

local M = {}





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

M.DEFAULT_GESTURES = {
    tap_3         = "none",
    tap_4         = "none",
    tap_5         = "none",
    swipe_2_diag  = "none",
    swipe_3_horiz = "none",
    swipe_3_diag  = "none",
    swipe_3_up    = "none",
    swipe_3_down  = "none",
    swipe_4_horiz = "none",
    swipe_4_diag  = "none",
    swipe_4_up    = "none",
    swipe_4_down  = "none",
    swipe_5_horiz = "none",
    swipe_5_diag  = "none",
    swipe_5_up    = "none",
    swipe_5_down  = "none",
}





-- =============================================
-- =============================================
-- ======= 2/ macOS Conflicts Management =======
-- =============================================
-- =============================================

-- On macOS Sequoia+, `defaults write` + `killall Dock` does NOT reliably disable
-- trackpad gestures. The gesture engine (MultitouchSupport / WindowServer daemon)
-- ignores pref changes unless they come through System Settings, which sends a
-- private IPC notification that cannot be replicated from the command line.
--
-- Strategy: detect the conflict and instruct the user to disable the system
-- gesture manually. Track which conflicts have already been reported so the
-- dialog appears only once per group activation (persisted across sessions).

-- Each group maps a human-readable description to the slots that conflict with
-- a built-in macOS gesture, plus the exact path to toggle it in System Settings.
local MACOS_GESTURE_GROUPS = {
    {
        key          = "tap_3_conflict",
        slots        = { "tap_3" },
        description  = "Tap 3 doigts — Recherche & détection de données",
        hint         = "Réglages Système › Trackpad › Pointer & cliquer\n→ Décocher « Recherche et détection de données »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_3_horiz_conflict",
        slots        = { "swipe_3_horiz" },
        description  = "Glisser 3 doigts gauche/droite — Pages / Passer d’un espace",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Faire défiler entre les pages » et « Passer d’un espace à l’autre »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_3_vert_conflict",
        slots        = { "swipe_3_up", "swipe_3_down" },
        description  = "Glisser 3 doigts haut/bas — Mission Control & App Exposé",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Mission Control » et « Exposé de l’app »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_4_horiz_conflict",
        slots        = { "swipe_4_horiz", "swipe_5_horiz" },
        description  = "Glisser 4/5 doigts gauche/droite — Passer d’un espace à l’autre",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Passer d’un espace à l’autre »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
    {
        key          = "swipe_4_vert_conflict",
        slots        = { "swipe_4_up", "swipe_4_down", "swipe_5_up", "swipe_5_down" },
        description  = "Glisser 4/5 doigts haut/bas — Mission Control & App Exposé",
        hint         = "Réglages Système › Trackpad › Plus de gestes\n→ Décocher « Mission Control » et « Exposé de l’app »",
        settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
    },
}

-- Reverse lookup: slot name → group
local SLOT_TO_GROUP = {}
for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
    for _, slot in ipairs(grp.slots) do
        SLOT_TO_GROUP[slot] = grp
    end
end

--- Returns true when at least one slot in the group has an active configuration
--- @param grp table The gesture group
--- @param ga_table table The active gesture actions map
--- @return boolean True if active
local function group_has_active_slot(grp, ga_table)
    for _, slot in ipairs(grp.slots) do
        if (ga_table[slot] or "none") ~= "none" then return true end
    end
    return false
end

--- Generates a warning structure if a new action triggers a system conflict
--- @param slot string The gesture slot name
--- @param new_action string The newly assigned action
--- @return table|nil Warning data or nil if no conflict
function M.on_action_changed(slot, new_action)
    if new_action == "none" then return nil end
    local grp = SLOT_TO_GROUP[slot]
    if not grp then return nil end
    
    -- A line of dashes forces the blockAlert dialog to be wide enough in UI
    local sep = string.rep("─", 26)
    return {
        msg = string.format(
            "%s\n"
            .. "Ce geste est peut-être géré par macOS :\n"
            .. "« %s »\n\n"
            .. "Si c’est le cas, macOS et Hammerspoon réagiront tous deux en même temps :\n"
            .. "les deux comportements seront envoyés simultanément.\n\n"
            .. "Si encore actif, désactivez-le ici :\n"
            .. "%s\n%s",
            sep, grp.description, grp.hint, sep),
        url = grp.settings_url,
    }
end

--- Logs active conflicts at startup (no automatic preference changes)
function M.apply_all_overrides()
    local actions = M.get_all_actions()
    for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
        if group_has_active_slot(grp, actions) then
            print(string.format("[gestures] Conflict active: \"%s\" — user must disable in System Settings", grp.description))
        end
    end
end

--- No-op function (we never modify system prefs automatically)
function M.restore_all_overrides()
end





-- ===========================================
-- ===========================================
-- ======= 3/ Engine Helpers & Actions =======
-- ===========================================
-- ===========================================



-- =======================================
-- ===== 3.1) Thresholds & State =====
-- =======================================

local TAP_MAX_SEC    = 0.35
local TAP_MAX_DELTA  = 2.0
local SWIPE_MIN      = 1.5    -- 3/4/5 fingers: minimum distance to validate a swipe
local SWIPE_MIN_2    = 3.0    -- 2 fingers horiz/vert (left to macOS, diagonal only)
local DIAG_MIN_2     = 5.0    -- 2 fingers: minimum total distance to validate a diagonal
local DIAG_MAX_RATIO = 2.0    -- max dx/dy ratio for a movement to be considered diagonal

local leftClickPressed = false
local mouseEventTap    = nil
local gesturesEnabled  = true

--- Determines natural scroll setting from macOS
--- @return boolean True if natural scrolling is active
local function readNaturalScroll()
    local ok, out = pcall(hs.execute, "defaults read -g com.apple.swipescrolldirection 2>/dev/null")
    return ok and type(out) == "string" and out:match("1") ~= nil
end

local naturalScroll = readNaturalScroll()
function M.isNaturalScroll() return naturalScroll end



-- ========================================
-- ===== 3.2) System & Navigation =====
-- ========================================

--- Safely terminates the custom selection drag mode
local function forceCleanup()
    if mouseEventTap and type(mouseEventTap.stop) == "function" then
        pcall(function() mouseEventTap:stop() end)
        mouseEventTap = nil
    end
    
    if leftClickPressed then
        pcall(function()
            hs.eventtap.event.newMouseEvent(
                hs.eventtap.event.types.leftMouseUp,
                hs.mouse.absolutePosition()
            ):post()
        end)
    end
    leftClickPressed = false
end

--- Toggles click-and-drag selection mode mimicking physical trackpad clicks
local function toggleSelection()
    if leftClickPressed then forceCleanup(); return end
    
    pcall(function()
        hs.eventtap.event.newMouseEvent(
            hs.eventtap.event.types.leftMouseDown,
            hs.mouse.absolutePosition()
        ):post()
    end)
    leftClickPressed = true
    
    local evTypes = hs.eventtap.event.types
    mouseEventTap = hs.eventtap.new(
        { evTypes.mouseMoved, evTypes.leftMouseDragged, evTypes.leftMouseUp },
        function(e)
            local t = e:getType()
            if t == evTypes.leftMouseDragged then
                pcall(function()
                    hs.eventtap.event.newMouseEvent(evTypes.leftMouseDragged, e:location()):post()
                end)
                return true
            elseif t == evTypes.leftMouseUp then
                hs.timer.doAfter(0, forceCleanup)
                return true
            end
            return false
        end)
        
    if mouseEventTap then pcall(function() mouseEventTap:start() end) end
end

--- Triggers macOS Dictionary Lookup (Cmd+Ctrl+D)
local function triggerLookup()
    pcall(function() hs.eventtap.keyStroke({"ctrl", "cmd"}, "d", 0) end)
end

--- Posts system media keys safely
--- @param name string The system key name
local function sysKey(name)
    pcall(function()
        hs.eventtap.event.newSystemKeyEvent(name, true):post()
        hs.eventtap.event.newSystemKeyEvent(name, false):post()
    end)
end

--- Cycles through standard windows of the frontmost application
--- @param goNext boolean True to navigate forward, false to navigate backward
local function winNav(goNext)
    local ok, app = pcall(hs.application.frontmostApplication)
    if not ok or not app then return end
    
    local ok_wins, wins = pcall(function() return app:allWindows() end)
    if not ok_wins or type(wins) ~= "table" then return end
    
    local visible = {}
    for _, w in ipairs(wins) do
        if w:isStandard() and not w:isMinimized() then table.insert(visible, w) end
    end
    
    if #visible <= 1 then return end
    table.sort(visible, function(a, b) return a:id() < b:id() end)
    
    local ok_cur, cur = pcall(hs.window.focusedWindow)
    local idx = 1
    for i, w in ipairs(visible) do
        if ok_cur and cur and w:id() == cur:id() then idx = i; break end
    end
    
    local target_idx = goNext and (idx % #visible + 1) or ((idx - 2) % #visible + 1)
    pcall(function() visible[target_idx]:focus() end)
end

--- Cycles through macOS Spaces
--- @param goNext boolean True to navigate forward, false to navigate backward
local function spaceNav(goNext)
    local ok, spaces = pcall(function() return require("hs.spaces") end)
    if ok and type(spaces) == "table" then
        local screen = hs.screen.mainScreen()
        local uuid = screen and screen:getUUID()
        
        if uuid then
            local ok_all, all = pcall(function() return spaces.allSpaces() end)
            if ok_all and type(all) == "table" and all[uuid] and #all[uuid] > 0 then
                local sps = all[uuid]
                local active = nil
                
                if type(spaces.activeSpace) == "function" then
                    pcall(function() active = spaces.activeSpace() end)
                else
                    local fw = hs.window.frontmostWindow()
                    if fw and type(spaces.windowSpaces) == "function" then
                        local okw, ws = pcall(function() return spaces.windowSpaces(fw) end)
                        if okw and type(ws) == "table" and #ws > 0 then active = ws[1] end
                    end
                end
                
                if active then
                    local idx = nil
                    for i, id in ipairs(sps) do 
                        if tostring(id) == tostring(active) then idx = i; break end 
                    end
                    
                    if idx then
                        local total = #sps
                        local delta = goNext and 1 or -1
                        local newIdx = ((idx - 1 + delta) % total) + 1
                        pcall(function() hs.eventtap.keyStroke({"ctrl"}, tostring(newIdx), 0) end)
                        return
                    end
                end
            end
        end
    end
    
    -- Absolute fallback via AppleScript using raw keycodes (123=Left, 124=Right)
    pcall(hs.osascript.applescript, string.format(
        "tell application \"System Events\" to key code %d using {control down}",
        goNext and 124 or 123
    ))
end





-- ==================================
-- ==================================
-- ======= 4/ Action Registry =======
-- ==================================
-- ==================================

local AX, SG = {}, {}
local function ax(n, lbl, p, nx, scalable) AX[n] = {label = lbl, prev = p, next = nx, scalable = scalable} end
local function sg(n, lbl, fn)              SG[n] = {label = lbl, fn = fn} end

local SCALE_DIV = 3.5

-- Axis actions (prev / next) — scalable=true for continuous actions
ax("tabs",       "Onglets",
    function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end,
    function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end)

ax("windows",    "Fenêtres",
    function() winNav(false) end, 
    function() winNav(true) end)

ax("spaces",     "Spaces",
    function() spaceNav(false) end, 
    function() spaceNav(true) end)

ax("volume",     "Volume",
    function() sysKey("SOUND_DOWN") end, 
    function() sysKey("SOUND_UP") end, true)

ax("brightness", "Luminosité",
    function() sysKey("BRIGHTNESS_DOWN") end, 
    function() sysKey("BRIGHTNESS_UP") end, true)

ax("tracks",     "Pistes",
    function() sysKey("PREVIOUS") end, 
    function() sysKey("NEXT") end)

ax("words",      "Mots",
    function() pcall(hs.eventtap.keyStroke, {"alt"}, "left") end,
    function() pcall(hs.eventtap.keyStroke, {"alt"}, "right") end, true)

ax("lines",      "Lignes",
    function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end,
    function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end, true)

ax("line_bounds","Ligne (début/fin)",
    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end,
    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end)

ax("paragraphs", "Paragraphes",
    function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end,
    function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end, true)

ax("document",   "Document (début/fin)",
    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end,
    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)

-- Single actions
sg("none",             "Désactivé",            function() end)
sg("selection_toggle", "Toggle sélection",     toggleSelection)
sg("lookup",           "Définition du mot",    triggerLookup)

sg("tab_new",          "Nouvel onglet",        function() pcall(hs.eventtap.keyStroke, {"cmd"}, "t") end)
sg("tab_close",        "Fermer onglet",        function() pcall(hs.eventtap.keyStroke, {"cmd"}, "w") end)
sg("tab_prev",         "Onglet précédent",     function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end)
sg("tab_next",         "Onglet suivant",       function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end)

sg("win_prev",         "Fenêtre précédente",   function() winNav(false) end)
sg("win_next",         "Fenêtre suivante",     function() winNav(true) end)

sg("space_prev",       "Space précédent",      function() spaceNav(false) end)
sg("space_next",       "Space suivant",        function() spaceNav(true) end)

sg("mission_control",  "Mission Control",      function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 160") end)
sg("app_expose",       "App Exposé",           function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 125 using {control down}") end)

sg("vol_up",           "Volume +",             function() sysKey("SOUND_UP") end)
sg("vol_down",         "Volume -",             function() sysKey("SOUND_DOWN") end)

sg("brightness_up",    "Luminosité +",         function() sysKey("BRIGHTNESS_UP") end)
sg("brightness_down",  "Luminosité -",         function() sysKey("BRIGHTNESS_DOWN") end)

sg("mute",             "Muet/Unmute",          function() sysKey("MUTE") end)
sg("track_play",       "Lecture/Pause",        function() sysKey("PLAY") end)
sg("track_next",       "Piste suivante",       function() sysKey("NEXT") end)
sg("track_prev",       "Piste précédente",     function() sysKey("PREVIOUS") end)

sg("word_prev",        "Mot précédent",        function() pcall(hs.eventtap.keyStroke, {"alt"}, "left") end)
sg("word_next",        "Mot suivant",          function() pcall(hs.eventtap.keyStroke, {"alt"}, "right") end)

sg("line_start",       "Début de ligne",       function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end)
sg("line_end",         "Fin de ligne",         function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end)

sg("para_prev",        "Paragraphe précédent", function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end)
sg("para_next",        "Paragraphe suivant",   function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end)

sg("doc_start",        "Début du document",    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end)
sg("doc_end",          "Fin du document",      function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)

M.AX_NAMES = {
    "none", "tabs", "windows", "spaces",
    "volume", "brightness", "tracks",
    "words", "lines", "line_bounds", "paragraphs", "document",
}

M.SG_NAMES = {
    "none", "selection_toggle", "lookup",
    "tab_new", "tab_close", "tab_prev", "tab_next",
    "win_prev", "win_next", "space_prev", "space_next",
    "mission_control", "app_expose",
    "vol_up", "vol_down", "brightness_up", "brightness_down", "mute",
    "track_play", "track_next", "track_prev",
    "word_prev", "word_next", "line_start", "line_end",
    "para_prev", "para_next", "doc_start", "doc_end",
}

--- Retrieves the localized label for a given action ID
--- @param name string The action ID
--- @return string The human-readable label
function M.get_action_label(name)
    if not name or name == "none" then return "Désactivé" end
    if AX[name] then return AX[name].label end
    if SG[name] then return SG[name].label end
    return name
end

-- Initialize gesture actions with defaults
local ga = {}
for k, v in pairs(M.DEFAULT_GESTURES) do
    ga[k] = v
end

M.AXIS_SLOTS = {
    "swipe_2_diag",
    "swipe_3_horiz", "swipe_3_diag",
    "swipe_4_horiz", "swipe_4_diag",
    "swipe_5_horiz", "swipe_5_diag",
}

M.SINGLE_SLOTS = {
    "tap_3", "tap_4", "tap_5",
    "swipe_3_up", "swipe_3_down",
    "swipe_4_up", "swipe_4_down",
    "swipe_5_up", "swipe_5_down",
}

function M.get_action(slot)         return ga[slot] end
function M.set_action(slot, action) ga[slot] = action end

function M.get_all_actions()
    local t = {}
    for k, v in pairs(ga) do t[k] = v end
    return t
end





-- ======================================
-- ======================================
-- ======= 5/ Gesture Engine Core =======
-- ======================================
-- ======================================



-- =========================================
-- ===== 5.1) Execution & Blocking =====
-- =========================================

local function doSingle(slot)
    local s = SG[ga[slot]]
    if s and type(s.fn) == "function" then pcall(s.fn) end
end

local function fireAxis(slot, goNext)
    local a = AX[ga[slot]]
    if not a then return end
    local fn = goNext and a.next or a.prev
    if type(fn) == "function" then pcall(fn) end
end

local function isScalableSlot(slot)
    local a = AX[ga[slot]]
    return a and a.scalable == true
end

local scrollBlocker = nil

local function startScrollBlock()
    if scrollBlocker then return end
    
    local evTypes = hs.eventtap.event.types
    scrollBlocker = hs.eventtap.new(
        { evTypes.scrollWheel, evTypes.gesture },
        function() return true end
    )
    if scrollBlocker then pcall(function() scrollBlocker:start() end) end
end

local function stopScrollBlock()
    if scrollBlocker and type(scrollBlocker.stop) == "function" then
        pcall(function() scrollBlocker:stop() end)
        scrollBlocker = nil
    end
end



-- ========================================
-- ===== 5.2) Mathematics & State =====
-- ========================================

local gs = {}
local function resetGS()
    stopScrollBlock()
    gs = {
        active         = false, 
        startTime      = nil, 
        startPos       = nil, 
        endPos         = nil, 
        maxFingers     = 0,
        lockedDir      = nil, 
        stepsCommitted = 0, 
        lifting        = false,
    }
end
resetGS()

local function avgPos(touches)
    local x, y = 0, 0
    if type(touches) ~= "table" or #touches == 0 then return {x=0, y=0} end
    
    for _, t in ipairs(touches) do
        if type(t) == "table" and type(t.absoluteVector) == "table" and type(t.absoluteVector.position) == "table" then
            x = x + (tonumber(t.absoluteVector.position.x) or 0)
            y = y + (tonumber(t.absoluteVector.position.y) or 0)
        end
    end
    return { x = x / #touches, y = y / #touches }
end

local function slotForDir(mf, dir)
    if mf == 2 then
        if dir == "diag"  then return "swipe_2_diag"  end
    elseif mf == 3 then
        if     dir == "horiz" then return "swipe_3_horiz"
        elseif dir == "diag"  then return "swipe_3_diag" end
    elseif mf == 4 then
        if     dir == "horiz" then return "swipe_4_horiz"
        elseif dir == "diag"  then return "swipe_4_diag" end
    elseif mf >= 5 then
        if     dir == "horiz" then return "swipe_5_horiz"
        elseif dir == "diag"  then return "swipe_5_diag" end
    end
    return nil
end

local function computeDir(dx, dy, mf)
    local adx  = math.abs(dx)
    local ady  = math.abs(dy)
    local dist = adx + ady
    local min  = (mf == 2) and SWIPE_MIN_2 or SWIPE_MIN
    
    if dist < min then return nil end

    local angle = math.deg(math.atan(ady, adx))

    if angle >= 35 then 
        return "vert"
    elseif angle <= 20 then 
        return "horiz"
    else
        local diagMin = (mf == 2) and DIAG_MIN_2 or min
        if adx >= diagMin and ady >= diagMin then return "diag" end
        return (adx >= ady) and "horiz" or "vert"
    end
end

local function signedDist(pos)
    if not gs.startPos then return 0 end
    local dx = pos.x - gs.startPos.x
    return (naturalScroll and -dx) or dx
end

local function commitGesture(now)
    if not gesturesEnabled or not gs.startPos or not gs.endPos then return end
    
    local dx      = gs.endPos.x - gs.startPos.x
    local dy      = gs.endPos.y - gs.startPos.y
    local adx     = math.abs(dx)
    local ady     = math.abs(dy)
    local elapsed = now - (gs.startTime or now)
    local mf      = gs.maxFingers

    -- Tap detection
    if elapsed <= TAP_MAX_SEC and (adx + ady) < TAP_MAX_DELTA then
        if     mf == 3 then doSingle("tap_3")
        elseif mf == 4 then doSingle("tap_4")
        elseif mf >= 5 then doSingle("tap_5") end
        return
    end

    local dir = computeDir(dx, dy, mf)
    if not dir then return end

    if dir == "vert" then
        local goDown = dy > 0
        if     mf == 3 then doSingle(goDown and "swipe_3_down" or "swipe_3_up")
        elseif mf == 4 then doSingle(goDown and "swipe_4_down" or "swipe_4_up")
        elseif mf >= 5 then doSingle(goDown and "swipe_5_down" or "swipe_5_up") end
        return
    end

    if dir == "diag" then
        local diag_slot = slotForDir(mf, dir)
        if not diag_slot or ga[diag_slot] == "none" then
            dir = (adx >= ady) and "horiz" or "vert"
        end
    end

    if dir == "vert" then
        local goDown = dy > 0
        if     mf == 3 then doSingle(goDown and "swipe_3_down" or "swipe_3_up")
        elseif mf == 4 then doSingle(goDown and "swipe_4_down" or "swipe_4_up")
        elseif mf >= 5 then doSingle(goDown and "swipe_5_down" or "swipe_5_up") end
        return
    end

    local slot = slotForDir(mf, dir)
    if not slot or ga[slot] == "none" then return end
    
    if not isScalableSlot(slot) then
        local sd = signedDist(gs.endPos)
        if math.abs(sd) >= SWIPE_MIN then fireAxis(slot, sd > 0) end
    end
end



-- ===========================================
-- ===== 5.3) Touch Frame Processor =====
-- ===========================================

local function onFrame(touches)
    if type(touches) ~= "table" then return end
    local n   = #touches
    local now = hs.timer.secondsSinceEpoch()
    
    if n == 0 then
        stopScrollBlock()
        if gs.active and gs.startPos and gs.endPos then
            pcall(commitGesture, now)
        end
        resetGS()
        return
    end
    
    if n >= 3 then startScrollBlock() end
    
    if n >= 2 then
        local pos = avgPos(touches)
        if not gs.active then
            gs.active         = true
            gs.startTime      = now
            gs.startPos       = pos
            gs.endPos         = pos
            gs.maxFingers     = n
            gs.stepsCommitted = 0
            gs.lifting        = false
        else
            if n < gs.maxFingers then
                gs.lifting = true
            else
                gs.maxFingers = n
            end
            gs.endPos = pos

            local adx_now = math.abs(pos.x - gs.startPos.x)
            local ady_now = math.abs(pos.y - gs.startPos.y)
            if (now - gs.startTime) < TAP_MAX_SEC and (adx_now + ady_now) < TAP_MAX_DELTA then
                return
            end

            if not gs.lifting then
                if gs.lockedDir == nil then
                    local dx = pos.x - gs.startPos.x
                    local dy = pos.y - gs.startPos.y
                    local tentative = computeDir(dx, dy, gs.maxFingers)
                    
                    if tentative == "diag" then
                        local diag_slot = slotForDir(gs.maxFingers, tentative)
                        if not diag_slot or ga[diag_slot] == "none" then
                            tentative = (math.abs(dx) >= math.abs(dy)) and "horiz" or "vert"
                        end
                    end
                    gs.lockedDir = tentative
                end

                if gs.lockedDir and gs.lockedDir ~= "vert" then
                    local slot = slotForDir(gs.maxFingers, gs.lockedDir)
                    if slot and isScalableSlot(slot) then
                        local sd          = signedDist(pos)
                        local targetSteps = math.floor(sd / SCALE_DIV)
                        local diff        = targetSteps - gs.stepsCommitted
                        
                        if diff > 0 then
                            for _ = 1, diff  do fireAxis(slot, true)  end
                        elseif diff < 0 then
                            for _ = 1, -diff do fireAxis(slot, false) end
                        end
                        gs.stepsCommitted = targetSteps
                    end
                end
            end
        end
    end
end





-- ==================================
-- ==================================
-- ======= 6/ Device Watchers =======
-- ==================================
-- ==================================

local touch_watchers = {}

local function create_watcher(deviceID)
    if not touchdevice then return end
    
    if touch_watchers[deviceID] then
        local ok, r = pcall(function() return touch_watchers[deviceID]:isRunning() end)
        if ok and r then return end
        pcall(function() touch_watchers[deviceID]:stop() end)
    end
    
    local ok_dev, dev = pcall(touchdevice.forDeviceID, deviceID)
    if not ok_dev or not dev then return end
    
    local w = dev:frameCallback(function(_, touches, _, _)
        pcall(onFrame, touches)
    end)
    
    touch_watchers[deviceID] = w
    if w and type(w.start) == "function" then
        pcall(function() w:start() end)
        if type(notifications.debugLog) == "function" then
            pcall(notifications.debugLog, "watcher created for device", deviceID)
        end
    end
end

local function ensure_watchers()
    if not touchdevice then return end
    local ok, devices = pcall(touchdevice.devices)
    if ok and type(devices) == "table" then
        for _, id in ipairs(devices) do pcall(create_watcher, id) end
    end
end





-- =============================
-- =============================
-- ======= 7/ Public API =======
-- =============================
-- =============================

--- Initializes and binds multi-touch listeners
function M.start()
    if not touchdevice then
        print("[gestures] Warning: touchdevice module not available.")
        return
    end
    
    gesturesEnabled = true
    pcall(ensure_watchers)
    
    -- Health check timer to restore dead device hooks
    hs.timer.doEvery(5, function()
        for id, w in pairs(touch_watchers) do
            local ok, r = pcall(function() return w:isRunning() end)
            if not ok or not r then
                touch_watchers[id] = nil
                pcall(create_watcher, id)
            end
        end
        pcall(ensure_watchers)
    end)
end

function M.enable_all()  gesturesEnabled = true  end
function M.disable_all() gesturesEnabled = false end

function M.enable(name)  if name == "all" then gesturesEnabled = true  end end
function M.disable(name) if name == "all" then gesturesEnabled = false end end

function M.is_enabled()  return gesturesEnabled end

M.forceCleanup       = forceCleanup
M.toggleSelection    = toggleSelection
M.triggerLookup      = triggerLookup

M.isLeftClickPressed = function() return leftClickPressed end

return M
