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
		local settings, storage = load_settings({["llm.enabled"] = true, ["llm.models.selected"] = "ollama"})
		local i18n = require("infra.i18n")
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		local menu = menu_builder.build({
			is_paused = function() return false end,
			llm = {
				is_enabled = function() return true end,
				toggle = function() return true end,
				get_backend = function() return "ollama" end,
				streaming_revision = function() return 0 end,
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
	initial["llm.enabled"], initial["llm.models.selected"] = true, options.backend or "ollama"
	if options.privacy_states then
		initial["llm.trigger.url_bar_filter_enabled"] = options.privacy_states[1]
		initial["llm.trigger.secure_filter_enabled"] = options.privacy_states[2]
	end
	local settings, storage = load_settings(initial)
	replace("modules.llm.profile_settings", nil)
	local profiles = require("modules.llm.profile_settings")
	local engine
	if options.native_epoch then
		replace("modules.llm.prediction_engine", nil)
		replace("modules.llm.profiles", nil)
		replace("modules.llm.enable_admission", nil)
		engine = require("modules.llm.prediction_engine")
	end
	if options.preference_epoch then storage.generation = function() return options.preference_epoch end end
	local observed = {writes = 0, redraws = 0}
	local write = storage.set
	storage.set = function(path, value)
		observed.writes = observed.writes + 1
		if options.refusal == "false" then return false end
		if options.refusal == "nil" then return nil end
		if options.refusal == "throw" then error("actual trigger writer refused") end
		return write(path, value)
	end
	local many = storage.set_many
	storage.set_many = function(values, source)
		observed.writes = observed.writes + 1
		if options.refusal == "false" then return false end
		if options.refusal == "nil" then return nil end
		if options.refusal == "throw" then error("actual privacy writer refused") end
		if options.before_writer then options.before_writer(storage) end
		return many(values, source)
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
			is_enabled = function()
				if engine then return engine.is_enabled() end
				return options.enabled ~= false
			end,
			toggle = function() return true end,
			get_models = function() return {} end,
			get_current_model = function() return nil end,
			get_backend = function() return options.backend or "ollama" end,
			streaming_revision = options.epoch_port or not options.missing_epoch and function()
				if options.native_epoch then return engine.streaming_revision() end
				if options.invalid_epoch ~= nil then return options.invalid_epoch end
				return 0
			end or nil,
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
	local ok, err = xpcall(function() body(assert(parent), settings, storage, observed, profiles, engine) end, debug.traceback)
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


--- Reads the independent privacy declarations and boolean pairs.
--- @return table corpus
local function privacy_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/privacy_trigger_controls.json"), "rb"))
	local bytes = file:read("*a")
	file:close()
	return assert(require("json").decode(bytes))
end

helpers.describe("Shared privacy trigger native owners", function()
	helpers.it("publishes every bool pair sparsely, preserves neighbours and refuses repeated held callbacks (shared-privacy-triggers)", function()
		local corpus = privacy_corpus()
		helpers.assert_eq(#corpus.states, 4)
		for _, states in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				for index, expected in ipairs(corpus.rows) do
					with_trigger_menu({states = {false, false}, privacy_states = states, count = count}, function(parent, settings, storage, observed)
						local row = trigger_row(parent, expected.i18n)
						helpers.assert_eq(row.checked or false, states[index])
						helpers.assert_eq(row.disabled or false, false)
						helpers.assert_eq(row.fn(), true)
						helpers.assert_eq(settings.get(expected.linux), not states[index])
						settings._reset()
						helpers.assert_eq(settings.get(expected.linux), not states[index])
						local neighbor = corpus.rows[index == 1 and 2 or 1]
						helpers.assert_eq(settings.get(neighbor.linux), states[index == 1 and 2 or 1])
						helpers.assert_eq(storage.get("llm.future_trigger_parameter"), 42)
						helpers.assert_eq(observed.writes, 1)
						helpers.assert_eq(observed.redraws, 1)
						helpers.assert_eq(row.fn(), false)
						helpers.assert_eq(observed.writes, 1)
					end)
				end
			end
		end
	end)

	for _, condition in ipairs({"pause", "master withdrawn", "foreign source", "runtime disagreement"}) do
		helpers.it("refuses held privacy commands after " .. condition .. " (shared-privacy-triggers)", function()
			for _, expected in ipairs(privacy_corpus().rows) do
				local options = {states = {false, false}, privacy_states = {false, false}}
				with_trigger_menu(options, function(parent, settings, storage, observed)
					local row = trigger_row(parent, expected.i18n)
					if condition == "pause" then options.paused = true end
					if condition == "master withdrawn" then options.enabled = false end
					if condition == "foreign source" then
						storage.values["llm.future_trigger_parameter"] = 73
						storage.set("llm.display.show_info_bar", false)
					end
					if condition == "runtime disagreement" then storage.set(expected.path, true) end
					local writes = observed.writes
					helpers.assert_eq(row.fn(), false)
					helpers.assert_eq(observed.writes, writes)
					helpers.assert_eq(observed.redraws, 0)
					helpers.assert_eq(settings.get(expected.linux), false)
					helpers.assert_eq(storage.get("llm.future_trigger_parameter"), condition == "foreign source" and 73 or 42)
				end)
			end
		end)
	end

	helpers.it("keeps all refusal receipts strict and never publishes unknown source changes (shared-privacy-triggers)", function()
		for _, expected in ipairs(privacy_corpus().rows) do
			for _, mode in ipairs({"false", "nil", "throw"}) do
				with_trigger_menu({states = {false, false}, privacy_states = {false, false}, refusal = mode}, function(parent, settings, storage, observed)
					local ok, receipt = pcall(trigger_row(parent, expected.i18n).fn)
					if mode == "throw" then helpers.assert_eq(ok, false) else helpers.assert_eq(ok, true); helpers.assert_eq(receipt, false) end
					helpers.assert_eq(settings.get(expected.linux), false)
					helpers.assert_eq(storage.get(expected.path), false)
					helpers.assert_eq(storage.get("llm.future_trigger_parameter"), 42)
					helpers.assert_eq(observed.writes, 1)
					helpers.assert_eq(observed.redraws, 0)
				end)
			end
			with_trigger_menu({states = {false, false}, privacy_states = {false, false},
				before_writer = function(storage)
					storage.values["llm.future_trigger_parameter"] = 73
					storage.set("llm.display.show_info_bar", false)
				end}, function(parent, settings, storage, observed)
				helpers.assert_eq(trigger_row(parent, expected.i18n).fn(), false)
				helpers.assert_eq(storage.get(expected.path), false)
				helpers.assert_eq(settings.get(expected.linux), false)
				helpers.assert_eq(storage.get("llm.future_trigger_parameter"), 73)
				helpers.assert_eq(observed.redraws, 0)
			end)
		end
	end)
end)


helpers.describe("Shared privacy intent vectors", function()
	helpers.it("replays strict bool types, owner revisions and exact backend identities (shared-privacy-triggers)", function()
		local corpus, policy = privacy_corpus(), require("llm.trigger_policy")
		for _, vector in ipairs(corpus.vectors) do
			local expected, current = {}, {}
			for key, value in pairs(corpus.snapshot) do expected[key], current[key] = value, value end
			expected.owner = {}
			current.owner = expected.owner
			for key, value in pairs(vector.current or {}) do current[key] = value end
			for _, key in ipairs(vector.missing or {}) do current[key] = nil end
			if vector.new_owner then current.owner = {} end
			local actual = policy.intent(expected, current)
			helpers.assert_eq(actual.admitted, vector.admitted, vector.name)
			helpers.assert_eq(actual.value, vector.value, vector.name)
		end
	end)
end)


helpers.describe("Privacy callback native epoch retirement", function()
	helpers.it("retires held callbacks across a real pause and resume without changing canonical bytes (shared-privacy-triggers)", function()
		for _, expected in ipairs(privacy_corpus().rows) do
			local options = {states = {false, false}, privacy_states = {false, false}, native_epoch = true}
			with_trigger_menu(options, function(parent, settings, storage, observed, _, engine)
				local row = trigger_row(parent, expected.i18n)
				local revision = storage.generation()
				local _, before = storage.get_many({expected.path})
				local core = engine.streaming_revision()
				options.paused = true
				engine.on_pause_change(true)
				options.paused = false
				engine.on_pause_change(false)
				helpers.assert_true(engine.streaming_revision() > core)
				helpers.assert_eq(storage.generation(), revision)
				local _, after = storage.get_many({expected.path})
				helpers.assert_eq(after.content, before.content)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(observed.writes, 0)
				helpers.assert_eq(observed.redraws, 0)
				helpers.assert_eq(settings.get(expected.linux), false)
			end)
		end
	end)

	helpers.it("retires held callbacks across actual master withdrawal and readmission (shared-privacy-triggers)", function()
		with_trigger_menu({states = {false, false}, privacy_states = {false, false}, native_epoch = true,
			backend = "api"}, function(parent, settings, storage, observed, _, engine)
			local expected = privacy_corpus().rows[1]
			local row = trigger_row(parent, expected.i18n)
			local core = engine.streaming_revision()
			helpers.assert_eq(engine.disable(), true)
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(engine.enable(), true)
			helpers.assert_eq(engine.is_enabled(), true)
			helpers.assert_true(engine.streaming_revision() > core)
			local writes = observed.writes
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, writes)
			helpers.assert_eq(observed.redraws, 0)
			helpers.assert_eq(settings.get(expected.linux), false)
			helpers.assert_eq(storage.get("llm.future_trigger_parameter"), 42)
		end)
	end)

	helpers.it("keeps core and preference epochs independent at the floating point boundary (shared-privacy-triggers)", function()
		with_trigger_menu({states = {false, false}, privacy_states = {false, false}, native_epoch = true,
			preference_epoch = 9007199254740992}, function(parent, _, storage, observed, _, engine)
			local row = trigger_row(parent, privacy_corpus().rows[1].i18n)
			local core = engine.streaming_revision()
			engine.cancel()
			helpers.assert_eq(engine.streaming_revision(), core + 1)
			helpers.assert_eq(storage.generation(), 9007199254740992)
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
		end)
	end)

	helpers.it("refuses missing or invalid native epochs without a fallback (shared-privacy-triggers)", function()
		local cases = {{missing_epoch = true}, {invalid_epoch = "1"}, {invalid_epoch = -1},
			{invalid_epoch = 0.5}, {invalid_epoch = math.huge}, {invalid_epoch = 0 / 0},
			{epoch_port = setmetatable({}, {__call = function() return 0 end})}}
		for _, value in ipairs(cases) do
			value.states, value.privacy_states = {false, false}, {false, false}
			with_trigger_menu(value, function(parent, _, _, observed)
				local row = trigger_row(parent, privacy_corpus().rows[1].i18n)
				helpers.assert_eq(row.disabled, true)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(observed.writes, 0)
				helpers.assert_eq(observed.redraws, 0)
			end)
		end
	end)
end)
