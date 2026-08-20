--- tests/unit/modules/updater/test_updater_version_compare.lua

--- Behavior parity gate for the semver comparator (lib-update-03 + D-1).
--- Drives macos/modules/updater/init.lua compare_versions over the SHARED cross-driver
--- vector table (_shared/modules/updater/version_vectors.json), which the JS
--- (tools/test/test-version-compare-contract.cjs) and AHK (test_updater.ahk)
--- suites also read. Non-semver tags MUST be fail-closed (expect 0) so an
--- ambiguous tag like "10" vs "9" can neither trigger nor suppress an update —
--- that lexicographic drift is exactly what this gate prevents.
---
--- This loads the module and asserts the RESULT, replacing the former
--- source-grep (which broke on a file move and asserted text tokens, not the
--- comparison outcome).

local helpers = require("tests.helpers")
local json    = require("json")

helpers.describe("updater.compare_versions: cross-driver version vectors (version-compare-parity)", function()
	-- modules.updater requires lib.logger / lib.dialog_util; stub the logger so the
	-- pure comparator loads headless under the hs stub.
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local updater = helpers.load_with_stubs("modules.updater")

	local path = helpers.shared("modules/updater/version_vectors.json")
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "version vectors must exist at: " .. path)
	local raw = fh:read("*a") ; fh:close()
	local vectors = (json.decode(raw) or {}).vectors or {}
	helpers.assert_true(#vectors >= 10, "version vectors: >=10 expected, got " .. #vectors)

	for _, v in ipairs(vectors) do
		helpers.it(
			"compare(" .. v.a .. ", " .. v.b .. ") == " .. tostring(v.expect) .. " [" .. v.id .. "]",
			function()
				helpers.assert_eq(updater.compare_versions(v.a, v.b), v.expect, v.id)
			end
		)
	end
end)
