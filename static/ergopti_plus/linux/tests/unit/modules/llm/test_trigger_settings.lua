--- tests/unit/modules/llm/test_trigger_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Trigger and Privacy Controls
--- DESCRIPTION:
--- Proves that the five supported trigger settings are durable and that
--- the prediction engine consumes them instead of advertising inert controls.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local held = {}

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
end

local function load_settings(initial, writes_fail)
	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	replace("adapters.storage", storage)
	package.loaded["modules.llm.trigger_settings"] = nil
	local settings = require("modules.llm.trigger_settings")
	settings._reset()
	return settings, storage
end

helpers.describe("LLM trigger settings: durable manifest-backed values", function()
	helpers.it("uses the Linux manifest defaults without storing them", function()
		local settings, storage = load_settings()
		local manifest = require("infra.manifest_reader")
		for _, name in ipairs({
			"debounce_ms", "instant_on_word_end", "after_hotstring",
			"secure_filter_enabled", "url_bar_filter_enabled",
		}) do
			helpers.assert_eq(settings.get(name), manifest.default_for("llm.trigger." .. name))
			helpers.assert_true(not storage.has("llm.trigger." .. name))
		end
		restore()
	end)

	helpers.it("persists a change before publishing it and clears a restored default", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.set("debounce_ms", 750))
		helpers.assert_eq(storage.get("llm.trigger.debounce_ms"), 750)
		helpers.assert_eq(settings.get("debounce_ms"), 750)
		helpers.assert_true(settings.set("debounce_ms", 500))
		helpers.assert_true(not storage.has("llm.trigger.debounce_ms"))
		restore()
	end)

	helpers.it("keeps the durable value live when persistence fails", function()
		local settings = load_settings({ ["llm.trigger.secure_filter_enabled"] = false }, true)
		helpers.assert_eq(settings.get("secure_filter_enabled"), false)
		helpers.assert_eq(settings.set("secure_filter_enabled", true), false)
		helpers.assert_eq(settings.get("secure_filter_enabled"), false)
		restore()
	end)

	helpers.it("rejects debounce values outside the shared UI range", function()
		local settings, storage = load_settings()
		for _, value in ipairs({ 49, 10001, 50.5, "500" }) do
			helpers.assert_eq(settings.set("debounce_ms", value), false)
		end
		helpers.assert_eq(#storage.keys(), 0)
		restore()
	end)
end)

helpers.describe("prediction engine: trigger settings affect requests", function()
	helpers.it("waits for the configured debounce and cancels a pending owner", function()
		local scheduler = Fakes.timer_scheduler()
		local chat_calls = 0
		replace("modules.llm.trigger_settings", {
			get = function(name)
				if name == "debounce_ms" then return 500 end
				if name == "secure_filter_enabled" then return false end
				if name == "url_bar_filter_enabled" then return false end
			end,
			set = function() return true end,
		})
		replace("modules.llm.api_ollama", {
			chat = function() chat_calls = chat_calls + 1 end,
			cancel = function() return true end,
		})
		replace("modules.llm.profiles", {
			init = function() end,
			is_enabled = function() return true end,
			get_current_model = function() return "test-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		})
		package.loaded["modules.llm.prediction_engine"] = nil
		local engine = require("modules.llm.prediction_engine")
		engine.init({ scheduler = scheduler })
		engine.on_char("/", "hello //", { app_id = "editor" })
		helpers.assert_eq(chat_calls, 0, "a debounce control that fires synchronously is inert")
		helpers.assert_eq(scheduler.test.advance(0.499), 0)
		helpers.assert_eq(chat_calls, 0)
		helpers.assert_eq(scheduler.test.advance(0.001), 1)
		helpers.assert_eq(chat_calls, 1)

		engine.on_char("/", "again //", { app_id = "editor" })
		engine.on_char("x", "again //x", { app_id = "editor" })
		scheduler.test.advance(1)
		helpers.assert_eq(chat_calls, 2,
			"continued typing must replace the stale explicit trigger with one inactivity request")

		engine.on_char("/", "final //", { app_id = "editor" })
		engine.cancel()
		scheduler.test.advance(1)
		helpers.assert_eq(chat_calls, 2, "cancel must settle the pending debounce owner")
		restore()
	end)

	helpers.it("applies the URL-bar toggle to the real detector seam", function()
		local chat_calls = 0
		replace("modules.llm.trigger_settings", {
			get = function(name)
				if name == "secure_filter_enabled" then return false end
				if name == "url_bar_filter_enabled" then return true end
				return 500
			end,
			set = function() return true end,
		})
		replace("adapters.secure_field_detector", {
			isSecureField = function() return false end,
			isUrlBar = function(app_id) return app_id == "firefox" end,
		})
		replace("adapters.process_lifecycle", { getForegroundApp = function() return "firefox" end })
		replace("modules.llm.api_ollama", { chat = function() chat_calls = chat_calls + 1 end })
		replace("modules.llm.profiles", {
			get_current_model = function() return "test-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		})
		package.loaded["modules.llm.prediction_engine"] = nil
		require("modules.llm.prediction_engine").predict("private browser context")
		helpers.assert_eq(chat_calls, 0,
			"the URL toggle must suppress the backend call, not only change a menu tick")
		restore()
	end)
end)

helpers.describe("LLM trigger settings: tray reachability", function()
	helpers.it("renders the declared trigger submenu and changes a privacy filter", function()
		local settings, storage = load_settings()
		local i18n = require("infra.i18n")
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		local menu = menu_builder.build({
			llm = {
				is_enabled = function() return true end,
				toggle = function() return true end,
				get_models = function() return {} end,
				get_current_model = function() return nil end,
			},
		})

		local wanted_parent = i18n.get("menu.llm.trigger_menu_title")
		local wanted_filter = i18n.get("menu.llm.disable_password_fields")
		local parent, filter = nil, nil
		local function walk(rows)
			for _, row in ipairs(rows or {}) do
				if row.title == wanted_parent and type(row.menu) == "table" then parent = row end
				if row.title == wanted_filter then filter = row end
				if type(row.menu) == "table" then walk(row.menu) end
			end
		end
		walk(menu)
		helpers.assert_not_nil(parent,
			"a supported setting without a reachable Linux control is not feature parity")
		helpers.assert_not_nil(filter)
		helpers.assert_eq(type(filter.fn), "function")
		filter.fn()
		helpers.assert_eq(storage.get("llm.trigger.secure_filter_enabled"), false)
		helpers.assert_eq(settings.get("secure_filter_enabled"), false)
		restore()
	end)
end)
