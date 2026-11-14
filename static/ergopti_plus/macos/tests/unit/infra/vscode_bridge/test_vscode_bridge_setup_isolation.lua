--- tests/unit/infra/vscode_bridge/test_vscode_bridge_setup_isolation.lua

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
--- passes. The wrapper's own shape is refused at the call by dialog_util.alert,
--- driven in test_dialog_focus_terminal_owner.lua.
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
--- @return table bridge, function server_started, function notice_calls
local function load_bridge_with_throwing_notice()
	package.loaded["infra.vscode_bridge"] = nil
	package.loaded["core.logger.engine.logger"] = nil
	_ = helpers.load_with_stubs("core.logger.engine.logger")

	-- Both plausible notification channels raise, so the test does not encode
	-- WHICH one the fix chooses — only that neither can stop the server.
	package.loaded["infra.dialog_util"] = {
		alert = function() error("dialog raised", 0) end,
		block_alert = function() error("dialog raised", 0) end,
	}
	local notice_count = 0
	package.loaded["infra.notifications"] = {
		notify = function()
			notice_count = notice_count + 1
			error("notify raised", 0)
		end,
	}
	package.loaded["core.i18n.engine.i18n"] = { get = function(k) return k end }

	local started = { count = 0 }
	local bridge = helpers.load_with_stubs("infra.vscode_bridge", {
		httpserver = {
			new = function()
				started.count = started.count + 1
				local listening_port = 0
				local srv
				srv = {
					setPort     = function(self, port) listening_port = port; return self end,
					setCallback = function(self) return self end,
					setInterface = function(self) return self end,
					start       = function(self) return self end,
					getPort     = function() return listening_port end,
					stop        = function(self) listening_port = 0; return self end,
				}
				return srv
			end,
		},
	})
	return bridge,
		function() return started.count end,
		function() return notice_count end
end



--- Runs `fn` with io.open forced so install_extension takes its "wrote the files"
--- path: reads return nil (so the already-up-to-date short-circuit is missed) and
--- writes succeed. Without this the function returns false at its write check and
--- never reaches the notification at all — which is how the first version of the
--- case below passed against the unfixed code.
--- @param fn function
--- @return boolean call_ok Whether setup stayed contained.
--- @return any result Exact setup result or thrown error.
local function with_install_path(fn)
	local real_open = io.open
	local real_execute = os.execute
	local real_rename = os.rename
	local real_remove = os.remove
	io.open = function(path, mode)
		if mode == "w" or mode == "wb" then
			local handle = {}
			handle.write = function(self) return self end
			handle.flush = function() return true end
			handle.close = function() return true end
			return handle
		end
		return nil, "missing", 2
	end
	os.execute = function() return true end
	os.rename = function() return true end
	os.remove = function() return true end
	local ok, err = pcall(fn)
	io.open = real_open
	os.execute = real_execute
	os.rename = real_rename
	os.remove = real_remove
	return ok, err
end

helpers.describe("vscode_bridge: setup() isolates the cosmetic step from the server", function()

	helpers.it("starts the HTTP server even when the reload notice raises", function()
		local bridge, server_started, notice_calls = load_bridge_with_throwing_notice()
		helpers.assert_type(bridge.setup, "function", "vscode_bridge must expose setup()")

		local call_ok, result = with_install_path(bridge.setup)

		helpers.assert_true(call_ok, "setup must contain the cosmetic notification failure")
		helpers.assert_eq(result, true, "setup must return exact success once the server owns its port")
		helpers.assert_eq(notice_calls(), 1,
			"the fixture must reach the throwing cosmetic notification")
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
		package.loaded["core.i18n.engine.i18n"] = { get = function(k) return k end }

		local started = { count = 0 }
		local bridge = helpers.load_with_stubs("infra.vscode_bridge", {
			httpserver = {
				new = function()
					started.count = started.count + 1
					local listening_port = 0
					local srv
					srv = {
						setPort = function(self, port) listening_port = port; return self end,
						setCallback = function(self) return self end,
						setInterface = function(self) return self end,
						start = function(self) return self end,
						getPort = function() return listening_port end,
						stop = function(self) listening_port = 0; return self end,
					}
					return srv
				end,
			},
		})

		local call_ok, result = with_install_path(bridge.setup)
		helpers.assert_true(call_ok, "the positive setup path must stay contained")
		helpers.assert_eq(result, true, "the positive setup path must return exact success")
		helpers.assert_eq(started.count, 1,
			"exactly one server, on the happy path too")
	end)

end)
