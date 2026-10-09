--- tests/unit/modules/shortcuts/test_send_input_parameter_vectors.lua

--- ==============================================================================
--- MODULE: send_text / send_key / send_shortcut replay the shared vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/send_input_vectors.json, which
--- the macOS and Windows suites replay too, through the gesture validator and the
--- shortcuts manager's parser over the real vocabulary
--- (_shared/modules/actions/send_keys.json), then fires the three actions from a
--- binding and checks the exact synthetic input: the text the injector types and
--- the evdev codes pressed on the daemon's uinput device.
---
--- ROOT CAUSE ENCODED:
--- No action could type a chosen text or press a chosen key or shortcut, and
--- parameter validation knew only URLs and wrap pairs.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

require("test.action_parameter_label_contract")(helpers, json, helpers.driver_root() .. "/../_shared")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/action_parameters/send_input_vectors.json"

local ACTIONS = { text = "send_text", key = "send_key", shortcut = "send_shortcut" }

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the send-input corpus is not valid JSON")
end

--- Loads the gestures manager with the daemon's composed handlers over a
--- recording injector, key emitter and a French AZERTY layout.
--- @return table gestures, table log
local function routed_gestures()
	local names = {
		combo = "modules.gestures.combo_emitter",
		injector = "modules.hotstrings.injector",
		layout = "adapters.keyboard_layout",
		keylogger = "modules.keylogger.keylogger",
	}
	local log = { codes = {}, injected = {} }
	package.loaded[names.combo] = {
		press = function() error("send_* must press evdev codes, not keysym combos") end,
		press_codes = function(mods, keys)
			log.codes[#log.codes + 1] = table.concat(mods, "+") .. "|" .. table.concat(keys, "+")
			return true
		end,
	}
	package.loaded[names.injector] = {
		inject = function(backspaces, text)
			log.injected[#log.injected + 1] = tostring(backspaces) .. "|" .. text
			return { ok = true }
		end,
	}
	-- AZERTY: "a" is typed by the key the kernel calls KEY_Q (16), "%" by
	-- Shift on KEY_APOSTROPHE (40), "@" by AltGr on KEY_0 (11).
	local azerty = {
		a = { keycode = 16, level = 1, mods = {} },
		["%"] = { keycode = 40, level = 2, mods = { "shift" } },
		["@"] = { keycode = 11, level = 3, mods = { "altgr" } },
	}
	package.loaded[names.layout] = {
		resolve = function(char) return azerty[char] end,
		is_ready = function() return true end,
	}
	package.loaded[names.keylogger] = { record_shortcut = function() return true end }
	package.loaded["modules.shortcuts.manager"] = nil

	local Shortcuts = require("modules.shortcuts.manager")
	local ScriptActions = helpers.load_module("modules.shortcuts.script_actions")
	local ActionHandlers = helpers.load_module("modules.shortcuts.action_handlers")
	local noop = function() end
	local Gestures = helpers.load_module("modules.gestures.manager")
	Gestures.init({
		enabled = false,
		persist = false,
		action_handlers = ActionHandlers.compose(
			ScriptActions.new({ reset = noop, reload = noop, quit = noop }).handlers, Shortcuts),
	})
	log.restore = function()
		for _, name in pairs(names) do package.loaded[name] = nil end
		package.loaded["modules.shortcuts.manager"] = nil
	end
	return Gestures, Shortcuts, log
end

helpers.describe("send input parameters replay the shared send-input corpus (send-input-actions)", function()
	local corpus = read_corpus()
	local Shortcuts = helpers.load_module("modules.shortcuts.manager")
	local Gestures = helpers.load_module("modules.gestures.manager")

	helpers.it("the parameters are declared and the corpus is loaded", function()
		for kind, action in pairs(ACTIONS) do
			helpers.assert_eq(Gestures.get_action_parameter_spec(action), kind, action .. " parameter kind")
		end
		helpers.assert_true(#corpus.vectors >= 40, "the corpus must hold its vectors")
	end)

	helpers.it("the prompts and refusals name the vocabulary", function()
		local key_prompt = Gestures.get_action_parameter_prompt("send_key")
		helpers.assert_true(key_prompt:find("page_down", 1, true) ~= nil
			and key_prompt:find("f1\226\128\166f20", 1, true) ~= nil,
			"the key prompt lists the named keys: " .. key_prompt)
		helpers.assert_true(Gestures.get_action_parameter_error("send_text"):find("500", 1, true) ~= nil,
			"the text refusal states the limit")
		helpers.assert_true(Gestures.get_action_parameter_prompt("send_shortcut"):find("{1}", 1, true) == nil,
			"the shortcut prompt has its placeholder filled")
	end)

	-- The picker's own editor edits these three kinds: it is told which rows take
	-- which, the value the binding holds, the vocabulary it validates with, and
	-- the prompts and refusals the zenity prompt shows.
	helpers.it("the picker's editor gets the send-input rows, their values and texts", function()
		local items = {
			{ type = "heading", level = 1, text = "Input" },
			{ type = "action", id = "send_key", label = "Press a key" },
			{ type = "action", id = "open_url", label = "Open a link" },
		}
		local fields = Gestures.get_picker_parameter_fields(items, "tap_key__number_row_left")
		helpers.assert_eq(items[2].parameter, "key", "the send_key row names its kind")
		helpers.assert_eq(items[2].parameterValue, "", "and the value its binding holds")
		helpers.assert_eq(items[3].parameter, "url",
			"a URL row names its kind too, so the page can offer to edit the current one")
		helpers.assert_eq(fields.parameter_strings.prompts.url, nil,
			"but the page does not edit a URL: the zenity prompt asks for it")
		helpers.assert_eq(items[1].parameter, nil, "a heading takes nothing")
		helpers.assert_eq(fields.send_vocabulary, Shortcuts.send_vocabulary(), "the drivers' own vocabulary")
		helpers.assert_eq(fields.parameter_strings.prompts.key, Gestures.get_action_parameter_prompt("send_key"))
		helpers.assert_eq(fields.parameter_strings.errors.key, Gestures.get_action_parameter_error("send_key"))
		helpers.assert_true(type(fields.parameter_strings.captureShortcut) == "string"
			and fields.parameter_strings.captureShortcut ~= "dialog.action_picker.capture_shortcut",
			"the capture hints are translated")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("send-input vector '" .. vector.id .. "'", function()
			local value = string.rep(vector.value, vector["repeat"] or 1)
			local valid = vector.valid ~= false
			helpers.assert_eq(Gestures.validate_action_parameter(ACTIONS[vector.kind], value), valid,
				vector.id .. ": validation")
			local parsed = Shortcuts.parse_send_input(vector.kind, value)
			if not valid then
				helpers.assert_eq(parsed, nil, vector.id .. ": an invalid value parses to nothing")
				return
			end
			helpers.assert_true(parsed ~= nil, vector.id .. ": a valid value parses")
			helpers.assert_eq(parsed.canonical,
				string.rep(vector.canonical, vector.canonical_repeat or 1), vector.id .. ": canonical form")
			helpers.assert_eq(parsed.named, vector.named, vector.id .. ": named key")
			helpers.assert_eq(parsed.char, vector.char, vector.id .. ": character key")
			if vector.kind == "shortcut" then
				helpers.assert_eq(table.concat(parsed.mods, ","), table.concat(vector.mods, ","),
					vector.id .. ": modifiers")
			end
		end)
	end
end)

helpers.describe("send input actions press and type exactly (send-input-actions)", function()
	--- Stores Value for the binding, fires the action and returns the log.
	local function fire(Gestures, action, value)
		helpers.assert_true(Gestures.set_action_parameter("tap_key__number_row_right_2", action, value),
			action .. " must accept " .. value)
		Gestures.execute_action(action, "tap_key__number_row_right_2")
	end

	helpers.it("send_shortcut presses the modifiers and the key the layout types the character with", function()
		local Gestures, _, log = routed_gestures()
		local ok, err = pcall(function()
			fire(Gestures, "send_shortcut", "ctrl+a")
			fire(Gestures, "send_shortcut", "primary+a")
			fire(Gestures, "send_shortcut", "primary+ctrl+shift+tab")
			fire(Gestures, "send_shortcut", "alt+%")
			fire(Gestures, "send_shortcut", "super+F4")
			helpers.assert_eq(table.concat(log.codes, " / "),
				"29|16 / 29|16 / 29+42|15 / 56+42|40 / 125|62",
				"Ctrl+A on AZERTY is Ctrl with KEY_Q; primary is Control; primary and ctrl collapse;"
					.. " a character's own level modifier joins the shortcut's")
			helpers.assert_eq(#log.injected, 0, "a shortcut types nothing")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("send_key presses a named key and types a character", function()
		local Gestures, _, log = routed_gestures()
		local ok, err = pcall(function()
			fire(Gestures, "send_key", "Enter")
			fire(Gestures, "send_key", "pgdn")
			fire(Gestures, "send_key", "é")
			helpers.assert_eq(table.concat(log.codes, " / "), "|28 / |109")
			helpers.assert_eq(table.concat(log.injected, " / "), "0|é",
				"a character key is typed through the injector, which owns its provenance")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("send_text types the stored text through the injector", function()
		local Gestures, _, log = routed_gestures()
		local ok, err = pcall(function()
			fire(Gestures, "send_text", "bonjour cela va bien?")
			helpers.assert_eq(table.concat(log.injected, " / "), "0|bonjour cela va bien?")
			helpers.assert_eq(#log.codes, 0)
			Gestures.execute_action("send_text", "tap_key__number_row_left")
			helpers.assert_eq(#log.injected, 1, "a binding without a stored text types nothing")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)
end)
