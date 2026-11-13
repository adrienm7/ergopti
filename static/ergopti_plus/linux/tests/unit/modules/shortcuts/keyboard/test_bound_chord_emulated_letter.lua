--- tests/unit/modules/shortcuts/keyboard/test_bound_chord_emulated_letter.lua

--- ==============================================================================
--- MODULE: A Keyboard Slot Follows the Emulated Letter (Linux)
--- DESCRIPTION:
--- Windows registers a keyboard shortcut slot on the key that types its letter
--- in the emulated layout (_KeyboardSlotLayoutVariant, KeyboardShortcutRunLayoutChord).
--- Linux offered the slot consumer the system layout's key: under Ergopti,
--- Ctrl on the key typing « z » ran the ctrl+q slot (ILX-001). Main's own
--- consume_bound_chord is compiled against recorded collaborators.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Compiles Main's consume_bound_chord with the given emulation.
--- @param emulation table Stand-in for modules.keymap.layout_emulation.
--- @param offered table Receives each key offered to the slot consumer.
--- @return function consume_bound_chord
local function compile(emulation, offered)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = assert(file:read("*a")); assert(file:close())
	local first = assert(source:find("\tlocal function consume_bound_chord(detail)", 1, true))
	local last = assert(source:find("\n\tlocal on_consume", first, true))
	local body = source:sub(first, last) .. "\nreturn consume_bound_chord"
	local environment = setmetatable({
		shortcuts = { is_enabled = function() return true end, configuration_admitted = function() return true end },
		keyboard_shortcuts = {
			consume = function(detail) offered[#offered + 1] = detail.key; return detail.key == "z" end,
			chord_name = function() return nil end,
		},
		script_actions = { pause_epoch = function() return 0 end, is_paused = function() return false end },
		opts = { dry_run = false },
		event_loop = { defer = function(fn) return fn end },
		input_capture_gate = { blocks_text = function() return false end },
		keystats = { record_shortcut = function() end },
		Monotonic = { now_ms = function() return 0 end },
		_cached_app_id = "editor",
		require = function(name)
			if name == "layouts.engine.registry.emulation" then return emulation end
			return require(name)
		end,
	}, { __index = _G })
	local chunk
	if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
	else chunk = assert(load(body, "Main consume_bound_chord", "t", environment)) end
	return chunk()
end

helpers.describe("keyboard slots under an emulated layout (Linux)", function()
	helpers.it("offers the slot consumer the emulated letter of a chord (ilx-001-slot-emulated-letter)", function()
		local offered = {}
		local consume = compile({ chord_key = function(detail)
			return detail.code == 16 and detail.mods.ctrl and "z" or nil
		end }, offered)
		local detail = { code = 16, key = "q", mods = { ctrl = true } }
		helpers.assert_true(consume(detail), "Ctrl on the key typing « z » runs the ctrl+z slot")
		helpers.assert_eq(offered, { "z" })
		helpers.assert_eq(detail.key, "q", "the hook's own detail is left as it came")
		helpers.assert_eq(consume({ code = 30, key = "a", mods = { ctrl = true } }), false)
		helpers.assert_eq(offered, { "z", "a" }, "a key the emulation leaves keeps its system letter")
	end)
end)
