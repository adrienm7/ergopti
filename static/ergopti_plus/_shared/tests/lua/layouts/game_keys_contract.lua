--- _shared/tests/lua/layouts/game_keys_contract.lua

--- ==============================================================================
--- MODULE: Game Keys Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/layouts/game_keys_vectors.json against
--- `layouts.engine.emulation.game_keys`, which the Windows twin
--- (windows/modules/keymap/keylayout/game_keys.ahk) replays too, so the three
--- drivers resolve the same « Touches de jeu » choice, take the same route
--- and send the same keys held. Both Lua drivers register it with their own
--- paths.
--- ==============================================================================

local M = {}

--- Reads a whole file.
local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- A stable rendering of a string-keyed table, for one equality assertion.
local function render(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(map[key]) end
	return table.concat(parts, ",")
end

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
--- @param shared function Resolves a path under _shared.
function M.register(helpers, shared)
	local Json = require("core.text.engine.json")
	local GameKeys = require("layouts.engine.emulation.game_keys")
	local default_for = require("menu.engine.manifest_reader").default_for
	local vectors = Json.decode(read_all(shared("tests/corpus/layouts/game_keys_vectors.json")))

	helpers.describe("game keys (shared vectors)", function()
		helpers.it("resolves the stored choice and applications (game-keys-resolve)", function()
			for _, case in ipairs(vectors.resolve) do
				local reported = 0
				local settings = GameKeys.resolve({ layout = case.layout }, default_for, function() reported = reported + 1 end)
				helpers.assert_eq(settings.choice, case.expected.choice, case.name)
				helpers.assert_eq(render(settings.apps), render(case.expected.apps), case.name)
			end
		end)

		helpers.it("reports an outdated value once per leaf (game-keys-outdated)", function()
			local reported = {}
			GameKeys.resolve({ layout = { game_keys = "wasd", game_keys_apps = { ["x"] = 3 } } }, default_for,
				function(segments) reported[#reported + 1] = table.concat(segments, ".") end)
			helpers.assert_eq(table.concat(reported, " "), "layout.game_keys layout.game_keys_apps")
		end)

		helpers.it("finds the choice in force for an application (game-keys-choice-for)", function()
			for _, case in ipairs(vectors.choice_for) do
				local choice, overridden = GameKeys.choice_for(case.settings, case.platform, case.app)
				helpers.assert_eq(choice, case.expected.choice, case.name)
				helpers.assert_eq(overridden, case.expected.overridden, case.name)
				helpers.assert_eq(GameKeys.is_game(case.settings, case.platform, case.app), case.expected.overridden,
					case.name .. " (is a game)")
			end
		end)

		helpers.it("sets and clears an application's own choice (game-keys-apps-with)", function()
			for _, case in ipairs(vectors.apps_with) do
				helpers.assert_eq(render(GameKeys.apps_with(case.settings, case.platform, case.app, case.choice)),
					render(case.expected), case.name)
			end
		end)

		helpers.it("routes every OS, mode and choice (game-keys-routes)", function()
			for _, case in ipairs(vectors.routes) do
				local name = case.platform .. " " .. case.mode .. " " .. case.choice
				local route = GameKeys.route(case.platform, case.mode, case.choice, case.caps)
				helpers.assert_eq(route.available, case.expected.available, name .. " available")
				helpers.assert_eq(route.identity, case.expected.identity, name .. " identity")
				helpers.assert_eq(route.strategy, case.expected.strategy, name .. " strategy")
				helpers.assert_eq(route.reason_key, case.expected.reason_key, name .. " reason")
				helpers.assert_eq(route.note_key, case.expected.note_key, name .. " note")
			end
		end)

		helpers.it("sends a key held only when the system layout types it as the hand holds (game-keys-held)", function()
			for _, case in ipairs(vectors.held) do
				helpers.assert_eq(GameKeys.held_admissible(case.text, case.step, case.hand), case.expected, case.name)
			end
		end)

		helpers.it("writes the global choice or an application's own (game-keys-write)", function()
			local settings = { choice = "physical", apps = { ["game.exe"] = "letters" } }
			local global = GameKeys.write_values(settings, "windows", nil, "letters")
			helpers.assert_eq(global["layout.game_keys"], "letters", "the global leaf")
			local own = GameKeys.write_values(settings, "windows", "Other.exe", "physical")
			helpers.assert_eq(render(own["layout.game_keys_apps"]), "game.exe=letters,other.exe=physical")
			helpers.assert_nil(GameKeys.write_values(settings, "windows", nil, "wasd"), "a refused choice writes nothing")
			helpers.assert_nil(GameKeys.write_values(settings, "windows", "", "letters"), "no application, nothing")
		end)

		helpers.it("draws the global choice, its reason, its limit and the application's own (game-keys-menu)", function()
			local Rows = require("layouts.engine.emulation.menu")
			local chosen = {}
			local rows = Rows.game_keys_rows({
				t = function(key) return key end,
				settings = { choice = "physical", apps = {} }, app = "unciv", app_choice = nil,
				route = function(choice, game) return GameKeys.route("linux", "emulation", choice, { game = game }) end,
				choose = function(choice) chosen[#chosen + 1] = "global:" .. choice end,
				choose_app = function(choice) chosen[#chosen + 1] = "app:" .. tostring(choice) end,
			})
			local items = rows[1].items
			helpers.assert_eq(items[1].label, "menu.layout.game_keys.physical")
			helpers.assert_true(items[1].checked and items[1].radio, "physical is the default, one of a group")
			helpers.assert_true(items[1].disabled, "no installed Ergopti layout on Linux: greyed")
			helpers.assert_eq(items[1].disabled_reason_key, "platform_reason.game_keys_physical_needs_installed_layout")
			helpers.assert_true(not items[2].disabled, "the letters are honoured")
			local own = items[3].items
			helpers.assert_eq(#own, 3, "like the others, then the two choices")
			helpers.assert_true(own[1].checked, "no own choice yet")
			own[3].action()
			items[2].action()
			helpers.assert_eq(table.concat(chosen, " "), "app:letters global:letters")
			local none = Rows.game_keys_rows({ t = function(key) return key end, settings = { choice = "letters", apps = {} },
				route = function(choice) return GameKeys.route("windows", "emulation", choice, {}) end,
				choose = function() end, choose_app = function() end })
			local named = Rows.game_keys_rows({ t = function(key) return key == "menu.layout.game_keys_app" and "For {1}" or key end,
				settings = { choice = "letters", apps = {} }, app = "com.example.Game", app_name = "Game",
				route = function(choice) return GameKeys.route("macos", "emulation", choice, {}) end,
				choose = function() end, choose_app = function() end })
			local app_row = named[1].items[#named[1].items]
			helpers.assert_true(app_row.label:find("For Game", 1, true) == 1, "the row shows the name, not the bundle id")
			helpers.assert_true(not app_row.label:find("com.example", 1, true), "no identity in the row")
			local last = none[1].items[#none[1].items]
			helpers.assert_eq(last.label, "menu.layout.game_keys_no_app", "no application in front")
			helpers.assert_true(last.disabled)
		end)

		helpers.it("refuses an unknown platform, mode or choice (game-keys-fail-fast)", function()
			helpers.assert_true(not pcall(GameKeys.route, "beos", "emulation", "letters", {}), "unknown platform")
			helpers.assert_true(not pcall(GameKeys.route, "linux", "kanata", "letters", {}), "unknown mode")
			helpers.assert_true(not pcall(GameKeys.route, "linux", "emulation", "wasd", {}), "unknown choice")
			helpers.assert_true(not pcall(GameKeys.apps_with, { choice = "physical", apps = {} }, "linux", "", "letters"),
				"no application")
		end)
	end)
end

return M
