--- tests/support/modules/hotstrings/terminators/terminator_settings_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_terminator_settings
--- DESCRIPTION:
--- Prelude shared by the test_terminator_settings_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local Codec = require("toml_codec")

--- Reads the independent custom-command identity used by each native provider.
--- @return table expected Canonical command expectation.
local function custom_command_expected()
	local path = require("infra.paths").shared("tests/corpus/menus/word_expander_custom_controls.json")
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	local corpus = assert(require("json").decode(text))
	assert(#corpus.rows == 1, "every independent custom command must be observed")
	return corpus.rows[1]
end

local SOURCE = '[hotstrings]\nunknown = "kept"\n\n[other]\nvalue = 42\n'

--- Runs body with the owner routed to a private config.toml, then puts the
--- shared catalogue and every module cache back.
--- @param source string|nil Initial config.toml bytes; nil is an absent file.
--- @param body function body(Settings, path, sandbox, Terminators)
local function with_settings(source, body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local Terminators = require("keymap.terminators")
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local baseline = nil
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			local paths = {}
			for key, value in pairs(require("infra.config_paths")) do paths[key] = value end
			paths.config = function() return path end
			package.loaded["infra.config_paths"] = paths
			for _, name in ipairs({ "infra.hotstring_preferences", "modules.hotstrings.terminator_settings" }) do
				package.loaded[name] = nil
			end
			local Settings = require("modules.hotstrings.terminator_settings")
			baseline = Settings.snapshot()
			local passed, failure = pcall(body, Settings, path, Sandbox, Terminators)
			assert(Settings.restore_configuration(baseline), "the shared catalogue must be put back")
			if not passed then error(failure, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

--- The default state the catalogue ships for one built-in delimiter.
--- @param Terminators table Shared catalogue.
--- @param key string Delimiter identity.
--- @return boolean
local function shipped(Terminators, key)
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key == key then return def.default_enabled ~= false end
	end
	error("no built-in delimiter " .. key)
end

--- Whether the catalogue holds a custom delimiter.
--- @param Terminators table Shared catalogue.
--- @param key string Delimiter identity.
--- @return boolean
local function has_custom(Terminators, key)
	for _, def in ipairs(Terminators.get_terminator_defs()) do
		if def.key == key and def.custom then return true end
	end
	return false
end

--- Independent stored-list vectors distinguish the admitted record from its
--- unusable neighbors, including an otherwise valid duplicate of the same key.
local DUPLICATE_RECORDS = {
	{
		name = "valid before invalid",
		owned = 1,
		rejected = 2,
		records = {
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
			{ key = "custom_¤", char = "ab", label = "invalid", consume = false, metadata = { note = "unusable" } },
		},
	},
	{
		name = "invalid before valid",
		owned = 2,
		rejected = 1,
		records = {
			{ key = "custom_¤", char = "ab", label = "invalid", consume = false, metadata = { note = "unusable" } },
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
		},
	},
	{
		name = "two valid definitions",
		owned = 1,
		rejected = 2,
		records = {
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
			{ key = "custom_¤", char = "§", label = "duplicate", consume = false, metadata = { note = "unusable" } },
		},
	},
	{
		name = "identical definitions with distinct metadata",
		owned = 1,
		rejected = 2,
		records = {
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "admitted" } },
			{ key = "custom_¤", char = "¤", label = "first", consume = true, metadata = { note = "unusable" } },
		},
	},
}

--- Builds the actual tray provider over its existing acknowledged settings owner.
--- @param Settings table Native persistent delimiter owner.
--- @param paused boolean Initial pause posture.
--- @param reordered boolean Whether the shared section is reversed.
--- @return table controls, table context, table observations
local function menu_controls(Settings, paused, reordered)
	local paths = require("infra.paths")
	local i18n = require("infra.i18n")
	local original = package.loaded["infra.manifest_menu"]
	local observations = { writes = 0, redraws = 0 }
	local renderer = assert(require("menu.renderer").new({
		platform = "linux",
		manifest_path = function() return paths.shared("modules/menu/menu_manifest.json") end,
		json_decode = function(raw)
			local value = assert(require("json").decode(raw))
			if reordered == "config_shared_label" then
				if type(value.hotstrings_delays_menu) == "table" then value.hotstrings_delays_menu[1].i18n = "button.ok" end
			elseif reordered == "custom_delete_label" then
				value.word_expander_custom_menu[1].i18n = "button.delete"
			elseif reordered then
				local rows = value.word_expanders_menu
				rows[1], rows[3] = rows[3], rows[1]
			end
			return value
		end,
		i18n = i18n,
		logger = require("logger.shim"),
	}))
	-- Forward the actual renderer's own methods through a plain observer facade.
	-- Native source admission deliberately does not acquire inherited methods.
	local facade = {}; for key, value in pairs(renderer) do facade[key] = value end
	facade.build = function(section, ...)
		local rows = renderer.build(section, ...)
		if section == "word_expanders_menu" then observations.controls = rows end
		return rows
	end
	package.loaded["infra.manifest_menu"] = facade
	local ctx = {
		paused = paused,
		config = {
			get_groups = function() return {} end,
			get_categories = function() return {} end,
			language_packs = function() return {} end,
			resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
			get_global_delay = function() return 0.75 end,
			has_global_delay_override = function() return false end,
		},
		on_persist_terminators = function()
			observations.writes = observations.writes + 1
			return Settings.persist()
		end,
		on_menu_changed = function() observations.redraws = observations.redraws + 1 end,
		on_toggle_pause = function() end,
		on_quit = function() end,
	}
	ctx.is_paused = function() return ctx.paused end
	local passed, rows = pcall(function() return helpers.load_module("ui.menu.menu_builder").build(ctx) end)
	package.loaded["infra.manifest_menu"] = original
	if not passed then error(rows, 0) end
	local function find(items)
		for _, row in ipairs(items or {}) do
			if row.title == i18n.get("menu.hotstrings.delays_colors") then observations.delay_controls = row.menu end
			if row.title == i18n.get("menu.hotstrings.word_expanders") then observations.controls_found = row.menu end
			local found = find(row.menu)
			if found then return found end
		end
	end
	for _, row in ipairs(rows) do
		if row.title == i18n.get("menu.hotstrings.title") then
			observations.hotstrings_disabled = row.disabled
			observations.hotstrings_submenu = row.menu
		end
	end
	find(rows)
	return assert(observations.controls_found or observations.controls, "the actual word-expander menu must be built"), ctx, observations
end

--- Reads the independent fixed-command and delimiter-state expectations.
--- @return table corpus
local function controls_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/word_expander_controls.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

--- Finds a command in the actual rendered native control list.
--- @param rows table Native menu items.
--- @param key string Independent translation identity.
--- @return table|nil row
local function custom_delete_row(rows, key)
	local text = require("infra.i18n").get(key)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:gsub("^%s+", "") == text then return row end
	end
end

--- Reads independent Add identity and custom-record expectations.
--- @return table corpus
local function add_command_expected()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/word_expander_add_controls.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

--- Uses the actual native menu and acknowledged TOML owner; only the native
--- prompt answers and writer refusal are controlled, then restored exactly.
--- @param mode string Native response/publication scenario.
--- @return table observed Captured effects, independent of callback catches.
local function observe_add_command(mode)
	local corpus = add_command_expected()
	local result
	with_settings(SOURCE, function(Settings, path, sandbox, Terminators)
		assert(Settings.load())
		local prior_prompt = package.loaded["ui.text_prompt"]
		local prior_execute = os.execute
		local Writer = require("toml_codec.writer")
		local prior_writer = Writer.batch_write
		local context, effects
		local observed = { prompts = 0, questions = 0, errors = 0, writes = 0 }
		package.loaded["ui.text_prompt"] = { ask = function()
			observed.prompts = observed.prompts + 1
			if mode == "pause_after_prompt" then context.paused = true end
			if mode == "input_cancel" then return nil end
			if mode == "input_empty" then return "" end
			return corpus.target.char
		end }
		os.execute = function(command)
			if command == "command -v zenity >/dev/null 2>&1" then
				return mode == "consume_unavailable" and 1 or 0
			end
			if command:find("zenity --question", 1, true) == 1 then
				observed.questions = observed.questions + 1
				if mode == "pause_after_consume" then context.paused = true end
				return mode == "consume_no" and 1 or 0
			end
			if command:find("zenity --error", 1, true) == 1 then
				observed.errors = observed.errors + 1
				return 0
			end
			return prior_execute(command)
		end
		Writer.batch_write = function(...)
			observed.writes = observed.writes + 1
			if mode == "write_false" then return false end
			if mode == "write_nil" then return nil end
			if mode == "write_throw" then error("injected Add writer refusal", 0) end
			if mode == "write_truthy" then return 2 end
			return prior_writer(...)
		end
		local passed, failure = pcall(function()
			local rows
			rows, context, effects = menu_controls(Settings, false)
			local row = assert(custom_delete_row(rows, corpus.i18n), "the actual Add provider must be accessible")
			if mode == "late_pause" then context.paused = true end
			observed.result = row.fn()
			observed.source = sandbox.read_bytes(path)
			observed.present = has_custom(Terminators, corpus.target.linux_key)
			observed.redraws = effects.redraws
			observed.records = require("toml_codec").decode(observed.source)
		end)
		package.loaded["ui.text_prompt"] = prior_prompt
		os.execute = prior_execute
		Writer.batch_write = prior_writer
		observed.prompt_restored = package.loaded["ui.text_prompt"] == prior_prompt
		observed.execute_restored = os.execute == prior_execute
		observed.writer_restored = Writer.batch_write == prior_writer
		if not passed then error(failure, 0) end
		result = observed
	end)
	return result
end

--- Reads the independent command and existing native window identity.
--- @return table corpus Historical command expectation.
local function delay_settings_command_expected()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/delays_settings_command.json"), "rb"))
	local bytes = file:read("*a")
	file:close()
	return assert(require("json").decode(bytes))
end

return {
	helpers = helpers,
	Codec = Codec,
	custom_command_expected = custom_command_expected,
	SOURCE = SOURCE,
	with_settings = with_settings,
	shipped = shipped,
	has_custom = has_custom,
	DUPLICATE_RECORDS = DUPLICATE_RECORDS,
	menu_controls = menu_controls,
	controls_corpus = controls_corpus,
	custom_delete_row = custom_delete_row,
	add_command_expected = add_command_expected,
	observe_add_command = observe_add_command,
	delay_settings_command_expected = delay_settings_command_expected,
}
