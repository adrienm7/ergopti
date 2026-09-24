--- tests/unit/meta/test_tap_hold_writer.lua

--- ==============================================================================
--- MODULE: The Tap-Hold Menu Writes What The Engine Reads
--- DESCRIPTION:
--- Every tray change goes through this writer into the user's tap_hold.toml and
--- is read back by the loader the engine runs on. The previous writer scanned
--- lines by hand, wrote strings without escaping them (a `"` in a value broke
--- the whole file), could not clear a default hold, had no « Disable all » and
--- restarted kanata. Each case below writes, then reads back with the real
--- loader: a writer that is right about its own file and wrong about what the
--- engine sees is the bug this suite exists for.
--- ==============================================================================

local helpers = require("tests.helpers")
local Loader = require("platform.remap.tap_hold_loader")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")

--- A writer bound to a throwaway file.
--- @param reload_ok boolean|nil What the reload reports (true by default).
--- @return table writer, string path, table state { reloads }
local function fresh_writer(reload_ok)
	local path = os.tmpname()
	os.remove(path)
	local state = { reloads = 0 }
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({
		path = path,
		reload = function() state.reloads = state.reloads + 1; return reload_ok ~= false end,
		is_tap_action = function(id) return id == "copy" or id == "paste" or id == "enter" end,
		is_hold_option = function(kind, id)
			return (kind == "none" and id == "") or (kind == "modifier" and (id == "ctrl" or id == "ctrl+shift"))
				or (kind == "layer" and id == "nav")
		end,
	})
	return writer, path, state
end

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return "" end
	local content = fh:read("*a")
	fh:close()
	return content
end

local function write_file(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- What the engine will run after the change.
local function effective(path)
	return Loader.load(DEFAULTS, path)
end

helpers.describe("tap-hold writer: a tray change reaches the engine", function()

	helpers.it("sets a tap in the shared schema and reloads the engine", function()
		local writer, path, state = fresh_writer()
		helpers.assert_true(writer.set_tap("left_shift", "paste"))
		helpers.assert_true(read_file(path):find("[tap_hold.keys.left_shift]", 1, true) ~= nil)
		helpers.assert_eq(effective(path).keys.left_shift.tap_action, "paste")
		helpers.assert_eq(effective(path).keys.left_shift.hold_modifier, "shift", "the default hold stays")
		helpers.assert_eq(state.reloads, 1, "in force at once, no restart")
		os.remove(path)
	end)

	helpers.it("writes only the keys the user changed, and keeps the earlier ones", function()
		local writer, path = fresh_writer()
		writer.set_tap("left_shift", "paste")
		writer.set_tap("left_ctrl", "copy")
		local content = read_file(path)
		helpers.assert_true(content:find("left_shift", 1, true) and content:find("left_ctrl", 1, true))
		helpers.assert_true(not content:find("caps_lock", 1, true), "an untouched key keeps inheriting")
		os.remove(path)
	end)

	helpers.it("swaps a modifier hold for the navigation layer, and back", function()
		local writer, path = fresh_writer()
		writer.set_hold("caps_lock", "layer", "nav")
		local keys = effective(path).keys
		helpers.assert_eq(keys.caps_lock.hold_layer, "nav")
		helpers.assert_nil(keys.caps_lock.hold_modifier, "CapsLock is the layer, no longer Ctrl")
		writer.set_hold("caps_lock", "modifier", "ctrl+shift")
		keys = effective(path).keys
		helpers.assert_eq(keys.caps_lock.hold_modifier, "ctrl+shift")
		helpers.assert_nil(keys.caps_lock.hold_layer)
		os.remove(path)
	end)

	helpers.it("clears a default hold with the none option", function()
		local writer, path = fresh_writer()
		writer.set_hold("left_alt", "none", "")
		local key = effective(path).keys.left_alt
		helpers.assert_nil(key.hold_layer, "the default layer is gone")
		helpers.assert_eq(key.hold_modifier, "", "and no modifier replaces it")
		os.remove(path)
	end)

	helpers.it("makes a key native: its own tap and no hold", function()
		local writer, path = fresh_writer()
		writer.set_native("caps_lock")
		local key = effective(path).keys.caps_lock
		helpers.assert_eq(key.tap_action, "")
		helpers.assert_eq(key.hold_modifier, "")
		local Engine = require("platform.remap.tap_hold_engine")
		local engine = Engine.new({ keys = effective(path).keys, tap_min_ms = 50, one_shot_timeout_ms = 2000 })
		helpers.assert_true(not engine:handles(58), "the engine leaves CapsLock alone")
		os.remove(path)
	end)

	helpers.it("disables everything, and the defaults do not come back", function()
		local writer, path = fresh_writer()
		writer.set_tap("left_shift", "paste")
		writer.disable_all()
		helpers.assert_nil(next(effective(path).keys), "no key at all")
		os.remove(path)
	end)

	helpers.it("resets to the shared defaults by removing the file", function()
		local writer, path, state = fresh_writer()
		writer.disable_all()
		helpers.assert_true(writer.reset_all())
		helpers.assert_eq(read_file(path), "")
		helpers.assert_eq(effective(path).keys.left_shift.tap_action, "copy")
		helpers.assert_eq(state.reloads, 2)
		os.remove(path)
	end)

	helpers.it("switches the feature off in the file", function()
		local writer, path = fresh_writer()
		writer.set_enabled(false)
		helpers.assert_true(not effective(path).enabled)
		writer.set_enabled(true)
		helpers.assert_true(effective(path).enabled)
		os.remove(path)
	end)

	helpers.it("writes a delay the loader reads back, and refuses one out of range", function()
		local writer, path = fresh_writer()
		helpers.assert_true(writer.set_threshold("caps_lock", 0.3))
		helpers.assert_eq(effective(path).keys.caps_lock.time_activation_seconds, 0.3)
		helpers.assert_true(not writer.set_threshold("caps_lock", 30))
		helpers.assert_true(not writer.set_threshold("caps_lock", 0))
		helpers.assert_eq(effective(path).keys.caps_lock.time_activation_seconds, 0.3)
		os.remove(path)
	end)

	helpers.it("refuses an unknown key, tap or hold, and writes nothing", function()
		local writer, path, state = fresh_writer()
		helpers.assert_true(not writer.set_tap("not_a_key", "copy"))
		helpers.assert_true(not writer.set_tap("left_shift", 'x" = 1'))
		helpers.assert_true(not writer.set_hold("left_shift", "layer", "sym"))
		helpers.assert_eq(read_file(path), "")
		helpers.assert_eq(state.reloads, 0)
		os.remove(path)
	end)

	helpers.it("never overwrites a file that does not parse", function()
		local writer, path = fresh_writer()
		local broken = "[tap_hold.keys.left_shift\ntap_action = \"paste\"\n"
		write_file(path, broken)
		helpers.assert_true(not writer.set_tap("left_shift", "copy"))
		helpers.assert_eq(read_file(path), broken, "the user's text is left as it was")
		os.remove(path)
	end)

	helpers.it("escapes what it writes and keeps data it does not own", function()
		local writer, path = fresh_writer()
		write_file(path, '[other]\nnote = "say \\"hi\\""\n[tap_hold.keys.left_shift]\ncustom = 3\n')
		writer.set_tap("left_shift", "paste")
		local parsed = require("toml_codec").decode(read_file(path))
		helpers.assert_eq(parsed.other.note, 'say "hi"', "a quote survives the round trip")
		helpers.assert_eq(parsed.tap_hold.keys.left_shift.custom, 3)
		os.remove(path)
	end)

	helpers.it("reports a change the engine could not reload", function()
		local writer, path = fresh_writer(false)
		helpers.assert_true(not writer.set_tap("left_shift", "paste"))
		os.remove(path)
	end)

end)
