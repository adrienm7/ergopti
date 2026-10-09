--- tests/unit/modules/shortcuts/test_tap_keys.lua

--- ==============================================================================
--- MODULE: Number-row tap keys (Linux)
--- DESCRIPTION:
--- KEY_GRAVE, KEY_MINUS and KEY_EQUAL as tap keys: a plain press of an assigned
--- one is consumed and runs its action on the next loop tick, under the key's
--- own binding; a press with any modifier (AltGr included), a press of an
--- unassigned key, and any press while shortcuts are off pass through untouched.
--- The menu names each key by what it types under the loaded XKB keymap, a dead
--- key with a hint, driven here against French AZERTY and US-international
--- keymap fixtures.
---
--- ROOT CAUSE ENCODED:
--- The edge keys of the number row could not be assigned to anything on Linux,
--- and no driver named them by the character they type.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local TomlCodec = require("toml_codec")

-- fr(azerty) and us(intl), cut to the three keys: TLDE (KEY_GRAVE, 41), AE11
-- (KEY_MINUS, 12) and AE12 (KEY_EQUAL, 13). XKB keycodes are evdev + 8.
local function keymap(tlde, ae11, ae12)
	return table.concat({
		"xkb_keymap {",
		"xkb_keycodes \"(unnamed)\" {",
		"\t<TLDE> = 49;", "\t<AE11> = 20;", "\t<AE12> = 21;",
		"\t<AD01> = 24;", "\t<AC01> = 38;",
		"};",
		"xkb_symbols \"(unnamed)\" {",
		"\tkey <TLDE> { [ " .. tlde .. " ] };",
		"\tkey <AE11> { [ " .. ae11 .. " ] };",
		"\tkey <AE12> { [ " .. ae12 .. " ] };",
		"\tkey <AD01> { [ a, A ] };",
		"\tkey <AC01> { [ q, Q ] };",
		"};",
		"};",
	}, "\n")
end
local AZERTY = keymap("twosuperior, asciitilde", "parenright, degree", "equal, plus")
local US_INTL = keymap("dead_grave, dead_tilde", "minus, underscore", "NoSymbol, NoSymbol")

--- A fresh tap_keys module over a real config file, with its deferred work
--- queued rather than run. Legacy storage remains a separate fixture.
--- @param stored table|nil Stored assignments, pref key -> value.
--- @return table tap_keys, table log
local function fresh(stored)
	local log = { deferred = {}, executed = {} }
	local previous = {}
	for _, name in ipairs({ "adapters.storage", "infra.config_paths", "modules.gestures.manager", "modules.shortcuts.tap_keys" }) do
		previous[name] = package.loaded[name]
	end
	local prefs = {}
	for key, value in pairs(stored or {}) do prefs[key] = value end
	local path = os.tmpname()
	local lines = { "[shortcuts.tap_keys]" }
	for key, value in pairs(prefs) do
		lines[#lines + 1] = key:match("([^.]+)$") .. " = " .. string.format("%q", value)
	end
	Sandbox.write_bytes(path, table.concat(lines, "\n") .. "\n")
	log.path = path
	package.loaded["infra.config_paths"] = { config = function() return path end }
	package.loaded["adapters.storage"] = {
		get = function(key, default) if prefs[key] == nil then return default end return prefs[key] end,
		set = function(key, value) prefs[key] = value return true end,
	}
	package.loaded["modules.gestures.manager"] = {
		is_assignable = function(id) return id == "screen_capture" or id == "send_text" or id == "send_shortcut" end,
		execute_action = function(action, binding) log.executed[#log.executed + 1] = action .. "@" .. binding end,
	}
	package.loaded["modules.shortcuts.tap_keys"] = nil
	local TapKeys = require("modules.shortcuts.tap_keys")
	log.active = true
	TapKeys.init({
		is_active = function() return log.active end,
		defer = function(fn) log.deferred[#log.deferred + 1] = fn return true end,
	})
	log.restore = function()
		for _, name in ipairs({ "adapters.storage", "infra.config_paths", "modules.gestures.manager", "modules.shortcuts.tap_keys" }) do
			package.loaded[name] = previous[name]
		end
		os.remove(path)
		os.remove(path .. ".tmp")
	end
	return TapKeys, log
end

helpers.describe("Linux number-row tap keys (tap-keys)", function()
	helpers.it("tap-config-owner: absent overrides stay native despite legacy storage", function()
		local TapKeys, log = fresh()
		local ok, err = pcall(function()
			package.loaded["adapters.storage"].get = function() return "screen_capture" end
			os.remove(log.path)
			helpers.assert_eq(TapKeys.get_action("number_row_left"), "none")
			helpers.assert_true(TapKeys.set_action("number_row_left", "send_text"))
			TapKeys._reset()
			helpers.assert_eq(TapKeys.get_action("number_row_left"), "send_text")
			os.remove(log.path)
			TapKeys._reset()
			helpers.assert_eq(TapKeys.get_action("number_row_left"), "none", "cleared overrides cannot reappear")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("tap-config-owner: refuses malformed input and preserves live assignments on a failed save", function()
		local TapKeys, log = fresh({ ["shortcuts.tap_keys.number_row_left"] = "screen_capture" })
		local ok, err = pcall(function()
			helpers.assert_eq(TapKeys.get_action("number_row_left"), "screen_capture")
			local broken = "[shortcuts.tap_keys\n"
			Sandbox.write_bytes(log.path, broken)
			helpers.assert_eq(TapKeys.set_action("number_row_left", "send_text"), false)
			helpers.assert_eq(TapKeys.get_action("number_row_left"), "screen_capture")
			helpers.assert_eq(Sandbox.read_bytes(log.path), broken)
			TapKeys._reset()
			local loaded, failure = pcall(TapKeys.get_action, "number_row_left")
			helpers.assert_eq(loaded, false)
			helpers.assert_true(tostring(failure):find("malformed configuration", 1, true) ~= nil)
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("tap-config-owner: cleanup retains consumed keys and writes preserve unknown neighbors", function()
		local TapKeys, log = fresh({ ["shortcuts.tap_keys.number_row_left"] = "screen_capture" })
		local ok, err = pcall(function()
			Sandbox.write_bytes(log.path, Sandbox.read_bytes(log.path) .. "unknown = \"keep\"\n[other]\nvalue = 42\n")
			local decoded = TomlCodec.decode(Sandbox.read_bytes(log.path))
			local marked = {}
			TapKeys.mark_config_reads(decoded, function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(table.concat(marked), "shortcuts.tap_keys.number_row_left")
			local cleanup = require("ui.menu.unused_keys_cleanup")
			local live_marked = {}
			-- Other owners remain real; the action catalogue stub supplies its unused collector.
			package.loaded["modules.gestures.manager"].mark_config_reads = function() end
			cleanup.collect(decoded, function(...) live_marked[table.concat({ ... }, ".")] = true end)
			helpers.assert_eq(live_marked["shortcuts.tap_keys.number_row_left"], true)
			helpers.assert_eq(live_marked["shortcuts.tap_keys.unknown"], nil)
			helpers.assert_true(TapKeys.set_action("number_row_left", "send_text"))
			local saved = TomlCodec.decode(Sandbox.read_bytes(log.path))
			helpers.assert_eq(saved.shortcuts.tap_keys.unknown, "keep")
			helpers.assert_eq(saved.other.value, 42)
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("a plain tap on an assigned key is consumed and runs its action on the next tick", function()
		local TapKeys, log = fresh({
			["shortcuts.tap_keys.number_row_left"] = "screen_capture",
			["shortcuts.tap_keys.number_row_right_2"] = "send_shortcut",
		})
		local ok, err = pcall(function()
			helpers.assert_eq(TapKeys.on_key({ code = 41, mods = {} }), true,
				"the explicitly assigned KEY_GRAVE opens the capture tool")
			helpers.assert_eq(TapKeys.on_key({ code = 13, mods = {} }), true, "KEY_EQUAL holds send_shortcut")
			helpers.assert_eq(#log.executed, 0, "nothing runs inside the consumption callback")
			for _, fn in ipairs(log.deferred) do fn() end
			helpers.assert_eq(table.concat(log.executed, " / "),
				"screen_capture@tap_key__number_row_left / send_shortcut@tap_key__number_row_right_2")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("a modifier, AltGr, an unassigned key or shortcuts off let the key through", function()
		local TapKeys, log = fresh()
		local ok, err = pcall(function()
			for _, code in ipairs({ 41, 12, 13 }) do
				helpers.assert_eq(TapKeys.on_key({ code = code, mods = {} }), false,
					"an absent assignment keeps every edge key native")
			end
			for _, name in ipairs({ "ctrl", "shift", "alt", "altgr", "meta" }) do
				helpers.assert_eq(TapKeys.on_key({ code = 41, mods = { [name] = true } }), false,
					name .. " keeps the key's own character")
			end
			helpers.assert_eq(TapKeys.on_key({ code = 12, mods = {} }), false,
				"KEY_MINUS has no default action")
			helpers.assert_eq(TapKeys.on_key({ code = 30, mods = {} }), false, "KEY_A is no tap key")
			log.active = false
			helpers.assert_eq(TapKeys.on_key({ code = 41, mods = {} }), false,
				"a paused driver or disabled shortcuts swallow nothing")
			helpers.assert_eq(#log.deferred, 0)
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("an assignment is stored, and an unknown stored action leaves the key alone", function()
		local TapKeys, log = fresh({ ["shortcuts.tap_keys.number_row_right_1"] = "no_such_action" })
		local ok, err = pcall(function()
			helpers.assert_eq(TapKeys.get_action("number_row_right_1"), "none")
			helpers.assert_eq(TapKeys.set_action("number_row_right_1", "send_text"), true)
			helpers.assert_eq(TapKeys.get_action("number_row_right_1"), "send_text")
			local saved = TomlCodec.decode(Sandbox.read_bytes(log.path))
			helpers.assert_eq(saved.shortcuts.tap_keys.number_row_right_1, "send_text",
				"the canonical config is the durable assignment owner (tap-config-owner)")
			TapKeys._reset()
			helpers.assert_eq(TapKeys.get_action("number_row_right_1"), "send_text", "restart reads config.toml")
			helpers.assert_eq(TapKeys.set_action("number_row_right_1", "no_such_action"), false)
			helpers.assert_eq(TapKeys.set_action("not_a_key", "send_text"), false)
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)

	helpers.it("the labels follow the loaded keymap, a dead key hinted", function()
		local TapKeys, log = fresh()
		local Layout = helpers.load_module("adapters.keyboard_layout")
		local i18n = require("infra.i18n")
		local ok, err = pcall(function()
			local function names()
				local out = {}
				for _, key in ipairs(TapKeys.keys()) do out[#out + 1] = TapKeys.display_name(key.id, Layout, i18n) end
				return table.concat(out, " ")
			end
			Layout._load_keymap_for_test(AZERTY)
			helpers.assert_eq(names(), "² ) =", "AZERTY")
			Layout._load_keymap_for_test(US_INTL)
			local dead = i18n.get("menu.shortcuts.tap_keys.dead_key")
			local at = dead:find("{1}", 1, true)
			local expected_dead = dead:sub(1, at - 1) .. "`" .. dead:sub(at + 3)
			helpers.assert_eq(names(), expected_dead .. " - "
				.. i18n.get("menu.shortcuts.tap_keys.number_row_right_2"),
				"US-international: a dead grave is hinted, a key with no symbol is named by its position")
			Layout._load_keymap_for_test(nil)
			helpers.assert_eq(TapKeys.display_name("number_row_left", Layout, i18n),
				i18n.get("menu.shortcuts.tap_keys.number_row_left"), "no keymap: the position name")
		end)
		log.restore()
		helpers.assert_true(ok, tostring(err))
	end)
end)

helpers.describe("Tap-key configuration admission", function()
	for _, scenario in ipairs({ "ordinary rebind", "owned dispatch", "released generation", "new generation", "paused drain" }) do
		helpers.it("keeps " .. scenario .. " bounded by the actual tap dispatcher", function()
			local subject, log = fresh({ ["shortcuts.tap_keys.number_row_left"] = "screen_capture" })
			local ok, err = pcall(function()
				local code
				for _, key in ipairs(subject.keys()) do if key.id == "number_row_left" then code = key.linux end end
				helpers.assert_not_nil(code)
				local detail = { code = code, mods = {} }
				helpers.assert_true(subject.on_key(detail))
				log.deferred[1]()
				helpers.assert_eq(table.concat(log.executed), "screen_capture@tap_key__number_row_left")
				log.executed = {}
				helpers.assert_true(subject.on_key(detail))
				if scenario == "paused drain" then
					log.active = false
					log.deferred[2]()
					helpers.assert_eq(#log.executed, 0, "pause after queuing must prevent the native action")
					return
				end
				if scenario == "ordinary rebind" then
					helpers.assert_true(subject.set_action("number_row_left", "send_text"))
					log.deferred[2]()
					helpers.assert_eq(#log.executed, 0, "an old assignment must not execute after a successful edit")
					helpers.assert_true(subject.on_key(detail))
					log.deferred[3]()
					helpers.assert_eq(table.concat(log.executed), "send_text@tap_key__number_row_left")
					return
				end
				local token = {}
				local before = Sandbox.read_bytes(log.path)
				helpers.assert_true(subject.acquire_configuration(token))
				helpers.assert_eq(subject.acquire_configuration({}), false)
				helpers.assert_eq(subject.acquire_configuration(token), false)
				helpers.assert_eq(subject.release_configuration({}), false)
				helpers.assert_eq(subject.set_action("number_row_left", "send_text"), false)
				helpers.assert_eq(Sandbox.read_bytes(log.path), before)
				helpers.assert_eq(subject.init({ is_active = function() return true end, defer = function() return true end }), false)
				helpers.assert_eq(subject.on_key(detail), false)
				helpers.assert_eq(#log.deferred, 2)
				if scenario == "owned dispatch" then log.deferred[2]() end
				helpers.assert_eq(#log.executed, 0)
				helpers.assert_true(subject.release_configuration(token))
				helpers.assert_eq(subject.release_configuration(token), false)
				log.deferred[2]()
				helpers.assert_eq(#log.executed, 0, "release must not replay canceled callbacks")
				if scenario == "new generation" then
					helpers.assert_true(subject.on_key(detail))
					log.deferred[3]()
					helpers.assert_eq(table.concat(log.executed), "screen_capture@tap_key__number_row_left")
				end
			end)
			log.restore()
			if not ok then error(err, 0) end
		end)
	end
end)
