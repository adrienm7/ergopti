--- tests/unit/modules/llm/test_llm_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Generation Settings
--- DESCRIPTION:
--- Every generation control: what defaults, persists, and is refused.
---
--- WHAT WAS WRONG:
--- The manifest has declared both as features for as long as it has existed.
--- This driver read them from the shared canonical defaults and had no way to
--- change either, so `llm.generation` could not honestly be declared for Linux —
--- and declaring a capability with no control is what ADR-008 removed a
--- notifier for.
---
--- WHY AN OUT-OF-RANGE STORED VALUE IS REFUSED AND NOT CLIPPED:
--- It can only come from a hand-edited config or an older schema. Clipping
--- would silently apply a setting the user never chose while the menu showed
--- the clipped value as if they had — the failure is invisible from both sides.
--- ==============================================================================

local helpers = require("tests.helpers")

local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local _displaced = { storage = nil, module = nil, held = false }

--- Loads the settings over a fake storage.
--- @param initial table|nil
--- @param writes_fail boolean|nil
--- @return table settings, table storage
local function load_over_storage(initial, writes_fail)
	if not _displaced.held then
		_displaced.storage = package.loaded["infra.llm_preferences"]
		_displaced.module = package.loaded["modules.llm.settings"]
		_displaced.held = true
	end
	local storage = PreferencesFixture.new({ initial = initial, writes_fail = writes_fail })
	package.loaded["infra.llm_preferences"] = storage
	package.loaded["modules.llm.settings"] = nil
	local settings = require("modules.llm.settings")
	settings._reset()
	return settings, storage
end

--- Puts back exactly what was there.
local function drop_storage()
	package.loaded["infra.llm_preferences"] = _displaced.storage
	package.loaded["modules.llm.settings"] = _displaced.module
end




-- =================================================================
-- =================================================================
-- ======= 1/ The shipped answer ===================================
-- =================================================================
-- =================================================================

helpers.describe("llm settings: where the default comes from", function()

	helpers.it("takes every consumed generation value from the shared manifest", function()
		local settings = load_over_storage()
		local Manifest = helpers.load_module("infra.manifest_reader")
		local actual = {}
		for _, name in ipairs({ "temperature", "context_length", "min_words", "max_words", "auto_raise_temp" }) do
			actual[name] = settings.get(name)
		end
		drop_storage()

		for name, value in pairs(actual) do
			helpers.assert_eq(value, Manifest.default_for("llm.generation." .. name),
				"a driver that writes its own default is only coincidentally similar")
		end
	end)

	helpers.it("stores nothing while both are at their shipped values", function()
		local settings, storage = load_over_storage()
		for _, name in ipairs({ "temperature", "context_length", "min_words", "max_words", "auto_raise_temp" }) do
			settings.get(name)
		end
		local written = 0
		for _, key in ipairs(storage.keys()) do
			if key:find("^llm%.generation%.") then written = written + 1 end
		end
		drop_storage()
		helpers.assert_eq(written, 0,
			"persisting the default would freeze today's default for anyone who had "
				.. "already run the driver")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ A change, and what survives ==========================
-- =================================================================
-- =================================================================

helpers.describe("llm settings: changing them", function()

	helpers.it("stores a value the user chose", function()
		local settings, storage = load_over_storage()
		helpers.assert_true(settings.set("temperature", 0.8))
		local stored = storage.get("llm.generation.temperature")
		drop_storage()
		helpers.assert_eq(stored, 0.8,
			"a setting that is not persisted is a control that forgets what the "
				.. "user told it at every restart")
	end)

	helpers.it("reads a stored value back", function()
		local settings = load_over_storage({ ["llm.generation.temperature"] = 0.5 })
		local value = settings.get("temperature")
		drop_storage()
		helpers.assert_eq(value, 0.5)
	end)

	helpers.it("keeps word limits coherent and persists automatic diversity", function()
		local settings, storage = load_over_storage()
		helpers.assert_true(settings.set("min_words", 5))
		helpers.assert_true(settings.set("max_words", 20))
		helpers.assert_true(settings.set("auto_raise_temp", false))
		helpers.assert_eq(storage.get("llm.generation.min_words"), 5)
		helpers.assert_eq(storage.get("llm.generation.max_words"), 20)
		helpers.assert_eq(storage.get("llm.generation.auto_raise_temp"), false)
		helpers.assert_eq(settings.set("max_words", 4), false)
		helpers.assert_eq(settings.get("max_words"), 20)
		drop_storage()
	end)

	helpers.it("clears the entry when it returns to the shipped value", function()
		local settings, storage = load_over_storage()
		local shipped = settings.get("temperature")
		settings.set("temperature", 0.8)
		settings.set("temperature", shipped)
		local has = storage.has("llm.generation.temperature")
		drop_storage()
		helpers.assert_true(not has,
			"back to the default means back to no entry, so the shipped answer "
				.. "stays live rather than being pinned at the moment they touched it")
	end)

	helpers.it("keeps the durable value active when a write or delete fails", function()
		local settings, storage = load_over_storage({ ["llm.generation.temperature"] = 0.5 }, true)
		helpers.assert_eq(settings.get("temperature"), 0.5)
		helpers.assert_eq(settings.set("temperature", 0.8), false)
		helpers.assert_eq(settings.get("temperature"), 0.5,
			"a failed write must not publish a session-only value")
		local default = helpers.load_module("infra.manifest_reader")
			.default_for("llm.generation.temperature")
		helpers.assert_eq(settings.set("temperature", default), false)
		helpers.assert_eq(settings.get("temperature"), 0.5,
			"a failed delete must not publish the shipped default")
		helpers.assert_eq(storage.get("llm.generation.temperature"), 0.5)
		drop_storage()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ What is refused ======================================
-- =================================================================
-- =================================================================

helpers.describe("llm settings: the bounds", function()

	helpers.it("refuses a value outside the declared range", function()
		local settings, storage = load_over_storage()
		local bounds = settings.bounds("temperature")
		helpers.assert_not_nil(bounds, "the range must be declared")
		local accepted = settings.set("temperature", bounds.max + 10)
		local written = #storage.keys()
		drop_storage()
		helpers.assert_true(not accepted,
			"a temperature ten above the maximum is not a user asking for more "
				.. "creativity, it is a caller with a bug, and accepting it hides that "
				.. "for ever")
		helpers.assert_eq(written, 0)
	end)

	helpers.it("ignores a stored value outside the range rather than clipping it", function()
		local settings = load_over_storage({ ["llm.generation.temperature"] = 99 })
		local value = settings.get("temperature")
		local shipped = settings.bounds("temperature")
		drop_storage()
		helpers.assert_true(value <= shipped.max,
			"clipping would silently apply a setting the user never chose while the "
				.. "menu showed the clipped value as if they had — invisible from both "
				.. "sides")
	end)

	helpers.it("offers only presets inside the range", function()
		local settings = load_over_storage()
		local checked = 0
		for _, name in ipairs({ "temperature", "context_length", "min_words", "max_words" }) do
			local bounds = settings.bounds(name)
			for _, value in ipairs(settings.presets(name)) do
				checked = checked + 1
				helpers.assert_true(value >= bounds.min and value <= bounds.max,
					name .. " offers " .. tostring(value) .. ", which its own set() would "
						.. "refuse — a menu row that cannot be applied")
			end
		end
		drop_storage()
		helpers.assert_true(checked > 0,
			"no presets were checked — the menu would have nothing to offer")
	end)

end)





-- =====================================================
-- =====================================================
-- ======= 4/ Shared Automatic Temperature Check =======
-- =====================================================
-- =====================================================

--- Builds the actual inline generation menu over both existing durable owners.
--- @param options table Independent count/state, refusal and declaration mutations.
--- @param callback function Observations asserted outside delivered callbacks.
local function with_auto_menu(options, callback)
	local names = { "infra.llm_preferences", "modules.llm.settings", "modules.llm.profile_settings", "infra.manifest_menu", "ui.menu.menu_builder" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local storage = PreferencesFixture.new({initial = {
		["llm.generation.auto_raise_temp"] = options.selected,
		["llm.profiles.num_predictions"] = options.count or 2,
		["llm.future_field"] = 42,
	}, writes_fail = options.refused})
	package.loaded["infra.llm_preferences"] = storage
	package.loaded["modules.llm.settings"] = nil
	package.loaded["modules.llm.profile_settings"] = nil
	package.loaded["ui.menu.menu_builder"] = nil
	local settings = require("modules.llm.settings")
	local profiles = require("modules.llm.profile_settings")
	settings._reset()
	profiles._reset()
	local renderer = assert(require("menu.renderer").new({
		platform = "linux",
		manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
		json_decode = function(raw)
			local root = assert(require("json").decode(raw))
			if root.llm_generation_menu then
				if options.label then root.llm_generation_menu[2].i18n = options.label end
				if options.auto_first then
					root.llm_generation_menu[1], root.llm_generation_menu[2] = root.llm_generation_menu[2], root.llm_generation_menu[1]
				end
			end
			return root
		end,
		i18n = require("infra.i18n"), logger = require("logger.shim"),
	}))
	package.loaded["infra.manifest_menu"] = renderer
	local observed = { writes = 0, redraws = 0 }
	local native_set = storage.set
	storage.set = function(...)
		observed.writes = observed.writes + 1
		return native_set(...)
	end
	local native_delete = storage.delete
	storage.delete = function(...)
		observed.writes = observed.writes + 1
		return native_delete(...)
	end
	local admission = { enabled = true }
	local context = {
		_version = "0.0.0-dev.12", paused = false,
		llm = { is_enabled = function() return admission.enabled end, toggle = function() return true end },
		on_quit = function() end,
		on_menu_changed = function() observed.redraws = observed.redraws + 1 end,
	}
	local ok, err = xpcall(function()
		local items = helpers.load_module("ui.menu.menu_builder").build(context)
		local function find(rows, title)
			for index, row in ipairs(rows or {}) do
				if row.title == title then return row, rows, index end
				local child, siblings, position = find(row.menu, title)
				if child then return child, siblings, position end
			end
		end
		local title = require("infra.i18n").get(options.label or "menu.llm.auto_raise_temp")
		local row, siblings, position = find(items, title)
		callback(assert(row, "the actual automatic temperature control must exist"), settings, profiles, storage, observed, context, admission, siblings, position)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

--- Reads expectations captured independently of the declaration and native policy.
--- @return table corpus
local function auto_raise_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/auto_raise_temperature.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared automatic temperature control", function()
	helpers.it("replays the bool by prediction-count matrix through real owners (shared-auto-raise)", function()
		local corpus = auto_raise_corpus()
		helpers.assert_eq(#corpus.states, 2)
		helpers.assert_eq(#corpus.prediction_counts, 2)
		for _, selected in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				with_auto_menu({selected = selected, count = count}, function(row, settings, _, storage, observed)
					helpers.assert_eq(row.checked or false, selected)
					helpers.assert_eq(row.disabled or false, count < 2)
					local result = row.fn()
					local expected = selected
					if count >= 2 then expected = not selected end
					helpers.assert_eq(settings.get("auto_raise_temp"), expected)
					helpers.assert_eq(storage.get("llm.generation.auto_raise_temp", settings.get("auto_raise_temp")), expected)
					helpers.assert_eq(storage.get("llm.future_field"), 42)
					helpers.assert_eq(observed.writes, count >= 2 and 1 or 0)
					helpers.assert_eq(observed.redraws, count >= 2 and 1 or 0)
					helpers.assert_eq(result, count >= 2)
					if count >= 2 and not selected then
						helpers.assert_eq(storage.has("llm.generation.auto_raise_temp"), false, "the owned default stays sparse")
					end
					settings._reset()
					helpers.assert_eq(settings.get("auto_raise_temp"), expected)
				end)
			end
		end
	end)

	helpers.it("uses the changed shared label and order before numeric providers (shared-auto-raise)", function()
		with_auto_menu({selected = true, label = auto_raise_corpus().alternate_i18n, auto_first = true}, function(row, _, _, _, observed, _, _, siblings, position)
			local count_label = string.format(require("infra.i18n").get("menu.llm.num_predictions_label"), "2")
			local count_position
			for index, sibling in ipairs(siblings) do if sibling.title == count_label then count_position = index end end
			helpers.assert_true(count_position ~= nil, "the actual numeric provider remains present")
			helpers.assert_true(position < count_position, "the declaration moves the check before numeric values")
			helpers.assert_eq(row.title, require("infra.i18n").get(auto_raise_corpus().alternate_i18n))
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
		end)
	end)

	helpers.it("refuses a delayed callback after the real count owner changes (shared-auto-raise)", function()
		with_auto_menu({selected = true}, function(row, settings, profiles, storage, observed)
			helpers.assert_eq(profiles.set("num_predictions", 1), true)
			observed.writes = 0
			local result = row.fn()
			helpers.assert_eq(settings.get("auto_raise_temp"), true)
			helpers.assert_eq(storage.get("llm.future_field"), 42)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(observed.redraws, 0)
			helpers.assert_eq(result, false)
		end)
	end)

	helpers.it("refuses stale callbacks after pause or the live AI gate closes (shared-auto-raise)", function()
		for _, gate in ipairs({ "pause", "master" }) do
			with_auto_menu({selected = true}, function(row, settings, _, _, observed, context, admission)
				if gate == "pause" then context.paused = true else admission.enabled = false end
				local result = row.fn()
				helpers.assert_eq(settings.get("auto_raise_temp"), true)
				helpers.assert_eq(observed.writes, 0)
				helpers.assert_eq(observed.redraws, 0)
				helpers.assert_eq(result, false)
			end)
		end
	end)

	helpers.it("preserves live and durable values with no optimistic redraw on writer refusal (shared-auto-raise)", function()
		for _, selected in ipairs(auto_raise_corpus().states) do
			with_auto_menu({selected = selected, refused = true}, function(row, settings, _, storage, observed)
				local result = row.fn()
				helpers.assert_eq(settings.get("auto_raise_temp"), selected)
				helpers.assert_eq(storage.get("llm.generation.auto_raise_temp"), selected)
				helpers.assert_eq(storage.get("llm.future_field"), 42)
				helpers.assert_eq(observed.writes, 1)
				helpers.assert_eq(observed.redraws, 0)
				helpers.assert_eq(result, false)
			end)
		end
	end)
end)
