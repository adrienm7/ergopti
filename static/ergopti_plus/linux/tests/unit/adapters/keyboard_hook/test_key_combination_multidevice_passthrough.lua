--- tests/unit/adapters/keyboard_hook/test_key_combination_multidevice_passthrough.lua

--- ==============================================================================
--- MODULE: Configured Pair Multi-device Pass-through
--- DESCRIPTION:
--- Saved Manager configurations run through the original Reader, Hook, pair
--- engine and Writer with controlled native syscalls. Per-source admission and
--- cleanup remain original; no physical device or desktop is acquired.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Persists the source that the real configuration owner will read and retain.
--- @param path string Owned fixture file.
--- @param text string Complete canonical configuration.
local function write(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text)); assert(file:close())
end

--- Runs original input consumers and a freshly initialized Manager.
--- @param route string Ordered tap, ordered hold, buffered chord or no binding.
--- @param body function Receives native event controls and lifecycle counters.
local function with_manager(route, body)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	for name in pairs(saved) do
		if name:match("^modules%.") or name:match("^adapters%.") or name:match("^infra%.")
			or name:match("^platform%.remap%.") or name:match("^config_binding") or name == "logger.shim" then package.loaded[name] = nil end
	end
	local config_path, tap_path = os.tmpname(), os.tmpname()
	local manager
	local ok, detail = pcall(function()
		local text = '[shortcuts]\nenabled = true\n'
		if route == "tap" or route == "hold" then
			text = text .. '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "script_reload"\n'
			if route == "hold" then text = text .. '[shortcuts.key_combination_holds]\ncaps_lock_then_tab = "ctrl"\n' end
		elseif route == "chord" then
			text = text .. '[mod_combos]\nenabled = true\nsimultaneous_threshold_ms = 50\nsymmetric = true\n'
				.. '[mod_combos.config.tab_then_caps_lock]\ncombo = "script_reload"\n'
		end
		write(config_path, text)
		write(tap_path, '[tap_hold]\nenabled = true\ninherit_defaults = false\n')
		local paths = require("infra.config_paths")
		local original = paths.config
		paths.config = function(name)
			if name == "config.toml" then return config_path end
			if name == "tap_hold.toml" then return tap_path end
			return original(name)
		end
		local chars = {}
		require("tests.support.input_owner_fixture").with_session({ public_chords = true, keys = {}, position_bits = true,
			on_char = function(char) chars[#chars + 1] = char end }, function(s)
			assert(s.hook.set_remapper(nil))
			local layout = require("adapters.keyboard_layout")
			layout._set_table_for_test({ a = { keycode = 30, mods = {} }, A = { keycode = 30, mods = { "shift" } } })
			s.reloads, s.chars = 0, chars
			local scripts = require("modules.shortcuts.script_actions").new({
				reset = function() error("unexpected pause") end,
				reload = function() s.reloads = s.reloads + 1 end,
				quit = function() error("unexpected quit") end,
			})
			manager = helpers.load_module("platform.remap.tap_hold_manager")
			assert(manager.init({ keyboard_hook = s.hook,
				execute_action = function(action) assert(scripts.handlers[action])() end,
				action_names = function() return { "script_reload" } end,
				on_text_injected = function() error("native pass-through cannot inject text") end,
				defaults_path = require("infra.paths").shared("tap_hold/defaults.toml"), user_path = tap_path }))
			s.manager = manager
			local snapshot = manager.configuration_snapshot()
			helpers.assert_eq(snapshot.combinations.has_bindings(), route ~= "none")
			helpers.assert_eq(type(snapshot.engine.has_combinations) == "function", route ~= "none")
			s.rows = {}
			function s.withdraw_binding() write(config_path, text:gsub('"script_reload"', '"none"')) end
			function s.select(ids)
				package.loaded["modules.hotstrings.device_finder"].find_devices = function()
					local selected = {}; for _, id in ipairs(ids) do selected[#selected + 1] = s.paths[id] end
					return selected, {}
				end
				for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
				helpers.assert_true(s.hook.isRunning())
			end
			body(s)
			assert(manager._reset_for_test()); manager = nil
		end)
	end)
	if manager then pcall(manager._reset_for_test) end
	os.remove(config_path); os.remove(tap_path)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(detail, 0) end
end

--- Counts only the decoded native wire edges for one physical code.
--- @param session table Original native consumer session.
--- @param code integer Native key code.
--- @param value integer Native event value.
--- @return integer count
local function count(session, code, value)
	local total = 0
	for _, row in ipairs(session.rows) do if row[1] == code and row[2] == value then total = total + 1 end end
	return total
end

helpers.describe("configured combinations preserve unrelated source-owned keys", function()
	for _, route in ipairs({ "none", "tap", "hold", "chord" }) do
		for _, code in ipairs({ 30, 54, 29, 100 }) do
			for _, order in ipairs({ { "a", "b" }, { "b", "a" } }) do
				helpers.it("pair-multidevice " .. route .. " code " .. code .. " release " .. order[1] .. order[2], function()
					with_manager(route, function(s)
						s.edge("a", code, 1, 1000); s.edge("b", code, 1, 1010)
						helpers.assert_eq(count(s, code, 1), 1)
						s.edge(order[1], code, 0, 1020)
						helpers.assert_eq(count(s, code, 0), 0, "The surviving physical source still owns the native key bit")
						local role = require("infra.evdev_codes").MODIFIER_OF[code]
						if role then helpers.assert_eq(s.hook.held_modifiers(), { [role] = true }) end
						s.edge(order[2], code, 2, 1030)
						helpers.assert_eq(count(s, code, 2), 1, "The surviving source retains its real autorepeat")
						s.edge(order[2], code, 0, 1040)
						helpers.assert_eq(count(s, code, 0), 1)
						helpers.assert_eq(s.hook.held_modifiers(), {})
						if code == 30 then helpers.assert_eq(s.chars, { "a", "a" }) end
						helpers.assert_eq(s.reloads, 0)
					end)
				end)
			end
		end
	end
	for _, code in ipairs({ 30, 54, 29, 100 }) do
		helpers.it("pair-multidevice source departure retains peer code " .. code, function()
			with_manager("tap", function(s)
				s.edge("a", code, 1, 1000); s.edge("b", code, 1, 1010)
				s.select({ "b" })
				helpers.assert_eq(count(s, code, 0), 0, "Removing one keyboard cannot release the peer's original physical hold")
				s.edge("b", code, 0, 1040)
				helpers.assert_eq(count(s, code, 0), 1)
				helpers.assert_eq(s.hook.held_modifiers(), {})
				helpers.assert_eq(s.reloads, 0)
			end)
		end)
	end
end)

helpers.describe("configured combinations retain their original isolation and buffering", function()
	for _, route in ipairs({ "tap", "hold", "chord" }) do
		helpers.it("pair-multidevice genuine single-source " .. route .. " remains eligible", function()
			with_manager(route, function(s)
				s.edge("a", 58, 1, 1000); s.edge("a", 15, 1, 1010)
				s.edge("a", 15, 0, 1100); s.edge("a", 58, 0, 1110)
				helpers.assert_eq(s.reloads, 1, "Original Manager dispatch reaches the original SCRIPT handler")
				helpers.assert_eq(s.hook.held_modifiers(), {})
			end)
		end)
		helpers.it("pair-multidevice cannot borrow a foreign " .. route .. " prefix", function()
			with_manager(route, function(s)
				s.edge("a", 58, 1, 1000); s.edge("b", 15, 1, 1010)
				s.edge("b", 15, 0, 1100); s.edge("a", 58, 0, 1110)
				helpers.assert_eq(s.reloads, 0)
				helpers.assert_eq(s.hook.held_modifiers(), {})
			end)
		end)
	end
	helpers.it("pair-multidevice held peer prevents buffering until its own final release", function()
		with_manager("chord", function(s)
			s.edge("a", 30, 1, 1000); s.edge("b", 30, 1, 1010); s.edge("a", 30, 0, 1020)
			s.edge("a", 58, 1, 1030)
			helpers.assert_eq(count(s, 58, 1), 1, "A still-held peer prevents enrolling buffered input")
			s.edge("a", 15, 1, 1040); s.edge("a", 15, 0, 1050); s.edge("a", 58, 0, 1060)
			helpers.assert_eq(s.reloads, 0)
			s.edge("b", 30, 0, 1070)
			local before = #s.rows
			s.edge("a", 58, 1, 1100)
			helpers.assert_eq(#s.rows, before, "Final native release restores real buffered admission")
			s.edge("a", 15, 1, 1110); s.edge("a", 15, 0, 1120); s.edge("a", 58, 0, 1130)
			helpers.assert_eq(s.reloads, 1)
		end)
	end)
	helpers.it("pair-multidevice saved source withdrawal still refuses a queued action", function()
		with_manager("chord", function(s)
			s.edge("a", 58, 1, 1000)
			helpers.assert_eq(#s.rows, 0, "Real source-owned buffering must precede withdrawal")
			s.withdraw_binding()
			s.edge("a", 15, 1, 1010); s.edge("a", 15, 0, 1100); s.edge("a", 58, 0, 1110)
			helpers.assert_eq(s.reloads, 0)
		end)
	end)
end)
