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
		-- The shipped catalogue, through the same canonicaliser the manager uses.
		canonical_hold = function(kind, id)
			return require("tap_hold.hold_options").canonical(kind, id, Loader.load(DEFAULTS, nil).hold_picker)
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
		write_file(path, require("tests.support.tap_hold_fixture").with_preset())
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

	helpers.it("stores a hold in the canonical spelling the loader reads back", function()
		local writer, path = fresh_writer()
		helpers.assert_true(writer.set_hold("caps_lock", "modifier", "Shift + Ctrl"))
		helpers.assert_true(read_file(path):find('hold_modifier = "ctrl+shift"', 1, true) ~= nil,
			"the file holds the picker's id, not the spelling it was given")
		helpers.assert_true(writer.set_hold("right_ctrl", "modifier", "AltGr"))
		helpers.assert_eq(effective(path).keys.right_ctrl.hold_modifier, "alt_gr")
		helpers.assert_true(not writer.set_hold("caps_lock", "modifier", "hyper"), "an unknown modifier is refused")
		helpers.assert_true(not writer.set_hold("caps_lock", "modifier", ""), "a modifier hold needs one")
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
		local engine = Engine.new({ keys = effective(path).keys, tap_min_ms = 50, one_shot_timeout_ms = 2000,
			key_text = function() return nil end, plan_text = function() return nil end, one_shot_result = function() return nil end, })
		helpers.assert_true(not engine:handles(58), "the engine leaves CapsLock alone")
		os.remove(path)
	end)

	helpers.it("renders a clear that the defaults never come back through", function()
		local writer, path = fresh_writer()
		writer.set_tap("left_shift", "paste")
		local rows = { { section = "tap_holds", key = "enabled", delete = true } }
		local candidate = writer.render_scope("clear", require("toml_codec").decode(read_file(path)), rows,
			Loader.preset_keys(DEFAULTS))
		write_file(path, candidate)
		helpers.assert_nil(next(effective(path).keys), "no key at all")
		helpers.assert_eq(effective(path).enabled, false)
		os.remove(path)
	end)

	helpers.it("renders the shared preset explicitly and preserves unknown nested fields", function()
		local writer, path, state = fresh_writer()
		write_file(path, '[tap_hold]\nenabled = false\ninherit_defaults = false\n'
			.. '[tap_hold.keys.left_shift]\ntap_action = "paste"\nenabled = false\n'
			.. '[tap_hold.keys.left_shift.custom]\nnote = "keep"\n'
			.. '[other]\nvalue = 17\n')
		local rows = { { section = "tap_holds", key = "enabled", value = true } }
		local candidate = writer.render_scope("recommended", require("toml_codec").decode(read_file(path)), rows,
			Loader.preset_keys(DEFAULTS))
		write_file(path, candidate)
		local stored = require("toml_codec").decode(read_file(path))
		helpers.assert_nil(stored.tap_hold.inherit_defaults, "the preset is written, never inherited")
		helpers.assert_eq(stored.tap_hold.keys.left_shift.custom.note, "keep")
		helpers.assert_eq(stored.other.value, 17)
		helpers.assert_eq(effective(path).enabled, true)
		helpers.assert_eq(effective(path).keys.left_shift.tap_action, "copy")
		helpers.assert_eq(state.reloads, 0, "rendering publishes and reloads nothing")
		os.remove(path)
	end)

	helpers.it("renders a clear of only owned tap-hold fields", function()
		local writer = fresh_writer()
		local document = require("toml_codec").decode('[tap_hold]\nenabled = true\ninherit_defaults = true\nfuture = "keep"\n'
			.. '[tap_hold.keys.left_shift]\ntap_action = "paste"\nhold_modifier = "shift"\n'
			.. 'enabled = true\ntime_activation_seconds = 0.3\n'
			.. '[tap_hold.keys.left_shift.custom]\nnote = "keep"\n'
			.. '[tap_hold.keys.left_ctrl]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.future_key]\ntap_action = "future"\nenabled = true\n'
			.. '[other]\nvalue = 17\n')
		local rows = { { section = "tap_holds", key = "enabled", delete = true } }
		local stored = require("toml_codec").decode(writer.render_scope("clear", document, rows, Loader.preset_keys(DEFAULTS)))
		helpers.assert_eq(stored.tap_hold.keys.left_shift, { custom = { note = "keep" } })
		helpers.assert_nil(stored.tap_hold.keys.left_ctrl)
		helpers.assert_eq(stored.tap_hold.keys.future_key, { tap_action = "future", enabled = true })
		helpers.assert_nil(stored.tap_hold.enabled)
		helpers.assert_nil(stored.tap_hold.inherit_defaults)
		helpers.assert_eq(stored.tap_hold.future, "keep")
		helpers.assert_eq(stored.other.value, 17)
	end)

	helpers.it("refuses to render a row it does not own or a malformed tap_hold table", function()
		local writer = fresh_writer()
		local preset = Loader.preset_keys(DEFAULTS)
		helpers.assert_throws(function()
			writer.render_scope("clear", {}, { { section = "tap_holds", key = "future", delete = true } }, preset)
		end)
		helpers.assert_throws(function() writer.render_scope("clear", { tap_hold = "opaque" }, {}, preset) end)
		helpers.assert_throws(function() writer.render_scope("factory", {}, {}, preset) end)
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
