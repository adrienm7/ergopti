--- tests/unit/ui/menu/test_menu_keyboard_layout_latency.lua

--- ==============================================================================
--- MODULE: Menubar Open-Latency Regression Guards
--- DESCRIPTION:
--- Locks in the fix for the ~1 s menubar-open latency. ROOT CAUSE: the menu
--- callback rebuilt the keyboard-layout submenu on every click, and that build
--- ran a python3 + `defaults export` probe (list_active_keyboard_layouts)
--- SYNCHRONOUSLY, plus several redundant bundle directory scans. A python3 cold
--- start alone is 300 ms–1 s.
---
--- THE FIX: bundle discovery is memoised for the session, and the active-layout
--- list is served from a cache that is refreshed ASYNCHRONOUSLY (hs.task, inline
--- `python3 -c`) off the click path. These tests assert that the warm open path
--- spawns no blocking subprocess and that the async probe output is parsed
--- correctly, so the latency can never silently return.
--- ==============================================================================

local helpers = require("tests.helpers")


-- A hs.task stub whose completion callback fires synchronously with canned
-- stdout, so the otherwise-async refresh resolves deterministically in-test.
local function task_stub_firing(stdout)
	return {
		new = function(_path, cb, _args)
			local task
			task = {
				start     = function()
					if cb then cb(0, stdout, "") end
					return task
				end,
				terminate = function() end,
			}
			return task
		end,
	}
end






--- ===================================================
--- ===================================================
--- ======= 1) Active-layout JSON parser (pure) =======
--- ===================================================
--- ===================================================

helpers.describe("menu_keyboard_layout._parse_active_layouts", function()
	local kbd = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")

	helpers.it("parses a JSON array of KeyboardLayout Names into records", function()
		local recs = kbd._parse_active_layouts('["French","Ergopti_v2_2_2_plus"]', nil)
		helpers.assert_true(type(recs) == "table" and #recs == 2, "two records expected")
		helpers.assert_eq(recs[1].id, "French")
		helpers.assert_eq(recs[2].id, "Ergopti_v2_2_2_plus")
		-- The raw versioned KeyboardLayout Name renders via the friendly formatter,
		-- which keeps the embedded version (the stable id form has none).
		helpers.assert_eq(recs[2].name, "Ergopti+ v2.2.2")
	end)

	helpers.it("computes `selected` live against the current layout name", function()
		local recs = kbd._parse_active_layouts('["French","Ergopti_v2_2_2_plus"]', "French")
		helpers.assert_true(recs[1].selected, "French must be selected")
		helpers.assert_true(not recs[2].selected, "Ergopti must not be selected")
	end)

	helpers.it("returns nil on non-array (probe error) output", function()
		helpers.assert_nil(kbd._parse_active_layouts("ERR:boom", nil))
		helpers.assert_nil(kbd._parse_active_layouts(nil, nil))
	end)
end)




--- ==========================================================
--- ====== 2) Open path is subprocess-free (root cause) ======
--- ==========================================================

helpers.describe("menu_keyboard_layout active-layout open path", function()
	helpers.it("serves the cache without ANY synchronous hs.execute call", function()
		local kbd = helpers.load_with_stubs("ui.menu.menu_keyboard_layout", {
			-- hs.task present → the async refresh uses it, never a blocking hs.execute.
			task = task_stub_firing('["French"]'),
		})
		-- Warm the cache as if a startup prime / earlier probe had populated it.
		kbd._set_active_layouts_cache({ { id = "French", name = "French", selected = false } })

		local before  = #hs.__exec_calls
		local records = kbd._list_active_keyboard_layouts()
		local after   = #hs.__exec_calls

		helpers.assert_eq(after, before,
			"the menu-open path must NOT spawn a blocking subprocess (python3 was the ~1 s cost)")
		helpers.assert_true(type(records) == "table" and #records >= 1, "records served from cache")
	end)
end)




-- =================================================
-- ===== 3) Async refresh updates the cache ========
-- =================================================

helpers.describe("menu_keyboard_layout async refresh", function()
	helpers.it("updates the cache from the probe stdout via hs.task", function()
		package.loaded["adapters.shell_runner"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		local kbd = helpers.load_with_stubs("ui.menu.menu_keyboard_layout", {
			task = task_stub_firing('["French","Ergopti_v2_2_2_plus"]'),
		})
		local done = false
		kbd._refresh_active_layouts_async(function() done = true end)
		helpers.assert_true(done, "on_done must fire when the task completes")

		-- A subsequent cache-served list reflects exactly the probed layouts.
		local records = kbd._list_active_keyboard_layouts()
		helpers.assert_eq(#records, 2, "cache must hold the two probed layouts")
		helpers.assert_eq(records[1].id, "French")
		helpers.assert_eq(records[2].id, "Ergopti_v2_2_2_plus")
	end)
end)




-- =================================================
-- ===== 4) Bundle discovery memoisation ===========
-- =================================================

helpers.describe("menu_keyboard_layout.pick_latest_bundle (memoised)", function()
	helpers.it("returns a stable result across repeated calls and honours invalidation", function()
		local kbd = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
		local bundles_dir = helpers.fixtures_dir() .. "bundles/"
		local first  = kbd.pick_latest_bundle(bundles_dir)
		local second = kbd.pick_latest_bundle(bundles_dir)
		helpers.assert_eq(second, first, "memoised lookup must be stable")
		helpers.assert_true(type(first) == "string" and first:match("^Ergopti_v[%d%.]+%.bundle$") ~= nil,
			"expected a bundle name, got " .. tostring(first))
		-- The invalidation hook exists and a fresh scan still yields the same bundle.
		helpers.assert_true(type(kbd._invalidate_bundle_caches) == "function",
			"invalidation hook must be exposed for install-time cache refresh")
		kbd._invalidate_bundle_caches()
		helpers.assert_eq(kbd.pick_latest_bundle(bundles_dir), first, "post-invalidation scan must agree")
	end)
end)




-- =================================================
-- ===== 5) Apps discovery is cached per session ===
-- =================================================

helpers.describe("menu_apps discovery cache", function()
	helpers.it("scans the apps/ directory at most once across repeated menu opens", function()
		local find_calls = 0
		-- Count `find … -name '*.app'` invocations; everything else is a no-op.
		local exec = function(cmd)
			if type(cmd) == "string" and cmd:find("-name '*.app'", 1, true) then
				find_calls = find_calls + 1
			end
			return "", true, "exit", 0
		end
		local apps = helpers.load_with_stubs("ui.menu.menu_apps", { execute = exec })
		local ctx  = { base_dir = "/tmp/ergopti-no-apps/", paused = false }
		apps.build(ctx)
		apps.build(ctx)
		helpers.assert_true(find_calls <= 1,
			"apps/ must be scanned at most once across opens, got " .. tostring(find_calls))
	end)
end)
