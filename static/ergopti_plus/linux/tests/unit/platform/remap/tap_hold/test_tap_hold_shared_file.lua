--- tests/unit/platform/remap/tap_hold/test_tap_hold_shared_file.lua

--- ==============================================================================
--- MODULE: The Shared Tap-Hold File On Linux
--- DESCRIPTION:
--- Every driver keeps its tap-hold settings in one tap_hold.toml
--- (_shared/tap_hold/SCHEMA.md). The cross-driver corpus
--- (_shared/tests/corpus/tap_hold_shared_file) holds one file written by the
--- Linux writer, pinned here byte for byte, and one written by the macOS
--- writer, pinned by the macOS suite. The Linux loader reads both as
--- expected.toml says, and a Linux change over the macOS file keeps every leaf
--- Linux does not own (the key combinations, the Karabiner integration).
--- ==============================================================================

local helpers = require("tests.helpers")
local Loader = require("platform.remap.tap_hold_loader")
local Paths = require("infra.paths")
local Codec = require("toml_codec")

local DEFAULTS = Paths.shared("tap_hold/defaults.toml")
local CORPUS = Paths.shared("tests/corpus/tap_hold_shared_file") .. "/"

require("test.tap_hold_shared_file_contract").register(helpers, { driver = "linux", shared_root = Paths.shared_root() })

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
			return require("tap_hold.hold_options").canonical(kind, id, Loader.load(DEFAULTS, nil).hold_picker)
		end,
	})
	local ok, err = pcall(body, writer, dir .. "/tap_hold.toml")
	for _, name in ipairs({ "tap_hold.toml", "tap_hold.toml.tmp" }) do os.remove(dir .. "/" .. name) end
	os.execute('rmdir "' .. dir .. '"')
	if not ok then error(err, 0) end
end

helpers.describe("The shared tap_hold.toml on Linux (tap-hold-shared-file)", function()
	local expected = Codec.decode(assert(read(CORPUS .. "expected.toml"), "the corpus expectations are missing"))

	helpers.it("the Linux writer writes the corpus file byte for byte (tap-hold-shared-file)", function()
		with_writer(function(writer, path)
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
		end)
	end)

	for _, name in ipairs({ "linux_written", "macos_written" }) do
		helpers.it("the Linux loader reads " .. name .. ".toml as expected.toml says (tap-hold-shared-file)", function()
			local want = expected.reads[name].linux
			local loaded = Loader.load(DEFAULTS, CORPUS .. name .. ".toml")
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
	end

	helpers.it("another driver's key is left alone, a macOS hold is named once (tap-hold-shared-file)", function()
		local Logger = require("logger.shim")
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
