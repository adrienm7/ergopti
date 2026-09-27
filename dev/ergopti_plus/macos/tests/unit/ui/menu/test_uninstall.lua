--- tests/unit/ui/menu/test_uninstall.lua

--- ==============================================================================
--- MODULE: Confirmed Uninstall Menu Tests
--- DESCRIPTION:
--- Exercises the native authorization protocol with inert tasks and dialogs.
--- No test launches a worker, exits the driver, or removes an application.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fixture(options)
	options = options or {}
	package.loaded["ui.menu.uninstall"] = nil
	local module = require("ui.menu.uninstall")
	local calls = { exits = 0, failures = 0, starts = 0, stops = 0, writes = {} }
	local deps = {
		i18n = { get = function(key) return key end },
		logger = { error = function() end, info = function() end },
		lifecycle = {
			is_pending = function() return options.pending == true end,
			request_user_exit = function(reason)
				helpers.assert_eq(reason, "menu_uninstall")
				calls.exits = calls.exits + 1
				return options.exit ~= false
			end,
		},
		resolver = { resolve = function()
			if options.source then return nil, "source tree" end
			return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus", nil, { identity = "exact" }
		end },
		dialog = { block_alert = function(_, _, _, _, style)
			if style == "critical" then calls.failures = calls.failures + 1; return end
			return options.cancel and "button.cancel" or "button.remove"
		end },
		shell = { spawn = function(_, args, done, chunk, environment)
			helpers.assert_eq(args[1], "--uninstall")
			helpers.assert_eq(environment.identity, "exact")
			calls.done, calls.chunk = done, chunk
			return {
				start = function() calls.starts = calls.starts + 1; return options.start ~= false end,
				terminate = function() calls.stops = calls.stops + 1; return true end,
				set_input = function(data)
					calls.writes[#calls.writes + 1] = data
					return options.write ~= false
				end,
			}
		end },
	}
	return module, deps, calls
end

helpers.describe("macOS uninstall", function()
	helpers.it("requires native ACK before controlled quit", function()
		local module, deps, calls = fixture()
		helpers.assert_true(module.run(deps))
		helpers.assert_eq(module.run(deps), false)
		calls.chunk(nil, "REA")
		helpers.assert_eq(#calls.writes, 0)
		calls.chunk(nil, "DY\n")
		helpers.assert_eq(calls.writes[1], "COMMIT\n")
		helpers.assert_eq(calls.exits, 0)
		calls.chunk(nil, "ACK\n")
		helpers.assert_eq(calls.exits, 1)
	end)
	helpers.it("rejects source trees, cancellation and existing terminal owners", function()
		for _, option in ipairs({ "source", "cancel", "pending" }) do
			local module, deps, calls = fixture({ [option] = true })
			helpers.assert_eq(module.run(deps), false)
			helpers.assert_eq(calls.starts, 0)
			helpers.assert_eq(calls.exits, 0)
		end
	end)
	helpers.it("retains the application on failed start or authorization write", function()
		for _, option in ipairs({ "start", "write" }) do
			local module, deps, calls = fixture({ [option] = false })
			module.run(deps)
			if option == "write" then calls.chunk(nil, "READY\n") end
			helpers.assert_eq(calls.exits, 0)
			helpers.assert_eq(calls.failures, 1)
			helpers.assert_eq(calls.stops, 1)
		end
	end)
	helpers.it("revokes malformed and late protocol messages", function()
		local module, deps, calls = fixture()
		module.run(deps)
		calls.chunk(nil, "ACK\n")
		calls.chunk(nil, "READY\nACK\n")
		calls.done(70)
		helpers.assert_eq(calls.exits, 0)
		helpers.assert_eq(calls.failures, 1)
	end)
end)
