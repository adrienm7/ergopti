--- tests/unit/lib/test_manifest_menu.lua

--- ==============================================================================
--- MODULE: Regression — ManifestMenu.build silently skips items with no handler (F-HIGH-25)
--- DESCRIPTION:
--- The "dynamic" and "action" dispatch branches in ManifestMenu.build fell
--- through silently when dynamic_handlers[id] was absent — unlike the sibling
--- "group" branch (which already warns on a missing id/i18n) and the unknown-type
--- else branch (which already warns on an unrecognised type). This let a
--- misclassified or drifted manifest entry vanish from the rendered menu with
--- zero diagnostic trail: personal_shortcuts was a live instance (declared with
--- no platforms restriction, so expected on macOS too, but menu_shortcuts.lua's
--- dyn_handlers had no matching key) before this same fix tagged it AHK-only.
---
--- Fix: log Logger.warn on a handler miss in both the "dynamic" and "action"
--- branches, matching the existing warn-on-drift convention already used by
--- the "group" and unknown-type branches.
---
--- This test exercises M.build with an EMPTY dynamic_handlers table against a
--- manifest entry of type "dynamic" (via a throwaway fixture manifest) and
--- asserts Logger.warn fires — it fails before the fix (zero warn calls,
--- silent skip) and passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a throwaway manifest fixture directory containing a "test_menu" key
--- with one type="dynamic" entry and one type="action" entry, neither of which
--- has a matching handler supplied by the test.
--- @return string tmp_dir Absolute path of the fixture directory created.
local function write_fixture_manifest()
	local tmp_dir = os.tmpname()
	os.remove(tmp_dir) -- os.tmpname() creates a file; we want a directory
	os.execute('mkdir "' .. tmp_dir .. '"')

	local manifest_dir = tmp_dir .. "/modules/menu"
	os.execute('mkdir "' .. tmp_dir .. '/modules" "' .. manifest_dir .. '"')

	local fh = io.open(manifest_dir .. "/menu_manifest.json", "w")
	helpers.assert_true(fh ~= nil, "could not create fixture menu_manifest.json")
	fh:write([[
{
	"test_menu": [
		{ "type": "dynamic", "id": "no_such_dynamic_handler" },
		{ "type": "action", "id": "no_such_action_handler" }
	]
}
]])
	fh:close()

	return tmp_dir
end

--- Builds a logger stub that records every Logger.warn call's format string.
--- @return table logger_stub Injectable package.loaded["lib.logger"] replacement.
--- @return table warn_messages Array of format strings passed to Logger.warn (grows live).
local function make_warn_capturing_logger()
	local warn_messages = {}
	local logger_stub = helpers.make_logger_stub()
	logger_stub.warn = function(_module, fmt, ...)
		-- Logger.warn(module, fmt, ...) formats internally, like the real logger —
		-- capture the FORMATTED message so id substitutions are actually visible.
		local ok, formatted = pcall(string.format, fmt, ...)
		warn_messages[#warn_messages + 1] = ok and formatted or tostring(fmt)
	end
	return logger_stub, warn_messages
end

helpers.describe("ManifestMenu.build: warns (does not silently skip) on a handler miss (F-HIGH-25)", function()
	helpers.it("logs Logger.warn when a type=dynamic entry has no matching dynamic_handlers key", function()
		local logger_stub, warn_messages = make_warn_capturing_logger()
		-- manifest_menu.lua captures `local Logger = require("lib.logger")` at
		-- require-time, so the stub must be installed BEFORE load_with_stubs
		-- forces a fresh require of lib.manifest_menu below.
		package.loaded["lib.logger"] = logger_stub

		local ManifestMenu = helpers.load_with_stubs("lib.manifest_menu")

		local tmp_dir = write_fixture_manifest()
		package.loaded["lib.paths"].shared = function(rel)
			if rel and rel ~= "" then return tmp_dir .. "/" .. rel end
			return tmp_dir
		end
		ManifestMenu.invalidate_cache()

		-- Empty dynamic_handlers: neither fixture entry has a matching handler.
		local built = ManifestMenu.build("test_menu", "Test", {}, nil, {})

		helpers.assert_eq(#built, 0, "no item should be rendered when no handler matches")
		helpers.assert_true(#warn_messages > 0,
			"Logger.warn must fire when a type=dynamic/action entry has no matching handler — " ..
			"silently skipping it hides a permanently vanished menu item (F-HIGH-25)")

		local saw_dynamic_warn = false
		local saw_action_warn = false
		for _, msg in ipairs(warn_messages) do
			if msg:find("no_such_dynamic_handler", 1, true) then saw_dynamic_warn = true end
			if msg:find("no_such_action_handler", 1, true) then saw_action_warn = true end
		end
		helpers.assert_true(saw_dynamic_warn, "a missing 'dynamic' handler must be named in the warning")
		helpers.assert_true(saw_action_warn, "a missing 'action' handler must be named in the warning")
	end)
end)
