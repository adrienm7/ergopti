--- tests/unit/modules/shortcuts/text_actions/test_selection_action_destination.lua

--- ==============================================================================
--- MODULE: Explicit Selection Action Destination
--- DESCRIPTION:
--- Executes the daemon dispatcher, shortcut handlers, clipboard transaction and
--- combo emitter with the real focus guard. Controlled clipboard/native ports
--- prove focus retirement during the existing waits cannot retarget a paste.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.text_owner_fixture")

--- Executes Main's actual initialization call while isolating configuration I/O.
--- @param shortcuts table Real shortcuts manager.
--- @param capture function|nil Live guard capture callback.
local function initialize_from_main(shortcuts, capture)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = file:read("*a"); assert(file:close())
	local call = assert(source:match("\n\t\t(shortcuts%.init%b())"), "Main must initialize shortcuts")
	local environment = {
		secure_focus_guard = { capture_text_owner = capture },
		shortcuts = { init = function(options)
			options.persist = false
			shortcuts.init(options)
		end },
	}
	local chunk
	if loadstring then chunk = assert(loadstring(call)); setfenv(chunk, environment)
	else chunk = assert(load(call, "actual Main shortcuts initialization", "t", environment)) end
	chunk()
end

--- Runs the actual user action chain against controlled desktop boundaries.
--- @param session string X11 or Wayland clipboard backend.
--- @param action string Catalogue action id.
--- @param change string Controlled retirement boundary, or stable.
--- @param body function Receives the observations after dispatch.
local function with_action(session, action, change, body)
	local names = {
		"adapters.shell_runner", "infra.display_server", "adapters.keyboard_layout",
		"adapters.keyboard_hook", "adapters.modifier_broker", "adapters.uinput_writer",
		"adapters.event_loop", "modules.hotstrings.injector", "adapters.clipboard",
		"modules.shortcuts.manager", "modules.gestures.manager", "modules.gestures.combo_emitter",
		"adapters.window_info",
	}
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local injector
	local ok, detail = pcall(function()
		fixture.with(function(guard, state, _, _, watch)
			local world = { clipboard = "saved clipboard", writes = {}, pasted = {}, events = {}, held = {}, reads = 0 }
			local pending, changed = nil, false
			local function retire(point)
				if changed or change ~= point then return end
				changed = true
				if change == "privacy" then state.role = 40 else state.path = "/field/successor" end
				if point == "key-down" then watch.barrier() end
			end
			package.loaded["adapters.shell_runner"] = {
				quote = function(value) return "'" .. value .. "'" end,
				has_command = function() return true end,
				exec_checked = function()
					world.reads = world.reads + 1
					if world.reads == 1 then retire("snapshot") end
					if action == "paste_plain" and world.reads == 1 then
						retire("privacy")
						if change == "read-refused" then return false, "", "controlled clipboard read refusal" end
					end
					return true, world.clipboard
				end,
				with_exact_stdin = function(command, text) pending = text; return command end,
				run = function()
					world.clipboard = pending
					world.writes[#world.writes + 1] = pending
					if #world.writes == 2 then retire("replacement") end
					return true
				end,
			}
			package.loaded["infra.display_server"] = {
				UNKNOWN = "unknown", kind = function() return session end,
				is_x11 = function() return session == "x11" end,
				is_wayland = function() return session == "wayland" end,
			}
			package.loaded["adapters.keyboard_layout"] = { shortcut_keycode = function(_, fallback)
				retire("layout"); return fallback
			end }
			package.loaded["adapters.keyboard_hook"] = {}
			package.loaded["adapters.modifier_broker"] = { for_channel = function() return nil end }
			package.loaded["adapters.uinput_writer"] = {
				is_open = function() return true end,
				emit = function(code, value)
					world.events[#world.events + 1] = { code, value }
					world.held[code] = value == 1 or nil
					if code == 46 and value == 1 then world.clipboard = "source selection" end
					if code == 47 and value == 1 then
						world.pasted[#world.pasted + 1] = { target = state.path, text = world.clipboard }
					end
					if value == 1 then retire("key-down") end
					return true
				end,
			}
			package.loaded["adapters.event_loop"] = { sleep_ms = function(ms)
				if ms == 80 then retire("copy-wait") end
				if ms == 30 then retire("paste-wait"); retire("privacy") end
				return true
			end }
			package.loaded["modules.hotstrings.injector"] = { inject = function()
				error("explicit selection actions must retain the clipboard transaction")
			end }
			if action == "paste_plain" then
				package.loaded["adapters.window_info"] = { focused_app_id = function()
					retire("metrics"); return "owned-editor"
				end }
				local layout = helpers.load_module("adapters.keyboard_layout")
				layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} } })
				package.loaded["adapters.clipboard"] = nil
				injector = helpers.load_module("modules.hotstrings.injector")
				injector._set_uinput(package.loaded["adapters.uinput_writer"])
				injector._set_nanosleep_for_test(function() end)
			end
			for _, name in ipairs({ "adapters.clipboard", "modules.shortcuts.manager",
				"modules.gestures.manager", "modules.gestures.combo_emitter" }) do
				if action ~= "paste_plain" or name ~= "adapters.clipboard" then package.loaded[name] = nil end
			end
			local original = assert(guard.capture_text_owner())
			local Shortcuts = require("modules.shortcuts.manager")
			initialize_from_main(Shortcuts, change ~= "absent" and guard.capture_text_owner or nil)
			local Gestures = require("modules.gestures.manager")
			local handlers = require("modules.shortcuts.action_handlers").compose({}, Shortcuts)
			if action == "paste_plain" then
				local perform = handlers.paste_plain
				handlers.paste_plain = function(...)
					world.action_result = perform(...)
					return world.action_result
				end
			end
			Gestures.init({ enabled = false, persist = false,
				action_handlers = handlers })
			if action == "wrap_selection" then helpers.assert_true(Gestures.set_action_parameter("tap_3", action, "(")) end
			helpers.assert_true(Gestures.execute_action(action, "tap_3"))
			world.original_current = original.current()
			helpers.assert_eq(world.clipboard, "saved clipboard", "retirement must still restore the saved clipboard")
			helpers.assert_eq(next(world.held), nil, "retirement must still release every owned key")
			body(world)
		end)
	end)
	if injector then
		injector._set_uinput(nil)
		assert(injector.close_fast_channel(), "the plain-paste clipboard owner must settle")
		injector._set_nanosleep_for_test(nil)
	end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	helpers.assert_true(ok, tostring(detail))
end

helpers.describe("explicit selection actions retain the originating destination", function()
	for _, session in ipairs({ "x11", "wayland" }) do
		for _, action in ipairs({ "selection_uppercase", "wrap_selection" }) do
			helpers.it("selection-action-owner commits stable " .. session .. " " .. action, function()
				with_action(session, action, "stable", function(world)
					helpers.assert_eq(#world.pasted, 1)
					helpers.assert_eq(world.pasted[1].target, "/field/original")
					helpers.assert_eq(world.pasted[1].text,
						action == "wrap_selection" and "(source selection)" or "SOURCE SELECTION")
					helpers.assert_true(world.original_current)
				end)
			end)
			for _, change in ipairs({ "copy-wait", "paste-wait", "snapshot", "replacement", "layout", "key-down", "privacy", "absent" }) do
				helpers.it("selection-action-owner refuses " .. change .. " " .. session .. " " .. action, function()
					with_action(session, action, change, function(world)
						helpers.assert_eq(#world.pasted, 0, "the original action cannot paste into a successor field")
						if change == "absent" then
							helpers.assert_eq(world.reads, 0, "missing destination authority must refuse before clipboard I/O")
							helpers.assert_eq(#world.events, 0)
						else helpers.assert_true(not world.original_current) end
					end)
				end)
			end
		end
	end
end)

helpers.describe("plain paste retains its destination before reading the clipboard", function()
	for _, session in ipairs({ "x11", "wayland" }) do
		helpers.it("plain-paste-owner commits stable " .. session, function()
			with_action(session, "paste_plain", "stable", function(world)
				helpers.assert_true(world.action_result)
				helpers.assert_eq(world.pasted, { { target = "/field/original", text = "saved clipboard" } })
				helpers.assert_true(world.reads > 0)
				helpers.assert_true(world.original_current)
			end)
		end)
		for _, change in ipairs({ "snapshot", "privacy", "metrics", "absent", "read-refused" }) do
			helpers.it("plain-paste-owner refuses " .. change .. " " .. session, function()
				with_action(session, "paste_plain", change, function(world)
					helpers.assert_eq(world.pasted, {}, "a delayed clipboard read cannot paste into a successor field")
					helpers.assert_eq(world.events, {}, "no synthetic key is allowed after destination refusal")
					helpers.assert_eq(world.writes, {}, "a refused paste cannot take clipboard ownership")
					helpers.assert_eq(world.action_result, false)
					if change == "absent" then helpers.assert_eq(world.reads, 0)
					else helpers.assert_eq(world.reads, 1, "the original clipboard read must actually run") end
					if change ~= "absent" and change ~= "read-refused" then helpers.assert_true(not world.original_current) end
				end)
			end)
		end
	end
end)

--- Runs one compound action through the real dispatcher and text output owners.
--- @param action string Catalogue action id.
--- @param change string Controlled destination retirement or native refusal.
--- @return table world Independently recorded output and handler result.
local function observe_compound_action(action, change)
	local names = { "adapters.shell_runner", "infra.display_server", "adapters.keyboard_hook",
		"adapters.modifier_broker", "adapters.uinput_writer", "adapters.event_loop",
		"modules.hotstrings.injector", "adapters.clipboard", "adapters.keyboard_layout",
		"modules.shortcuts.manager", "modules.gestures.manager", "modules.gestures.combo_emitter",
		"adapters.window_info" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local world = { events = {}, held = {}, downs = {}, changed = false }
	local injector
	local ok, detail = pcall(function()
		fixture.with(function(guard, state, _, _, watch)
			local function retire(point)
				if world.changed or change ~= point then return end
				world.changed = true
				state.path = "/field/successor"
				if change == "password" then state.role = 40 end
				watch.barrier()
				if change == "aba" then state.path = "/field/original"; watch.barrier() end
			end
			package.loaded["adapters.shell_runner"] = {
				quote = function(v) return "'" .. v .. "'" end,
				has_command = function() return false end,
			}
			package.loaded["infra.display_server"] = {
				UNKNOWN = "unknown", kind = function() return "x11" end,
				is_x11 = function() return true end, is_wayland = function() return false end,
			}
			package.loaded["adapters.keyboard_hook"] = {}
			package.loaded["adapters.modifier_broker"] = { for_channel = function() return nil end }
			package.loaded["adapters.event_loop"] = { sleep_ms = function() return true end }
			package.loaded["adapters.window_info"] = { focused_app_id = function()
				retire("metrics"); return "owned-editor"
			end }
			local first_navigation = action == "select_word" and 106 or 102
			local data_count = 0
			local writer = {
				is_open = function() return change ~= "closed" end,
				emit = function(code, value)
					if change == "native-refused" and value == 1 and code == first_navigation then
						world.refused = true; return false
					end
					world.events[#world.events + 1] = { code = code, value = value, target = state.path }
					world.held[code] = value == 1 or nil
					if value == 1 then
						world.downs[#world.downs + 1] = { code = code, target = state.path, after_change = world.changed }
						if code == 10 or code == 11 then data_count = data_count + 1 end
						if code == first_navigation then retire("during-down") end
					elseif code == first_navigation and not world.changed then
						retire("after-navigation"); retire("password"); retire("aba")
					elseif code == 10 and data_count == 1 then retire("after-opening") end
					return true
				end,
			}
			package.loaded["adapters.uinput_writer"] = writer
			local Layout = helpers.load_module("adapters.keyboard_layout")
			Layout._set_table_for_test({ ["("] = { keycode = 10, level = 2, mods = {"shift"} },
				[")"] = { keycode = 11, level = 2, mods = {"shift"} } })
			package.loaded["adapters.clipboard"] = nil
			injector = helpers.load_module("modules.hotstrings.injector")
			injector._set_uinput(writer); injector._set_nanosleep_for_test(function() end)
			for _, name in ipairs({"modules.shortcuts.manager", "modules.gestures.manager", "modules.gestures.combo_emitter"}) do package.loaded[name] = nil end
			local Shortcuts = require("modules.shortcuts.manager")
			initialize_from_main(Shortcuts, change ~= "absent" and guard.capture_text_owner or nil)
			local original = assert(guard.capture_text_owner())
			local handlers = require("modules.shortcuts.action_handlers").compose({}, Shortcuts)
			local perform = assert(handlers[action])
			handlers[action] = function(...)
				world.action_result = perform(...)
				return world.action_result
			end
			local Gestures = require("modules.gestures.manager")
			Gestures.init({ enabled = false, persist = false, action_handlers = handlers })
			world.dispatch_result = Gestures.execute_action(action, "tap_3")
			world.original_current = original.current()
			world.final_field = state.path
		end)
	end)
	if injector then
		injector._set_uinput(nil)
		world.injector_closed = injector.close_fast_channel()
		injector._set_nanosleep_for_test(nil)
	end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
	return world
end

helpers.describe("compound actions retain one originating text destination", function()
	for _, action in ipairs({ "surround_parens", "select_word", "select_line" }) do
		local vectors = { "stable", "after-navigation", "aba", "password", "absent", "metrics", "during-down", "closed", "native-refused" }
		if action == "surround_parens" then vectors[#vectors + 1] = "after-opening" end
		for _, change in ipairs(vectors) do
			helpers.it("compound-action-owner " .. action .. " " .. change, function()
				local observation = observe_compound_action(action, change)
				helpers.assert_eq(next(observation.held), nil, "all acknowledged owned DOWNs must have cleanup UPs")
				helpers.assert_true(observation.injector_closed, "injector owner must be closed")
				if change == "stable" then
					helpers.assert_true(observation.action_result)
					local actual = {}
					for _, event in ipairs(observation.downs) do
						helpers.assert_eq(event.target, "/field/original")
						if event.code ~= 29 and event.code ~= 42 then actual[#actual + 1] = event.code end
					end
					local expected = action == "surround_parens" and { 102, 10, 107, 11, 102 }
						or action == "select_word" and { 106, 105 } or { 102, 107 }
					helpers.assert_eq(actual, expected, "stable operation retains the intended exact sequence")
				elseif change == "closed" or change == "native-refused" then
					helpers.assert_eq(observation.action_result, false)
					if change == "closed" then helpers.assert_eq(#observation.downs, 0) end
				else
					if change ~= "absent" then
						helpers.assert_true(observation.changed, "the intended real focus boundary must run")
						helpers.assert_eq(observation.original_current, false, "an observed successor permanently retires the original owner")
					end
					for _, event in ipairs(observation.downs) do
						helpers.assert_eq(event.after_change, false, "no business DOWN is allowed after original text ownership retired")
					end
					if change == "absent" then helpers.assert_eq(#observation.downs, 0, "missing original authority must refuse before output") end
					helpers.assert_eq(observation.action_result, false, "retired compound operation must not report delivery success")
				end
			end)
		end
	end
end)

--- Executes printable insertion through the daemon's real composed dispatcher.
--- The document is a receiver observation, independent from the retained guard.
--- @param session string Controlled clipboard display backend.
--- @param action string The actual send_* action.
--- @param route string Direct layout text, clipboard text or a named command.
--- @param change string The desktop boundary which retires the original field.
--- @return table observations Independent output, clipboard and owner receipts.
local function observe_configured_insertion(session, action, route, change)
	local names = { "adapters.shell_runner", "infra.display_server", "adapters.keyboard_hook",
		"adapters.modifier_broker", "adapters.uinput_writer", "adapters.event_loop",
		"modules.hotstrings.injector", "adapters.clipboard", "adapters.keyboard_layout",
		"modules.shortcuts.manager", "modules.gestures.manager", "modules.gestures.combo_emitter" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local world = { documents = { ["/field/original"] = "", ["/field/successor"] = "" },
		clipboard = "saved clipboard", events = {}, downs = {}, held = {}, reads = 0, writes = 0, changed = false }
	local injector, configuration_path
	local ok, detail = pcall(function()
		fixture.with(function(guard, state, _, _, watch)
			local original = assert(guard.capture_text_owner())
			local function retire(point)
				local boundary = (change == "password" or change == "aba") and "snapshot" or change
				if world.changed or boundary ~= point then return end
				world.changed = true
				state.path = "/field/successor"
				if change == "password" then state.role = 40 end
				-- Direct per-key admission observes the same resident event a real
				-- watch publishes; blocking clipboard paths must request their probe.
				if point == "after-first" or change == "aba" then watch.barrier() end
				if change == "aba" then state.path = "/field/original"; watch.barrier() end
			end
			local pending
			package.loaded["adapters.shell_runner"] = {
				quote = function(value) return "'" .. value .. "'" end,
				has_command = function() return true end,
				exec_checked = function()
					world.reads = world.reads + 1
					retire("snapshot")
					return true, world.clipboard
				end,
				with_exact_stdin = function(command, text) pending = text; return command end,
				run = function()
					world.clipboard = pending
					world.writes = world.writes + 1
					if world.writes == 1 then retire("publication") end
					return true
				end,
			}
			package.loaded["infra.display_server"] = {
				UNKNOWN = "unknown", kind = function() return session end,
				is_x11 = function() return session == "x11" end,
				is_wayland = function() return session == "wayland" end,
			}
			package.loaded["adapters.keyboard_hook"] = {}
			package.loaded["adapters.modifier_broker"] = { for_channel = function() return nil end }
			package.loaded["adapters.event_loop"] = { sleep_ms = function() return true end }
			local writer = {
				is_open = function() return true end,
				emit = function(code, value)
					if change == "native-refused" and value == 1 and (code == 24 or code == 47) then
						world.native_refused = true; return false
					end
					world.events[#world.events + 1] = { code = code, value = value, target = state.path }
					world.held[code] = value == 1 or nil
					if value == 1 then
						world.downs[#world.downs + 1] = { code = code, target = state.path, retired = world.changed }
						local character = code == 24 and "o" or code == 37 and "k" or nil
						if character then world.documents[state.path] = world.documents[state.path] .. character end
						if code == 47 then world.documents[state.path] = world.documents[state.path] .. world.clipboard end
					elseif code == 24 then retire("after-first") end
					return true
				end,
			}
			package.loaded["adapters.uinput_writer"] = writer
			local layout = helpers.load_module("adapters.keyboard_layout")
			layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} } })
			package.loaded["adapters.clipboard"] = nil
			injector = helpers.load_module("modules.hotstrings.injector")
			injector._set_uinput(writer)
			injector._set_nanosleep_for_test(function() retire("settle") end)
			for _, name in ipairs({ "modules.shortcuts.manager", "modules.gestures.manager", "modules.gestures.combo_emitter" }) do
				package.loaded[name] = nil
			end
			local Shortcuts = require("modules.shortcuts.manager")
			local capture = guard.capture_text_owner
			if change == "absent" then capture = nil
			elseif change == "capture-refused" then capture = function() return nil end
			elseif change == "capture-threw" then capture = function() error("controlled capture refusal") end end
			initialize_from_main(Shortcuts, capture)
			if change == "configuration" then
				configuration_path = os.tmpname()
				local file = assert(io.open(configuration_path, "wb")); assert(file:write("[shortcuts]\nenabled = true\n")); assert(file:close())
				Shortcuts.init({ persist = true, config_path = configuration_path, capture_text_owner = capture })
				world.configuration_token = {}; assert(Shortcuts.acquire_configuration(world.configuration_token))
			end
			local handlers = require("modules.shortcuts.action_handlers").compose({}, Shortcuts)
			local perform = assert(handlers[action])
			handlers[action] = function(...)
				world.action_result = perform(...)
				return world.action_result
			end
			local Gestures = require("modules.gestures.manager")
			Gestures.init({ enabled = false, persist = false, action_handlers = handlers })
			local parameter = route == "clipboard" and "é" or route == "direct" and (action == "send_text" and "ok" or "o") or route
			assert(Gestures.set_action_parameter("tap_3", action, parameter))
			world.dispatch_result = Gestures.execute_action(action, "tap_3")
			if world.configuration_token then assert(Shortcuts.release_configuration(world.configuration_token)) end
			world.original_current = original.current()
			world.final_field = state.path
			world.parameter = parameter
		end)
	end)
	if injector then
		injector._set_uinput(nil)
		world.injector_closed = injector.close_fast_channel()
		injector._set_nanosleep_for_test(nil)
	end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if configuration_path then assert(os.remove(configuration_path)) end
	if not ok then error(detail, 0) end
	return world
end

helpers.describe("configured printable insertions retain their original destination", function()
	for _, action in ipairs({ "send_text", "send_key" }) do
		for _, route in ipairs({ "direct", "clipboard" }) do
			for _, session in ipairs(route == "clipboard" and { "x11", "wayland" } or { "x11" }) do
				local changes = route == "clipboard" and { "stable", "snapshot", "publication", "settle", "password", "aba", "absent", "capture-refused", "capture-threw", "configuration", "native-refused" }
					or { "stable", "absent", "capture-refused", "capture-threw", "configuration", "native-refused" }
				if route == "direct" and action == "send_text" then changes[#changes + 1] = "after-first" end
				for _, change in ipairs(changes) do
					helpers.it("configured-insertion-owner " .. action .. " " .. route .. " " .. session .. " " .. change, function()
						local observation = observe_configured_insertion(session, action, route, change)
						helpers.assert_true(observation.dispatch_result, "the actual gesture dispatcher must invoke the configured action")
						helpers.assert_eq(next(observation.held), nil, "every owned DOWN must have a cleanup UP")
						helpers.assert_true(observation.injector_closed, "the injector's clipboard lifetime must settle")
						helpers.assert_eq(observation.clipboard, "saved clipboard", "even refusal must restore the user's clipboard")
						if change == "stable" then
							helpers.assert_true(observation.action_result)
							helpers.assert_true(observation.original_current)
							helpers.assert_eq(observation.documents["/field/original"], observation.parameter)
							helpers.assert_eq(observation.documents["/field/successor"], "")
						elseif change == "native-refused" then
							helpers.assert_true(observation.native_refused, "the real output transaction must reach the native refusal")
							helpers.assert_eq(observation.action_result, false)
						else
							if change == "snapshot" or change == "publication" or change == "settle" or change == "password"
								or change == "aba" or change == "after-first" then
								helpers.assert_true(observation.changed, "the intended real output boundary must run")
								helpers.assert_eq(observation.original_current, false, "the independent real field owner must retire")
							end
							helpers.assert_eq(observation.documents["/field/successor"], "", "old insertion must never deliver configured bytes into field B (delivery ACK: " .. tostring(observation.action_result) .. ")")
							for _, event in ipairs(observation.downs) do
								helpers.assert_eq(event.retired, false, "no business DOWN is admitted after an observed destination retirement")
							end
							if change == "absent" or change:match("^capture") or change == "configuration" then
								helpers.assert_eq(#observation.events, 0, "missing authority must refuse before reserving output")
								helpers.assert_eq(observation.reads, 0, "missing authority must refuse before reading the clipboard")
							end
							helpers.assert_eq(observation.action_result, false, "destination refusal is not a successful delivery")
						end
					end)
				end
			end
		end
	end
	for _, vector in ipairs({ { "send_key", "Tab", 15 }, { "send_key", "Enter", 28 },
		{ "send_key", "page_down", 109 }, { "send_shortcut", "alt+F4", 62 }, { "send_shortcut", "super+Tab", 15 } }) do
		helpers.it("configured-insertion-owner preserves non-text command " .. vector[1] .. " " .. vector[2], function()
			local observation = observe_configured_insertion("x11", vector[1], vector[2], "capture-threw")
			helpers.assert_true(observation.action_result, "named/global commands do not require a text field owner")
			local found = false
			for _, event in ipairs(observation.downs) do if event.code == vector[3] then found = true end end
			helpers.assert_true(found, "the actual requested command must still reach the receiver")
			helpers.assert_eq(next(observation.held), nil)
			helpers.assert_true(observation.injector_closed)
			helpers.assert_eq(observation.reads, 0)
		end)
	end
end)
