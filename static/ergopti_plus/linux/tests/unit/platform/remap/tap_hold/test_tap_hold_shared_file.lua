--- tests/unit/platform/remap/tap_hold/test_tap_hold_shared_file.lua

--- ==============================================================================
--- MODULE: The Shared Tap-Hold File On Linux
--- DESCRIPTION:
--- Every driver keeps its tap-hold keys in one tap_hold.toml
--- (_shared/tap_hold/data/SCHEMA.md) and the manifest rows (the switch, the timings,
--- the key combinations) in config.toml. The cross-driver corpus
--- (_shared/tests/corpus/tap_hold_shared_file) holds, per driver, the pair its
--- writers produce: <name>.toml pinned here byte for byte for Linux, and
--- <name>.config.toml pinned as values. The Linux readers read every pair as
--- expected.toml says, and a Linux change over the macOS file keeps every leaf
--- Linux does not own (the Karabiner integration, a macOS hold).
--- ==============================================================================

local helpers = require("tests.helpers")
local Loader = require("platform.remap.tap_hold_loader")
local Paths = require("core.fs.engine.paths")
local Codec = require("core.text.engine.toml_codec")

local DEFAULTS = Paths.shared("tap_hold/data/defaults.toml")
local CORPUS = Paths.shared("tests/corpus/tap_hold_shared_file") .. "/"
-- Every pair of the corpus the Linux readers read; windows_written once the
-- Windows writer pins its own.
local PAIRS = { "linux_written", "macos_written" }
for _, name in ipairs({ "windows_written" }) do
	local probe = io.open(CORPUS .. name .. ".toml", "rb")
	if probe then probe:close(); PAIRS[#PAIRS + 1] = name end
end

require("tests.lua.keyboard.tap_hold_shared_file_contract").register(helpers, { driver = "linux", shared_root = Paths.shared_root() })

--- Reads a whole file, nil when it is absent.
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Writes a whole file.
local function write(path, text)
	local fh = assert(io.open(path, "wb")); fh:write(text); fh:close()
end

--- Runs body(writer, path) with a writer bound to a private folder's tap_hold.toml.
local function with_writer(body)
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({
		path = dir .. "/tap_hold.toml",
		reload = function() return true end,
		is_tap_action = function(id) return id == "copy" or id == "backspace" end,
		canonical_hold = function(kind, id)
			return require("tap_hold.engine.hold_options").canonical(kind, id, Loader.load(DEFAULTS, nil).hold_picker)
		end,
	})
	local ok, err = pcall(body, writer, dir .. "/tap_hold.toml", dir .. "/config.toml")
	for _, name in ipairs({ "tap_hold.toml", "tap_hold.toml.tmp", "config.toml", "config.toml.tmp" }) do
		os.remove(dir .. "/" .. name)
	end
	os.execute('rmdir "' .. dir .. '"')
	if not ok then error(err, 0) end
end

-- Thumb keys a Mac spells its own way (TCL-004, « follow the position »).
local SPELLINGS = Paths.shared("tests/corpus/tap_hold_spellings") .. "/"

helpers.describe("Mac thumb keys in the shared tap_hold.toml on Linux (tap-hold-spellings)", function()
	local expected = Codec.decode(assert(read(SPELLINGS .. "expected.toml"), "the spelling expectations are missing"))

	helpers.it("Linux reads a Mac thumb id as the PC key at its place (tap-hold-spellings)", function()
		local path = os.tmpname()
		write(path, assert(read(SPELLINGS .. "mac_thumb.toml")))
		local ok, loaded = pcall(Loader.load, DEFAULTS, path)
		os.remove(path)
		assert(ok, tostring(loaded))
		for key_id, fields in pairs(expected.reads.mac_thumb.linux.keys) do
			for field, value in pairs(fields) do
				helpers.assert_eq(loaded.keys[key_id] and loaded.keys[key_id][field], value, key_id .. "." .. field)
			end
		end
	end)
end)

helpers.describe("The shared tap_hold.toml on Linux (tap-hold-shared-file)", function()
	local expected = Codec.decode(assert(read(CORPUS .. "expected.toml"), "the corpus expectations are missing"))

	helpers.it("the Linux writers write the corpus pair: tap_hold.toml byte for byte, config.toml as values (tap-hold-shared-file)", function()
		with_writer(function(writer, path, config_path)
			for _, change in ipairs({
				function() return writer.set_enabled(true) end,
				function() return writer.set_global_threshold(0.25) end,
				function() return writer.set_lone_tap_max_ms(0) end,
				function() return writer.set_one_shot_timeout_ms(1500) end,
				function() return writer.set_tap("caps_lock", "backspace") end,
				function() return writer.set_hold("caps_lock", "modifier", "ctrl") end,
				function() return writer.set_tap("left_shift", "copy") end,
				function() return writer.set_hold("left_shift", "modifier", "shift") end,
				function() return writer.set_threshold("left_shift", 0.3) end,
				function() return writer.set_hold("tab", "layer", "nav") end,
				function() return writer.set_hold("win", "modifier", "ctrl+alt") end,
			}) do
				helpers.assert_true(change(), "each corpus change is saved")
			end
			helpers.assert_eq(read(path), read(CORPUS .. "linux_written.toml"))
			helpers.assert_eq(Codec.decode(assert(read(config_path), "the switch and timings reach config.toml")),
				Codec.decode(read(CORPUS .. "linux_written.config.toml")))
		end)
	end)

	for _, name in ipairs(PAIRS) do
		helpers.it("the Linux loader reads the " .. name .. " pair as expected.toml says (tap-hold-shared-file)", function()
			local want = expected.reads[name].linux
			local loaded = Loader.load(DEFAULTS, CORPUS .. name .. ".toml", CORPUS .. name .. ".config.toml")
			helpers.assert_eq(loaded.user_error, nil)
			for _, field in ipairs({ "enabled", "global_seconds", "lone_tap_max_ms", "one_shot_timeout_ms" }) do
				helpers.assert_eq(loaded[field], want[field], field)
			end
			local keys = {}
			for key_id, fields in pairs(loaded.keys) do
				keys[key_id] = { tap_action = fields.tap_action, hold_modifier = fields.hold_modifier,
					hold_layer = fields.hold_layer, time_activation_seconds = fields.time_activation_seconds }
			end
			helpers.assert_eq(keys, want.keys)
		end)

		helpers.it("the Linux key combinations read the " .. name .. " pair as expected.toml says (tap-hold-shared-file)", function()
			local want = expected.reads[name].linux.mod_combos
			local defaults = Loader.load(DEFAULTS, nil)
			local owner = require("modules.shortcuts.key_combinations").new({ keys = defaults.catalog,
				hold_picker = defaults.hold_picker, files = require("core.fs.adapters.file_system"),
				route = function() return CORPUS .. name .. ".config.toml" end,
				is_paused = function() return false end, changed = function() return true end,
				actions = { is_assignable = function(action) return action == "copy" end } })
			local token = {}
			helpers.assert_true(owner.acquire_configuration(token))
			local snapshot = owner.configuration_snapshot(token)
			helpers.assert_true(owner.release_configuration(token))
			helpers.assert_eq(snapshot.chord_enabled, want.enabled)
			helpers.assert_eq(snapshot.chord_settings, { simultaneous_threshold_ms = want.simultaneous_threshold_ms,
				combo_symmetric = want.symmetric })
			local chords = {}
			for pair, action in pairs(snapshot.chords) do if action ~= "none" then chords[pair] = action end end
			helpers.assert_eq(chords, want.chords)
		end)
	end

	helpers.it("a [tap_hold] leaf config.toml owns is warned once and never read (tap-hold-shared-file)", function()
		local Logger = require("core.logger.engine.shim")
		local real_warn, warnings = Logger.warn, {}
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local path = os.tmpname()
		local ok, err = pcall(function()
			write(path, '[_meta]\nschema_version = 1\n[tap_hold]\nenabled = true\nlone_modifier_tap_max_ms = 0\n')
			local loaded = Loader.load(DEFAULTS, path)
			helpers.assert_eq(loaded.enabled, require("menu.engine.manifest_reader").default_for(require("settings.engine.keys").KEY.TAP_HOLDS_ENABLED),
				"the switch comes from config.toml only")
			helpers.assert_eq(loaded.lone_tap_max_ms, Loader.LONE_TAP_DEFAULT_MS, "the window comes from config.toml only")
			helpers.assert_eq(#warnings, 2, table.concat(warnings, "\n"))
			helpers.assert_contains(warnings[1] .. warnings[2], "since config schema v22")
		end)
		Logger.warn = real_warn
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("another driver's key is left alone, a macOS hold is named once (tap-hold-shared-file)", function()
		local Logger = require("core.logger.engine.shim")
		local real_warn, warnings = Logger.warn, {}
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local path = os.tmpname()
		local ok, err = pcall(function()
			write(path, '[_meta]\nschema_version = 1\n[tap_hold.keys.fn]\ntap_action = "paste"\n'
				.. '[tap_hold.keys.caps_lock]\ntap_action = "copy"\nhold_action = "screenshot"\n')
			local loaded = Loader.load(DEFAULTS, path)
			helpers.assert_nil(loaded.keys.fn, "Linux has no Fn key")
			helpers.assert_eq(loaded.keys.caps_lock.tap_action, "copy", "the key keeps its tap")
			helpers.assert_nil(loaded.keys.caps_lock.hold_modifier)
			helpers.assert_eq(#warnings, 1, table.concat(warnings, "\n"))
			helpers.assert_contains(warnings[1], "'tap_hold.keys.caps_lock.hold_action' in '" .. path .. "'")
		end)
		Logger.warn = real_warn
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("a hold chosen on Linux replaces the macOS hold of the key (tap-hold-shared-file)", function()
		with_writer(function(writer, path)
			write(path, '[_meta]\nschema_version = 1\n[tap_hold.keys.caps_lock]\nhold_action = "screenshot"\n'
				.. '[tap_hold.keys.tab]\nhold_action = "screenshot"\n')
			helpers.assert_true(writer.set_hold("caps_lock", "modifier", "ctrl"))
			helpers.assert_true(writer.set_native("tab"))
			local keys = Codec.decode(read(path)).tap_hold.keys
			helpers.assert_eq(keys.caps_lock, { hold_modifier = "ctrl" })
			helpers.assert_eq(keys.tab, { tap_action = "", hold_modifier = "" })
		end)
	end)

	helpers.it("a Linux change over the macOS file keeps every leaf Linux does not own (tap-hold-shared-file)", function()
		with_writer(function(writer, path)
			local source = assert(read(CORPUS .. "macos_written.toml"))
			write(path, source)
			helpers.assert_true(writer.set_tap("escape", "copy"))
			local before, after = Codec.decode(source), Codec.decode(read(path))
			helpers.assert_eq(after.tap_hold.keys.escape, { tap_action = "copy" })
			after.tap_hold.keys.escape = nil
			helpers.assert_eq(after, before, "only the escape key changed")
		end)
	end)
end)
