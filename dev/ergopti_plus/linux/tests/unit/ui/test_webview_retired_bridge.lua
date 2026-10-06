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

--- Uses actual page epochs, close routing and bridge session ownership.
--- Only native creation, HTML loading and JavaScript presentation are controlled.
--- @param run function Receives the actual bridge, manager and presentation receipts.
local function with_download_page(run)
	local names = { "ui.webview_manager", "ui.download_window.bridge" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, detail = xpcall(function()
		local manager = helpers.load_module_with_dependency("ui.webview_manager", "lgi", false)
		manager.build_page_html = function() return "owned download page fixture" end
		manager._create_gtk_window = function() return true end
		local world = { evaluated = {}, cancellations = 0 }
		manager.eval_js = function(app, code)
			if manager.current_epoch(app) == nil then return false end
			world.evaluated[#world.evaluated + 1] = code
			return true
		end
		local bridge = helpers.load_module("ui.download_window.bridge")
		world.show = function(label)
			return bridge.show({ kind = "ollama_model", label = label or "Owned page fixture",
				on_cancel = function() world.cancellations = world.cancellations + 1; return true end })
		end
		world.ready = function()
			return manager.route_message("download_window", "dl_bridge", "ready",
				manager.current_epoch("download_window"))
		end
		run(bridge, manager, world)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("download progress native page closure", function()
	helpers.it("linux-download-page-close: pre-ready close preserves background completion", function()
		with_download_page(function(bridge, manager, world)
			local id = world.show()
			helpers.assert_true(type(id) == "number")
			helpers.assert_true(manager.hide("download_window"))
			helpers.assert_true(bridge.complete(id, true, "Installed after page close"))
			helpers.assert_eq(bridge.session_id(), id)
			helpers.assert_eq(#world.evaluated, 0)
			helpers.assert_eq(world.cancellations, 0)
		end)
	end)
	helpers.it("linux-download-page-close: ready close acknowledges complete without a stale push", function()
		with_download_page(function(bridge, manager, world)
			local id = world.show()
			helpers.assert_true(world.ready().pushed)
			local pushes = #world.evaluated
			helpers.assert_true(manager.hide("download_window"))
			helpers.assert_true(bridge.complete(id, true, "Installed after ready page close"))
			helpers.assert_eq(#world.evaluated, pushes)
			helpers.assert_eq(world.cancellations, 0)
		end)
	end)
	helpers.it("linux-download-page-close: ready close permits exact operation retirement", function()
		with_download_page(function(bridge, manager, world)
			local id = world.show()
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(manager.hide("download_window"))
			helpers.assert_true(bridge.complete(id, true, "Installed"))
			helpers.assert_true(bridge.retire(id))
			helpers.assert_nil(bridge.on_message("ready"))
			helpers.assert_eq(world.cancellations, 0)
		end)
	end)
	helpers.it("linux-download-page-close: focus reopens a fresh page with retained terminal data", function()
		with_download_page(function(bridge, manager, world)
			local id = world.show()
			local first = manager.current_epoch("download_window")
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(manager.hide("download_window"))
			helpers.assert_true(bridge.complete(id, true, "Installed in background"))
			helpers.assert_true(bridge.focus(id))
			helpers.assert_true(manager.current_epoch("download_window") > first)
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(world.evaluated[#world.evaluated]:find('done(true', 1, true) ~= nil)
		end)
	end)
	helpers.it("linux-download-page-close: delayed old close cannot clear reopened readiness", function()
		with_download_page(function(bridge, manager, world)
			local id = world.show()
			local first = manager.current_epoch("download_window")
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(manager.hide("download_window"))
			helpers.assert_true(bridge.focus(id))
			helpers.assert_true(world.ready().pushed)
			helpers.assert_eq(bridge.on_window_closed(first), false)
			local pushes = #world.evaluated
			helpers.assert_true(bridge.update(id, 42, "Current reopened progress"))
			helpers.assert_eq(#world.evaluated, pushes + 1)
			helpers.assert_true(bridge.complete(id, true, "Installed"))
		end)
	end)
	helpers.it("linux-download-page-close: delayed close cannot clear a foreign session page", function()
		with_download_page(function(bridge, manager, world)
			local old = world.show("First session")
			local first = manager.current_epoch("download_window")
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(bridge.complete(old, true, "First installed"))
			local current = world.show("Second session")
			helpers.assert_true(type(current) == "number" and current ~= old)
			helpers.assert_true(world.ready().pushed)
			helpers.assert_eq(bridge.on_window_closed(first), false)
			local pushes = #world.evaluated
			helpers.assert_eq(bridge.complete(old, true, "Foreign completion"), false)
			helpers.assert_true(bridge.update(current, 57, "Current session progress"))
			helpers.assert_eq(#world.evaluated, pushes + 1)
		end)
	end)
	helpers.it("linux-download-page-close: focusing a live page retains its exact close owner", function()
		with_download_page(function(bridge, manager, world)
			local id = world.show()
			local epoch = manager.current_epoch("download_window")
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(bridge.focus(id))
			helpers.assert_eq(manager.current_epoch("download_window"), epoch)
			helpers.assert_true(manager.hide("download_window", epoch))
			helpers.assert_true(bridge.complete(id, true, "Installed after focused page close"))
		end)
	end)
	helpers.it("linux-download-page-close: closing a page does not infer explicit cancellation", function()
		with_download_page(function(bridge, manager, world)
			local id = world.show()
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(manager.hide("download_window"))
			helpers.assert_true(bridge.focus(id))
			helpers.assert_true(world.ready().pushed)
			local result = manager.route_message("download_window", "dl_bridge",
				{ action = "cancel", session = id }, manager.current_epoch("download_window"))
			helpers.assert_true(result.cancelled)
			helpers.assert_eq(world.cancellations, 1)
		end)
	end)
end)
