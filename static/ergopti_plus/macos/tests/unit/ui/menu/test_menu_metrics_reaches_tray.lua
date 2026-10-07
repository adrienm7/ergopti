--- tests/unit/ui/menu/test_menu_metrics_reaches_tray.lua

--- ==============================================================================
--- MODULE: Regression — the Metrics submenu reaches the tray populated
--- DESCRIPTION:
--- The tray root is rendered as provider DATA, where a subtree hangs on `items`
--- (rows to materialise) or `submenu` (a tree already materialised). The
--- Metrics row hung its already-rendered tree on `menu`, a field the renderer
--- never reads on a provider row, so the Metrics entry opened empty on the real
--- menu bar. This renders the real row through the tray's own call.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Metrics submenu reaches the tray populated", function()
	helpers.it("the rendered tray row carries the manifest's metrics rows", function()
		local metrics = helpers.load_with_stubs("ui.menu.menu_metrics")
		local ManifestMenu = require("infra.manifest_menu")
		local item = metrics.build({
			state      = {},
			save_prefs = function() return true end,
			updateMenu = function() end,
		})
		helpers.assert_true(type(item) == "table", "menu_metrics.build must return a row")
		helpers.assert_nil(item.menu,
			"a provider row never carries `menu`: the renderer does not read it")

		local row = ManifestMenu.render_rows({ item }, "top_level")[1]
		helpers.assert_true(type(row) == "table" and type(row.menu) == "table" and #row.menu > 0,
			"the Metrics submenu reached the tray empty")
		local found = false
		for _, entry in ipairs(row.menu) do
			if entry.title == "menu.metrics.show_typing" then found = true end
		end
		helpers.assert_true(found, "the manifest's show_typing row must be in the rendered Metrics submenu")
	end)
end)


--- Replays the genuine Metrics owner without changing its completed child route.
--- @param body function Structural source and parent assertions.
local function metrics_parent_fixture(body)
	local names = { "ui.menu.menu_metrics", "infra.manifest_menu", "infra.i18n", "infra.locale", "locale.core", "hs.fs" }
	local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	package.loaded["hs.fs"] = hs.fs
	local renderer, locale = require("infra.manifest_menu"), require("infra.locale")
	local language = locale.current_locale()
	locale.set_locale("en")
	local native = require("ui.menu.menu_metrics")
	local observed = { builds=0, parents=0, getters=0 }
	local function build(paused, enabled)
		local state = { keylogger_enabled=enabled }
		local item = native.build({ state=state, save_prefs=function()return true end,
			updateMenu=function()end, script_control={is_paused=function()return paused==true end} })
		if item == nil then return nil end
		return renderer.render_rows({item}, "metrics_parent_test")[1]
	end
	local ok, detail = xpcall(function() body(renderer,build,observed,locale) end, debug.traceback)
	locale.set_locale(language)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail,0) end
end
local metrics_parent_file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/metrics_parent.json", "rb"))
local metrics_parent_raw = metrics_parent_file:read("*a");metrics_parent_file:close()
require("test.metrics_parent_contract").register(helpers, metrics_parent_fixture,
	assert(require("adapters.json_codec").decode(metrics_parent_raw)), "hs")
