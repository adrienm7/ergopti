--- tests/unit/modules/test_karabiner_reset_script_self_destruct.lua

--- ==============================================================================
--- MODULE: Destructive Karabiner Reset Scripts Stay Retired
--- DESCRIPTION:
--- The old background reset wrote a detached script that enumerated and killed
--- shared Karabiner services. Self-deleting that artifact solved only its /tmp
--- leak; it did not make the destructive operation safe. Exact lease revocation
--- removes the script class entirely.
--- ==============================================================================

local helpers = require("tests.helpers")

local source = helpers.read_driver_source()
helpers.assert_true(type(source) == "string" and #source > 100000,
	"the production scan must cover the whole macOS driver")

for _, retired in ipairs({
	"KARABINER_KILL_TOTAL_SCRIPT",
	"run_total_reset_async",
	"ergopti_ke_total_reset",
}) do
	helpers.assert_true(source:find(retired, 1, true) == nil,
		"detached destructive Karabiner reset artifact must stay retired: " .. retired)
end

print("[PASS] test_karabiner_reset_script_self_destruct")
