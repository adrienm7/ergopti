--- tests/support/onboarding_finish_fixture.lua

--- ==============================================================================
--- MODULE: Onboarding Finish Fixture
--- DESCRIPTION:
--- Drives the real onboarding finish-message handler with controlled
--- persistence boundaries: the language store, the destination read and the
--- configuration writer. Everything else (the catalogue, the manifest reader,
--- the answers contract and the config migration) is the production code.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

local MODULE_NAMES = {
	"adapters.file_system",
	"infra.deferred_work",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.paths",
	"infra.text_utils",
	"infra.toml.codec",
	"infra.toml.writer",
	"ui.onboarding",
}

--- Returns one named upvalue and its numeric slot.
--- @param fn function
--- @param target string
--- @return any value
--- @return integer|nil index
local function named_upvalue(fn, target)
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == target then return value, index end
	end
	return nil, nil
end

--- Runs one finish message through the production handler.
--- @param opts table `{ answers, locale = "true"|"false"|"nil"|"throw",
---   write = "true"|"false"|"nil"|"throw", read = function(path)|nil }`.
--- @param scenario function scenario(state) with the recorded side effects.
function M.with_finish(opts, scenario)
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local state = {
		alerts = {},
		deferred = 0,
		locale_persists = 0,
		locale_switches = 0,
		notifications = 0,
		writes = {},
	}
	local function noop() end
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.paths"] = { shared = function() return "/virtual/shared" end }
	package.loaded["infra.text_utils"] = { applescript_format = string.format }
	package.loaded["infra.toml.codec"] = { decode = function() return {} end }
	package.loaded["adapters.file_system"] = {
		read_with_status = opts.read or function() return nil, "absent" end,
	}
	package.loaded["infra.toml.writer"] = {
		batch_write = function(path, rows)
			state.writes[#state.writes + 1] = { path = path, rows = rows }
			local mode = opts.write or "true"
			if mode == "throw" then error("disk on fire") end
			if mode == "nil" then return nil end
			if mode == "false" then return false, "rename failed" end
			return true
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function() state.notifications = state.notifications + 1; return true end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function() state.deferred = state.deferred + 1; return true end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = function(title, body, button)
			state.alerts[#state.alerts + 1] = { title = title, body = body, button = button }
			return true
		end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		set_locale_no_reload = function()
			state.locale_switches = state.locale_switches + 1
			return true
		end,
		persist_locale = function()
			state.locale_persists = state.locale_persists + 1
			local mode = opts.locale or "true"
			if mode == "throw" then error("injected locale persistence failure") end
			if mode == "nil" then return nil end
			return mode == "true"
		end,
	}
	local ok, err = xpcall(function()
		local onboarding = require("ui.onboarding")
		require("tests.support.onboarding_shared_data").install()
		local handle_message = named_upvalue(onboarding.run, "handle_message")
		helpers.assert_type(handle_message, "function",
			"the fixture must drive the production onboarding message handler")
		local _, config_path_index = named_upvalue(onboarding.run, "_config_path")
		helpers.assert_not_nil(config_path_index,
			"the fixture must assign the real commit destination upvalue")
		debug.setupvalue(onboarding.run, config_path_index, "/virtual/onboarding-config.toml")
		handle_message({ action = "finish", answers = opts.answers })
		scenario(state)
	end, debug.traceback)
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

return M
