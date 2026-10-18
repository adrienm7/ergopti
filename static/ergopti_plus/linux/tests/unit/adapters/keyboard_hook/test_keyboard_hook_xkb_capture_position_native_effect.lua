--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_xkb_capture_position_native_effect.lua

--- ==============================================================================
--- MODULE: Keyboard Hook to XKB Capture Integration Tests
--- DESCRIPTION:
--- Pins the join between raw evdev routing and the stateful XKB adapter. The XKB
--- unit tests prove state semantics; these cases prove keyboard_hook does not
--- bypass that state for modifiers, locks, releases, repeats or shortcuts.
---
--- ROOT CAUSE ENCODED:
--- The old hook returned early for modifiers and CapsLock, discarded releases,
--- and resolved printable keys through a static table. Even a correct XKB
--- adapter would therefore drift immediately if the hook forwarded only the
--- events that happened to produce text.
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.keyboard_hook_xkb_capture_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_xkb_capture_fixture")
local helpers, key, with_position_capture =
	Fixture.helpers, Fixture.key, Fixture.with_position_capture




helpers.describe("Position capture native effect ownership", function()
	helpers.it("refuses a replaced native effect port and permits a fresh original request after restoration", function()
		with_position_capture(nil, function(s)
			local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "modules.gestures.manager",
				"infra.paths", "infra.i18n", "logger.shim" }
			local previous = {}; for _, name in ipairs(names) do previous[name] = { package.loaded[name] } end
			local host, receipt, epoch, sends, writes, paused = nil, {}, 0, {}, 0, false
			local called, detail = pcall(function()
				package.loaded["ui.webview_manager"] = { native_available = function() return true end,
					current_epoch = function() return epoch > 0 and epoch or nil end,
					page_current = function(_, exact) return epoch > 0 and epoch == exact end,
					show = function() epoch = 53; return host.on_window_acquiring(epoch) end,
					hide = function(_, exact) if exact ~= epoch then return false end; local old = epoch; epoch = 0; host.on_window_closed(old); return true end,
					eval_js = function(_, script) sends[#sends + 1] = script; return true end }
				package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end, get_action_label = function(action) return action end }
				package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["logger.shim"] = helpers.make_logger_stub()
				host = helpers.load_module("ui.physical_shortcuts.bridge")
				local scope = { physical_delivery_available = function() return true end,
					capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
					editor_source_current = function(exact) return rawequal(exact, receipt) end,
					edit = function() writes = writes + 1; return false end }
				helpers.assert_true(host.open({ scope = scope, is_paused = function() return paused end }),
					"controlled host prerequisite is not public native delivery qualification")
				local function message(value) return host.on_message(value, {}, { app_name = "physical_shortcuts", epoch = epoch }) end
				helpers.assert_true(message({ action = "ready" }))
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 7 } }))
				local manager = package.loaded["ui.webview_manager"]
				local original_eval = manager.eval_js
				local foreign_calls = 0
				manager.eval_js = function(_, script)
					foreign_calls = foreign_calls + 1
					sends[#sends + 1] = script
					return true
				end
				s.edge("b", 42, 1, 10); s.edge("a", 36, 1, 20)
				print("INDEPENDENT_FOREIGN_EFFECT_CALLS", foreign_calls, "WRITES", writes)
				manager.eval_js = original_eval
				helpers.assert_eq(foreign_calls, 0, "replacement native effect port must not receive physical position")
				for _, script in ipairs(sends) do
					helpers.assert_true(not script:match("^captured%("), "refused event reaches no retained or foreign page effect")
				end
				helpers.assert_eq(writes, 0, "effect replacement never authorizes a publisher")
				s.edge("a", 36, 0, 30); s.edge("b", 42, 0, 40)
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 8 } }), "original port restoration permits a separate observation")
				s.edge("b", 42, 1, 50); s.edge("a", 36, 1, 60)
				local json = sends[#sends]:match("^captured%((.*)%)$")
				helpers.assert_true(type(json) == "string", "actual original Hook emits through the retained page controller")
				local packet = require("json").decode(json)
				helpers.assert_eq(packet.code, "KeyJ", "original native36 crosses the shared registry")
				helpers.assert_eq(packet.mods, { shift = true }, "another original physical source owns Shift")
				helpers.assert_eq(packet.request_id, 8, "page request identity survives all producers")
				helpers.assert_eq(writes, 0, "joint capture publishes no assignment, parameter or output")
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 9 } }))
				local sent = #sends
				paused = true
				s.edge("a", 37, 1, 70)
				helpers.assert_eq(#sends, sent, "live pause withdraws the actual host enrollment before Reader delivery")
				helpers.assert_true(host.close(), "page retirement cancels only observation")
				s.edge("a", 36, 0, 80); s.edge("b", 42, 0, 90)
				helpers.assert_eq(s.rows[#s.rows - 1], { 36, 0 }, "closing page cannot orphan primary physical UP")
				helpers.assert_eq(s.rows[#s.rows], { 42, 0 }, "closing page cannot orphan modifier physical UP")
			end)
			if host then host.close() end
			for _, name in ipairs(names) do package.loaded[name] = previous[name][1] end
			if not called then error(detail, 0) end
		end)
	end)

	helpers.it("refuses effect replacement inside an original canonical getter before delivery", function()
		with_position_capture(nil, function(s)
			local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "modules.gestures.manager",
				"infra.paths", "infra.i18n", "logger.shim" }
			local previous = {}; for _, name in ipairs(names) do previous[name] = { package.loaded[name] } end
			local host, receipt, epoch, sends, writes, paused = nil, {}, 0, {}, 0, false
			local replace_on_current
			local called, detail = pcall(function()
				package.loaded["ui.webview_manager"] = { native_available = function() return true end,
					current_epoch = function() return epoch > 0 and epoch or nil end,
					page_current = function(_, exact) return epoch > 0 and epoch == exact end,
					show = function() epoch = 53; return host.on_window_acquiring(epoch) end,
					hide = function(_, exact) if exact ~= epoch then return false end; local old = epoch; epoch = 0; host.on_window_closed(old); return true end,
					eval_js = function(_, script) sends[#sends + 1] = script; return true end }
				package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end, get_action_label = function(action) return action end }
				package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["logger.shim"] = helpers.make_logger_stub()
				host = helpers.load_module("ui.physical_shortcuts.bridge")
				local scope = { physical_delivery_available = function() return true end,
					capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
					editor_source_current = function(exact)
						if replace_on_current then local replace = replace_on_current; replace_on_current = nil; replace() end
						return rawequal(exact, receipt)
					end,
					edit = function() writes = writes + 1; return false end }
				helpers.assert_true(host.open({ scope = scope, is_paused = function() return paused end }),
					"controlled host prerequisite is not public native delivery qualification")
				local function message(value) return host.on_message(value, {}, { app_name = "physical_shortcuts", epoch = epoch }) end
				helpers.assert_true(message({ action = "ready" }))
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 7 } }))
				local manager = package.loaded["ui.webview_manager"]
				local original_eval = manager.eval_js
				local foreign_calls = 0
				replace_on_current = function() manager.eval_js = function(_, script)
					foreign_calls = foreign_calls + 1
					sends[#sends + 1] = script
					return true
				end end
				s.edge("b", 42, 1, 10); s.edge("a", 36, 1, 20)
				print("INDEPENDENT_FOREIGN_EFFECT_CALLS", foreign_calls, "WRITES", writes)
				manager.eval_js = original_eval
				helpers.assert_eq(foreign_calls, 0, "replacement native effect port must not receive physical position")
				for _, script in ipairs(sends) do
					helpers.assert_true(not script:match("^captured%("), "refused event reaches no retained or foreign page effect")
				end
				helpers.assert_eq(writes, 0, "effect replacement never authorizes a publisher")
				s.edge("a", 36, 0, 30); s.edge("b", 42, 0, 40)
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 8 } }), "original port restoration permits a separate observation")
				s.edge("b", 42, 1, 50); s.edge("a", 36, 1, 60)
				local json = sends[#sends]:match("^captured%((.*)%)$")
				helpers.assert_true(type(json) == "string", "actual original Hook emits through the retained page controller")
				local packet = require("json").decode(json)
				helpers.assert_eq(packet.code, "KeyJ", "original native36 crosses the shared registry")
				helpers.assert_eq(packet.mods, { shift = true }, "another original physical source owns Shift")
				helpers.assert_eq(packet.request_id, 8, "page request identity survives all producers")
				helpers.assert_eq(writes, 0, "joint capture publishes no assignment, parameter or output")
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 9 } }))
				local sent = #sends
				paused = true
				s.edge("a", 37, 1, 70)
				helpers.assert_eq(#sends, sent, "live pause withdraws the actual host enrollment before Reader delivery")
				helpers.assert_true(host.close(), "page retirement cancels only observation")
				s.edge("a", 36, 0, 80); s.edge("b", 42, 0, 90)
				helpers.assert_eq(s.rows[#s.rows - 1], { 36, 0 }, "closing page cannot orphan primary physical UP")
				helpers.assert_eq(s.rows[#s.rows], { 42, 0 }, "closing page cannot orphan modifier physical UP")
			end)
			if host then host.close() end
			for _, name in ipairs(names) do package.loaded[name] = previous[name][1] end
			if not called then error(detail, 0) end
		end)
	end)
end)

