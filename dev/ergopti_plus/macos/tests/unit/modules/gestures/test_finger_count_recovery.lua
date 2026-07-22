--- tests/unit/modules/gestures/test_finger_count_recovery.lua

--- ==============================================================================
--- MODULE: Regression — a transient finger-count change must not kill the gesture
--- DESCRIPTION:
--- Two independent latches, each of which silently dropped the whole remainder of
--- a swipe after one moment of imperfect finger contact.
---
--- ROOT CAUSE 1 — the spike candidate was never retired.
--- gs.candidateFingers is armed when n rises more than one above maxFingers (a
--- "spike" needing confirmation), and it was cleared ONLY inside that same
--- `n > gs.maxFingers` branch. The moment the extra contact disappeared, n fell
--- back and that branch became unreachable, so the candidate stayed armed until
--- finger-lift. triggerLiveAxisIfNeeded returns early for as long as a candidate
--- is pending ("live blocked: finger spike confirmation pending"), so every live
--- fire for the rest of the gesture was swallowed.
---
--- ROOT CAUSE 2 — maxFingers was never demoted.
--- A confirmed drop set gs.lifting = true unconditionally. maxFingers is
--- monotonically non-decreasing, so after a genuine 4->3 change n stayed
--- permanently below it: no branch could clear `lifting` again, the rest of the
--- swipe was ignored, and the gesture mis-committed as a tap of the higher count.
---
--- WHY A SOURCE GUARD RATHER THAN A BEHAVIOURAL TEST:
--- Both defects are states of the engine's private `gs` table, and the engine
--- exposes no accessor for it (its public surface is process_frame / init / stop /
--- emergency_reset / the scroll-block pair). Driving the symptom through
--- process_frame was attempted and rejected: in x1 mode the axis fires on
--- threshold crossings and then stops on its own, so "stopped firing" is
--- indistinguishable from normal completion and the test could not discriminate
--- fixed from broken. What IS decidable, and what was actually wrong, is the
--- STRUCTURE: the clearing path sat where the falling-count branches could never
--- reach it. These assertions pin exactly that.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the engine source once for every assertion below.
--- @return string The engine source.
local function engine_source()
	-- Selected by a declaration unique to modules/gestures/engine.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function startScrollBlock")
	helpers.assert_true(src ~= nil, "modules/gestures/engine.lua source must be locatable")
	if not src then return end
	return src
end





-- ===============================================
-- ===============================================
-- ======= 1/ The Candidate Can Be Retired =======
-- ===============================================
-- ===============================================

helpers.describe("a stale finger-spike candidate is reachable for clearing", function()
	helpers.it("the candidate is retired before the finger-count branch chain", function()
		local src = engine_source()

		local retire_at = src:find("gs%.candidateFingers%s*~=%s*nil%s*and%s*n%s*~=%s*gs%.candidateFingers")
		helpers.assert_true(retire_at ~= nil,
			"engine must retire a spike candidate when the observed count stops matching it. "
			.. "Clearing it only inside the `n > gs.maxFingers` branch makes the clearing path "
			.. "unreachable the moment the count falls back, so the candidate stays armed and "
			.. "the live-fire gate blocks every trigger until finger-lift")

		-- Reachability is the whole point: it must sit BEFORE the branch chain, so
		-- the falling-count and equal-count paths run it too.
		local chain_at = src:find("if n < gs%.maxFingers then")
		helpers.assert_true(chain_at ~= nil, "the finger-count branch chain must be locatable")
		helpers.assert_true(retire_at < chain_at,
			"the retire must precede the `n < maxFingers` chain — placed inside a branch it is "
			.. "unreachable from exactly the cases that need it")
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 2/ A Confirmed Drop Demotes =======
-- ===========================================
-- ===========================================

helpers.describe("a confirmed drop to a still-multi-finger count is a change, not an end", function()
	helpers.it("demotes maxFingers instead of latching lifting", function()
		local src = engine_source()

		local confirm_at = src:find("Confirmed finger drop", 1, true)
		helpers.assert_true(confirm_at ~= nil, "the confirmed-drop branch must be locatable")

		-- Within the confirmed-drop branch, a still-multi-finger count must take the
		-- demotion path rather than unconditionally setting lifting.
		local tail = src:sub(confirm_at, confirm_at + 1200)
		helpers.assert_true(tail:find("gs%.maxFingers%s*=%s*n") ~= nil,
			"a confirmed drop to a still-multi-finger count must demote gs.maxFingers. Without "
			.. "it n stays permanently below maxFingers, nothing can clear `lifting` again, and "
			.. "the rest of the swipe is dropped then mis-committed as a tap of the old count")
		helpers.assert_true(tail:find("if n >= 2 then") ~= nil,
			"the demotion must be gated on a still-multi-finger count — a drop to zero fingers "
			.. "is a real lift-off and must still end the gesture")
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Lift-off Still Ends It =======
-- =========================================
-- =========================================

helpers.describe("a full lift-off still ends the gesture", function()
	helpers.it("firing stops once every finger is gone", function()
		-- Behavioural where it CAN be observed: the opposite failure. Demoting on
		-- every drop would mean a real lift-off never terminates the gesture, so this
		-- drives the real engine and asserts nothing fires after the fingers leave.
		package.loaded["modules.gestures.engine"] = nil
		package.loaded["lib.logger"]  = nil
		package.loaded["lib.timings"] = nil
		local _ = helpers.load_with_stubs("lib.logger")
		package.loaded["lib.timings"] = {
			sec = function(_, key)
				if key == "tap_max_ms" then return 0.5
				elseif key == "finger_confirm_ms" then return 0.05
				elseif key == "finger_drop_confirm_ms" then return 0.12 end
				return 0.0
			end,
		}

		local Engine = require("modules.gestures.engine")
		local fired  = {}
		Engine.init({
			enabled = true,
			ga = {
				swipe_2_up = "none", swipe_2_down = "none",
				swipe_2_left = "none", swipe_2_right = "none",
				swipe_3_up = "tab_prev", swipe_3_down = "tab_next",
				swipe_3_left = "none", swipe_3_right = "none",
				tap_2 = "none", tap_3 = "none", tap_4 = "none", tap_5 = "none",
			},
			modes         = { swipe_3_up = "x1", swipe_3_down = "x1" },
			sensitivities = { swipe_3_up = 3.5, swipe_3_down = 3.5 },
		}, {
			execute_single = function(a) fired[#fired + 1] = a end,
			execute_axis   = function(a) fired[#fired + 1] = a end,
			set_gesture_in_progress = function() end,
		})

		local function fingers(count, y)
			local f = {}
			for i = 1, count do
				f[#f + 1] = { absoluteVector = { position = { x = 100 + (i * 10), y = y } } }
			end
			return f
		end

		local y = 100
		for _ = 1, 4 do Engine.process_frame(fingers(3, y)) ; y = y + 8 end
		for _ = 1, 5 do Engine.process_frame({}) end
		local after_lift = #fired
		for _ = 1, 5 do Engine.process_frame({}) end

		helpers.assert_eq(#fired, after_lift,
			"once every finger is lifted the gesture is over and must fire nothing more — a "
			.. "demotion applied to a drop to zero would keep it alive forever")
	end)
end)
