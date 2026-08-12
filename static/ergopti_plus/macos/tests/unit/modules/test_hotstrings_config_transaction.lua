--- tests/unit/modules/test_hotstrings_config_transaction.lua

--- ==============================================================================
--- MODULE: Hotstrings Override Transaction Regression Tests
--- DESCRIPTION:
--- Proves that an unreadable override file never becomes a writable empty
--- configuration and that every setter publishes memory only after the atomic
--- file-system adapter confirms the complete write transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

local SENTINEL = "[rolls]\ndelay = 0.33\n"

--- Returns a unique override path containing the user's pre-existing data.
--- @param suffix string Test discriminator.
--- @return string path
local function fixture_path(suffix)
	local path = os.tmpname() .. "_" .. suffix .. ".toml"
	local fh = assert(io.open(path, "w"))
	assert(fh:write(SENTINEL))
	assert(fh:close())
	return path
end

--- Reads a fixture after restoring the real I/O implementation.
--- @param path string Fixture path.
--- @return string content
local function read_fixture(path)
	local fh = assert(io.open(path, "r"))
	local content = assert(fh:read("*a"))
	assert(fh:close())
	return content
end

--- Loads a fresh config module with an injected atomic-writer result.
--- @param path string Override path.
--- @param write_result boolean Result returned by the file-system adapter.
--- @return table module
local function fresh_module(path, write_result)
	package.loaded["adapters.file_system"] = {
		write = function() return write_result end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	mod.init({ override_path = path, toml_resolver = function() return nil end })
	return mod
end

--- Runs init while replacing only the target file's read handle.
--- @param path string Override path.
--- @param open_target function Target-path io.open implementation.
--- @return boolean ok
--- @return table|string module_or_error
local function init_with_open_override(path, open_target)
	local original_open = io.open
	io.open = function(candidate, mode)
		if candidate == path and mode == "r" then return open_target() end
		return original_open(candidate, mode)
	end
	package.loaded["adapters.file_system"] = { write = function() return true end }
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local ok, result = pcall(function()
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		mod.init({ override_path = path, toml_resolver = function() return nil end })
		return mod
	end)
	io.open = original_open
	return ok, result
end

--- Creates a handle that can be read but whose exact close result fails.
--- @return table handle
local function close_failure_handle()
	local lines = { "[rolls]", "delay = 0.33" }
	return {
		read = function() return SENTINEL end,
		lines = function()
			local index = 0
			return function()
				index = index + 1
				return lines[index]
			end
		end,
		close = function() return false, "close failed" end,
	}
end





-- ======================================================
-- ======================================================
-- ======= 1/ Failed Reads Block Every Later Save =======
-- ======================================================
-- ======================================================

helpers.describe("hotstrings config: failed source reads stay fail-closed", function()
	helpers.it("EACCES preserves the existing group and rejects a later setter", function()
		local path = fixture_path("eacces")
		local ok, mod = init_with_open_override(path, function()
			return nil, "permission denied", 13
		end)
		helpers.assert_true(ok, "an EACCES read must degrade safely instead of throwing")

		helpers.assert_eq(mod.set_override("abbrevs", nil, "delay", 0.7), false,
			"an unread source must never become a writable empty configuration")
		helpers.assert_eq(mod.clear_override("missing", nil, "delay"), false,
			"even a logical no-op must not report a writable state after EACCES")
		helpers.assert_nil(mod.get_user_override("abbrevs", nil),
			"the rejected candidate must not leak into memory")
		helpers.assert_eq(read_fixture(path), SENTINEL,
			"the user's pre-existing rolls group must survive the transient lock")
		os.remove(path)
	end)

	helpers.it("a mid-read failure is contained and leaves the source write-blocked", function()
		local path = fixture_path("read")
		local ok, mod = init_with_open_override(path, function()
			return {
				read = function() return nil, "input/output error", 5 end,
				lines = function()
					return function() error("input/output error") end
				end,
				close = function() return true end,
			}
		end)
		helpers.assert_true(ok, "a file iterator/read failure must not escape init")
		helpers.assert_eq(mod.set_override("abbrevs", nil, "delay", 0.7), false)
		helpers.assert_eq(read_fixture(path), SENTINEL)
		os.remove(path)
	end)

	helpers.it("a failed close withholds the parsed candidate and blocks writes", function()
		local path = fixture_path("close")
		local ok, mod = init_with_open_override(path, close_failure_handle)
		helpers.assert_true(ok, "a close failure must be reported as a failed read transaction")
		helpers.assert_eq(mod.set_override("abbrevs", nil, "delay", 0.7), false)
		helpers.assert_nil(mod.get_user_override("rolls", nil),
			"bytes are not committed input until close succeeds")
		helpers.assert_eq(read_fixture(path), SENTINEL)
		os.remove(path)
	end)
end)





-- ======================================================
-- ======================================================
-- ======= 2/ Failed Writes Publish No Candidate ========
-- ======================================================
-- ======================================================

helpers.describe("hotstrings config: setters publish only after atomic commit", function()
	for _, failure in ipairs({ "write=nil", "close=false", "rename=false" }) do
		helpers.it(failure .. " preserves disk, memory, and the resolve cache", function()
			local path = fixture_path(failure:gsub("[^%w]", "_"))
			local mod = fresh_module(path, false)
			local before = mod.resolve("rolls", nil)

			helpers.assert_eq(mod.set_override("rolls", nil, "delay", 0.7), false,
				"the setter must propagate the failed atomic transaction")
			helpers.assert_eq(mod.get_user_override("rolls", nil).delay, 0.33,
				"failed publication must leave the loaded state unchanged")
			helpers.assert_eq(mod.resolve("rolls", nil), before,
				"failed publication must not invalidate or replace the committed memo")
			helpers.assert_eq(read_fixture(path), SENTINEL)
			os.remove(path)
		end)
	end

	helpers.it("clear_override rolls back when publication fails", function()
		local path = fixture_path("clear")
		local mod = fresh_module(path, false)
		helpers.assert_eq(mod.clear_override("rolls", nil, "delay"), false)
		helpers.assert_eq(mod.get_user_override("rolls", nil).delay, 0.33)
		helpers.assert_eq(read_fixture(path), SENTINEL)
		os.remove(path)
	end)

	helpers.it("set_word_delimiters rolls back when publication fails", function()
		local path = fixture_path("delimiters")
		local original_open = io.open
		local fh = assert(original_open(path, "w"))
		assert(fh:write('[__global__]\nword_delimiters = " ,"\n\n' .. SENTINEL))
		assert(fh:close())
		local original_content = read_fixture(path)
		local mod = fresh_module(path, false)

		helpers.assert_eq(mod.set_word_delimiters(" ;"), false)
		helpers.assert_eq(mod.get_word_delimiters(), " ,",
			"the runtime delimiter set must change only after durable publication")
		helpers.assert_eq(read_fixture(path), original_content)
		os.remove(path)
	end)

	helpers.it("word delimiters with control characters commit and round-trip", function()
		local path = fixture_path("delimiter_roundtrip")
		package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		mod.init({ override_path = path, toml_resolver = function() return nil end })
		local delimiters = " \t\r\n,"

		helpers.assert_eq(mod.set_word_delimiters(delimiters), true)
		helpers.assert_contains(read_fixture(path), 'word_delimiters = " \\t\\r\\n,"',
			"control bytes must stay escaped inside one TOML basic string")
		helpers.assert_eq(mod.reload(), true)
		helpers.assert_eq(mod.get_word_delimiters(), delimiters)
		os.remove(path)
	end)
end)
