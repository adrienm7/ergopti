--- tests/unit/modules/keystats/storage/test_foreign_sync_directory_failure.lua

--- ==============================================================================
--- MODULE: Foreign-ledger directory failure regression
--- DESCRIPTION:
--- Proves that the foreign data.sql scan uses the canonical directory adapter
--- and that both log-manager call paths preserve a refused or raised sync detail.
--- ==============================================================================

local helpers = require("tests.helpers")

local function strip_lua_comments(source)
	source = source:gsub("%-%-%[%[.-%]%]", " ")
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line:gsub("%-%-.*$", "")
	end
	return table.concat(lines, "\n")
end





-- ==========================================
-- ==========================================
-- ======= 1/ Export Enumeration Gate =======
-- ==========================================
-- ==========================================

helpers.describe("keystats export — foreign directory enumeration", function()
	helpers.it("distinguishes a missing directory from an uninspectable directory", function()
		helpers.with_fresh_modules({"core.logger.engine.logger", "core.i18n.engine.i18n", "core.fs.engine.dir", "core.fs.adapters.file_system",
			"modules.keystats.export"}, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			package.loaded["core.i18n.engine.i18n"] = {get = function(key) return key end}
			local status, failing_path = "error", "/metrics/"
			package.loaded["core.fs.adapters.file_system"] = {classify_no_follow = function(path)
				helpers.assert_eq(path, failing_path)
				return nil, status
			end}
			local export = helpers.load_with_stubs("modules.keystats.export", {fs = {attributes = function(path)
				if path == failing_path then return nil end
				return {mode = "directory"}
			end}})
			export.init({paths = {metrics_dir = "/metrics/"}, device_id = "local", get_db = function() return {} end})
			for _, path in ipairs({"/metrics/", "/metrics/by_device/"}) do
				failing_path, status = path, "error"
				local devices, detail = export.sync_foreign_data_sql()
				helpers.assert_nil(devices, "unverified directory must not be reported as empty")
				helpers.assert_true(type(detail) == "string")
				status = "absent"
				devices, detail = export.sync_foreign_data_sql()
				helpers.assert_eq(devices, {})
				helpers.assert_nil(detail)
			end
		end)
	end)

	helpers.it("returns the canonical directory refusal without throwing", function()
		helpers.with_fresh_modules({
			"core.fs.engine.dir",
			"core.i18n.engine.i18n",
			"core.logger.engine.logger",
			"modules.keystats.export",
		}, function()
			local try_calls = 0
			package.loaded["core.fs.engine.dir"] = {
				try_entries = function(path)
					try_calls = try_calls + 1
					helpers.assert_eq(path, "/metrics/by_device/")
					if try_calls > 1 then return { ".", "..", "local-device" }, true end
					return {}, false, "HS023_DIRECTORY_REFUSAL"
				end,
			}
			package.loaded["core.i18n.engine.i18n"] = {
				get = function(key) return key end,
			}
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()

			local export = helpers.load_with_stubs("modules.keystats.export", {
				fs = {
					attributes = function() return { mode = "directory" } end,
				},
			})
			export.init({
				paths = { metrics_dir = "/metrics/" },
				device_id = "local-device",
				get_db = function() return {} end,
			})

			local call_ok, result, detail = pcall(export.sync_foreign_data_sql)
			if not call_ok then
				error("directory refusal escaped the adapter: " .. tostring(result))
			end
			helpers.assert_nil(result,
				"an incomplete enumeration may not masquerade as an empty successful scan")
			helpers.assert_true(type(detail) == "string"
				and detail:find("HS023_DIRECTORY_REFUSAL", 1, true) ~= nil,
				"the adapter refusal detail must remain available to the caller")
			helpers.assert_eq(try_calls, 1,
				"foreign sync must enumerate through the canonical directory boundary")

			local recovered, recovered_detail = export.sync_foreign_data_sql()
			helpers.assert_true(type(recovered) == "table" and #recovered == 0,
				"a later authoritative empty listing must recover normally")
			helpers.assert_nil(recovered_detail)
			helpers.assert_eq(try_calls, 2,
				"each retry must acquire a fresh authoritative directory snapshot")
		end)
	end)
end)





-- =======================================
-- =======================================
-- ======= 2/ Caller Error Surface =======
-- =======================================
-- =======================================

local function ingest_errors(sync_foreign_data_sql)
	return helpers.with_fresh_modules({
		"core.logger.engine.logger",
		"core.fs.adapters.file_system",
		"modules.keystats.sqlite_writer",
		"modules.keystats.aggregator",
		"modules.keystats.rotation",
		"modules.keystats.export",
		"metrics.engine.metrics",
		"core.fs.adapters.ledger_append", "modules.keystats.log_manager",
	}, function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_module_name, message, ...)
			local ok, rendered = pcall(string.format, message, ...)
			errors[#errors + 1] = ok and rendered or tostring(message)
		end
		package.loaded["core.logger.engine.logger"] = logger

		local db = {}
		function db:nrows()
			return function() return nil end
		end
		package.loaded["modules.keystats.sqlite_writer"] = {
			get_db = function() return db end,
		}
		package.loaded["modules.keystats.aggregator"] = {}
		package.loaded["modules.keystats.rotation"] = {
			read_new_entries = function() return {}, 0, "eof" end,
		}
		package.loaded["modules.keystats.export"] = {
			sync_foreign_data_sql = sync_foreign_data_sql,
		}
		package.loaded["metrics.engine.metrics"] = {}

		local manager = helpers.load_with_stubs("modules.keystats.log_manager")
		local call_ok, call_err = pcall(manager.ingest_once)
		if not call_ok then
			error("foreign sync failure aborted the ingest tick: " .. tostring(call_err))
		end
		return errors
	end)
end

local function errors_contain(errors, needle)
	for _, message in ipairs(errors) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

helpers.describe("keystats log manager — foreign sync failures", function()
	helpers.it("logs a raised foreign-sync detail", function()
		local errors = ingest_errors(function()
			error("HS023_SYNC_THROW")
		end)
		helpers.assert_true(errors_contain(errors, "HS023_SYNC_THROW"),
			"the pcall traceback must not be discarded")
	end)

	helpers.it("logs a refused foreign-sync detail", function()
		local errors = ingest_errors(function()
			return nil, "HS023_SYNC_REFUSAL"
		end)
		helpers.assert_true(errors_contain(errors, "HS023_SYNC_REFUSAL"),
			"a non-throwing adapter refusal must remain visible")
	end)

	helpers.it("routes every production caller through one checked boundary", function()
		local source = helpers.read_driver_source("local function _mark_aggregate_cache_rebuilt")
		helpers.assert_not_nil(source, "log-manager source must be discoverable")
		local executable = strip_lua_comments(source)
		local direct_calls = select(2, executable:gsub("Export%.sync_foreign_data_sql", ""))
		helpers.assert_eq(direct_calls, 1,
			"ingest and startup recovery must share one error-reporting foreign-sync boundary")
		helpers.assert_true(executable:find(
			"local foreign_devices = _sync_foreign_data_sql(function(device_id)", 1, true) ~= nil,
			"the recurring ingest path must consume the checked boundary result")
		local recovery = executable:match("local function _recover_aggregate_cache%(db, replay_state%)(.-)\nend\n")
		-- A resumed walk leaves foreign rows to ingest; a fresh one imports them here.
		helpers.assert_true(recovery ~= nil and recovery:find(
			"\n\tif _running_recovery_progress() == nil then _sync_foreign_data_sql() end\n", 1, true) ~= nil,
			"startup aggregate recovery must route through the checked boundary too")
	end)
end)

helpers.describe("foreign sync writer quarantine", function()
	helpers.it("does not touch the previously captured handle after foreign sync retires it", function()
		helpers.with_fresh_modules({ "core.logger.engine.logger", "modules.keystats.sqlite_writer",
			"modules.keystats.aggregator", "modules.keystats.rotation", "modules.keystats.export",
			"metrics.engine.metrics", "core.fs.adapters.ledger_append", "modules.keystats.log_manager" }, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			local calls = 0
			local db = { nrows = function() calls = calls + 1; error("retired handle read") end,
				exec = function() calls = calls + 1; error("retired handle write") end }
			local current = db
			package.loaded["modules.keystats.sqlite_writer"] = { get_db = function() return current end }
			package.loaded["modules.keystats.aggregator"] = {}
			package.loaded["modules.keystats.rotation"] = {}
			package.loaded["modules.keystats.export"] = { sync_foreign_data_sql = function()
				current = nil
				return {}
			end }
			package.loaded["metrics.engine.metrics"] = {}
			local manager = helpers.load_with_stubs("modules.keystats.log_manager")
			helpers.assert_eq(manager.ingest_once(), false)
			helpers.assert_eq(calls, 0, "foreign sync may retire the original writer")
		end)
	end)
end)
