--- tests/unit/modules/keylogger/test_device_identity_fail_closed.lua

--- ==============================================================================
--- MODULE: Keylogger Device Identity Fail-Closed Tests
--- DESCRIPTION:
--- Drives the real log-manager initialization against an existing device entry
--- whose `device.json` cannot be owned. A read or decode failure must stop
--- initialization before UUID generation, persistence, or subordinate storage
--- modules can split one physical Mac across two identities.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================
-- ======================================
-- ======= 1/ Transaction Harness =======
-- ======================================
-- ======================================

local HOST_SIGNATURE = "TEST-HOST-DEVICE-IDENTITY"
local DEVICE_PATH_SUFFIX = "/by_device/existing-device/device.json"

local STUBBED_MODULES = {
	"modules.keylogger.sqlite_writer",
	"modules.keylogger.aggregator",
	"modules.keylogger.rotation",
	"modules.keylogger.export",
	"keylogger.metrics",
}

local function make_state()
	return {
		LOG_DIR               = "/virtual/metrics",
		buffer_events         = {},
		buffer_text           = "",
		rich_chunks           = {},
		session_mouse_clicks  = 0,
		session_mouse_scrolls = 0,
		mouse_distance_px     = 0,
		last_flush_time       = 0,
		last_time             = 0,
		pending_keyup         = {},
		today_idx             = {},
		manifest              = {},
	}
end

local function fake_writer()
	return {
		write = function(self) return self end,
		flush = function() return true end,
		close = function() return true end,
	}
end

local function run_unowned_case(failure)
	local saved_modules = {}
	for _, name in ipairs(STUBBED_MODULES) do
		saved_modules[name] = package.loaded[name]
	end

	local calls = {
		uuid_random = 0,
		write_open = 0,
		sqlite_init = 0,
		aggregator_init = 0,
		export_init = 0,
		rotation_init = 0,
		timer_new = 0,
	}

	package.loaded["modules.keylogger.sqlite_writer"] = {
		init = function() calls.sqlite_init = calls.sqlite_init + 1 end,
		open_db = function() return false end,
		close_db = function() end,
		get_db = function() return nil end,
	}
	package.loaded["modules.keylogger.aggregator"] = {
		init = function() calls.aggregator_init = calls.aggregator_init + 1 end,
	}
	package.loaded["modules.keylogger.rotation"] = {
		init = function() calls.rotation_init = calls.rotation_init + 1 end,
		is_initialized = function() return false end,
		read_new_entries = function() return {}, 0 end,
	}
	package.loaded["modules.keylogger.export"] = {
		init = function() calls.export_init = calls.export_init + 1 end,
	}
	package.loaded["keylogger.metrics"] = {}

	local timer_handle = {
		start = function() end,
		stop = function() end,
	}
	local module = helpers.load_with_stubs("modules.keylogger.log_manager", {
		execute = function(command)
			if command:find("ioreg", 1, true) then return HOST_SIGNATURE end
			return ""
		end,
		fs = {
			attributes = function(path)
				if path:sub(-#"/by_device/existing-device") == "/by_device/existing-device" then
					return "directory"
				end
				return nil
			end,
			dir = function()
				local entries = { ".", "..", "existing-device" }
				local index = 0
				return function()
					index = index + 1
					return entries[index]
				end
			end,
		},
		timer = {
			absoluteTime = function() return 1000000 end,
			new = function()
				calls.timer_new = calls.timer_new + 1
				return timer_handle
			end,
		},
	})

	local real_open = io.open
	local real_random = math.random
	local real_randomseed = math.randomseed
	local ok, failure_detail = xpcall(function()
		io.open = function(path, mode)
			if mode == "r" and path:sub(-#DEVICE_PATH_SUFFIX) == DEVICE_PATH_SUFFIX then
				if failure == "unreadable" then
					return nil, "permission denied", 13
				end
				return {
					read = function() return "{broken-device-json" end,
					close = function() return true end,
				}
			end
			if mode == "w" then
				calls.write_open = calls.write_open + 1
				return fake_writer()
			end
			return real_open(path, mode)
		end
		math.randomseed = function() end
		math.random = function(lower)
			calls.uuid_random = calls.uuid_random + 1
			if lower == nil then return 0.5 end
			return lower
		end

		local initialized = module.init(make_state())
		helpers.assert_eq(calls.uuid_random, 0,
			"read/decode failure must stop before a replacement UUID is generated")
		helpers.assert_eq(calls.write_open, 0,
			"failed ownership must publish neither device.json nor sibling ledgers")
		helpers.assert_eq(calls.sqlite_init, 0,
			"SQLite must not bind to an identity selected after a failed read")
		helpers.assert_eq(calls.aggregator_init, 0,
			"aggregates must not bind to an identity selected after a failed read")
		helpers.assert_eq(calls.export_init, 0,
			"exports must not bind to an identity selected after a failed read")
		helpers.assert_eq(calls.rotation_init, 0,
			"rotation must not bind to an identity selected after a failed read")
		helpers.assert_eq(calls.timer_new, 0,
			"a failed identity handshake must not leave an ingest timer alive")
		helpers.assert_eq(initialized, false,
			"an unowned existing identity must make initialization fail closed")
	end, debug.traceback)

	io.open = real_open
	math.random = real_random
	math.randomseed = real_randomseed
	for _, name in ipairs(STUBBED_MODULES) do
		package.loaded[name] = saved_modules[name]
	end
	package.loaded["modules.keylogger.log_manager"] = nil
	if not ok then error(failure_detail, 0) end
end





-- ==============================================
-- ==============================================
-- ======= 2/ Existing Identity Ownership =======
-- ==============================================
-- ==============================================

helpers.describe("log_manager device identity ownership", function()
	helpers.it("does not replace an unreadable device.json", function()
		run_unowned_case("unreadable")
	end)

	helpers.it("does not replace a corrupt device.json", function()
		run_unowned_case("corrupt")
	end)
end)
