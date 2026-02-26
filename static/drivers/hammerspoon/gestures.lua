-- gestures.lua
-- Gestion des gestes multi-doigts via touchdevice + Swipe spoon (3 doigts)
--
-- Architecture : une seule machine à états (gs) par callback de frame.
-- La décision tap/swipe est prise uniquement au lever complet des doigts (n==0),
-- en utilisant gs.maxFingers pour éviter tout conflit 4↔5 doigts.

local utils = require("utils")
local touchdevice = require("hs._asm.undocumented.touchdevice")
local M = {}

-- ── Feature flags ─────────────────────────────────────────────────────────────
-- Noms conservés identiques pour compatibilité avec le menu existant.
local ff = {
    tap_selection = true,  -- tap 3 doigts  → activer/désactiver sélection texte
    tap_lookup    = true,  -- tap 4 doigts  → définition du mot (Ctrl+Cmd+D)
    swipe_left    = true,  -- swipe 3 ←    → onglet précédent
    swipe_right   = true,  -- swipe 3 →    → onglet suivant
    swipe_up      = true,  -- swipe 3 ↑    → nouvel onglet
    swipe_down    = true,  -- swipe 3 ↓    → fermer onglet
    swipe_4       = true,  -- swipe 4 ←/→  → changer de Space (⚠ désactiver dans Réglages Système > Trackpad)
    swipe_5       = true,  -- swipe 5 ←/→  → fenêtre suivante/précédente même app
}

-- ── Seuils ────────────────────────────────────────────────────────────────────
local TAP_MAX_SEC   = 0.35
local TAP_MAX_DELTA = 2.0
local SWIPE_MIN_H   = 1.5
local SWIPE_MIN_V   = 3.0

-- ── Natural scroll ────────────────────────────────────────────────────────────
-- "1" = naturel (sens trackpad = sens contenu, comme iOS) :
--   glisser gauche → contenu part à droite → Space suivant
-- "0" = non-naturel (sens classique) :
--   glisser gauche → Space précédent
-- On lit le réglage une fois au chargement ; un rechargement HS suffit si on change.
local function isNaturalScroll()
    local out = hs.execute("defaults read -g com.apple.swipescrolldirection 2>/dev/null")
    return out and out:match("1") ~= nil
end
local naturalScroll = isNaturalScroll()

function M.isNaturalScroll() return naturalScroll end

-- ── Mode sélection ────────────────────────────────────────────────────────────
local leftClickPressed = false
local mouseEventTap = nil

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
                hs.timer.doAfter(0, forceCleanup)
                return true
            end
        end)
    pcall(function() mouseEventTap:start() end)
end

local function triggerLookup()
    pcall(function() hs.eventtap.keyStroke({"ctrl", "cmd"}, "d", 0) end)
end

-- ── Machine à états des gestes ────────────────────────────────────────────────
local gs = {}

local function resetGS()
    gs = { active=false, startTime=nil, startPos=nil, endPos=nil, maxFingers=0 }
end
resetGS()

local function avgPos(touches)
    local x, y = 0, 0
    for _, t in ipairs(touches) do
        x = x + t.absoluteVector.position.x
        y = y + t.absoluteVector.position.y
    end
    return { x = x / #touches, y = y / #touches }
end

-- Appelée une seule fois, quand tous les doigts quittent le trackpad.
local function commitGesture(now)
    local elapsed = now - gs.startTime
    local dx = gs.endPos.x - gs.startPos.x
    local dy = gs.endPos.y - gs.startPos.y
    local dist = math.abs(dx) + math.abs(dy)
    local mf = gs.maxFingers

    if elapsed <= TAP_MAX_SEC and dist < TAP_MAX_DELTA then
        -- ── TAP ──────────────────────────────────────────────────────────────
        if     mf == 3 and ff.tap_selection then toggleSelection()
        elseif mf == 4 and ff.tap_lookup    then triggerLookup() end

    elseif mf == 4 and ff.swipe_4 then
        local adx, ady = math.abs(dx), math.abs(dy)
        if adx > ady and adx > SWIPE_MIN_H then
            local goNext = (naturalScroll and dx < 0) or (not naturalScroll and dx > 0)
            local keycode = goNext and 124 or 123  -- 124=→  123=←
            hs.osascript.applescript(string.format(
                'tell application "System Events" to key code %d using {control down}',
                keycode))
        end

    elseif mf >= 5 and ff.swipe_5 then
        local adx, ady = math.abs(dx), math.abs(dy)
        if adx > ady and adx > SWIPE_MIN_H then
            local goNext = (naturalScroll and dx < 0) or (not naturalScroll and dx > 0)
            local app = hs.application.frontmostApplication()
            if app then
                local visible = {}
                for _, w in ipairs(app:allWindows()) do
                    if w:isStandard() and not w:isMinimized() then
                        table.insert(visible, w)
                    end
                end
                if #visible > 1 then
                    table.sort(visible, function(a, b) return a:id() < b:id() end)
                    local focused = hs.window.focusedWindow()
                    local currentIdx = 1
                    for i, w in ipairs(visible) do
                        if focused and w:id() == focused:id() then currentIdx = i; break end
                    end
                    local targetIdx
                    if goNext then
                        targetIdx = currentIdx % #visible + 1
                    else
                        targetIdx = (currentIdx - 2) % #visible + 1
                    end
                    visible[targetIdx]:focus()
                end
            end
        end
    end
    -- mf == 3 : swipe géré par le Swipe Spoon, on ne fait rien ici.
end

local function onFrame(touches)
    local n = #touches
    local now = hs.timer.secondsSinceEpoch()

    if n == 0 then
        -- Lever complet : c'est ici qu'on décide du geste.
        if gs.active and gs.startPos and gs.endPos then
            pcall(commitGesture, now)
        end
        resetGS()
        return
    end

    if n >= 3 then
        local pos = avgPos(touches)
        if not gs.active then
            -- Premier frame avec 3+ doigts : démarrage du geste.
            gs.active    = true
            gs.startTime = now
            gs.startPos  = pos
            gs.endPos    = pos
            gs.maxFingers = n
        else
            -- Mise à jour : on mémorise le nombre max de doigts vus.
            -- Cela permet de distinguer 4 et 5 doigts même si le 5e arrive tard.
            if n > gs.maxFingers then gs.maxFingers = n end
            gs.endPos = pos
        end
    end
    -- n = 1 ou 2 : on laisse macOS gérer ; si un geste était en cours,
    -- on attend simplement n==0 pour le valider (doigts qui se lèvent un à un).
end

-- ── Gestion des watchers ──────────────────────────────────────────────────────
local touch_watchers = {}

local function create_watcher(deviceID)
    if touch_watchers[deviceID] then
        local ok, running = pcall(function() return touch_watchers[deviceID]:isRunning() end)
        if ok and running then return end
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
    for _, id in ipairs(touchdevice.devices()) do
        pcall(create_watcher, id)
    end
end

-- ── Swipe 3 doigts via Spoon ──────────────────────────────────────────────────
local Swipe3 = nil
local sw3_id, sw3_th_h, sw3_th_v = nil, 0.04, 0.12

local function start_swipe3()
    local ok, sp = pcall(function() return hs.loadSpoon("Swipe") end)
    if not ok or not sp then
        utils.debugLog("Swipe spoon indisponible, swipe 3 doigts désactivé")
        return
    end
    Swipe3 = sp
    Swipe3:start(3, function(dir, dist, id)
        if id ~= sw3_id then
            sw3_id = id; sw3_th_h = 0.04; sw3_th_v = 0.12
        end
        local th = (dir == "left" or dir == "right") and sw3_th_h or sw3_th_v
        if dist > th then
            sw3_th_h, sw3_th_v = math.huge, math.huge
            -- En mode naturel le doigt va dans le même sens que le contenu :
            -- glisser gauche = aller vers l'onglet suivant (à droite).
            -- En mode non-naturel : glisser gauche = onglet précédent (sens classique).
            local isLeft  = (naturalScroll and dir == "right") or (not naturalScroll and dir == "left")
            local isRight = (naturalScroll and dir == "left")  or (not naturalScroll and dir == "right")
            if isLeft  and ff.swipe_left  then hs.eventtap.keyStroke({"ctrl","shift"}, "tab") end
            if isRight and ff.swipe_right then hs.eventtap.keyStroke({"ctrl"}, "tab") end
            if dir == "up"   and ff.swipe_up   then hs.eventtap.keyStroke({"cmd"}, "t") end
            if dir == "down" and ff.swipe_down then hs.eventtap.keyStroke({"cmd"}, "w") end
        end
    end)
    utils.debugLog("swipe3 démarré")
end

local function stop_swipe3()
    if Swipe3 then pcall(function() Swipe3:stop() end); Swipe3 = nil end
end

local function swipe3_needed()
    return ff.swipe_left or ff.swipe_right or ff.swipe_up or ff.swipe_down
end

-- ── API publique ──────────────────────────────────────────────────────────────
function M.start()
    ensure_watchers()
    if swipe3_needed() then start_swipe3() end
    -- Superviseur : redémarre les watchers morts toutes les 5 s.
    hs.timer.doEvery(5, function()
        for id, w in pairs(touch_watchers) do
            local ok, r = pcall(function() return w:isRunning() end)
            if not ok or not r then
                utils.debugLog("superviseur : redémarrage watcher", id)
                touch_watchers[id] = nil
                pcall(create_watcher, id)
            end
        end
        pcall(ensure_watchers)
    end)
end

local ALL_FLAGS = {
    "tap_selection","tap_lookup",
    "swipe_left","swipe_right","swipe_up","swipe_down",
    "swipe_4","swipe_5"
}

function M.enable(name)
    if name == "all" then
        for _, k in ipairs(ALL_FLAGS) do ff[k] = true end
        if not Swipe3 then start_swipe3() end
        return
    end
    if name == "swipe" then
        for _, k in ipairs({"swipe_left","swipe_right","swipe_up","swipe_down","swipe_4","swipe_5"}) do ff[k] = true end
        if not Swipe3 then start_swipe3() end
        return
    end
    if ff[name] ~= nil then
        ff[name] = true
        if (name=="swipe_left" or name=="swipe_right" or name=="swipe_up" or name=="swipe_down") and not Swipe3 then
            start_swipe3()
        end
    end
end

function M.disable(name)
    if name == "all" then
        for _, k in ipairs(ALL_FLAGS) do ff[k] = false end
        stop_swipe3()
        return
    end
    if name == "swipe" then
        for _, k in ipairs({"swipe_left","swipe_right","swipe_up","swipe_down","swipe_4","swipe_5"}) do ff[k] = false end
        stop_swipe3()
        return
    end
    if ff[name] ~= nil then
        ff[name] = false
        if not swipe3_needed() then stop_swipe3() end
    end
end

function M.is_enabled(name)
    return ff[name] == true
end

M.forceCleanup       = forceCleanup
M.toggleSelection    = toggleSelection
M.triggerLookup      = triggerLookup
M.isLeftClickPressed = function() return leftClickPressed end

return M
