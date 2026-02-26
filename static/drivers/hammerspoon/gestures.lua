-- gestures.lua
-- Chaque geste (slot) est indépendamment assignable à une action.
-- Slots "axe" (←/→ ou /\) → actions avec sens prev/next.
-- Slots "simple" (tap, ↑↓)  → actions sans direction.

local utils = require("utils")
local touchdevice = require("hs._asm.undocumented.touchdevice")
local M = {}

-- ── Seuils ────────────────────────────────────────────────────────────────────
local TAP_MAX_SEC    = 0.35
local TAP_MAX_DELTA  = 2.0
local SWIPE_MIN      = 1.5    -- 3/4/5 doigts : distance min pour valider un swipe
local SWIPE_MIN_2    = 3.0    -- 2 doigts horiz/vert (laissés à macOS, seulement diag)
local DIAG_MIN_2     = 5.0    -- 2 doigts : distance totale min pour valider une diagonale
                               -- (évite les micro-mouvements de scroll interprétés comme diag)
local DIAG_MAX_RATIO = 2.0    -- ratio max dx/dy pour qu'un mouvement soit considéré diagonal

-- ── Natural scroll ────────────────────────────────────────────────────────────
local function readNaturalScroll()
    local out = hs.execute("defaults read -g com.apple.swipescrolldirection 2>/dev/null")
    return out and out:match("1") ~= nil
end
local naturalScroll = readNaturalScroll()
function M.isNaturalScroll() return naturalScroll end

-- ── Mode sélection ────────────────────────────────────────────────────────────
-- Déclarés tôt pour que les closures d'action puissent les referencer.
local leftClickPressed = false
local mouseEventTap    = nil
local gesturesEnabled  = true

local function forceCleanup()
    if mouseEventTap then
        pcall(function() mouseEventTap:stop() end)
        mouseEventTap = nil
    end
    if leftClickPressed then
        hs.eventtap.event.newMouseEvent(
            hs.eventtap.event.types.leftMouseUp,
            hs.mouse.absolutePosition()):post()
    end
    leftClickPressed = false
end

local function toggleSelection()
    if leftClickPressed then forceCleanup(); return end
    hs.eventtap.event.newMouseEvent(
        hs.eventtap.event.types.leftMouseDown,
        hs.mouse.absolutePosition()):post()
    leftClickPressed = true
    mouseEventTap = hs.eventtap.new(
        { hs.eventtap.event.types.mouseMoved,
          hs.eventtap.event.types.leftMouseDragged,
          hs.eventtap.event.types.leftMouseUp },
        function(e)
            local t = e:getType()
            if t == hs.eventtap.event.types.leftMouseDragged then
                hs.eventtap.event.newMouseEvent(
                    hs.eventtap.event.types.leftMouseDragged, e:location()):post()
                return true
            elseif t == hs.eventtap.event.types.leftMouseUp then
                hs.timer.doAfter(0, forceCleanup); return true
            end
        end)
    pcall(function() mouseEventTap:start() end)
end

local function triggerLookup()
    pcall(function() hs.eventtap.keyStroke({"ctrl","cmd"}, "d", 0) end)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function sysKey(name)
    hs.eventtap.event.newSystemKeyEvent(name, true):post()
    hs.eventtap.event.newSystemKeyEvent(name, false):post()
end

local function winNav(goNext)
    local app = hs.application.frontmostApplication()
    if not app then return end
    local visible = {}
    for _, w in ipairs(app:allWindows()) do
        if w:isStandard() and not w:isMinimized() then table.insert(visible, w) end
    end
    if #visible <= 1 then return end
    table.sort(visible, function(a,b) return a:id() < b:id() end)
    local cur = hs.window.focusedWindow()
    local idx = 1
    for i, w in ipairs(visible) do
        if cur and w:id() == cur:id() then idx = i; break end
    end
    visible[goNext and (idx%#visible+1) or ((idx-2)%#visible+1)]:focus()
end

local function spaceNav(goNext)
    hs.osascript.applescript(string.format(
        'tell application "System Events" to key code %d using {control down}',
        goNext and 124 or 123))
end

-- ── Registre des actions ──────────────────────────────────────────────────────
local AX, SG = {}, {}
-- scalable=true : l'action est répétée N fois proportionnellement à la distance.
-- Adapté aux actions continues (volume, luminosité, curseur).
-- NON scalable : actions ponctuelles (next track, changer de space, onglet...).
local function ax(n,lbl,p,nx,scalable) AX[n]={label=lbl, prev=p, next=nx, scalable=scalable} end
local function sg(n,lbl,fn)            SG[n]={label=lbl, fn=fn} end

-- Diviseur pour le calcul des steps : dist / SCALE_DIV arrondi.
-- Augmenter pour moins de répétitions, diminuer pour plus.
local SCALE_DIV = 3.5

-- Actions axe (prev / next) — scalable=true pour les actions continues
ax("tabs",       "Onglets",
    function() hs.eventtap.keyStroke({"ctrl","shift"},"tab") end,
    function() hs.eventtap.keyStroke({"ctrl"},"tab") end)
ax("windows",    "Fenêtres",
    function() winNav(false) end, function() winNav(true) end)
ax("spaces",     "Spaces",
    function() spaceNav(false) end, function() spaceNav(true) end)
ax("volume",     "Volume",
    function() sysKey("SOUND_DOWN") end, function() sysKey("SOUND_UP") end,   true)
ax("brightness", "Luminosité",
    function() sysKey("BRIGHTNESS_DOWN") end, function() sysKey("BRIGHTNESS_UP") end, true)
ax("tracks",     "Pistes",
    function() sysKey("PREVIOUS") end, function() sysKey("NEXT") end)
ax("words",      "Mots",
    function() hs.eventtap.keyStroke({"alt"},"left")  end,
    function() hs.eventtap.keyStroke({"alt"},"right") end, true)
ax("lines",      "Lignes",
    function() hs.eventtap.keyStroke({"alt"},"up")   end,
    function() hs.eventtap.keyStroke({"alt"},"down") end, true)
ax("line_bounds","Ligne (début/fin)",
    function() hs.eventtap.keyStroke({"cmd"},"left")  end,
    function() hs.eventtap.keyStroke({"cmd"},"right") end)
ax("paragraphs", "Paragraphes",
    function() hs.eventtap.keyStroke({"alt"},"up")   end,
    function() hs.eventtap.keyStroke({"alt"},"down") end, true)
ax("document",   "Document (début/fin)",
    function() hs.eventtap.keyStroke({"cmd"},"up")   end,
    function() hs.eventtap.keyStroke({"cmd"},"down") end)

-- Actions simples
sg("none",            "Désactivé",            function() end)
sg("selection_toggle","Toggle sélection",     toggleSelection)
sg("lookup",          "Définition du mot",    triggerLookup)
sg("tab_new",         "Nouvel onglet",        function() hs.eventtap.keyStroke({"cmd"},"t") end)
sg("tab_close",       "Fermer onglet",        function() hs.eventtap.keyStroke({"cmd"},"w") end)
sg("tab_prev",        "Onglet précédent",     function() hs.eventtap.keyStroke({"ctrl","shift"},"tab") end)
sg("tab_next",        "Onglet suivant",       function() hs.eventtap.keyStroke({"ctrl"},"tab") end)
sg("win_prev",        "Fenêtre précédente",   function() winNav(false) end)
sg("win_next",        "Fenêtre suivante",     function() winNav(true)  end)
sg("space_prev",      "Space précédent",      function() spaceNav(false) end)
sg("space_next",      "Space suivant",        function() spaceNav(true)  end)
sg("mission_control", "Mission Control",      function()
    hs.osascript.applescript('tell application "System Events" to key code 160') end)
sg("app_expose",      "App Exposé",           function()
    hs.osascript.applescript('tell application "System Events" to key code 125 using {control down}') end)
sg("vol_up",          "Volume +",             function() sysKey("SOUND_UP")        end)
sg("vol_down",        "Volume -",             function() sysKey("SOUND_DOWN")      end)
sg("brightness_up",   "Luminosité +",         function() sysKey("BRIGHTNESS_UP")   end)
sg("brightness_down", "Luminosité -",         function() sysKey("BRIGHTNESS_DOWN") end)
sg("mute",            "Muet/Unmute",          function() sysKey("MUTE")            end)
sg("track_play",      "Lecture/Pause",        function() sysKey("PLAY")            end)
sg("track_next",      "Piste suivante",       function() sysKey("NEXT")            end)
sg("track_prev",      "Piste précédente",     function() sysKey("PREVIOUS")        end)
sg("word_prev",       "Mot précédent",        function() hs.eventtap.keyStroke({"alt"},"left")  end)
sg("word_next",       "Mot suivant",          function() hs.eventtap.keyStroke({"alt"},"right") end)
sg("line_start",      "Début de ligne",       function() hs.eventtap.keyStroke({"cmd"},"left")  end)
sg("line_end",        "Fin de ligne",         function() hs.eventtap.keyStroke({"cmd"},"right") end)
sg("para_prev",       "Paragraphe précédent", function() hs.eventtap.keyStroke({"alt"},"up")    end)
sg("para_next",       "Paragraphe suivant",   function() hs.eventtap.keyStroke({"alt"},"down")  end)
sg("doc_start",       "Début du document",    function() hs.eventtap.keyStroke({"cmd"},"up")    end)
sg("doc_end",         "Fin du document",      function() hs.eventtap.keyStroke({"cmd"},"down")  end)

-- Listes exposées pour le menu (ordre affiché)
M.AX_NAMES = {
    "none","tabs","windows","spaces",
    "volume","brightness","tracks",
    "words","lines","line_bounds","paragraphs","document",
}
M.SG_NAMES = {
    "none","selection_toggle","lookup",
    "tab_new","tab_close","tab_prev","tab_next",
    "win_prev","win_next","space_prev","space_next",
    "mission_control","app_expose",
    "vol_up","vol_down","brightness_up","brightness_down","mute",
    "track_play","track_next","track_prev",
    "word_prev","word_next","line_start","line_end",
    "para_prev","para_next","doc_start","doc_end",
}

function M.get_action_label(name)
    if not name or name == "none" then return "Désactivé" end
    if AX[name] then return AX[name].label end
    if SG[name] then return SG[name].label end
    return name
end

-- ── Slots et valeurs par défaut ───────────────────────────────────────────────
local ga = {
    tap_3         = "selection_toggle",
    tap_4         = "lookup",
    tap_5         = "none",
    swipe_2_diag  = "tabs",
    swipe_3_horiz = "none",
    swipe_3_diag  = "none",
    swipe_3_up    = "none",
    swipe_3_down  = "none",
    swipe_4_horiz = "spaces",
    swipe_4_diag  = "windows",
    swipe_4_up    = "mission_control",
    swipe_4_down  = "app_expose",
    swipe_5_horiz = "windows",
    swipe_5_diag  = "none",
    swipe_5_up    = "none",
    swipe_5_down  = "none",
}

-- Distinction axe vs simple (pour savoir quel sous-menu afficher)
M.AXIS_SLOTS   = {
    "swipe_2_diag",
    "swipe_3_horiz","swipe_3_diag",
    "swipe_4_horiz","swipe_4_diag",
    "swipe_5_horiz","swipe_5_diag",
}
M.SINGLE_SLOTS = {
    "tap_3","tap_4","tap_5",
    "swipe_3_up","swipe_3_down",
    "swipe_4_up","swipe_4_down",
    "swipe_5_up","swipe_5_down",
}

function M.get_action(slot)         return ga[slot] end
function M.set_action(slot, action) ga[slot] = action end
function M.get_all_actions()
    local t = {}; for k,v in pairs(ga) do t[k]=v end; return t
end

-- ── Exécution ─────────────────────────────────────────────────────────────────
-- dist : distance du swipe (en unités touchdevice) pour les actions scalables.
local function doAxis(slot, goNext, dist)
    local a = AX[ga[slot]]
    if not a then return end
    local steps = 1
    if a.scalable and dist then
        steps = math.max(1, math.floor(dist / SCALE_DIV))
    end
    local fn = goNext and a.next or a.prev
    for _ = 1, steps do fn() end
end

local function doSingle(slot)
    local s = SG[ga[slot]]
    if s then s.fn() end
end

-- ── Scroll blocker ────────────────────────────────────────────────────────────
-- Bloque les events scroll/swipe générés par macOS pendant un geste 3+ doigts,
-- ce qui empêche le scroll parasite pendant les swipes verticaux notamment.
local scrollBlocker = nil

local function startScrollBlock()
    if scrollBlocker then return end
    scrollBlocker = hs.eventtap.new(
        { hs.eventtap.event.types.scrollWheel,
          hs.eventtap.event.types.gesture },
        function() return true end)  -- avaler l'événement
    pcall(function() scrollBlocker:start() end)
end

local function stopScrollBlock()
    if scrollBlocker then
        pcall(function() scrollBlocker:stop() end)
        scrollBlocker = nil
    end
end

-- ── Machine à états ───────────────────────────────────────────────────────────
local gs = {}
local function resetGS()
    stopScrollBlock()
    gs = {active=false, startTime=nil, startPos=nil, endPos=nil, maxFingers=0}
end
resetGS()

local function avgPos(touches)
    local x, y = 0, 0
    for _, t in ipairs(touches) do
        x = x + t.absoluteVector.position.x
        y = y + t.absoluteVector.position.y
    end
    return {x=x/#touches, y=y/#touches}
end

local function commitGesture(now)
    if not gesturesEnabled then return end
    local dx      = gs.endPos.x - gs.startPos.x
    local dy      = gs.endPos.y - gs.startPos.y
    local adx     = math.abs(dx)
    local ady     = math.abs(dy)
    local elapsed = now - gs.startTime
    local mf      = gs.maxFingers
    local min     = (mf == 2) and SWIPE_MIN_2 or SWIPE_MIN
    local goNext  = (naturalScroll and dx < 0) or (not naturalScroll and dx > 0)

    -- Tap
    if elapsed <= TAP_MAX_SEC and (adx + ady) < TAP_MAX_DELTA then
        if     mf == 3 then doSingle("tap_3")
        elseif mf == 4 then doSingle("tap_4")
        elseif mf >= 5 then doSingle("tap_5") end
        return
    end

    local isVert  = ady > adx * 2 and ady > min
    local isHoriz = adx > ady * 2 and adx > min
    -- Pour la diagonale 2 doigts : exige une distance totale minimale absolue
    -- pour éviter que les micro-mouvements de scroll soient interprétés comme diagonale.
    local diagMin = (mf == 2) and DIAG_MIN_2 or min
    local isDiag  = adx > diagMin and ady > diagMin
                    and adx < ady * DIAG_MAX_RATIO and ady < adx * DIAG_MAX_RATIO
    -- Pour les actions scalables : distance principale du swipe
    local distH = adx                        -- pour slots horiz
    local distD = math.max(adx, ady)         -- pour slots diag
    local distV = ady                        -- pour slots vert (non utilisé, simples)

    if mf == 2 then
        if isDiag then doAxis("swipe_2_diag", goNext, distD) end

    elseif mf == 3 then
        if     isHoriz then doAxis("swipe_3_horiz", goNext, distH)
        elseif isDiag  then doAxis("swipe_3_diag",  goNext, distD)
        elseif isVert  then
            if dy < 0 then doSingle("swipe_3_up") else doSingle("swipe_3_down") end
        end

    elseif mf == 4 then
        if     isVert  then
            if dy < 0 then doSingle("swipe_4_up") else doSingle("swipe_4_down") end
        elseif isDiag  then doAxis("swipe_4_diag",  goNext, distD)
        elseif isHoriz then doAxis("swipe_4_horiz", goNext, distH)
        end

    elseif mf >= 5 then
        if     isVert  then
            if dy < 0 then doSingle("swipe_5_up") else doSingle("swipe_5_down") end
        elseif isDiag  then doAxis("swipe_5_diag",  goNext, distD)
        elseif isHoriz then doAxis("swipe_5_horiz", goNext, distH)
        end
    end
end

local function onFrame(touches)
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
    if n >= 3 then
        -- Bloquer le scroll macOS dès qu'on pose 3+ doigts
        startScrollBlock()
    end
    if n >= 2 then
        local pos = avgPos(touches)
        if not gs.active then
            gs = {active=true, startTime=now, startPos=pos, endPos=pos, maxFingers=n}
        else
            if n > gs.maxFingers then gs.maxFingers = n end
            gs.endPos = pos
        end
    end
end

-- ── Watchers ──────────────────────────────────────────────────────────────────
local touch_watchers = {}

local function create_watcher(deviceID)
    if touch_watchers[deviceID] then
        local ok, r = pcall(function() return touch_watchers[deviceID]:isRunning() end)
        if ok and r then return end
        pcall(function() touch_watchers[deviceID]:stop() end)
    end
    local w = touchdevice.forDeviceID(deviceID):frameCallback(function(_, touches, _, _)
        pcall(onFrame, touches)
    end)
    touch_watchers[deviceID] = w
    pcall(function() w:start() end)
    utils.debugLog("watcher créé pour device", deviceID)
end

local function ensure_watchers()
    for _, id in ipairs(touchdevice.devices()) do pcall(create_watcher, id) end
end

-- ── API publique ──────────────────────────────────────────────────────────────
function M.start()
    gesturesEnabled = true
    ensure_watchers()
    hs.timer.doEvery(5, function()
        for id, w in pairs(touch_watchers) do
            local ok, r = pcall(function() return w:isRunning() end)
            if not ok or not r then
                touch_watchers[id] = nil; pcall(create_watcher, id)
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
