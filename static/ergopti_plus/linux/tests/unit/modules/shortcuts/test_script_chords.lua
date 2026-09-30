--- tests/unit/modules/shortcuts/test_script_chords.lua

--- ==============================================================================
--- MODULE: Script-management chords (Linux)
--- DESCRIPTION:
--- AltGr + Enter, Backspace, Delete and Escape, the four chords the three
--- drivers share: an empty configuration runs each slot's preset (pause toggle,
--- reload, personal shortcuts, quit) on the next loop tick and keeps the chord
--- from the application; an unassigned slot, the switch off, another modifier,
--- a layout without AltGr and, while paused, any action outside script
--- management leave the chord to the application.
---
--- ROOT CAUSE ENCODED:
--- The Linux driver had no script-management chord at all: a paused daemon
--- could only be resumed from the tray (script-chords-three-os-2026-09-30).
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local TomlCodec = require("toml_codec")

-- evdev codes of the four keys.
local KEY_ENTER, KEY_BACKSPACE, KEY_DELETE, KEY_ESC = 28, 14, 111, 1
local ALTGR = { altgr = true }

local PRESETS = {
	script_altgr_enter = "script_pause_toggle",
	script_altgr_backspace = "script_reload",
	script_altgr_delete = "open_personal_shortcuts",
	script_altgr_escape = "script_quit",
}

--- A fresh script_chords module over a real config file, its deferred work
--- queued rather than run.
--- @param source string|nil config.toml content; nil for an absent file.
--- @return table chords, table log
local function fresh(source)
	local log = { deferred = {}, executed = {}, paused = false }
	local previous = {}
	for _, name in ipairs({ "infra.config_paths", "modules.gestures.manager", "modules.shortcuts.script_chords" }) do
		previous[name] = package.loaded[name]
	end
	local path = os.tmpname()
	os.remove(path)
	if source then Sandbox.write_bytes(path, source) end
	log.path = path
	package.loaded["infra.config_paths"] = { config = function() return path end }
	package.loaded["modules.gestures.manager"] = {
		is_assignable = function(id)
			return PRESETS.script_altgr_enter == id or id == "script_reload" or id == "open_personal_shortcuts"
				or id == "script_quit" or id == "screen_capture"
		end,
		execute_action = function(action, binding) log.executed[#log.executed + 1] = action .. "@" .. binding end,
	}
	package.loaded["modules.shortcuts.script_chords"] = nil
	local Chords = require("modules.shortcuts.script_chords")
	Chords.init({
		is_paused = function() return log.paused end,
		defer = function(fn) log.deferred[#log.deferred + 1] = fn return true end,
	})
	log.run = function()
		local queued = log.deferred
		log.deferred = {}
		for _, fn in ipairs(queued) do fn() end
	end
	log.restore = function()
		for name, value in pairs(previous) do package.loaded[name] = value end
		os.remove(path)
		os.remove(path .. ".tmp")
	end
	return Chords, log
end

--- Runs a body over a fresh module and always restores the loaded modules.
local function with_chords(source, body)
	local Chords, log = fresh(source)
	local ok, err = pcall(body, Chords, log)
	log.restore()
	helpers.assert_true(ok, tostring(err))
end

helpers.describe("Linux script-management chords (script-chords-three-os-2026-09-30)", function()
	helpers.it("script-chord: an empty configuration runs the four presets and keeps each chord from the application", function()
		with_chords(nil, function(Chords, log)
			helpers.assert_eq(Chords.chords_enabled(), true)
			for _, code in ipairs({ KEY_ENTER, KEY_BACKSPACE, KEY_DELETE, KEY_ESC }) do
				helpers.assert_eq(Chords.on_key({ code = code, mods = ALTGR }), true, "AltGr + " .. code)
			end
			helpers.assert_eq(#log.executed, 0, "nothing runs inside the consumption callback")
			log.run()
			helpers.assert_eq(table.concat(log.executed, " / "),
				"script_pause_toggle@script__script_altgr_enter / script_reload@script__script_altgr_backspace / "
				.. "open_personal_shortcuts@script__script_altgr_delete / script_quit@script__script_altgr_escape")
		end)
	end)

	helpers.it("script-chord: the four slots are the shared catalogue's, in menu order", function()
		with_chords(nil, function(Chords)
			local ids = {}
			for _, slot in ipairs(Chords.slots()) do ids[#ids + 1] = slot.id end
			helpers.assert_eq(table.concat(ids, ","),
				"script_altgr_enter,script_altgr_backspace,script_altgr_delete,script_altgr_escape")
			for id, action in pairs(PRESETS) do helpers.assert_eq(Chords.get_action(id), action, id) end
		end)
	end)

	helpers.it("script-chord: the switch off leaves every chord native and keeps the slots' actions", function()
		with_chords("[shortcuts.script_control]\nchords_enabled = false\n", function(Chords, log)
			helpers.assert_eq(Chords.chords_enabled(), false)
			for _, code in ipairs({ KEY_ENTER, KEY_BACKSPACE, KEY_DELETE, KEY_ESC }) do
				helpers.assert_eq(Chords.on_key({ code = code, mods = ALTGR }), false)
			end
			helpers.assert_eq(Chords.get_action("script_altgr_escape"), "script_quit")
			helpers.assert_true(Chords.set_chords_enabled(true))
			helpers.assert_eq(Chords.on_key({ code = KEY_ESC, mods = ALTGR }), true)
			local saved = TomlCodec.decode(Sandbox.read_bytes(log.path))
			helpers.assert_eq(((saved.shortcuts or {}).script_control or {}).chords_enabled, nil,
				"the switch back on its default is a deletion")
		end)
	end)

	helpers.it("script-chord: an explicit none is kept and leaves that chord to the application", function()
		with_chords('[shortcuts.script_control]\nscript_altgr_enter = "none"\n', function(Chords, log)
			helpers.assert_eq(Chords.get_action("script_altgr_enter"), "none")
			helpers.assert_eq(Chords.on_key({ code = KEY_ENTER, mods = ALTGR }), false)
			helpers.assert_eq(Chords.on_key({ code = KEY_ESC, mods = ALTGR }), true)
			helpers.assert_true(Chords.set_action("script_altgr_backspace", "none"))
			local saved = TomlCodec.decode(Sandbox.read_bytes(log.path)).shortcuts.script_control
			helpers.assert_eq(saved.script_altgr_backspace, "none", "none is written, since absence is the preset")
			helpers.assert_eq(saved.script_altgr_enter, "none")
			helpers.assert_true(Chords.set_action("script_altgr_backspace", "script_reload"))
			saved = TomlCodec.decode(Sandbox.read_bytes(log.path)).shortcuts.script_control
			helpers.assert_eq(saved.script_altgr_backspace, nil, "the preset back is a deletion")
		end)
	end)

	helpers.it("script-chord: paused, only a script-management action runs", function()
		with_chords('[shortcuts.script_control]\nscript_altgr_delete = "screen_capture"\n', function(Chords, log)
			log.paused = true
			helpers.assert_eq(Chords.on_key({ code = KEY_DELETE, mods = ALTGR }), false,
				"a paused daemon leaves any other action's chord to the application")
			helpers.assert_eq(Chords.on_key({ code = KEY_ENTER, mods = ALTGR }), true, "the way back from a pause")
			log.run()
			helpers.assert_eq(table.concat(log.executed, " / "), "script_pause_toggle@script__script_altgr_enter")
			log.paused = false
			helpers.assert_eq(Chords.on_key({ code = KEY_DELETE, mods = ALTGR }), true)
			log.paused = true
			log.run()
			helpers.assert_eq(#log.executed, 1, "a pause between the press and its tick runs nothing else")
		end)
	end)

	helpers.it("script-chord: without AltGr, with another modifier or on another key the press is the application's", function()
		with_chords(nil, function(Chords, log)
			helpers.assert_eq(Chords.on_key({ code = KEY_ENTER, mods = {} }), false)
			for _, name in ipairs({ "ctrl", "alt", "meta" }) do
				helpers.assert_eq(Chords.on_key({ code = KEY_ENTER, mods = { altgr = true, [name] = true } }), false, name)
			end
			helpers.assert_eq(Chords.on_key({ code = KEY_ENTER, mods = { altgr = true, shift = true } }), true,
				"Shift rides along, as on Windows")
			helpers.assert_eq(Chords.on_key({ code = 30, mods = ALTGR }), false, "AltGr + A types its character")
			helpers.assert_eq(#log.deferred, 1)
		end)
	end)

	helpers.it("script-chord: the cleanup keeps what the loader reads and offers an unknown action", function()
		with_chords('[shortcuts.script_control]\nscript_altgr_enter = "retired_action"\nchords_enabled = true\n'
			.. 'script_altgr_escape = "none"\nforeign = 1\n', function(Chords)
			local marked = {}
			Chords.mark_config_reads(TomlCodec.decode(
				'[shortcuts.script_control]\nscript_altgr_enter = "retired_action"\nchords_enabled = true\n'
				.. 'script_altgr_escape = "none"\nforeign = 1\n'),
				function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			table.sort(marked)
			helpers.assert_eq(table.concat(marked, ","),
				"shortcuts.script_control.chords_enabled,shortcuts.script_control.script_altgr_escape")
			helpers.assert_eq(Chords.get_action("script_altgr_enter"), "script_pause_toggle",
				"an outdated action reads as the slot's preset")
		end)
	end)
end)
