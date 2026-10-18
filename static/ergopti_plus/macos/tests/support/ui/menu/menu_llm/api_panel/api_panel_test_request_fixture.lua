--- tests/support/ui/menu/menu_llm/api_panel/api_panel_test_request_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_api_panel_test_request
--- DESCRIPTION:
--- Prelude shared by the test_api_panel_test_request_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")


local function fixture_context()
	return {
		state = { llm_backend = "api", llm_model = "probe-model" },
		paused = false,
		is_paused = function() return false end,
		keymap = { reset_predictions_for_configuration = function() return true end },
		update_menu = function() end,
		WarmupCtrl = { warmup = function() end },
	}
end

local function install_doubles(args)
	local entries = args.entries
	local active_id = args.active_id
	local spec = args.spec
	local calls = {}
	local 	api_remote = {
		PROVIDER_ORDER = { "openai" },
		PROVIDERS = {
			openai = { label = "OpenAI", default_model = "openai-default" },
		},
		get_entries = function() return entries end,
		set_entries = function(value) entries = value end,
		get_active_entry_id = function() return active_id end,
		set_active_entry_id = function(value) active_id = value end,
		get_active_entry = function()
			for _, entry in ipairs(entries) do
				if entry.id == active_id then return entry end
			end
			return nil
		end,
		get_test_request_spec = function() return spec end,
		test_request = function(entry, request_spec, on_ok, on_fail)
			calls[#calls + 1] = {
				entry = entry, spec = request_spec,
				on_ok = on_ok, on_fail = on_fail,
			}
			return true
		end,
	}
	package.loaded["modules.llm"] = { api_remote = api_remote }
	-- The two body templates mirror the en.json shapes so the substitution
	-- wiring is exercised; every other key echoes itself.
	package.loaded["infra.i18n"] = { get = function(key)
		if args.locale_strings then return args.locale_strings[key] or key end
		if key == "menu.llm.api_test_ok_body" then
			return '"{1}" answered in {2} ms: {3}'
		end
		if key == "menu.llm.api_unreachable_body" then
			return '"%s" did not respond'
		end
		return key
	end }
	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function() end,
	}
	package.loaded["infra.dialog_util"] = {}
	local notifications = {}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, level)
			notifications[#notifications + 1] = {
				title = title, body = body, level = level,
			}
			return true
		end,
	}
	local command_renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
		json_decode = require("adapters.json_codec").decode,
		i18n = {
			get = package.loaded["infra.i18n"].get,
			-- These command rows never request a translated section.
			section = function() return {} end,
		},
		logger = helpers.make_logger_stub(),
	}))
	package.loaded["infra.manifest_menu"] = {
		command_row = command_renderer.command_row,
		template_rows = command_renderer.template_rows,
		get_array = command_renderer.get_array,
		render_rows = function(rows) return rows end,
	}
	package.loaded["ui.menu.menu_llm.api_panel"] = nil
	return api_remote, calls, notifications
end

local function test_row(rows)
	for _, row in ipairs(rows) do
		if row.label == "menu.llm.api_test_entry" then return row end
	end
	return nil
end



local function with_api_add_locale(scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local native, owner, receipt, acquired
	local ok, err = pcall(function()
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
		helpers.assert_eq(native.get_locale(), "en")
		helpers.assert_eq(require("infra.locale").current_locale(), "en")
		scenario(native)
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], previous[name]), true, name) end
	helpers.assert_eq(restored, true, "the genuine runtime inverse restores its previous locale")
	helpers.assert_eq(released, true, "the temporary locale owner is released on every exit")
	helpers.assert_eq(forgotten, true, "the temporary locale receipt is forgotten on every exit")
	if not ok then error(err, 0) end
end

return {
	fixture_context = fixture_context,
	install_doubles = install_doubles,
	test_row = test_row,
	with_api_add_locale = with_api_add_locale,
}
