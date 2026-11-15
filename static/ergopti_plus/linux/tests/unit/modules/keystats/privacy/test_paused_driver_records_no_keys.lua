--- tests/unit/modules/keystats/privacy/test_paused_driver_records_no_keys.lua

--- ==============================================================================
--- MODULE: A Paused Driver Records No Keys (Linux)
--- DESCRIPTION:
--- EDD-1: a pause stops everything that acts on typing, the metrics included.
--- macOS discards keystats taps while paused and Windows' hook dispatcher
--- returns while suspended, yet Linux Main still fed every physical key-down to
--- the heatmap and the live WPM, and counted every modifier chord, while paused
--- (paused-records-no-keys). Main's handle_physical and consume_bound_chord are
--- compiled against recorded collaborators, as test_bound_chord_emulated_letter
--- does.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Compiles one of Main's local functions with the given environment.
--- @param first_marker string Start of the function.
--- @param last_marker string Text just after it, or its closing line when
---   keep_marker is set.
--- @param name string Function name returned by the chunk.
--- @param environment table Its collaborators.
--- @param keep_marker boolean|nil Whether last_marker closes the function.
--- @return function compiled
local function compile(first_marker, last_marker, name, environment, keep_marker)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = assert(file:read("*a")); assert(file:close())
	local first = assert(source:find(first_marker, 1, true), first_marker)
	local last = assert(source:find(last_marker, first, true), last_marker)
	local body = "local capture_owned_scancodes, physical_privacy_admission = {}, nil\n"
		.. source:sub(first, keep_marker and last + #last_marker - 1 or last) .. "\nreturn " .. name
	setmetatable(environment, { __index = _G })
	local chunk
	if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
	else chunk = assert(load(body, "Main " .. name, "t", environment)) end
	return chunk()
end

--- The collaborators both callbacks read, recording what metrics receive.
--- @param state table { paused = boolean }
--- @param recorded table Receives one entry per metrics call.
--- @return table environment
local function environment_for(state, recorded)
	local function record(kind) return function() recorded[#recorded + 1] = kind; return true end end
	return {
		InputEvent = { VALUE_DOWN = 1 },
		TapHold = { observe_copy_activity = function() end },
		gestures = { release_clicks_on_activity = function() end },
		secure_focus_guard = { blocks_text = function() return false end },
		user_hotstring_native = nil,
		keystats = {
			is_unrecorded_app = function() return false end,
			suppress = function() end, unsuppress = function() end,
			media_id = function(code) return code == 164 end,
			record_media_press = record("media"),
			record_physical_key = record("key"),
			record_shortcut = record("shortcut"),
			discard_roi = function() end,
			record_roi_key = function() end,
		},
		keyboard_hook = { source_device_identity = function() return "device" end },
		Monotonic = { now_ms = function() return 0 end },
		script_actions = {
			is_paused = function() return state.paused end,
			pause_epoch = function() return 0 end,
		},
		shortcuts = { is_enabled = function() return true end, configuration_admitted = function() return true end },
		keyboard_shortcuts = {
			consume = function() return true end,
			dispatch = function() return true end,
			collision_identity = function(key) return key end,
			chord_name = function() return "Ctrl+S" end,
		},
		prediction_engine = nil,
		engine = { forget_ai_context = function() end },
		WordReset = { observe_key = function() end, is_terminal_app = function() return false end },
		opts = { dry_run = false },
		event_loop = { defer = function(fn) return fn end },
		input_capture_gate = { blocks_text = function() return false end },
		_cached_app_id = "editor",
		require = function(name)
			if name == "modules.keymap.layout_emulation" then return { chord_key = function() return nil end } end
			return require(name)
		end,
	}
end

helpers.describe("a paused Linux driver records no keys (EDD-1)", function()
	helpers.it("(paused-records-no-keys) a physical key-down feeds no metrics while paused", function()
		local state, recorded = { paused = true }, {}
		local physical = compile("\tlocal function handle_physical(", "\n\tlocal on_physical",
			"handle_physical", environment_for(state, recorded))
		physical(30, "a", "a", 1, "device")
		physical(164, "playpause", nil, 1, "device")
		helpers.assert_eq(recorded, {}, "neither the heatmap, the live WPM nor a media key while paused")
		state.paused = false
		physical(30, "a", "a", 1, "device")
		physical(164, "playpause", nil, 1, "device")
		helpers.assert_eq(recorded, { "key", "media" }, "resumed, every key-down counts again")
	end)

	helpers.it("(paused-records-no-keys) a chord consumed while paused is not counted", function()
		local state, recorded = { paused = true }, {}
		local consume = compile("\tlocal function consume_bound_chord(detail)", "\n\tlocal on_consume",
			"consume_bound_chord", environment_for(state, recorded))
		helpers.assert_true(consume({ code = 31, key = "s", mods = { ctrl = true } }))
		helpers.assert_eq(recorded, {}, "a paused driver counts no chord")
		state.paused = false
		helpers.assert_true(consume({ code = 31, key = "s", mods = { ctrl = true } }))
		helpers.assert_eq(recorded, { "shortcut" }, "resumed, a chord counts again")
	end)

	helpers.it("(paused-records-no-keys) a modifier chord typed while paused is not counted", function()
		local state, recorded = { paused = true }, {}
		local control = compile("\tlocal function handle_control(key_name, detail)", "\n\tend\n",
			"handle_control", environment_for(state, recorded), true)
		control("shortcut", { code = 31, key = "s", mods = { ctrl = true } })
		helpers.assert_eq(recorded, {}, "a paused driver counts no chord")
	end)
end)
