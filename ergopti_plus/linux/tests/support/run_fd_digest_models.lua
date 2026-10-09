--- tests/support/run_fd_digest_models.lua

--- ==============================================================================
--- MODULE: Registered FD Digest Model Cohort
--- DESCRIPTION:
--- Executes six genuine normal-framework modules with fixed per-module floors.
--- This modeled cohort does not establish native descriptor or install proof.
--- ==============================================================================

local self_path = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local driver_root = self_path:match("^(.*)/tests/support/run_fd_digest_models%.lua$")
if not driver_root then
	assert(self_path == "tests/support/run_fd_digest_models.lua", "Canonical model qualifier path required")
	driver_root = "."
end
package.path = driver_root .. "/?.lua;" .. driver_root .. "/?/init.lua;"
	.. driver_root .. "/../_shared/lua/?.lua;" .. driver_root .. "/../_shared/lua/?/init.lua;" .. package.path

assert(_VERSION == "Lua 5.1" or _VERSION == "Lua 5.4", "Required Lua ABI unavailable")
if _VERSION == "Lua 5.1" then
	assert(type(jit) == "table" and jit.os == "Linux", "Actual Linux LuaJIT required")
end

local helpers = require("tests.helpers")
local get_results = assert(helpers.get_results)
local initial = get_results()
assert(initial.passed == 0 and initial.failed == 0, "Fresh framework process required")
local manifest = require("tests.test_manifest")
local registrations = {}
for _, name in ipairs(manifest) do registrations[name] = (registrations[name] or 0) + 1 end
local cohort = {
	{ "tests.unit.infra.test_archive_output", 26 },
	{ "tests.unit.infra.test_archive_output_input", 25 },
	{ "tests.unit.infra.test_fd_sha256", 21 },
	{ "tests.unit.infra.test_archive_seal", 25 },
	{ "tests.unit.infra.test_archive_capability_identity", 6 },
	{ "tests.unit.meta.test_transfer_budget", 22 },
}

for _, entry in ipairs(cohort) do
	local name, floor = entry[1], entry[2]
	assert(registrations[name] == 1, "Required normal registration missing or duplicated: " .. name)
	assert(package.loaded[name] == nil, "Model module must execute once in its fresh process: " .. name)
	local before = get_results()
	local passed, failed = before.passed, before.failed
	require(name)
	local after = get_results()
	assert(after.passed >= passed and after.failed >= failed, "Framework counters regressed: " .. name)
	assert(after.passed + after.failed - passed - failed == floor,
		"Independent registered model floor changed: " .. name)
end
local results = get_results()
assert(results.passed + results.failed == 125, "Independent six-module cohort floor changed")
print(string.format("Registered FD digest models: %d passed, %d failed; 0 skipped.", results.passed, results.failed))
assert(results.failed == 0 and results.passed == 125, "Registered FD digest model qualification failed")
