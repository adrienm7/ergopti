--- tests/unit/modules/llm/test_display_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Suggestion Presentation
--- DESCRIPTION:
--- Proves that display controls persist and that the headless suggestion model
--- turns parsed predictions into selectable, labelled renderer rows.
--- ==============================================================================

local helpers = require("tests.helpers")
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
	package.loaded["modules.llm.display_settings"] = nil
	local settings = require("modules.llm.display_settings")
	settings._reset()
	return settings, storage
end

helpers.describe("LLM display settings: durable manifest-backed values", function()
	helpers.it("reads all four defaults without persisting them", function()
		local settings, storage = load_settings()
		local manifest = require("infra.manifest_reader")
		for _, name in ipairs({ "pred_indent", "show_info_bar", "streaming", "streaming_multi" }) do
			helpers.assert_eq(settings.get(name), manifest.default_for("llm.display." .. name))
			helpers.assert_true(not storage.has("llm.display." .. name))
		end
		restore()
	end)

	helpers.it("persists accepted changes and refuses invalid indentation", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.set("streaming", false))
		helpers.assert_eq(storage.get("llm.display.streaming"), false)
		helpers.assert_true(settings.set("pred_indent", -7))
		for _, invalid in ipairs({ -8, 8, 1.5, "2" }) do
			helpers.assert_eq(settings.set("pred_indent", invalid), false)
		end
		helpers.assert_eq(settings.get("pred_indent"), -7)
		restore()
	end)

	helpers.it("does not publish a write that failed", function()
		local settings = load_settings({ ["llm.display.show_info_bar"] = false }, true)
		helpers.assert_eq(settings.get("show_info_bar"), false)
		helpers.assert_eq(settings.set("show_info_bar", true), false)
		helpers.assert_eq(settings.get("show_info_bar"), false)
		restore()
	end)
end)

helpers.describe("LLM suggestion overlay: headless row decisions", function()
	helpers.it("labels alternatives, marks the selection, and appends optional info", function()
		replace("modules.llm.display_settings", {
			get = function(name)
				if name == "pred_indent" then return 2 end
				if name == "show_info_bar" then return true end
			end,
		})
		package.loaded["ui.tooltip.llm"] = nil
		local overlay = require("ui.tooltip.llm")
		local rows = overlay.build_rows({
			{ to_type = "first" },
			{ to_type = "second" },
		}, 2, {
			model = "qwen:4b",
			profile = "batch_advanced",
			validation_modifiers = { "alt" },
		})
		local chrome = require("ui.tooltip.config").llm_line()
		helpers.assert_eq(rows[1].segments[1].text, "first")
		helpers.assert_eq(rows[1].label, "Alt+1")
		helpers.assert_eq(rows[1].selected, false)
		helpers.assert_eq(rows[2].segments[1].text, "second")
		helpers.assert_eq(rows[2].label, "Alt+2")
		helpers.assert_eq(rows[2].selected, true)
		-- A positive indentation pushes the selected line, mark included.
		helpers.assert_eq(rows[2].prefix, "  " .. chrome.mark)
		helpers.assert_eq(rows[1].prefix, chrome.align)
		helpers.assert_contains(rows[3].text, "qwen:4b")
		helpers.assert_contains(rows[3].text, "2/2")
		restore()
	end)

	helpers.it("redraws selection through an injected renderer", function()
		replace("modules.llm.display_settings", {
			get = function(name) return name == "pred_indent" and 0 or false end,
		})
		package.loaded["ui.tooltip.llm"] = nil
		local overlay = require("ui.tooltip.llm")
		local frames = {}
		local renderer = {
			show = function(rows) frames[#frames + 1] = rows; return true end,
			hide = function() return true end,
			is_visible = function() return true end,
		}
		helpers.assert_true(overlay.init({ style = {}, renderer = renderer }))
		helpers.assert_true(overlay.show({ { to_type = "one" }, { to_type = "two" } }, {}))
		helpers.assert_true(overlay.select(2))
		helpers.assert_eq(#frames, 2)
		helpers.assert_eq(frames[2][1].selected, false)
		helpers.assert_eq(frames[2][2].selected, true)
		overlay.hide()
		helpers.assert_eq(overlay.is_visible(), false)
		restore()
	end)
end)





-- ========================================
-- ========================================
-- ======= 3/ Shared Info Bar Check =======
-- ========================================
-- ========================================

--- Builds the real AI display menu over its existing acknowledged settings owner.
--- @param options table Fixture state, writer refusal and shared label mutation.
--- @param callback function Observations asserted outside native callbacks.
local function with_info_menu(options, callback)
	local names = { "infra.llm_preferences", "modules.llm.display_settings", "modules.llm.profile_settings", "infra.manifest_menu", "ui.menu.menu_builder" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local settings, storage = load_settings({
		["llm.enabled"] = options.stored_enabled ~= false,
		["llm.display.show_info_bar"] = options.selected,
		["llm.display.streaming_multi"] = options.progressive,
		["llm.display.streaming"] = options.streaming,
		["llm.profiles.num_predictions"] = options.count,
		["llm.display.pred_indent"] = options.indent or 0,
		["llm.future_field"] = 42,
	}, options.refused)
	package.loaded["modules.llm.profile_settings"] = nil
	local profiles = require("modules.llm.profile_settings")
	profiles._reset()
	local renderer = assert(require("menu.renderer").new({
		platform = "linux",
		manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
		json_decode = function(raw)
			local root = assert(require("json").decode(raw))
			if options.label then root.llm_display_menu[2].i18n = options.label end
			for index, row in ipairs(root.llm_display_menu) do
				if row.id == "llm_show_all" then
					if options.show_all_label then row.i18n = options.show_all_label end
					if options.show_all_first then table.remove(root.llm_display_menu, index); table.insert(root.llm_display_menu, 1, row) end
					break
				end
			end
			if options.info_last then
				local info = table.remove(root.llm_display_menu, 2)
				table.insert(root.llm_display_menu, info)
			end
			return root
		end,
		i18n = require("infra.i18n"), logger = require("logger.shim"),
	}))
	package.loaded["infra.manifest_menu"] = renderer
	local observed = { writes = 0, redraws = 0, active = true, paused = false, backend = options.backend or "ollama", revision = 0 }
	local native_set, native_many = storage.set, storage.set_many
	local function admission_boundary()
		observed.writes = observed.writes + 1
		if observed.source_race then
			observed.source_race = false
			assert(native_set("llm.enabled", false))
		end
		if options.refusal_mode == "nil" then return false, nil end
		if options.refusal_mode == "throw" then error("owned writer refused") end
		return true
	end
	storage.set = function(...)
		local admitted, result = admission_boundary()
		if not admitted then return result end
		return native_set(...)
	end
	storage.set_many = function(...)
		local admitted, result = admission_boundary()
		if not admitted then return result end
		return native_many(...)
	end
	local ok, err = xpcall(function()
		local items = helpers.load_module("ui.menu.menu_builder").build({
			_version = "0.0.0-dev.12",
			llm = { is_enabled = function() return observed.active end, toggle = function() return true end,
				get_backend = function() return observed.backend end,
				streaming_revision = function() return observed.revision end },
			on_quit = function() end,
			is_paused = function() return observed.paused end,
			on_menu_changed = function() observed.redraws = observed.redraws + 1 end,
		})
		local title = require("infra.i18n").get("menu.llm.display_menu_title")
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if row.title == title and row.menu then return row end
				local nested = find(row.menu)
				if nested then return nested end
			end
		end
		callback(assert(find(items), "the actual AI display submenu must be present"), settings, storage, observed, profiles)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	restore()
	if not ok then error(err, 0) end
end

--- Loads a historical expectation independently of the generated menu declaration.
--- @return table corpus
local function info_bar_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/info_bar_control.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared Info Bar check", function()
	helpers.it("replays both states through the actual durable display owner (shared-info-bar)", function()
		local corpus = info_bar_corpus()
		helpers.assert_eq(#corpus.states, 2)
		for _, selected in ipairs(corpus.states) do
			with_info_menu({selected = selected}, function(parent, settings, storage, observed)
				local row = parent.menu[1]
				helpers.assert_eq(row.title, require("infra.i18n").get(corpus.row.i18n))
				helpers.assert_eq(row.checked or false, selected)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(settings.get("show_info_bar"), not selected)
				helpers.assert_eq(storage.get("llm.display.show_info_bar", settings.get("show_info_bar")), not selected)
				helpers.assert_eq(storage.get("llm.future_field"), 42)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, 1)
				settings._reset()
				helpers.assert_eq(settings.get("show_info_bar"), not selected, "restart reads the acknowledged sparse value")
			end)
		end
	end)

	helpers.it("moves the actual check after its shared remaining provider (shared-info-bar)", function()
		with_info_menu({selected = true, info_last = true}, function(parent, _, _, observed)
			helpers.assert_eq(parent.menu[#parent.menu].title, require("infra.i18n").get(info_bar_corpus().row.i18n))
			helpers.assert_true(#parent.menu > 1)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
		end)
	end)

	helpers.it("refuses an ordinary native click without optimistic redraw (shared-info-bar)", function()
		with_info_menu({selected = true, refused = true}, function(parent, settings, storage, observed)
			local receipt = parent.menu[1].fn()
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(observed.redraws, 0)
			helpers.assert_eq(settings.get("show_info_bar"), true)
			helpers.assert_eq(storage.get("llm.display.show_info_bar"), true)
			helpers.assert_eq(storage.get("llm.future_field"), 42)
			helpers.assert_eq(receipt, false)
		end)
	end)

	helpers.it("reads the shared label and retains exact state on refusal (shared-info-bar)", function()
		local corpus = info_bar_corpus()
		with_info_menu({selected = true, refused = true, label = corpus.alternate_i18n}, function(parent, settings, storage, observed)
			local row = parent.menu[1]
			helpers.assert_eq(row.title, require("infra.i18n").get(corpus.alternate_i18n))
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(settings.get("show_info_bar"), true)
			helpers.assert_eq(storage.get("llm.display.show_info_bar"), true)
			helpers.assert_eq(storage.get("llm.future_field"), 42)
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(observed.redraws, 0)
		end)
	end)
end)





-- ==================================
-- ==================================
-- ======= 4/ Show-All Parity =======
-- ==================================
-- ==================================

--- Reads fixed progressive and show-all semantics independently of native code.
--- @return table
local function show_all_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/show_all_control.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

--- Finds the declared checkbox after Linux's real tray projection.
--- @param parent table
--- @param key string
--- @return table
local function show_all_row(parent, key)
	local title = require("infra.i18n").get(key)
	for _, row in ipairs(parent.menu) do if row.title == title then return row end end
	error("the real display submenu omitted " .. key)
end

helpers.describe("LLM shared Show-all check", function()
	helpers.it("replays both canonical polarities and persists only an admitted change (shared-show-all)", function()
		local corpus = show_all_corpus()
		helpers.assert_eq(#corpus.states, 2)
		for _, expected in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				with_info_menu({selected = true, progressive = expected.progressive, count = count}, function(parent, settings, storage, observed)
					local row = show_all_row(parent, corpus.row.i18n)
					helpers.assert_eq(row.checked or false, expected.show_all)
					helpers.assert_eq(row.disabled == true, count < 2)
					helpers.assert_eq(row.fn(), count >= 2)
					local value = expected.progressive
					if count >= 2 then value = not expected.progressive end
					helpers.assert_eq(settings.get("streaming_multi"), value)
					helpers.assert_eq(storage.get("llm.future_field"), 42)
					helpers.assert_eq(observed.writes, count >= 2 and 1 or 0)
					helpers.assert_eq(observed.redraws, count >= 2 and 1 or 0)
					settings._reset()
					helpers.assert_eq(settings.get("streaming_multi"), value, "restart retains canonical polarity")
				end)
			end
		end
	end)

	helpers.it("uses the declared Show-all label and placement (shared-show-all)", function()
		local corpus = show_all_corpus()
		with_info_menu({selected = true, progressive = true, count = 2, show_all_label = corpus.alternate_i18n, show_all_first = true}, function(parent)
			helpers.assert_eq(parent.menu[1].title, require("infra.i18n").get(corpus.alternate_i18n))
			helpers.assert_eq(parent.menu[1].checked or false, false)
			helpers.assert_eq(parent.menu[2].title, require("infra.i18n").get("menu.llm.show_info_bar"))
		end)
	end)

	helpers.it("refuses a held callback after current count or native readiness is withdrawn (shared-show-all)", function()
		with_info_menu({selected = true, progressive = true, count = 2}, function(parent, settings, storage, observed, profiles)
			local row = show_all_row(parent, show_all_corpus().row.i18n)
			helpers.assert_true(profiles.set("num_predictions", 1))
			local before = observed.writes
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, before)
			helpers.assert_true(profiles.set("num_predictions", 2))
			before = observed.writes
			observed.paused = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, before)
			observed.paused = false
			observed.active = false
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(settings.get("streaming_multi"), true)
			helpers.assert_eq(observed.writes, before)
			helpers.assert_eq(observed.redraws, 0)
		end)
	end)

	helpers.it("keeps durable, runtime and menu state after false, nil or throwing writers (shared-show-all)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_info_menu({selected = true, progressive = true, count = 2, refused = mode == "false", refusal_mode = mode}, function(parent, settings, storage, observed)
				local row = show_all_row(parent, show_all_corpus().row.i18n)
				local ok, result = pcall(row.fn)
				helpers.assert_true(not ok or result == false, "a refusal cannot acknowledge success")
				helpers.assert_eq(settings.get("streaming_multi"), true)
				helpers.assert_eq(storage.get("llm.display.streaming_multi"), true)
				helpers.assert_eq(storage.get("llm.future_field"), 42)
				helpers.assert_eq(observed.redraws, 0)
				helpers.assert_eq(row.checked or false, false)
			end)
		end
	end)
end)





-- =========================================
-- =========================================
-- ======= 5/ Shared Streaming Check =======
-- =========================================
-- =========================================

helpers.describe("LLM token streaming live admission", function()
	for _, condition in ipairs({ "paused", "off", "backend", "retired source", "restored runtime owner" }) do
		helpers.it("refuses an existing callback after " .. condition .. " (shared-token-streaming)", function()
			with_info_menu({selected = true, progressive = true, streaming = false, count = 2}, function(parent, settings, storage, observed)
				local row = show_all_row(parent, "menu.llm.show_streaming")
				if condition == "paused" then observed.paused = true end
				if condition == "off" then observed.active = false end
				if condition == "backend" then observed.backend = "api" end
				if condition == "retired source" then helpers.assert_true(storage.set("llm.display.show_info_bar", false)) end
				if condition == "restored runtime owner" then observed.revision = observed.revision + 2 end
				local before = observed.writes
				local result = row.fn()
				helpers.assert_eq(observed.writes, before, "a retained row cannot write after current admission changes")
				helpers.assert_eq(result, false)
				helpers.assert_eq(settings.get("streaming"), false)
				helpers.assert_eq(observed.redraws, 0)
			end)
		end)
	end
end)

--- Reads independent native capability and stale-command expectations.
--- @return table corpus
local function token_streaming_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/token_streaming_control.json"), "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return assert(require("json").decode(text))
end

helpers.describe("shared token streaming policy", function()
	helpers.it("replays independent capability and admission vectors (shared-token-streaming)", function()
		local policy = require("llm.display_policy")
		local corpus = token_streaming_corpus()
		helpers.assert_eq(#corpus.capabilities, 9)
		helpers.assert_eq(#corpus.cases, 15)
		for _, vector in ipairs(corpus.capabilities) do
			helpers.assert_eq(policy.streaming_capable(vector.platform, vector.backend), vector.capable)
		end
		for _, vector in ipairs(corpus.cases) do
			local expected, current = {}, {}
			for key, value in pairs(corpus.base) do expected[key], current[key] = value, value end
			for key, value in pairs(vector.expected or {}) do expected[key] = value end
			for key, value in pairs(vector.current) do current[key] = value end
			local decision = policy.streaming_intent(expected, current)
			helpers.assert_eq(decision.admitted, vector.admitted, vector.id)
			if vector.admitted then helpers.assert_eq(decision.value, vector.value, vector.id) end
		end
	end)
end)

helpers.describe("Linux acknowledged token streaming checkbox", function()
	helpers.it("refuses the actual settings writer after a canonical source race (shared-token-streaming)", function()
		with_info_menu({selected = true, progressive = true, streaming = false, count = 2}, function(parent, settings, storage, observed)
			local row = show_all_row(parent, token_streaming_corpus().row.i18n)
			observed.source_race = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(settings.get("streaming"), false)
			helpers.assert_eq(storage.get("llm.display.streaming"), false)
			helpers.assert_eq(storage.get_many({"llm.enabled"})["llm.enabled"], false)
			helpers.assert_eq(storage.has("llm.enabled"), false, "the external off choice remains sparse")
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(observed.redraws, 0)
		end)
	end)

	helpers.it("refuses a freshly rendered canonical-off/runtime-on checkbox (shared-token-streaming)", function()
		with_info_menu({selected = true, progressive = true, streaming = false, count = 2, stored_enabled = false}, function(parent, settings, storage, observed)
			local row = show_all_row(parent, token_streaming_corpus().row.i18n)
			helpers.assert_eq(row.disabled, true)
			if row.fn then helpers.assert_eq(row.fn(), false) end
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(settings.get("streaming"), false)
		end)
	end)

	helpers.it("keeps the durable boolean across restart and refreshes only after acknowledgement (shared-token-streaming)", function()
		for _, selected in ipairs({false, true}) do
			with_info_menu({selected = true, progressive = true, streaming = selected, count = 2}, function(parent, settings, storage, observed)
				local row = show_all_row(parent, token_streaming_corpus().row.i18n)
				helpers.assert_eq(row.checked or false, selected)
				helpers.assert_eq(row.disabled == true, false)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(settings.get("streaming"), not selected)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, 1)
				helpers.assert_eq(storage.get("llm.future_field"), 42)
				settings._reset()
				helpers.assert_eq(settings.get("streaming"), not selected)
				helpers.assert_eq(row.fn(), false, "a published revision retires its previous menu callback")
				helpers.assert_eq(observed.writes, 1)
			end)
		end
	end)

	helpers.it("does not redraw or publish after false, nil or throwing durable writers (shared-token-streaming)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_info_menu({selected = true, progressive = true, streaming = false, count = 2, refused = mode == "false", refusal_mode = mode}, function(parent, settings, storage, observed)
				local row = show_all_row(parent, token_streaming_corpus().row.i18n)
				local ok, result = pcall(row.fn)
				helpers.assert_true(not ok or result == false)
				helpers.assert_eq(settings.get("streaming"), false)
				helpers.assert_eq(storage.get("llm.display.streaming"), false)
				helpers.assert_eq(storage.get("llm.future_field"), 42)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, 0)
			end)
		end
	end)
end)





-- ============================================
-- ============================================
-- ======= 6/ Shared Indentation Choice =======
-- ============================================
-- ============================================

--- Reads independent signed values and retained-command expectations.
--- @return table corpus
local function indentation_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/indentation_control.json"), "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return assert(require("json").decode(text))
end

--- Finds the actual declared numeric submenu, including its selected caption.
--- @param parent table Native AI display submenu.
--- @return table row
local function indentation_row(parent)
	local label = require("infra.i18n").get("menu.llm.indent_label")
	for _, row in ipairs(parent.menu) do
		if type(row.title) == "string" and row.title:sub(1, #label) == label and row.menu then return row end
	end
	error("the actual indentation choice is absent")
end

helpers.describe("shared indentation choice", function()
	helpers.it("renders fifteen distinct translated offsets from the canonical numeric declaration (shared-indentation)", function()
		with_info_menu({selected = true, progressive = true, streaming = false, count = 3}, function(parent, settings)
			local row, corpus = indentation_row(parent), indentation_corpus()
			helpers.assert_eq(#row.menu, 15)
			for index, choice in ipairs(corpus.choices) do
				helpers.assert_eq(row.menu[index].title, choice.prefix .. require("infra.i18n").get(choice.i18n))
				helpers.assert_eq(row.menu[index].checked or false, choice.value == settings.get("pred_indent"))
			end
			helpers.assert_eq(row.disabled == true, false)
		end)
	end)

	for _, condition in ipairs({"paused", "off", "single", "retired source", "restored owner"}) do
		helpers.it("refuses a retained indentation choice after " .. condition .. " (shared-indentation)", function()
			with_info_menu({selected = true, progressive = true, streaming = false, count = 3}, function(parent, settings, storage, observed, profiles)
				local command = assert(indentation_row(parent).menu[1].fn)
				if condition == "paused" then observed.paused = true end
				if condition == "off" then observed.active = false end
				if condition == "single" then helpers.assert_true(profiles.set("num_predictions", 1)) end
				if condition == "retired source" then helpers.assert_true(storage.set("llm.display.show_info_bar", false)) end
				if condition == "restored owner" then observed.revision = observed.revision + 2 end
				local writes = observed.writes
				helpers.assert_eq(command(), false)
				helpers.assert_eq(observed.writes, writes)
				helpers.assert_eq(settings.get("pred_indent"), 0)
				helpers.assert_eq(observed.redraws, 0)
			end)
		end)
	end

	helpers.it("requires a strict writer ACK and preserves unrelated settings on refusal (shared-indentation)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_info_menu({selected = true, progressive = true, streaming = false, count = 3, refused = mode == "false", refusal_mode = mode}, function(parent, settings, storage, observed)
				local command = assert(indentation_row(parent).menu[1].fn)
				local ok, result = pcall(command)
				helpers.assert_true(not ok or result == false)
				helpers.assert_eq(settings.get("pred_indent"), 0)
				helpers.assert_eq(storage.get("llm.display.pred_indent", 0), 0)
				helpers.assert_eq(storage.get("llm.future_field"), 42)
				helpers.assert_eq(observed.redraws, 0)
			end)
		end
	end)

	helpers.it("persists each numeric boundary and zero across restart without reviving its held callback (shared-indentation)", function()
		for _, index in ipairs({1, 8, 15}) do
			with_info_menu({selected = true, progressive = true, streaming = false, count = 3, indent = 1}, function(parent, settings, storage, observed)
				local command = assert(indentation_row(parent).menu[index].fn)
				local value = indentation_corpus().choices[index].value
				helpers.assert_eq(command(), true)
				helpers.assert_eq(settings.get("pred_indent"), value)
				helpers.assert_eq(storage.get("llm.display.pred_indent", 0), value)
				settings._reset()
				helpers.assert_eq(settings.get("pred_indent"), value)
				helpers.assert_eq(observed.redraws, 1)
				helpers.assert_eq(command(), false)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(storage.get("llm.future_field"), 42)
			end)
		end
	end)

	helpers.it("keeps an external master withdrawal intact under the actual sparse CAS writer (shared-indentation)", function()
		with_info_menu({selected = true, progressive = true, streaming = false, count = 3}, function(parent, settings, storage, observed)
			local command = assert(indentation_row(parent).menu[1].fn)
			observed.source_race = true
			helpers.assert_eq(command(), false)
			helpers.assert_eq(settings.get("pred_indent"), 0)
			helpers.assert_eq(storage.get_many({"llm.enabled"})["llm.enabled"], false)
			helpers.assert_eq(storage.get("llm.future_field"), 42)
			helpers.assert_eq(observed.redraws, 0)
		end)
	end)

	helpers.it("replays independent shared multi-prediction admission and value vectors (shared-indentation)", function()
		local corpus, policy = indentation_corpus(), require("llm.display_policy")
		local owner, other = {}, {}
		for _, vector in ipairs(corpus.cases) do
			local expected, current = {}, {}
			for key, value in pairs(corpus.base) do expected[key], current[key] = value, value end
			for key, value in pairs(vector.expected or {}) do expected[key] = value end
			for key, value in pairs(vector.current) do current[key] = value end
			expected.owner = expected.owner == "owned" and owner or other
			current.owner = current.owner == "owned" and owner or other
			local decision = policy.indentation_intent(expected, current, vector.value, {-7,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,7})
			helpers.assert_eq(decision.admitted, vector.admitted, vector.id)
			if vector.admitted then helpers.assert_eq(decision.value, vector.value, vector.id) end
		end
	end)
end)

helpers.describe("LLM retained Info Bar admission", function()
	helpers.it("replays independent live-owner decisions without count or transport restrictions (shared-info-bar)", function()
		local corpus = info_bar_corpus()
		local owner, other = {}, {}
		for _, vector in ipairs(corpus.cases) do
			local expected, current = {}, {}
			for key, value in pairs(corpus.base) do expected[key], current[key] = value, value end
			for key, value in pairs(vector.expected or {}) do expected[key] = value end
			for key, value in pairs(vector.current) do current[key] = value end
			expected.owner = expected.owner == "owned" and owner or other
			current.owner = current.owner == "owned" and owner or other
			local decision = require("llm.display_policy").info_bar_intent(expected, current)
			helpers.assert_eq(decision.admitted, vector.admitted, vector.id)
			if vector.admitted then helpers.assert_eq(decision.value, vector.value, vector.id) end
		end
	end)

	for _, condition in ipairs({"paused", "master", "canonical master", "source", "runtime value", "generation", "backend"}) do
		helpers.it("refuses a retained actual native checkbox after " .. condition .. " (shared-info-bar)", function()
			with_info_menu({selected = true, count = 1, progressive = false}, function(parent, settings, storage, observed)
				local row = show_all_row(parent, info_bar_corpus().row.i18n)
				helpers.assert_eq(row.disabled == true, false)
				if condition == "paused" then observed.paused = true end
				if condition == "master" then observed.active = false end
				if condition == "canonical master" then assert(storage.set("llm.enabled", false)) end
				if condition == "source" then assert(storage.set("llm.generation.temperature", 0.9)) end
				if condition == "runtime value" then assert(settings.set("show_info_bar", false)) end
				if condition == "generation" then observed.revision = observed.revision + 1 end
				if condition == "backend" then observed.backend = "api" end
				local before = observed.writes
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(observed.writes, before)
				helpers.assert_eq(observed.redraws, 0)
				helpers.assert_eq(settings.get("show_info_bar"), condition ~= "runtime value")
				helpers.assert_eq(storage.get("llm.future_field"), 42)
			end)
		end)
	end

	helpers.it("uses actual sparse CAS when the source changes inside the writer (shared-info-bar)", function()
		with_info_menu({selected = true, count = 1}, function(parent, settings, storage, observed)
			local row = show_all_row(parent, info_bar_corpus().row.i18n)
			observed.source_race = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(observed.redraws, 0)
			helpers.assert_eq(storage.get("llm.enabled", false), false)
			helpers.assert_eq(storage.get("llm.display.show_info_bar"), true)
			helpers.assert_eq(settings.get("show_info_bar"), true)
		end)
	end)

	helpers.it("admits one API prediction and retires the acknowledged callback (shared-info-bar)", function()
		with_info_menu({selected = true, count = 1, progressive = false, streaming = false, backend = "api"}, function(parent, settings, storage, observed)
			-- The source is the same owner; the backend is captured when built.
			local row = show_all_row(parent, info_bar_corpus().row.i18n)
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(observed.writes, 1)
			helpers.assert_eq(observed.redraws, 1)
			helpers.assert_eq(settings.get("show_info_bar"), false)
			helpers.assert_eq(storage.get("llm.future_field"), 42)
		end)
	end)

	for _, mode in ipairs({"nil", "throw"}) do
		helpers.it("preserves exact native publication after " .. mode .. " writer refusal (shared-info-bar)", function()
			with_info_menu({selected = true, refusal_mode = mode}, function(parent, settings, storage, observed)
				local ok, result = pcall(show_all_row(parent, info_bar_corpus().row.i18n).fn)
				helpers.assert_true(not ok or result ~= true)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, 0)
				helpers.assert_eq(settings.get("show_info_bar"), true)
				helpers.assert_eq(storage.get("llm.display.show_info_bar"), true)
			end)
		end)
	end
end)
