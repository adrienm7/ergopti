--- tests/unit/platform/remap/test_activation_stop_supersession.lua

--- ==============================================================================
--- MODULE: Activation Superseded By Its Own Exact Stop Regression Tests
--- DESCRIPTION:
--- Drives the real remap coordinator over the token-aware lease double, whose
--- Stop answers with the controller's contract reasons. When the coordinator
--- itself fences the generation it is activating (a layout change during the
--- boot's READY wait or RESUME, a reload during the user's Resume or Enable),
--- the activation is superseded, not failed: it logs no ERROR, which opened
--- the error window at startup with « prepared lease RESUME failed:
--- lease-stopping », and a retained intent completes on a fresh generation. A
--- RESUME the worker fails is still an ERROR (lease-stop-supersedes-activation).
--- ==============================================================================

local helpers = require("tests.helpers")
local with_remap = require("tests.support.activation_layout_fixture").with_remap

--- Returns the messages logged at one level.
--- @param calls table Fixture observations.
--- @param level string Logger level.
--- @return table messages
local function logged(calls, level)
	local messages = {}
	for _, entry in ipairs(calls.logs) do
		if entry.level == level then messages[#messages + 1] = entry.message end
	end
	return messages
end

--- Returns whether one logged message at a level contains a fragment.
--- @param calls table Fixture observations.
--- @param level string Logger level.
--- @param fragment string Plain text to find.
--- @return boolean found
local function logged_containing(calls, level, fragment)
	for _, message in ipairs(logged(calls, level)) do
		if message:find(fragment, 1, true) then return true end
	end
	return false
end

--- Starts the boot's public regeneration and returns its first build.
--- @param remap table Real remap coordinator.
--- @param calls table Fixture observations.
--- @return table build First build descriptor.
local function start_boot_regeneration(remap, calls)
	helpers.assert_true(remap.regenerate())
	local build = calls.builds[#calls.builds]
	helpers.assert_type(build, "table", "the boot regeneration must build a generation")
	helpers.assert_eq(calls.phase, "starting")
	return build
end

--- Completes the fresh generation the retained regeneration rebuilds.
--- @param calls table Fixture observations.
--- @param stale_token string Token the layout change fenced.
local function complete_fresh_generation(calls, stale_token)
	helpers.assert_true(calls.drain_until(function() return #calls.builds >= 2 end),
		"the retained regeneration must rebuild after the fence settles")
	local replacement = calls.builds[#calls.builds]
	helpers.assert_true(replacement.token ~= stale_token, "the fenced token is never reused")
	helpers.assert_eq(replacement.layout, "layout-b")
	helpers.assert_true(calls.deliver_all_ready(replacement.token))
	helpers.assert_true(calls.deliver_resumed(replacement.token))
	helpers.assert_eq(calls.phase, "active")
	helpers.assert_eq(calls.status_token, replacement.token)
end





-- ==========================================================
-- ==========================================================
-- ======= 1/ Superseded Activations Are Not Failures =======
-- ==========================================================
-- ==========================================================

helpers.describe("Karabiner activation superseded by its own exact stop", function()
	helpers.it("(lease-stop-supersedes-activation) a layout fence of the boot's RESUME logs no ERROR", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local stale = start_boot_regeneration(remap, calls)
			helpers.assert_true(calls.deliver_all_ready(stale.token))
			helpers.assert_eq(calls.phase, "resuming", "the boot's RESUME must be in flight")

			calls.change_layout("layout-b")
			helpers.assert_eq(#logged(calls, "error"), 0,
				"a fence the coordinator requested is no failure: "
					.. table.concat(logged(calls, "error"), " | "))
			helpers.assert_true(logged_containing(calls, "info", "superseded by its exact stop"),
				"the superseded activation must still be logged")
			helpers.assert_eq(table.concat(calls.stop_reasons, ","), "layout_changed_during_activation",
				"the superseded startup must not relabel the layout fence as a bind failure")

			complete_fresh_generation(calls, stale.token)
			helpers.assert_eq(#logged(calls, "error"), 0)
		end)
	end)

	helpers.it("(lease-stop-supersedes-activation) a layout fence before the boot's READY logs no ERROR", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local stale = start_boot_regeneration(remap, calls)

			calls.change_layout("layout-b")
			helpers.assert_eq(#logged(calls, "error"), 0,
				"a fence the coordinator requested is no failure: "
					.. table.concat(logged(calls, "error"), " | "))
			helpers.assert_true(logged_containing(calls, "info", "preparation superseded by its exact stop"))
			helpers.assert_eq(table.concat(calls.stop_reasons, ","), "layout_changed_during_activation")

			complete_fresh_generation(calls, stale.token)
			helpers.assert_eq(#logged(calls, "error"), 0)
		end)
	end)

	helpers.it("(lease-stop-supersedes-activation) a reload during the user's Resume logs no ERROR", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.resume(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			helpers.assert_eq(calls.phase, "resuming", "the user's RESUME must be in flight")

			helpers.assert_true(remap.revoke("hammerspoon_reload"))
			helpers.assert_eq(#logged(calls, "error"), 0,
				"a reload the user asked for is no failure: " .. table.concat(logged(calls, "error"), " | "))
			helpers.assert_true(logged_containing(calls, "info", "resume transaction superseded by its exact stop"))
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok == false, "a superseded Resume did not resume")
		end)
	end)

	helpers.it("(lease-stop-supersedes-activation) a reload during Enable logs no ERROR", function()
		with_remap({ enabled = false, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.set_enabled(true, function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local build = calls.builds[#calls.builds]
			helpers.assert_true(calls.deliver_all_ready(build.token))
			helpers.assert_eq(calls.phase, "resuming", "the Enable's RESUME must be in flight")
			-- The fixture's disabled start cannot read a karabiner.json; judge the reload only.
			calls.logs = {}

			helpers.assert_true(remap.revoke("hammerspoon_reload"))
			helpers.assert_eq(#logged(calls, "error"), 0,
				"a reload the user asked for is no failure: " .. table.concat(logged(calls, "error"), " | "))
			helpers.assert_true(logged_containing(calls, "info", "enable activation superseded by its exact stop"))
			helpers.assert_true(remap.get_enabled() == false, "a superseded Enable never commits")
		end)
	end)

	helpers.it("(lease-stop-supersedes-activation) a RESUME the worker failed is still an ERROR", function()
		with_remap({ enabled = true, paused = false, initial_phase = "prepared" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.regenerate(function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			local build = calls.builds[#calls.builds]
			helpers.assert_true(calls.deliver_all_ready(build.token))
			local pending = table.remove(calls.resume_callbacks, 1)
			helpers.assert_type(pending, "table", "the boot's RESUME must be in flight")

			pending.callback(false, "timeout waiting for RESUMED")
			helpers.assert_true(logged_containing(calls, "error",
				"Lease-bound input startup failed: prepared lease RESUME failed: timeout waiting for RESUMED"))
			helpers.assert_true(logged_containing(calls, "error", "Prepared Karabiner lease activation failed"))
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok == false, "a failed RESUME must fail its regeneration")
		end)
	end)
end)
