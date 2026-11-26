--- tests/meta/harness/test_runner_double_leak_guard.lua

--- ==============================================================================
--- MODULE: Runner Double Leak Guard
--- DESCRIPTION:
--- helpers.measure_module restores every product module a test module left
--- replaced by a test double, and fails that module by name. One fixture that
--- failed before its own restore otherwise left its doubles for every later
--- module: the document fixture's timings double failed about 1200 Linux tests.
--- It also forgets a tray root left cached under a manifest facade a module
--- replaced, a root that then built an empty tray for every later module.
--- These cases drive the detectors directly, so they record no runner failure.
--- ==============================================================================

local helpers = require("tests.helpers")

--- @return table before Shallow copy of package.loaded.
local function snapshot()
	local before = {}
	for key, value in pairs(package.loaded) do before[key] = value end
	return before
end

helpers.describe("runner: test doubles never outlive their module", function()
	helpers.it("restores a replaced and a new double, and names both", function()
		-- A real product module absent from the cache stands for a new double, so
		-- the probe stubs a module that exists (test-stubs-intercept-something).
		local previous_events = package.loaded["metrics.engine.system.session_events"]
		package.loaded["metrics.engine.system.session_events"] = nil
		local before = snapshot()
		local real_monotonic = package.loaded["core.logger.engine.monotonic"]
		package.loaded["core.logger.engine.monotonic"] = { now_ms = function() return 0 end }
		package.loaded["metrics.engine.system.session_events"] = { new = function() return {} end }
		local leaked = helpers.restore_leaked_doubles(before)
		local new_double = package.loaded["metrics.engine.system.session_events"]
		package.loaded["metrics.engine.system.session_events"] = previous_events
		helpers.assert_eq(table.concat(leaked, ","), "core.logger.engine.monotonic,metrics.engine.system.session_events")
		helpers.assert_true(rawequal(package.loaded["core.logger.engine.monotonic"], real_monotonic),
			"the replaced product module is the original object again")
		helpers.assert_eq(new_double, nil, "a new double is removed")
	end)

	helpers.it("keeps a real module a test reloaded and test-support modules", function()
		local before = snapshot()
		local previous_text = package.loaded["core.text.engine.utils_core"]
		package.loaded["core.text.engine.utils_core"] = nil
		local fresh = require("core.text.engine.utils_core")
		local previous_fixture = package.loaded["tests.support.document_fixture"]
		package.loaded["tests.support.document_fixture"] = { call = function() return true end }
		local leaked = helpers.restore_leaked_doubles(before)
		helpers.assert_eq(#leaked, 0, "only doubles of product modules are restored: "
			.. table.concat(leaked, ","))
		helpers.assert_true(rawequal(package.loaded["core.text.engine.utils_core"], fresh), "a real reload stays")
		package.loaded["core.text.engine.utils_core"] = previous_text
		package.loaded["tests.support.document_fixture"] = previous_fixture
	end)
end)

helpers.describe("runner: the tray root never outlives its manifest facade", function()
	local ROOT, FACADE = "menu.ui.builder.builder", "menu.engine.manifest_menu"

	--- Runs `body` over stand-in root and facade entries, then puts the real ones back.
	--- @param body function Receives (root, facade).
	local function with_tray_pair(body)
		local restore = helpers.keep_loaded({ ROOT, FACADE })
		local root, facade = { name = "root" }, { name = "facade" }
		package.loaded[ROOT], package.loaded[FACADE] = root, facade
		local ok, err = pcall(body, root, facade)
		restore()
		if not ok then error(err, 0) end
	end

	helpers.it("forgets the cached tray root when a module replaced its facade", function()
		with_tray_pair(function()
			local before = snapshot()
			local reloaded = { name = "reloaded facade" }
			package.loaded[FACADE] = reloaded
			helpers.assert_true(helpers.forget_stale_tray_root(before), "the stale root is detected")
			helpers.assert_nil(package.loaded[ROOT], "the next require binds a fresh root")
			helpers.assert_true(rawequal(package.loaded[FACADE], reloaded), "the facade later modules captured stays")
		end)
	end)

	helpers.it("keeps a facade reloaded together with its root, or with no root cached", function()
		with_tray_pair(function()
			local before = snapshot()
			local facade, root = { name = "new facade" }, { name = "new root" }
			package.loaded[FACADE], package.loaded[ROOT] = facade, root
			helpers.assert_eq(helpers.forget_stale_tray_root(before), false)
			helpers.assert_true(rawequal(package.loaded[ROOT], root), "a consistent reload stays")
			package.loaded[ROOT] = nil
			before = snapshot()
			package.loaded[FACADE] = { name = "later facade" }
			helpers.assert_eq(helpers.forget_stale_tray_root(before), false, "no cached root reads the old facade")
		end)
	end)
end)
