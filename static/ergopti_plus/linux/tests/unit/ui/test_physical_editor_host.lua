--- tests/unit/ui/test_physical_editor_host.lua

--- Checks the actual native host through controlled constructor and cleanup ports.
local helpers = require("tests.helpers")
local Json = require("json")
helpers.describe("Physical shortcut native host ownership", function()
	helpers.it("(physical-editor-ui) refuses stale pages and retains failed native cleanup", function()
		local loaded, original_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local called, detail = pcall(function()
			require("test.physical_editor_host_contract")(helpers, Json,
				function(relative) return helpers.driver_root() .. "/../_shared/" .. relative end,
				function() package.loaded["ui.physical_shortcuts.bridge"] = nil; return require("ui.physical_shortcuts.bridge") end, "linux")
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		_G.hs = original_hs
		if not called then error(detail, 0) end
	end)
end)

helpers.describe("Physical editor position capture host epoch composition", function()
	helpers.it("uses genuine thin-host session guards through explicitly controlled native ports", function()
		local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "adapters.keyboard_hook",
			"modules.gestures.manager", "infra.paths", "infra.i18n", "logger.shim" }
		local saved = {}; for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
		local host, epoch, callback, native_token, guard, cancel_refused, writes, sends = nil, 0, nil, nil, nil, false, 0, 0
		local receipt = {}
		local on_page = nil
		local manager = { native_available = function() return true end,
			current_epoch = function() return epoch > 0 and epoch or nil end,
			page_current = function(_, exact) local valid = epoch > 0 and epoch == exact; if on_page then on_page() end; return valid end,
			show = function() epoch = epoch + 1; return host.on_window_acquiring(epoch) end,
			hide = function(_, exact) if epoch ~= exact then return false end; local old = epoch; epoch = 0; host.on_window_closed(old); return true end,
			eval_js = function() sends = sends + 1; return true end }
		local hook = { position_capture_available = function() return true end,
			capture_position = function(current, receive) guard, callback, native_token = current, receive, {}; return native_token end,
			cancel_position = function(token) return not cancel_refused and rawequal(token, native_token) end }
		local scope = { physical_delivery_available = function() return true end,
			capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
			editor_source_current = function(exact) return rawequal(exact, receipt) end,
			edit = function() writes = writes + 1; return true end }
		local called, detail = pcall(function()
			package.loaded["ui.webview_manager"], package.loaded["adapters.keyboard_hook"] = manager, hook
			package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end, get_action_label = function(action) return action end }
			package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["logger.shim"] = helpers.make_logger_stub()
			host = helpers.load_module("ui.physical_shortcuts.bridge")
			helpers.assert_true(host.open({ scope = scope, is_paused = function() return false end }))
			local function send(message, exact) return host.on_message(message, {}, { app_name = "physical_shortcuts", epoch = exact or epoch }) end
			helpers.assert_true(send({ action = "ready" }))
			helpers.assert_true(send({ action = "capture_position", request = { request_id = 1 } }))
			helpers.assert_true(guard(), "actual shared/native host retains its Manager epoch and canonical receipt")
			helpers.assert_true(callback({ native_code = 36, mods = {} }), "controlled observation passes actual host and shared registry")
			helpers.assert_eq(writes, 0, "host observation is never a native Save or delivery capability")
			helpers.assert_true(not send({ action = "capture_position", request = { request_id = 2 } }, epoch + 1), "foreign page epoch cannot enroll")
			helpers.assert_true(send({ action = "capture_position", request = { request_id = 3 } }), "controlled new request has a separate host guard")
			local original = hook.capture_position
			local foreign = 0
			hook.capture_position = function() foreign = foreign + 1; return {} end
			helpers.assert_true(not guard(), "public Hook replacement cannot retain the host enrollment")
			helpers.assert_true(not callback({ native_code = 36, mods = {} }))
			helpers.assert_eq(foreign, 0, "captured host ports never execute replacement constructors")
			hook.capture_position = original
			local original_manager_epoch = manager.current_epoch
			manager.current_epoch = function() foreign = foreign + 1; return epoch end
			helpers.assert_true(not send({ action = "capture_position", request = { request_id = 4 } }), "message admission rejects a foreign Manager query")
			helpers.assert_eq(foreign, 0, "native page admission never invokes a replaced epoch callback")
			manager.current_epoch = original_manager_epoch
			local original_epoch = epoch
			on_page = function() epoch = epoch + 1; on_page = nil end
			helpers.assert_true(not guard(), "page query cannot change its epoch and still acknowledge the original page")
			epoch = original_epoch

			local previous = sends
			receipt = {}
			helpers.assert_true(not guard(), "canonical source replacement withdraws original request")
			helpers.assert_true(not callback({ native_code = 36, mods = {} }), "late source callback cannot fill current form")
			helpers.assert_eq(sends, previous, "no JavaScript send after stale-source refusal")
			cancel_refused = true
			helpers.assert_true(not host.close(), "controlled cancellation refusal retains exact page owner")
			cancel_refused = false
			helpers.assert_true(host.close(), "original observation and native page cleanup can retry")
			helpers.assert_true(not callback({ native_code = 36, mods = {} }), "closed original page callback cannot publish")
			on_page = function() epoch = epoch + 1; on_page = nil end
			helpers.assert_true(not host.open({ scope = scope, is_paused = function() return false end }),
				"constructor's last page getter cannot revoke its epoch and still report opened")
			epoch = 1
			helpers.assert_true(host.close(), "controlled exact Manager epoch recovery permits retained page cleanup")
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
		if not called then error(detail, 0) end
	end)
end)
