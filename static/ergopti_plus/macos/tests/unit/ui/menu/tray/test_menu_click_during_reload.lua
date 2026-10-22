--- tests/unit/ui/menu/tray/test_menu_click_during_reload.lua

--- ==============================================================================
--- MODULE: Menubar Click During A Reload Regression
--- DESCRIPTION:
--- Boots the real ui.menu.start over doubles. The static menubar stays
--- clickable through a controlled reload, and every save is refused there, so
--- a toggle clicked then half applied in RAM and vanished with the reload.
--- The click must be held instead, handed to the reloaded menu at teardown and
--- replayed there once, unless its row already shows the state it asked for.
--- ==============================================================================

local helpers = require("tests.helpers")
local boot = require("tests.support.menu_boot_fixture").boot

local REPLAY_KEY = "menu_reload_replay"

--- Boots a menubar whose one check row reads and flips a shared switch.
--- @param switch table { on, runs } shared across generations.
--- @param before_start function|nil Seeds the store of a successor boot.
--- @return table fixture
--- @return table items The published, gated tree.
local function boot_with_row(switch, before_start)
	local fixture = boot({
		before_start = before_start,
		generate = function()
			local shown = switch.on
			return { { title = "Features", menu = { { title = "Preview", checked = shown, fn = function()
				switch.runs = switch.runs + 1
				switch.on = not switch.on
			end } } } }
		end,
	})
	helpers.assert_type(fixture.menu_provider, "function", "the menu publishes its dynamic provider")
	return fixture, fixture.menu_provider()
end

helpers.describe("menubar click during a reload (menu-click-reload-handoff)", function()
	helpers.it("(menu-click-reload-held) holds a click made while a reload is pending", function()
		local switch = { on = false, runs = 0 }
		local fixture, items = boot_with_row(switch)
		fixture.terminal_pending = true
		items[1].menu[1].fn({}, {})
		helpers.assert_eq(switch.runs, 0, "a click during a reload must not run against a dying generation")
		require("infra.reload_guard").mark_reload()
		helpers.assert_true(fixture.menu ~= nil)
		helpers.assert_true(require("ui.menu.init").stop_watchers())
		local stored = require("adapters.storage").get(REPLAY_KEY, nil)
		helpers.assert_type(stored, "string", "the held click is handed to the reloaded menu")
		local record = require("json").decode(stored)
		helpers.assert_eq(#record.clicks, 1)
		helpers.assert_eq(record.clicks[1].path, { "Features", "Preview" })
		helpers.assert_eq(record.clicks[1].desired, true, "the click asks for the opposite of the checkmark")
	end)

	helpers.it("(menu-click-reload-replayed) replays a handed-off click once in the successor", function()
		local switch = { on = false, runs = 0 }
		local record = require("json").encode({ schema = 1, at = os.time(),
			clicks = { { path = { "Features", "Preview" }, desired = true } } })
		local fixture = boot_with_row(switch, function()
			helpers.assert_true(require("adapters.storage").set(REPLAY_KEY, record))
		end)
		helpers.assert_eq(require("adapters.storage").get(REPLAY_KEY, nil), nil, "the hand-off is consumed once")
		_G.hs.timer.__fire_all()
		helpers.assert_eq(switch.runs, 1, "the successor runs the held click")
		helpers.assert_eq(switch.on, true)
		helpers.assert_true(fixture.menu ~= nil)
	end)

	helpers.it("(menu-click-reload-intent-skip) skips a handed-off click whose row already shows its state", function()
		local switch = { on = true, runs = 0 }
		local record = require("json").encode({ schema = 1, at = os.time(),
			clicks = { { path = { "Features", "Preview" }, desired = true } } })
		local fixture = boot_with_row(switch, function()
			helpers.assert_true(require("adapters.storage").set(REPLAY_KEY, record))
		end)
		_G.hs.timer.__fire_all()
		helpers.assert_eq(switch.runs, 0, "running it would toggle the row back off")
		helpers.assert_eq(switch.on, true)
		local skipped = false
		for _, message in ipairs(fixture.logs.infos) do
			if message:find("skipped: the row is already checked", 1, true) then skipped = true end
		end
		helpers.assert_true(skipped, "the skip is logged, so the replay provably reached the row")
	end)

	helpers.it("(menu-click-stale-tree) resolves a click on a stale tree by its row path", function()
		local switch = { on = false, runs = 0 }
		local fixture, items = boot_with_row(switch)
		local stale = items[1].menu[1].fn
		stale({}, {})
		helpers.assert_eq(switch.runs, 1)
		-- The row changed state; the published tree still shows it unchecked.
		fixture.ctx.updateMenu()
		stale({}, {})
		helpers.assert_eq(switch.runs, 1, "a second click on the old checkmark must not toggle the row back")
		helpers.assert_eq(switch.on, true)
	end)
end)
