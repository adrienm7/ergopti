--- tests/unit/adapters/test_spawn_args_are_strings.lua

--- ==============================================================================
--- MODULE: Spawn argument typing (keylogger-worker-timings-must-be-strings)
--- DESCRIPTION:
--- quote() composes a SHELL STRING, where tostring() is a meaningful conversion,
--- so it is deliberately forgiving. An argv array is a different boundary: libuv
--- hands each element to execve(2) as a C string and refuses anything else
--- without naming the offending slot.
---
--- The Windows driver shipped that exact defect for sixteen days -- six Integer
--- timing constants spliced into the metrics worker's vector -- and the argument
--- index was the only diagnostic that ever located it. This driver was already
--- correct by discipline (curl_args tostring()s every numeric option), which is
--- precisely the kind of correctness that regresses silently: nothing enforced
--- it. These tests enforce it.
---
--- ROOT CAUSE ENCODED: refuse by index at the argv boundary, before libuv, on
--- every driver; and prove both luv.spawn sites validate ahead of spawning.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_driver_file(relative_path)
	local path = helpers.driver_root() .. "/" .. relative_path
	local fh = io.open(path, "r")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	return src
end




-- ================================================================
-- ================================================================
-- ======= 1/ The validator names the offending slot ==============
-- ================================================================
-- ================================================================

helpers.describe("ShellRunner: argv typing", function()

	helpers.it("refuses a non-string argument by its index", function()
		local Shell = helpers.load_module("adapters.shell_runner")
		local refusal = Shell.validate_spawn_args("curl", { "--max-time", 5 })
		helpers.assert_contains(refusal, "argument 2",
			"the refusal must name the offending slot -- that index was the only "
			.. "diagnostic that located the identical Windows defect")
		helpers.assert_eq(
			Shell.validate_spawn_args("curl", { "--max-time", "5" }), "",
			"the same value as decimal text must be admissible, otherwise the "
			.. "guard would be vacuous")
	end)

	helpers.it("refuses every non-string element type, not only numbers", function()
		local Shell = helpers.load_module("adapters.shell_runner")
		local cases = {
			{ value = 5, label = "number" },
			{ value = true, label = "boolean" },
			{ value = {}, label = "table" },
			{ value = print, label = "function" },
		}
		for _, case in ipairs(cases) do
			local refusal = Shell.validate_spawn_args("curl", { "--flag", case.value })
			helpers.assert_true(refusal ~= "",
				"a " .. case.label .. " argument must be refused")
			helpers.assert_contains(refusal, "argument 2",
				"the " .. case.label .. " refusal must still name the index")
		end
		helpers.assert_eq(#cases, 4, "every non-string type must be covered")
	end)

	helpers.it("refuses an empty or non-string executable", function()
		local Shell = helpers.load_module("adapters.shell_runner")
		helpers.assert_true(Shell.validate_spawn_args("", { "--flag" }) ~= "",
			"an empty executable must be refused")
		helpers.assert_true(Shell.validate_spawn_args(nil, { "--flag" }) ~= "",
			"a nil executable must be refused")
	end)

	helpers.it("accepts a nil argument vector as 'no arguments'", function()
		local Shell = helpers.load_module("adapters.shell_runner")
		helpers.assert_eq(Shell.validate_spawn_args("curl", nil), "",
			"callers that pass no arguments must stay admissible")
	end)

	helpers.it("refuses a keyed table posing as an argument vector", function()
		local Shell = helpers.load_module("adapters.shell_runner")
		helpers.assert_true(
			Shell.validate_spawn_args("curl", { flag = "--x" }) ~= "",
			"a keyed table has no argv order and must be refused rather than "
			.. "silently spawning with zero arguments")
	end)

	-- quote() must stay forgiving: it is the shell-string path, and hundreds of
	-- call sites rely on tostring semantics. Pinning both behaviours together
	-- documents that the asymmetry is deliberate, not an oversight.
	helpers.it("leaves quote() forgiving -- the two boundaries differ on purpose",
		function()
			local Shell = helpers.load_module("adapters.shell_runner")
			helpers.assert_eq(Shell.quote(5), "'5'",
				"quote() composes a shell string, where tostring() is meaningful")
			helpers.assert_true(Shell.validate_spawn_args("curl", { 5 }) ~= "",
				"argv is not a shell string and must refuse the same value")
		end)




	-- ================================================================
	-- ================================================================
	-- ======= 2/ Every luv.spawn site validates first ================
	-- ================================================================
	-- ================================================================

	-- The whole class, not the one site the defect was found at: a future third
	-- spawn that skips the check is exactly how "fixed on Windows, still broken
	-- here" ships. Ordering matters too -- a check after luv.spawn proves nothing.
	helpers.it("both luv.spawn sites validate their argv before spawning", function()
		local sites = {
			{ file = "adapters/http_client.lua", binary = "curl" },
			{ file = "adapters/file_digest.lua", binary = "sha256sum" },
		}
		local checked = 0
		for _, site in ipairs(sites) do
			local src = read_driver_file(site.file)
			helpers.assert_true(src ~= nil and src ~= "",
				site.file .. " must be readable -- an unreadable source would make "
				.. "this guard pass vacuously")
			checked = checked + 1
			local validate_at = src:find("validate_spawn_args(", 1, true)
			-- The CALL, not the availability probe: both modules also test
			-- `type(luv.spawn) ~= "function"` near the top, and matching that
			-- would compare the ordering against the wrong line.
			local spawn_at = src:find("pcall(luv.spawn,", 1, true)
			helpers.assert_true(validate_at ~= nil,
				site.file .. " must validate its argv via ShellRunner.validate_spawn_args")
			helpers.assert_true(spawn_at ~= nil,
				site.file .. " must still spawn " .. site.binary
				.. " through pcall(luv.spawn, …) -- otherwise the assertion above "
				.. "is vacuous")
			helpers.assert_true(validate_at < spawn_at,
				site.file .. " must validate BEFORE luv.spawn, so a refusal costs no "
				.. "process (keylogger-worker-timings-must-be-strings)")
		end
		helpers.assert_eq(checked, 2, "both spawn sites must have been inspected")
	end)

	-- The three drivers must agree on this contract, or the next audit fixes it
	-- in one place again. Both Lua drivers expose the same named entry point.
	helpers.it("exposes the same validator name as the macOS driver", function()
		local Shell = helpers.load_module("adapters.shell_runner")
		helpers.assert_type(Shell.validate_spawn_args, "function",
			"adapters.shell_runner must expose validate_spawn_args under the exact "
			.. "name the macOS driver uses, so the contract is greppable across drivers")
	end)
end)
