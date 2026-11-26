--- tests/unit/modules/keymap/test_game_keys_focus.lua

--- ==============================================================================
--- MODULE: Game Keys Focus (Linux)
--- DESCRIPTION:
--- « Touches de jeu » at their physical place in a game under the layout
--- emulation: with the Ergopti XKB layout in the session, a game whose own
--- choice is "physical" gets that layout while focused and the emulation
--- lets its keys through; the previous layout comes back when it loses the
--- focus. Recorded switcher, no desktop.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fixture(apps, opts)
	opts = opts or {}
	package.loaded["modules.keymap.game_keys_focus"] = nil
	local M = require("modules.keymap.game_keys_focus")
	local record = { selected = {}, refreshed = 0, select_ok = opts.select_ok ~= false, games = {} }
	local choices = opts.choices or { { id = "fr", label = "French", active = true },
		{ id = "fr(ergopti)", label = "French (Ergopti)", active = false } }
	local switcher = {
		choices = function() return choices end,
		refresh = function(done) record.refreshed = record.refreshed + 1; done(false) end,
		select = function(id, done) record.selected[#record.selected + 1] = id; done(record.select_ok, "refused") end,
	}
	M.init({
		settings = function() return { choice = opts.choice or "physical", apps = apps } end,
		emulation = function() return { active = opts.emulating ~= false, ergopti = opts.ergopti ~= false } end,
		switcher = function() return switcher end,
		set_game = function(game) record.games[#record.games + 1] = game end,
	})
	return M, record
end

helpers.describe("game keys focus (Linux)", function()
	helpers.it("switches a physical game to the installed Ergopti layout and back (game-keys-switch-installed)", function()
		local M, record = fixture({ unciv = "physical" })
		M.on_focus("Unciv")
		helpers.assert_true(M.passes_through(), "the emulation lets the game's keys through")
		helpers.assert_eq(record.selected, { "fr(ergopti)" }, "the installed layout types there")
		M.on_focus("org.gnome.TextEditor")
		helpers.assert_true(not M.passes_through(), "another application is emulated again")
		helpers.assert_eq(record.selected, { "fr(ergopti)", "fr" }, "the previous layout comes back")
		helpers.assert_eq(record.refreshed, 1, "the session's layouts are read once")
		helpers.assert_eq(record.games[#record.games], false, "the editor keeps its tap-holds")
		helpers.assert_true(record.games[1] == true, "the game skipped them (game-keys-tap-holds)")
	end)

	helpers.it("leaves an application without its own choice emulated (game-keys-switch-installed)", function()
		local M, record = fixture({})
		M.on_focus("unciv")
		helpers.assert_true(not M.passes_through())
		helpers.assert_eq(#record.selected, 0, "only a game switches the session layout")
	end)

	helpers.it("switches nothing without the installed layout or an Ergopti emulation (game-keys-switch-installed)", function()
		local M, record = fixture({ unciv = "physical" }, { choices = { { id = "us", label = "English", active = true } } })
		M.on_focus("unciv")
		helpers.assert_true(not M.passes_through(), "no Ergopti layout in the session")
		local route = M.route("unciv")
		helpers.assert_eq(route.reason_key, "platform_reason.game_keys_physical_needs_installed_layout",
			"the menu names why")
		local other, other_record = fixture({ unciv = "physical" }, { ergopti = false })
		other.on_focus("unciv")
		helpers.assert_true(not other.passes_through(), "a bépo emulation is not what the Ergopti layout types")
		helpers.assert_eq(#other_record.selected, 0)
	end)

	helpers.it("types through the emulation again when the switch is refused (game-keys-switch-installed)", function()
		local M, record = fixture({ unciv = "physical" }, { select_ok = false })
		M.on_focus("unciv")
		helpers.assert_true(not M.passes_through(), "a refused switch leaves the emulation typing")
		helpers.assert_eq(record.selected, { "fr(ergopti)" })
	end)

	helpers.it("refuses a second initialization and a focus before the first (game-keys-focus-owner)", function()
		local M = fixture({})
		helpers.assert_true(not pcall(M.init, { settings = function() end, emulation = function() end,
			switcher = function() end, set_game = function() end }), "one owner")
		M._reset_for_test()
		helpers.assert_true(not pcall(M.on_focus, "unciv"), "no focus before init")
		helpers.assert_true(not M.is_initialised())
	end)
end)
