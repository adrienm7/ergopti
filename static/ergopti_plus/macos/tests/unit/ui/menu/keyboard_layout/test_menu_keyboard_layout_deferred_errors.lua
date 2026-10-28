--- tests/unit/ui/menu/keyboard_layout/test_menu_keyboard_layout_deferred_errors.lua

--- ==============================================================================
--- MODULE: Deferred Keyboard Layout Error Reporting
--- DESCRIPTION:
--- Drives rendered layout actions through the real deferred-work and timer
--- owners. Callback failures must reach their existing logged exception guard.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNERS = {
	"adapters.timer_scheduler", "infra.deferred_work", "infra.logger",
	"modules.keymap.input_sources", "modules.keymap.layout_install",
	"ui.menu.menu_keyboard_layout", "infra.manifest_menu",
	"infra.notifications", "infra.i18n",
}

--- Exercises one real rendered action through both retained continuations.
--- @param site string The continuation whose business callback raises.
local function exercise_failure(site)
	helpers.with_stub_scope(OWNERS, function()
		local sources = helpers.load_with_stubs("modules.keymap.input_sources")
		local install = require("modules.keymap.layout_install")
		local errors, native_timers = {}, hs.timer.__timers
		local logger = helpers.make_logger_stub()
		logger.error = function(_, template, ...)
			errors[#errors + 1] = string.format(template, ...)
		end
		package.loaded["infra.logger"] = logger
		-- Input-source construction loaded deferred work and its scheduler. Both
		-- continuation owners must capture this fixture's current logger and port.
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["infra.deferred_work"] = nil
		local scheduler = require("adapters.timer_scheduler")
		local marker = "controlled " .. site .. " callback failure"
		local dispatched, refreshed, business_done = 0, 0, nil
		sources.list_active_keyboard_layouts = function()
			return { { id = "French", name = "French", selected = false } }
		end
		sources.build_kl_name_to_tis_id = function() return {} end
		sources.resolve_installed_ergopti_version = function() return nil end
		sources.set_input_source_async = function(_, _, callback)
			dispatched = dispatched + 1
			if site == "dispatch" then error(marker) end
			business_done = callback
			return true
		end
		install.pick_latest_bundle = function() return nil end
		install.highest_installed = function() return nil end
		package.loaded["infra.notifications"] = { notify = function() return true end }

		local Json, Paths = require("json"), require("infra.paths")
		local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
		local labels = assert(Json.decode(assert(file:read("*a"))))
		assert(file:close())
		require("infra.i18n").get = function(key) return labels[key] or key end
		local renderer = require("infra.manifest_menu")
		package.loaded["infra.manifest_menu"] = {
			template_rows = renderer.template_rows,
			status_rows = renderer.status_rows,
			group_row = renderer.group_row,
			build = function(_, _, _, _, _, providers) return providers.active_layouts() end,
		}
		local menu = require("ui.menu.menu_keyboard_layout").build({
			base_dir = "/tmp/ergopti/",
			updateMenu = function()
				refreshed = refreshed + 1
				error(marker)
			end,
		})
		helpers.assert_eq(#menu.submenu, 1, "the actual manifest exposes the native layout row")
		local before = #native_timers
		menu.submenu[1].action()
		helpers.assert_eq(dispatched, 0, "the native mutation never runs inside the menu click")
		helpers.assert_eq(#native_timers, before + 1)
		native_timers[before + 1]:fire()
		helpers.assert_eq(dispatched, 1)
		if site == "refresh" then
			helpers.assert_true(type(business_done) == "function")
			business_done(false)
			helpers.assert_eq(refreshed, 0, "refresh remains deferred after the business terminal")
			helpers.assert_eq(#native_timers, before + 2)
			native_timers[before + 2]:fire()
			helpers.assert_eq(refreshed, 1)
		end
		helpers.assert_eq(#errors, 1, "the real scheduler reports the exception exactly once")
		helpers.assert_contains(errors[1], marker, "the original callback failure remains visible")
		helpers.assert_contains(errors[1], "callback raised", "the existing exception guard owns reporting")
		helpers.assert_eq(scheduler.activeCount(), 0, "all native one-shot timers have retired")
	end)
end

helpers.describe("keyboard layout deferred callback visibility", function()
	for _, site in ipairs({ "dispatch", "refresh" }) do
		helpers.it("reports " .. site .. " errors through the real timer guard (layout-deferred-errors)", function()
			exercise_failure(site)
		end)
	end
end)
