--- modules/gestures/engine.lua

--- ==============================================================================
--- MODULE: Gestures Engine
--- DESCRIPTION:
--- Processes raw touch frames, computes vectors and thresholds, and triggers
--- the corresponding actions based on the global state configuration.
--- ==============================================================================

local M = {}

local hs = hs

local _state   = nil
local _actions = nil





-- =======================================
-- =======================================
-- ======= 1/ Constants & Thresholds =====
-- =======================================
-- =======================================

local TAP_MAX_SEC    = 0.35
local TAP_MAX_DELTA  = 2.0
local SWIPE_MIN      = 1.5    -- 3/4/5 fingers: minimum distance to validate a swipe
local SWIPE_MIN_2    = 3.0    -- 2 fingers horiz/vert (left to macOS, diagonal only)
local DIAG_MIN_2     = 5.0    -- 2 fingers: minimum total distance to validate a diagonal
local SCALE_DIV      = 3.5

local scrollBlocker  = nil
local gs             = {}





-- =====================================
-- =====================================
-- ======= 2/ Blocking Utilities =======
-- =====================================
-- =====================================

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





-- =====================================
-- =====================================
-- ======= 3/ Math & State Logic =======
-- =====================================
-- =====================================

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
    return (_state.natural_scroll and -dx) or dx
end

local function commitGesture(now)
    if not _state.enabled or not gs.startPos or not gs.endPos then return end
    
    local dx      = gs.endPos.x - gs.startPos.x
    local dy      = gs.endPos.y - gs.startPos.y
    local adx     = math.abs(dx)
    local ady     = math.abs(dy)
    local elapsed = now - (gs.startTime or now)
    local mf      = gs.maxFingers

    -- Tap detection
    if elapsed <= TAP_MAX_SEC and (adx + ady) < TAP_MAX_DELTA then
        local slot = nil
        if     mf == 3 then slot = "tap_3"
        elseif mf == 4 then slot = "tap_4"
        elseif mf >= 5 then slot = "tap_5" end
        
        if slot and _state.ga[slot] then _actions.execute_single(_state.ga[slot]) end
        return
    end

    local dir = computeDir(dx, dy, mf)
    if not dir then return end

    if dir == "vert" then
        local goDown = dy > 0
        local slot = nil
        if     mf == 3 then slot = goDown and "swipe_3_down" or "swipe_3_up"
        elseif mf == 4 then slot = goDown and "swipe_4_down" or "swipe_4_up"
        elseif mf >= 5 then slot = goDown and "swipe_5_down" or "swipe_5_up" end
        
        if slot and _state.ga[slot] then _actions.execute_single(_state.ga[slot]) end
        return
    end

    if dir == "diag" then
        local diag_slot = slotForDir(mf, dir)
        if not diag_slot or _state.ga[diag_slot] == "none" then
            dir = (adx >= ady) and "horiz" or "vert"
        end
    end

    if dir == "vert" then
        local goDown = dy > 0
        local slot = nil
        if     mf == 3 then slot = goDown and "swipe_3_down" or "swipe_3_up"
        elseif mf == 4 then slot = goDown and "swipe_4_down" or "swipe_4_up"
        elseif mf >= 5 then slot = goDown and "swipe_5_down" or "swipe_5_up" end
        
        if slot and _state.ga[slot] then _actions.execute_single(_state.ga[slot]) end
        return
    end

    local slot = slotForDir(mf, dir)
    if not slot or _state.ga[slot] == "none" then return end
    
    if not _actions.is_scalable(_state.ga[slot]) then
        local sd = signedDist(gs.endPos)
        if math.abs(sd) >= SWIPE_MIN then _actions.execute_axis(_state.ga[slot], sd > 0) end
    end
end





-- =========================================
-- =========================================
-- ======= 4/ Touch Frame Processor ========
-- =========================================
-- =========================================

--- Evaluates a raw frame array of touches from the trackpad API.
--- @param touches table The raw touch data objects.
function M.process_frame(touches)
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
                        if not diag_slot or _state.ga[diag_slot] == "none" then
                            tentative = (math.abs(dx) >= math.abs(dy)) and "horiz" or "vert"
                        end
                    end
                    gs.lockedDir = tentative
                end

                if gs.lockedDir and gs.lockedDir ~= "vert" then
                    local slot = slotForDir(gs.maxFingers, gs.lockedDir)
                    if slot and _actions.is_scalable(_state.ga[slot]) then
                        local sd          = signedDist(pos)
                        local targetSteps = math.floor(sd / SCALE_DIV)
                        local diff        = targetSteps - gs.stepsCommitted
                        
                        if diff > 0 then
                            for _ = 1, diff  do _actions.execute_axis(_state.ga[slot], true)  end
                        elseif diff < 0 then
                            for _ = 1, -diff do _actions.execute_axis(_state.ga[slot], false) end
                        end
                        gs.stepsCommitted = targetSteps
                    end
                end
            end
        end
    end
end





-- =============================
-- =============================
-- ======= 5/ Module API =======
-- =============================
-- =============================

--- Mounts the shared state and dependencies.
--- @param core_state table The shared state object.
--- @param actions_mod table The actions registry module reference.
function M.init(core_state, actions_mod)
    _state   = core_state
    _actions = actions_mod
end

return M
