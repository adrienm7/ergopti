--- tests/unit/platform/remap/config/test_config_scope_source.lua

--- ==============================================================================
--- MODULE: Remap Configuration Under A Scope Transaction
--- DESCRIPTION:
--- A scope backs up tap_hold.toml, then saves: the save must refuse a
--- file that changed after that backup, or the backup would not hold the bytes
--- it replaced. The recommended state it saves sparsely must also load back as
--- exactly the recommended state, since absence is the neutral value.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYS = { { id = "caps_lock" }, { id = "left_shift" }, { id = "escape" } }
local COMBOS = { { id = "esc_tab" } }

--- Runs body with the real config module over an in-memory pair of files:
--- remap.toml (`disk.content`) and the config.toml beside it (`disk.config`),
--- which holds the manifest rows. `disk.writes` counts remap.toml's writes.
--- @param source string|nil Initial bytes, nil for absent.
--- @param body function Receives the config module and the disk table.
local function with_disk(source, body)
	helpers.with_stub_scope({ "platform.remap.config", "platform.remap.tap_hold_file", "core.fs.adapters.file_system", "core.text.engine.toml.codec", "core.text.engine.toml_codec" }, function()
		local config = helpers.load_with_stubs("platform.remap.config")
		local files = require("core.fs.adapters.file_system")
		local old_read, old_write = files.read_with_status, files.write_if_unchanged
		local config_path = config.config_toml_path_for("remap.toml")
		local disk = { content = source, writes = 0, config_writes = 0 }
		files.read_with_status = function(path)
			if path == config_path then return disk.config, disk.config and "ok" or "absent" end
			if disk.before_read then disk.before_read() end
			return disk.content, disk.content and "ok" or "absent"
		end
		files.write_if_unchanged = function(path, content)
			if path == config_path then
				disk.config_writes, disk.config = disk.config_writes + 1, content
				return true
			end
			disk.writes, disk.content = disk.writes + 1, content
			return true
		end
		local ok, err = pcall(body, config, disk)
		files.read_with_status, files.write_if_unchanged = old_read, old_write
		if not ok then error(err, 0) end
	end)
end

helpers.describe("remap configuration under a scope transaction", function()
	helpers.it("saves only over the exact bytes the scope backed up", function()
		with_disk("[other]\nvalue = 17\n", function(config, disk)
			local state = config.build_recommended_state(KEYS, COMBOS)
			helpers.assert_true(config.save_user_config(state, "remap.toml", false,
				{ status = "ok", content = "[other]\nvalue = 17\n" }))
			helpers.assert_eq(disk.writes, 1)
			helpers.assert_eq(require("core.text.engine.toml_codec").decode(disk.content).other.value, 17)
		end)
	end)

	helpers.it("refuses a file edited after its backup and writes nothing", function()
		with_disk("[other]\nvalue = 17\n", function(config, disk)
			disk.before_read = function() disk.content = "[other]\nvalue = 18\n" end
			local state = config.build_recommended_state(KEYS, COMBOS)
			helpers.assert_eq(config.save_user_config(state, "remap.toml", false,
				{ status = "ok", content = "[other]\nvalue = 17\n" }), false)
			helpers.assert_eq(disk.writes, 0)
			helpers.assert_eq(disk.content, "[other]\nvalue = 18\n")
		end)
	end)

	helpers.it("rewrites an unparseable file only over the exact bytes a scope backed up", function()
		local corrupt = "[tap_holds\nenabled = true\n"
		with_disk(corrupt, function(config, disk)
			local state = config.build_recommended_state(KEYS, COMBOS)
			helpers.assert_eq(config.save_user_config(state, "remap.toml", false), false,
				"an ordinary save still refuses the unparseable file")
			helpers.assert_eq(disk.writes, 0)
			helpers.assert_true(config.save_user_config(state, "remap.toml", false,
				{ status = "ok", content = corrupt }))
			helpers.assert_eq(disk.writes, 1)
			local loaded, status = config.load_user_config(KEYS, COMBOS, "remap.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(loaded.tap_hold_config, state.tap_hold_config)
		end)
	end)

	helpers.it("refuses a file created after an absent backup", function()
		with_disk("[other]\nvalue = 1\n", function(config, disk)
			local state = config.build_default_state(KEYS, COMBOS)
			helpers.assert_eq(config.save_user_config(state, "remap.toml", false, { status = "absent" }), false)
			helpers.assert_eq(disk.writes, 0)
		end)
	end)

	helpers.it("loads a sparse recommended save back as exactly the recommended state", function()
		with_disk(nil, function(config, disk)
			local recommended = config.build_recommended_state(KEYS, COMBOS)
			helpers.assert_true(config.save_user_config(recommended, "remap.toml", false, { status = "absent" }))
			local loaded, status = config.load_user_config(KEYS, COMBOS, "remap.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(loaded.tap_holds_enabled, recommended.tap_holds_enabled)
			helpers.assert_eq(loaded.tap_hold_config, recommended.tap_hold_config)
			helpers.assert_eq(loaded.mod_combos_config, recommended.mod_combos_config)
			helpers.assert_eq(loaded.tap_hold_timeout_ms, recommended.tap_hold_timeout_ms)
			helpers.assert_eq(loaded.sticky_timeout_ms, recommended.sticky_timeout_ms)
			helpers.assert_true(disk.content:find("caps_lock", 1, true) ~= nil,
				"the recommended bindings are written explicitly")
		end)
	end)
end)


-- The tap-hold switch, timings and [mod_combos] live in config.toml. The
-- menus' scopes compare config.toml with the bytes the preferences loaded, so
-- a remap save that rewrites those rows must hand the new bytes over, or the
-- next participant of a global restore refuses its own scope.
helpers.describe("remap save of config.toml rows and the preferences source", function()
	--- Runs body with a fake preferences owner that loaded `loaded` for path.
	local function with_preferences(loaded, body)
		local previous = package.loaded["infra.preferences"]
		local owner = { exchanges = 0, snapshots = {} }
		function owner.source_snapshot(path) return owner.snapshots[path] end
		function owner.replace_source(path, expected, replacement)
			local current = owner.snapshots[path]
			if type(current) ~= "table" or current.status ~= expected.status or current.content ~= expected.content then
				return false
			end
			owner.exchanges, owner.snapshots[path] = owner.exchanges + 1, replacement
			return true
		end
		package.loaded["infra.preferences"] = owner
		local ok, err = pcall(body, owner, loaded)
		package.loaded["infra.preferences"] = previous
		if not ok then error(err, 0) end
	end

	helpers.it("moves the loaded preferences source to the published config.toml (global-restore-shortcuts)", function()
		with_disk("[other]\nvalue = 17\n", function(config, disk)
			disk.config = "[tap_holds]\nenabled = true\n"
			with_preferences(nil, function(owner)
				local config_path = config.config_toml_path_for("remap.toml")
				owner.snapshots[config_path] = { status = "ok", content = disk.config }
				local state = config.build_recommended_state(KEYS, COMBOS)
				state.tap_holds_enabled = false
				helpers.assert_true(config.save_user_config(state, "remap.toml", false,
					{ status = "ok", content = "[other]\nvalue = 17\n" }))
				helpers.assert_eq(disk.config_writes, 1, "the switch is a config.toml row")
				helpers.assert_eq(owner.exchanges, 1)
				helpers.assert_eq(owner.snapshots[config_path].content, disk.config,
					"the preferences acknowledge the bytes now on disk")
			end)
		end)
	end)

	helpers.it("leaves a config.toml the preferences never loaded alone", function()
		with_disk("[other]\nvalue = 17\n", function(config, disk)
			disk.config = "[tap_holds]\nenabled = true\n"
			with_preferences(nil, function(owner)
				local state = config.build_recommended_state(KEYS, COMBOS)
				state.tap_holds_enabled = false
				helpers.assert_true(config.save_user_config(state, "remap.toml", false,
					{ status = "ok", content = "[other]\nvalue = 17\n" }))
				helpers.assert_eq(disk.config_writes, 1)
				helpers.assert_eq(owner.exchanges, 0)
			end)
		end)
	end)
end)

return true
