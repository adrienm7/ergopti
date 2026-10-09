--- tests/unit/test_helpers_temp_dir.lua

--- ==============================================================================
--- MODULE: Isolated scratch directory for fixtures
---         (macos-test-fixtures-escape-into-the-repo)
--- DESCRIPTION:
--- Ten test files used to resolve their scratch directory inline as
--- `os.getenv("TEMP") or os.getenv("TMP") or "."`. On macOS -- the platform this
--- suite exists for -- TEMP and TMP are normally unset while TMPDIR is set, so
--- every one of those expressions returned ".": the process working directory,
--- which is the driver root inside the checkout.
---
--- The suite therefore wrote .toml fixtures into the repository, and the atomic
--- writer left its stable `.ergoptiplus-write-lock-v1` sidecar next to one of
--- them -- a zero-byte file that shows up in `git status` looking like real work
--- and that nothing ever removes.
---
--- ROOT CAUSE ENCODED: the ten call sites were the symptom; allowing a scratch
--- path to be RELATIVE at all was the defect. These tests pin the ordering that
--- makes macOS work, and pin that no environment can talk this helper into
--- handing back a path inside the checkout.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs `callback` with os.getenv answering from `env`, then restores it.
--- @param env table Map of variable name to value (absent keys read as nil).
--- @param callback function
--- @return any
local function with_env(env, callback)
	local real_getenv = os.getenv
	os.getenv = function(name) return env[name] end
	local ok, result = pcall(callback)
	os.getenv = real_getenv
	if not ok then error(result, 0) end
	return result
end




-- =====================================================
-- =====================================================
-- ======= 1/ TMPDIR is the macOS answer ===============
-- =====================================================
-- =====================================================

helpers.describe("helpers.temp_dir", function()

	helpers.it("prefers TMPDIR, which is the variable macOS actually sets", function()
		local resolved = with_env({ TMPDIR = "/var/folders/ab/T", TEMP = "/ignored" },
			helpers.temp_dir)
		helpers.assert_eq(resolved, "/var/folders/ab/T",
			"reading TEMP first is what made every macOS run fall through to '.' "
			.. "(macos-test-fixtures-escape-into-the-repo)")
	end)

	helpers.it("still honours TEMP and TMP where those are the ones set", function()
		helpers.assert_eq(with_env({ TEMP = "C:/Users/x/AppData/Local/Temp" },
			helpers.temp_dir), "C:/Users/x/AppData/Local/Temp")
		helpers.assert_eq(with_env({ TMP = "/tmp/fixture" }, helpers.temp_dir),
			"/tmp/fixture")
	end)

	helpers.it("falls back to /tmp, never to the working directory", function()
		helpers.assert_eq(with_env({}, helpers.temp_dir), "/tmp",
			"an unset environment must still produce an ABSOLUTE directory")
	end)

	helpers.it("normalises separators and drops a trailing slash", function()
		helpers.assert_eq(with_env({ TMPDIR = "C:\\Temp\\" }, helpers.temp_dir),
			"C:/Temp",
			"callers append '/name', so a trailing slash would produce a double one")
	end)




	-- =====================================================
	-- =====================================================
	-- ======= 2/ A relative answer is refused =============
	-- =====================================================
	-- =====================================================

	-- The whole class, not just ".": any relative answer lands inside the
	-- checkout, so each one must raise rather than quietly resolve.
	--
	-- Each case asserts the MESSAGE, not merely that pcall came back false. A
	-- status alone would prove "something raised" — including a typo in this test
	-- calling a nil field — which is the pcall-only false green the suite ratchets
	-- against. The message has to name both the rejected value and the
	-- consequence, because this failure is environmental and the person reading it
	-- is the one who has to fix their machine.
	helpers.it("refuses every relative scratch directory, and says why", function()
		local relatives = { ".", "./scratch", "tmp", "" }
		local refused = 0
		for _, candidate in ipairs(relatives) do
			local ok, err = pcall(function()
				return with_env({ TMPDIR = candidate }, helpers.temp_dir)
			end)
			helpers.assert_eq(ok, false,
				"'" .. candidate .. "' resolves inside the checkout and must raise "
				.. "(macos-test-fixtures-escape-into-the-repo)")
			helpers.assert_true(tostring(err):find("checkout", 1, true) ~= nil,
				"the refusal for '" .. candidate .. "' must name the consequence -- a "
				.. "fixture written into the repository is the thing prevented; got: "
				.. tostring(err))
			helpers.assert_true(tostring(err):find("scratch directory", 1, true) ~= nil,
				"and it must name what was being resolved, so the reader knows which "
				.. "environment variable to set; got: " .. tostring(err))
			refused = refused + 1
		end
		helpers.assert_eq(refused, #relatives,
			"every relative shape must have been exercised")
	end)

	helpers.it("resolves to an absolute directory on this machine too", function()
		local resolved = helpers.temp_dir()
		helpers.assert_true(type(resolved) == "string" and resolved ~= "")
		local absolute = resolved:sub(1, 1) == "/" or resolved:match("^%a:/") ~= nil
		helpers.assert_true(absolute,
			"the live environment must also produce an absolute path: got '"
			.. resolved .. "'")
		helpers.assert_true(resolved:sub(-1) ~= "/",
			"no trailing slash, so call sites can append '/name'")
	end)
end)
