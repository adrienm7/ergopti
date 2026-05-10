--- modules/gestures/engine.lua

--- ==============================================================================
--- MODULE: Gestures Engine
--- DESCRIPTION:
--- Processes raw touch frames, computes vectors and thresholds, and triggers
--- the corresponding actions based on the global state configuration.
---
--- FEATURES & RATIONALE:
--- 1. Accurate Mathematical Engine: Evaluates vectors and dynamic scrolling offsets.
--- 2. Failsafe Architecture: Safely prevents system crashes during multi-touch processing.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "gestures.engine"

local _state   = nil
local _actions = nil





-- =========================================
-- =========================================
-- ======= 1/ Constants & Thresholds =======
-- =========================================
-- =========================================

local TAP_MAX_SEC    = 0.70   -- Capture slightly slow multi-finger taps
-- Minimum centroid displacement (Manhattan distance) to confirm a swipe on commit.
-- Intentionally larger than SWIPE_MIN so brief frémissements during a tap that
-- were enough to lock a direction during live tracking are not misclassified as
-- swipes when fingers lift.
local TAP_MAX_DELTA  = 8.0    -- Units below which a gesture is always treated as a tap on commit
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

--- Engages a local eventtap to swallow default macOS scrolling events.
local function startScrollBlock()
	if scrollBlocker then return end
	
	Logger.debug(LOG, "Enabling system scrolling block…")
	local evTypes = hs.eventtap.event.types
	scrollBlocker = hs.eventtap.new(
		{ evTypes.scrollWheel, evTypes.gesture },
		function() return true end
	)
	if scrollBlocker then
		pcall(function() scrollBlocker:start() end)
		Logger.info(LOG, "System scrolling block enabled.")
	end
end

--- Disengages the scroll blocking interceptor.
local function stopScrollBlock()
	if scrollBlocker and type(scrollBlocker.stop) == "function" then
		Logger.debug(LOG, "Disabling system scrolling block…")
		pcall(function() scrollBlocker:stop() end)
		scrollBlocker = nil
		Logger.info(LOG, "System scrolling block disabled.")
	end
end





-- =====================================
-- =====================================
-- ======= 3/ Math & State Logic =======
-- =====================================
-- =====================================

--- Resets the global tracking state for the current gesture.
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

--- Calculates the central point among all current fingers.
--- @param touches table Trackpad touch arrays.
--- @return table X and Y coordinate map.
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

--- Infers the action configuration slot ID given fingers count and direction.
--- @param mf number Number of fingers.
--- @param dir string Direction name (e.g., "horiz", "diag").
--- @return string|nil The slot string ID.
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

--- Derives a general direction from geometric distances.
--- @param dx number X delta.
--- @param dy number Y delta.
--- @param mf number Amount of fingers.
--- @return string|nil Direction string.
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

--- Computes continuous signed distance respecting the native Natural Scroll setting.
--- @param pos table Current position coordinates.
--- @return number Adjusted delta.
local function signedDist(pos)
	if not gs.startPos then return 0 end
	local dx = pos.x - gs.startPos.x
	return (_state.natural_scroll and -dx) or dx
end

--- Evaluates the gesture state upon release and issues the appropriate trigger.
--- @param now number Timestamp of the evaluation.
local function commitGesture(now)
	if not _state.enabled or not gs.startPos or not gs.endPos then return end

	local dx      = gs.endPos.x - gs.startPos.x
	local dy      = gs.endPos.y - gs.startPos.y
	local elapsed = now - (gs.startTime or now)
	local mf      = gs.maxFingers

	-- Tap detection: if no direction was ever locked during the gesture, no swipe
	-- motion was committed, so this is a tap (or an abandoned gesture).
	-- Also treat as a tap when lockedDir was set by a brief frémissement (delta
	-- below TAP_MAX_DELTA) — SWIPE_MIN is intentionally small for live tracking
	-- responsiveness, but a real swipe always produces a larger final displacement.
	local total_delta = math.abs(gs.endPos.x - gs.startPos.x) + math.abs(gs.endPos.y - gs.startPos.y)
	if gs.lockedDir == nil or total_delta < TAP_MAX_DELTA then
		if elapsed <= TAP_MAX_SEC then
			local slot = nil
			if     mf == 3 then slot = "tap_3"
			elseif mf == 4 then slot = "tap_4"
			elseif mf >= 5 then slot = "tap_5" end

			if slot and _state.ga[slot] then
				Logger.info(LOG, string.format("Tap validated on slot: %s (%.3fs, %d finger(s)).", slot, elapsed, mf))
				_actions.execute_single(_state.ga[slot])
			end
		end
		return
	end

	local dir = computeDir(dx, dy, mf)
	if not dir then return end

	if dir == "vert" then
		local goDown = dy < 0
		local slot = nil
		if     mf == 3 then slot = goDown and "swipe_3_down" or "swipe_3_up"
		elseif mf == 4 then slot = goDown and "swipe_4_down" or "swipe_4_up"
		elseif mf >= 5 then slot = goDown and "swipe_5_down" or "swipe_5_up" end
		
		if slot and _state.ga[slot] then
			Logger.info(LOG, string.format("Vertical swipe validated on slot: %s.", slot))
			_actions.execute_single(_state.ga[slot])
		end
		return
	end

	if dir == "diag" then
		local diag_slot = slotForDir(mf, dir)
		if not diag_slot or _state.ga[diag_slot] == "none" then
			dir = (math.abs(dx) >= math.abs(dy)) and "horiz" or "vert"
		end
	end

	if dir == "vert" then
		local goDown = dy < 0
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
		if math.abs(sd) >= SWIPE_MIN then
			Logger.info(LOG, string.format("Horizontal swipe validated on slot: %s.", slot))
			_actions.execute_axis(_state.ga[slot], sd > 0)
		end
	end
end





-- ========================================
-- ========================================
-- ======= 4/ Touch Frame Processor =======
-- ========================================
-- ========================================

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
		-- Signal the actions module that the gesture is over before resetting,
		-- so leftMouseUp events generated after the finger lift are not silenced
		-- beyond the gesture boundary.
		if _actions and type(_actions.set_gesture_in_progress) == "function" then
			pcall(_actions.set_gesture_in_progress, false)
		end
		resetGS()
		return
	end

	if n >= 3 then startScrollBlock() end

	if n >= 2 then
		local pos = avgPos(touches)
		if not gs.active then
			-- Signal the actions module that a new gesture has begun, so any
			-- leftMouseUp from trackpad contact does not cancel drag selection.
			if _actions and type(_actions.set_gesture_in_progress) == "function" then
				pcall(_actions.set_gesture_in_progress, true)
			end
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
			elseif n > gs.maxFingers then
				-- A new finger joined: reset the tap baseline so the centroid shift
				-- from the new finger doesn't count as movement
				gs.maxFingers = n
				gs.startPos   = pos
				gs.startTime  = now
				gs.lifting    = false
			elseif gs.lifting and n == gs.maxFingers then
				-- Full finger count restored after a partial lift without a clean n=0
				-- frame in between. This is a rapid successive tap: commit the current
				-- gesture immediately and start fresh, keeping the scroll blocker alive
				-- (fingers are still on the pad, tearing it down would add jitter).
				Logger.debug(LOG, "Rapid re-tap detected (%d finger(s)) — committing and restarting.", n)
				if gs.startPos then pcall(commitGesture, now) end
				gs.startTime      = now
				gs.startPos       = pos
				gs.endPos         = pos
				gs.lockedDir      = nil
				gs.stepsCommitted = 0
				gs.lifting        = false
				return
			end
			-- Freeze endPos once lifting starts: the centroid of fewer fingers
			-- drifts away from the full-contact centroid and would produce a false
			-- delta in commitGesture, breaking both tap and swipe detection.
			if not gs.lifting then
				gs.endPos = pos
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
					-- lockedDir stays nil until SWIPE_MIN is exceeded; commitGesture
					-- interprets lockedDir==nil as a tap candidate
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
	Logger.debug(LOG, "Initializing gestures engine dependencies…")
	_state   = core_state
	_actions = actions_mod
	Logger.info(LOG, "Gestures engine dependencies initialized.")
end

return M
