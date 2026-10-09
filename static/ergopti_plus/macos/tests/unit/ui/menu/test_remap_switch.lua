--- tests/unit/ui/menu/test_remap_switch.lua

--- ==============================================================================
--- MODULE: Remap Switch Menu Commands Tests
--- DESCRIPTION:
--- The Configuration rows only ask the remap owner and report its terminal:
--- a removal is confirmed after the owner reported it, and every refusal is
--- an error (which the shared error UI surfaces), never a confirmation.
--- ==============================================================================

local helpers, runtime_inputs = require("tests.support.remap_menu_runtime_inputs").bind(require("tests.helpers"))

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
		get_runtime = runtime_inputs.get_runtime,
		shared_runtime_selected = runtime_inputs.shared_runtime_selected,
		runtime_unavailable_reason = runtime_inputs.runtime_unavailable_reason,
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
