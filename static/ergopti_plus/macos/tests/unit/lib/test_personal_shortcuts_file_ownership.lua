--- tests/unit/lib/test_personal_shortcuts_file_ownership.lua

--- ============================================================================
--- MODULE: Personal Shortcuts File-Ownership Regression
--- DESCRIPTION:
--- Drives the real personal-shortcuts loader and editor entry point through the
--- canonical FileSystem status contract. An unreadable path, dangling link, or
--- failed create-only publication must never authorize a template write, dofile,
--- or editor launch; a concurrent readable winner remains an idempotent success.
--- ============================================================================

local helpers = require("tests.helpers")

local PERSONAL_PATH = "/controlled/personal_shortcuts.lua"

local function logger_stub()
	local noop = function() end
	return {
		trace = noop, debug = noop, info = noop, done = noop,
		start = noop, success = noop, warn = noop, error = noop,
	}
end

local function load_module(file_system, observations)
	local hs_stub = require("tests.stubs.hs")
	hs_stub.timer.doAfter = function(_, callback)
		observations.timers = observations.timers + 1
		callback()
		return { stop = function() end }
	end
	hs_stub.execute = function()
		observations.executes = observations.executes + 1
		return "", true, "exit", 0
	end
	_G.hs = hs_stub
	package.loaded["adapters.file_system"] = file_system
	package.loaded["infra.config_paths"] = {
		get = function(key)
			helpers.assert_eq(key, "PersonalShortcutsLuaPath")
			return PERSONAL_PATH
		end,
	}
	package.loaded["infra.logger"] = logger_stub()
	package.loaded["infra.text_utils"] = {
		shell_quote = function(value) return "'" .. tostring(value) .. "'" end,
	}
	package.loaded["infra.personal_shortcuts"] = nil
	return require("infra.personal_shortcuts")
end

local function with_runtime(file_system, body)
	local original_open = io.open
	local original_dofile = dofile
	local observations = {
		raw_opens = 0,
		dofiles = 0,
		timers = 0,
		executes = 0,
		creates = 0,
	}
	io.open = function()
		observations.raw_opens = observations.raw_opens + 1
		return nil, "raw io.open must not own this path", 13
	end
	_G.dofile = function(path)
		observations.dofiles = observations.dofiles + 1
		helpers.assert_eq(path, PERSONAL_PATH)
		return true
	end
	local ok, err = xpcall(function()
		body(load_module(file_system, observations), observations)
	end, debug.traceback)
	io.open = original_open
	_G.dofile = original_dofile
	package.loaded["infra.personal_shortcuts"] = nil
	package.loaded["adapters.file_system"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("personal shortcuts: exact file ownership", function()
	helpers.it("unreadable and dangling paths authorize no side effect", function()
		for _, detail in ipairs({ "Permission denied", "dangling symlink", "path is a directory" }) do
			local fs = {
				read_with_status = function(path)
					helpers.assert_eq(path, PERSONAL_PATH)
					return nil, "error", detail
				end,
				create_if_absent = function()
					error("create_if_absent must not run after an ownership error", 0)
				end,
			}
			with_runtime(fs, function(personal, seen)
				helpers.assert_eq(personal.load(), false)
				helpers.assert_eq(personal.open(), false)
				helpers.assert_eq(seen.raw_opens, 0)
				helpers.assert_eq(seen.dofiles, 0)
				helpers.assert_eq(seen.timers, 0)
				helpers.assert_eq(seen.executes, 0)
			end)
		end
	end)

	helpers.it("a failed create-only transaction loads and launches nothing", function()
		local fs = {
			read_with_status = function() return nil, "absent" end,
			create_if_absent = function()
				return false, "error", "concurrent path is not readable"
			end,
		}
		with_runtime(fs, function(personal, seen)
			helpers.assert_eq(personal.load(), false)
			helpers.assert_eq(personal.open(), false)
			helpers.assert_eq(seen.dofiles, 0)
			helpers.assert_eq(seen.timers, 0)
		end)
	end)

	helpers.it("a concurrent readable winner is an idempotent success", function()
		local fs = {
			read_with_status = function() return nil, "absent" end,
			create_if_absent = function(path, content)
				helpers.assert_eq(path, PERSONAL_PATH)
				helpers.assert_true(type(content) == "string" and content:find("personal_shortcuts.lua", 1, true) ~= nil)
				return false, "exists"
			end,
		}
		with_runtime(fs, function(personal, seen)
			helpers.assert_eq(personal.load(), true)
			helpers.assert_eq(seen.dofiles, 1)
			helpers.assert_eq(personal.open(), true)
			helpers.assert_eq(seen.timers, 1)
			helpers.assert_eq(seen.executes, 1)
		end)
	end)
end)
