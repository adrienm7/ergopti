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

--- A file's content, nil when it is absent (read_file() answers "" for both).
local function read_or_nil(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Runs body(writer, dir, state) with a writer bound to the tap_hold.toml of a
--- private configuration folder, as the daemon binds it.
--- @param opts table|nil { reload_ok = boolean, layers = false to bind no layer folder }
local function with_folder_writer(opts, body)
	opts = opts or {}
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local state = { reloads = 0 }
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({
		path = dir .. "/tap_hold.toml",
		reload = function() state.reloads = state.reloads + 1; return opts.reload_ok ~= false end,
		is_tap_action = function(id) return id == "copy" end,
		canonical_hold = function(kind, id)
			return require("tap_hold.hold_options").canonical(kind, id, Loader.load(DEFAULTS, nil).hold_picker)
		end,
		layers = opts.layers ~= false
			and { shared_root = require("infra.paths").shared_root(), config_dir = dir } or nil,
	})
	local ok, err = pcall(body, writer, dir, state)
	for _, name in ipairs({ "tap_hold.toml", "tap_hold.toml.tmp", "layers.toml" }) do os.remove(dir .. "/" .. name) end
	os.execute('rmdir "' .. dir .. '"')
	if not ok then error(err, 0) end
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

	-- Picking the navigation layer as a key's hold wrote hold_layer and nothing
	-- else: in a folder with no layers.toml the key entered a layer that binds
	-- no key. The pick brings the recommended layer along, as the restore does.
	helpers.it("(hold-picker-brings-the-layer-2026-10-01) picking the layer as a hold creates layers.toml from the recommended layer", function()
		local preset = read_or_nil(require("infra.paths").shared("keymap/layers.recommended.toml"))
		helpers.assert_type(preset, "string", "the shipped layer must be readable")
		with_folder_writer(nil, function(writer, dir, state)
			helpers.assert_true(writer.set_hold("caps_lock", "modifier", "ctrl"))
			helpers.assert_nil(read_or_nil(dir .. "/layers.toml"), "a modifier hold brings no layer file")
			helpers.assert_true(writer.set_hold("caps_lock", "layer", "nav"))
			helpers.assert_eq(read_or_nil(dir .. "/layers.toml"), preset, "the recommended layer's exact bytes")
			helpers.assert_eq(effective(dir .. "/tap_hold.toml").keys.caps_lock.hold_layer, "nav")
			helpers.assert_eq(state.reloads, 2, "the engine reloads once the layer is there")
		end)
	end)

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) an existing layers.toml is the user's and stays byte for byte", function()
		with_folder_writer(nil, function(writer, dir)
			write_file(dir .. "/layers.toml", "# my own layer\n")
			local own = read_or_nil(dir .. "/layers.toml")
			helpers.assert_true(writer.set_hold("caps_lock", "layer", "nav"))
			helpers.assert_eq(read_or_nil(dir .. "/layers.toml"), own)
			write_file(dir .. "/tap_hold.toml", "[tap_hold.keys.left_shift\n")
			helpers.assert_true(not writer.set_hold("caps_lock", "layer", "nav"), "a file that does not parse refuses the change")
			helpers.assert_eq(read_or_nil(dir .. "/layers.toml"), own, "a refused change removes only a file the pick created")
		end)
	end)

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) a refused key write takes the layer it created back", function()
		with_folder_writer(nil, function(writer, dir)
			local broken = "[tap_hold.keys.left_shift\n"
			write_file(dir .. "/tap_hold.toml", broken)
			helpers.assert_true(not writer.set_hold("caps_lock", "layer", "nav"))
			helpers.assert_eq(read_file(dir .. "/tap_hold.toml"), broken, "the user's text is left as it was")
			helpers.assert_nil(read_or_nil(dir .. "/layers.toml"), "no layer file outlives a refused change")
		end)
	end)

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) a saved key keeps its layer when the engine does not reload", function()
		with_folder_writer({ reload_ok = false }, function(writer, dir)
			helpers.assert_true(not writer.set_hold("caps_lock", "layer", "nav"), "the failed reload is reported")
			helpers.assert_eq(effective(dir .. "/tap_hold.toml").keys.caps_lock.hold_layer, "nav", "the key is saved")
			helpers.assert_type(read_or_nil(dir .. "/layers.toml"), "string", "the layer the saved key enters stays")
		end)
	end)

	helpers.it("(hold-picker-brings-the-layer-2026-10-01) a writer bound to no layer folder writes no layer file", function()
		with_folder_writer({ layers = false }, function(writer, dir)
			helpers.assert_true(writer.set_hold("caps_lock", "layer", "nav"))
			helpers.assert_nil(read_or_nil(dir .. "/layers.toml"))
		end)
	end)

	-- The daemon is the caller that names the folder.
	helpers.it("(hold-picker-brings-the-layer-2026-10-01) the daemon binds the writer to the configuration folder's layer file", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local call = source:match('require%("platform%.remap%.tap_hold_writer"%)%.init%(%b{}%)')
		helpers.assert_type(call, "string", "the daemon must initialise the tap-hold writer")
		helpers.assert_true(call:find("layers%s*=%s*{") ~= nil and call:find("config_dir", 1, true) ~= nil
			and call:find("shared_root", 1, true) ~= nil, "the writer must be given the folder a layer hold needs")
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

-- The first-run wizard's Tap-Holds answer: it names a file of the folder it
-- sets up, which may not be the running one, and restarts the daemon after.
helpers.describe("tap-hold writer: the wizard imports only the checked keys", function()

	--- A throwaway path with no file behind it.
	local function absent_path()
		local path = os.tmpname()
		os.remove(path)
		return path
	end

	helpers.it("imports each key's preset exactly over a backup, switches the feature on and leaves the rest", function()
		local writer = helpers.load_module("platform.remap.tap_hold_writer")
		local path = absent_path()
		local original = '[tap_hold]\ninherit_defaults = false\n'
			.. '[tap_hold.keys.caps_lock]\ncustom = 3\n'
			.. '[tap_hold.keys.left_shift]\ntap_action = "paste"\n'
			.. '[other]\nvalue = 17\n'
		write_file(path, original)
		local preset = Loader.preset_keys(DEFAULTS)
		local imported, err, backup = writer.import_recommended(path, { "caps_lock", "left_alt" }, preset)
		helpers.assert_true(imported, tostring(err))
		helpers.assert_type(backup, "string", "the replaced file is backed up")
		helpers.assert_true(backup:find(path, 1, true) == 1, "beside itself: " .. backup)
		helpers.assert_eq(read_file(backup), original, "the backup holds the file's exact bytes")
		local loaded = effective(path)
		helpers.assert_eq(loaded.enabled, true, "an imported key is live once the daemon restarts")
		helpers.assert_eq(loaded.keys.caps_lock.tap_action, preset.caps_lock.tap_action)
		helpers.assert_eq(loaded.keys.caps_lock.hold_modifier, preset.caps_lock.hold_modifier)
		helpers.assert_eq(loaded.keys.caps_lock.time_activation_seconds, preset.caps_lock.time_activation_seconds)
		helpers.assert_eq(loaded.keys.left_alt.hold_layer, preset.left_alt.hold_layer)
		helpers.assert_eq(loaded.keys.left_shift.tap_action, "paste", "an unchecked key keeps what it had")
		helpers.assert_nil(loaded.keys.right_ctrl, "a key nobody checked is not written")
		local stored = require("toml_codec").decode(read_file(path))
		helpers.assert_eq(stored.tap_hold.keys.caps_lock.custom, 3, "a field the writer does not own survives")
		helpers.assert_eq(stored.tap_hold.inherit_defaults, false)
		helpers.assert_eq(stored.other.value, 17)
		os.remove(backup)
		os.remove(path)
	end)

	-- A re-run answered Yes imported over the keys the user had set.
	helpers.it("never imports over a key the user configured, and writes nothing", function()
		local writer = helpers.load_module("platform.remap.tap_hold_writer")
		local preset = Loader.preset_keys(DEFAULTS)
		local path = absent_path()
		for label, text in pairs({
			["another tap and hold"] = '[tap_hold.keys.caps_lock]\ntap_action = "copy"\nhold_layer = "nav"\n',
			["a disabled key"] = '[tap_hold.keys.caps_lock]\nenabled = false\n',
			["another delay"] = '[tap_hold.keys.caps_lock]\ntime_activation_seconds = 0.5\n',
		}) do
			write_file(path, text)
			local imported, err, backup = writer.import_recommended(path, { "left_alt", "caps_lock" }, preset)
			helpers.assert_eq(imported, false, label)
			helpers.assert_true(tostring(err):find("caps_lock", 1, true) ~= nil, label .. ": " .. tostring(err))
			helpers.assert_nil(backup, label)
			helpers.assert_eq(read_file(path), text, label .. ": the user's file is left as it was")
		end
		local recommended = '[tap_hold.keys.caps_lock]\ntime_activation_seconds = 0.35\ntap_action = "enter"\n'
			.. 'hold_modifier = "ctrl"\nenabled = true\n'
		write_file(path, recommended)
		local imported, err, backup = writer.import_recommended(path, { "caps_lock" }, preset)
		helpers.assert_true(imported, "a key already at its recommendation is not the user's: " .. tostring(err))
		os.remove(backup)
		os.remove(path)
	end)

	helpers.it("creates the file of a folder that has none", function()
		local writer = helpers.load_module("platform.remap.tap_hold_writer")
		local path = absent_path()
		local imported, _, backup = writer.import_recommended(path, { "tab" }, Loader.preset_keys(DEFAULTS))
		helpers.assert_true(imported)
		helpers.assert_nil(backup, "nothing to back up")
		local loaded = effective(path)
		helpers.assert_eq(loaded.enabled, true)
		helpers.assert_eq(loaded.keys.tab.tap_action, Loader.preset_keys(DEFAULTS).tab.tap_action)
		helpers.assert_nil(loaded.keys.caps_lock, "only the checked key")
		os.remove(path)
	end)

	helpers.it("refuses what it cannot import exactly, and writes nothing", function()
		local writer = helpers.load_module("platform.remap.tap_hold_writer")
		local preset = Loader.preset_keys(DEFAULTS)
		local path = absent_path()
		for label, keys in pairs({
			["unknown key"] = { "not_a_key" },
			["key without a recommendation"] = { "escape" },
			["key twice"] = { "tab", "tab" },
			["no key"] = {},
		}) do
			local imported, err = writer.import_recommended(path, keys, preset)
			helpers.assert_eq(imported, false, label)
			helpers.assert_type(err, "string", label)
			helpers.assert_eq(read_file(path), "", label .. ": nothing is written")
		end
		local broken = "[tap_hold.keys.left_shift\ntap_action = \"paste\"\n"
		write_file(path, broken)
		helpers.assert_eq(writer.import_recommended(path, { "tab" }, preset), false)
		helpers.assert_eq(read_file(path), broken, "the user's text is left as it was")
		write_file(path, 'tap_hold = "opaque"\n')
		helpers.assert_eq(writer.import_recommended(path, { "tab" }, preset), false)
		helpers.assert_eq(read_file(path), 'tap_hold = "opaque"\n')
		os.remove(path)
	end)

end)

helpers.describe("tap-hold writer: classified source refusal", function()
	local original = '# Keep this exact user file on refusal.\n'
		.. '[tap_hold]\nenabled = true\n'
		.. '[tap_hold.keys.left_shift]\ntap_action = "copy"\ncustom = "future"\n'
		.. '[future]\nopaque = ["one", "two"]\n'

	local function observe_refusal(fault, invoke)
		local writer, path, state = fresh_writer()
		write_file(path, original)
		local real_open, real_rename = io.open, os.rename
		local observed = { reads = 0, closes = 0, writes = 0, staging = 0, renames = 0 }
		local owned_handle
		io.open = function(target, mode)
			if target:sub(1, #path) == path and mode == "w" then observed.writes = observed.writes + 1 end
			if target == path .. ".tmp" then observed.staging = observed.staging + 1 end
			if target ~= path or mode ~= "r" then return real_open(target, mode) end
			observed.reads = observed.reads + 1
			if fault == "permission" then return nil, "owned source refused", 13 end
			if fault == "other_errno" then return nil, "owned source refused", 5 end
			if fault == "no_errno" then return nil, "owned source refused" end
			if fault == "string_errno" then return nil, "owned source refused", "2" end
			if fault == "open_raise" then error("owned source open raised") end
			local handle, err, code = real_open(target, mode)
			owned_handle = handle
			if not handle then return nil, err, code end
			return {
				read = function(_, format)
					if fault == "read_nil" then return nil, "owned source read refused" end
					if fault == "read_raise" then error("owned source read raised") end
					return owned_handle:read(format)
				end,
				close = function()
					observed.closes = observed.closes + 1
					local closed = owned_handle:close()
					if fault == "close_nil" then return nil, "owned source close refused" end
					if fault == "close_false" then return false, "owned source close refused" end
					if fault == "close_raise" then error("owned source close raised") end
					return closed
				end,
			}
		end
		os.rename = function(from, to)
			if from == path .. ".tmp" and to == path then observed.renames = observed.renames + 1 end
			return real_rename(from, to)
		end
		local call_ok, accepted = pcall(invoke, writer, path)
		io.open, os.rename = real_open, real_rename
		if owned_handle then pcall(owned_handle.close, owned_handle) end
		local unchanged, staged = read_or_nil(path), read_or_nil(path .. ".tmp")
		os.remove(path)
		os.remove(path .. ".tmp")
		helpers.assert_true(call_ok, "the classified read reports refusal without raising")
		helpers.assert_eq(accepted, false, "an unreadable source never grants write permission")
		helpers.assert_eq(observed.reads, 1, "the actual source read was reached")
		helpers.assert_eq(unchanged, original, "comments, known values and unknown neighbors retain exact bytes")
		helpers.assert_eq(observed.writes, 0, "neither a backup nor a candidate is opened for writing")
		helpers.assert_eq(observed.staging, 0, "refusal precedes temporary file creation")
		helpers.assert_eq(observed.renames, 0, "refusal precedes publication")
		helpers.assert_nil(staged, "there is no staged candidate")
		helpers.assert_eq(state.reloads, 0, "runtime reload never sees a refused candidate")
		if fault:match("^read_") or fault:match("^close_") then
			helpers.assert_true(owned_handle ~= nil, "the fault reached an actual opened source handle")
			helpers.assert_eq(observed.closes, 1, "the actual read owner closes its handle")
		end
	end

	for _, fault in ipairs({ "permission", "other_errno", "no_errno", "string_errno", "open_raise",
		"read_nil", "read_raise", "close_nil", "close_false", "close_raise" }) do
		helpers.it("refuses " .. fault .. " before the ordinary setter stages or reloads", function()
			observe_refusal(fault, function(writer) return writer.set_tap("left_shift", "paste") end)
		end)
	end

	helpers.it("refuses an unreadable source before the recommended import creates a backup", function()
		observe_refusal("permission", function(writer, path)
			return writer.import_recommended(path, { "tab" }, Loader.preset_keys(DEFAULTS))
		end)
	end)

	helpers.it("admits native ENOENT and publishes the actual missing-file setter", function()
		local writer, path, state = fresh_writer()
		local fh, _, code = io.open(path, "r")
		helpers.assert_nil(fh, "the source is physically absent")
		helpers.assert_eq(code, 2, "the native missing-file receipt is ENOENT")
		local accepted = writer.set_tap("left_shift", "paste")
		local loaded = effective(path)
		local staged = read_or_nil(path .. ".tmp")
		os.remove(path)
		helpers.assert_eq(accepted, true, "absence permits the real writer")
		helpers.assert_eq(state.reloads, 1, "only the acknowledged publication reloads")
		helpers.assert_eq(loaded.keys.left_shift.tap_action, "paste", "the real loader reads the published value")
		helpers.assert_nil(staged, "the actual rename retired its candidate")
	end)

	helpers.it("keeps unknown neighbors when the classified source read succeeds", function()
		local writer, path, state = fresh_writer()
		write_file(path, original)
		local accepted = writer.set_tap("left_shift", "paste")
		local document = require("toml_codec").decode(read_file(path))
		os.remove(path)
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(state.reloads, 1)
		helpers.assert_eq(document.tap_hold.keys.left_shift.tap_action, "paste")
		helpers.assert_eq(document.tap_hold.keys.left_shift.custom, "future")
		helpers.assert_eq(document.future.opaque[1], "one")
		helpers.assert_eq(document.future.opaque[2], "two")
	end)
end)

helpers.describe("tap-hold writer: staging write and close acknowledgement", function()
	local original = '# Preserve the complete source when staging is refused.\n'
		.. '[tap_hold]\nenabled = true\n'
		.. '[tap_hold.keys.left_shift]\ntap_action = "copy"\ncustom = "future"\n'
		.. '[future]\nopaque = ["left", "right"]\n'

	local function observe_staging(fault)
		local writer, path, state = fresh_writer()
		write_file(path, original)
		local real_open, real_rename, real_remove = io.open, os.rename, os.remove
		local observed = { opens = 0, writes = 0, closes = 0, renames = 0, removals = 0 }
		local handle, proxy
		io.open = function(target, mode)
			if target ~= path .. ".tmp" or mode ~= "w" then return real_open(target, mode) end
			observed.opens = observed.opens + 1
			local opened, err, code = real_open(target, mode)
			handle = opened
			if not opened then return nil, err, code end
			proxy = {
				write = function(self, text)
					observed.writes = observed.writes + 1
					local partial = fault:match("^write_") or fault == "cleanup_refused"
					local payload = partial and text:sub(1, math.floor(#text / 2)) or text
					local written, write_err, write_code = handle:write(payload)
					observed.native_write_ack = written == true or written == handle
					if fault == "write_raise" then error("owned staging write raised") end
					if fault == "write_nil" or fault == "cleanup_refused" then return nil, "owned staging write refused" end
					if fault == "write_false" then return false end
					if fault == "write_table" then return {} end
					if fault == "write_string" then return "written" end
					if fault == "write_foreign_handle" then return handle end
					if written == true then return true end
					if written ~= handle then return nil, write_err, write_code end
					return self
				end,
				close = function()
					observed.closes = observed.closes + 1
					local closed, close_err, close_code = handle:close()
					observed.native_close_ack = closed == true
					if fault == "close_raise" then error("owned staging close raised") end
					if fault == "close_nil" then return nil, "owned staging close refused" end
					if fault == "close_false" then return false end
					if fault == "close_string" then return "closed" end
					if fault == "close_handle" then return handle end
					return closed, close_err, close_code
				end,
			}
			return proxy
		end
		os.rename = function(from, to)
			if from == path .. ".tmp" and to == path then observed.renames = observed.renames + 1 end
			return real_rename(from, to)
		end
		os.remove = function(target)
			if target == path .. ".tmp" then
				observed.removals = observed.removals + 1
				if fault == "cleanup_refused" then return nil, "owned stage removal refused" end
			end
			return real_remove(target)
		end
		local call_ok, accepted = pcall(writer.set_tap, "left_shift", "paste")
		io.open, os.rename, os.remove = real_open, real_rename, real_remove
		if handle then pcall(handle.close, handle) end
		local source, staged = read_or_nil(path), read_or_nil(path .. ".tmp")
		os.remove(path)
		os.remove(path .. ".tmp")
		helpers.assert_true(call_ok, "the public setter reports staging refusal without raising")
		helpers.assert_eq(accepted, false, "a refused staging receipt cannot acknowledge a tray change")
		helpers.assert_true(handle ~= nil, "the fault reached an actual temporary file handle")
		helpers.assert_eq(observed.opens, 1)
		helpers.assert_eq(observed.writes, 1)
		helpers.assert_eq(observed.native_write_ack, true, "the temporary bytes were written by the native file owner")
		helpers.assert_eq(observed.closes, 1, "even a raised write closes its actual handle")
		helpers.assert_eq(observed.native_close_ack, true, "the real file handle was physically closed")
		helpers.assert_eq(observed.renames, 0, "an unacknowledged stage is never published")
		helpers.assert_eq(state.reloads, 0, "runtime sees no refused candidate")
		helpers.assert_eq(source, original, "known fields, comments and unknown neighbors retain exact bytes")
		helpers.assert_eq(observed.removals, 1, "cleanup concerns only the temporary file the writer opened")
		if fault == "cleanup_refused" then
			helpers.assert_type(staged, "string", "refused cleanup leaves its owned candidate, never the user source")
		else
			helpers.assert_nil(staged, "acknowledged cleanup retires the refused candidate")
		end
	end

	for _, fault in ipairs({ "write_nil", "write_false", "write_table", "write_string", "write_foreign_handle",
		"write_raise", "close_nil", "close_false", "close_string", "close_handle", "close_raise", "cleanup_refused" }) do
		helpers.it("refuses " .. fault .. " before publication and reload", function() observe_staging(fault) end)
	end

	helpers.it("publishes only after the actual file write and close acknowledge their owner", function()
		local writer, path, state = fresh_writer()
		write_file(path, original)
		local accepted = writer.set_tap("left_shift", "paste")
		local document = require("toml_codec").decode(read_file(path))
		local staged = read_or_nil(path .. ".tmp")
		os.remove(path)
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(state.reloads, 1)
		helpers.assert_eq(document.tap_hold.keys.left_shift.tap_action, "paste")
		helpers.assert_eq(document.tap_hold.keys.left_shift.custom, "future")
		helpers.assert_eq(document.future.opaque[1], "left")
		helpers.assert_eq(document.future.opaque[2], "right")
		helpers.assert_nil(staged)
	end)
end)
