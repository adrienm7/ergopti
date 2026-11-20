--- tests/unit/modules/shortcuts/keyboard/test_ctrl_magic_save.lua

--- ==============================================================================
--- MODULE: Ctrl + Magic Key Saves (Linux)
--- DESCRIPTION:
--- Windows turns Ctrl alone on the layout's own magic key into a bare Ctrl+S
--- when [layout] ctrl_magic_save is on (LayoutRegistry_MagicKeyHotkeys). Linux
--- had no equivalent: Ctrl+★ reached the application as a chord nothing binds.
--- These tests pin the Windows contract: Ctrl alone, the key whose plain press
--- types the magic key, never a physical magic key the user chose, the switch
--- read from config.toml at the press, and every auto-repeat saving again.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("tests.lua.settings.unused_keys_contract").sandbox

-- KEY_C types the magic key, KEY_S types « s ».
local PLAIN = { [46] = "★", [31] = "s" }

local function fresh()
	package.loaded["modules.shortcuts.ctrl_magic_save"] = nil
	return require("modules.shortcuts.ctrl_magic_save")
end

--- The hook's ports, with the switch on, the automatic source and ★ as the magic key.
local function options(overrides)
	local state = { queued = {}, pressed = {}, active = true, enabled = true, chosen = false }
	local built = {
		active = function() return state.active end,
		magic_key = function() return "★" end,
		chosen_source = function() return state.chosen end,
		plain_text = function(code) return PLAIN[code] end,
		enabled = function() return state.enabled end,
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

helpers.describe("linux Ctrl + magic key saves (linux-ctrl-magic-save)", function()
	helpers.it("ctrl-magic-save: Ctrl alone on the layout's magic key presses Ctrl+S on the next tick", function()
		local Save = fresh()
		local opts, state = options()
		helpers.assert_eq(Save.on_key({ code = 46, value = 1, mods = { ctrl = true } }, opts), true)
		helpers.assert_eq(#state.pressed, 0, "nothing is pressed inside the consumption callback")
		run_queued(state)
		helpers.assert_eq(state.pressed, { "ctrl+s" })
	end)

	helpers.it("ctrl-magic-save: another chord, another key or a bare press stays the application's", function()
		local Save = fresh()
		local opts, state = options()
		for _, mods in ipairs({ { ctrl = true, shift = true }, { ctrl = true, alt = true },
			{ ctrl = true, altgr = true }, { ctrl = true, meta = true }, {}, { shift = true } }) do
			helpers.assert_eq(Save.on_key({ code = 46, value = 1, mods = mods }, opts), false)
		end
		helpers.assert_eq(Save.on_key({ code = 31, value = 1, mods = { ctrl = true } }, opts), false,
			"Ctrl on a key that types no magic key keeps its own chord")
		helpers.assert_eq(Save.on_key({ code = 46, value = 0, mods = { ctrl = true } }, opts), false,
			"a release decides nothing")
		helpers.assert_eq(#state.queued, 0)
	end)

	helpers.it("ctrl-magic-save: the switch off, a chosen physical source or a pause leave Ctrl+★ alone", function()
		local Save = fresh()
		local opts, state = options()
		local press = { code = 46, value = 1, mods = { ctrl = true } }
		state.enabled = false
		helpers.assert_eq(Save.on_key(press, opts), false, "the switch off")
		state.enabled = nil
		helpers.assert_eq(Save.on_key(press, opts), false, "an unreadable configuration consumes nothing")
		state.enabled, state.chosen = true, true
		helpers.assert_eq(Save.on_key(press, opts), false,
			"a key the user chose keeps every chord the layout gives it, as on Windows")
		state.chosen, state.active = false, false
		helpers.assert_eq(Save.on_key(press, opts), false, "paused, or the magic key not replaced")
		helpers.assert_eq(#state.queued, 0)
	end)

	-- The Windows ^SCxxx hotkey fires on every auto-repeat: holding Ctrl+★ saves
	-- again, and a pause mid-hold hands the repeats back to the application.
	helpers.it("ctrl-magic-save: each auto-repeat saves again while Ctrl alone is held", function()
		local Save = fresh()
		local opts, state = options()
		local consumed, repeat_callback = Save.on_key({ code = 46, value = 1, mods = { ctrl = true } }, opts)
		helpers.assert_eq(consumed, true)
		helpers.assert_type(repeat_callback, "function", "the held chord owns its repeats")
		helpers.assert_eq(repeat_callback({ code = 46, value = 2, mods = { ctrl = true } }), true)
		helpers.assert_eq(repeat_callback({ code = 46, value = 2, mods = { ctrl = true, shift = true } }), false,
			"Shift added mid-hold is another chord")
		helpers.assert_eq(repeat_callback({ code = 31, value = 2, mods = { ctrl = true } }), false,
			"another key's repeat is not its own")
		run_queued(state)
		helpers.assert_eq(state.pressed, { "ctrl+s", "ctrl+s" })
		state.active = false
		helpers.assert_eq(repeat_callback({ code = 46, value = 2, mods = { ctrl = true } }), false)
	end)

	helpers.it("ctrl-magic-save: a caller without the hook's ports is refused", function()
		local Save = fresh()
		local opts = options({ plain_text = false })
		helpers.assert_throws(function() Save.on_key({ code = 46, value = 1, mods = { ctrl = true } }, opts) end)
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
