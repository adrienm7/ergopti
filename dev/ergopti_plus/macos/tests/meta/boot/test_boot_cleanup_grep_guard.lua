--- tests/meta/boot/test_boot_cleanup_grep_guard.lua

--- ==============================================================================
--- MODULE: Boot cleanup grep guard (meta)
--- DESCRIPTION:
--- The boot cleanup shell command guards grep -c . with || true so it survives set -e.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("boot_cleanup.lua: grep -c . is guarded with || true (audit-v5)", function()

	helpers.it("grep -c . is followed by || true", function()
		-- The MLX boot kill_cmd was extracted from init.lua into the
		-- modules/llm/boot_cleanup.lua sibling; the set -e guard moved with it.
		-- Selected by a declaration unique to modules/llm/boot_cleanup.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.run_selective_cleanup")
		helpers.assert_true(src ~= nil, "modules/llm/boot_cleanup.lua source must be locatable")
		helpers.assert_true(
			src:find("grep -c . || true", 1, true) ~= nil,
			"boot_cleanup.lua kill_cmd must use `grep -c . || true` to survive set -e shells")
	end)

end)
