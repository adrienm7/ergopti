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
		helpers.assert_eq(rows[1].segments[2].text, chrome.label_gap .. "Alt+1")
		helpers.assert_eq(rows[1].selected, false)
		helpers.assert_eq(rows[2].segments[1].text, "second")
		helpers.assert_eq(rows[2].segments[2].text, chrome.label_gap .. "Alt+2")
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
		["llm.display.show_info_bar"] = options.selected,
		["llm.display.streaming_multi"] = options.progressive,
		["llm.profiles.num_predictions"] = options.count,
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
	local observed = { writes = 0, redraws = 0, active = true, paused = false }
	local native_set = storage.set
	storage.set = function(...)
		observed.writes = observed.writes + 1
		if options.refusal_mode == "nil" then return nil end
		if options.refusal_mode == "throw" then error("owned writer refused") end
		return native_set(...)
	end
	local ok, err = xpcall(function()
		local items = helpers.load_module("ui.menu.menu_builder").build({
			_version = "0.0.0-dev.12",
			llm = { is_enabled = function() return observed.active end, toggle = function() return true end },
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
