--- tests/unit/platform/remap/test_config_corrupt_toml_write_guard.lua

--- ==============================================================================
--- MODULE: config_karabiner.toml Corruption Guard — Write Path
--- DESCRIPTION:
--- Regression guard for the half of the corruption fix that was missing: the
--- READ path already falls back to defaults without touching an unparseable
--- config_karabiner.toml, but save_user_config() overwrote it anyway, so the
--- next setter the user touched (a tap action, a timeout, the on/off toggle)
--- destroyed the still-repairable file. Losing the data on the WRITE path made
--- the read-path refusal pointless.
---
--- FEATURES & RATIONALE:
--- 1. Real codec, real files: the shared TOML codec is pure Lua, so the tests
---    write genuinely malformed TOML to a temp file and let the production
---    decoder reject it — no stub that could disagree with the real parser.
--- 2. Root cause, not symptom: the assertions are about the bytes on disk, not
---    about a log line. A corrupt file must come back byte-identical and no
---    payload may be staged; a valid file must still be written normally.
--- 3. Class loop: the last test derives every Config.save_user_config() call site
---    from the whole driver source, so a future setter that opts out of the guard
---    joins the test automatically instead of being forgotten.
--- ==============================================================================

local helpers = require("tests.helpers")

local Config = helpers.load_with_stubs("platform.remap.config")
-- Required AFTER Config so this is the very table config.lua just captured.
local Logger = require("infra.logger")

-- Unclosed table header plus a bare unquoted value: the shared codec returns a
-- non-table for this input, which is exactly the "exists but cannot be decoded"
-- case the read path already refuses to reset.
local CORRUPT_TOML = "[karabiner\nenabled = true\n[tap_holds\nconfig = broken ]]\n"

-- A plausible, fully populated state — the writer must be able to encode it, so
-- a failure in the positive controls means the guard fired, not a bad fixture.
local function make_state()
	return {
		enabled                   = true,
		tap_hold_config           = { escape = { tap = "none", hold = "layer" } },
		mod_combos_config         = { esc_tab = { combo = "none", tap = "none", hold = "none" } },
		tap_hold_timeout_ms       = 200,
		sticky_timeout_ms         = 1000,
		simultaneous_threshold_ms = 50,
		combo_symmetric           = false,
	}
end

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local body = fh:read("*a")
	fh:close()
	return body
end

local function write_file(path, content)
	local fh = assert(io.open(path, "w"), "cannot create the fixture file")
	fh:write(content)
	fh:close()
end

local function cleanup(path)
	os.remove(path .. ".tmp")
	os.remove(path)
end

--- Returns the TOML the writer produced for `path`, wherever it landed.
--- POSIX rename() publishes over an existing target; Windows rename() refuses an
--- existing destination and the encoded payload stays staged at `.tmp`. Both
--- outcomes prove the same thing the positive controls care about: the writer ran
--- past the corruption guard and encoded the state. A refusal produces neither.
--- @param path string Config path passed to save_user_config.
--- @param original string|nil Content of the file before the save attempt.
--- @return string|nil The produced payload, or nil when nothing was written.
local function produced_payload(path, original)
	local staged = read_file(path .. ".tmp")
	if staged then return staged end
	local published = read_file(path)
	if published and published ~= original then return published end
	return nil
end

--- Runs `fn` with Logger.error captured, and returns the concatenated messages.
--- Restores the original function even when the body throws, so a failure here
--- never silences the logger for the rest of the suite.
--- @param fn function Body to run.
--- @return string All ERROR messages emitted during `fn`, newline-separated.
local function with_captured_errors(fn)
	local original = Logger.error
	local messages = {}
	Logger.error = function(_tag, fmt, ...)
		local ok, msg = pcall(string.format, tostring(fmt or ""), ...)
		messages[#messages + 1] = ok and msg or tostring(fmt)
	end
	local ok, err = pcall(fn)
	Logger.error = original
	if not ok then error(err, 0) end
	return table.concat(messages, "\n")
end





-- ===============================================
-- ===============================================
-- ======= 1/ Corrupt File Not Overwritten =======
-- ===============================================
-- ===============================================

helpers.describe("Config.save_user_config — corrupt file is not overwritten (karabiner-silent-reset)", function()

	helpers.it("leaves an unparseable config byte-identical and stages nothing", function()
		local path = os.tmpname()
		write_file(path, CORRUPT_TOML)

		local saved
		local logged = with_captured_errors(function()
			saved = Config.save_user_config(make_state(), path)
		end)

		local after = read_file(path)
		local staged = read_file(path .. ".tmp")
		cleanup(path)

		helpers.assert_eq(after, CORRUPT_TOML,
			"the corrupt user config must come back byte-identical (RED before the fix: overwritten by the setter)")
		helpers.assert_nil(staged,
			"nothing may be staged at .tmp either — the guard must fire before any write")
		helpers.assert_eq(saved, false,
			"save_user_config must report that nothing reached disk")
		helpers.assert_true(logged:find("Refusing to overwrite") ~= nil,
			"the refusal must be loud, naming the file: got " .. helpers.inspect(logged))
	end)

	helpers.it("names the corrupt path so the user can go and repair it", function()
		local path = os.tmpname()
		write_file(path, CORRUPT_TOML)

		local logged = with_captured_errors(function()
			Config.save_user_config(make_state(), path)
		end)
		cleanup(path)

		helpers.assert_true(logged:find(path, 1, true) ~= nil,
			"the refusal must quote the absolute path of the file it refused to touch")
	end)

end)





-- ===========================================
-- ===========================================
-- ======= 2/ Healthy Saves Unaffected =======
-- ===========================================
-- ===========================================

helpers.describe("Config.save_user_config — normal saves are untouched", function()

	helpers.it("writes the config when the file does not exist yet (first launch)", function()
		local path = os.tmpname()
		os.remove(path)  -- os.tmpname creates the file on some builds

		local saved = Config.save_user_config(make_state(), path)
		local written = read_file(path)
		cleanup(path)

		helpers.assert_eq(saved, true, "a first-launch save must succeed")
		helpers.assert_true(written ~= nil and written:find("[tap_holds", 1, true) ~= nil,
			"the encoded TOML must land on disk on first launch")
	end)

	helpers.it("still rewrites a config that decodes cleanly", function()
		local path = os.tmpname()
		local valid = "[karabiner]\nenabled = false\n"
		write_file(path, valid)

		local logged = with_captured_errors(function()
			Config.save_user_config(make_state(), path)
		end)
		local payload = produced_payload(path, valid)
		cleanup(path)

		helpers.assert_true(payload ~= nil,
			"a valid config must still be re-encoded and written — the guard must not block healthy saves")
		helpers.assert_true(payload:find("enabled = true", 1, true) ~= nil,
			"the produced payload must carry the new state: got " .. helpers.inspect(payload))
		helpers.assert_true(logged:find("Refusing to overwrite") == nil,
			"a decodable config must never trigger the corruption refusal")
	end)

	helpers.it("lets an explicit reset rebuild a corrupt file", function()
		local path = os.tmpname()
		write_file(path, CORRUPT_TOML)

		-- Third argument = the reset-to-defaults escape hatch. Without it a user
		-- whose file went bad could never repair it from the UI.
		Config.save_user_config(make_state(), path, true)
		local payload = produced_payload(path, CORRUPT_TOML)
		cleanup(path)

		helpers.assert_true(payload ~= nil,
			"the explicit reset must be allowed to overwrite an unparseable config")
		helpers.assert_true(payload:find("enabled = true", 1, true) ~= nil,
			"the reset must publish the supplied state, not the corrupt bytes")
	end)

end)





-- ===============================================
-- ===============================================
-- ======= 3/ No Setter Bypasses The Guard =======
-- ===============================================
-- ===============================================

--- Splits a call's argument list on top-level commas so nested calls such as
--- `resolve_user_config()` do not inflate the count.
--- @param args string The `(...)` slice of a call, parentheses included.
--- @return number Number of top-level arguments.
local function count_arguments(args)
	local inner = args:sub(2, -2)
	if inner:match("^%s*$") then return 0 end
	local depth, count = 0, 1
	for i = 1, #inner do
		local c = inner:sub(i, i)
		if c == "(" or c == "{" or c == "[" then
			depth = depth + 1
		elseif c == ")" or c == "}" or c == "]" then
			depth = depth - 1
		elseif c == "," and depth == 0 then
			count = count + 1
		end
	end
	return count
end

helpers.describe("karabiner setters — only the reset bypasses the corruption guard", function()

	-- Whole-driver scan rather than a pinned path: a call site that moves out of
	-- platform/remap/init.lua, or a new caller in a menu module, is picked up
	-- automatically instead of silently escaping the guard.
	local src = helpers.read_driver_source("Config.save_user_config")

	helpers.it("driver source carrying the persistence calls is readable (precondition)", function()
		helpers.assert_true(src ~= nil, "no production file calls Config.save_user_config — scan symbol has drifted")
	end)

	if not src then return end

	-- Derived from source, so a setter added tomorrow is checked automatically.
	local total, bypassing = 0, {}
	for pos, args in src:gmatch("()Config%.save_user_config(%b())") do
		total = total + 1
		if count_arguments(args) >= 3 then
			-- Attribute the call to the nearest enclosing `function M.<name>`.
			local owner = "<file scope>"
			for name_pos, name in src:gmatch("()function M%.([%w_]+)") do
				if name_pos < pos then owner = name else break end
			end
			bypassing[#bypassing + 1] = owner
		end
	end

	helpers.it("scans every persistence call site", function()
		helpers.assert_true(total >= 10,
			"expected the full set of Config.save_user_config() call sites, found " .. total ..
			" — the scan pattern has drifted and the guard below would be vacuous")
	end)

	helpers.it("only reset_to_defaults passes the overwrite_corrupt flag", function()
		for _, owner in ipairs(bypassing) do
			helpers.assert_eq(owner, "reset_to_defaults",
				"'" .. owner .. "' passes overwrite_corrupt to save_user_config — every setter " ..
				"except the explicit reset must refuse to clobber an unparseable config")
		end
		helpers.assert_eq(#bypassing, 1,
			"exactly one call site (reset_to_defaults) may bypass the guard, found " .. #bypassing)
	end)

end)
