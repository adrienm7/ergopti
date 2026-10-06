--- tests/unit/ui/test_llm_menu_prediction_count.lua

--- ==============================================================================
--- MODULE: The AI Suggestion Count Rows (Linux tray)
--- DESCRIPTION:
--- The count rows (1 to 10 suggestions) read one locale key per plural form,
--- menu.llm.prediction_count_label_one for one and _other for every other count,
--- as macOS and Windows do. Linux showed bare numbers, and the two other drivers
--- injected an "s" after one shared key, a plural only French and English form.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the tray around an enabled LLM double.
--- @return table items
local function build()
	local mb = helpers.load_module("ui.menu.menu_builder")
	return mb.build({
		_version = "0.0.0-dev.12",
		llm = { is_enabled = function() return true end, toggle = function() return true end },
		on_quit = function() end,
		on_menu_changed = function() end,
	})
end

--- The AI submenu's rows.
--- @param items table Top-level tray rows.
--- @return table rows
local function ai_rows(items)
	local label = require("infra.i18n").get("menu.llm.title")
	for _, item in ipairs(items) do
		if item.title == label then return item.menu end
	end
	error("the tray has no AI submenu")
end

--- The row that opens the suggestion count choices, and its index.
--- @param rows table AI submenu rows.
--- @return table row, number index
local function count_row(rows)
	local current = require("modules.llm.profile_settings").get("num_predictions")
	local label = string.format(require("infra.i18n").get("menu.llm.num_predictions_label"), current)
	for index, row in ipairs(rows) do
		if row.title == label then return row, index end
	end
	error("the AI submenu has no suggestion count row labelled " .. label)
end

helpers.describe("tray (linux): the AI suggestion count", function()

	helpers.it("labels each count with the one/other plural keys (llm-count-plural)", function()
		local i18n = require("infra.i18n")
		local one = i18n.get("menu.llm.prediction_count_label_one")
		local other = i18n.get("menu.llm.prediction_count_label_other")
		helpers.assert_true(one:find("%d", 1, true) ~= nil, "the singular key must resolve, got: " .. one)
		helpers.assert_true(other:find("%d", 1, true) ~= nil, "the plural key must resolve, got: " .. other)
		local row = count_row(ai_rows(build()))
		helpers.assert_eq(type(row.menu), "table", "the count row opens its choices")
		helpers.assert_eq(#row.menu, 10, "one choice per count from 1 to 10")
		helpers.assert_eq(row.menu[1].title, string.format(one, 1), "one reads the singular key")
		for count = 2, 10 do
			helpers.assert_eq(row.menu[count].title, string.format(other, count),
				"every other count reads the plural key")
		end
	end)

	-- The count is a generation parameter on every driver: here the generation
	-- rows are inline, so it heads them, right above the temperature.
	helpers.it("heads the generation parameters, not the profile block (llm-count-row)", function()
		local i18n = require("infra.i18n")
		local rows = ai_rows(build())
		local _, index = count_row(rows)
		local next_row = rows[index + 1]
		helpers.assert_true(next_row ~= nil and type(next_row.title) == "string", "a row follows the count")
		helpers.assert_true(next_row.title:find(i18n.get("menu.llm.generation.temperature"), 1, true) == 1,
			"the first generation parameter after the count is the temperature, got: " .. tostring(next_row.title))
		local trigger_index = nil
		for position, row in ipairs(rows) do
			if row.title == i18n.get("menu.llm.trigger_menu_title") then trigger_index = position end
		end
		helpers.assert_true(trigger_index ~= nil, "the AI submenu draws its trigger row")
		helpers.assert_true(index > trigger_index,
			"the count sits with the generation parameters, below the trigger row, not beside the profile")
	end)

end)

-- The free numeric entry is a complete fixed tail, shared by debounce and all
-- four generation pickers. Its context and native publication owners stay local.
local NumericJson = require("json")
local NumericSandbox = require("test.config_unused_keys_contract").sandbox
local NumericRenderer = require("menu.renderer")
local NumericRoot = helpers.driver_root() .. "/../_shared/"
--- Reads an independent corpus or locale as exact physical bytes.
--- @param path string
--- @return string
local function numeric_read(path)
	local handle = assert(io.open(path, "rb"))
	local bytes = handle:read("*a")
	handle:close()
	return bytes
end
local NumericCorpus = NumericJson.decode(numeric_read(NumericRoot .. "tests/corpus/menus/linux_numeric_custom_tail.json"))

-- A full cache snapshot restores transitive native owners as well as explicitly
-- injected presentation ports. The settings/publisher are the real modules.
--- @param options table|nil Native presentation mutations.
--- @param exercise function Actual rendered-owner assertions.
local function with_numeric_menu(options, exercise)
	options = options or {}
	local prompt_preload = package.preload["ui.numeric_prompt.bridge"]
	local loaded = {}
	for key, value in pairs(package.loaded) do loaded[key] = value end
	local path = os.tmpname()
	local initial = "[llm]\nenabled = true\n[llm.generation]\ntemperature = 0.7\ncontext_length = 1600\nmin_words = 3\nmax_words = 10\n[llm.trigger]\ndebounce_ms = 300\n[future]\nkeep = \"foreign\"\n"
	NumericSandbox.write_bytes(path, initial)
	local ok, err = xpcall(function()
		for name in pairs(package.loaded) do
			if name:match("^modules%.llm%.") or name:match("^infra%.llm_") then package.loaded[name] = nil end
		end
		package.loaded["toml_codec.writer"] = nil
		local writer = require("toml_codec.writer")
		package.loaded["infra.config_paths"] = { config = function() return path end }
		local locale = options.locale or "en"
		local strings = NumericJson.decode(numeric_read(NumericRoot .. "data/locales/" .. locale .. ".json"))
		local translate = { get = function(key) return strings[key] or key end,
			section = function(key) return strings[key] or key end, get_locale = function() return locale end }
		setmetatable(translate, { __index = loaded["infra.i18n"] })
		package.loaded["infra.i18n"] = translate
		local renderer = assert(NumericRenderer.new({ platform = options.platform or "linux",
			manifest_path = function() return NumericRoot .. "modules/menu/menu_manifest.json" end, json_decode = NumericJson.decode,
			i18n = translate, logger = require("logger.shim") }))
		local declaration = renderer.get_array("llm_numeric_custom_rows")
		if options.mutate then options.mutate(declaration) end
		package.loaded["infra.manifest_menu"] = renderer
		local log = { prompts = {}, changed = 0 }
		package.loaded["ui.numeric_prompt.bridge"] = { ask = function(spec, webview)
			log.prompts[#log.prompts + 1] = { spec = spec, webview = webview }
		end }
		if options.prompt_missing then
			package.loaded["ui.numeric_prompt.bridge"] = nil
			package.preload["ui.numeric_prompt.bridge"] = function() error("independent missing native dialog owner") end
		end
		local webview = { show = function() return false end }
		local paused = options.paused == true
		local ctx = { _version = "0.0.0-dev.12", llm = {
			is_enabled = function() return true end, toggle = function() return true end },
			paused = paused, is_paused = function() return paused end,
			webview = webview, on_quit = function() end,
			on_menu_changed = function() log.changed = log.changed + 1 end }
		local mb = helpers.load_module("ui.menu.menu_builder")
		local rendered = mb.build(ctx)
		exercise({ rows = rendered, declaration = declaration, renderer = renderer, strings = strings,
			log = log, path = path, initial = initial, webview = webview,
			writer = writer, settings = require("modules.llm.settings"), trigger = require("modules.llm.trigger_settings"),
			set_paused = function(value) paused = value; ctx.paused = value end,
			rebuild = function() return mb.build(ctx) end })
	end, debug.traceback)
	package.preload["ui.numeric_prompt.bridge"] = prompt_preload
	os.remove(path)
	os.remove(path .. ".bak")
	os.remove(path .. ".tmp")
	for key in pairs(package.loaded) do if loaded[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(loaded) do package.loaded[key] = value end
	helpers.assert_true(ok, tostring(err))
end
--- Finds the native numeric picker by its existing translated heading.
--- @param rows table|nil
--- @param key string
--- @param strings table
--- @return table|nil
local function numeric_picker(rows, key, strings)
	local prefix = strings[key]
	if prefix then prefix = prefix:match("^(.-)%%[ds]") or prefix end
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and prefix and row.title:sub(1, #prefix) == prefix
			and type(row.menu) == "table" then return row end
		local found = numeric_picker(row.menu, key, strings)
		if found then return found end
	end
end
--- Returns the last native preset child and its complete sibling list.
--- @param fixture table
--- @param context table Handwritten independent native context.
--- @return table, table
local function numeric_tail(fixture, context)
	local picker = assert(numeric_picker(fixture.rows, context.key, fixture.strings), "missing native numeric picker")
	return picker.menu[#picker.menu], picker.menu
end

helpers.describe("tray (linux): declared free numeric tails", function()
	helpers.it("matches the independent two-row declaration without hiding preset choices", function()
		with_numeric_menu({}, function(f)
			helpers.assert_eq(f.declaration, NumericCorpus.declaration)
			for _, context in ipairs(NumericCorpus.contexts) do
				local row, choices = numeric_tail(f, context)
				helpers.assert_true(#choices > 2)
				helpers.assert_eq(choices[#choices - 1].title, "-")
				helpers.assert_eq(row.title, "Other value…")
				helpers.assert_type(row.fn, "function")
			end
		end)
	end)
	for _, context in ipairs(NumericCorpus.contexts) do
		helpers.it("delivers the real " .. context.name .. " prompt and durable on-save receipt", function()
			with_numeric_menu({}, function(f)
				local row = numeric_tail(f, context)
				helpers.assert_nil(row.fn(), "the existing native prompt launch acknowledges with nil")
				helpers.assert_eq(#f.log.prompts, 1)
				local prompt = f.log.prompts[1]
				helpers.assert_true(rawequal(prompt.webview, f.webview))
				helpers.assert_eq(prompt.spec.min, context.min)
				helpers.assert_eq(prompt.spec.max, context.max)
				helpers.assert_eq(prompt.spec.value, context.current)
				helpers.assert_true(prompt.spec.on_save(context.candidate))
				local owner = context.name == "debounce_ms" and f.trigger or f.settings
				helpers.assert_eq(owner.get(context.name), context.saved)
				helpers.assert_eq(f.log.changed, 1)
				local written = NumericSandbox.read_bytes(f.path)
				helpers.assert_contains(written, 'keep = "foreign"')
				helpers.assert_true(written ~= f.initial)
			end)
		end)
		helpers.it("retains actual " .. context.name .. " writer refusal and retry", function()
			with_numeric_menu({}, function(f)
				local row = numeric_tail(f, context)
				row.fn()
				local spec = f.log.prompts[1].spec
				f.writer.refuse_writes(f.path, "independent numeric publication refusal")
				helpers.assert_true(spec.on_save(context.candidate) == false)
				helpers.assert_eq(NumericSandbox.read_bytes(f.path), f.initial)
				helpers.assert_eq(f.log.changed, 0)
				helpers.assert_type(f.writer.write_refusal(f.path), "string")
				package.loaded["toml_codec.writer"] = nil
				package.loaded["infra.llm_preferences"] = nil
				helpers.assert_true(spec.on_save(context.candidate))
				helpers.assert_eq(f.log.changed, 1)
			end)
		end)
	end
	helpers.it("keeps the native missing-dialog refusal without manufacturing an acknowledgement", function()
		with_numeric_menu({ prompt_missing = true }, function(f)
			for _, context in ipairs(NumericCorpus.contexts) do
				local row = numeric_tail(f, context)
				helpers.assert_nil(row.fn())
			end
			helpers.assert_eq(#f.log.prompts, 0)
			helpers.assert_eq(f.log.changed, 0)
			helpers.assert_eq(NumericSandbox.read_bytes(f.path), f.initial)
		end)
	end)
	helpers.it("keeps cancellation effect-free and generation prompts read the live value", function()
		with_numeric_menu({}, function(f)
			local context = NumericCorpus.contexts[2]
			local row = numeric_tail(f, context)
			helpers.assert_true(f.settings.set("temperature", 0.9))
			local before = NumericSandbox.read_bytes(f.path)
			row.fn()
			helpers.assert_eq(f.log.prompts[1].spec.value, 0.9)
			helpers.assert_eq(NumericSandbox.read_bytes(f.path), before)
			helpers.assert_eq(f.log.changed, 0)
		end)
	end)
	helpers.it("uses shared source order and caption rather than native constants", function()
		with_numeric_menu({ mutate = function(rows)
			rows[1], rows[2] = rows[2], rows[1]
			rows[1].i18n = "button.cancel"
		end }, function(f)
			for _, context in ipairs(NumericCorpus.contexts) do
				local picker = assert(numeric_picker(f.rows, context.key, f.strings))
				-- Normalization removes the declared terminal separator; it never
				-- inserts the former native leading separator or original caption.
				helpers.assert_eq(picker.menu[#picker.menu].title, f.strings["button.cancel"])
				helpers.assert_true(picker.menu[#picker.menu - 1].title ~= "-")
			end
		end)
	end)
	helpers.it("does not fabricate a native fallback when the template is withdrawn", function()
		with_numeric_menu({ mutate = function(rows) for index = #rows, 1, -1 do rows[index] = nil end end }, function(f)
			for _, context in ipairs(NumericCorpus.contexts) do
				local row = numeric_tail(f, context)
				helpers.assert_true(row.title ~= "Other value…")
				helpers.assert_true(row.title ~= "-")
			end
		end)
	end)
	helpers.it("refuses every retained prompt callback after declaration withdrawal", function()
		with_numeric_menu({}, function(f)
			local held = {}
			for _, context in ipairs(NumericCorpus.contexts) do held[#held + 1] = numeric_tail(f, context) end
			for index = #f.declaration, 1, -1 do f.declaration[index] = nil end
			for _, row in ipairs(held) do helpers.assert_true(row.fn() == false) end
			helpers.assert_eq(#f.log.prompts, 0)
			helpers.assert_eq(NumericSandbox.read_bytes(f.path), f.initial)
		end)
	end)
	helpers.it("honors shared platform hiding in the actual Linux providers", function()
		with_numeric_menu({ mutate = function(rows) for _, row in ipairs(rows) do row.platforms = { "hs" } end end }, function(f)
			for _, context in ipairs(NumericCorpus.contexts) do
				local row = numeric_tail(f, context)
				helpers.assert_true(row.title ~= "Other value…")
			end
		end)
	end)
	helpers.it("keeps the existing paused parent effect-free", function()
		with_numeric_menu({ paused = true }, function(f)
			local parent
			for _, row in ipairs(f.rows) do
				if row.title:find(f.strings["menu.llm.title"], 1, true) == 1 then parent = row end
			end
			helpers.assert_not_nil(parent)
			helpers.assert_true(parent.disabled == true)
			helpers.assert_nil(parent.menu)
			helpers.assert_nil(parent.fn)
			helpers.assert_eq(#f.log.prompts, 0)
			helpers.assert_eq(NumericSandbox.read_bytes(f.path), f.initial)
		end)
	end)
	for locale, expected in pairs(NumericCorpus.captions) do
		helpers.it("uses the original " .. locale .. " caption in all five contexts", function()
			with_numeric_menu({ locale = locale }, function(f)
				helpers.assert_eq(f.strings["menu.llm.generation.custom_value"], expected)
				for _, context in ipairs(NumericCorpus.contexts) do
					local row = numeric_tail(f, context)
					helpers.assert_eq(row.title, expected)
				end
			end)
		end)
	end
	helpers.it("does not promise the Linux preset tail on the two direct-dialog platforms", function()
		for _, platform in ipairs({ "hs", "ahk" }) do
			with_numeric_menu({ platform = platform }, function(f)
				local calls = 0
				local rows = f.renderer.template_rows("llm_numeric_custom_rows", {
					llm_numeric_custom_value = function() calls = calls + 1 end })
				helpers.assert_eq(rows, {})
				helpers.assert_eq(calls, 0)
			end)
		end
	end)
end)
