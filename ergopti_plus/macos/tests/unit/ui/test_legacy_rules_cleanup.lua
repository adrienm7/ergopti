--- tests/unit/ui/test_legacy_rules_cleanup.lua

--- ==============================================================================
--- MODULE: Legacy Karabiner rules cleanup dialog (karabiner-legacy-cleanup)
--- DESCRIPTION:
--- When rules an older ErgoptiPlus left in Karabiner refuse every deploy, the
--- user gets a dialog naming them with « Retirer les anciennes règles » and
--- « Plus tard ». Removing goes through the remap bridge and the result is
--- reported from the timer scheduler, never from the lease callback that
--- carries it; « Plus tard » removes nothing.
--- ==============================================================================

local helpers    = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local MODULES = { "ui.legacy_rules_cleanup", "infra.logger", "infra.i18n", "infra.dialog_util",
	"infra.deferred_work" }

--- Installs recording doubles and loads the dialog module.
--- @param h table Harness receiving the recordings.
--- @return table cleanup
local function load_cleanup(h)
	h.logs, h.alerts, h.deferred = {}, {}, {}
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "info", "start", "success", "warn", "error" }) do
		logger[level] = function(_, message, ...)
			h.logs[#h.logs + 1] = { level = level, message = string.format(message, ...) }
		end
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.dialog_util"] = {
		block_alert = function(message, informative, first, second, style)
			h.alerts[#h.alerts + 1] = { message = message, informative = informative, first = first,
				second = second, style = style, during_remap_callback = h.in_remap_callback == true }
			return h.answer
		end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(delay, callback, label)
			h.deferred[#h.deferred + 1] = { delay = delay, callback = callback, label = label }
			return true
		end,
	}
	local cleanup = helpers.load_with_stubs("ui.legacy_rules_cleanup")
	-- The loader installs its echoing i18n stub, which the module captured:
	-- give that same table a format that shows its arguments.
	package.loaded["infra.i18n"].format = function(key, ...)
		local parts = { key }
		for index = 1, select("#", ...) do parts[#parts + 1] = tostring(select(index, ...)) end
		return table.concat(parts, "|")
	end
	return cleanup
end

--- A remap facade with pending rules and a scripted removal outcome.
--- @param h table Harness.
--- @param pending table|nil legacy_rule_conflicts() answer.
--- @return table remap
local function make_remap(h, pending)
	h.removals = 0
	return {
		legacy_rule_conflicts = function() return pending end,
		remove_legacy_rules = function(on_done)
			h.removals = h.removals + 1
			h.in_remap_callback = true
			on_done(h.outcome_ok, h.outcome)
			h.in_remap_callback = false
			return h.outcome_ok == true or h.outcome.stage == "regeneration"
		end,
	}
end

--- Runs the deferred report callbacks.
--- @param h table Harness.
local function fire_deferred(h)
	local queued = h.deferred
	h.deferred = {}
	for _, item in ipairs(queued) do item.callback() end
end

local PENDING = {
	count = 25,
	descriptions = {
		"CapsWord — toggle and deactivation", "Layer", "Combos", "Script control 1", "Script control 2",
		"Script control 3", "Left Shift", "Right Shift", "Left Command", "Right Command",
	},
}

helpers.describe("the legacy Karabiner rules cleanup dialog (karabiner-legacy-cleanup)", function()
	helpers.it("names the rules with a remove button and a later button (karabiner-legacy-cleanup)", function()
		helpers.with_fresh_modules(MODULES, function()
			local h = { answer = "common.later" }
			local cleanup = load_cleanup(h)
			helpers.assert_true(cleanup.offer(make_remap(h, PENDING)))
			helpers.assert_eq(#h.alerts, 1)
			local alert = h.alerts[1]
			helpers.assert_eq(alert.message, "karabiner.legacy_cleanup.title")
			helpers.assert_eq(alert.first, "karabiner.legacy_cleanup.remove", "removing is the primary button")
			helpers.assert_eq(alert.second, "common.later")
			local body = alert.informative
			helpers.assert_true(body:find("karabiner.legacy_cleanup.body_other|25|", 1, true) == 1,
				"the body gives the count: " .. body)
			helpers.assert_true(body:find("• CapsWord — toggle and deactivation", 1, true) ~= nil,
				"the rules are named")
			helpers.assert_true(body:find("karabiner.legacy_cleanup.more|2", 1, true) ~= nil,
				"rules beyond the listed ones are counted")
		end)
	end)

	helpers.it("« Plus tard » removes nothing (karabiner-legacy-cleanup)", function()
		helpers.with_fresh_modules(MODULES, function()
			local h = { answer = "common.later" }
			local cleanup = load_cleanup(h)
			helpers.assert_true(cleanup.offer(make_remap(h, PENDING)))
			helpers.assert_eq(h.removals, 0, "declining never reaches the removal")
			helpers.assert_eq(#h.deferred, 0, "and reports nothing")
		end)
	end)

	helpers.it("confirming removes, then reports outside the remap callback (karabiner-legacy-cleanup)", function()
		helpers.with_fresh_modules(MODULES, function()
			local h = { answer = "karabiner.legacy_cleanup.remove", outcome_ok = true,
				outcome = { stage = "regeneration", reason = "ready", removed_count = 25,
					backup_path = "/Users/me/.config/karabiner/karabiner.json.bak" } }
			local cleanup = load_cleanup(h)
			helpers.assert_true(cleanup.offer(make_remap(h, PENDING)))
			helpers.assert_eq(h.removals, 1)
			helpers.assert_eq(#h.alerts, 1, "no report dialog runs inside the remap callback")
			helpers.assert_eq(#h.deferred, 1)
			helpers.assert_eq(h.deferred[1].delay, 0)
			fire_deferred(h)
			helpers.assert_eq(#h.alerts, 2)
			local report = h.alerts[2]
			helpers.assert_true(not report.during_remap_callback)
			helpers.assert_true(report.informative:find(
				"karabiner.legacy_cleanup.removed|25|/Users/me/.config/karabiner/karabiner.json.bak", 1, true) ~= nil,
				"the report names the count and the backup: " .. report.informative)
			helpers.assert_true(report.informative:find("karabiner.legacy_cleanup.applied", 1, true) ~= nil)
			helpers.assert_eq(report.first, "common.ok")
		end)
	end)

	helpers.it("reports the precise failure of each stage (karabiner-legacy-cleanup)", function()
		helpers.with_fresh_modules(MODULES, function()
			local h = { answer = "karabiner.legacy_cleanup.remove", outcome_ok = false,
				outcome = { stage = "removal", reason = "karabiner.json publication refused: source changed",
					removed_count = 0 } }
			local cleanup = load_cleanup(h)
			cleanup.open(make_remap(h, PENDING))
			fire_deferred(h)
			helpers.assert_eq(h.alerts[2].informative,
				"karabiner.legacy_cleanup.removal_failed|karabiner.json publication refused: source changed")

			h.alerts, h.outcome = {}, { stage = "regeneration", reason = "script-paused", removed_count = 3,
				backup_path = "/b.bak" }
			cleanup.open(make_remap(h, PENDING))
			fire_deferred(h)
			local informative = h.alerts[2].informative
			helpers.assert_true(informative:find("karabiner.legacy_cleanup.removed|3|/b.bak", 1, true) ~= nil)
			helpers.assert_true(informative:find("karabiner.legacy_cleanup.apply_failed|script-paused", 1, true) ~= nil,
				"a removal whose regeneration failed says both: " .. informative)
		end)
	end)

	helpers.it("shows nothing once no rule is pending (karabiner-legacy-cleanup)", function()
		helpers.with_fresh_modules(MODULES, function()
			local h = { answer = "karabiner.legacy_cleanup.remove" }
			local cleanup = load_cleanup(h)
			helpers.assert_eq(cleanup.open(make_remap(h, nil)), false)
			helpers.assert_eq(#h.alerts, 0)
			helpers.assert_eq(h.removals, 0)
			helpers.assert_true(not pcall(cleanup.open, {}), "a facade without the removal fails fast")
		end)
	end)

	helpers.it("keeps the maintainer's reference wording (karabiner-legacy-cleanup)", function()
		local locales = helpers.driver_root() .. "../_shared/data/locales/"
		local fr = hs.json.decode(SourceFile.read(locales .. "fr.json"))
		local en = hs.json.decode(SourceFile.read(locales .. "en.json"))
		helpers.assert_eq(fr["karabiner.legacy_cleanup.remove"], "Retirer les anciennes règles")
		helpers.assert_eq(fr["common.later"], "Plus tard")
		helpers.assert_eq(en["karabiner.legacy_cleanup.remove"], "Remove the old rules")
		for _, key in ipairs({ "karabiner.legacy_cleanup.body_one", "karabiner.legacy_cleanup.body_other" }) do
			helpers.assert_true(fr[key]:find("sauvegarde", 1, true) ~= nil, key .. " says a backup is made")
			helpers.assert_true(en[key]:find("backup", 1, true) ~= nil, key .. " says a backup is made")
		end
	end)
end)
