--- tests/unit/platform/remap/runtime_owner/test_runtime_owner_admission.lua

--- ==============================================================================
--- MODULE: Owned Runtime Admission
--- DESCRIPTION:
--- Proves that platform/remap/runtime_owner.lua admits the owned Karabiner
--- runtime only when every precondition holds, and otherwise names the reason
--- with an explanation instead of falling back to another runtime.
---
--- ROOT CAUSES ENCODED: (a) a runtime that starts without being asked would
--- change today's behaviour for every user, so initialization binds ports and
--- touches nothing; (b) only one VirtualHIDDevice version can be active on a
--- Mac, so an incompatible one must stop admission before any job, process or
--- other Karabiner is touched; (c) an unreadable machine state is a failure,
--- never "assume it is fine".
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.platform.remap.runtime_owner_fixture")

--- Runs admission to its settlement.
--- @param owner table Owner module.
--- @param options table|nil Overrides of the start options.
--- @return boolean admitted
--- @return string|nil reason
--- @return string|nil explanation
local function admit(owner, options)
	local settled = {}
	local start_options = { close_other_instances = true }
	for key, value in pairs(options or {}) do start_options[key] = value end
	helpers.assert_true(owner.start(start_options, function(...) settled = table.pack(...) end))
	return settled[1], settled[2], settled[3]
end





-- ==================================
-- ==================================
-- ======= 1/ Dormant Binding =======
-- ==================================
-- ==================================

helpers.describe("owned runtime owner: dormant until asked", function()
	helpers.it("is uninitialized after loading and binding the ports touches nothing", function()
		local owner = Fixture.load_owner()
		helpers.assert_eq(owner.status().state, "uninitialized")
		local world = Fixture.new_world()
		local touched = 0
		for _, group in pairs(world.ports) do
			if type(group) == "table" then
				for name, fn in pairs(group) do
					-- Registering the loss callback is part of binding: it reads nothing.
					if type(fn) == "function" and name ~= "on_lost" then
						group[name] = function(...) touched = touched + 1; return fn(...) end
					end
				end
			end
		end
		helpers.assert_true(owner.init(world.ports))
		helpers.assert_eq(touched, 0)
		helpers.assert_eq(owner.status().state, "idle")
		helpers.assert_eq(#world.calls.capture_start, 0)
		helpers.assert_eq(owner.admitted(), false)
	end)

	helpers.it("refuses a second initialization instead of replacing the ports", function()
		local owner = Fixture.load_owner()
		local first, second = Fixture.new_world(), Fixture.new_world()
		helpers.assert_true(owner.init(first.ports))
		helpers.assert_eq(owner.init(second.ports), false)
		admit(owner)
		helpers.assert_eq(#first.calls.states > 0, true)
		helpers.assert_eq(#second.calls.states, 0)
	end)

	helpers.it("rejects ports that miss a capability", function()
		local owner = Fixture.load_owner()
		local world = Fixture.new_world()
		world.ports.launchd = nil
		helpers.assert_throws(function() owner.init(world.ports) end)
		helpers.assert_eq(owner.status().state, "uninitialized")
		local other = Fixture.new_world()
		other.ports.capture.on_lost = nil
		helpers.assert_throws(function() owner.init(other.ports) end)
		local timerless = Fixture.new_world()
		timerless.ports.timer = nil
		helpers.assert_throws(function() owner.init(timerless.ports) end)
		local captureless = Fixture.new_world()
		captureless.ports.capture = nil
		helpers.assert_throws(function() owner.init(captureless.ports) end)
		helpers.assert_eq(owner.status().state, "uninitialized")
	end)

	helpers.it("rejects a start before initialization and invalid start options", function()
		local owner = Fixture.load_owner()
		helpers.assert_throws(function() owner.start({ close_other_instances = true }) end)
		helpers.assert_true(owner.init(Fixture.new_world().ports))
		helpers.assert_throws(function() owner.start({}) end)
		helpers.assert_throws(function() owner.start({ close_other_instances = "yes" }) end)
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 2/ What Admission Requires =======
-- ==========================================
-- ==========================================

helpers.describe("owned runtime owner: admission", function()
	helpers.it("admits a complete, compatible, uncontested runtime without starting anything", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		owner.init(world.ports)
		local admitted, reason = admit(owner)
		helpers.assert_eq(admitted, true)
		helpers.assert_nil(reason)
		helpers.assert_eq(owner.status().state, "admitted")
		helpers.assert_eq(owner.admitted(), true)
		helpers.assert_eq(#world.calls.capture_start, 0)
		helpers.assert_eq(#world.calls.timers, 0)
		helpers.assert_eq(world.calls.close, 0)
	end)

	helpers.it("names an unpinned artifact and starts nothing", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.pinned = nil
		owner.init(world.ports)
		local admitted, reason, explanation = admit(owner)
		helpers.assert_eq(admitted, false)
		helpers.assert_eq(reason, "artifact_unpinned")
		helpers.assert_contains(explanation, "manifest absent")
		helpers.assert_eq(owner.status().state, "unavailable")
	end)

	helpers.it("names the missing file of an incomplete install", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		local KePaths = require("platform.remap.ke_paths")
		world.files[KePaths.OWNED.CONSOLE] = nil
		owner.init(world.ports)
		local admitted, reason, explanation = admit(owner)
		helpers.assert_eq(admitted, false)
		helpers.assert_eq(reason, "runtime_not_installed")
		helpers.assert_contains(explanation, "ErgoptiPlus-Remap-Console")
	end)

	helpers.it("refuses an incompatible VirtualHIDDevice with both versions named, before any job or process", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.listing_text = Fixture.listing("6.0.0", "activated enabled")
		world.others = 2
		local job_reads = 0
		local original = world.ports.launchd.loaded
		world.ports.launchd.loaded = function(...) job_reads = job_reads + 1; return original(...) end
		owner.init(world.ports)
		local admitted, reason, explanation = admit(owner)
		helpers.assert_eq(admitted, false)
		helpers.assert_eq(reason, "virtual_hid_incompatible")
		helpers.assert_contains(explanation, "6.0.0")
		helpers.assert_contains(explanation, "8.5.0")
		helpers.assert_contains(explanation, "confirmation")
		helpers.assert_eq(job_reads, 0)
		helpers.assert_eq(world.calls.close, 0)
		helpers.assert_eq(#world.calls.capture_start, 0)
		helpers.assert_eq(owner.admitted(), false)
		helpers.assert_eq(owner.status().explanation, explanation)
	end)

	helpers.it("refuses a driver signed by another team", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.listing_text = Fixture.listing("8.5.0", "activated enabled", "ABCDE12345")
		owner.init(world.ports)
		local _, reason = admit(owner)
		helpers.assert_eq(reason, "virtual_hid_incompatible")
	end)

	helpers.it("tells an absent, an unapproved and an unreadable driver apart", function()
		local cases = {
			{ text = "0 extension(s)\n", reason = "virtual_hid_absent" },
			{ text = Fixture.listing("8.5.0", "activated waiting for user"), reason = "virtual_hid_not_active" },
			{ text = "garbage", reason = "virtual_hid_unreadable" },
		}
		for _, case in ipairs(cases) do
			local owner, world = Fixture.load_owner(), Fixture.new_world()
			world.listing_text = case.text
			owner.init(world.ports)
			local _, reason = admit(owner)
			helpers.assert_eq(reason, case.reason)
		end
	end)

	helpers.it("prefers the active copy over a terminated older one", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.listing_text = Fixture.listing("6.0.0", "terminated waiting to uninstall on reboot")
			.. Fixture.listing("8.5.0", "activated enabled")
		owner.init(world.ports)
		helpers.assert_eq((admit(owner)), true)
	end)

	helpers.it("fails, rather than assuming, when the machine state cannot be read", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.listing_text = nil
		owner.init(world.ports)
		local _, reason = admit(owner)
		helpers.assert_eq(reason, "system_extension_listing_failed")
		helpers.assert_eq(owner.status().state, "failed")

		local second, other = Fixture.load_owner(), Fixture.new_world()
		other.launchd_unreadable = true
		second.init(other.ports)
		local _, launchd_reason = admit(second)
		helpers.assert_eq(launchd_reason, "launchd_unreadable")
		helpers.assert_eq(second.status().state, "failed")

		local third, probe = Fixture.load_owner(), Fixture.new_world()
		probe.probe_fails = true
		third.init(probe.ports)
		local _, probe_reason = admit(third)
		helpers.assert_eq(probe_reason, "coexistence_probe_failed")
	end)

	helpers.it("names an installed job that launchd has not loaded", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		local KePaths = require("platform.remap.ke_paths")
		world.jobs[KePaths.OWNED.CORE_LABEL] = false
		owner.init(world.ports)
		local _, reason, explanation = admit(owner)
		helpers.assert_eq(reason, "runtime_job_not_loaded")
		helpers.assert_contains(explanation, "com.ergoptiplus.runtime.core")
	end)
end)





-- ==================================
-- ==================================
-- ======= 3/ Other Karabiner =======
-- ==================================
-- ==================================

helpers.describe("owned runtime owner: coexistence", function()
	helpers.it("does not fight another Karabiner when the close option is off", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.others = 1
		owner.init(world.ports)
		local admitted, reason, explanation = admit(owner, { close_other_instances = false })
		helpers.assert_eq(admitted, false)
		helpers.assert_eq(reason, "other_karabiner_running")
		helpers.assert_contains(explanation, "option")
		helpers.assert_eq(world.calls.close, 0)
	end)

	helpers.it("closes the other Karabiner under the default-on option and re-checks", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.others = 3
		owner.init(world.ports)
		helpers.assert_eq((admit(owner)), true)
		helpers.assert_eq(world.calls.close, 1)
	end)

	helpers.it("reports a Karabiner that survives the request", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.others, world.others_after_close = 1, 1
		owner.init(world.ports)
		local _, reason = admit(owner)
		helpers.assert_eq(reason, "other_karabiner_still_running")
	end)

	helpers.it("names a closer that is not bound instead of skipping the check", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.others = 1
		world.ports.coexistence.close = nil
		owner.init(world.ports)
		local _, reason = admit(owner)
		helpers.assert_eq(reason, "close_other_unsupported")
	end)

	helpers.it("fails when the other Karabiner cannot be asked to quit", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.others, world.close_result = 1, false
		owner.init(world.ports)
		local _, reason = admit(owner)
		helpers.assert_eq(reason, "close_other_failed")
		helpers.assert_eq(owner.status().state, "failed")
	end)

	helpers.it("defaults the close option to on, as ADR 011 decided", function()
		helpers.assert_eq(Fixture.load_owner().CLOSE_OTHER_INSTANCES_DEFAULT, true)
	end)
end)





-- ==================================
-- ==================================
-- ======= 4/ Capture Pinning =======
-- ==================================
-- ==================================

helpers.describe("owned runtime owner: physical capture admission", function()
	helpers.it("refuses an artifact that declares no capture, since the capture is the only way to a Console", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.pinned.capture = nil
		owner.init(world.ports)
		local _, reason, explanation = admit(owner)
		helpers.assert_eq(reason, "capture_unpinned")
		helpers.assert_contains(explanation, "capture")
		helpers.assert_eq(#world.calls.capture_start, 0)
	end)

	helpers.it("takes no capture option: the user side of the runtime always runs with the capture", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		owner.init(world.ports)
		helpers.assert_eq((admit(owner, { capture = false })), true)
		helpers.assert_eq(#world.calls.capture_start, 0)
	end)
end)





-- ================================
-- ================================
-- ======= 5/ Stale Results =======
-- ================================
-- ================================

helpers.describe("owned runtime owner: results that arrive late", function()
	helpers.it("ignores an admission step delivered after a stop", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.deferred = true
		owner.init(world.ports)
		local settled = false
		helpers.assert_true(owner.start({ close_other_instances = true }, function() settled = true end))
		helpers.assert_eq(owner.status().state, "starting")
		helpers.assert_eq(owner.stop(), true)
		world.flush()
		helpers.assert_eq(settled, false)
		helpers.assert_eq(owner.status().state, "stopped")
		helpers.assert_eq(owner.admitted(), false)
	end)

	helpers.it("refuses to start while an admission is in flight", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.deferred = true
		owner.init(world.ports)
		helpers.assert_true(owner.start({ close_other_instances = true }))
		helpers.assert_eq(owner.start({ close_other_instances = true }), false)
	end)
end)
