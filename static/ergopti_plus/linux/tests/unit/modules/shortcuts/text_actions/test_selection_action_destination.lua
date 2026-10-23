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
