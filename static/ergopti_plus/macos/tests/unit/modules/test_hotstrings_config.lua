--- tests/unit/modules/test_hotstrings_config.lua

--- ==============================================================================
--- MODULE: hotstrings_config Priority Unit Tests
--- DESCRIPTION:
--- The delays/colors window edits per-section/file collision priority through
--- modules.hotstrings_config, persisting to the shared `hotstrings_config.toml`
--- override file that BOTH drivers read. These tests pin that priority is an
--- accepted override field, serialises as a BARE INTEGER, round-trips through
--- serialize -> parse, is reported by get_user_override, and is cleared cleanly.
--- ==============================================================================

local helpers = require("tests.helpers")

-- hotstrings_config logs through lib.logger; load it first under the stub.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

--- Build a unique writable temp path (the module itself creates the file).
--- @param name string A short discriminator so concurrent cases never collide.
--- @return string The absolute path to a (not-yet-created) override file.
local function temp_path(name)
	local base = (os.getenv("TEMP") or os.getenv("TMPDIR") or "."):gsub("\\", "/")
	return base .. "/hcfg_" .. name .. "_" .. tostring(os.time()) .. ".toml"
end

--- Reload the module so its module-level `_state` resets, then init it against a
--- fresh override file with a no-op TOML resolver (no package defaults).
--- @param path string The override file path.
--- @return table The freshly-initialised module.
local function fresh_module(path)
	package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	mod.init({ override_path = path, toml_resolver = function() return nil end })
	return mod
end




helpers.describe("hotstrings_config: priority override round-trip", function()
	helpers.it("set/clear priority persists as a bare integer and round-trips through disk", function()
		local path = temp_path("rt")
		os.remove(path)
		local mod = fresh_module(path)

		helpers.assert_eq(mod.set_override("rolls", nil, "priority", 25), true, "file-level priority accepted")
		helpers.assert_eq(mod.set_override("rolls", "ct", "priority", 80), true, "section priority accepted")

		-- In-memory introspection used by the window's overridden/reset state.
		helpers.assert_eq(mod.get_user_override("rolls", nil).priority, 25)
		helpers.assert_eq(mod.get_user_override("rolls", "ct").priority, 80)

		-- Re-read from disk: serialize -> parse must preserve both levels.
		mod.reload()
		helpers.assert_eq(mod.get_user_override("rolls", nil).priority, 25, "file-level priority survives a reload")
		helpers.assert_eq(mod.get_user_override("rolls", "ct").priority, 80, "section priority survives a reload")

		-- Priority is a BARE integer in the TOML, never a quoted string.
		local fh = io.open(path, "r")
		local txt = fh:read("*a")
		fh:close()
		helpers.assert_eq(txt:find("priority = 25", 1, true) ~= nil, true, "file-level priority is a bare integer")
		helpers.assert_eq(txt:find("priority = 80", 1, true) ~= nil, true, "section priority is a bare integer")
		helpers.assert_eq(txt:find('priority = "', 1, true) ~= nil, false, "priority is never quoted")

		-- Clearing the field drops it; the entry has no other override, so the
		-- whole entry resolves back to nil.
		mod.clear_override("rolls", nil, "priority")
		local fov = mod.get_user_override("rolls", nil)
		helpers.assert_eq(fov and fov.priority or nil, nil, "cleared file-level priority is gone")
		os.remove(path)
	end)

	helpers.it("clearing all fields (nil field) also clears priority", function()
		local path = temp_path("clrall")
		os.remove(path)
		local mod = fresh_module(path)
		mod.set_override("rolls", "ct", "delay", 0.2)
		mod.set_override("rolls", "ct", "priority", 77)
		mod.clear_override("rolls", "ct", nil)
		local ov = mod.get_user_override("rolls", "ct")
		helpers.assert_eq(ov, nil, "an empty-field clear wipes every field including priority")
		os.remove(path)
	end)

	helpers.it("set_override rejects a field other than delay/color/show_tooltip/priority", function()
		local path = temp_path("bad")
		os.remove(path)
		local mod = fresh_module(path)
		helpers.assert_eq(mod.set_override("rolls", nil, "badfield", 1), false, "unknown field is rejected")
		os.remove(path)
	end)
end)
