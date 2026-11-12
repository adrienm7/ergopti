--- tests/unit/platform/remap/tap_hold/test_tap_hold_combos_import.lua

--- ==============================================================================
--- MODULE: Key Combinations In The Shared tap_hold.toml (Linux)
--- DESCRIPTION:
--- `[mod_combos]` lives in the shared tap_hold.toml on every driver
--- (_shared/tap_hold/SCHEMA.md). Linux kept it in config.toml until 1.0.9: the
--- boot moves it once (migrations.toml `[legacy_imports.linux]`), publishing
--- tap_hold.toml first, so a crash between the two writes is finished by the
--- next start. The combinations owner reads the section from tap_hold.toml
--- only, and its source receipts cover both files. The scopes publish the
--- section through the tap-hold writer's preparation, which versions the file.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Writer = require("platform.remap.tap_hold_writer")

local COMBOS = '[mod_combos]\nenabled = false\nsimultaneous_threshold_ms = 80\nsymmetric = true\n'
	.. '[mod_combos.config.tab_then_caps_lock]\ncombo = "copy"\nfuture = 17\n'
local CONFIG = '# the user\'s comment\n[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n\n'
	.. COMBOS .. '\n[unrelated]\nkeep = 42\n'
local STAMPED = '[_meta]\nschema_version = 1\n\n[tap_hold]\nenabled = true # kept\n'

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

local function write(path, text)
	local fh = assert(io.open(path, "wb")); assert(fh:write(text)); assert(fh:close())
end

--- Runs body(config_path, tap_path, folder) in a private configuration folder,
--- then removes every file the scenario left, backups included.
--- @param config string|nil Initial config.toml bytes; nil leaves it absent.
--- @param tap string|nil Initial tap_hold.toml bytes; nil leaves it absent.
local function with_folder(config, tap, body)
	local folder = os.tmpname(); os.remove(folder)
	local made = os.execute("mkdir '" .. folder .. "'")
	assert(made == true or made == 0, "the private configuration folder must exist")
	local config_path, tap_path = folder .. "/config.toml", folder .. "/tap_hold.toml"
	if config then write(config_path, config) end
	if tap then write(tap_path, tap) end
	local ok, err = pcall(body, config_path, tap_path, folder)
	local listing = io.popen("ls -A '" .. folder .. "'")
	for name in listing:lines() do os.remove(folder .. "/" .. name) end
	listing:close()
	os.execute("rmdir '" .. folder .. "'")
	if not ok then error(err, 0) end
end

--- The backups a scenario made in its folder, by the file they copy.
local function backups(folder)
	local found = {}
	local listing = io.popen("ls -A '" .. folder .. "'")
	for name in listing:lines() do
		local origin = name:match("^(.-)%.mod_combos%-.*%.bak$")
		if origin then found[origin] = (found[origin] or 0) + 1 end
	end
	listing:close()
	return found
end

helpers.describe("config.toml [mod_combos] moves into tap_hold.toml once (tap-hold-combos-import)", function()
	helpers.it("moves the whole section, deletes it line by line and backs both files up", function()
		with_folder(CONFIG, STAMPED, function(config_path, tap_path, folder)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "imported")
			local config, tap = read(config_path), read(tap_path)
			helpers.assert_eq(config, '# the user\'s comment\n[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n\n\n[unrelated]\nkeep = 42\n',
				"only the section's lines leave config.toml")
			helpers.assert_contains(tap, "enabled = true # kept", "tap_hold.toml keeps its own bytes")
			helpers.assert_eq(Codec.decode(tap).mod_combos, Codec.decode(COMBOS).mod_combos, "unknown fields move too")
			helpers.assert_eq(backups(folder), { ["config.toml"] = 1, ["tap_hold.toml"] = 1 })
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "none", "the import runs once")
		end)
	end)

	helpers.it("creates a stamped tap_hold.toml that holds only the section", function()
		with_folder(CONFIG, nil, function(config_path, tap_path, folder)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "imported")
			local tap = Codec.decode(read(tap_path))
			helpers.assert_eq(tap._meta.schema_version, 1)
			helpers.assert_eq(tap.tap_hold, nil, "no tap-hold key is invented: the loader reads it as an absent file")
			helpers.assert_eq(tap.mod_combos.config.tab_then_caps_lock.combo, "copy")
			helpers.assert_eq(backups(folder), { ["config.toml"] = 1 }, "a new file has nothing to back up")
		end)
	end)

	helpers.it("finishes an import a crash interrupted after tap_hold.toml was published", function()
		with_folder(CONFIG, STAMPED .. "\n" .. COMBOS, function(config_path, tap_path)
			local tap = read(tap_path)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "completed")
			helpers.assert_eq(read(tap_path), tap, "the shared copy is not written again")
			helpers.assert_eq(Codec.decode(read(config_path)).mod_combos, nil)
		end)
	end)

	helpers.it("leaves both files alone when tap_hold.toml already holds other combinations", function()
		local other = STAMPED .. '[mod_combos]\nsimultaneous_threshold_ms = 120\n'
		with_folder(CONFIG, other, function(config_path, tap_path, folder)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "kept")
			helpers.assert_eq(read(config_path), CONFIG); helpers.assert_eq(read(tap_path), other)
			helpers.assert_eq(backups(folder), {})
		end)
	end)

	helpers.it("an empty section carries nothing: no file is created or written", function()
		local empty = '[mod_combos]\n[unrelated]\nkeep = 42\n'
		with_folder(empty, nil, function(config_path, tap_path)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "none")
			helpers.assert_eq(read(tap_path), nil); helpers.assert_eq(read(config_path), empty)
		end)
	end)

	helpers.it("never writes a tap_hold.toml saved by a newer build", function()
		local newer = '[_meta]\nschema_version = 99\n'
		with_folder(CONFIG, newer, function(config_path, tap_path)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "failed")
			helpers.assert_eq(read(config_path), CONFIG, "the combinations stay where they are")
			helpers.assert_eq(read(tap_path), newer)
		end)
	end)

	helpers.it("does nothing without a config.toml or without a section", function()
		with_folder(nil, nil, function(config_path, tap_path)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "none")
		end)
		with_folder('[unrelated]\nkeep = 42\n', nil, function(config_path, tap_path)
			helpers.assert_eq(Writer.import_config_combos(config_path, tap_path), "none")
			helpers.assert_eq(read(tap_path), nil)
		end)
	end)

	helpers.it("the daemon imports right after versioning tap_hold.toml, before the engine reads it", function()
		local source = assert(read(helpers.driver_root() .. "/ergopti_hotstrings.lua"))
		local migrate = assert(source:find("tap_hold_writer\").migrate_file(", 1, true))
		local import = assert(source:find("tap_hold_writer\").import_config_combos(", 1, true))
		local manager = assert(source:find("local TapHold = require(\"platform.remap.tap_hold_manager\")", 1, true))
		helpers.assert_true(migrate < import and import < manager)
	end)
end)

helpers.describe("the tap-hold writer prepares [mod_combos] rows for a scope (tap-hold-combos-import)", function()
	local row = { section = "mod_combos.config.tab_then_caps_lock", key = "combo", value = "copy" }

	helpers.it("edits an existing file line by line and keeps its other bytes", function()
		with_folder(nil, STAMPED, function(_, tap_path)
			local prepared, detail, candidate, source = Writer.prepare_combo_rows(tap_path, { row })
			helpers.assert_true(prepared, detail)
			helpers.assert_eq(source, { status = "ok", content = STAMPED })
			helpers.assert_contains(candidate, "enabled = true # kept")
			helpers.assert_eq(Codec.decode(candidate).mod_combos.config.tab_then_caps_lock.combo, "copy")
			helpers.assert_eq(read(tap_path), STAMPED, "preparation writes nothing")
		end)
	end)

	helpers.it("stamps a file it creates, and creates none for deletes alone", function()
		with_folder(nil, nil, function(_, tap_path)
			local prepared, _, candidate, source = Writer.prepare_combo_rows(tap_path, { row })
			helpers.assert_true(prepared); helpers.assert_eq(source, { status = "absent" })
			helpers.assert_eq(Codec.decode(candidate)._meta.schema_version, 1)
			prepared, _, candidate = Writer.prepare_combo_rows(tap_path,
				{ { section = "mod_combos", key = "symmetric", delete = true } })
			helpers.assert_true(prepared); helpers.assert_eq(candidate, "")
		end)
	end)

	helpers.it("migrates an older file in the same candidate", function()
		local old = '[tap_hold]\nexplicit_delays = true\n'
		with_folder(nil, old, function(_, tap_path)
			local prepared, _, candidate, source = Writer.prepare_combo_rows(tap_path, { row })
			helpers.assert_true(prepared); helpers.assert_eq(source.content, old)
			local decoded = Codec.decode(candidate)
			helpers.assert_eq(decoded._meta.schema_version, 1); helpers.assert_eq(decoded.tap_hold, nil)
		end)
	end)

	helpers.it("refuses rows outside [mod_combos] and files it cannot version", function()
		with_folder(nil, STAMPED, function(_, tap_path)
			helpers.assert_eq(Writer.prepare_combo_rows(tap_path, { { section = "tap_hold", key = "enabled", value = false } }), false)
		end)
		for _, text in ipairs({ '[_meta]\nschema_version = 99\n', '[_meta]\nschema_version = "one"\n', 'not = [toml' }) do
			with_folder(nil, text, function(_, tap_path)
				helpers.assert_eq(Writer.prepare_combo_rows(tap_path, { row }), false, text)
			end)
		end
	end)
end)

helpers.describe("the combinations owner reads [mod_combos] from tap_hold.toml only (tap-hold-combos-import)", function()
	local catalog = { { id = "caps_lock", key = "caps_lock" }, { id = "tab", key = "tab" } }
	local function owner(bytes)
		return require("modules.shortcuts.key_combinations").new({ keys = catalog,
			hold_picker = { modifiers = { "shift" }, layers = { "nav" } },
			files = { read_with_status = function(path)
				local content = bytes[path]; return content, content and "ok" or "absent"
			end },
			route = function() return "/controlled/config.toml" end,
			is_paused = function() return false end, changed = function() return true end,
			actions = { is_assignable = function(action) return action == "copy" end } })
	end

	helpers.it("a config.toml [mod_combos] is inert: the shared file is the single source", function()
		local slot = '[mod_combos.config.tab_then_caps_lock]\ncombo = "copy"\n'
		local stale = owner({ ["/controlled/config.toml"] = slot })
		helpers.assert_eq(stale.get_chord("tab_then_caps_lock"), "none")
		local shared = owner({ ["/controlled/config.toml"] = "", ["/controlled/tap_hold.toml"] = slot })
		helpers.assert_eq(shared.get_chord("tab_then_caps_lock"), "copy")
		local settings = owner({ ["/controlled/config.toml"] = '[mod_combos]\nsimultaneous_threshold_ms = 5\n',
			["/controlled/tap_hold.toml"] = COMBOS })
		helpers.assert_eq(settings.chord_settings(), { simultaneous_threshold_ms = 80, combo_symmetric = true })
	end)

	helpers.it("every receipt carries tap_hold.toml and a change to it revokes the guards", function()
		local bytes = { ["/controlled/config.toml"] = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n',
			["/controlled/tap_hold.toml"] = COMBOS }
		local pairs_owner = owner(bytes)
		local receipt = pairs_owner.capture_edit_source()
		helpers.assert_eq(receipt.chord, { path = "/controlled/tap_hold.toml", status = "ok", content = COMBOS })
		local runtime, action = pairs_owner.capture_runtime(), pairs_owner.capture_action("combination__caps_lock_then_tab", "copy")
		helpers.assert_true(receipt.guard()); helpers.assert_true(runtime()); helpers.assert_true(action())
		bytes["/controlled/tap_hold.toml"] = COMBOS .. "# edited elsewhere\n"
		helpers.assert_eq(receipt.guard(), false); helpers.assert_eq(runtime(), false); helpers.assert_eq(action(), false)
		local token = {}
		helpers.assert_true(pairs_owner.acquire_configuration(token))
		local frame = pairs_owner.configuration_source(token)
		helpers.assert_true(pairs_owner.configuration_source_matches(token, frame))
		bytes["/controlled/tap_hold.toml"] = nil
		helpers.assert_eq(pairs_owner.configuration_source_matches(token, frame), false)
		helpers.assert_true(pairs_owner.release_configuration(token))
	end)
end)
