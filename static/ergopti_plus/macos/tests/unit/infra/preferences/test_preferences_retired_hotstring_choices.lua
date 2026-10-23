--- tests/unit/infra/preferences/test_preferences_retired_hotstring_choices.lua

--- ==============================================================================
--- MODULE: Retired Hotstring Choices
--- DESCRIPTION:
--- An explicit [hotstrings] category, section or order choice naming a category
--- or section this build no longer ships is an outdated entry: reported, read as
--- absent and offered by the cleanup, never lost by a later save. Before boot
--- publishes the catalogue nothing is judged, and a personal file, an extension
--- pack or a dynamic group is never judged (hotstring-choice-retired-2026-10-23).
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")
local load_fixture_preferences = require("tests.support.infra.preferences.preferences_keeps_unowned_sections_fixture").load_preferences

local SOURCE = table.concat({
	"[hotstrings.groups]",
	"autocorrection = false",
	"removed = true",
	'"personal-file:aa" = false',
	'"ext:pack:stem" = false',
	"",
	"[hotstrings.modules.autocorrection]",
	"names = false",
	"gone = true",
	"",
	"[hotstrings.modules.removed]",
	"anything = true",
	"",
	"[hotstrings.order_overrides]",
	'removed = ["a", "b"]',
	'autocorrection = ["names"]',
	"",
}, "\n")

--- Loads a private config.toml through the real preferences owner.
--- @param body function Receives (preferences, path, warnings, catalogue).
local function with_source(body)
	helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim",
		"config_outdated", "infra.hotstring_choice_catalogue" }, function()
		local warnings = {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...)
			warnings[#warnings + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
		end
		logger.error = logger.warn
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		package.loaded["adapters.file_system"] = nil
		package.loaded["infra.hotstring_choice_catalogue"] = nil
		local config_outdated = require("config_outdated")
		if type(config_outdated.reset_for_tests) == "function" then config_outdated.reset_for_tests() end
		local preferences = helpers.load_with_stubs("infra.preferences")
		local catalogue = require("infra.hotstring_choice_catalogue")
		OutputFixture.with_output(function(path)
			local file = assert(io.open(path, "wb")); assert(file:write(SOURCE)); assert(file:close())
			body(preferences, path, warnings, catalogue)
		end)
	end)
end

--- Publishes the catalogue of a build that ships only the autocorrection category.
--- @param catalogue table Choice catalogue owner.
local function publish_build(catalogue)
	helpers.assert_true(catalogue.publish(function(id)
		if id:find("^personal%-file:") or id:find("^ext:") then return { unjudged = true } end
		if id == "autocorrection" then return { sections = { names = true } } end
		return nil
	end), "the catalogue publishes once")
end

--- Whether a warning names one dotted path.
--- @param warnings table Collected warning lines.
--- @param needle string Path text.
--- @return boolean
local function names(warnings, needle)
	for _, line in ipairs(warnings) do
		if line:find(needle, 1, true) then return true end
	end
	return false
end

helpers.describe("retired hotstring choices (hotstring-choice-retired-2026-10-23)", function()
	helpers.it("accepts one catalogue owner and refuses a second or a non-function", function()
		helpers.with_stub_scope({ "infra.hotstring_choice_catalogue" }, function()
			package.loaded["infra.hotstring_choice_catalogue"] = nil
			local catalogue = require("infra.hotstring_choice_catalogue")
			helpers.assert_eq(catalogue.retired("anything"), false, "an unpublished catalogue retires nothing")
			helpers.assert_eq(catalogue.publish("not a lookup"), false)
			helpers.assert_eq(catalogue.publish(function() return nil end), true)
			helpers.assert_eq(catalogue.publish(function() return nil end), false, "a second owner is refused")
			helpers.assert_eq(catalogue.retired("anything"), true)
		end)
	end)

	helpers.it("judges nothing before the catalogue is published", function()
		with_source(function(preferences, path, warnings)
			local state, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.hotstrings.removed, true, "an unpublished catalogue keeps every category choice")
			helpers.assert_eq(state.section_states.removed.anything, true)
			helpers.assert_true(state.sections_order_overrides.removed ~= nil)
			helpers.assert_eq(names(warnings, "removed"), false, "no retired entry is reported before the catalogue exists")
		end)
	end)

	helpers.it("reports and drops a category and a section the build no longer ships", function()
		with_source(function(preferences, path, warnings, catalogue)
			publish_build(catalogue)
			local state = preferences.load(path)
			helpers.assert_nil(state.hotstrings.removed, "a retired category choice reads as absent")
			helpers.assert_eq(state.hotstrings.autocorrection, false, "a shipped category choice is kept")
			helpers.assert_nil(state.section_states.removed, "a retired category's section choices read as absent")
			helpers.assert_nil(state.section_states.autocorrection.gone, "a retired section choice reads as absent")
			helpers.assert_eq(state.section_states.autocorrection.names, false, "a shipped section choice is kept")
			helpers.assert_nil(state.sections_order_overrides.removed, "a retired category's order reads as absent")
			helpers.assert_true(state.sections_order_overrides.autocorrection ~= nil)
			helpers.assert_true(names(warnings, "hotstrings.groups.removed"), "the category is reported: " .. table.concat(warnings, " | "))
			helpers.assert_true(names(warnings, "hotstrings.modules.autocorrection.gone"), "the section is reported")
			helpers.assert_true(names(warnings, "hotstrings.order_overrides.removed"), "the order is reported")
		end)
	end)

	helpers.it("never judges a personal file or an extension pack", function()
		with_source(function(preferences, path, warnings, catalogue)
			publish_build(catalogue)
			local state = preferences.load(path)
			helpers.assert_eq(state.hotstrings["personal-file:aa"], false)
			helpers.assert_eq(state.hotstrings["ext:pack:stem"], false)
			helpers.assert_eq(names(warnings, "personal-file"), false, "a personal file's absence may be temporary")
			helpers.assert_eq(names(warnings, "ext:pack"), false, "an extension pack's absence may be temporary")
		end)
	end)

	helpers.it("keeps a retired choice in the file across a save", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.hotstring_choice_catalogue",
			"config_outdated" }, function()
			package.loaded["infra.hotstring_choice_catalogue"] = nil
			require("config_outdated").reset_for_tests()
			local path = "/virtual/retired_choices/config.toml"
			local disk = { [path] = SOURCE }
			local preferences = load_fixture_preferences(disk)
			publish_build(require("infra.hotstring_choice_catalogue"))
			local state = preferences.load(path)
			state.hotstrings.autocorrection = true
			helpers.assert_eq(preferences.save(path, state, {}, {}), true)
			local text = disk[path]
			helpers.assert_true(text:find("removed = true", 1, true) ~= nil,
				"the retired category choice stays for the cleanup to offer: " .. text)
			helpers.assert_true(text:find("anything = true", 1, true) ~= nil, "the retired section choices stay")
			helpers.assert_true(text:find("gone = true", 1, true) ~= nil, "the retired section choice stays")
			helpers.assert_true(text:find("order_overrides", 1, true) ~= nil and text:find("removed", 1, true) ~= nil,
				"the retired order stays")
		end)
	end)

	helpers.it("keeps every retired choice when the state holds no category at all", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.hotstring_choice_catalogue",
			"config_outdated" }, function()
			package.loaded["infra.hotstring_choice_catalogue"] = nil
			require("config_outdated").reset_for_tests()
			local path = "/virtual/retired_choices/empty.toml"
			local disk = { [path] = "[hotstrings.groups]\nremoved = true\n" }
			local preferences = load_fixture_preferences(disk)
			require("infra.hotstring_choice_catalogue").publish(function() return nil end)
			local state = preferences.load(path)
			helpers.assert_nil(state.hotstrings.removed)
			helpers.assert_eq(preferences.save(path, state, {}, {}), true)
			helpers.assert_true(disk[path]:find("removed = true", 1, true) ~= nil,
				"an empty inventory never rewrites the whole table over the retired entry: " .. disk[path])
		end)
	end)
end)

return true
