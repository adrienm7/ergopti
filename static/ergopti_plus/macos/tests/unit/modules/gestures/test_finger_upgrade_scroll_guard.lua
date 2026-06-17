--- tests/unit/modules/gestures/test_finger_upgrade_scroll_guard.lua

--- ==============================================================================
--- MODULE: modules.gestures.engine — 3-finger upgrade guard during scroll
--- DESCRIPTION:
--- Locks down the bug where a brief accidental 3rd-finger contact during a
--- 2-finger vertical scroll was instantly upgrading `maxFingers` to 3 via the
--- fast-path, then firing `swipe_3_up` (tab_prev) or `swipe_3_down` (tab_next)
--- every time the user used 2 fingers to scroll.
---
--- Root cause: the fast-path `n <= gs.maxFingers + 1` accepted any single-finger
--- join immediately, with no check for whether the NEW finger count had active
--- actions on the already-locked axis. On a vertical scroll (lockedDir="vert"),
--- a stray 3rd finger instantly set maxFingers=3 and the live-fire path fired
--- swipe_3_up/swipe_3_down.
---
--- Fix: the fast-path is now skipped when `lockedDir` is set AND the incoming
--- finger count is active on that axis AND a live action has already fired
--- (liveAxisSign ~= nil). This means a stray 3rd finger mid-scroll (after the
--- 2-finger action already fired) goes through candidate confirmation, while a
--- genuine 3-finger gesture whose 3rd contact lands before any action fires
--- takes the fast-path immediately — keeping real 3-finger swipes instant.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_source(module_name)
	local path = package.searchpath(module_name, package.path)
	helpers.assert_true(
		type(path) == "string" and path ~= "",
		"could not resolve " .. module_name .. " on package.path"
	)
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "could not open " .. module_name)
	local src = fh:read("*a")
	fh:close()
	return src
end




-- =============================================================================
-- =============================================================================
-- ======= 1/ Source-level guard: active-axis fast-path exclusion ============
-- =============================================================================
-- =============================================================================

helpers.describe("gestures.engine — fast-path excludes active-axis count upgrades", function()
	helpers.it("declares new_count_active_on_locked_axis guard variable", function()
		local src = read_source("modules.gestures.engine")
		helpers.assert_true(
			src:find("new_count_active_on_locked_axis", 1, true) ~= nil,
			"modules.gestures.engine must declare `new_count_active_on_locked_axis` to " ..
			"prevent stray 3rd-finger contact during 2-finger scroll from instantly " ..
			"promoting maxFingers and firing tab_prev/tab_next"
		)
	end)

	helpers.it("fast-path condition gates on not new_count_active_on_locked_axis", function()
		local src = read_source("modules.gestures.engine")
		-- The guard must prevent the fast-path when the new finger count is active
		-- on the locked axis.
		helpers.assert_true(
			src:find("not new_count_active_on_locked_axis", 1, true) ~= nil,
			"modules.gestures.engine: fast-path must be disabled when the incoming " ..
			"finger count has active actions on the locked axis"
		)
	end)

	helpers.it("guard also checks liveAxisSign to allow genuine 3-finger gestures", function()
		local src = read_source("modules.gestures.engine")
		-- The guard must additionally check liveAxisSign ~= nil so that a real
		-- 3-finger gesture (3rd finger lands before any live fire) still takes
		-- the fast-path and fires immediately without candidate-path delay.
		helpers.assert_true(
			src:find("liveAxisSign ~= nil", 1, true) ~= nil,
			"modules.gestures.engine: new_count_active_on_locked_axis guard must " ..
			"also require liveAxisSign ~= nil so genuine 3-finger swipes are instant"
		)
	end)

	helpers.it("uses finger_count_is_inert to check the new count on the locked axis", function()
		local src = read_source("modules.gestures.engine")
		-- The guard uses finger_count_is_inert(n, lockedDir) — we check that the
		-- call appears close to new_count_active_on_locked_axis.
		local guard_pos = src:find("new_count_active_on_locked_axis", 1, true)
		helpers.assert_true(guard_pos ~= nil)
		-- Within 200 chars around the declaration there must be a call to
		-- finger_count_is_inert that takes `n` as argument.
		local window = src:sub(math.max(1, guard_pos - 20), guard_pos + 200)
		helpers.assert_true(
			window:find("finger_count_is_inert%(n", 1, true) ~= nil or
			window:find("finger_count_is_inert(n", 1, true) ~= nil,
			"the new_count_active_on_locked_axis guard must call finger_count_is_inert " ..
			"with the candidate finger count `n` to check activity on the locked axis"
		)
	end)

	helpers.it("fast-path still exists for the normal (inert-axis) case", function()
		local src = read_source("modules.gestures.engine")
		-- The original fast-path comment and use_fast_path conditional must still
		-- be present so non-problematic finger joins remain instant.
		helpers.assert_true(
			src:find("use_fast_path", 1, true) ~= nil,
			"modules.gestures.engine: the fast-path variable `use_fast_path` must still " ..
			"exist — its purpose is to keep non-active-axis joins instant (no regression)"
		)
	end)
end)




-- =============================================================================
-- =============================================================================
-- ======= 2/ Runtime: process_frame with stub state =========================
-- =============================================================================
-- =============================================================================

helpers.describe("gestures.engine — 3-finger upgrade blocked on vertical scroll", function()
	helpers.it("stray 3rd finger does not promote maxFingers when scroll is locked vert", function()
		-- Build a minimal stub state with swipe_3_up/down configured (the default).
		-- We call M.process_frame() directly so no OS interaction is needed.
		package.loaded["modules.gestures.engine"] = nil
		package.loaded["lib.logger"]  = nil
		package.loaded["lib.timings"] = nil

		local _ = helpers.load_with_stubs("lib.logger")

		-- Stub timings to return fixed values
		package.loaded["lib.timings"] = {
			sec = function(_, key)
				if key == "tap_max_ms"              then return 0.5
				elseif key == "live_rearm_ms"       then return 0.1
				elseif key == "live_rearm_reverse_ms" then return 0.05
				elseif key == "finger_confirm_ms"   then return 0.05
				elseif key == "finger_drop_confirm_ms" then return 0.12
				elseif key == "finger_count_stable_ms" then return 0.06
				end
				return 0.05
			end,
		}

		local Engine = require("modules.gestures.engine")

		-- Stub state: 2-finger scroll with vertical actions on finger 3, but not
		-- horizontal — mirrors the default gesture configuration.
		local fired_slots = {}
		-- swipe_2_down is active so the live-fire path triggers on 2-finger scroll
		-- (setting liveAxisSign). The guard requires liveAxisSign ~= nil to block
		-- the fast-path upgrade: without a prior live fire the 3rd finger would be
		-- accepted immediately as a genuine 3-finger gesture (correct new behaviour).
		local stub_state = {
			enabled = true,
			ga = {
				swipe_2_up    = "none",
				swipe_2_down  = "scroll_down", -- live action: sets liveAxisSign during scroll
				swipe_2_left  = "none",
				swipe_2_right = "none",
				swipe_3_up    = "tab_prev",    -- active: this must NOT fire on scroll
				swipe_3_down  = "tab_next",    -- active: this must NOT fire on scroll
				swipe_3_left  = "word_prev",
				swipe_3_right = "word_next",
				tap_2 = "none", tap_3 = "none", tap_4 = "none", tap_5 = "none",
			},
			modes         = { swipe_2_down = "x1", swipe_3_up = "x1", swipe_3_down = "x1" },
			sensitivities = { swipe_2_down = 0.01, swipe_3_up = 3.5, swipe_3_down = 3.5 },
		}

		local stub_actions = {
			execute_single = function(action) table.insert(fired_slots, action) end,
			execute_axis   = function(action) table.insert(fired_slots, action) end,
			set_gesture_in_progress = function() end,
		}

		Engine.init(stub_state, stub_actions)

		-- Helper to build a fake touch at position (x, y)
		local function touch(x, y)
			return { absoluteVector = { position = { x = x, y = y } } }
		end

		-- Simulate: 2-finger downward scroll (vertical, lockedDir = "vert")
		-- Frame 1: gesture starts with 2 fingers moving down
		Engine.process_frame({ touch(0.5, 0.3), touch(0.5, 0.35) })
		-- Frame 2: movement progresses down — enough to lock direction as "vert"
		Engine.process_frame({ touch(0.5, 0.4), touch(0.5, 0.45) })
		-- Frame 3: more movement (3.0+ units)
		Engine.process_frame({ touch(0.5, 0.55), touch(0.5, 0.60) })
		-- Frame 4: stray 3rd finger joins briefly (accidental contact)
		Engine.process_frame({ touch(0.5, 0.55), touch(0.5, 0.60), touch(0.2, 0.8) })
		-- Frame 5: stray finger lifts — back to 2 fingers
		Engine.process_frame({ touch(0.5, 0.55), touch(0.5, 0.60) })
		-- Frame 6: fingers lift — gesture ends
		Engine.process_frame({})

		-- The accidental 3rd-finger contact must not have triggered swipe_3_up or
		-- swipe_3_down (tab_prev / tab_next).
		local bad_fires = {}
		for _, a in ipairs(fired_slots) do
			if a == "tab_prev" or a == "tab_next" then
				table.insert(bad_fires, a)
			end
		end

		helpers.assert_eq(
			#bad_fires, 0,
			"stray 3rd-finger contact during 2-finger scroll must not fire " ..
			"tab_prev or tab_next — fired: " .. table.concat(bad_fires, ", ")
		)
	end)
end)
