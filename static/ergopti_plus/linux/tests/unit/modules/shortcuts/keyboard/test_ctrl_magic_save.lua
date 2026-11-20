--- tests/unit/modules/shortcuts/keyboard/test_ctrl_magic_save.lua

--- ==============================================================================
--- MODULE: Modifiers + Magic Key Saves (Linux)
--- DESCRIPTION:
--- With [layout] ctrl_magic_save on, a shortcut chord on the layout's own magic
--- key sends the same modifiers with S on the three drivers
--- (_shared/shortcuts/engine/magic_key_save_core.lua). Linux first sent a bare
--- Ctrl+S for Ctrl alone and left Ctrl+Shift+★, Alt+★ and Super+★ to the
--- application. These tests pin the shared rule on the hook's presses: every
--- shortcut chord, ★ alone and AltGr left to the layout, never a physical magic
--- key the user chose, a chord an assigned shortcut owns kept, the switch read
--- from config.toml at the press, and every auto-repeat saving again.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("tests.lua.settings.unused_keys_contract").sandbox

require("tests.lua.keyboard.magic_key_save_contract")(helpers, require("core.text.engine.json"),
	helpers.driver_root() .. "/../_shared")

-- KEY_C types the magic key, KEY_S types « s ».
local PLAIN = { [46] = "★", [31] = "s" }

local function fresh()
	package.loaded["modules.shortcuts.ctrl_magic_save"] = nil
	return require("modules.shortcuts.ctrl_magic_save")
end

--- The hook's ports, with the switch on, the automatic source and ★ as the magic key.
local function options(overrides)
	local state = { queued = {}, pressed = {}, active = true, enabled = true, chosen = false, owned = false,
		plain_reads = 0, active_reads = 0, enabled_reads = 0 }
	local built = {
		active = function() state.active_reads = state.active_reads + 1 return state.active end,
		magic_key = function() return "★" end,
		chosen_source = function() return state.chosen end,
		plain_text = function(code) state.plain_reads = state.plain_reads + 1 return PLAIN[code] end,
		shortcut_owns = function() return state.owned end,
		enabled = function() state.enabled_reads = state.enabled_reads + 1 return state.enabled end,
		defer = function(fn) state.queued[#state.queued + 1] = fn return true end,
		press = function(combo) state.pressed[#state.pressed + 1] = combo return true end,
	}
	for key, value in pairs(overrides or {}) do built[key] = value end
	return built, state
end

local function run_queued(state)
	for _, fn in ipairs(state.queued) do fn() end
	state.queued = {}
end

--- The chord one press of KEY_C with these modifiers sends, or false.
local function chord_of(mods)
	local Save = fresh()
	local opts, state = options()
	if not Save.on_key({ code = 46, value = 1, mods = mods }, opts) then return false end
	helpers.assert_eq(#state.pressed, 0, "nothing is pressed inside the consumption callback")
	run_queued(state)
	return state.pressed[1]
end

helpers.describe("linux modifiers + magic key saves (linux-ctrl-magic-save)", function()
	helpers.it("ctrl-magic-save: Ctrl alone on the layout's magic key presses Ctrl+S on the next tick", function()
		helpers.assert_eq(chord_of({ ctrl = true }), "ctrl+s")
	end)

	helpers.it("ctrl-magic-save: every shortcut chord keeps its modifiers with S", function()
		helpers.assert_eq(chord_of({ ctrl = true, shift = true }), "ctrl+shift+s")
		helpers.assert_eq(chord_of({ alt = true }), "alt+s")
		helpers.assert_eq(chord_of({ meta = true }), "super+s")
		helpers.assert_eq(chord_of({ meta = true, shift = true }), "shift+super+s")
		helpers.assert_eq(chord_of({ ctrl = true, alt = true }), "ctrl+alt+s")
	end)

	helpers.it("ctrl-magic-save: ★ alone, Shift and AltGr keep the layout's level", function()
		for _, mods in ipairs({ {}, { shift = true }, { altgr = true }, { altgr = true, shift = true },
			{ ctrl = true, altgr = true } }) do
			helpers.assert_eq(chord_of(mods), false)
		end
	end)

	helpers.it("ctrl-magic-save: only the layout's magic key is read, and only under a shortcut chord", function()
		local Save = fresh()
		local opts, state = options()
		helpers.assert_eq(Save.on_key({ code = 31, value = 1, mods = { ctrl = true } }, opts), false,
			"Ctrl on a key that types no magic key keeps its own chord")
		helpers.assert_eq(state.enabled_reads, 0, "Ctrl on another key, a Readline Ctrl+U, never reads the switch")
		state.plain_reads, state.active_reads = 0, 0
		helpers.assert_eq(Save.on_key({ code = 46, value = 0, mods = { ctrl = true } }, opts), false,
			"a release decides nothing")
		helpers.assert_eq(Save.on_key({ code = 31, value = 1, mods = { shift = true } }, opts), false)
		helpers.assert_eq(Save.on_key({ code = 31, value = 1, mods = {} }, opts), false)
		helpers.assert_eq(state.plain_reads + state.active_reads, 0,
			"a release or a press with no shortcut modifier reads no driver state")
		helpers.assert_eq(#state.queued, 0)
	end)

	-- The daemon offers every consumed key to this hook before the layout
	-- emulation: a Ctrl+U that read the driver state raised there and never
	-- reached the consumers behind it (CI run 44733461420).
	helpers.it("ctrl-magic-save: another key's shortcut chord reads no driver state and no config.toml", function()
		local Save = fresh()
		local reads = {}
		local opts = options({
			active = function() reads[#reads + 1] = "active" error("active read for a foreign chord") end,
			chosen_source = function() reads[#reads + 1] = "chosen" error("source read for a foreign chord") end,
			shortcut_owns = function() reads[#reads + 1] = "owns" error("slots read for a foreign chord") end,
			enabled = function() reads[#reads + 1] = "enabled" error("config.toml read for a foreign chord") end,
		})
		for _, code in ipairs({ 31, 22, 35 }) do
			for _, mods in ipairs({ { ctrl = true }, { ctrl = true, shift = true }, { alt = true }, { meta = true } }) do
				helpers.assert_eq(Save.on_key({ code = code, value = 1, mods = mods }, opts), false)
			end
		end
		helpers.assert_eq(Save.on_key({ code = 46, value = 1, mods = {} }, opts), false)
		helpers.assert_eq(Save.on_key({ code = 46, value = 1, mods = { altgr = true } }, opts), false)
		helpers.assert_eq(reads, {})
	end)

	helpers.it("ctrl-magic-save: the switch off, a chosen source, an owned chord or a pause leave the chord", function()
		local Save = fresh()
		local opts, state = options()
		local press = { code = 46, value = 1, mods = { meta = true } }
		state.enabled = false
		helpers.assert_eq(Save.on_key(press, opts), false, "the switch off")
		state.enabled = nil
		helpers.assert_eq(Save.on_key(press, opts), false, "an unreadable configuration consumes nothing")
		state.enabled, state.chosen = true, true
		helpers.assert_eq(Save.on_key(press, opts), false,
			"a key the user chose keeps every chord the layout gives it, as on Windows")
		state.chosen, state.owned = false, true
		helpers.assert_eq(Save.on_key(press, opts), false, "an assigned shortcut keeps its chord")
		state.owned, state.active = false, false
		helpers.assert_eq(Save.on_key(press, opts), false, "paused, or the magic key not replaced")
		helpers.assert_eq(#state.queued, 0)
	end)

	-- The Windows hotkeys fire on every auto-repeat: holding Ctrl+Shift+★ saves
	-- again, and a pause mid-hold hands the repeats back to the application.
	helpers.it("ctrl-magic-save: each auto-repeat sends the chord held at that repeat", function()
		local Save = fresh()
		local opts, state = options()
		local consumed, repeat_callback = Save.on_key({ code = 46, value = 1, mods = { ctrl = true, shift = true } },
			opts)
		helpers.assert_eq(consumed, true)
		helpers.assert_type(repeat_callback, "function", "the held chord owns its repeats")
		helpers.assert_eq(repeat_callback({ code = 46, value = 2, mods = { ctrl = true, shift = true } }), true)
		helpers.assert_eq(repeat_callback({ code = 46, value = 2, mods = { ctrl = true } }), true,
			"Shift released mid-hold sends the chord now held")
		helpers.assert_eq(repeat_callback({ code = 46, value = 2, mods = { shift = true } }), false,
			"a repeat with no shortcut modifier is the layout's")
		helpers.assert_eq(repeat_callback({ code = 31, value = 2, mods = { ctrl = true } }), false,
			"another key's repeat is not its own")
		run_queued(state)
		helpers.assert_eq(state.pressed, { "ctrl+shift+s", "ctrl+shift+s", "ctrl+s" })
		state.active = false
		helpers.assert_eq(repeat_callback({ code = 46, value = 2, mods = { ctrl = true } }), false)
	end)

	-- The magic editor's Super+★ and every keyboard slot on a chord of the magic
	-- key keep it: the daemon asks the slots first, then the save, then the
	-- layout emulation, which would type the chord's own level.
	helpers.it("ctrl-magic-save: the daemon decides the keyboard slots before the save", function()
		local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = handle:read("*a")
		handle:close()
		local slots = source:find("if consume_bound_chord(detail) then return true end", 1, true)
		local save = source:find('require("modules.shortcuts.ctrl_magic_save").on_key(detail', 1, true)
		local emulation = source:find('require("modules.keymap.layout_emulation").on_key(detail)', 1, true)
		helpers.assert_true(slots ~= nil and save ~= nil and emulation ~= nil, "the three consumers exist")
		helpers.assert_true(slots < save and save < emulation, "slots, then the save, then the emulation")
	end)

	helpers.it("ctrl-magic-save: a caller without the hook's ports is refused", function()
		local Save = fresh()
		for _, missing in ipairs({ "plain_text", "shortcut_owns" }) do
			local opts = options({ [missing] = false })
			helpers.assert_throws(function() Save.on_key({ code = 46, value = 1, mods = { ctrl = true } }, opts) end)
		end
	end)

	helpers.it("ctrl-magic-save: the switch is config.toml's, over the manifest default", function()
		local path = os.tmpname()
		local saved = package.loaded["settings.engine.paths"]
		package.loaded["settings.engine.paths"] = { config = function() return path end }
		local ok, err = pcall(function()
			Sandbox.write_bytes(path, "")
			local Save = fresh()
			helpers.assert_eq(Save.enabled(), false, "the manifest default is off")
			helpers.assert_eq(Save.set(true), true)
			helpers.assert_eq(Save.enabled(), true)
			helpers.assert_eq(Save.set(false), true)
			helpers.assert_eq(Save.enabled(), false)
			local marked = {}
			local function mark(...) marked[#marked + 1] = table.concat({ ... }, ".") end
			Save.mark_config_reads({ layout = { ctrl_magic_save = true } }, mark)
			Save.mark_config_reads({ layout = { ctrl_magic_save = "yes" } }, mark)
			helpers.assert_eq(marked, { "layout.ctrl_magic_save" }, "an outdated value is left for the cleanup")
		end)
		package.loaded["settings.engine.paths"] = saved
		os.remove(path)
		if not ok then error(err, 0) end
	end)
end)
