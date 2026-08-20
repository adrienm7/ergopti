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
	local fixture_io = require("tests.support.file_system_write_stub")
	package.loaded["adapters.file_system"] = {
		read_with_status = fixture_io.read_with_status,
		write_if_unchanged = function() return write_result end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	mod.init({ override_path = path, toml_resolver = function() return nil end })
	return mod
end

--- Runs init against one explicit adapter read result.
--- @param path string Override path.
--- @param status string Adapter status.
--- @param detail string Failure detail.
--- @return boolean ok
--- @return table|string result
--- @return table calls
local function init_with_read_status(path, status, detail)
	local calls = { reads = 0, writes = 0 }
	package.loaded["adapters.file_system"] = {
		read_with_status = function(candidate)
			helpers.assert_eq(candidate, path)
			calls.reads = calls.reads + 1
			if status == "ok" then return SENTINEL, "ok" end
			return nil, status, detail
		end,
		write_if_unchanged = function()
			calls.writes = calls.writes + 1
			return true
		end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local ok, result = pcall(function()
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		local initialized = mod.init({ override_path = path, toml_resolver = function() return nil end })
		return { module = mod, initialized = initialized }
	end)
	return ok, result, calls
end





-- ======================================================
-- ======================================================
-- ======= 1/ Failed Reads Block Every Later Save =======
-- ======================================================
-- ======================================================

helpers.describe("hotstrings config: failed source reads stay fail-closed", function()
	for _, case in ipairs({
		{ label = "EACCES", detail = "permission denied" },
		{ label = "mid-read failure", detail = "input/output error" },
		{ label = "failed close", detail = "close failed" },
		{ label = "dangling symlink", detail = "dangling symlink target" },
		{ label = "directory", detail = "expected a regular file, got directory" },
	}) do
		helpers.it(case.label .. " preserves the source and rejects every later setter", function()
			local path = fixture_path(case.label:gsub("[^%w]", "_"))
			local ok, result, calls = init_with_read_status(path, "error", case.detail)
			helpers.assert_true(ok, case.label .. " must degrade safely instead of throwing")
			helpers.assert_eq(result.initialized, false,
				"an uncommitted source must be visible to the caller")

			local mod = result.module
			helpers.assert_eq(mod.set_override("abbrevs", nil, "delay", 0.7), false,
				"an unread source must never become a writable empty configuration")
			helpers.assert_eq(mod.clear_override("missing", nil, "delay"), false,
				"even a logical no-op must stay blocked after an unsafe read")
			helpers.assert_nil(mod.get_user_override("abbrevs", nil),
				"the rejected candidate must not leak into memory")
			helpers.assert_eq(calls.reads, 1,
				"initialization must consume exactly one classified adapter snapshot")
			helpers.assert_eq(calls.writes, 0,
				"an unsafe source classification must never reach publication")
			helpers.assert_eq(read_fixture(path), SENTINEL,
				"the user's pre-existing group must survive the unsafe source")
			os.remove(path)
		end)
	end

	helpers.it("a dangling symlink discovered by reload retains prior memory and blocks writes", function()
		local path = fixture_path("reload_dangling")
		local phase = "ok"
		local calls = { writes = 0 }
		package.loaded["adapters.file_system"] = {
			read_with_status = function()
				if phase == "ok" then return SENTINEL, "ok" end
				return nil, "error", "dangling symlink target"
			end,
			write_if_unchanged = function() calls.writes = calls.writes + 1 return true end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		helpers.assert_eq(mod.init({ override_path = path, toml_resolver = function() return nil end }), true)
		helpers.assert_eq(mod.get_user_override("rolls", nil).delay, 0.33)

		phase = "retargeted"
		helpers.assert_eq(mod.reload(), false)
		helpers.assert_eq(mod.get_user_override("rolls", nil).delay, 0.33,
			"a failed revalidation must retain the last committed in-memory snapshot")
		helpers.assert_eq(mod.set_override("rolls", nil, "delay", 0.7), false)
		helpers.assert_eq(calls.writes, 0)
		helpers.assert_eq(read_fixture(path), SENTINEL)
		os.remove(path)
	end)

	helpers.it("a proven-absent override source remains writable", function()
		local path = os.tmpname() .. "_absent.toml"
		os.remove(path)
		local writes = 0
		package.loaded["adapters.file_system"] = {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				return nil, "absent", "not found"
			end,
			write_if_unchanged = function(candidate, content, expected_source)
				helpers.assert_eq(candidate, path)
				helpers.assert_contains(content, "[rolls]")
				helpers.assert_eq(expected_source.status, "absent")
				writes = writes + 1
				return true
			end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")

		helpers.assert_eq(mod.init({ override_path = path, toml_resolver = function() return nil end }), true)
		helpers.assert_eq(mod.set_override("rolls", nil, "delay", 0.7), true)
		helpers.assert_eq(mod.get_user_override("rolls", nil).delay, 0.7)
		helpers.assert_eq(writes, 1,
			"only a positively classified absence may start a new override file")
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

	helpers.it("a symlink retarget between committed read and write publishes no candidate", function()
		local path = fixture_path("retarget")
		local events = {}
		package.loaded["adapters.file_system"] = {
			read_with_status = function(candidate)
				helpers.assert_eq(candidate, path)
				events[#events + 1] = "read"
				return SENTINEL, "ok"
			end,
			write_if_unchanged = function(candidate)
				helpers.assert_eq(candidate, path)
				events[#events + 1] = "retarget-refused"
				return false
			end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		helpers.assert_eq(mod.init({ override_path = path, toml_resolver = function() return nil end }), true)
		local before = mod.resolve("rolls", nil)

		helpers.assert_eq(mod.set_override("rolls", nil, "delay", 0.7), false)
		helpers.assert_eq(events[1], "read")
		helpers.assert_eq(events[2], "retarget-refused",
			"publication must remain delegated to the symlink-revalidating adapter")
		helpers.assert_eq(events[3], "read",
			"a failed publication must revalidate whether the committed source changed")
		helpers.assert_eq(#events, 3)
		helpers.assert_eq(mod.get_user_override("rolls", nil).delay, 0.33)
		helpers.assert_eq(mod.resolve("rolls", nil), before,
			"the last committed memo must survive a TOCTOU refusal")
		helpers.assert_eq(read_fixture(path), SENTINEL)
		os.remove(path)
	end)

	helpers.it("an external edit wins instead of being overwritten by a stale in-memory candidate", function()
		local path = fixture_path("external_edit")
		local external = "[rolls]\ndelay = 0.91\n\n[abbrevs]\ncolor = \"#123456\"\n"
		local snapshots = {}
		local fixture_io = require("tests.support.file_system_write_stub")
		package.loaded["adapters.file_system"] = {
			read_with_status = fixture_io.read_with_status,
			write_if_unchanged = function(candidate, content, expected_source)
				helpers.assert_eq(candidate, path)
				snapshots[#snapshots + 1] = expected_source
				local current, status = fixture_io.read_with_status(candidate)
				if status ~= expected_source.status
					or (status == "ok" and current ~= expected_source.content) then
					return false, "source changed"
				end
				return fixture_io.write(candidate, content)
			end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		helpers.assert_eq(mod.init({ override_path = path, toml_resolver = function() return nil end }), true)

		helpers.assert_eq(fixture_io.write(path, external), true,
			"the competing driver must publish its complete version before the setter")
		helpers.assert_eq(mod.set_override("rolls", nil, "delay", 0.7), false,
			"a candidate derived from the old source must lose the compare-and-publish race")
		helpers.assert_eq(read_fixture(path), external,
			"the exact external version must survive the rejected stale candidate")
		helpers.assert_eq(#snapshots, 1)
		helpers.assert_eq(snapshots[1].status, "ok")
		helpers.assert_eq(snapshots[1].content, SENTINEL,
			"publication must compare against the exact bytes used to build memory")
		helpers.assert_eq(mod.get_user_override("rolls", nil).delay, 0.91,
			"a proven conflict must adopt the external committed version in memory")
		helpers.assert_eq(mod.get_user_override("abbrevs", nil).color, "#123456")
		os.remove(path)
	end)

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
