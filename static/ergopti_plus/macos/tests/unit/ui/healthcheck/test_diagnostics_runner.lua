--- tests/unit/ui/healthcheck/test_diagnostics_runner.lua

--- ==============================================================================
--- MODULE: Diagnostics Runner Tests (macOS)
--- DESCRIPTION:
--- Pins the shared diagnostics action engine (_shared/lua/healthcheck/report.lua)
--- the macOS and Linux report modules build: a runner refuses missing ports, an
--- unknown action completes as a failure instead of vanishing, a URL action
--- opens through the effect kind its port names and a cancelled request never
--- completes.
--- ==============================================================================

local helpers = require("tests.helpers")
local Runner = require("healthcheck.report")

local function silent_logger()
	local logger = {}
	for _, level in ipairs({ "start", "success", "info", "debug", "warn", "error" }) do logger[level] = function() end end
	return logger
end

local function build(effects, extra)
	local ports = {
		logger = silent_logger(), log = "test.runner",
		effects_with = function() return effects end,
		url_effects = (extra and extra.url_effects) or { open_settings = "open" },
		module_current = function() return true end,
		perform_requires_loaded_owner = false,
		reveal_outcome = (extra and extra.reveal_outcome) or function() return false end,
	}
	return Runner.new(ports)
end

local function owner_into(results)
	return { current = function() return true end, complete = function(result) results[#results + 1] = result end }
end

helpers.describe("diagnostics runner (macOS)", function()
	helpers.it("refuses a runner built without its ports", function()
		helpers.assert_contains(tostring(helpers.assert_throws(function() Runner.new({}) end)), "logger")
	end)

	helpers.it("completes an unknown action as a failure", function()
		local results = {}
		build({}).perform({ action = "bogus" }, {}, {}, {}, nil, nil, owner_into(results))
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].ok, false)
	end)

	helpers.it("opens the URL of an action through the effect kind its port names", function()
		local opened, results = {}, {}
		local effects = {
			open = function(target, done) opened[#opened + 1] = { "open", target }; done({ ok = true }); return { cancel = function() end } end,
			open_url = function(target, done) opened[#opened + 1] = { "open_url", target }; done({ ok = true }); return { cancel = function() end } end,
		}
		local runner = build(effects)
		runner.perform({ action = "open_settings", url = "x-settings:" }, {}, {}, {}, nil, nil, owner_into(results))
		runner.perform({ action = "suggest_feature", url = "https://example.test/f" }, {}, {}, {}, nil, nil, owner_into(results))
		helpers.assert_eq(opened[1][1], "open")
		helpers.assert_eq(opened[1][2], "x-settings:")
		helpers.assert_eq(opened[2][1], "open_url")
		helpers.assert_eq(#results, 2)
		helpers.assert_eq(results[1].ok, true)
	end)

	helpers.it("does not know an extra action the port did not declare", function()
		local results = {}
		build({}, { url_effects = {} }).perform({ action = "open_settings", url = "u" }, {}, {}, {}, nil, nil, owner_into(results))
		helpers.assert_eq(results[1].ok, false)
	end)

	helpers.it("never completes a cancelled request", function()
		local results, pending = {}, nil
		local effects = {
			open_url = function(_, done) pending = done; return { cancel = function() end } end,
		}
		local request = build(effects).perform({ action = "suggest_feature", url = "u" }, {}, {}, {}, nil, nil, owner_into(results))
		request.cancel()
		pending({ ok = true })
		helpers.assert_eq(#results, 0)
	end)
end)
