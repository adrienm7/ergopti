--- tests/meta/test_e2e_exercises_real_dispatch.lua

--- ==============================================================================
--- MODULE: Regression — the "macOS E2E" CI job no longer overclaims coverage (F-HIGH-30)
--- DESCRIPTION:
--- .github/workflows/ci.yml's `e2e-hs` job was named 'macOS · E2E' and ran on
--- ubuntu-latest, executing tests/e2e/run_e2e.lua — which drives Registry +
--- Expander directly via Expander.try_expand(), the EXACT SAME in-memory
--- tests/stubs/hs.lua fake that tests/unit uses. No real Hammerspoon process,
--- no WindowServer, no CGEventPost round-trip is ever exercised in CI.
--- tests/e2e/PLAN_E2E_REAL_HS.md documents this is deliberately deferred (it
--- requires a self-hosted macOS runner with a live GUI session — building that
--- is out of scope here), but nothing in the green CI check communicated that
--- to a reviewer: a "macOS · E2E" job passing looks exactly like real OS-level
--- coverage.
---
--- CHOSEN FIX: renamed the CI job display name and added an explanatory
--- comment block directly above it in ci.yml, rather than building the
--- self-hosted-runner job sketched in PLAN_E2E_REAL_HS.md (that requires
--- physical macOS GUI infrastructure this task cannot provision) or rewriting
--- run_e2e.lua to drive the real onKeyDownRaw dispatch entry point (that
--- function consumes a real hs.eventtap.event object with getKeyCode/getFlags/
--- getCharacters/getProperty methods across ~200 lines of keycode-level
--- dispatch — faithfully synthesizing that for every corpus vector is a much
--- larger undertaking than a naming fix, and Expander.try_expand already
--- exercises the real Registry + Expander logic layer). A reviewer can now
--- immediately tell, from the job name alone, that this is a stubbed
--- virtual-keyboard replay and not real macOS/Hammerspoon coverage.
---
--- This test is a source-invariant check on ci.yml itself: the e2e-hs job's
--- display name must no longer read exactly 'macOS · E2E' (the overclaiming
--- string), and the job definition must carry an explanatory comment
--- referencing the stub/deferred nature of the coverage.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Climb from macos/ root up to repo root, same pattern as
-- tests/meta/test_port_adapter_coverage.lua's REPO_ROOT derivation.
local DRIVER_ROOT = helpers.driver_root()
local REPO_ROOT   = DRIVER_ROOT:gsub("[/\\]static[/\\]ergopti_plus[/\\]macos[/\\]?$", "")

local function read_ci_yml()
	local path = REPO_ROOT .. "/.github/workflows/ci.yml"
	local fh   = io.open(path, "r")
	helpers.assert_true(fh ~= nil, ".github/workflows/ci.yml must be readable at " .. path)
	local src = fh:read("*a"); fh:close()
	return src
end

helpers.describe("F-HIGH-30: the macOS virtual-keyboard CI job no longer overclaims coverage", function()

	helpers.it("the e2e-hs job's display name is no longer the bare overclaiming 'macOS · E2E'", function()
		local src = read_ci_yml()

		local job_pos = src:find("\n  e2e%-hs:\n")
		helpers.assert_true(job_pos ~= nil, "ci.yml must still define the e2e-hs job")

		-- Look at the name: line immediately following the job key.
		local name_line = src:match("\n  e2e%-hs:\n%s*name: '([^']*)'")
		helpers.assert_true(name_line ~= nil, "the e2e-hs job must have a quoted name: field")
		helpers.assert_true(name_line ~= "macOS · E2E",
			"the e2e-hs job name must no longer read the bare, overclaiming 'macOS · E2E' — " ..
			"this job runs on ubuntu-latest against a stubbed hs.* fake, never a real macOS/Hammerspoon " ..
			"process, and the display name must say so (F-HIGH-30)")
	end)

	helpers.it("the e2e-hs job name explicitly flags itself as stubbed / not real Hammerspoon", function()
		local src = read_ci_yml()
		local name_line = src:match("\n  e2e%-hs:\n%s*name: '([^']*)'")
		helpers.assert_true(name_line ~= nil, "the e2e-hs job must have a quoted name: field")

		local lowered = name_line:lower()
		helpers.assert_true(
			lowered:find("stub", 1, true) ~= nil or lowered:find("not real", 1, true) ~= nil,
			"the e2e-hs job name must flag that it is a stubbed harness, not real Hammerspoon coverage " ..
			"(got: '" .. name_line .. "')")
	end)

	helpers.it("ci.yml documents WHY the e2e-hs job is not real macOS/Hammerspoon coverage", function()
		local src = read_ci_yml()
		local job_pos = src:find("\n  e2e%-hs:\n")
		helpers.assert_true(job_pos ~= nil, "ci.yml must still define the e2e-hs job")

		-- The explanatory comment block sits directly above the job key.
		local preceding = src:sub(math.max(1, job_pos - 900), job_pos)
		helpers.assert_true(preceding:find("PLAN_E2E_REAL_HS", 1, true) ~= nil,
			"a comment above the e2e-hs job must reference tests/e2e/PLAN_E2E_REAL_HS.md " ..
			"so a reviewer can find the deferred real-coverage plan (F-HIGH-30)")
		helpers.assert_true(preceding:find("ubuntu%-latest") ~= nil or preceding:find("WindowServer", 1, true) ~= nil,
			"the comment above the e2e-hs job must explain the ubuntu-latest / no-WindowServer constraint")
	end)
end)
