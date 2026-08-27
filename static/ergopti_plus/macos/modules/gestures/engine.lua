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

local hs       = hs
local Logger   = require("infra.logger")
local Timings  = require("infra.timings")
local Geometry = require("modules.gestures.geometry")
local LOG      = "gestures.engine"

local _state      = nil
local _actions    = nil

-- Optional callback fired on every frame where at least one finger is touching
-- the trackpad. Registered by external modules (e.g. karabiner watcher) via
-- M.set_any_touch_hook(). Only one hook is supported at a time.
local _any_touch_hook = nil





-- =========================================
-- =========================================
-- ======= 1/ Constants & Thresholds =======
-- =========================================
-- =========================================

-- Timing constants come from the shared cross-driver registry
-- (_shared/modules/timings/constants.toml [gestures]) so AHK and macOS stay in sync;
-- the spatial thresholds below it are driver-specific and stay local.
local TAP_MAX_SEC    = Timings.sec("gestures", "tap_max_ms")   -- Capture slightly slow multi-finger taps
-- Minimum centroid displacement (Manhattan distance) to confirm a swipe on commit.
-- Intentionally larger than SWIPE_MIN so brief frémissements during a tap that
-- were enough to lock a direction during live tracking are not misclassified as
-- swipes when fingers lift.
local TAP_MAX_DELTA  = 8.0    -- Units below which a gesture is always treated as a tap on commit
-- Swipe-distance thresholds live in gestures/geometry.lua (single source of
-- truth); the commit path reads SWIPE_MIN back from there so the direction
-- classifier and the commit threshold check can never drift apart.
local SWIPE_MIN      = Geometry.SWIPE_MIN
local SCALE_DIV      = 3.5
local LIVE_AXIS_MIN               = 1.0   -- Minimum signed distance to trigger non-scalable horizontal actions live
local LIVE_REARM_SEC              = Timings.sec("gestures", "live_rearm_ms")          -- Minimum delay between consecutive live axis triggers
local LIVE_REARM_REVERSE_FAST_SEC = Timings.sec("gestures", "live_rearm_reverse_ms")  -- Faster rearm when user reverses direction strongly
local LIVE_REVERSE_FAST_MIN       = 1.5   -- Signed distance threshold to unlock fast reversal rearm

-- Candidate confirmation for noisy multi-finger spikes (e.g., 3→5 transient).
-- The MS threshold used to be 0.12 s but logs showed real 4-finger swipes
-- being misclassified: the user held 4 fingers for ~100 ms then lifted one
-- to end the gesture, so the candidate=4 never confirmed and we fell back
-- to maxFingers=3 — producing 9 word_prev fires instead of 1 space_prev.
-- 50 ms is still long enough to filter out genuine palm-spike noise (which
-- typically lasts <30 ms / 1-2 frames at 60 Hz).
local FINGER_CONFIRM_FRAMES = 4
local FINGER_CONFIRM_SEC     = Timings.sec("gestures", "finger_confirm_ms")

-- Candidate confirmation for noisy multi-finger drops (flickering)
-- We are more aggressive in keeping a higher finger count active.
local FINGER_DROP_CONFIRM_FRAMES = 8
local FINGER_DROP_CONFIRM_SEC     = Timings.sec("gestures", "finger_drop_confirm_ms")

-- Finger count stability gate before allowing ANY live trigger.
-- Without this, a 4-finger swipe whose first frames register only 2-3 contacts
-- fires the WRONG action (e.g., swipe_2_left=arrow_up) before the engine
-- upgrades maxFingers to 4. Holding live fires for a short grace period gives
-- the rest of the fingers time to land and the centroid time to stabilise.
local FINGER_COUNT_STABLE_SEC = Timings.sec("gestures", "finger_count_stable_ms")   -- 60 ms — fast enough to feel instant, slow enough to absorb staggered contact

-- Minimum time a peak finger count must have been seen before we treat it as
-- the user's true intent (used to override a lower maxFingers at commit time
-- when fingers staggered down before the candidate could confirm).
local PEAK_FINGERS_CONFIRM_MS = 0.05

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

-- All directional slot suffixes a finger count can resolve to.
local SLOT_DIRS_ALL   = { "left", "right", "up", "down", "left_up", "right_up", "left_down", "right_down" }
local SLOT_DIRS_HORIZ = { "left", "right" }
local SLOT_DIRS_VERT  = { "up", "down" }
local SLOT_DIRS_DIAG  = { "left_up", "right_up", "left_down", "right_down" }

--- Returns true when every relevant swipe slot for the given finger count is
--- bound to "none" on the supplied axis. When axis is nil (gesture has not
--- locked a direction yet), the tap slot is also required to be "none" — we
--- don't yet know whether the user is tapping or swiping.
---
--- When this returns true, no live or commit fire can ever target this finger
--- count on this axis, so the engine is free to shortcut the spike-confirmation
--- period: there is literally nothing it could fire wrong, so being tolerant
--- about an N→M finger upgrade is risk-free.
---
--- The axis-aware variant matters because, in practice, users disable 2-finger
--- HORIZONTAL events (which collide with macOS native swipes) but keep
--- 2-finger vertical or diagonal events bound. With this helper, a horizontal
--- 4-finger swipe whose first contacts land staggered can promote to 4 fingers
--- the moment lockedDir resolves to "horiz", without waiting 120 ms for the
--- candidate confirmation that would otherwise be needed.
--- @param mf number Finger count to test.
--- @param axis string|nil "horiz", "vert", "diag", or nil (check all).
--- @return boolean
local function finger_count_is_inert(mf, axis)
	if not _state or not _state.ga then return false end
	local fc = tostring(mf)
	local dirs
	if     axis == "horiz" then dirs = SLOT_DIRS_HORIZ
	elseif axis == "vert"  then dirs = SLOT_DIRS_VERT
	elseif axis == "diag"  then dirs = SLOT_DIRS_DIAG
	else                        dirs = SLOT_DIRS_ALL end
	for _, dir in ipairs(dirs) do
		local action = _state.ga["swipe_" .. fc .. "_" .. dir]
		if action and action ~= "none" then return false end
	end
	-- Tap only matters when direction is not yet known — a moving gesture
	-- past lockedDir cannot become a tap.
	if axis == nil then
		local tap_action = _state.ga["tap_" .. fc]
		if tap_action and tap_action ~= "none" then return false end
	end
	return true
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
		liveAxisSlot   = nil,  -- Slot of the most recent live fire (separate from sign — different slots are unrelated)
		hadLiveFire    = false, -- Sticky flag: true once any live fire fired; NOT cleared on rebase (unlike liveAxisSign)
		lastLiveFire   = 0,
		lastFirePos    = nil,  -- Position of the most recent incremental fire (for reversal detection)
		lastN          = nil,
		fingerCountChangedAt = 0,  -- Timestamp of the last finger count change (for stability gate)
		-- Peak finger count: highest n observed during the gesture (regardless
		-- of whether the candidate-confirmation path ever promoted maxFingers).
		-- Used at commit time to recover the user's true intent when a real
		-- 4-finger swipe ends with one finger lifting before the others.
		peakN          = 0,
		peakNFirstSeen = nil,
		-- Last frame the peak was still observed. Together with peakNFirstSeen this
		-- gives the span the peak was actually HELD, which is what the commit-time
		-- override tests — a single-frame spike must not win the commit slot.
		peakNLastSeen  = nil,
		-- Candidate spike confirmation state (joining)
		candidateFingers = nil,
		candidateSince   = nil,
		candidateFrames  = 0,
		lateUpgradeRejected = false,
		-- Candidate drop confirmation state (leaving)
		tentativeLifting       = false,
		tentativeLiftingSince  = nil,
		tentativeLiftingFrames = 0,
	}
end
resetGS()

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
local function triggerAction(action, sign, slot)
	if not action or action == "none" then return end
	pcall(function() _actions.execute_single(action, slot) end)
	pcall(function() _actions.execute_axis(action, sign > 0) end)
end

--- Triggers non-scalable horizontal actions during the gesture to reduce latency.
--- @param slot string|nil The action slot resolved from direction and finger count.
--- @param pos table Current centroid position.
--- @param now number Current timestamp.
local function triggerLiveAxisIfNeeded(slot, pos, now, axis)
	-- Do not fire live actions while gestures are disabled or pause-suspended. The
	-- commit path gates on both axes; this live-fire path must match it, otherwise
	-- a swipe performed while the script is paused still executes real system
	-- actions (word_next, tab_next, …). Mirrors AHK native Suspend.
	if not _state.enabled or _state.suspended then return end
	if not slot or not _state.ga[slot] or _state.ga[slot] == "none" then return end
	local action = _state.ga[slot]

	-- Pending finger-spike confirmation gate. While the engine is still
	-- confirming whether the finger count just jumped (e.g., 2→4 takes up to
	-- FINGER_CONFIRM_SEC to confirm), maxFingers reflects the OLD count. Firing
	-- a live trigger here would target the wrong slot — typically swipe_2_<dir>
	-- instead of swipe_4_<dir> for a 4-finger swipe whose first contacts land
	-- staggered. Hold all live fires until the candidate resolves.
	if gs.candidateFingers ~= nil then
		Logger.debug(LOG, "live blocked: finger spike confirmation pending (candidate=%d, current=%d) slot=%s",
			gs.candidateFingers, gs.maxFingers, slot)
		return
	end

	-- Finger-count stability gate. After a confirmed count change, give the
	-- centroid a brief moment to stabilise before firing — quick single-finger
	-- joins (2→3, 3→4) skip the candidate path above so this catches them too.
	local stable_elapsed = now - (gs.fingerCountChangedAt or 0)
	if stable_elapsed < FINGER_COUNT_STABLE_SEC then
		Logger.debug(LOG, "live blocked: finger count unstable (%.0fms since change, need %.0fms) slot=%s",
			stable_elapsed * 1000, FINGER_COUNT_STABLE_SEC * 1000, slot)
		return
	end

	local mode = _state.modes[slot] or "x1"
	local sensitivity = _state.sensitivities[slot] or SCALE_DIV

	if mode == "incremental" then
		-- Early reversal detection: if the user has fired in one direction and now
		-- moves at least LIVE_AXIS_MIN units back FROM THE LAST FIRE POSITION in
		-- the opposite direction, rebase immediately instead of waiting for them
		-- to come all the way back through the original origin. This makes reverse
		-- swipes feel as responsive as fresh ones.
		if gs.liveAxisSign and gs.lastFirePos then
			local local_delta
			if axis == "horiz" then
				local_delta = pos.x - gs.lastFirePos.x
			elseif axis == "vert" then
				local_delta = pos.y - gs.lastFirePos.y
			else
				-- Diagonal: project movement along the 45° diagonal signed direction
				-- (same convention as signedDistAxis) so reversal detection is axis-aware.
				local ddx = pos.x - gs.lastFirePos.x
				local ddy = pos.y - gs.lastFirePos.y
				local mag = math.sqrt(ddx*ddx + ddy*ddy)
				local_delta = ((ddx + ddy > 0) and 1 or -1) * mag
			end
			local local_sign = (local_delta > 0) and 1 or (local_delta < 0 and -1 or 0)
			if local_sign ~= 0 and local_sign ~= gs.liveAxisSign and math.abs(local_delta) >= LIVE_AXIS_MIN then
				Logger.info(LOG, string.format("INCREMENTAL REVERSAL DETECTED slot=%s axis=%s local_delta=%.2f prevSign=%d newSign=%d — rebasing startPos to (%.1f,%.1f)",
					slot, axis, local_delta, gs.liveAxisSign, local_sign, pos.x, pos.y))
				-- Clone pos: startPos and endPos must not alias the same table; the
				-- centroid-jump compensator mutates gs.startPos.x/y in place, which
				-- would corrupt gs.endPos if they point to the same table
				-- (gesture-engine-table-mutation).
				gs.startPos       = {x = pos.x, y = pos.y}
				gs.endPos         = {x = pos.x, y = pos.y}
				gs.stepsCommitted = 0
				gs.liveAxisSign   = nil
				gs.lastFirePos    = nil
				return
			end
		end

		local sd = signedDistAxis(pos, axis)
		local targetSteps = math.floor(math.abs(sd) / sensitivity)
		local diff = targetSteps - gs.stepsCommitted

		if diff > 0 then
			Logger.info(LOG, string.format("INCREMENTAL FIRE slot=%s axis=%s sd=%.2f sensitivity=%.2f targetSteps=%d prevSteps=%d diff=%d action=%s",
				slot, axis, sd, sensitivity, targetSteps, gs.stepsCommitted, diff, tostring(action)))
			for _ = 1, diff do
				triggerAction(action, sd, slot)
			end
			gs.stepsCommitted = targetSteps
			gs.liveAxisSign   = (sd > 0) and 1 or -1
			gs.hadLiveFire    = true
			gs.lastFirePos    = pos
			gs.lastLiveFire   = now
		elseif diff < 0 then
			-- Fallback rebase: still kept as a safety net if reversal slipped past
			-- the early detector above (e.g., sudden centroid jump from finger count change).
			Logger.info(LOG, string.format("INCREMENTAL FALLBACK REBASE slot=%s axis=%s sd=%.2f targetSteps=%d prevSteps=%d diff=%d",
				slot, axis, sd, targetSteps, gs.stepsCommitted, diff))
			gs.startPos       = {x = pos.x, y = pos.y}
			gs.endPos         = {x = pos.x, y = pos.y}
			gs.stepsCommitted = 0
			gs.liveAxisSign   = nil
			gs.lastFirePos    = nil
		end
		return
	end

	-- x1 mode
	local sd = signedDistAxis(pos, axis)
	if math.abs(sd) < LIVE_AXIS_MIN then return end

	local sign = (sd > 0) and 1 or -1
	-- Block only if the EXACT same slot+sign already fired live. When the slot
	-- changes mid-gesture (e.g., user goes from 2 fingers to 4, swipe_2_left →
	-- swipe_4_left), the new slot is a fresh action and must be allowed to fire.
	if gs.liveAxisSign == sign and gs.liveAxisSlot == slot then
		Logger.debug(LOG, "x1 live blocked: same slot+sign as previous (slot=%s sign=%d sd=%.2f)", slot, sign, sd)
		return
	end

	local rearm_delay = LIVE_REARM_SEC
	local is_reversal = (gs.liveAxisSign and sign ~= gs.liveAxisSign)
	if is_reversal and math.abs(sd) >= LIVE_REVERSE_FAST_MIN then
		rearm_delay = LIVE_REARM_REVERSE_FAST_SEC
	end
	if gs.lastLiveFire and (now - gs.lastLiveFire) < rearm_delay then
		Logger.debug(LOG, "x1 live blocked: rearm delay (slot=%s elapsed=%.3fs need=%.3fs reversal=%s)",
			slot, now - gs.lastLiveFire, rearm_delay, tostring(is_reversal))
		return
	end

	Logger.info(LOG, "x1 LIVE FIRE slot=%s axis=%s sign=%d sd=%.2f reversal=%s prevSlot=%s action=%s",
		slot, axis, sign, sd, tostring(is_reversal), tostring(gs.liveAxisSlot), tostring(action))

	triggerAction(action, sign, slot)

	-- Rebase after each live trigger so a quick direction reversal can fire promptly.
	gs.liveAxisSign = sign
	gs.liveAxisSlot = slot
	gs.hadLiveFire  = true
	gs.lastLiveFire = now
	gs.startPos     = {x = pos.x, y = pos.y}
	gs.endPos       = {x = pos.x, y = pos.y}
	gs.stepsCommitted = 0
end

--- Evaluates the gesture state upon release and issues the appropriate trigger.
--- @param now number Timestamp of the evaluation.
local function commitGesture(now)
	-- ENTRY DIAGNOSTIC — full state dump every commit
	local sp = gs.startPos and string.format("(%.1f,%.1f)", gs.startPos.x, gs.startPos.y) or "nil"
	local ep = gs.endPos   and string.format("(%.1f,%.1f)", gs.endPos.x,   gs.endPos.y)   or "nil"
	Logger.info(LOG, "commitGesture ENTRY: enabled=%s maxFingers=%d startPos=%s endPos=%s lockedDir=%s liveAxisSign=%s stepsCommitted=%d elapsed=%.3fs",
		tostring(_state.enabled), gs.maxFingers, sp, ep, tostring(gs.lockedDir),
		tostring(gs.liveAxisSign), gs.stepsCommitted, now - (gs.startTime or now))

	if not _state.enabled or _state.suspended or not gs.startPos or not gs.endPos then
		Logger.debug(LOG, "commitGesture: SKIP (enabled=%s suspended=%s startPos=%s endPos=%s)",
			tostring(_state.enabled), tostring(_state.suspended), sp, ep)
		return
	end

	local dx      = gs.endPos.x - gs.startPos.x
	local dy      = gs.endPos.y - gs.startPos.y
	local elapsed = now - (gs.startTime or now)
	-- Prefer the peak finger count over maxFingers when the peak was sustained
	-- long enough. This recovers user intent when a 4-finger swipe ends with
	-- one finger lifting early (n drops from 4 to 3 before the candidate path
	-- can confirm 4 as the new maxFingers). Without this, the commit would
	-- fire the 3-finger action instead of the 4-finger one.
	local mf = gs.maxFingers
	-- HELD duration, not wall time since the peak was first seen. Measuring from
	-- `now` meant a single-frame spike qualified as "sustained" purely because the
	-- gesture continued afterwards: touch 4 fingers for one frame, hold 3 for
	-- 200 ms, and the commit fired the 4-finger action. Only the span the peak was
	-- actually observed over expresses intent.
	local peak_elapsed = (gs.peakNLastSeen or gs.peakNFirstSeen or now) - (gs.peakNFirstSeen or now)
	if gs.peakN and gs.peakN > mf and peak_elapsed >= PEAK_FINGERS_CONFIRM_MS then
		Logger.info(LOG, "commitGesture: PEAK OVERRIDE — using peakN=%d (held %.3fs) over maxFingers=%d",
			gs.peakN, peak_elapsed, mf)
		mf = gs.peakN
	end

	-- Tap detection
	-- Critical guard: a gesture that already fired a live action is by
	-- definition NOT a tap. After a live fire we rebase startPos to the
	-- centroid at fire time, so the residual dx/dy at lift-off is naturally
	-- small (< TAP_MAX_DELTA). Without this guard the engine would classify
	-- the lift residue as a tap and fire the tap action ON TOP OF the
	-- legitimate swipe action — e.g., a 4-finger down swipe firing
	-- app_expose during the swipe, then app_window_previous on lift.
	-- Use the sticky hadLiveFire flag (not liveAxisSign) so a direction reversal
	-- that clears liveAxisSign via rebase does not hide the prior live fire from
	-- the tap guard below — without this, the rebase-then-lift path fires a
	-- spurious tap even though the gesture already triggered an action.
	local had_live_fire = gs.hadLiveFire
	local total_delta = math.abs(dx) + math.abs(dy)
	Logger.debug(LOG, "commitGesture: dx=%.2f dy=%.2f total_delta=%.2f TAP_MAX_DELTA=%.2f TAP_MAX_SEC=%.2f had_live_fire=%s",
		dx, dy, total_delta, TAP_MAX_DELTA, TAP_MAX_SEC, tostring(had_live_fire))
	if not had_live_fire and total_delta < TAP_MAX_DELTA then
		Logger.debug(LOG, "commitGesture: classified as TAP candidate (lockedDir=%s, total_delta=%.2f < %.2f)",
			tostring(gs.lockedDir), total_delta, TAP_MAX_DELTA)
		if elapsed <= TAP_MAX_SEC then
			local slot = nil
			if     mf == 2 then slot = "tap_2"
			elseif mf == 3 then slot = "tap_3"
			elseif mf == 4 then slot = "tap_4"
			elseif mf >= 5 then slot = "tap_5" end

			if slot and _state.ga[slot] then
				Logger.info(LOG, "TAP FIRE slot=%s action=%s elapsed=%.3fs fingers=%d",
					slot, tostring(_state.ga[slot]), elapsed, mf)
				_actions.execute_single(_state.ga[slot], slot)
			else
				Logger.debug(LOG, "commitGesture: tap not fired (slot=%s, action=%s)",
					tostring(slot), tostring(slot and _state.ga[slot]))
			end
		else
			Logger.debug(LOG, "commitGesture: tap too slow (elapsed=%.3fs > TAP_MAX_SEC=%.2fs)", elapsed, TAP_MAX_SEC)
		end
		return
	end
	if had_live_fire and total_delta < TAP_MAX_DELTA then
		Logger.debug(LOG, "commitGesture: tap-zone hit AFTER a live fire — refusing to fire spurious tap (residual=lift-off drift)")
		return
	end

	local dir = Geometry.computeDir(dx, dy, mf)
	Logger.debug(LOG, "commitGesture: computeDir → %s (lockedDir=%s)", tostring(dir), tostring(gs.lockedDir))
	if not dir then
		Logger.debug(LOG, "commitGesture: no direction computed — return")
		return
	end

	-- Enforce gesture axis lock at commit time. The post-last-live-fire centroid
	-- drift during finger lift-off can produce a dx/dy that points to a DIFFERENT
	-- axis than the gesture was locked on (e.g., a vertical swipe with a tail
	-- of horizontal drift). Without this guard, we would fire a spurious third
	-- action on the wrong axis on top of the legitimate live fires.
	if gs.lockedDir and gs.lockedDir ~= dir then
		Logger.debug(LOG, "commitGesture: dir=%s does not match gesture lockedDir=%s — skipping commit",
			dir, gs.lockedDir)
		return
	end

	local slot = Geometry.slotForDir(mf, dir, dx, dy)
	Logger.debug(LOG, "commitGesture: slotForDir(%d, %s, %.2f, %.2f) → %s", mf, dir, dx, dy, tostring(slot))
	if not slot or _state.ga[slot] == "none" then
		Logger.debug(LOG, "commitGesture: slot=%s action=%s — skip",
			tostring(slot), tostring(slot and _state.ga[slot]))
		return
	end

	local action = _state.ga[slot]
	if not action or action == "none" then
		Logger.debug(LOG, "commitGesture: action missing for slot %s — skip", slot)
		return
	end

	local mode = _state.modes[slot] or "x1"
	local sensitivity = _state.sensitivities[slot] or SCALE_DIV
	Logger.debug(LOG, "commitGesture: slot=%s action=%s mode=%s sensitivity=%.2f", slot, action, mode, sensitivity)

	if mode == "incremental" then
		local sd = signedDistAxis(gs.endPos, dir)
		local targetSteps = math.floor(math.abs(sd) / sensitivity)
		local diff = targetSteps - gs.stepsCommitted
		Logger.info(LOG, "commitGesture INCREMENTAL: sd=%.2f targetSteps=%d prevSteps=%d diff=%d",
			sd, targetSteps, gs.stepsCommitted, diff)

		if diff > 0 then
			Logger.info(LOG, "COMMIT INCREMENTAL FIRE slot=%s action=%s diff=%d", slot, action, diff)
			for _ = 1, diff do
				triggerAction(action, sd, slot)
			end
		end
		gs.stepsCommitted = targetSteps
	else
		-- x1 mode
		local sd = signedDistAxis(gs.endPos, dir)
		local sign = (sd > 0) and 1 or (sd < 0 and -1 or 0)
		Logger.info(LOG, "commitGesture x1: dir=%s slot=%s sd=%.2f sign=%d prevLiveSlot=%s prevLiveSign=%s SWIPE_MIN=%.2f",
			dir, slot, sd, sign, tostring(gs.liveAxisSlot), tostring(gs.liveAxisSign), SWIPE_MIN)
		-- Block double-fire only when commit and the previous live fire targeted the
		-- EXACT same slot+sign. Two cases that must still fire at commit:
		--   1. Reversal: user swiped left (live fired swipe_X_left), then reversed to
		--      right and lifted before live re-armed — sign differs, must fire right.
		--   2. Finger transition: live fired swipe_2_left during a staggered 4-finger
		--      landing, then user actually swiped 4 fingers — slot differs (swipe_4_left
		--      vs swipe_2_left), so the 4-finger action must fire at commit.
		if gs.liveAxisSign == sign and gs.liveAxisSlot == slot then
			Logger.warn(LOG, "commitGesture x1: BLOCKED — same slot+sign as previous live fire (slot=%s sign=%d)",
				slot, sign)
			return
		end
		if math.abs(sd) >= SWIPE_MIN then
			Logger.info(LOG, "COMMIT X1 FIRE slot=%s action=%s sign=%d sd=%.2f (prevLiveSlot=%s prevLiveSign=%s)",
				slot, action, sign, sd, tostring(gs.liveAxisSlot), tostring(gs.liveAxisSign))
			triggerAction(action, sd, slot)
		else
			Logger.warn(LOG, "commitGesture x1: BELOW THRESHOLD (|sd|=%.2f < SWIPE_MIN=%.2f) — not firing slot %s",
				math.abs(sd), SWIPE_MIN, slot)
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

	if #touches > 0 and _any_touch_hook then
		pcall(_any_touch_hook)
	end

	local n   = #touches
	local now = hs.timer.secondsSinceEpoch()

	if n == 0 then
		stopScrollBlock()
		if gs.active and gs.startPos and gs.endPos then
			Logger.info(LOG, "process_frame: n=0 → fingers lifted, calling commitGesture (was active)")
			pcall(commitGesture, now)
		elseif gs.active then
			Logger.debug(LOG, "process_frame: n=0 but startPos/endPos missing (startPos=%s, endPos=%s)",
				tostring(gs.startPos), tostring(gs.endPos))
		end
		resetGS()
		return
	end

	-- Once a two-finger gesture has locked its direction, it belongs to native
	-- scrolling for the rest of that contact sequence. Some touch devices report
	-- a ghost third contact for longer than the generic spike-confirmation window;
	-- promoting that late count executes a configured three-finger action and
	-- swallows the user's scroll. A real three-finger gesture still starts at
	-- three contacts or joins before the direction lock is established.
	local late_two_finger_upgrade = n > 2
		and gs.active
		and gs.maxFingers == 2
		and gs.lockedDir ~= nil
	if late_two_finger_upgrade then
		stopScrollBlock()
		if not gs.lateUpgradeRejected then
			Logger.debug(LOG,
				"Late finger-count upgrade ignored for locked 2-finger scroll: 2 -> %d.", n)
			gs.lateUpgradeRejected = true
		end
		return
	elseif gs.lateUpgradeRejected then
		Logger.debug(LOG, "Locked 2-finger scroll returned to its accepted contact count.")
		gs.lateUpgradeRejected = false
	end

	if n >= 3 and _state and _state.enabled and not _state.suspended then startScrollBlock() end

	if n >= 2 then
		local pos = Geometry.avgPos(touches)
		if not gs.active then
			Logger.info(LOG, "GESTURE START: fingers=%d pos=(%.1f,%.1f) ts=%.3f", n, pos.x, pos.y, now)
			gs.active         = true
			gs.startTime      = now
			gs.startPos       = {x = pos.x, y = pos.y}
			gs.endPos         = {x = pos.x, y = pos.y}
			gs.maxFingers     = n
			gs.lastN          = n
			gs.stepsCommitted = 0
			gs.lifting        = false
			gs.liveAxisSign   = nil
			gs.liveAxisSlot   = nil
			gs.hadLiveFire    = false
			gs.lastLiveFire   = 0
			gs.lastFirePos    = nil
			gs.fingerCountChangedAt = now
			gs.peakN          = n
			gs.peakNFirstSeen = now
			gs.peakNLastSeen  = now

			gs.tentativeLifting       = false
			gs.tentativeLiftingSince  = nil
			gs.tentativeLiftingFrames = 0
		else
			-- Track the peak finger count seen so far. This recovers user
			-- intent at commit time when a real 4-finger swipe ends with one
			-- finger lifting before the others, draining maxFingers below the
			-- gesture's actual peak before the candidate path can confirm.
			if n > (gs.peakN or 0) then
				gs.peakN = n
				gs.peakNFirstSeen = now
				gs.peakNLastSeen  = now
			elseif n == gs.peakN then
				-- Extend the held span only while the peak is CONTINUOUSLY on the
				-- trackpad. gs.lastN still holds the previous frame's count here, so
				-- a mismatch means the peak was dropped and re-attained: two
				-- momentary spikes with a dip between them, which the old
				-- unconditional extension measured as one long hold and let the
				-- override promote. Restarting the span on re-attainment means each
				-- spike is judged on the time it was actually held.
				if gs.lastN == gs.peakN then
					gs.peakNLastSeen = now
				else
					gs.peakNFirstSeen = now
					gs.peakNLastSeen  = now
				end
			end

			-- StartPos Compensation: if finger count changed, the centroid (pos) jumps.
			-- We adjust startPos to maintain the same relative displacement,
			-- effectively absorbing the jump and preserving momentum/fluidity.
			if n ~= gs.lastN and gs.endPos then
				local jumpX = pos.x - gs.endPos.x
				local jumpY = pos.y - gs.endPos.y
				gs.startPos.x = gs.startPos.x + jumpX
				gs.startPos.y = gs.startPos.y + jumpY
				-- lastFirePos is used by the reversal detector (local_delta = pos − lastFirePos).
				-- Without this compensation the detector sees the full centroid jump as
				-- movement in the opposite direction and fires a spurious reversal.
				if gs.lastFirePos then
					gs.lastFirePos = {x = gs.lastFirePos.x + jumpX, y = gs.lastFirePos.y + jumpY}
				end
				Logger.debug(LOG, string.format("Centroid jump compensated: n %d -> %d (jump: %.1f, %.1f).", gs.lastN or 0, n, jumpX, jumpY))
			end
			gs.lastN = n

			-- Retire a pending spike candidate the moment the observed count stops
			-- matching it: the spike did not persist, so there is nothing left to
			-- confirm. The candidate was only ever cleared inside the n > maxFingers
			-- branch, so once the count fell back the clearing path was unreachable and
			-- the candidate stayed armed until finger-lift — keeping the live-fire gate
			-- in triggerLiveAxisIfNeeded closed and silently swallowing the rest of the
			-- gesture. Placed here so it covers all three count branches at once.
			if gs.candidateFingers ~= nil and n ~= gs.candidateFingers then
				Logger.debug(LOG, string.format("Finger spike candidate retired (candidate=%d, current=%d).",
					gs.candidateFingers, n))
				gs.candidateFingers = nil
				gs.candidateSince   = nil
				gs.candidateFrames  = 0
			end

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
					if gs.tentativeLiftingFrames >= FINGER_DROP_CONFIRM_FRAMES or elapsed >= FINGER_DROP_CONFIRM_SEC then
						if not gs.lifting then
							Logger.info(LOG, string.format("Confirmed finger drop: %d -> %d (frames=%d, %.3fs).", gs.maxFingers, n, gs.tentativeLiftingFrames, elapsed))
						end
						if n >= 2 then
							-- A confirmed drop to a still-multi-finger count is a finger-count
							-- CHANGE, not the end of the gesture. maxFingers is otherwise never
							-- demoted, so n stayed permanently below it: no branch could clear
							-- lifting again and the whole remainder of the swipe was dropped,
							-- then mis-committed as tap_(N+1). Same reset quintet the fast-path
							-- join branch uses below.
							gs.maxFingers           = n
							gs.lifting              = false
							gs.tentativeLifting     = false
							gs.fingerCountChangedAt = now
							gs.candidateFingers     = nil
							gs.candidateSince       = nil
							gs.candidateFrames      = 0
							-- Rebase the peak on the confirmed count as well. Demoting
							-- maxFingers alone left peakN holding the count the user just
							-- abandoned, and the peak override at commit re-promoted it —
							-- so a confirmed 4→3 change still fired the 4-finger action,
							-- the exact outcome this demotion exists to prevent. The peak
							-- is meant to recover intent from a finger lifting a frame
							-- early, not to outrank a change we spent frames confirming.
							gs.peakN          = n
							gs.peakNFirstSeen = now
							gs.peakNLastSeen  = now
						else
							gs.lifting = true
						end
					end
				end
			elseif n > gs.maxFingers then
				-- Reset tentative lifting if finger count is restored
				gs.tentativeLifting = false

				-- A new finger joined. Accept single-finger joins immediately,
				-- but require confirmation for large spikes (e.g., 3→5) which are often transient.
				-- Fast-path: accept the new count immediately when either it is
				-- only one above the current count (normal sequential landing) OR
				-- the CURRENT finger count is inert on the locked axis (no
				-- configured actions can fire). If nothing was going to fire at
				-- maxFingers anyway, there is no false-positive to protect against
				-- — being tolerant is free. Using the locked axis (rather than
				-- "all directions") means a horizontal swipe benefits from
				-- 2-finger HORIZONTAL being "none" even if 2-finger vertical or
				-- diagonal is bound.
				--
				-- Exception: when a direction is already locked AND the INCOMING
				-- finger count has active actions on that axis, skip the fast-path and
				-- require candidate confirmation. Locked 2-finger gestures are handled
				-- earlier and never reach this branch because their ownership stays
				-- with native scrolling for the complete contact sequence.
				local inert = finger_count_is_inert(gs.maxFingers, gs.lockedDir)
				local new_count_active_on_locked_axis = gs.lockedDir ~= nil
					and not finger_count_is_inert(n, gs.lockedDir)
				local use_fast_path = (n <= gs.maxFingers + 1 or inert)
					and not new_count_active_on_locked_axis
				if use_fast_path then
					Logger.info(LOG, string.format("Finger join (fast-path): %d → %d (inert_at_%d_on_%s=%s)",
						gs.maxFingers, n, gs.maxFingers, tostring(gs.lockedDir), tostring(inert)))
					gs.maxFingers = n
					gs.lifting    = false
					gs.fingerCountChangedAt = now
					gs.candidateFingers = nil
					gs.candidateSince   = nil
					gs.candidateFrames  = 0
				else
					if gs.candidateFingers == n then
						gs.candidateFrames = gs.candidateFrames + 1
						local elapsed = now - (gs.candidateSince or now)
						if gs.candidateFrames >= FINGER_CONFIRM_FRAMES and elapsed >= FINGER_CONFIRM_SEC then
							Logger.info(LOG, string.format("Confirmed multi-finger join: %d → %d (frames=%d, %.3fs).", gs.maxFingers, n, gs.candidateFrames, elapsed))
							gs.maxFingers = n
							gs.lifting    = false
							-- The candidate-confirmation period already enforced stability:
							-- the user has held this finger count for >= FINGER_CONFIRM_SEC.
							-- Zero out fingerCountChangedAt so the live-fire stability gate
							-- does not impose an ADDITIONAL 60 ms wait on top of that.
							gs.fingerCountChangedAt = 0
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
						Logger.debug(LOG, string.format("Observed spurious finger spike, awaiting confirmation: %d → %d.", gs.maxFingers, n))
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
					gs.startPos       = {x = pos.x, y = pos.y}
					gs.endPos         = {x = pos.x, y = pos.y}
					gs.lockedDir      = nil
					gs.stepsCommitted = 0
					gs.lifting        = false
					gs.liveAxisSign   = nil
					gs.liveAxisSlot   = nil
					gs.hadLiveFire    = false
					gs.lastFirePos    = nil
					gs.fingerCountChangedAt = now
					-- Reset peak finger state so the new gesture's finger count is
					-- evaluated independently (peakN from the committed gesture must
					-- not influence the peak override for the fresh one).
					gs.peakN          = n
					gs.peakNFirstSeen = now
					gs.peakNLastSeen  = now
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
					local tentative = Geometry.computeDir(dx, dy, gs.maxFingers)
					if tentative ~= nil then
						Logger.info(LOG, "LOCKED DIR=%s (dx=%.2f dy=%.2f maxFingers=%d)",
							tentative, dx, dy, gs.maxFingers)
					end
					gs.lockedDir = tentative
				end

				if gs.lockedDir then
					local axis = gs.lockedDir
					local dx = pos.x - gs.startPos.x
					local dy = pos.y - gs.startPos.y
					local slot = Geometry.slotForDir(gs.maxFingers, axis, dx, dy)

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
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — module non-functional.")
		return
	end
	Logger.start(LOG, "Initializing gestures engine dependencies…")
	_state   = core_state
	_actions = actions_mod
	
	-- Vital: Permanent event tap to block scroll events dynamically via flag.
	-- Dynamically calling :start() and :stop() triggers a 10s macOS Accessibility block.
	if not scrollBlocker then
		local evTypes = hs.eventtap.event.types
		scrollBlocker = hs.eventtap.new(
			{ evTypes.scrollWheel, evTypes.gesture },
			function(e)
				return isBlockingScroll
			end
		)
		if scrollBlocker then
			pcall(function() scrollBlocker:start() end)
		end
	end
	
	Logger.success(LOG, "Gestures engine dependencies initialized.")
end

--- Releases an armed scroll-block (the permanent scrollBlocker eventtap keeps
--- running but its swallow decision goes back to false). Called on pause/suspend:
--- a scroll-block armed mid-gesture (3+ fingers) otherwise keeps swallowing native
--- scroll until the user lifts all fingers — a "pause = everything off" violation.
--- Idempotent and safe when nothing is armed.
--- @return boolean settled
function M.unblock_scroll()
	stopScrollBlock()
	return true
end

--- Returns whether the scroll-block is currently swallowing scroll events.
--- @return boolean
function M.is_blocking_scroll()
	return isBlockingScroll
end

--- Stops the engine and releases the scroll-blocker eventtap.
--- Must be called from gestures init.lua M.stop() so the tap is not left armed
--- across reloads (N reloads without stop → N concurrent scroll eventtaps).
function M.stop()
	if scrollBlocker then
		pcall(function() scrollBlocker:stop() end)
		scrollBlocker = nil
	end
	_state   = nil
	_actions = nil
	Logger.done(LOG, "Gestures engine stopped.")
end

--- Registers a callback fired on every frame where at least one finger touches
--- the trackpad. Pass nil to unregister.
--- @param hook fun()|nil
function M.set_any_touch_hook(hook)
	_any_touch_hook = hook
end

--- Forces all gesture-tracking state back to idle and clears the scroll block.
--- Called from the frame-callback error path when process_frame throws: without
--- this, a crash after startScrollBlock() leaves isBlockingScroll=true and the
--- user can never scroll again until Hammerspoon is reloaded. Idempotent.
function M.emergency_reset()
	Logger.warn(LOG, "emergency_reset() called — forcing gesture state reset and scroll unblock.")
	resetGS()
end

return M
