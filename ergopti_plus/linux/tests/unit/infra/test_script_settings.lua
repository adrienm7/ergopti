--- tests/unit/infra/test_script_settings.lua

--- ==============================================================================
--- MODULE: Script Settings Regression Tests
--- DESCRIPTION:
--- Proves that Linux reads `script.log_level` from the canonical manifest,
--- restores it at runtime, and never publishes a menu choice before persistence.
--- ==============================================================================

local helpers = require("tests.helpers")

local ENUM_VALUES = {
	"DEBUG", "TRACE", "DONE", "INFO", "START", "SUCCESS", "WARNING", "ERROR",
}

local THRESHOLDS = {
	debug = 10,
	trace = 10,
	done = 10,
	info = 20,
	start = 20,
	success = 20,
	warn = 30,
	error = 40,
}

--- Loads script_settings against isolated manifest, storage, and logger seams.
--- @param options table|nil { stored?: any, writable?: boolean, default?: string }
--- @return table, table, table
local function load_settings(options)
	options = options or {}
	local storage = {
		values = {},
		writes = {},
		writable = options.writable ~= false,
	}
	if options.stored ~= nil then storage.values["script.log_level"] = options.stored end
	storage.get = function(key, default_value)
		local value = storage.values[key]
		if value == nil then return default_value end
		return value
	end
	storage.set = function(key, value)
		storage.writes[#storage.writes + 1] = { key = key, value = value }
		if not storage.writable then return false end
		storage.values[key] = value
		return true
	end

	local logger = { levels = {}, warnings = {}, errors = {} }
	logger.level_of = function(variant) return THRESHOLDS[variant] end
	logger.set_level = function(level) logger.levels[#logger.levels + 1] = level end
	logger.warn = function(_, message, value)
		logger.warnings[#logger.warnings + 1] = string.format(message, value)
	end
	logger.error = function(_, message, value)
		logger.errors[#logger.errors + 1] = string.format(message, value)
	end

	local manifest = {
		find_entry_by_path = function(path)
			if path ~= "script.log_level" then return nil end
			return {
				default = options.default or "INFO",
				enum_values = ENUM_VALUES,
			}
		end,
	}

	local previous = {
		logger = package.loaded["logger.shim"],
		manifest = package.loaded["infra.manifest_reader"],
		storage = package.loaded["adapters.storage"],
		settings = package.loaded["infra.script_settings"],
	}
	package.loaded["logger.shim"] = logger
	package.loaded["infra.manifest_reader"] = manifest
	package.loaded["adapters.storage"] = storage
	package.loaded["infra.script_settings"] = nil
	local settings = require("infra.script_settings")
	package.loaded["logger.shim"] = previous.logger
	package.loaded["infra.manifest_reader"] = previous.manifest
	package.loaded["adapters.storage"] = previous.storage
	package.loaded["infra.script_settings"] = previous.settings
	return settings, storage, logger
end





-- =========================================
-- =========================================
-- ======= 1/ Restore and validation =======
-- =========================================
-- =========================================

helpers.describe("script settings restore", function()
	helpers.it("applies the manifest default when no choice is stored", function()
		local settings, _, logger = load_settings()
		helpers.assert_true(settings.apply())
		helpers.assert_eq(logger.levels, { 20 })
		helpers.assert_eq(settings.current(), "INFO")
	end)

	helpers.it("restores a persisted choice", function()
		local settings, _, logger = load_settings({ stored = "WARNING" })
		helpers.assert_true(settings.apply())
		helpers.assert_eq(logger.levels, { 30 })
		helpers.assert_eq(settings.current(), "WARNING")
	end)

	helpers.it("accepts every enum value declared by the manifest", function()
		local settings, _, logger = load_settings()
		local expected = { 10, 10, 10, 20, 20, 20, 30, 40 }
		for _, level in ipairs(ENUM_VALUES) do
			helpers.assert_true(settings.apply(level), level .. " must be applicable")
		end
		helpers.assert_eq(logger.levels, expected)
	end)

	helpers.it("rejects a corrupt persisted value and uses the shipped default", function()
		local settings, _, logger = load_settings({ stored = "EVERYTHING" })
		helpers.assert_true(settings.apply())
		helpers.assert_eq(logger.levels, { 20 })
		helpers.assert_eq(#logger.warnings, 1)
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ Durable mutation =============
-- =========================================
-- =========================================

helpers.describe("script settings mutation", function()
	helpers.it("normalises, persists, and then applies a menu choice", function()
		local settings, storage, logger = load_settings()
		helpers.assert_true(settings.set("error"))
		helpers.assert_eq(storage.writes, {
			{ key = "script.log_level", value = "ERROR" },
		})
		helpers.assert_eq(logger.levels, { 40 })
		helpers.assert_eq(settings.current(), "ERROR")
	end)

	helpers.it("leaves the active level unchanged when persistence fails", function()
		local settings, storage, logger = load_settings({ writable = false })
		helpers.assert_true(settings.apply("INFO"))
		helpers.assert_true(not settings.set("ERROR"))
		helpers.assert_eq(#storage.writes, 1)
		helpers.assert_eq(logger.levels, { 20 })
		helpers.assert_eq(settings.current(), "INFO")
	end)

	helpers.it("rejects an undeclared level without touching storage or logger", function()
		local settings, storage, logger = load_settings()
		helpers.assert_true(not settings.set("ALL"))
		helpers.assert_eq(#storage.writes, 0)
		helpers.assert_eq(#logger.levels, 0)
	end)
end)
