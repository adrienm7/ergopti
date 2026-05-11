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
local LIVE_AXIS_MIN               = 1.0   -- Minimum signed distance to trigger non-scalable horizontal actions live
local LIVE_REARM_SEC              = 0.08  -- Minimum delay between consecutive live axis triggers
local LIVE_REARM_REVERSE_FAST_SEC = 0.03  -- Faster rearm when user reverses direction strongly
local LIVE_REVERSE_FAST_MIN       = 1.5   -- Signed distance threshold to unlock fast reversal rearm

-- Candidate confirmation for noisy multi-finger spikes (e.g., 3→5 transient)
local FINGER_CONFIRM_FRAMES = 4
local FINGER_CONFIRM_MS     = 0.12

-- Candidate confirmation for noisy multi-finger drops (flickering)
-- We are more aggressive in keeping a higher finger count active.
local FINGER_DROP_CONFIRM_FRAMES = 8
local FINGER_DROP_CONFIRM_MS     = 0.20

local scrollBlocker  = nil
local isBlockingScroll = false
local gs             = {}





-- =====================================
-- =====================================
-- ======= 2/ Blocking Utilities =======
-- =====================================
-- =====================================

--- Engages a local eventtap to swallow default macOS scrolling events.
local function startScrollBlock()
	if not isBlockingScroll then
		isBlockingScroll = true
	end
end

--- Disengages the scroll blocking interceptor.
local function stopScrollBlock()
	if isBlockingScroll then
		isBlockingScroll = false
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
		liveAxisSign   = nil,
		lastLiveFire   = 0,
		lastN          = nil,
		-- Candidate spike confirmation state (joining)
		candidateFingers = nil,
		candidateSince   = nil,
		candidateFrames  = 0,
		-- Candidate drop confirmation state (leaving)
		tentativeLifting       = false,
		tentativeLiftingSince  = nil,
		tentativeLiftingFrames = 0,
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
--- @param dx number X delta.
--- @param dy number Y delta.
--- @return string|nil The slot string ID.
local function slotForDir(mf, dir, dx, dy)
	local prefix = "swipe_" .. tostring(mf) .. "_"
	if dir == "horiz" then
		return prefix .. (dx > 0 and "right" or "left")
	elseif dir == "vert" then
		return prefix .. (dy > 0 and "down" or "up")
	elseif dir == "diag" then
		if dx > 0 then
			return prefix .. (dy > 0 and "right_down" or "right_up")
		else
			return prefix .. (dy > 0 and "left_down" or "left_up")
		end
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

	-- Stricter angles for primary axes to avoid accidental diagonal lock
	-- Horizontal: 0-25 degrees (atan dy/dx)
	-- Vertical: 65-90 degrees
	-- Diagonal: 25-65 degrees
	local angle = math.deg(math.atan(ady, adx))

	if angle >= 65 then 
		return "vert"
	elseif angle <= 25 then 
		return "horiz"
	else
		-- Diagnostic: only lock diagonal if user really meant it (both axes moved significantly)
		local diagMin = (mf == 2) and DIAG_MIN_2 or (min * 1.5)
		if adx >= diagMin and ady >= diagMin then return "diag" end
		
		-- Fallback to dominant axis if not enough "diagonal-ness"
		return (adx >= ady) and "horiz" or "vert"
	end
end

--- Computes continuous signed distance (absolute trackpad coordinates).
--- @param pos table Current position coordinates.
--- @return number Adjusted delta.
local function signedDist(pos)
	if not gs.startPos then return 0 end
	return pos.x - gs.startPos.x
end

--- Compute signed distance along a given axis ('horiz'|'vert'|'diag').
--- @param pos table Position table.
--- @param axis string Axis name.
local function signedDistAxis(pos, axis)
	if not gs.startPos then return 0 end
	if axis == "horiz" then
		return pos.x - gs.startPos.x
	elseif axis == "vert" then
		return pos.y - gs.startPos.y
	else
		-- For diagonal, use Euclidean distance to represent true travel
		local dx = pos.x - gs.startPos.x
		local dy = pos.y - gs.startPos.y
		local dist = math.sqrt(dx*dx + dy*dy)
		local sign = (dx + dy > 0) and 1 or -1
		return sign * dist
	end
end

--- Executes an action by trying both single and axis variants.
--- @param action string The action ID.
--- @param sign number The direction sign (1 for next, -1 for prev).
local function triggerAction(action, sign)
	if not action or action == "none" then return end
	pcall(function() _actions.execute_single(action) end)
	pcall(function() _actions.execute_axis(action, sign > 0) end)
end

--- Triggers non-scalable horizontal actions during the gesture to reduce latency.
--- @param slot string|nil The action slot resolved from direction and finger count.
--- @param pos table Current centroid position.
--- @param now number Current timestamp.
local function triggerLiveAxisIfNeeded(slot, pos, now, axis)
	if not slot or not _state.ga[slot] or _state.ga[slot] == "none" then return end
	local action = _state.ga[slot]

	local mode = _state.modes[slot] or "x1"
	local sensitivity = _state.sensitivities[slot] or SCALE_DIV

	if mode == "incremental" then
		local sd = signedDistAxis(pos, axis)
		local targetSteps = math.floor(math.abs(sd) / sensitivity)
		local diff = targetSteps - gs.stepsCommitted

		if diff > 0 then
			for _ = 1, diff do
				triggerAction(action, sd)
			end
			gs.stepsCommitted = targetSteps
		elseif diff < 0 then
			-- Reversal detection
			gs.startPos = pos
			gs.endPos = pos
			gs.stepsCommitted = 0
		end
		return
	end

	-- x1 mode
	local sd = signedDistAxis(pos, axis)
	if math.abs(sd) < LIVE_AXIS_MIN then return end

	local sign = (sd > 0) and 1 or -1
	if gs.liveAxisSign == sign then return end

	local rearm_delay = LIVE_REARM_SEC
	if gs.liveAxisSign and sign ~= gs.liveAxisSign and math.abs(sd) >= LIVE_REVERSE_FAST_MIN then
		rearm_delay = LIVE_REARM_REVERSE_FAST_SEC
	end
	if gs.lastLiveFire and (now - gs.lastLiveFire) < rearm_delay then return end

	Logger.info(LOG, string.format("%s swipe live trigger on slot: %s (sign=%d).", axis, slot, sign))

	triggerAction(action, sign)

	-- Rebase after each live trigger so a quick direction reversal can fire promptly.
	gs.liveAxisSign = sign
	gs.lastLiveFire = now
	gs.startPos     = pos
	gs.endPos       = pos
	gs.stepsCommitted = 0
end

--- Evaluates the gesture state upon release and issues the appropriate trigger.
--- @param now number Timestamp of the evaluation.
local function commitGesture(now)
	if not _state.enabled or not gs.startPos or not gs.endPos then return end

	local dx      = gs.endPos.x - gs.startPos.x
	local dy      = gs.endPos.y - gs.startPos.y
	local elapsed = now - (gs.startTime or now)
	local mf      = gs.maxFingers

	-- Tap detection
	local total_delta = math.abs(gs.endPos.x - gs.startPos.x) + math.abs(gs.endPos.y - gs.startPos.y)
	if gs.lockedDir == nil or total_delta < TAP_MAX_DELTA then
		if elapsed <= TAP_MAX_SEC then
			local slot = nil
			if     mf == 2 then slot = "tap_2"
			elseif mf == 3 then slot = "tap_3"
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

	local slot = slotForDir(mf, dir, dx, dy)
	if not slot or _state.ga[slot] == "none" then return end

	local action = _state.ga[slot]
	if not action or action == "none" then return end

	local mode = _state.modes[slot] or "x1"
	local sensitivity = _state.sensitivities[slot] or SCALE_DIV

	if mode == "incremental" then
		local sd = signedDistAxis(gs.endPos, dir)
		local targetSteps = math.floor(math.abs(sd) / sensitivity)
		local diff = targetSteps - gs.stepsCommitted

		if diff > 0 then
			for _ = 1, diff do
				triggerAction(action, sd)
			end
		end
		gs.stepsCommitted = targetSteps
	else
		if gs.liveAxisSign ~= nil then return end
		local sd = signedDistAxis(gs.endPos, dir)
		if math.abs(sd) >= SWIPE_MIN then
			Logger.info(LOG, string.format("%s swipe validated on slot: %s.", dir, slot))
			triggerAction(action, sd)
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
	
	-- Signal that we are receiving data
	if not _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME and #touches > 0 then
		_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
	end

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
			gs.liveAxisSign   = nil
			gs.lastLiveFire   = 0
			
			gs.tentativeLifting       = false
			gs.tentativeLiftingSince  = nil
			gs.tentativeLiftingFrames = 0
		else
			-- StartPos Compensation: if finger count changed, the centroid (pos) jumps.
			-- We adjust startPos to maintain the same relative displacement,
			-- effectively absorbing the jump and preserving momentum/fluidity.
			if n ~= gs.lastN and gs.endPos then
				local jumpX = pos.x - gs.endPos.x
				local jumpY = pos.y - gs.endPos.y
				gs.startPos.x = gs.startPos.x + jumpX
				gs.startPos.y = gs.startPos.y + jumpY
				Logger.debug(LOG, string.format("Centroid jump compensated: n %d -> %d (jump: %.1f, %.1f).", gs.lastN or 0, n, jumpX, jumpY))
			end
			gs.lastN = n

			if n < gs.maxFingers then
				-- Flickering / Drop Debouncing: don't commit to "lifting" (end of gesture)
				-- too quickly. Fingers often lose contact for 50-150ms during swipes.
				if not gs.tentativeLifting then
					gs.tentativeLifting = true
					gs.tentativeLiftingSince = now
					gs.tentativeLiftingFrames = 1
				else
					gs.tentativeLiftingFrames = gs.tentativeLiftingFrames + 1
					local elapsed = now - gs.tentativeLiftingSince
					if gs.tentativeLiftingFrames >= FINGER_DROP_CONFIRM_FRAMES or elapsed >= FINGER_DROP_CONFIRM_MS then
						if not gs.lifting then
							Logger.info(LOG, string.format("Confirmed finger drop: %d -> %d (frames=%d, %.3fs).", gs.maxFingers, n, gs.tentativeLiftingFrames, elapsed))
						end
						gs.lifting = true
					end
				end
			elseif n > gs.maxFingers then
				-- Reset tentative lifting if finger count is restored
				gs.tentativeLifting = false

				-- A new finger joined. Accept single-finger joins immediately,
				-- but require confirmation for large spikes (e.g., 3→5) which are often transient.
				if n <= gs.maxFingers + 1 then
					gs.maxFingers = n
					gs.lifting    = false
					gs.candidateFingers = nil
					gs.candidateSince   = nil
					gs.candidateFrames  = 0
				else
					if gs.candidateFingers == n then
						gs.candidateFrames = gs.candidateFrames + 1
						local elapsed = now - (gs.candidateSince or now)
						if gs.candidateFrames >= FINGER_CONFIRM_FRAMES and elapsed >= FINGER_CONFIRM_MS then
							Logger.info(LOG, string.format("Confirmed multi-finger join: %d → %d (frames=%d, %.3fs).", gs.maxFingers, n, gs.candidateFrames, elapsed))
							gs.maxFingers = n
							gs.lifting    = false
							gs.candidateFingers = nil
							gs.candidateSince   = nil
							gs.candidateFrames  = 0
						else
							Logger.debug(LOG, string.format("Tentative finger spike persists (%d frames, %.3fs): %d → %d.", gs.candidateFrames, elapsed, gs.maxFingers, n))
						end
					else
						gs.candidateFingers = n
						gs.candidateSince   = now
						gs.candidateFrames  = 1
						Logger.warn(LOG, string.format("Observed spurious finger spike, awaiting confirmation: %d → %d.", gs.maxFingers, n))
					end
				end
			elseif n == gs.maxFingers then
				-- If we were tentatively lifting but the finger came back, cancel it.
				if gs.tentativeLifting then
					Logger.debug(LOG, "Finger flickering recovered (count restored to " .. tostring(n) .. ").")
					gs.tentativeLifting = false
					gs.tentativeLiftingSince = nil
					gs.tentativeLiftingFrames = 0
				end

				if gs.lifting then
					-- Rapid re-tap detected: commit current and restart
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
			end

			-- Update endPos and process movement ONLY if we are not in a tentative
			-- lift state (to avoid jitter from centroid shifts) and not confirmed lifting.
			if not gs.lifting and not gs.tentativeLifting then
				gs.endPos = pos

				if gs.lockedDir == nil then
					local dx = pos.x - gs.startPos.x
					local dy = pos.y - gs.startPos.y
					local tentative = computeDir(dx, dy, gs.maxFingers)
					gs.lockedDir = tentative
				end

				if gs.lockedDir then
					local axis = gs.lockedDir
					local dx = pos.x - gs.startPos.x
					local dy = pos.y - gs.startPos.y
					local slot = slotForDir(gs.maxFingers, axis, dx, dy)
					
					if slot and _state.ga[slot] and _state.ga[slot] ~= "none" then
						triggerLiveAxisIfNeeded(slot, pos, now, axis)
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
	
	-- Vital: Permanent event tap to block scroll events dynamically via flag.
	-- Dynamically calling :start() and :stop() triggers a 10s macOS Accessibility block.
	if not scrollBlocker then
		local evTypes = hs.eventtap.event.types
		scrollBlocker = hs.eventtap.new(
			{ evTypes.scrollWheel, evTypes.gesture },
			function() return isBlockingScroll end
		)
		if scrollBlocker then
			pcall(function() scrollBlocker:start() end)
		end
	end
	
	Logger.info(LOG, "Gestures engine dependencies initialized.")
end

return M
