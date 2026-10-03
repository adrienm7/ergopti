--- tests/unit/modules/llm/test_trigger_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Trigger and Privacy Controls
--- DESCRIPTION:
--- Proves that the five supported trigger settings are durable and that
--- the prediction engine consumes them instead of advertising inert controls.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

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
	local storage = PreferencesFixture.new({ initial = initial, writes_fail = writes_fail })
	replace("infra.llm_preferences", storage)
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
		engine.init({ scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end })
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






-- ====================================================
-- ====================================================
-- ======= 2/ Shared Automatic Trigger Commands =======
-- ====================================================
-- ====================================================

--- Reads independent combinations without deriving expectations from setters.
--- @return table corpus
local function trigger_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/automatic_trigger_controls.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

--- Exercises real menu projection and the manifest-backed durable setting owner.
--- @param options table Fixture settings, current admission and writer refusal.
--- @param body function Assertions outside production callback guards.
local function with_trigger_menu(options, body)
	local corpus = trigger_corpus()
	local initial = {["llm.future_trigger_parameter"] = 42, ["llm.profiles.num_predictions"] = options.count or 1}
	for index, row in ipairs(corpus.rows) do initial["llm.trigger." .. row.native] = options.states[index] end
	local settings, storage = load_settings(initial)
	replace("modules.llm.profile_settings", nil)
	local profiles = require("modules.llm.profile_settings")
	local observed = {writes = 0, redraws = 0}
	local write = storage.set
	storage.set = function(path, value)
		observed.writes = observed.writes + 1
		if options.refusal == "false" then return false end
		if options.refusal == "nil" then return nil end
		if options.refusal == "throw" then error("actual trigger writer refused") end
		return write(path, value)
	end
	if options.label or options.first then
		local renderer = assert(require("menu.renderer").new({
			platform = "linux",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = function(raw)
				local root = assert(require("json").decode(raw))
				if options.label then root.llm_trigger_menu[2].i18n = options.label end
				if options.first then
					local row = table.remove(root.llm_trigger_menu, 2)
					table.insert(root.llm_trigger_menu, 1, row)
				end
				return root
			end,
			i18n = require("infra.i18n"), logger = require("logger.shim"),
		}))
		replace("infra.manifest_menu", renderer)
	end
	replace("ui.menu.menu_builder", nil)
	local menu = require("ui.menu.menu_builder").build({
		is_paused = function() return options.paused == true end,
		on_menu_changed = function() observed.redraws = observed.redraws + 1 end,
		llm = {
			is_enabled = function() return options.enabled ~= false end,
			toggle = function() return true end,
			get_models = function() return {} end,
			get_current_model = function() return nil end,
		},
	})
	local parent
	local function walk(rows)
		for _, row in ipairs(rows or {}) do
			if row.title == require("infra.i18n").get("menu.llm.trigger_menu_title") and type(row.menu) == "table" then parent = row end
			if row.menu then walk(row.menu) end
		end
	end
	walk(menu)
	local ok, err = xpcall(function() body(assert(parent), settings, storage, observed, profiles) end, debug.traceback)
	restore()
	if not ok then error(err, 0) end
end

--- Finds a native check by its expected translated identity.
--- @param parent table Actual trigger submenu.
--- @param key string Canonical translated label key.
--- @return table row
local function trigger_row(parent, key)
	for _, row in ipairs(parent.menu) do
		if row.title == require("infra.i18n").get(key) then return row end
	end
	error("actual trigger menu omitted " .. key)
end

helpers.describe("LLM shared automatic trigger controls", function()
	helpers.it("replays four bool pairs through actual durable controls (shared-automatic-triggers)", function()
		local corpus = trigger_corpus()
		helpers.assert_eq(#corpus.states, 4)
		for _, states in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				for index, expected in ipairs(corpus.rows) do
					with_trigger_menu({states = states, count = count}, function(parent, settings, storage, observed)
						local row = trigger_row(parent, expected.i18n)
						helpers.assert_eq(row.checked or false, states[index])
						helpers.assert_eq(row.disabled or false, false)
						helpers.assert_eq(row.fn(), true)
						helpers.assert_eq(settings.get(expected.native), not states[index])
						settings._reset()
						helpers.assert_eq(settings.get(expected.native), not states[index], "restart resolves acknowledged sparse value")
						helpers.assert_eq(storage.get("llm.future_trigger_parameter"), 42)
						local neighbor = corpus.rows[index == 1 and 2 or 1]
						helpers.assert_eq(settings.get(neighbor.native), states[index == 1 and 2 or 1])
						helpers.assert_eq(observed.writes, 1)
						helpers.assert_eq(observed.redraws, 1)
					end)
				end
			end
		end
	end)

	helpers.it("takes shared labels and reordering into actual projection (shared-automatic-triggers)", function()
		local corpus = trigger_corpus()
		with_trigger_menu({states = {false, true}, label = corpus.alternate_i18n, first = true}, function(parent, _, _, observed)
			helpers.assert_eq(parent.menu[1].title, require("infra.i18n").get(corpus.alternate_i18n))
			helpers.assert_true(parent.menu[2].menu ~= nil, "numeric debounce provider follows the reordered shared check")
			helpers.assert_eq(observed.writes, 0)
		end)
	end)

	helpers.it("reads current values and refuses stale commands after pause or master withdrawal (shared-automatic-triggers)", function()
		for _, expected in ipairs(trigger_corpus().rows) do
			local options = {states = {false, false}, count = 2}
			with_trigger_menu(options, function(parent, settings, storage, observed, profiles)
				local row = trigger_row(parent, expected.i18n)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(profiles.set("num_predictions", 1), true)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(settings.get(expected.native), false, "held callback toggles the effective current bool")
				local writes, redraws = observed.writes, observed.redraws
				options.paused = true
				helpers.assert_eq(row.fn(), false)
				options.paused = false
				options.enabled = false
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(observed.writes, writes)
				helpers.assert_eq(observed.redraws, redraws)
				helpers.assert_eq(storage.get("llm.future_trigger_parameter"), 42)
			end)
		end
	end)

	helpers.it("never redraws or publishes refused writes including thrown native errors (shared-automatic-triggers)", function()
		for _, expected in ipairs(trigger_corpus().rows) do
			for _, mode in ipairs({"false", "nil", "throw"}) do
				with_trigger_menu({states = {false, false}, refusal = mode}, function(parent, settings, storage, observed)
					local ok, receipt = pcall(trigger_row(parent, expected.i18n).fn)
					if mode == "throw" then helpers.assert_eq(ok, false) else helpers.assert_eq(ok, true); helpers.assert_eq(receipt, false) end
					helpers.assert_eq(settings.get(expected.native), false)
					helpers.assert_eq(storage.get("llm.trigger." .. expected.native), false)
					helpers.assert_eq(storage.get("llm.future_trigger_parameter"), 42)
					helpers.assert_eq(observed.writes, 1)
					helpers.assert_eq(observed.redraws, 0)
				end)
			end
		end
	end)
end)
