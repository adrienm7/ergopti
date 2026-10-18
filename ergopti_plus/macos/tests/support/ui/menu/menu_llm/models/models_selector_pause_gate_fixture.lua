--- tests/support/ui/menu/menu_llm/models/models_selector_pause_gate_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_models_selector_pause_gate
--- DESCRIPTION:
--- Prelude shared by the test_models_selector_pause_gate_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Build a minimal fake context that satisfies ModelsSelector.build() I/O contract
local function make_ctx(paused)
	local switch_calls = {}
	local disable_calls = 0
	return {
		state = {
			llm_model   = "",
			llm_backend = "mlx",
		},
		models_mgr = {
			get_installed_models = function() return {} end,
			get_presets          = function() return {} end,
			get_model_info       = function() return nil end,
			get_model_ram        = function() return 0 end,
			is_model_installed   = function() return false end,
		},
		switch_model  = function(m) switch_calls[#switch_calls + 1] = m end,
		disable_model = function() disable_calls = disable_calls + 1; return true end,
		save_prefs    = function() end,
		update_menu   = function() end,
		DEFAULT_STATE = { llm_model_mlx = "", llm_model_ollama = "" },
		paused        = paused,
		get_switch_calls = function() return switch_calls end,
		get_disable_calls = function() return disable_calls end,
	}
end






local function model_readout_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/model_readout_frames.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

local function with_model_readout_owner(scenario)
	local previous, previous_hs, previous_getenv = {}, rawget(_G, "hs"), os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local native, owner, receipt, acquired, scratch, fresh_bridge
	local ok, err = pcall(function()
		local driver = helpers.driver_root():gsub("/+$", "")
		local shared = assert(driver:match("^(.*)/[^/]+$")) .. "/_shared/lua"
		require("tests.support.module_isolation").purge(driver, shared)
		helpers.load_with_stubs("infra.logger")
		scratch = assert(os.tmpname())
		assert(os.remove(scratch))
		assert(hs.fs.mkdir(scratch))
		assert(hs.fs.mkdir(scratch .. "/metrics"))
		local ledger = assert(io.open(scratch .. "/metrics/karabiner_kc.log", "wb")); assert(ledger:close())
		local bootstrap = assert(io.open(scratch .. "/paths.toml", "wb"))
		assert(bootstrap:write('ConfigDirPath = "' .. scratch .. '/"\n'))
		assert(bootstrap:close())
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return scratch .. "/paths.toml" end
			return previous_getenv(name)
		end
		local paths = require("infra.config_paths")
		helpers.assert_eq(paths.init(scratch .. "/"), true)
		helpers.assert_eq(paths.get_config_dir(), scratch .. "/")
		package.loaded["infra.i18n"] = nil
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner)
		helpers.assert_eq(acquired, true)
		receipt = native.scope_capture(owner)
		helpers.assert_not_nil(receipt)
		helpers.assert_eq(native.scope_apply(owner, receipt, "en"), true)
		local manager = require("ui.menu.menu_llm.models_manager").new({ trigger_reload = function() end })
		fresh_bridge = package.loaded["modules.keylogger.kc_bridge"]
		local calls = {}
		local ctx = {
			state = { llm_backend = "ollama", llm_model = "", llm_user_models = {} },
			models_mgr = manager, DEFAULT_STATE = {}, paused = false,
			switch_model = function(name) calls[#calls + 1] = name end,
			disable_model = function() return true end,
			save_prefs = function() error("readout construction must not save") end,
			update_menu = function() error("readout construction must not refresh") end,
		}
		scenario(require("ui.menu.menu_llm.models_selector"), ctx,
			require("infra.manifest_menu"), native, calls, model_readout_corpus())
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleanup_ok, cleanup_error = pcall(function()
		fresh_bridge = fresh_bridge or package.loaded["modules.keylogger.kc_bridge"]
		if fresh_bridge and not rawequal(fresh_bridge, previous["modules.keylogger.kc_bridge"]) then fresh_bridge.stop() end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then
			helpers.assert_eq(scheduler.cancelAll(), true)
			helpers.assert_eq(scheduler.activeCount(), 0)
		end
		if scratch then
			os.remove(scratch .. "/metrics/karabiner_kc.log")
			os.remove(scratch .. "/paths.toml")
			if hs.fs.attributes(scratch .. "/hammerspoon") then assert(hs.fs.rmdir(scratch .. "/hammerspoon")) end
			if hs.fs.attributes(scratch .. "/metrics") then assert(hs.fs.rmdir(scratch .. "/metrics")) end
			assert(hs.fs.rmdir(scratch))
		end
	end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs = previous_hs
	os.getenv = previous_getenv
	helpers.assert_eq(rawequal(os.getenv, previous_getenv), true)
	for name, value in pairs(previous) do helpers.assert_eq(rawequal(package.loaded[name], value), true, name) end
	helpers.assert_eq(cleanup_ok, true, tostring(cleanup_error))
	helpers.assert_eq(restored, true, "actual translator inverse restores before releasing ownership")
	helpers.assert_eq(released, true)
	helpers.assert_eq(forgotten, true)
	if not ok then error(err, 0) end
end

local function model_readout_sheet(rows, name)
	for _, provider in ipairs(rows) do
		for _, model in ipairs(provider.items or {}) do
			if type(model.label) == "string" and model.label:find(name, 1, true) then
				return model.items, model
			end
		end
	end
	error("actual curated model is missing: " .. name)
end

local function with_complete_model_locale(locale, scenario)
	local previous, previous_hs, previous_getenv = {}, rawget(_G, "hs"), os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local native, owner, receipt, acquired, scratch, fresh_bridge
	local ok, err = pcall(function()
		local driver = helpers.driver_root():gsub("/+$", "")
		local shared = assert(driver:match("^(.*)/[^/]+$")) .. "/_shared/lua"
		require("tests.support.module_isolation").purge(driver, shared)
		helpers.load_with_stubs("infra.logger")
		scratch = assert(os.tmpname())
		assert(os.remove(scratch))
		assert(hs.fs.mkdir(scratch))
		assert(hs.fs.mkdir(scratch .. "/metrics"))
		local ledger = assert(io.open(scratch .. "/metrics/karabiner_kc.log", "wb")); assert(ledger:close())
		local bootstrap = assert(io.open(scratch .. "/paths.toml", "wb"))
		assert(bootstrap:write('ConfigDirPath = "' .. scratch .. '/"\n'))
		assert(bootstrap:close())
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return scratch .. "/paths.toml" end
			return previous_getenv(name)
		end
		local paths = require("infra.config_paths")
		helpers.assert_eq(paths.init(scratch .. "/"), true)
		helpers.assert_eq(paths.get_config_dir(), scratch .. "/")
		package.loaded["infra.i18n"] = nil
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner)
		helpers.assert_eq(acquired, true)
		receipt = native.scope_capture(owner)
		helpers.assert_not_nil(receipt)
		helpers.assert_eq(native.scope_apply(owner, receipt, locale), true)
		local manager = require("ui.menu.menu_llm.models_manager").new({ trigger_reload = function() end })
		fresh_bridge = package.loaded["modules.keylogger.kc_bridge"]
		local calls = {}
		local ctx = {
			state = { llm_backend = "ollama", llm_model = "", llm_user_models = {} },
			models_mgr = manager, DEFAULT_STATE = {}, paused = false,
			switch_model = function(name) calls[#calls + 1] = name end,
			disable_model = function() return true end,
			save_prefs = function() error("readout construction must not save") end,
			update_menu = function() error("readout construction must not refresh") end,
		}
		scenario(require("ui.menu.menu_llm.models_selector"), ctx,
			require("infra.manifest_menu"), native, calls, model_readout_corpus())
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleanup_ok, cleanup_error = pcall(function()
		fresh_bridge = fresh_bridge or package.loaded["modules.keylogger.kc_bridge"]
		if fresh_bridge and not rawequal(fresh_bridge, previous["modules.keylogger.kc_bridge"]) then fresh_bridge.stop() end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then
			helpers.assert_eq(scheduler.cancelAll(), true)
			helpers.assert_eq(scheduler.activeCount(), 0)
		end
		if scratch then
			os.remove(scratch .. "/metrics/karabiner_kc.log")
			os.remove(scratch .. "/paths.toml")
			if hs.fs.attributes(scratch .. "/hammerspoon") then assert(hs.fs.rmdir(scratch .. "/hammerspoon")) end
			if hs.fs.attributes(scratch .. "/metrics") then assert(hs.fs.rmdir(scratch .. "/metrics")) end
			assert(hs.fs.rmdir(scratch))
		end
	end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs = previous_hs
	os.getenv = previous_getenv
	helpers.assert_eq(rawequal(os.getenv, previous_getenv), true)
	for name, value in pairs(previous) do helpers.assert_eq(rawequal(package.loaded[name], value), true, name) end
	helpers.assert_eq(cleanup_ok, true, tostring(cleanup_error))
	helpers.assert_eq(restored, true, "actual translator inverse restores before releasing ownership")
	helpers.assert_eq(released, true)
	helpers.assert_eq(forgotten, true)
	if not ok then error(err, 0) end
end

return {
	make_ctx = make_ctx,
	model_readout_corpus = model_readout_corpus,
	model_readout_sheet = model_readout_sheet,
	with_complete_model_locale = with_complete_model_locale,
	with_model_readout_owner = with_model_readout_owner,
}
