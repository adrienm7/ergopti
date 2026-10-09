--- tests/unit/ui/menu/test_remap_switch.lua

--- ==============================================================================
--- MODULE: Remap Switch Menu Commands Tests
--- DESCRIPTION:
--- The Configuration rows only ask the remap owner and report its terminal:
--- a removal is confirmed after the owner reported it, and every refusal is
--- an error (which the shared error UI surfaces), never a confirmation.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.logger",
	"infra.i18n",
	"infra.notifications",
	"ui.menu.remap_switch",
}

--- Loads the commands over recording logger and notification doubles.
--- @return table switch
--- @return table seen
local function load_switch()
	local seen = { notices = {}, errors = {}, refreshes = 0 }
	local logger = {}
	for _, level in ipairs({ "debug", "done", "info", "start", "success", "trace", "warn" }) do
		logger[level] = function() end
	end
	logger.error = function(_, message) seen.errors[#seen.errors + 1] = message end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.notifications"] = {
		notify = function(message, _, kind)
			seen.notices[#seen.notices + 1] = { message = message, kind = kind }
			return true
		end,
	}
	local switch = helpers.load_with_stubs("ui.menu.remap_switch")
	return switch, seen
end

--- Builds a remap owner double settling every request with one result.
--- @param enabled boolean Current switch state.
--- @param ok boolean Terminal result.
--- @return table karabiner
--- @return table requests
local function owner(enabled, ok)
	local requests = {}
	return {
		get_enabled = function() return enabled end,
		set_enabled = function(value, on_done)
			requests[#requests + 1] = value
			on_done(ok, ok and "stopped" or "rules-not-removed: unprovable")
			return true
		end,
		remove_from_karabiner = function(on_done)
			requests[#requests + 1] = "remove"
			on_done(ok, ok and "removed" or "karabiner.json could not be read", 0)
			return ok
		end,
	}, requests
end

helpers.describe("« Ergopti uses Karabiner » menu commands", function()
	helpers.it("turns the integration off and confirms only after the owner removed the rules", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local switch, seen = load_switch()
			local karabiner, requests = owner(true, true)
			helpers.assert_true(switch.toggle(karabiner, function() seen.refreshes = seen.refreshes + 1 end))
			helpers.assert_eq(requests[1], false)
			helpers.assert_eq(#seen.notices, 1)
			helpers.assert_eq(seen.notices[1].message, "notify.karabiner.removed")
			helpers.assert_eq(seen.refreshes, 1)
			helpers.assert_eq(#seen.errors, 0)
		end)
	end)

	helpers.it("turns the integration on without a removal confirmation", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local switch, seen = load_switch()
			local karabiner, requests = owner(false, true)
			switch.toggle(karabiner, nil)
			helpers.assert_eq(requests[1], true)
			helpers.assert_eq(#seen.notices, 0)
		end)
	end)

	helpers.it("reports a refused transition as an error, never as a confirmation", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local switch, seen = load_switch()
			local karabiner = owner(true, false)
			switch.toggle(karabiner, nil)
			switch.remove(karabiner, nil)
			helpers.assert_eq(#seen.notices, 0)
			helpers.assert_eq(#seen.errors, 2)
		end)
	end)

	helpers.it("confirms an explicit removal and refuses without an owner", function()
		helpers.with_stub_scope(OWNED_MODULES, function()
			local switch, seen = load_switch()
			local karabiner, requests = owner(false, true)
			helpers.assert_true(switch.remove(karabiner, nil))
			helpers.assert_eq(requests[1], "remove")
			helpers.assert_eq(#seen.notices, 1)

			helpers.assert_true(switch.toggle(nil, nil) == false)
			helpers.assert_true(switch.remove({}, nil) == false)
			helpers.assert_eq(#seen.errors, 2)
			helpers.assert_true(switch.is_enabled(nil) == false)
		end)
	end)
end)


local with_remap_fixture = require("tests.support.remap_transaction_fixture")

--- Joins the real menu and remap transaction without native lease or file effects.
local function with_real_switch(options, callback)
	helpers.with_stub_scope(OWNED_MODULES, function()
		with_remap_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap(options)
			local switch, seen = load_switch()
			callback(switch, seen, remap, calls)
			helpers.assert_eq(calls.execute, 0, "the transaction must not operate stock Karabiner")
		end)
	end)
end

helpers.describe("Karabiner OFF menu owns the real retirement transaction", function()
	helpers.it("confirms only after STOPPED, guardian retirement and owned rule removal", function()
		with_real_switch({ initially_enabled = true, unregister_mode = "async" }, function(switch, seen, remap, calls)
			helpers.assert_true(switch.toggle(remap, function() seen.refreshes = seen.refreshes + 1 end))
			helpers.assert_eq(calls.stop, 1)
			helpers.assert_eq(calls.stop_reasons[1], "integration_disabled")
			helpers.assert_nil(calls.unregister_guardian)
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(#calls.rule_removals, 0)
			helpers.assert_eq(#seen.notices, 0)
			helpers.assert_eq(seen.refreshes, 0)
			calls.finish_stop(true)
			helpers.assert_eq(calls.unregister_guardian, 1)
			helpers.assert_true(remap.get_enabled())
			helpers.assert_eq(calls.save, 0)
			helpers.assert_eq(#calls.rule_removals, 0)
			helpers.assert_eq(#seen.notices, 0)
			local opposite
			helpers.assert_eq(remap.set_enabled(true, function(ok) opposite = ok end), false)
			helpers.assert_eq(opposite, false)
			calls.unregister_callback(true, "unregistered")
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(calls.lease_phase, "idle")
			helpers.assert_true(helpers.deep_equal(calls.saved_enabled, { false }))
			helpers.assert_eq(#calls.rule_removals, 1)
			helpers.assert_eq(#seen.notices, 1)
			helpers.assert_eq(seen.notices[1].message, "notify.karabiner.removed")
			helpers.assert_eq(seen.refreshes, 1)
			helpers.assert_eq(#seen.errors, 0)
		end)
	end)

	for _, refused in ipairs({ "stop", "guardian", "guardian_throw", "guardian_request", "persist" }) do
		helpers.it("does not confirm OFF after " .. refused .. " refusal", function()
			local options = { initially_enabled = true, unregister_mode = "async" }
			if refused == "guardian_throw" then options.unregister_mode = "throw" end
			if refused == "guardian_request" then options.unregister_mode = "refuse" end
			if refused == "persist" then options.save_succeeds = false end
			with_real_switch(options, function(switch, seen, remap, calls)
				switch.toggle(remap, function() seen.refreshes = seen.refreshes + 1 end)
				calls.finish_stop(refused ~= "stop", "owned-stop-result")
				if refused == "guardian" then calls.unregister_callback(false, "owned-guardian-refusal") end
				if refused == "persist" then calls.unregister_callback(true, "unregistered") end
				helpers.assert_eq(#seen.notices, 0)
				helpers.assert_eq(seen.refreshes, 0, "failure cannot settle before recovery ownership")
				helpers.assert_eq(#calls.rule_removals, 0)
				helpers.assert_true(remap.get_enabled())
				helpers.assert_eq(calls.start_paused, 1)
				calls.set_save_succeeds(true)
				calls.deliver_ready()
				calls.deliver_resumed()
				helpers.assert_eq(#seen.notices, 0)
				helpers.assert_eq(#seen.errors, 1)
				helpers.assert_eq(seen.refreshes, 1)
				helpers.assert_true(remap.get_enabled())
			end)
		end)
	end

	helpers.it("reports removal refusal while keeping the exact stopped OFF state", function()
		with_real_switch({ initially_enabled = true, unregister_mode = "async", rule_removal_succeeds = false },
			function(switch, seen, remap, calls)
				switch.toggle(remap, function() seen.refreshes = seen.refreshes + 1 end)
				calls.finish_stop(true)
				calls.unregister_callback(true, "unregistered")
				helpers.assert_eq(remap.get_enabled(), false)
				helpers.assert_eq(calls.lease_phase, "idle")
				helpers.assert_eq(calls.unregister_guardian, 1)
				helpers.assert_eq(#calls.rule_removals, 1)
				helpers.assert_eq(#seen.notices, 0)
				helpers.assert_eq(#seen.errors, 1)
				helpers.assert_eq(seen.refreshes, 1)
				helpers.assert_eq(calls.start_paused, 0)
			end)
	end)
end)
