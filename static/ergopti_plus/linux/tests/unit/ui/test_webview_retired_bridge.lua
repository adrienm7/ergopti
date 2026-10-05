--- tests/unit/ui/test_webview_retired_bridge.lua

--- ==============================================================================
--- MODULE: Native WebView Message Epoch Retirement
--- DESCRIPTION:
--- A queued message must retain its native page epoch after the window closes.
--- Legacy epochless calls remain available to existing bridge consumers.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Supplies an owned bridge and the existing native-creator seam.
--- @param run function Receives the manager and recorded handler calls.
local function with_manager(run)
	local manager = helpers.load_module_with_dependency("ui.webview_manager", "lgi", false)
	manager.build_page_html = function() return "owned page fixture" end
	manager._create_gtk_window = function() return true end
	local calls = {}
	local name = "ui.metrics_typing.bridge"
	local previous = package.loaded[name]
	package.loaded[name] = {
		bridge_name = "metrics_typing_bridge",
		on_message = function(payload, _, context)
			calls[#calls + 1] = { payload = payload, epoch = context.epoch }
			return "accepted"
		end,
	}
	local ok, detail = xpcall(function() run(manager, calls) end, debug.traceback)
	package.loaded[name] = previous
	if not ok then error(detail, 0) end
end

helpers.describe("native bridge messages retain their page epoch", function()
	helpers.it("linux-retired-bridge: refuses a native message after public hide", function()
		with_manager(function(manager, calls)
			helpers.assert_true(manager.show("metrics_typing", "en"))
			local epoch = manager.current_epoch("metrics_typing")
			helpers.assert_true(manager.hide("metrics_typing"))
			helpers.assert_nil(manager.route_message("metrics_typing", "metrics_typing_bridge", "queued", epoch))
			helpers.assert_eq(#calls, 0)
		end)
	end)
	helpers.it("linux-retired-bridge: refuses an epoch without a live page", function()
		with_manager(function(manager, calls)
			helpers.assert_nil(manager.route_message("metrics_typing", "metrics_typing_bridge", "queued", 41))
			helpers.assert_eq(#calls, 0)
		end)
	end)
	helpers.it("linux-retired-bridge: refuses a replaced native page", function()
		with_manager(function(manager, calls)
			helpers.assert_true(manager.show("metrics_typing", "en"))
			local epoch = manager.current_epoch("metrics_typing")
			helpers.assert_true(manager.hide("metrics_typing"))
			helpers.assert_true(manager.show("metrics_typing", "en"))
			helpers.assert_true(manager.current_epoch("metrics_typing") > epoch)
			helpers.assert_nil(manager.route_message("metrics_typing", "metrics_typing_bridge", "queued", epoch))
			helpers.assert_eq(#calls, 0)
		end)
	end)
	helpers.it("linux-retired-bridge: accepts the current native page", function()
		with_manager(function(manager, calls)
			helpers.assert_true(manager.show("metrics_typing", "en"))
			local epoch = manager.current_epoch("metrics_typing")
			helpers.assert_eq(manager.route_message("metrics_typing", "metrics_typing_bridge", "live", epoch), "accepted")
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(calls[1].epoch, epoch)
		end)
	end)
	helpers.it("linux-retired-bridge: preserves legacy epochless routing", function()
		with_manager(function(manager, calls)
			helpers.assert_eq(manager.route_message("metrics_typing", "metrics_typing_bridge", "legacy"), "accepted")
			helpers.assert_eq(#calls, 1)
			helpers.assert_nil(calls[1].epoch)
		end)
	end)
end)
