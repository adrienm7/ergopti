--- tests/unit/lib/test_vscode_bridge_setup_isolation.lua

--- ==============================================================================
--- MODULE: Regression — a cosmetic notification must not take down the caret bridge
--- DESCRIPTION:
--- `vscode_bridge.M.setup()` chained `install_extension()` and `start_server()`
--- with nothing between them. install_extension ends by telling the user to reload
--- VS Code — a purely cosmetic step — and it did so through `dialog_util.alert`
--- with the argument shape of `hs.alert.show(message, duration)` while that
--- wrapper forwards to `hs.dialog.alert`, whose first parameters are coordinates
--- and a callback. So on exactly the boot that installs or updates the extension,
--- the notification raised, install_extension raised with it, setup() aborted, and
--- `start_server()` never ran: no caret bridge for the whole session.
---
--- ROOT CAUSE ENCODED:
--- A functional step sequenced AFTER a cosmetic one, with no isolation between
--- them — plus one wrapper serving two incompatible call shapes. The assertions
--- below are on whether the server still starts when the notification throws, not
--- on the order of two statements, so any restructuring that keeps the guarantee
--- passes.
---
--- Why it was silent: init.lua's call site is inside a pcall that logs, so the
--- throw produced one line about the bridge failing and nothing about the server
--- never having been reached. The bridge then degrades to the AX caret path, which
--- works well enough that nobody attributed the difference to this boot.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==================================================================
-- ==================================================================
-- ======= 1/ The server starts even when the notice throws =========
-- ==================================================================
-- ==================================================================

--- Loads vscode_bridge with the extension install forced down its "wrote the
--- files" path and with every notification channel raising.
--- @return table bridge, function server_started
local function load_bridge_with_throwing_notice()
	package.loaded["infra.vscode_bridge"] = nil
	package.loaded["infra.logger"] = nil
	_ = helpers.load_with_stubs("infra.logger")

	-- Both plausible notification channels raise, so the test does not encode
	-- WHICH one the fix chooses — only that neither can stop the server.
	package.loaded["infra.dialog_util"] = {
		alert = function() error("dialog raised", 0) end,
		block_alert = function() error("dialog raised", 0) end,
	}
	package.loaded["infra.notifications"] = {
		notify = function() error("notify raised", 0) end,
	}
	package.loaded["infra.i18n"] = { get = function(k) return k end }

	local started = { count = 0 }
	local bridge = helpers.load_with_stubs("infra.vscode_bridge", {
		httpserver = {
			new = function()
				started.count = started.count + 1
				local srv
				srv = {
					setPort     = function(self) return self end,
					setCallback = function(self) return self end,
					setInterface = function(self) return self end,
					start       = function(self) return self end,
					stop        = function(self) return self end,
				}
				return srv
			end,
		},
	})
	return bridge, function() return started.count end
end



--- Runs `fn` with io.open forced so install_extension takes its "wrote the files"
--- path: reads return nil (so the already-up-to-date short-circuit is missed) and
--- writes succeed. Without this the function returns false at its write check and
--- never reaches the notification at all — which is how the first version of the
--- case below passed against the unfixed code.
--- @param fn function
local function with_install_path(fn)
	local real_open = io.open
	io.open = function(path, mode)
		if mode == "w" or mode == "wb" then
			return { write = function() return true end, close = function() return true end }
		end
		return nil
	end
	local ok, err = pcall(fn)
	io.open = real_open
	return ok, err
end

helpers.describe("vscode_bridge: setup() isolates the cosmetic step from the server", function()

	helpers.it("starts the HTTP server even when the reload notice raises", function()
		local bridge, server_started = load_bridge_with_throwing_notice()
		helpers.assert_type(bridge.setup, "function", "vscode_bridge must expose setup()")

		with_install_path(bridge.setup)

		helpers.assert_true(server_started() >= 1,
			"the caret bridge server is the functional half of setup(); a throw in the "
			.. "cosmetic \"reload VS Code\" notice must not be able to prevent it from "
			.. "starting, which is exactly what happened on every boot that installed or "
			.. "updated the extension")
	end)

	helpers.it("still starts the server when nothing throws", function()
		-- Without this case the assertion above would pass against a setup() that
		-- starts the server twice, or against a stub that counts a call nobody made.
		package.loaded["infra.vscode_bridge"] = nil
		package.loaded["infra.dialog_util"] = { alert = function() end, block_alert = function() end }
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["infra.i18n"] = { get = function(k) return k end }

		local started = { count = 0 }
		local bridge = helpers.load_with_stubs("infra.vscode_bridge", {
			httpserver = {
				new = function()
					started.count = started.count + 1
					local srv
					srv = {
						setPort = function(self) return self end,
						setCallback = function(self) return self end,
						setInterface = function(self) return self end,
						start = function(self) return self end,
						stop = function(self) return self end,
					}
					return srv
				end,
			},
		})

		with_install_path(bridge.setup)
		helpers.assert_eq(started.count, 1,
			"exactly one server, on the happy path too")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ One wrapper, one argument shape =======================
-- ==================================================================
-- ==================================================================

helpers.describe("dialog_util.alert: every call site agrees on the shape", function()

	helpers.it("no call site passes a number where the wrapper forwards a string", function()
		-- dialog_util.alert forwards straight to hs.dialog.alert, whose leading
		-- parameters are coordinates and a callback — never (message, duration).
		-- One call site used the hs.alert.show shape instead, which is what raised.
		-- A transient toast belongs on lib.notifications, which every other toast in
		-- the driver already uses.
		local src = helpers.read_driver_source("focus_hammerspoon")
		helpers.assert_true(src ~= nil and src ~= "",
			"dialog_util must be locatable by 'focus_hammerspoon'")

		-- The corpus for the CALL SITES is the whole driver, not just the wrapper's
		-- own file: the mismatch is between a definition here and callers elsewhere.
		local offenders = {}
		for _, rel in ipairs({
			"infra/vscode_bridge.lua", "ui/metrics_apps/init.lua", "modules/keylogger/init.lua",
		}) do
			local fh = io.open(helpers.driver_root() .. rel, "r")
			if fh then
				local code = fh:read("*a"):gsub("%-%-[^\n]*", "")
				fh:close()
				local n = 0
				for args in code:gmatch("dialog[_%w]*%.alert%(([^\n]*)") do
					n = n + 1
					-- A bare numeric literal as the LAST argument is the hs.alert.show
					-- duration, i.e. the wrong wrapper for this call.
					if args:match(",%s*%d+%s*%)") then
						table.insert(offenders, rel .. " -> " .. args:sub(1, 60))
					end
				end
			end
		end

		helpers.assert_eq(#offenders, 0,
			"one wrapper cannot serve two contracts: these pass a duration to a function "
			.. "that forwards to hs.dialog.alert, so the call raises and takes its caller "
			.. "down with it: " .. table.concat(offenders, " | "))
	end)

end)
