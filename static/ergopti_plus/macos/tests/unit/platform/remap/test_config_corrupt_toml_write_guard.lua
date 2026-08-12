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

local FileSystem = require("adapters.file_system")
local Config = helpers.load_with_stubs("platform.remap.config")
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

	helpers.it("refuses unreadable existing config and failed staging commits", function()
		local path = os.tmpname()
		local original = "[karabiner]\nenabled = false\n"
		write_file(path, original)
		local original_open = io.open
		local original_write = FileSystem.write
		local publications = 0

		io.open = function(candidate, mode)
			if candidate == path and mode == "r" then return nil, "PRIVATE-READ-FAILURE", 13 end
			return original_open(candidate, mode)
		end
		FileSystem.write = function() publications = publications + 1; return true end
		local unreadable_result = Config.save_user_config(make_state(), path)
		io.open = original_open
		FileSystem.write = original_write
		helpers.assert_eq(unreadable_result, false,
			"an unreadable existing config must reject the save transaction")
		helpers.assert_eq(publications, 0, "an unreadable source must authorize no publication")
		helpers.assert_eq(read_file(path), original, "read refusal must preserve exact committed bytes")

		-- The first fixture mocked io.open, but the classifier is intentionally
		-- stricter than raw stream access and may cache no conclusion from it.
		-- Use a classified adapter snapshot for the publication-refusal half.
		local original_read = FileSystem.read_with_status
		local reads = 0
		FileSystem.read_with_status = function(candidate)
			reads = reads + 1
			return original, "ok"
		end
		FileSystem.write = function(_, _, expected_source)
			publications = publications + 1
			if type(expected_source) ~= "table"
					or expected_source.status ~= "ok"
					or expected_source.content ~= original then
				return false
			end
			return false
		end
		local write_result = Config.save_user_config(make_state(), path)
		FileSystem.read_with_status = original_read
		FileSystem.write = original_write
		helpers.assert_eq(write_result, false, "a refused staging write must reject the save")
		helpers.assert_eq(reads, 1, "save must take one classified source snapshot")
		helpers.assert_eq(publications, 1,
			"the classified source may reach exactly one atomic adapter publication attempt")
		helpers.assert_eq(read_file(path), original, "failed staging must preserve committed bytes")
		cleanup(path)
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

		local payload
		local write_assertion
		local original_write = FileSystem.write
		FileSystem.write = function(candidate, content, expected_source)
			write_assertion = candidate == path
				and type(expected_source) == "table"
				and expected_source.status == "absent"
				and expected_source.content == nil
			payload = content
			return true
		end
		local saved = Config.save_user_config(make_state(), path)
		FileSystem.write = original_write
		cleanup(path)

		helpers.assert_eq(saved, true, "a first-launch save must succeed")
		helpers.assert_true(write_assertion,
			"first-launch publication must carry a proven-absent source precondition")
		helpers.assert_true(payload ~= nil and payload:find("[tap_holds", 1, true) ~= nil,
			"the encoded TOML must reach the atomic adapter on first launch")
	end)

	helpers.it("still rewrites a config that decodes cleanly", function()
		local path = os.tmpname()
		local valid = "[karabiner]\nenabled = false\n"
		write_file(path, valid)

		local payload
		local write_assertion
		local original_read = FileSystem.read_with_status
		local reads = 0
		local original_write = FileSystem.write
		FileSystem.read_with_status = function(candidate)
			reads = reads + 1
			return valid, "ok"
		end
		FileSystem.write = function(candidate, content, expected_source)
			write_assertion = candidate == path
				and type(expected_source) == "table"
				and expected_source.status == "ok"
				and expected_source.content == valid
			payload = content
			return true
		end
		local saved
		local logged = with_captured_errors(function()
			saved = Config.save_user_config(make_state(), path)
		end)
		FileSystem.read_with_status = original_read
		FileSystem.write = original_write
		cleanup(path)

		helpers.assert_eq(saved, true)
		helpers.assert_eq(reads, 1, "save must take one classified source snapshot")
		helpers.assert_true(write_assertion,
			"the writer must revalidate the exact classified bytes before publication")
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
		local payload
		local write_assertion
		local original_write = FileSystem.write
		FileSystem.write = function(candidate, content, expected_source)
			write_assertion = candidate == path
				and (expected_source == nil or expected_source == false)
			payload = content
			return true
		end
		local saved = Config.save_user_config(make_state(), path, true)
		FileSystem.write = original_write
		cleanup(path)

		helpers.assert_eq(saved, true)
		helpers.assert_true(write_assertion,
			"the explicit reset intentionally discards the corrupt source snapshot")
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

	helpers.it("keeps direct persistence outside the setter transaction helper bounded", function()
		helpers.assert_eq(total, 2,
			"only boot migration and first-launch publication may call the writer directly")
	end)

	helpers.it("routes the reset-only bypass through the transactional helper", function()
		helpers.assert_eq(#bypassing, 0,
			"no direct writer call may bypass classified-source protection")
		local reset_at = src:find("function M.reset_to_defaults", 1, true)
		local reset_end = reset_at and src:find("\nend", reset_at, true)
		local reset_body = reset_at and src:sub(reset_at, reset_end) or ""
		helpers.assert_true(reset_body:find("end, true", 1, true) ~= nil,
			"only reset_to_defaults may pass overwrite_corrupt=true into commit_state_mutation")
	end)

end)
