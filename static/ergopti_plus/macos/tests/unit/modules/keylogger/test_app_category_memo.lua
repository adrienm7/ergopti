--- tests/unit/modules/keylogger/test_app_category_memo.lua

--- ==============================================================================
--- MODULE: Regression — the app-category memo must cache the permanent miss, and
---         only the permanent miss
--- DESCRIPTION:
--- `get_native_app_category` resolves an app's category with a
--- running-application scan plus an Info.plist read from disk, and the ingest tick
--- calls it INSIDE the open SQLite write transaction — so the database stays locked
--- for a filesystem round-trip per distinct app, on a timer. The memo exists to
--- remove that, and its comment states that "a miss is cached too". The code only
--- ever stored `resolved ~= nil`, so every app without a category re-ran the whole
--- probe on every tick, for the life of the process.
---
--- ROOT CAUSE ENCODED:
--- A comment describing behaviour the code does not have. The assertions below
--- count OS probes across repeated calls, so they are about the cost that was
--- being paid rather than about the shape of the cache table.
---
--- THE DISTINCTION THAT MATTERS, and why "cache every miss" would be wrong:
--- there are two structurally different misses.
---   * The app resolved but its bundle carries no LSApplicationCategoryType. That
---     is a property of the installed bundle and is safe to memoise forever.
---   * hs.application.get() returned nil because the app is not running RIGHT NOW.
---     That is a property of this instant, not of the name. Memoising it would
---     poison the table — and the worst case is the recovery path, which replays
---     historic ledger rows whose apps are mostly not running, so one recovery
---     pass would pin dozens of names to the general fallback for days.
--- ==============================================================================

local helpers = require("tests.helpers")

local CATEGORISED   = "AppWithCategory"
local NO_CATEGORY   = "AppWithoutCategory"
local NOT_RUNNING   = "AppNotRunning"


--- Loads keylogger.export with hs.application instrumented.
--- @return table Export, function probe_count
local function load_export()
	package.loaded["modules.keylogger.export"] = nil
	package.loaded["infra.logger"] = nil
	_ = helpers.load_with_stubs("infra.logger")
	package.loaded["infra.i18n"] = { get = function(k) return k end }

	local probes = { get = 0, info = 0 }
	local Export = helpers.load_with_stubs("modules.keylogger.export", {
		application = {
			-- Faithful to the real API's shape: get() returns nil for an app that is
			-- not running, and a userdata-like object with :path() otherwise.
			get = function(name)
				probes.get = probes.get + 1
				if name == NOT_RUNNING then return nil end
				return { path = function() return "/Applications/" .. name .. ".app" end }
			end,
			infoForBundlePath = function(path)
				probes.info = probes.info + 1
				if path:find(CATEGORISED, 1, true) then
					return { LSApplicationCategoryType = "public.app-category.productivity" }
				end
				-- Installed, readable, and simply carries no category key.
				return {}
			end,
		},
	})
	return Export, function() return probes end
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ A permanent miss is memoised ==========================
-- ==================================================================
-- ==================================================================

helpers.describe("app category: a bundle with no category is probed once", function()

	helpers.it("does not re-probe an app whose bundle carries no category", function()
		local Export, probes = load_export()
		helpers.assert_type(Export.get_native_app_category, "function",
			"export must expose get_native_app_category")

		Export.get_native_app_category(NO_CATEGORY)
		local after_first = probes().info
		helpers.assert_true(after_first >= 1,
			"the first call must actually read the bundle, or the assertion below would pass "
			.. "against a function that probes nothing at all")

		Export.get_native_app_category(NO_CATEGORY)
		Export.get_native_app_category(NO_CATEGORY)

		helpers.assert_eq(probes().info, after_first,
			"an installed bundle's LSApplicationCategoryType does not change, so this must be "
			.. "learned once. It is read inside the open SQLite write transaction on the "
			.. "ingest tick, so every repeat locks the database for a filesystem round-trip")
	end)

	helpers.it("still memoises the successful lookup", function()
		local Export, probes = load_export()
		Export.get_native_app_category(CATEGORISED)
		local after_first = probes().info
		Export.get_native_app_category(CATEGORISED)
		helpers.assert_eq(probes().info, after_first,
			"the case that already worked must keep working")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ A transient miss is NOT memoised ======================
-- ==================================================================
-- ==================================================================

helpers.describe("app category: a not-running app stays re-checkable", function()

	helpers.it("re-probes an app that was not running", function()
		local Export, probes = load_export()

		Export.get_native_app_category(NOT_RUNNING)
		local after_first = probes().get
		Export.get_native_app_category(NOT_RUNNING)

		helpers.assert_true(probes().get > after_first,
			"hs.application.get() returning nil is a property of this instant, not of the "
			.. "name. Memoising it would poison the table — the recovery path replays "
			.. "historic ledger rows whose apps are mostly not running, so one pass would pin "
			.. "dozens of names to the general fallback for the life of the process")
	end)

end)
