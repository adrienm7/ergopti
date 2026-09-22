--- tests/unit/ui/test_healthcheck_permissions.lua

--- ==============================================================================
--- MODULE: Healthcheck reports the privacy permissions (macOS)
--- DESCRIPTION:
--- A packaged ErgoptiPlus.app without Screen Recording showed the Ctrl+H
--- selector and left nothing on the clipboard, and no diagnostic said why. The
--- healthcheck now reports the Screen Recording and Accessibility state of the
--- runtime itself, without ever prompting.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body with the real healthcheck modules over stubbed permission adapters.
--- @param states table accessibility and screen_recording native results.
--- @param body function Receives (H, core, prompts).
local function with_healthcheck(states, body)
	local saved, prior_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local prompts = {}
	local ok, err = xpcall(function()
		helpers.load_with_stubs("infra.logger")
		local logger = helpers.make_logger_stub()
		logger.ring_buffer_snapshot = function() return {} end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.accessibility_permission"] = {
			is_trusted = function() return table.unpack(states.accessibility, 1, 2) end,
			request_prompt = function() prompts[#prompts + 1] = "accessibility" return true end,
		}
		package.loaded["adapters.screen_capture"] = {
			permission_state = function() return table.unpack(states.screen_recording, 1, 2) end,
			request_permission = function() prompts[#prompts + 1] = "screen" return true end,
		}
		package.loaded["ui.healthcheck.core"] = nil
		package.loaded["ui.healthcheck.helpers"] = nil
		local H = require("ui.healthcheck.helpers")
		local core = require("ui.healthcheck.core")
		body(H, core, prompts)
	end, debug.traceback)
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("healthcheck: macOS privacy permissions", function()
	helpers.it("reports a missing Screen Recording grant without prompting", function()
		with_healthcheck({ accessibility = { true }, screen_recording = { false } },
			function(H, _, prompts)
				local permissions = H.collect_permissions()
				helpers.assert_eq(permissions.screen_recording, "missing")
				helpers.assert_eq(permissions.accessibility, "granted")
				helpers.assert_eq(#prompts, 0, "a diagnostic must never show a macOS prompt")
			end)
	end)

	helpers.it("reports a failed query as unknown with its detail", function()
		with_healthcheck({ accessibility = { nil, "ax down" }, screen_recording = { nil, "tcc down" } },
			function(H)
				local permissions = H.collect_permissions()
				helpers.assert_eq(permissions.screen_recording, "unknown (tcc down)")
				helpers.assert_eq(permissions.accessibility, "unknown (ax down)")
			end)
	end)

	helpers.it("puts the permission state in the snapshot and the plain-text report", function()
		with_healthcheck({ accessibility = { true }, screen_recording = { false } },
			function(H, core)
				-- Isolate every unrelated collector; the permission one stays real.
				local real_permissions = H.collect_permissions
				for name, value in pairs(H) do
					if type(value) == "function" and name ~= "format_uptime" then
						H[name] = function() return {} end
					end
				end
				H.collect_permissions = real_permissions
				local snapshot = core.run()
				helpers.assert_eq(snapshot.permissions.screen_recording, "missing")
				local plain = core.format_plain(snapshot)
				helpers.assert_contains(plain, "Screen Recording : missing")
				helpers.assert_contains(plain, "Accessibility    : granted")
			end)
	end)
end)
