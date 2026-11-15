--- tests/unit/settings/preferences/test_script_settings.lua

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
	local current_level = 20
	logger.set_level = function(level) current_level = level; logger.levels[#logger.levels + 1] = level end
	logger.get_level = function() return current_level end
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
		logger = package.loaded["core.logger.engine.shim"],
		manifest = package.loaded["infra.manifest_reader"],
		storage = package.loaded["core.fs.adapters.storage"],
		settings = package.loaded["settings.engine.scope.script_settings"],
	}
	package.loaded["core.logger.engine.shim"] = logger
	package.loaded["infra.manifest_reader"] = manifest
	package.loaded["core.fs.adapters.storage"] = storage
	package.loaded["settings.engine.scope.script_settings"] = nil
	local settings = require("settings.engine.scope.script_settings")
	local original_set = settings.set
	settings.set = function(value)
		local saved_scope, saved_settings = package.loaded["settings.engine.scope.script_scope"], package.loaded["settings.engine.scope.script_settings"]
		local saved_shim, saved_logger = package.loaded["core.logger.engine.shim"], package.loaded["core.logger.engine"]
		package.loaded["settings.engine.scope.script_settings"], package.loaded["core.logger.engine.shim"], package.loaded["core.logger.engine"] = settings, logger, logger
		package.loaded["settings.engine.scope.script_scope"] = { retry_edit = function() return true end, edit_setting = function(key, level)
			if not storage.set(key, level) then return false end
			local token = { pending = function() return false end }
			assert(settings.scope_acquire(token))
			local receipt = assert(settings.scope_capture(token))
			local applied = settings.scope_apply(token, receipt, level)
			assert(settings.scope_release(token)); assert(settings.scope_forget(token, receipt))
			return applied
		end }
		local ok, result = pcall(original_set, value)
		package.loaded["settings.engine.scope.script_scope"], package.loaded["settings.engine.scope.script_settings"] = saved_scope, saved_settings
		package.loaded["core.logger.engine.shim"], package.loaded["core.logger.engine"] = saved_shim, saved_logger
		if not ok then error(result, 0) end
		return result
	end
	package.loaded["core.logger.engine.shim"] = previous.logger
	package.loaded["infra.manifest_reader"] = previous.manifest
	package.loaded["core.fs.adapters.storage"] = previous.storage
	package.loaded["settings.engine.scope.script_settings"] = previous.settings
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

-- Each log-level, locale or error-window change wrote storage.edit-*.bak, a
-- full copy of the store, and config.toml.edit-*.bak when the file held the
-- row, and nothing removed them: the folder grew with ordinary use. Windows
-- and macOS keep no copy per edit; a committed and released edit now removes
-- its own rollback copies (CFL-002, script-edit-backups).
helpers.describe("script settings edits (script-edit-backups)", function()
	--- Names of the edit backups in the scratch configuration folder.
	local function edit_backups(dir)
		local found = {}
		local listing = assert(io.popen("ls -1A " .. require("core.process.adapters.shell_runner").quote(dir) .. " 2>/dev/null"))
		for name in listing:lines() do
			if name:find("%.edit%-.*%.bak$") then found[#found + 1] = name end
		end
		listing:close()
		return found
	end

	helpers.it("removes its rollback copies once an edit commits (script-edit-backups)", function()
		local Paths = require("settings.engine.paths")
		local dir = Paths.default_config_dir()
		helpers.assert_true(dir:find(os.getenv("HOME") or "\0", 1, true) == 1, "the runner's scratch home holds the folder")
		local Settings = require("settings.engine.scope.script_settings")
		local before = Settings.current()
		local config = Paths.config("config.toml")
		assert(os.execute("mkdir -p " .. require("core.process.adapters.shell_runner").quote(dir)))
		local handle = assert(io.open(config, "w"))
		handle:write('[script]\nlog_level = "INFO"\n')
		handle:close()
		local ok, err = pcall(function()
			for _, level in ipairs({ "DEBUG", "WARNING", "ERROR" }) do
				helpers.assert_true(Settings.set(level), "the menu change commits: " .. level)
			end
			helpers.assert_eq(Settings.current(), "ERROR")
			local file = assert(io.open(config, "r"))
			local text = file:read("*a")
			file:close()
			helpers.assert_true(text:find('log_level = "ERROR"', 1, true) ~= nil, "the row the file holds is rewritten")
			helpers.assert_eq(edit_backups(dir), {}, "no copy of the store or the file is left behind")
		end)
		Settings.set(before)
		os.remove(config)
		if not ok then error(err, 0) end
	end)
end)
