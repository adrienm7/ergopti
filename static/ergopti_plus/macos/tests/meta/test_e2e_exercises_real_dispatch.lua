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
--- comment block directly above it, rather than building the self-hosted-runner
--- job sketched in PLAN_E2E_REAL_HS.md (that requires physical macOS GUI
--- infrastructure this task cannot provision) or rewriting run_e2e.lua to drive
--- the real onKeyDownRaw dispatch entry point (that function consumes a real
--- hs.eventtap.event object with getKeyCode/getFlags/getCharacters/getProperty
--- methods across ~200 lines of keycode-level dispatch — faithfully synthesizing
--- that for every corpus vector is a much larger undertaking than a naming fix,
--- and Expander.try_expand already exercises the real Registry + Expander logic
--- layer). A reviewer can now immediately tell, from the check name alone, that
--- this is a stubbed virtual-keyboard replay and not real macOS/Hammerspoon
--- coverage.
---
--- The harness runs in the separate `e2e-hs` job after unit tests in
--- .github/workflows/ci-macos.yml, which ci.yml calls as its 'macOS' box, so
--- its check reads 'macOS / <job name>'. This test is a source-invariant check
--- on that file: the step that runs the harness and the job that owns it must
--- both say "stub", the comment block right above the step must explain why,
--- and no job or step may be named a bare 'E2E'. Every lookup asserts, so a
--- check cannot pass against a step or a file that is no longer there.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Climb from macos/ root up to repo root, same pattern as
-- tests/meta/test_port_adapter_coverage.lua's REPO_ROOT derivation.
local DRIVER_ROOT = helpers.driver_root()
local REPO_ROOT   = DRIVER_ROOT:gsub("[/\\]static[/\\]ergopti_plus[/\\]macos[/\\]?$", "")

local PIPELINE  = ".github/workflows/ci.yml"
local MACOS_BOX = ".github/workflows/ci-macos.yml"
local HARNESS   = "tests/e2e/run_e2e.lua"

--- Reads one repository file, asserting that it exists and is not empty.
--- @param rel string Repository-relative path.
--- @return string
local function read_repo_file(rel)
	local path = REPO_ROOT .. "/" .. rel
	local fh   = io.open(path, "r")
	helpers.assert_true(fh ~= nil, rel .. " must be readable at " .. path)
	local src = fh:read("*a"); fh:close()
	helpers.assert_true(#src > 0, rel .. " must not be empty")
	return src
end

--- Returns a YAML scalar without its surrounding whitespace and quotes.
--- @param raw string
--- @return string
local function unquote(raw)
	local value = raw:gsub("^%s+", ""):gsub("%s+$", "")
	return value:match("^'(.*)'$") or value:match('^"(.*)"$') or value
end

--- Locates the one step that runs the stubbed harness and the job that owns it.
--- @param src string ci-macos.yml source.
--- @return table { step_at, step_name, job_id, job_name }
local function locate_harness(src)
	local run_at = src:find(HARNESS, 1, true)
	helpers.assert_true(run_at ~= nil, MACOS_BOX .. " must run " .. HARNESS)
	helpers.assert_true(src:find(HARNESS, run_at + 1, true) == nil,
		MACOS_BOX .. " must run " .. HARNESS .. " exactly once")

	-- The step starts at the last six-space list item before the command.
	local step_at
	local cursor = 1
	while true do
		local found = src:find("\n      %- ", cursor)
		if not found or found > run_at then break end
		step_at, cursor = found, found + 1
	end
	helpers.assert_true(step_at ~= nil, "the harness command must sit inside a workflow step")
	local step_name = src:match("^\n      %- name:([^\n]*)", step_at)
	helpers.assert_true(step_name ~= nil, "the harness step must open with its name: field")

	-- The job is the last two-space key before the step.
	local job_at, job_id
	cursor = 1
	while true do
		local found, stop, id = src:find("\n  ([%w_%-]+):[ \t]*\n", cursor)
		if not found or found > step_at then break end
		job_at, job_id, cursor = found, id, stop
	end
	helpers.assert_true(job_at ~= nil, "the harness step must belong to a job")
	local job_name = src:match("^\n  [%w_%-]+:[ \t]*\n    name:([^\n]*)", job_at)
	-- The bound temporary prerelease condition is the only admitted prelude.
	-- The raw central CI policy separately validates its authorization and full defaults.
	local fast_header = "\n  e2e-hs:\n    if: ${{ !inputs.fast_prerelease }}\n"
	if job_name == nil and job_id == "e2e-hs"
		and src:sub(job_at, job_at + #fast_header - 1) == fast_header then
		job_name = src:match("^    name:([^\n]*)", job_at + #fast_header)
	end
	helpers.assert_true(job_name ~= nil, "the harness job must open with its name: field")

	return {
		step_at   = step_at,
		step_name = unquote(step_name),
		job_id    = job_id,
		job_name  = unquote(job_name),
	}
end

--- True when a display name says it is a stub rather than real coverage.
--- @param name string
--- @return boolean
local function flags_stub(name)
	local lowered = name:lower()
	return lowered:find("stub", 1, true) ~= nil or lowered:find("not real", 1, true) ~= nil
end

helpers.describe("F-HIGH-30: the macOS virtual-keyboard CI job no longer overclaims coverage", function()

	helpers.it("ci.yml runs the macOS box that holds the stubbed harness", function()
		local src = read_repo_file(PIPELINE)
		helpers.assert_true(src:find("uses: ./" .. MACOS_BOX, 1, true) ~= nil,
			PIPELINE .. " must call " .. MACOS_BOX .. ", or the harness below never runs")
	end)

	helpers.it("the harness step and its job flag themselves as stubbed / not real Hammerspoon", function()
		local harness = locate_harness(read_repo_file(MACOS_BOX))
		helpers.assert_true(harness.job_id == "e2e-hs",
			"the stubbed harness must run in the Hammerspoon E2E job e2e-hs (got: " .. harness.job_id .. ")")
		helpers.assert_true(flags_stub(harness.step_name),
			"the harness step name must flag that it is a stubbed harness, not real Hammerspoon coverage " ..
			"(got: '" .. harness.step_name .. "')")
		-- The job name is what the check reads, as 'macOS / <job name>'.
		helpers.assert_true(flags_stub(harness.job_name),
			"the name of the job that runs the harness must flag the stub too, since it is the check name " ..
			"a reviewer reads (got: '" .. harness.job_name .. "')")
	end)

	helpers.it("no macOS job or step is named a bare, overclaiming 'E2E'", function()
		local src = read_repo_file(MACOS_BOX)
		local names = 0
		for raw in src:gmatch("\n +%-? *name:([^\n]*)") do
			local name = unquote(raw)
			names = names + 1
			local bare = name:lower():gsub("^macos%s*·%s*", "")
			helpers.assert_true(bare ~= "e2e",
				"'" .. name .. "' reads as real macOS/Hammerspoon coverage, which this box does not have (F-HIGH-30)")
		end
		helpers.assert_true(names >= 10, MACOS_BOX .. " must declare its job and step names (found " .. names .. ")")
	end)

	helpers.it("ci-macos.yml documents WHY the harness is not real macOS/Hammerspoon coverage", function()
		local src = read_repo_file(MACOS_BOX)
		local harness = locate_harness(src)

		-- The explanatory comment block sits directly above the step.
		local preceding = src:sub(math.max(1, harness.step_at - 900), harness.step_at)
		helpers.assert_true(preceding:find("PLAN_E2E_REAL_HS", 1, true) ~= nil,
			"a comment above the harness step must reference tests/e2e/PLAN_E2E_REAL_HS.md " ..
			"so a reviewer can find the deferred real-coverage plan (F-HIGH-30)")
		helpers.assert_true(preceding:find("ubuntu%-latest") ~= nil or preceding:find("WindowServer", 1, true) ~= nil,
			"the comment above the harness step must explain the ubuntu-latest / no-WindowServer constraint")
	end)
end)

--- Closed workflow-source fixtures; these do not execute GitHub or Hammerspoon.
helpers.describe("F-HIGH-30: exact temporary fast-header composition", function()
	local function fixture(header, job_name, step_name)
		return "jobs:\n" .. header .. "    name: " .. (job_name or "'E2E tests (stubbed)'")
			.. "\n    steps:\n      - name: " .. (step_name or "Run virtual-keyboard harness (stubbed)")
			.. "\n        run: lua5.4 " .. HARNESS .. "\n"
	end
	helpers.it("both ordinary and exact fast headers preserve stub coverage labels", function()
		for _, header in ipairs({ "  e2e-hs:\n", "  e2e-hs:\n    if: ${{ !inputs.fast_prerelease }}\n" }) do
			local harness = locate_harness(fixture(header))
			helpers.assert_eq(harness.job_id, "e2e-hs")
			helpers.assert_true(flags_stub(harness.job_name))
			helpers.assert_true(flags_stub(harness.step_name))
		end
	end)
	-- Bind refusal to the name-field guard, not an unrelated exception. The
	-- shared assertion helper prefixes source location and appends the false value.
	helpers.it("arbitrary disabling or overbroad conditions are refused", function()
		for _, condition in ipairs({ "false", "true", "always()", "${{ !inputs.fast_prerelease || true }}", "${{ !inputs.fast_prerelease && false }}" }) do
			local ok, reason = pcall(locate_harness, fixture("  e2e-hs:\n    if: " .. condition .. "\n"))
			helpers.assert_eq(ok, false, "an unadmitted job condition must not hide the mandatory name")
			helpers.assert_true(type(reason) == "string" and #reason > 0, "condition refusal must have a string reason")
			helpers.assert_eq(reason:match("^.-:%d+: (.-) — actual: false$"),
				"the harness job must open with its name: field")
		end
	end)
	helpers.it("a duplicated condition or foreign job cannot acquire this prelude", function()
		for _, header in ipairs({
			"  e2e-hs:\n    if: ${{ !inputs.fast_prerelease }}\n    if: ${{ !inputs.fast_prerelease }}\n",
			"  other-hs:\n    if: ${{ !inputs.fast_prerelease }}\n",
		}) do
			local accepted, reason = pcall(locate_harness, fixture(header))
			helpers.assert_eq(accepted, false)
			helpers.assert_true(type(reason) == "string" and #reason > 0, "prelude refusal must have a string reason")
			helpers.assert_eq(reason:match("^.-:%d+: (.-) — actual: false$"),
				"the harness job must open with its name: field")
		end
	end)
	helpers.it("the exact prelude never substitutes for a job name", function()
		local src = fixture("  e2e-hs:\n    if: ${{ !inputs.fast_prerelease }}\n")
		src = src:gsub("    name: 'E2E tests %(stubbed%)'\n", "")
		local accepted, reason = pcall(locate_harness, src)
		helpers.assert_eq(accepted, false)
		helpers.assert_true(type(reason) == "string" and #reason > 0, "missing-name refusal must have a string reason")
		helpers.assert_eq(reason:match("^.-:%d+: (.-) — actual: false$"),
			"the harness job must open with its name: field")
	end)
	helpers.it("the same label predicates reject overclaimed fast-header coverage", function()
		local header = "  e2e-hs:\n    if: ${{ !inputs.fast_prerelease }}\n"
		local job = locate_harness(fixture(header, "'E2E'"))
		local step = locate_harness(fixture(header, nil, "Run real Hammerspoon E2E"))
		helpers.assert_eq(flags_stub(job.job_name), false)
		helpers.assert_eq(flags_stub(step.step_name), false)
	end)
end)
