--- tests/unit/platform/remap/config/test_tap_hold_shared_file.lua

--- ==============================================================================
--- MODULE: The Shared Tap-Hold File On macOS
--- DESCRIPTION:
--- macOS keeps its remap keys in the shared tap_hold.toml
--- (_shared/tap_hold/data/SCHEMA.md) and the manifest's tap-hold rows (the switch,
--- the one-shot and lone-tap timings, the key combinations) in the config.toml
--- beside it. The writer's pair is pinned by the cross-driver corpus
--- (_shared/tests/corpus/tap_hold_shared_file): tap_hold.toml byte for byte,
--- config.toml as values. The macOS reader reads every driver's pair as
--- expected.toml says, a macOS save over the Linux pair keeps every leaf macOS
--- does not own, and an old config_karabiner.toml is carried over once, its
--- rows moved on into config.toml by the v22 config migration.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "platform.remap.config", "platform.remap.tap_hold_file", "core.fs.adapters.file_system", "core.logger.engine.logger",
	"core.logger.engine.shim", "core.text.engine.toml_codec", "infra.toml.codec" }
local CORPUS = helpers.shared() .. "/tests/corpus/tap_hold_shared_file/"
-- The pairs of the corpus, each <name>.toml and <name>.config.toml.
local PAIRS = { "macos_written", "linux_written", "windows_written" }
local STAMP = "20990101-000000"

require("tests.lua.keyboard.tap_hold_shared_file_contract").register(helpers, { driver = "macos", shared_root = helpers.shared() })

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
	return require("core.text.engine.toml_codec").decode(text)
end

--- Runs body against a private folder holding the driver's tap_hold.toml.
--- @param body function Receives the fixture.
local function with_folder(body)
	helpers.with_stub_scope(MODULES, function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["core.logger.engine.logger"], package.loaded["core.logger.engine.shim"] = logger, logger
		require("settings.engine.migration.outdated").reset_for_tests()
		local config = helpers.load_with_stubs("platform.remap.config")
		local dir = os.tmpname()
		os.remove(dir)
		assert(os.execute('mkdir "' .. dir .. '"'))
		local path = dir .. "/tap_hold.toml"
		local files = require("core.fs.adapters.file_system")
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
		local Json = require("core.fs.adapters.json_codec")
		local data = helpers.driver_root() .. "/platform/remap/data/"
		local keys = Json.decode(read(data .. "tap_hold_keys.json"))
		local combos = Json.decode(read(data .. "mod_combos.json"))
		local ok, err = pcall(body, { config = config, dir = dir, path = path, config_path = dir .. "/config.toml",
			keys = keys, combos = combos,
			warnings = warnings, errors = errors, files = files, native_write = native_write,
			load = function() return config.load_user_config(keys, combos, path) end })
		files.write_if_unchanged = native_write
		for _, name in ipairs({ "tap_hold.toml", "config.toml", "config_karabiner.toml",
			"config_karabiner.toml.migrated", "config.pre-v22-" .. STAMP .. ".toml", "tap_hold.pre-v22-" .. STAMP .. ".toml" }) do
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

--- A decoded config.toml without its version stamp.
local function config_rows(text)
	local document = decode(text or "")
	document._meta = nil
	return document
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

-- Action ids and thumb keys a driver spells its own way (TCL-002, TCL-004).
local SPELLINGS = helpers.shared() .. "/tests/corpus/tap_hold_spellings/"

helpers.describe("Spellings across drivers in the shared tap_hold.toml (tap-hold-spellings)", function()
	local expected = decode(assert(read(SPELLINGS .. "expected.toml"), "the spelling expectations are missing"))

	helpers.it("macOS reads PC action ids and thumb keys under its own (tap-hold-spellings)", function()
		with_folder(function(f)
			write(f.path, assert(read(SPELLINGS .. "pc_written.toml")))
			write(f.config_path, assert(read(SPELLINGS .. "pc_written.config.toml")))
			local state, status = f.load()
			helpers.assert_eq(status, "ok")
			assert_reads(state, expected.reads.pc_written.hs)
		end)
	end)

	helpers.it("macOS writes its action ids and thumb keys as the PC spells them (tap-hold-spellings)", function()
		with_folder(function(f)
			local state = f.config.build_default_state(f.keys, f.combos)
			for _, field in ipairs({ "tap_hold_config", "mod_combos_config" }) do
				for id, binding in pairs(expected.writes.hs.state[field]) do state[field][id] = binding end
			end
			helpers.assert_true(f.config.save_user_config(state, f.path), "the state is saved")
			local stored = decode(read(f.path))
			for key_id, entry in pairs(expected.writes.hs.file.tap_hold.keys) do
				helpers.assert_eq(stored.tap_hold.keys[key_id], entry, key_id)
			end
			for _, mac_id in ipairs({ "left_command", "right_option" }) do
				helpers.assert_nil(stored.tap_hold.keys[mac_id], "no Mac thumb id is written: " .. mac_id)
			end
			helpers.assert_eq(config_rows(read(f.config_path)).mod_combos.config.escape_then_tab,
				expected.writes.hs.config.mod_combos.config.escape_then_tab)
		end)
	end)

	helpers.it("a Mac thumb id loses to the PC key at its place and is named (tap-hold-spellings)", function()
		with_folder(function(f)
			write(f.path, assert(read(SPELLINGS .. "mac_thumb.toml")))
			local state = f.load()
			helpers.assert_eq(state.tap_hold_config.left_command.tap, "copy", "an old Mac id is still read")
			helpers.assert_eq(state.tap_hold_config.right_option.tap, "backspace")
			helpers.assert_eq(state.tap_hold_config.right_command.tap, "backspace", "the positional entry wins")
			local named = false
			for _, line in ipairs(f.warnings) do
				if line:find("tap_hold.keys.right_command", 1, true) then named = true end
			end
			helpers.assert_true(named, "the superseded Mac entry is named")
		end)
	end)
end)

-- TCL-007: every macOS save rendered tap_hold.toml afresh, dropping the user's
-- comments and the header the Linux writer puts on top.
helpers.describe("A macOS save edits tap_hold.toml line by line (tcl-007-keep-comments)", function()
	helpers.it("keeps the comments and the Linux header of the Linux pair (tcl-007-keep-comments)", function()
		with_folder(function(f)
			local source = assert(read(CORPUS .. "linux_written.toml"))
				.. "# My own note about the next key.\n[tap_hold.keys.escape]\ntap_action = \"copy\" # inline note\n"
			write(f.path, source)
			write(f.config_path, assert(read(CORPUS .. "linux_written.config.toml")))
			local state = f.load()
			state.tap_hold_config.escape = { tap = "paste", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			local text = read(f.path)
			helpers.assert_contains(text, "# tap_hold.toml — written by the Ergopti+ tray menu.")
			helpers.assert_contains(text, "# My own note about the next key.")
			helpers.assert_eq(decode(text).tap_hold.keys.escape.tap_action, "paste")
			for _, line in ipairs(f.warnings) do
				helpers.assert_true(line:find("rewritten whole", 1, true) == nil, "the file is not rewritten: " .. line)
			end
		end)
	end)
end)

-- TCL-006: over a file laid on the shipped keys, a cleared tap or hold written as
-- an absent field read as the shipped one on Windows and Linux.
helpers.describe("Clearing a key over inherit_defaults (tcl-006-explicit-none)", function()
	helpers.it("a cleared tap and hold are written as nothing, not left out (tcl-006-explicit-none)", function()
		with_folder(function(f)
			write(f.path, '[_meta]\nschema_version = 1\n[tap_hold]\ninherit_defaults = true\n'
				.. '[tap_hold.keys.caps_lock]\ntap_action = "copy"\nhold_modifier = "ctrl"\n')
			local state = f.load()
			state.tap_hold_config.caps_lock = { tap = "none", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_eq(decode(read(f.path)).tap_hold.keys.caps_lock, { tap_action = "none", hold_modifier = "" })
			local reloaded = f.load()
			helpers.assert_eq(reloaded.tap_hold_config.caps_lock, { tap = "none", hold = "none" }, "macOS reads it back as none")
		end)
	end)

	helpers.it("without inherit_defaults a cleared key is left out as before (tcl-006-explicit-none)", function()
		with_folder(function(f)
			write(f.path, '[_meta]\nschema_version = 1\n[tap_hold.keys.caps_lock]\ntap_action = "copy"\nhold_modifier = "ctrl"\n')
			local state = f.load()
			state.tap_hold_config.caps_lock = { tap = "none", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_nil((decode(read(f.path)).tap_hold or {}).keys)
		end)
	end)
end)

-- TCL-005: SCHEMA.md bounds a delay to 0 < x <= 10 s; macOS took a longer global
-- delay and ran a key's delay <= 0 as the global without a word.
helpers.describe("Delays outside the bound in the shared tap_hold.toml (tcl-005-delay-bound)", function()
	helpers.it("a global delay above 10 s is named and not used (tcl-005-delay-bound)", function()
		with_folder(function(f)
			write(f.path, '[_meta]\nschema_version = 1\n[tap_hold]\ntime_activation_seconds = 12\n')
			local state = f.load()
			helpers.assert_eq(state.tap_hold_timeout_ms, f.config.build_default_state(f.keys, f.combos).tap_hold_timeout_ms)
			helpers.assert_true(table.concat(f.warnings, "\n"):find("tap_hold.time_activation_seconds", 1, true) ~= nil,
				"the warning names the file's leaf")
		end)
	end)

	for _, seconds in ipairs({ "0", "-0.5", "11" }) do
		helpers.it("a key's delay of " .. seconds .. " s is named, not silently replaced (tcl-005-delay-bound)", function()
			with_folder(function(f)
				write(f.path, '[_meta]\nschema_version = 1\n[tap_hold.keys.caps_lock]\ntap_action = "copy"\n'
					.. "time_activation_seconds = " .. seconds .. "\n")
				f.load()
				helpers.assert_true(table.concat(f.warnings, "\n"):find("tap_hold.keys.caps_lock.time_activation_seconds", 1, true)
					~= nil, "the warning names the key's delay: " .. table.concat(f.warnings, " | "))
			end)
		end)
	end
end)

helpers.describe("The shared tap_hold.toml on macOS (tap-hold-shared-file)", function()
	local expected = decode(assert(read(CORPUS .. "expected.toml"), "the corpus expectations are missing"))

	helpers.it("the macOS writer writes the corpus pair (tap-hold-shared-file)", function()
		with_folder(function(f)
			helpers.assert_true(f.config.save_user_config(corpus_state(f), f.path), "the corpus state is saved")
			helpers.assert_eq(read(f.path), read(CORPUS .. "macos_written.toml"), "tap_hold.toml byte for byte")
			helpers.assert_eq(config_rows(read(f.config_path)), config_rows(read(CORPUS .. "macos_written.config.toml")),
				"the config.toml rows as values")
		end)
	end)

	for _, name in ipairs(PAIRS) do
		helpers.it("the macOS reader reads the " .. name .. " pair as expected.toml says (tap-hold-shared-file)", function()
			with_folder(function(f)
				write(f.path, assert(read(CORPUS .. name .. ".toml")))
				write(f.config_path, assert(read(CORPUS .. name .. ".config.toml")))
				local state, status = f.load()
				helpers.assert_eq(status, "ok")
				assert_reads(state, expected.reads[name].hs)
			end)
		end)
	end

	helpers.it("a tap-hold row left in tap_hold.toml is named and not read (tap-hold-shared-file)", function()
		with_folder(function(f)
			write(f.path, '[_meta]\nschema_version = 1\n[tap_hold]\nenabled = true\nsticky_timeout_ms = 900\n')
			local state = f.load()
			helpers.assert_eq(state.sticky_timeout_ms, f.config.build_default_state(f.keys, f.combos).sticky_timeout_ms)
			local named = false
			for _, line in ipairs(f.warnings) do
				if line:find("tap_hold.sticky_timeout_ms", 1, true) and line:find("config.toml", 1, true) then named = true end
			end
			helpers.assert_true(named, "the warning names the leaf and its new home")
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_eq(decode(read(f.path)).tap_hold.sticky_timeout_ms, 900, "the unread copy stays for the user")
		end)
	end)

	helpers.it("a macOS save over the Linux pair keeps every leaf macOS does not own (tap-hold-shared-file)", function()
		with_folder(function(f)
			local source = assert(read(CORPUS .. "linux_written.toml"))
			local config_source = assert(read(CORPUS .. "linux_written.config.toml"))
			write(f.path, source)
			write(f.config_path, config_source)
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
			helpers.assert_eq(read(f.config_path), config_source, "a save that changes no row leaves config.toml as it is")
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
			local source = '[_meta]\nschema_version = 99\n[tap_hold.keys.caps_lock]\ntap_action = "copy"\n'
			write(f.path, source)
			local state = f.load()
			helpers.assert_eq(state.tap_hold_config.caps_lock.tap, "copy")
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
			-- The boot then versions config.toml: its v22 step moves the rows on.
			write(f.config_path, "[_meta]\nschema_version = 21\n")
			local Engine = require("settings.engine.migration.migrate")
			local registry = assert(Engine.validate_registry(decode(table.concat({
				"[registry]", "current_version = 22", "unstamped_version = 2", "oldest_version = 21",
				"[steps.v21_to_v22]", "from = 21", "to = 22", 'drivers = ["hs"]', 'reason = "Contract."', "ops = [",
				'{ op = "import_companion", file = "tap_hold.toml", section = "tap_hold", key = "enabled", to_section = "tap_holds" },',
				'{ op = "import_companion", file = "tap_hold.toml", section = "tap_hold", key = "lone_modifier_tap_max_ms", to_section = "tap_holds" },',
				'{ op = "import_companion", file = "tap_hold.toml", section = "tap_hold", key = "sticky_timeout_ms", to_section = "tap_holds" },',
				'{ op = "import_companion", file = "tap_hold.toml", section = "mod_combos", to_section = "mod_combos" },',
				"]" }, "\n"))))
			-- Through the native configuration owner, as the boot runs it: the
			-- engine refuses a substituted adapter, so the fixture's writer steps aside.
			local fixture_write = f.files.write_if_unchanged
			f.files.write_if_unchanged = f.native_write
			local called, result = pcall(Engine.run, { path = f.config_path, driver = "hs", registry = registry,
				stamp = STAMP, companions = { ["tap_hold.toml"] = f.path } })
			f.files.write_if_unchanged = fixture_write
			assert(called, tostring(result))
			helpers.assert_eq(result.status, "migrated", tostring(result.detail))
			helpers.assert_eq(decode(read(f.path)), decode(read(CORPUS .. "macos_written.toml")))
			helpers.assert_eq(config_rows(read(f.config_path)), config_rows(read(CORPUS .. "macos_written.config.toml")))
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
