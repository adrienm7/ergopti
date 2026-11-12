--- tests/unit/platform/remap/config/test_tap_hold_shared_file.lua

--- ==============================================================================
--- MODULE: The Shared Tap-Hold File On macOS
--- DESCRIPTION:
--- macOS keeps its remap settings in the shared tap_hold.toml
--- (_shared/tap_hold/SCHEMA.md). The writer's file is pinned byte for byte by
--- the cross-driver corpus (_shared/tests/corpus/tap_hold_shared_file), whose
--- other file the Linux writer wrote: the macOS reader reads both as
--- expected.toml says, a macOS save over the Linux file keeps every leaf macOS
--- does not own, and an old config_karabiner.toml is carried over once.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "platform.remap.config", "platform.remap.tap_hold_file", "adapters.file_system", "infra.logger",
	"logger.shim", "toml_codec", "infra.toml.codec" }
local CORPUS = helpers.shared() .. "/tests/corpus/tap_hold_shared_file/"

require("test.tap_hold_shared_file_contract").register(helpers, { driver = "macos", shared_root = helpers.shared() })

--- Reads a whole file, nil when it is absent.
--- @param path string
--- @return string|nil
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Writes a whole file.
local function write(path, text)
	local fh = assert(io.open(path, "wb")); assert(fh:write(text)); assert(fh:close())
end

--- A Lua value as a JSON-free comparable copy (expected.toml is TOML).
local function decode(text)
	return require("toml_codec").decode(text)
end

--- Runs body against a private folder holding the driver's tap_hold.toml.
--- @param body function Receives the fixture.
local function with_folder(body)
	helpers.with_stub_scope(MODULES, function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		require("config_outdated").reset_for_tests()
		local config = helpers.load_with_stubs("platform.remap.config")
		local dir = os.tmpname()
		os.remove(dir)
		assert(os.execute('mkdir "' .. dir .. '"'))
		local path = dir .. "/tap_hold.toml"
		local files = require("adapters.file_system")
		local native_write = files.write_if_unchanged
		-- The source fence is the writer's own; the fixture publishes the
		-- candidate over the unchanged source it was given.
		files.write_if_unchanged = function(destination, content, expected)
			local current = read(destination)
			helpers.assert_eq(expected.status, current and "ok" or "absent")
			if current then helpers.assert_eq(expected.content, current) end
			write(destination, content)
			return true
		end
		local Json = require("adapters.json_codec")
		local data = helpers.driver_root() .. "/platform/remap/data/"
		local keys = Json.decode(read(data .. "tap_hold_keys.json"))
		local combos = Json.decode(read(data .. "mod_combos.json"))
		local ok, err = pcall(body, { config = config, dir = dir, path = path, keys = keys, combos = combos,
			warnings = warnings, errors = errors, files = files,
			load = function() return config.load_user_config(keys, combos, path) end })
		files.write_if_unchanged = native_write
		for _, name in ipairs({ "tap_hold.toml", "config_karabiner.toml", "config_karabiner.toml.migrated" }) do
			os.remove(dir .. "/" .. name)
		end
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end)
end

--- The state the corpus's macOS writer case saves.
local function corpus_state(f)
	local state = f.config.build_default_state(f.keys, f.combos)
	state.enabled = false
	state.tap_holds_enabled = true
	state.tap_hold_timeout_ms = 250
	state.sticky_timeout_ms = 1500
	state.lone_modifier_tap_max_ms = 0
	state.tap_hold_config.caps_lock = { tap = "backspace", hold = "ctrl" }
	state.tap_hold_config.left_shift = { tap = "copy", hold = "shift", timeout_ms = 300 }
	state.tap_hold_config.tab = { tap = "none", hold = "layer" }
	state.tap_hold_config.left_control = { tap = "none", hold = "cmd_shift" }
	state.simultaneous_threshold_ms = 80
	state.combo_symmetric = true
	state.mod_combos_config.esc_tab = { combo = "copy", tap = "none", hold = "none" }
	return state
end

--- Asserts that a loaded state matches an expected.toml `hs` table.
local function assert_reads(state, expected)
	for field, value in pairs(expected) do
		if field ~= "tap_hold_config" and field ~= "mod_combos_config" then
			helpers.assert_eq(state[field], value, field)
		end
	end
	for _, field in ipairs({ "tap_hold_config", "mod_combos_config" }) do
		for id, binding in pairs(expected[field] or {}) do
			for slot, value in pairs(binding) do
				helpers.assert_eq(state[field][id][slot], value, field .. "." .. id .. "." .. slot)
			end
		end
	end
end

helpers.describe("The shared tap_hold.toml on macOS (tap-hold-shared-file)", function()
	local expected = decode(assert(read(CORPUS .. "expected.toml"), "the corpus expectations are missing"))

	helpers.it("the macOS writer writes the corpus file byte for byte (tap-hold-shared-file)", function()
		with_folder(function(f)
			helpers.assert_true(f.config.save_user_config(corpus_state(f), f.path), "the corpus state is saved")
			helpers.assert_eq(read(f.path), read(CORPUS .. "macos_written.toml"))
		end)
	end)

	for _, name in ipairs({ "macos_written", "linux_written" }) do
		helpers.it("the macOS reader reads " .. name .. ".toml as expected.toml says (tap-hold-shared-file)", function()
			with_folder(function(f)
				write(f.path, assert(read(CORPUS .. name .. ".toml")))
				local state, status = f.load()
				helpers.assert_eq(status, "ok")
				assert_reads(state, expected.reads[name].hs)
			end)
		end)
	end

	helpers.it("a macOS save over the Linux file keeps every leaf macOS does not own (tap-hold-shared-file)", function()
		with_folder(function(f)
			local source = assert(read(CORPUS .. "linux_written.toml"))
			write(f.path, source)
			local state = f.load()
			state.tap_hold_config.escape = { tap = "copy", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path), "the change is saved")
			local before, after = decode(source), decode(read(f.path))
			after.tap_hold.keys.escape = nil
			-- The integration switch is macOS's own and always written.
			helpers.assert_eq(after.karabiner, { integration_enabled = true })
			after.karabiner = nil
			helpers.assert_eq(after, before, "only the escape key and macOS's own section changed")
			helpers.assert_eq(decode(read(f.path)).tap_hold.keys.escape, { tap_action = "copy" })
		end)
	end)

	helpers.it("a macOS reset replaces macOS's keys and keeps the Linux-only ones (tap-hold-shared-file)", function()
		with_folder(function(f)
			write(f.path, assert(read(CORPUS .. "linux_written.toml")))
			local state = f.config.build_default_state(f.keys, f.combos)
			helpers.assert_true(f.config.save_user_config(state, f.path, true), "the reset is saved")
			local stored = decode(read(f.path))
			helpers.assert_eq(stored.tap_hold.keys, { win = { hold_modifier = "ctrl+alt" } })
			helpers.assert_eq(stored._meta.schema_version, 1)
		end)
	end)

	helpers.it("a hold macOS cannot run is named in the file and kept (tap-hold-shared-file)", function()
		with_folder(function(f)
			write(f.path, '[_meta]\nschema_version = 1\n[tap_hold.keys.caps_lock]\ntap_action = "copy"\nhold_modifier = "win"\n')
			local state = f.load()
			helpers.assert_eq(state.tap_hold_config.caps_lock, { tap = "copy", hold = "none" })
			helpers.assert_true(#f.warnings > 0 and f.warnings[1]:find("tap_hold.keys.caps_lock.hold_modifier", 1, true) ~= nil,
				"the warning names the file's leaf")
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_eq(decode(read(f.path)).tap_hold.keys.caps_lock.hold_modifier, "win")
		end)
	end)

	helpers.it("an old [tap_holds] section pasted into the file is kept and not read (tap-hold-shared-file)", function()
		with_folder(function(f)
			write(f.path, '[_meta]\nschema_version = 1\n[tap_holds.config.escape]\ntap = "copy"\n')
			local state = f.load()
			helpers.assert_eq(state.tap_hold_config.escape, { tap = "none", hold = "none" })
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			local stored = decode(read(f.path))
			helpers.assert_eq(stored.tap_holds, { config = { escape = { tap = "copy" } } })
			helpers.assert_eq(stored.tap_hold.keys, { tab = { tap_action = "copy" } })
		end)
	end)

	helpers.it("a file a newer build saved is read and never written (tap-hold-shared-file)", function()
		with_folder(function(f)
			local source = '[_meta]\nschema_version = 99\n[tap_hold]\nenabled = true\n'
			write(f.path, source)
			local state = f.load()
			helpers.assert_eq(state.tap_holds_enabled, true)
			state.tap_hold_timeout_ms = 300
			helpers.assert_eq(f.config.save_user_config(state, f.path), false)
			helpers.assert_eq(read(f.path), source)
		end)
	end)

	helpers.it("an old config_karabiner.toml is carried over once (tap-hold-shared-file)", function()
		with_folder(function(f)
			local legacy = f.dir .. "/config_karabiner.toml"
			local text = assert(read(CORPUS .. "macos_legacy.toml"))
			write(legacy, text)
			local TapHoldFile = require("platform.remap.tap_hold_file")
			helpers.assert_eq({ TapHoldFile.import_legacy(f.path, f.files) }, { true, "imported" })
			helpers.assert_eq(decode(read(f.path)), decode(read(CORPUS .. "macos_written.toml")))
			helpers.assert_eq(read(legacy), nil, "the old file is no longer read")
			helpers.assert_eq(read(legacy .. ".migrated"), text, "the old file is kept as a backup")
			helpers.assert_eq({ TapHoldFile.import_legacy(f.path, f.files) }, { true, "none" })
			write(legacy, text)
			helpers.assert_eq({ TapHoldFile.import_legacy(f.path, f.files) }, { true, "kept" })
			helpers.assert_eq(read(legacy), text, "with both files present the old one is left alone")
		end)
	end)

	helpers.it("an unparseable config_karabiner.toml is refused, not carried over (tap-hold-shared-file)", function()
		with_folder(function(f)
			write(f.dir .. "/config_karabiner.toml", "[tap_holds\n")
			local TapHoldFile = require("platform.remap.tap_hold_file")
			helpers.assert_eq({ TapHoldFile.import_legacy(f.path, f.files) }, { false, "unparseable" })
			helpers.assert_eq(read(f.path), nil)
		end)
	end)
end)
