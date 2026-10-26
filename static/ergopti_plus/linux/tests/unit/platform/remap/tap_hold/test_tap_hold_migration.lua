--- tests/unit/platform/remap/tap_hold/test_tap_hold_migration.lua

--- ==============================================================================
--- MODULE: Versioned tap_hold.toml (Linux)
--- DESCRIPTION:
--- Replaces the permanent `[tap_hold] explicit_delays = true` marker. Runs the
--- shared migration contract under the Linux runner, then pins the driver side:
--- the boot publishes the migrated file once after a byte-exact backup, a file
--- of the current version is never rewritten, the user's own per-key delays
--- survive, a newer or unreadable file is left alone and refused to every
--- writer, the loader reads an unmigrated file as the migration leaves it, and
--- the daemon migrates before the tap-hold engine reads the file.
--- ==============================================================================

local helpers = require("tests.helpers")
local Loader = require("platform.remap.tap_hold_loader")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")

require("test.tap_hold_migrate_contract").register(helpers,
	{ driver = "linux", platform = "linux", shared_root = require("infra.paths").shared_root() })

local OLD_FILE = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
	.. '[tap_hold.keys.caps_lock]\ntap_action = "enter"\nhold_modifier = "ctrl"\ntime_activation_seconds = 0.35\n'
	.. '[tap_hold.keys.left_ctrl]\ntime_activation_seconds = 0.45\n'

local function write_file(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Runs body(writer, path) on a throwaway file the writer is bound to, then
--- removes the file and the backups the scenario made.
--- @param text string|nil Initial bytes; nil leaves the file absent.
--- @param body function body(writer, path, backups) where backups collects paths.
local function with_file(text, body)
	local path = os.tmpname()
	os.remove(path)
	if text then write_file(path, text) end
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({
		path = path,
		reload = function() return true end,
		is_tap_action = function(id) return id == "paste" end,
		canonical_hold = function(kind, id)
			return require("tap_hold.hold_options").canonical(kind, id, Loader.load(DEFAULTS, nil).hold_picker)
		end,
	})
	local backups = {}
	local ok, err = pcall(body, writer, path, backups)
	for _, backup in ipairs(backups) do os.remove(backup) end
	os.remove(path)
	os.remove(path .. ".tmp")
	if not ok then error(err, 0) end
end

--- The effective configuration the engine would run on.
local function effective(path)
	return Loader.load(DEFAULTS, path)
end

helpers.describe("versioned tap_hold.toml (tap-hold-versioned-file)", function()
	helpers.it("migrates an old file without the marker once: copied delays go, the user's stay, a backup holds the bytes", function()
		with_file(OLD_FILE, function(writer, path, backups)
			local status, backup = writer.migrate_file(path)
			backups[#backups + 1] = backup
			helpers.assert_eq(status, "migrated")
			helpers.assert_eq(read_file(backup), OLD_FILE, "byte-exact backup")
			local text = read_file(path)
			helpers.assert_true(text:find("schema_version = 1", 1, true) ~= nil, "stamped")
			helpers.assert_true(text:find("explicit_delays", 1, true) == nil, "no marker is written")
			helpers.assert_true(text:find("0.35", 1, true) == nil, "the shipped delay of Caps Lock went")
			local loaded = effective(path)
			helpers.assert_eq(loaded.keys.caps_lock.time_activation_seconds, loaded.global_seconds)
			helpers.assert_eq(loaded.keys.left_ctrl.time_activation_seconds, 0.45, "the user's own delay survives")
		end)
	end)

	helpers.it("migrates an old file with the marker: every delay stays, the marker goes", function()
		local flagged = OLD_FILE:gsub("%[tap_hold%]\n", "[tap_hold]\nexplicit_delays = true\n", 1)
		with_file(flagged, function(writer, path, backups)
			local status, backup = writer.migrate_file(path)
			backups[#backups + 1] = backup
			helpers.assert_eq(status, "migrated")
			local text = read_file(path)
			helpers.assert_true(text:find("explicit_delays", 1, true) == nil, "the marker is not kept")
			helpers.assert_eq(effective(path).keys.caps_lock.time_activation_seconds, 0.35,
				"a delay of a flagged file is the user's own")
		end)
	end)

	helpers.it("never rewrites a file of the current version, and a second boot is a no-op", function()
		with_file(OLD_FILE, function(writer, path, backups)
			local _, backup = writer.migrate_file(path)
			backups[#backups + 1] = backup
			local migrated = read_file(path)
			helpers.assert_eq((writer.migrate_file(path)), "current")
			helpers.assert_eq(read_file(path), migrated, "idempotent")
			-- A delay equal to a shipped one, set after the migration, is the user's.
			helpers.assert_true(writer.set_threshold("caps_lock", 0.35))
			helpers.assert_eq(effective(path).keys.caps_lock.time_activation_seconds, 0.35)
			helpers.assert_eq((writer.migrate_file(path)), "current")
			helpers.assert_eq(effective(path).keys.caps_lock.time_activation_seconds, 0.35, "kept by the next boot")
		end)
	end)

	helpers.it("leaves an absent file absent; the first write creates it stamped", function()
		with_file(nil, function(writer, path)
			helpers.assert_eq((writer.migrate_file(path)), "absent")
			helpers.assert_eq(read_file(path), nil)
			helpers.assert_true(writer.set_tap("tab", "paste"))
			local text = read_file(path)
			helpers.assert_true(text:find("schema_version = 1", 1, true) ~= nil, "a created file is stamped")
			helpers.assert_true(text:find("explicit_delays", 1, true) == nil)
		end)
	end)

	helpers.it("refuses a file saved by a newer build: untouched, and no writer changes it", function()
		local newer = '[_meta]\nschema_version = 2\n[tap_hold.keys.caps_lock]\ntime_activation_seconds = 0.35\n'
		with_file(newer, function(writer, path)
			local status = writer.migrate_file(path)
			helpers.assert_eq(status, "newer")
			helpers.assert_eq(read_file(path), newer)
			helpers.assert_true(not writer.set_tap("tab", "paste"), "a write is refused")
			helpers.assert_eq(read_file(path), newer, "the newer file is preserved")
			helpers.assert_eq(effective(path).keys.caps_lock.time_activation_seconds, 0.35, "and read as it is")
		end)
	end)

	helpers.it("refuses an unreadable stamp and a malformed file without writing", function()
		local bad = '[_meta]\nschema_version = "1"\n'
		with_file(bad, function(writer, path)
			helpers.assert_eq((writer.migrate_file(path)), "invalid")
			helpers.assert_eq(read_file(path), bad)
			helpers.assert_true(not writer.set_tap("tab", "paste"))
		end)
		with_file("[tap_hold\n", function(writer, path)
			helpers.assert_eq((writer.migrate_file(path)), "failed")
			helpers.assert_eq(read_file(path), "[tap_hold\n")
		end)
	end)

	helpers.it("reads a file the boot has not migrated as the migration leaves it, without touching the disk", function()
		with_file(OLD_FILE, function(_, path)
			local loaded = effective(path)
			helpers.assert_eq(loaded.keys.caps_lock.time_activation_seconds, loaded.global_seconds)
			helpers.assert_eq(loaded.keys.left_ctrl.time_activation_seconds, 0.45)
			helpers.assert_eq(read_file(path), OLD_FILE, "reading never writes")
		end)
	end)

	helpers.it("the first change of an unmigrated file migrates it in the same write", function()
		with_file(OLD_FILE, function(writer, path)
			helpers.assert_true(writer.set_tap("tab", "paste"))
			local text = read_file(path)
			helpers.assert_true(text:find("schema_version = 1", 1, true) ~= nil)
			helpers.assert_true(text:find("0.35", 1, true) == nil)
			helpers.assert_true(text:find("0.45", 1, true) ~= nil)
		end)
	end)

	helpers.it("the daemon migrates tap_hold.toml before the tap-hold engine reads it (tap-hold-migrate-boot-order)", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local code = fh:read("*a"):gsub("%-%-[^\n]*", "")
		fh:close()
		local migrate = code:find("tap_hold_writer\").migrate_file(", 1, true)
		local engine = code:find("TapHold.init({", 1, true)
		helpers.assert_true(migrate and engine and migrate < engine, "migrate_file runs before TapHold.init")
	end)
end)
