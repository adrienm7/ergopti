--- tests/unit/meta/test_layer_editor_bridge.lua

--- ==============================================================================
--- MODULE: Navigation Layer Editor Bridge (Linux)
--- DESCRIPTION:
--- Drives ui/layer_editor/bridge.lua the way the shared page does, with the
--- real shared host logic, loader and TOML codec, and doubles for the webview
--- manager and the remap manager.
---
--- COVERAGE:
--- 1. The bridge is registered for the page, under the page's bridge name.
--- 2. "ready" sends the user's file and the problems every OS's loader finds.
--- 3. A save is refused, and nothing is written or restarted, when the text is
---    not a string, is too large, names an action outside the vocabulary, or
---    binds something one of the three OSes cannot resolve.
--- 4. End to end: the page's scripted session (_shared/tests/corpus/
---    layer_editor/edited_layers.toml) is saved, the remap manager is asked to
---    reload, the window closes, and the installed native daemon engine emits
---    every Linux keyboard edit.
--- 5. A remap restart that fails keeps the window open.
--- 6. Legends (layer-editor-current-layout-legends): init() carries what the
---    loaded keymap types on every character key (the shared corpus
---    _shared/tests/corpus/layer_editor/legends.json, compiled into an XKB
---    keymap the real keyboard_layout adapter loads), leaves out and reports
---    once the keys it types nothing printable on, names the key whose hold
---    enters the layer in the shipped tap-hold defaults, and answers "legends"
---    with the keymap loaded then.
--- ==============================================================================

local helpers     = require("tests.helpers")
local Json        = require("json")
local TomlCodec   = require("toml_codec")
local Layers      = require("keymap.layers")
local Manager = require("platform.remap.tap_hold_manager")

local SHARED_ROOT = helpers.driver_root() .. "/../_shared"
local FIXTURE = SHARED_ROOT .. "/tests/corpus/layer_editor/edited_layers.toml"
local LEGENDS = SHARED_ROOT .. "/tests/corpus/layer_editor/legends.json"





-- ====================================
-- ====================================
-- ======= 1/ Doubles and setup =======
-- ====================================
-- ====================================

--- Reads a whole file; raises when it cannot.
local function read_file(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("cannot open " .. path .. ": " .. tostring(err)) end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Creates an empty folder of its own, standing for a configuration folder.
local function make_config_dir()
	local dir = os.tmpname()
	os.remove(dir)
	local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
	helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
	return dir
end

local function remove_config_dir(dir)
	os.remove(dir .. "/layers.toml")
	os.remove(dir .. "/tap_hold.toml")
	os.execute('rmdir "' .. dir .. '"')
end

--- A daemon state whose webview and remap managers record what they are asked.
local function make_state(dir)
	local world = { scripts = {}, hidden = 0, restarts = 0, restart_result = true, titles = {} }
	world.state = {
		webview_manager = {
			eval_js = function(app, js)
				world.scripts[#world.scripts + 1] = { app = app, js = js }
				return true
			end,
			hide = function(app)
				world.hidden = world.hidden + 1
				return app == "layer_editor"
			end,
			set_title = function(app, label) world.titles[#world.titles + 1] = app .. "=" .. label end,
		},
		tap_hold = { reload = function()
			world.restarts = world.restarts + 1
			if world.on_reload then return world.on_reload() end
			return world.restart_result
		end },
		paths = { shared_root = function() return SHARED_ROOT end },
		config_paths = { get_config_dir = function() return dir end },
		i18n = { get = function(key) return key end },
		keyboard_layout = { base_symbol = function() return nil end, is_ready = function() return false end },
	}
	return world
end

--- An XKB keymap typing, at level 1, each character of `layout` (code -> text)
--- on its registry key: what `xkbcli dump-keymap` prints, cut to those keys.
local function xkb_keymap(layout)
	local Registry = Json.decode(read_file(SHARED_ROOT .. "/data/keycodes/physical_keys.json"))
	local keycodes, symbols = {}, {}
	for code, text in pairs(layout) do
		local evdev = Registry.keys[code].evdev
		local first = utf8.codepoint(text, 1)
		keycodes[#keycodes + 1] = string.format("\t<K%d> = %d;", evdev, evdev + 8)
		symbols[#symbols + 1] = string.format("\tkey <K%d> { [ U%04X ] };", evdev, first)
	end
	return table.concat({ "xkb_keymap {", 'xkb_keycodes "(unnamed)" {', table.concat(keycodes, "\n"), "};",
		'xkb_symbols "(unnamed)" {', table.concat(symbols, "\n"), "};", "};" }, "\n")
end

--- The payload of the last call the page received to one of its functions.
local function last_call(world, fn_name)
	for i = #world.scripts, 1, -1 do
		local payload = world.scripts[i].js:match("window%." .. fn_name .. "%((.*)%)$")
		if payload then return Json.decode(payload) end
	end
	return nil
end

local function codes(payload)
	local out = {}
	for _, err in ipairs(payload.errors or {}) do out[#out + 1] = err.code end
	table.sort(out)
	return table.concat(out, ",")
end





-- =============================
-- =============================
-- ======= 2/ The bridge =======
-- =============================
-- =============================

helpers.describe("Linux navigation layer editor bridge", function()
	local Bridge = helpers.load_module("ui.layer_editor.bridge")

	helpers.it("is the page's registered bridge", function()
		local WebkitHost = require("ui.webkit_host")
		helpers.assert_eq(Bridge.bridge_name, "layer_editor_bridge")
		helpers.assert_eq(WebkitHost.bridge_for_app("layer_editor"), Bridge.bridge_name)
	end)

	helpers.it("sends the user's file and every OS's problems on ready", function()
		local dir = make_config_dir()
		local fh = assert(io.open(dir .. "/layers.toml", "wb"))
		fh:write('[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"WheelUp" = "vol_up"\n')
		fh:close()
		local world = make_state(dir)
		local outcome = Bridge.on_message("ready", world.state)
		remove_config_dir(dir)
		helpers.assert_eq(outcome.pushed, true)
		local init = last_call(world, "init")
		helpers.assert_eq(init.os, "linux")
		helpers.assert_true(init.text:match('"WheelUp" = "vol_up"') ~= nil, "init() carries the file's text")
		-- The wheel is no layer key on macOS: that loader refuses the entry.
		helpers.assert_eq(codes(init), "unavailable_on_os")
		helpers.assert_eq(world.titles[1], "layer_editor=layer_editor.window_title")
	end)

	helpers.it("refuses, writes nothing and restarts nothing for an invalid save", function()
		local dir = make_config_dir()
		local world = make_state(dir)
		local refused = {
			{ text = nil, code = "invalid_payload" },
			{ text = {}, code = "invalid_payload" },
			{ text = string.rep("#", 70000), code = "invalid_payload" },
			{ text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyA" = "format_disk"\n', code = "unknown_action" },
			{ text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyA" = "spotlight"\n', code = "unavailable_on_os" },
			{ text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"Digit1" = "repeat_count:500"\n', code = "invalid_parameter" },
		}
		for _, case in ipairs(refused) do
			local outcome = Bridge.on_message({ action = "save", text = case.text }, world.state)
			helpers.assert_eq(outcome.saved, false)
			local result = last_call(world, "saveResult")
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(codes(result), case.code)
		end
		local created = io.open(dir .. "/layers.toml", "rb")
		if created then created:close() end
		remove_config_dir(dir)
		helpers.assert_nil(created, "a refused save writes nothing")
		helpers.assert_eq(world.restarts, 0, "a refused save restarts nothing")
		helpers.assert_eq(world.hidden, 0, "a refused save keeps the window open")
		helpers.assert_nil(Bridge.on_message({ action = "format_disk" }, world.state), "an unknown action does nothing")
	end)

	helpers.it("sends the loaded keymap's legends and the layer key (layer-editor-current-layout-legends)", function()
		local corpus = Json.decode(read_file(LEGENDS))
		local Layout = helpers.load_module("adapters.keyboard_layout")
		local LayerEditor = require("keymap.layer_editor")
		-- The bridge, loaded over a logger that records its warnings.
		local warnings = {}
		local recorder = helpers.make_logger_stub()
		recorder.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
		local previous_logger = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = recorder
		local Recorded = helpers.load_module("ui.layer_editor.bridge")
		package.loaded["logger.shim"] = previous_logger
		for _, case in ipairs(corpus.cases) do
			local dir = make_config_dir()
			local world = make_state(dir)
			local hook = { key_text = function() return nil end,
				held_modifiers = function() return {} end,
				held_text_modifier_codes = function() return {} end,
				held_shortcut_modifier_codes = function() return {} end,
				set_remapper = function() end }
			-- The shipped tap-hold keys in force, as the recommended import leaves them.
			local config = assert(io.open(dir .. "/tap_hold.toml", "wb"))
			config:write("[tap_hold]\nenabled = true\ninherit_defaults = true\n")
			config:close()
			Manager._reset_for_test()
			Manager.init({ keyboard_hook = hook, execute_action = function() end,
				action_names = function() return {} end, on_text_injected = function() end,
				defaults_path = SHARED_ROOT .. "/tap_hold/defaults.toml", user_path = dir .. "/tap_hold.toml" })
			world.state.tap_hold = Manager
			world.state.keyboard_layout = Layout
			Layout._load_keymap_for_test(xkb_keymap(case.layout))
			LayerEditor._reset_for_test()
			local ok, err = pcall(function()
				local outcome = Recorded.on_message("ready", world.state)
				helpers.assert_eq(outcome.pushed, true)
				Recorded.on_message("ready", world.state)
				local init = last_call(world, "init")
				helpers.assert_type(init.legends, "table", "init() must carry the legends of the keymap")
				helpers.assert_eq(init.legends.source, case.source)
				local count = 0
				for code, text in pairs(case.expected) do
					count = count + 1
					helpers.assert_eq(init.legends.keys[code], text, case.name .. ": " .. code)
				end
				for code in pairs(init.legends.keys) do
					helpers.assert_not_nil(case.expected[code], case.name .. ": " .. code .. " must not have a legend")
				end
				helpers.assert_true(count >= 40, "only " .. count .. " legends compared")
				helpers.assert_eq(table.concat(init.layer_keys, ","), table.concat(corpus.recommended_layer_keys.linux, ","),
					"the key whose hold enters the layer")

				-- Another layout loaded, then the window comes back to the front.
				Layout._load_keymap_for_test(xkb_keymap({ KeyQ = "q" }))
				local answer = Recorded.on_message({ action = "legends" }, world.state)
				helpers.assert_eq(answer.pushed, true)
				local refreshed = last_call(world, "setLegends")
				helpers.assert_eq(refreshed.keys.KeyQ, "q")
			end)
			Layout._load_keymap_for_test(nil)
			Manager._reset_for_test()
			remove_config_dir(dir)
			helpers.assert_true(ok, tostring(err))
			local warned = 0
			for _, text in ipairs(warnings) do
				if text:match("registry code") and text:find(table.concat(case.unresolved, ", "), 1, true) then
					warned = warned + 1
				end
			end
			helpers.assert_eq(warned, 1, "the keys without a legend are reported once")
		end
	end)

	helpers.it("saves the page's session and the live daemon applies every keyboard edit (e2e)", function()
		local dir = make_config_dir()
		local config = assert(io.open(dir .. "/tap_hold.toml", "wb"))
		config:write('[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.left_alt]\ntime_activation_seconds = 0.2\n'
			.. 'tap_action = "backspace"\nhold_layer = "nav"\n')
		config:close()
		local world = make_state(dir)
		local hook = { key_text = function() return nil end,
			held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end }
		function hook.set_remapper(engine) hook.engine = engine end
		Manager._reset_for_test()
		Manager.init({ keyboard_hook = hook, execute_action = function() end,
			action_names = function() return {} end, on_text_injected = function() end,
			defaults_path = SHARED_ROOT .. "/tap_hold/defaults.toml", user_path = dir .. "/tap_hold.toml" })
		local original = hook.engine
		world.on_reload = Manager.reload
		local text = read_file(FIXTURE)
		local outcome = Bridge.on_message({ action = "save", text = text }, world.state)
		local written = read_file(dir .. "/layers.toml")
		local engine = hook.engine
		Manager._reset_for_test()
		remove_config_dir(dir)
		helpers.assert_eq(outcome.saved, true)
		helpers.assert_eq(outcome.applied, true)
		helpers.assert_eq(outcome.closed, true)
		helpers.assert_eq(world.restarts, 1)
		helpers.assert_eq(written:gsub("\r\n", "\n"), text, "the saved file is the page's text")
		local result = last_call(world, "saveResult")
		helpers.assert_eq(result.saved, true)
		helpers.assert_eq(result.applied, true)
		helpers.assert_type(original, "table", "the explicitly configured layer holder owns the original engine")
		helpers.assert_true(engine ~= original, "the saved file swaps the actual daemon engine")
		engine:process(56, 1, 0)
		helpers.assert_eq(engine:process(20, 1, 10), { { code = 113, value = 1 } }, "KeyT emits mute")
		engine:process(20, 0, 20)
		helpers.assert_eq(engine:process(34, 1, 30), { { code = 88, value = 1 } }, "KeyG emits F12")
		engine:process(34, 0, 40)
		helpers.assert_eq(engine:process(16, 1, 50), {
			{ code = 29, value = 1 }, { code = 42, value = 1 }, { code = 102, value = 1 },
		}, "the persisted common binding emits Ctrl+Shift+Home")
		engine:release_all()
	end)

	helpers.it("saving layer mappings never enables an unconfigured tap-hold owner", function()
		local dir = make_config_dir()
		local world = make_state(dir)
		local hook = { key_text = function() return nil end,
			held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end }
		function hook.set_remapper(engine) hook.engine = engine end
		Manager._reset_for_test()
		Manager.init({ keyboard_hook = hook, execute_action = function() end,
			action_names = function() return {} end, on_text_injected = function() end,
			defaults_path = SHARED_ROOT .. "/tap_hold/defaults.toml", user_path = dir .. "/tap_hold.toml" })
		local original, before_enabled = hook.engine, Manager.file_enabled()
		world.on_reload = Manager.reload
		local outcome = Bridge.on_message({ action = "save", text = read_file(FIXTURE) }, world.state)
		local current, active, keys = hook.engine, Manager.is_active(), Manager.keys()
		Manager._reset_for_test()
		remove_config_dir(dir)
		helpers.assert_eq(before_enabled, false, "absence keeps the file-level master neutral")
		helpers.assert_nil(original, "no native owner before the edit")
		helpers.assert_eq(outcome.saved, true)
		helpers.assert_eq(outcome.applied, true, "reload accepts the new mappings without enabling input")
		helpers.assert_nil(current, "saving a mapping cannot activate its layer holder")
		helpers.assert_eq(active, false)
		helpers.assert_eq(next(keys), nil, "an absent tap-hold file never imports the preset keys")
	end)

	helpers.it("keeps the window open when the remap restart fails", function()
		local dir = make_config_dir()
		local world = make_state(dir)
		world.restart_result = false
		local outcome = Bridge.on_message({ action = "save", text = read_file(FIXTURE) }, world.state)
		remove_config_dir(dir)
		helpers.assert_eq(outcome.saved, true)
		helpers.assert_eq(outcome.applied, false)
		helpers.assert_eq(world.hidden, 0)
		helpers.assert_eq(last_call(world, "saveResult").applied, false)
		local cancelled = Bridge.on_message({ action = "cancel" }, world.state)
		helpers.assert_eq(cancelled.closed, true)
	end)
end)
