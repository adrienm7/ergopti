--- tests/unit/ui/menu/test_menu_apps_discovery_outcome.lua

--- ==============================================================================
--- MODULE: Bundled App Discovery Outcome Tests
--- DESCRIPTION:
--- Failed enumeration remains retryable and cannot poison the session cache.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_apps(callback)
	local previous_hs = _G.hs
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({ "ui.menu.menu_apps", "infra.logger", "infra.paths",
			"infra.i18n", "infra.manifest_menu", "adapters.task_lifecycle", "infra.text_utils" }, function()
			local state = { calls = {}, warnings = {}, images = {}, app_scans = 0,
				output = "", status = true, kind = "exit", code = 0 }
			local logger = helpers.make_logger_stub()
			logger.warn = function(_, message, ...)
				state.warnings[#state.warnings + 1] = string.format(message, ...)
			end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.paths"] = {}
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.manifest_menu"] = { build = function(_, _, _, _, _, providers)
				return providers.apps_installed()
			end }
			package.loaded["adapters.task_lifecycle"] = {}
			local module = helpers.load_with_stubs("ui.menu.menu_apps", {
				fs = { attributes = function() return { mode = "directory" } end },
				execute = function(command)
					state.calls[#state.calls + 1] = command
					if command:find("*.icns", 1, true) then
						if state.icon_failure then return "/private/Partial.icns\n", nil, "exit", 1 end
						return "", true, "exit", 0
					end
					state.app_scans = state.app_scans + 1
					if state.throw then error("PRIVATE_FAILURE") end
					return state.output, state.status, state.kind, state.code
				end,
				application = { infoForBundlePath = function() return {} end },
				image = { imageFromPath = function(path)
					state.images[#state.images + 1] = path
					return nil
				end },
			})
			callback(module, state, { base_dir = "/virtual/apps-fixture" })
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end

helpers.describe("Bundled app discovery outcome", function()
	for _, mode in ipairs({ "exit", "signal", "throw", "invalid" }) do
		helpers.it("(apps-discovery-outcome) retries after " .. mode .. " without caching partial output", function()
			with_apps(function(module, state, ctx)
				state.output = "/virtual/Partial.app\n"
				state.status = nil
				state.code = 1
				state.kind = mode == "signal" and "signal" or "exit"
				state.throw = mode == "throw"
				if mode == "invalid" then state.status = true; state.output = false end
				module.prime(ctx)
				module.prime(ctx)
				helpers.assert_eq(state.app_scans, 2, "failed scans must remain retryable")
				helpers.assert_eq(#state.warnings, 1, "repeat failures must be bounded")
				helpers.assert_nil(state.warnings[1]:find("PRIVATE", 1, true))
				helpers.assert_nil(state.warnings[1]:find("/private", 1, true))
				helpers.assert_nil(state.warnings[1]:find("/virtual", 1, true))
				state.throw, state.status, state.kind, state.code = false, true, "exit", 0
				state.output = "/virtual/Zebra.app\n/virtual/Alpha.app\n"
				local rows = module.build(ctx).submenu
				helpers.assert_eq(rows[1].label, "Alpha")
				helpers.assert_eq(rows[2].label, "Zebra")
				local count = #state.calls
				module.build(ctx)
				helpers.assert_eq(#state.calls, count, "successful discovery must cache")
			end)
		end)
	end
	helpers.it("(apps-discovery-outcome) discards failed icon output without hiding valid apps", function()
		with_apps(function(module, state, ctx)
			state.output = "/virtual/First.app\n/virtual/Second.app\n"
			state.icon_failure = true
			local rows = module.build(ctx).submenu
			helpers.assert_eq(#rows, 2)
			helpers.assert_eq(rows[1].label, "First")
			helpers.assert_eq(#state.warnings, 1)
			helpers.assert_nil(state.warnings[1]:find("PRIVATE", 1, true))
			helpers.assert_nil(state.warnings[1]:find("/private", 1, true))
			helpers.assert_nil(state.warnings[1]:find("/virtual", 1, true))
			for _, path in ipairs(state.images) do
				helpers.assert_nil(path:find("Partial.icns", 1, true))
			end
		end)
	end)
	helpers.it("(apps-discovery-outcome) caches a successfully empty directory", function()
		with_apps(function(module, state, ctx)
			module.prime(ctx)
			local rows = module.build(ctx).submenu
			helpers.assert_eq(#state.calls, 1)
			helpers.assert_eq(rows[1].disabled, true)
			helpers.assert_eq(#state.warnings, 0)
		end)
	end)
end)
