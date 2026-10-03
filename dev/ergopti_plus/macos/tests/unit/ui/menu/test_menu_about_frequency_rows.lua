--- tests/unit/ui/menu/test_menu_about_frequency_rows.lua

--- ==============================================================================
--- MODULE: The About Submenu Owns The Check Frequency (macOS)
--- DESCRIPTION:
--- macOS had no check frequency: Sparkle checked once a day whatever the user
--- wanted, and the About submenu offered nothing to change it. The frequency
--- picker now follows the check row, as on Windows and Linux: one row per
--- shared preset, labelled in words and ticked on the interval in force, and a
--- click persists through the automatic-check owner. The check row names a
--- release the last automatic check found. Built through the real builder and
--- renderer, so a row the renderer drops fails here.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local function presets()
	local handle = assert(io.open(helpers.shared("modules/updater/defaults.json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded.timing.check_interval_presets
end

local function fake_owner(subscribed)
	return {
		get = function() return subscribed end,
		set = function() return true end,
		subscribe = function() end,
	}
end

--- An automatic-check owner double recording the interval the menu sets.
local function fake_checks(code, latest)
	local calls = {}
	local list = presets()
	return {
		presets = function() return list end,
		interval_code = function() return code end,
		interval = function()
			for _, preset in ipairs(list) do if preset.code == code then return preset.seconds end end
			error("The fixture names no preset.")
		end,
		set_interval = function(seconds) calls[#calls + 1] = seconds; return true end,
		latest = function() return latest end,
	}, calls
end

--- Builds the About submenu through the real renderer.
--- @param checks table|nil The automatic-check owner; a local version has none.
--- @param local_source boolean|nil True for a local version run from source.
--- @param state table|nil Menu state (the stored check interval).
local function build(checks, local_source, state)
	local Updater = require("modules.updater")
	local real_local = Updater.is_local_source
	Updater.is_local_source = function() return local_source == true end
	package.loaded["ui.menu.menu_about"] = nil
	local ok, rows = pcall(function()
		local About = helpers.load_with_stubs("ui.menu.menu_about")
		return About.build({ channel_owner = fake_owner("dev"), update_checks = checks, state = state or {} }, {
			start_at_login = function() error("Building About must not change startup.") end,
			uninstall = function() error("Building About must not uninstall the application.") end,
		}).submenu
	end)
	Updater.is_local_source = real_local
	package.loaded["ui.menu.menu_about"] = nil
	if not ok then error(rows, 0) end
	return rows
end

--- The row whose submenu is the frequency picker.
local function picker(rows)
	local prefix = require("infra.i18n").get("menu.about.frequency_menu") .. ": "
	for _, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:find(prefix, 1, true) == 1 then return row end
	end
	return nil
end

helpers.describe("menu_about: the check frequency (macOS)", function()
	helpers.it("lists the shared presets after the check row, ticked on the interval in force", function()
		local checks = fake_checks("1d")
		local rows = build(checks)
		local i18n = require("infra.i18n")
		local row = picker(rows)
		helpers.assert_not_nil(row, "the About submenu must offer the check frequency")
		helpers.assert_eq(row.title, i18n.get("menu.about.frequency_menu") .. ": " .. i18n.get("menu.about.frequency.1d"),
			"the parent row names the preset in force in words")
		local list = presets()
		helpers.assert_eq(#row.menu, #list, "one row per shared preset")
		local ticked = 0
		for index, preset in ipairs(list) do
			helpers.assert_eq(row.menu[index].title, i18n.get("menu.about.frequency." .. preset.code),
				"preset row " .. index .. " reads its translated label")
			if row.menu[index].checked == true then
				ticked = ticked + 1
				helpers.assert_eq(preset.code, "1d", "the interval in force is the ticked row")
			end
		end
		helpers.assert_eq(ticked, 1, "exactly one preset is ticked")
		local check_at, picker_at = nil, nil
		for index, candidate in ipairs(rows) do
			if candidate.title == i18n.get("menu.about.check_for_updates") then check_at = index end
			if candidate == row then picker_at = index end
		end
		helpers.assert_true(check_at ~= nil and picker_at == check_at + 1, "the picker follows the check row")
	end)

	helpers.it("a preset row sets the interval through the owner", function()
		local checks, calls = fake_checks("1d")
		local row = picker(build(checks))
		local list = presets()
		row.menu[1].fn()
		helpers.assert_eq(calls, { list[1].seconds }, "the first preset's seconds are persisted")
	end)

	helpers.it("the check row names the release the last automatic check found", function()
		local checks = fake_checks("1d", { tag = "v0.0.0-dev.150", channel = "dev" })
		local rows = build(checks)
		local picker_row = picker(rows)
		local check_row = nil
		for index, row in ipairs(rows) do
			if rows[index + 1] == picker_row then check_row = row end
		end
		helpers.assert_not_nil(check_row, "the check row precedes the picker")
		helpers.assert_true(check_row.title:find("v0.0.0-dev.150", 1, true) ~= nil,
			"the check row names the found release: " .. tostring(check_row.title))
		local idle = build(fake_checks("1d"))
		for _, row in ipairs(idle) do
			helpers.assert_true(row.title:find("v0.0.0-dev.150", 1, true) == nil,
				"without a found release no row names one")
		end
	end)

	-- A local version has no installation to update, so it starts no
	-- automatic check. Its check row and its frequency row used to be left
	-- out, and nobody could tell whether the feature existed: they are drawn
	-- greyed, with the reason, and run nothing.
	helpers.it("(update-rows-greyed-on-local-2026-10-01) a local version draws the update rows greyed with their reason", function()
		--- The reason as the renderer shortens it: its text before the first colon.
		--- Read after a build, which loads the locale module the page was drawn with.
		local function reason_head()
			local reason = require("infra.i18n").get("menu.about.source_run_reason")
			return reason:match("^(.-)%s*[:：]") or reason
		end
		for _, case in ipairs({ { state = {}, code = "1d" }, { state = { update_check_interval_seconds = 604800 }, code = "1w" } }) do
			local rows = build(nil, true, case.state)
			local i18n = require("infra.i18n")
			local head = reason_head()
			local expected = {
				i18n.get("menu.about.check_for_updates"),
				i18n.get("menu.about.frequency_menu") .. ": " .. i18n.get("menu.about.frequency." .. case.code),
			}
			local found = {}
			for index, row in ipairs(rows) do
				for at, label in ipairs(expected) do
					if type(row.title) == "string" and row.title:find(label, 1, true) == 1 then found[at] = index end
				end
			end
			helpers.assert_true(found[1] ~= nil, "a local version draws the check row")
			helpers.assert_true(found[2] ~= nil, "a local version draws the frequency row, naming the preset " .. case.code)
			helpers.assert_eq(found[2], found[1] + 1, "the frequency row follows the check row")
			for at, label in ipairs(expected) do
				local row = rows[found[at]]
				helpers.assert_eq(row.title, label .. " — " .. head, "the row says why it is greyed")
				helpers.assert_eq(row.disabled, true, label .. " is greyed")
				helpers.assert_nil(row.fn, label .. " runs nothing")
				helpers.assert_nil(row.menu, label .. " opens nothing")
			end
		end
		local installed = build(fake_checks("1d"))
		local head = reason_head()
		for _, row in ipairs(installed) do
			helpers.assert_true(type(row.title) ~= "string" or row.title:find(head, 1, true) == nil,
				"an installed build greys no row for this reason: " .. tostring(row.title))
		end
	end)
end)


--- Reads independent numeric values, translated labels and snap expectations.
local function frequency_corpus()
	local handle = assert(io.open(helpers.shared("tests/corpus/menus/update_check_frequency.json"), "rb"))
	local raw = assert(handle:read("*a"))
	assert(handle:close())
	return assert(Json.decode(raw))
end

--- Builds the actual cadence owner around observable durable and timer ports.
local function actual_checks(refusal, interval)
	local AutoCheck = require("modules.updater.auto_check")
	local config = AutoCheck.load_config()
	local stored = interval == nil and 3600 or interval
	local obs = {state = {[AutoCheck.STATE_KEY] = stored, future_setting = 42}, durable = stored,
		saves = 0, timers = {}, cancels = 0, requests = 0, paused = false}
	obs.owner = AutoCheck.new({
		state = obs.state,
		save = function()
			obs.saves = obs.saves + 1
			if refusal == "throw" then error("The cadence writer refused.") end
			if refusal == "false" then return false end
			if refusal == "nil" then return nil end
			obs.durable = obs.state[AutoCheck.STATE_KEY]
			return true
		end,
		channel = function() return "dev" end,
		is_paused = function() return obs.paused end,
		on_available = function() error("Changing cadence cannot announce a release.") end,
		config = config,
		timer = {
			after = function(delay, fn)
				local handle = {delay = delay, fn = fn, armed = true}
				obs.timers[#obs.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle) obs.cancels = obs.cancels + 1; handle.armed = false; return true end,
		},
		storage = {get = function(_, default) return default end, set = function() return true end},
		http = {get = function() obs.requests = obs.requests + 1; return false end},
		now = function() return 1700000000 end,
		current_version = function() return "0.0.0-dev.140" end,
		installed_channel = function() return "dev" end,
	})
	helpers.assert_eq(obs.owner.start(), true)
	return obs
end

helpers.describe("shared updater frequency choices (macOS)", function()
	helpers.it("projects independent presets and snapped captions into real menu rows (shared-update-frequency)", function()
		local corpus = frequency_corpus()
		helpers.assert_eq(#corpus.choices, 10)
		for _, expected in ipairs(corpus.snapped_states) do
			local obs = actual_checks(nil, expected.stored)
			local row = assert(picker(build(obs.owner)))
			helpers.assert_eq(#row.menu, #corpus.choices)
			local i18n = require("infra.i18n")
			helpers.assert_eq(row.title, i18n.get(corpus.i18n) .. ": " .. i18n.get("menu.about.frequency." .. expected.code))
			for index, choice in ipairs(corpus.choices) do
				helpers.assert_eq(row.menu[index].title, i18n.get(choice.i18n))
				helpers.assert_eq(row.menu[index].checked, choice.value == expected.value)
			end
			helpers.assert_eq(obs.saves, 0, "rendering a snapped caption must not rewrite a stored interval")
			helpers.assert_eq(obs.durable, expected.stored)
			helpers.assert_eq(obs.owner.stop(), true)
		end
	end)

	helpers.it("preserves native and durable cadence plus timer ownership after refused saves (shared-update-frequency)", function()
		for _, refusal in ipairs({"false", "nil", "throw"}) do
			local obs = actual_checks(refusal)
			local row = assert(picker(build(obs.owner)))
			local held = row.menu[1].fn
			local timers, cancels = #obs.timers, obs.cancels
			local result = held()
			helpers.assert_eq(obs.owner.interval(), 3600)
			helpers.assert_eq(obs.durable, 3600)
			helpers.assert_eq(obs.state.future_setting, 42)
			helpers.assert_eq(#obs.timers, timers)
			helpers.assert_eq(obs.cancels, cancels)
			helpers.assert_eq(obs.saves, 1)
			helpers.assert_eq(result, false, "the actual menu must report a refused durable owner")
			helpers.assert_eq(obs.owner.stop(), true)
		end
	end)

	helpers.it("returns the actual acknowledged owner receipt and keeps absolute held selections (shared-update-frequency)", function()
		local obs = actual_checks()
		local row = assert(picker(build(obs.owner)))
		local held = row.menu[1].fn
		obs.paused = true
		local result = held()
		helpers.assert_eq(obs.owner.interval(), frequency_corpus().choices[1].value)
		helpers.assert_eq(obs.durable, frequency_corpus().choices[1].value)
		helpers.assert_eq(obs.saves, 1)
		helpers.assert_eq(obs.requests, 0, "pausing still fences background requests")
		helpers.assert_eq(result, true)
		helpers.assert_eq(held(), true)
		helpers.assert_eq(obs.saves, 1, "replaying an acknowledged absolute selection does not write again")
		helpers.assert_eq(obs.owner.stop(), true)
	end)
end)


helpers.describe("published updater frequency choices (macOS)", function()
	helpers.it("consumes the published label order and numeric command values (shared-update-frequency)", function()
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local previous = root.about_update_frequency_menu
		local corpus, choices = frequency_corpus(), {}
		for index = #corpus.choices, 1, -1 do
			local source = corpus.choices[index]
			choices[#choices + 1] = {value = source.value, i18n = source.i18n}
		end
		choices[1].i18n = corpus.alternate_i18n
		root.about_update_frequency_menu = {{type = "choice", id = corpus.id, path = corpus.path,
			i18n = corpus.i18n, show_current_choice = true, current_choice_suffix = corpus.suffix,
			choices = choices}}
		local ok, detail = pcall(function()
			local checks, calls = fake_checks("1d")
			local row = assert(picker(build(checks)))
			helpers.assert_eq(#row.menu, #choices)
			for index, choice in ipairs(choices) do
				helpers.assert_eq(row.menu[index].title, require("infra.i18n").get(choice.i18n))
				row.menu[index].fn()
				helpers.assert_eq(calls[index], choice.value, "the published seconds reach the existing owner")
			end
		end)
		root.about_update_frequency_menu = previous
		if not ok then error(detail, 0) end
	end)
end)
