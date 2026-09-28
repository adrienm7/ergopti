--- tests/unit/modules/shortcuts/test_bindings_fixture_config.lua

--- Keeps real TapKeys preference setup inside a reversible in-memory file boundary.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

local function scenario(body)
	return helpers.with_stub_scope({ "modules.shortcuts.tap_keys", "infra.preferences",
		"infra.config_paths", "adapters.file_system" }, function()
		helpers.load_with_stubs("infra.preferences")
		local files = require("adapters.file_system")
		local paths = require("infra.config_paths")
		local escaped = 0
		local native_read = files.read_with_status
		local function forbidden()
			escaped = escaped + 1
			error("fixture escaped to external configuration")
		end
		local read = function(path)
			if path == helpers.shared("modules/actions/tap_keys.json") then return native_read(path) end
			return forbidden()
		end
		files.read_with_status, files.write_if_unchanged, files.write = read, forbidden, forbidden
		paths.get = forbidden
		local selected = false
		local bindings = {
			pause_hotkeys_only = function() return true end,
			list_shortcuts = function() return { { id = "tap_keys" } } end,
			enable = function() selected = true; return true end,
			is_bound = function() return false end,
			release_pause_admission = function() return true end,
		}
		body(bindings)
		helpers.assert_eq(escaped, 0)
		helpers.assert_eq(files.read_with_status, read)
		helpers.assert_eq(files.write_if_unchanged, forbidden)
		helpers.assert_eq(files.write, forbidden)
		helpers.assert_eq(paths.get, forbidden)
		return selected
	end)
end

helpers.describe("bindings fixture canonical file isolation", function()
	helpers.it("configures the real TapKeys owner without external I/O on repeated setup", function()
		helpers.assert_eq(scenario(function(bindings)
			Fixture.prefer_all(bindings)
			helpers.assert_eq(require("modules.shortcuts.tap_keys").get_action("number_row_left"), "screen_capture")
			Fixture.prefer_all(bindings)
		end), true)
	end)

	helpers.it("restores every file and path port after preference setup throws", function()
		scenario(function(bindings)
			bindings.pause_hotkeys_only = function() error("native admission refused") end
			local ok, detail = pcall(Fixture.prefer_all, bindings)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("native admission refused", 1, true) ~= nil)
		end)
	end)
end)
