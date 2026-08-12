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
	"adapters.file_system",
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

local function run_unowned_case(failure)
	local saved_modules = {}
	for _, name in ipairs(STUBBED_MODULES) do
		saved_modules[name] = package.loaded[name]
	end

	local calls = {
		classified_reads = 0,
		raw_identity_reads = 0,
		uuid_random = 0,
		publication_calls = 0,
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
	package.loaded["adapters.file_system"] = {
		read_with_status = function(path)
			helpers.assert_true(path:sub(-#DEVICE_PATH_SUFFIX) == DEVICE_PATH_SUFFIX,
				"the classified read must inspect the enumerated device identity")
			calls.classified_reads = calls.classified_reads + 1
			if failure == "corrupt" then return "{broken-device-json", "ok" end
			return nil, "error", failure
		end,
		write = function()
			calls.publication_calls = calls.publication_calls + 1
			return true
		end,
	}

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
				calls.raw_identity_reads = calls.raw_identity_reads + 1
				if failure == "unreadable" then
					return nil, "permission denied", 13
				end
				if failure == "dangling" then
					return nil, "No such file or directory", 2
				end
				if failure == "directory" then
					return nil, "Is a directory", 21
				end
				return {
					read = function() return "{broken-device-json" end,
					close = function() return true end,
				}
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
		helpers.assert_eq(calls.classified_reads, 1,
			"identity ownership must use the adapter's classified read boundary")
		helpers.assert_eq(calls.raw_identity_reads, 0,
			"identity ownership must not infer absence from raw io.open errno values")
		helpers.assert_eq(calls.uuid_random, 0,
			"read/decode failure must stop before a replacement UUID is generated")
		helpers.assert_eq(calls.publication_calls, 0,
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

local function run_publication_case(failure)
	local saved_modules = {}
	for _, name in ipairs(STUBBED_MODULES) do
		saved_modules[name] = package.loaded[name]
	end

	local calls = {
		classified_reads = 0,
		removes = 0,
		publication_calls = 0,
		sqlite_init = 0,
		aggregator_init = 0,
		export_init = 0,
		rotation_init = 0,
		rotation_appends = 0,
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
		append_log = function() calls.rotation_appends = calls.rotation_appends + 1 end,
		read_new_entries = function() return {}, 0, "eof" end,
	}
	package.loaded["modules.keylogger.export"] = {
		init = function() calls.export_init = calls.export_init + 1 end,
		get_device_short_id = function() return "" end,
		get_sqlite_path = function() return "" end,
	}
	package.loaded["keylogger.metrics"] = {}
	package.loaded["adapters.file_system"] = {
		read_with_status = function(path)
			helpers.assert_true(path:sub(-#DEVICE_PATH_SUFFIX) == DEVICE_PATH_SUFFIX,
				"the candidate device.json must cross the classified read boundary")
			calls.classified_reads = calls.classified_reads + 1
			return nil, "absent"
		end,
		write = function()
			calls.publication_calls = calls.publication_calls + 1
			return failure == nil
		end,
	}

	local module = helpers.load_with_stubs("modules.keylogger.log_manager", {
		execute = function(command)
			if command:find("ioreg", 1, true) then return HOST_SIGNATURE end
			return ""
		end,
		fs = {
			attributes = function() return nil end,
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
				return { start = function() end, stop = function() end }
			end,
		},
	})

	local ok, failure_detail = xpcall(function()
		local initialized = module.init(make_state())
		module.log_shortcut("cmd+c", "Finder")
		helpers.assert_eq(calls.classified_reads, 1,
			"only the adapter's proven-absent status may authorize a new identity")
		if failure then
			helpers.assert_eq(initialized, false,
				"identity publication failure must make initialization fail closed")
			helpers.assert_eq(calls.sqlite_init, 0,
				"SQLite must not receive an identity that was never published")
			helpers.assert_eq(calls.aggregator_init, 0,
				"aggregates must not receive an identity that was never published")
			helpers.assert_eq(calls.export_init, 0,
				"exports must not expose an identity that was never published")
			helpers.assert_eq(calls.rotation_init, 0,
				"rotation must not receive an identity that was never published")
			helpers.assert_eq(calls.timer_new, 0,
				"failed publication must not leave an ingest timer alive")
			helpers.assert_eq(calls.rotation_appends, 0,
				"failed publication must leave public log actions behind _require_state")
		else
			helpers.assert_eq(initialized, true,
				"a fully published new identity must complete initialization")
			helpers.assert_eq(calls.publication_calls, 1,
				"a successful new identity must cross one atomic publication boundary")
			helpers.assert_eq(calls.sqlite_init, 1,
				"submodules may initialize after identity publication commits")
			helpers.assert_eq(calls.rotation_appends, 1,
				"public log actions must become reachable after the commit")
		end
	end, debug.traceback)

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

	helpers.it("does not replace a dangling device.json symlink", function()
		run_unowned_case("dangling")
	end)

	helpers.it("does not replace a directory at device.json", function()
		run_unowned_case("directory")
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Identity Publication =========
-- =========================================
-- =========================================

helpers.describe("log_manager device identity publication", function()
	helpers.it("atomic-write refusal exposes no generated identity", function()
		run_publication_case("write")
	end)

	helpers.it("publishes once after a proven-absent candidate identity", function()
		run_publication_case(nil)
	end)
end)
