--- tests/unit/platform/remap/config/test_config_preferences_source.lua

--- ==============================================================================
--- MODULE: Remap Rows And The Preferences Source
--- DESCRIPTION:
--- The tap-hold rows of the manifest are config.toml rows (config schema v22),
--- and the preferences owner saves config.toml only over the exact bytes it last
--- read or wrote. A remap save that publishes those rows hands the new bytes to
--- that owner; without it, a global restore refused at its next category and
--- every later preference save was refused.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYS = { { id = "caps_lock" }, { id = "escape" } }
local COMBOS = { { id = "esc_tab" } }
local CONFIG_BEFORE = "[gestures]\nenabled = true\n"

--- Runs body with the real config module over in-memory files and a
--- preferences owner that tracks config.toml.
--- @param tracked table|nil The source the preferences owner holds, nil for none.
--- @param body function Receives the config module, the disk and the owner's calls.
local function with_disk(tracked, body)
	helpers.with_stub_scope({ "platform.remap.config", "platform.remap.tap_hold_file", "adapters.file_system",
		"infra.toml.codec", "toml_codec", "infra.preferences" }, function()
		local config = helpers.load_with_stubs("platform.remap.config")
		local config_path = config.config_toml_path_for("remap.toml")
		local disk = { [config_path] = CONFIG_BEFORE }
		local files = require("adapters.file_system")
		local old_read, old_write = files.read_with_status, files.write_if_unchanged
		files.read_with_status = function(path) return disk[path], disk[path] and "ok" or "absent" end
		files.write_if_unchanged = function(path, content)
			disk[path] = content
			return true
		end
		local calls = {}
		package.loaded["infra.preferences"] = {
			source_snapshot = function(path)
				if path ~= config_path or tracked == nil then return nil end
				return { status = tracked.status, content = tracked.content }
			end,
			replace_source = function(path, expected, replacement)
				calls[#calls + 1] = { path = path, expected = expected, replacement = replacement }
				return tracked ~= nil and expected.content == tracked.content
			end,
		}
		local ok, err = pcall(body, config, disk, calls, config_path)
		files.read_with_status, files.write_if_unchanged = old_read, old_write
		if not ok then error(err, 0) end
	end)
end

helpers.describe("remap rows hand config.toml to the preferences owner", function()
	helpers.it("a save of the tap-hold rows replaces the read the preferences hold", function()
		with_disk({ status = "ok", content = CONFIG_BEFORE }, function(config, disk, calls, config_path)
			local state = config.build_recommended_state(KEYS, COMBOS)
			helpers.assert_true(config.save_user_config(state, "remap.toml", false))
			helpers.assert_true(disk[config_path] ~= CONFIG_BEFORE, "the rows are published to config.toml")
			helpers.assert_eq(calls, { { path = config_path, expected = { status = "ok", content = CONFIG_BEFORE },
				replacement = { status = "ok", content = disk[config_path] } } })
		end)
	end)

	helpers.it("no read is handed over before the preferences track config.toml", function()
		with_disk(nil, function(config, _, calls)
			local state = config.build_recommended_state(KEYS, COMBOS)
			helpers.assert_true(config.save_user_config(state, "remap.toml", false))
			helpers.assert_eq(calls, {})
		end)
	end)
end)

return true
