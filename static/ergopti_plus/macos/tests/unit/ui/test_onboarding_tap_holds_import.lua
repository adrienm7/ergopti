--- tests/unit/ui/test_onboarding_tap_holds_import.lua

--- ==============================================================================
--- MODULE: Regression — the wizard's Tap-Holds answer imports the checked keys
--- DESCRIPTION:
--- The first-run wizard's Tap-Holds page asked nothing on macOS: the switch
--- lives in config_karabiner.toml, where a config.toml answer is never read,
--- so the page showed a note and a Yes imported no key.
---
--- ROOT CAUSE ENCODED:
--- the page had no per-key checklist and the host had no route to the remap
--- owner. The checked keys now reach it: a running bridge takes them in its
--- settings transaction, and before it starts (the first run) or for a folder
--- the wizard moves the configuration to, the owner saves them to that folder's
--- file, each time over a backup of its own beside that file. No tap-hold key
--- reaches config.toml, an unchecked key or a No imports nothing, and the
--- reload waits for the import, never past a bounded timeout. A notice waits
--- for deferred work, never inside the owner's callback, and a reload the
--- termination coordinator refuses or aborts tells the user one is needed.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_finish_fixture")
local with_finish = Fixture.with_finish

local RELOAD, NOTICE, TIMEOUT = "onboarding.reload", "onboarding.notice", "onboarding.tap_holds_import_timeout"

--- A finish payload answering the Tap-Holds page and one config.toml question.
--- @param keys table Key id -> checked.
--- @param config_dir string|nil Folder typed on the config page.
--- @return table answers
local function answers(keys, config_dir)
	local operations = { { path = "llm.enabled", value = true } }
	for _, key in ipairs({ "caps_lock", "tab", "left_command" }) do
		if keys[key] ~= nil then
			operations[#operations + 1] = { path = "tap_holds.keys." .. key, value = keys[key] }
		end
	end
	return { locale = "en", config_dir = config_dir or "", operations = operations }
end

--- Asserts that one import named a new backup beside the remap settings.
--- @param state table Fixture state.
local function assert_one_backup(state)
	helpers.assert_eq(#state.backups, 1)
	local pattern = "^" .. Fixture.KARABINER_CONFIG_PATH:gsub("%p", "%%%0") .. "%.tap_holds%-%d+%-%d+%.bak$"
	helpers.assert_true(state.backups[1]:find(pattern) ~= nil,
		"the settings are backed up beside themselves first: " .. tostring(state.backups[1]))
end

--- Asserts that config.toml received only the configuration answer.
--- @param state table Fixture state.
local function assert_only_config_rows(state)
	helpers.assert_eq(#state.writes, 1)
	helpers.assert_eq(state.writes[1].rows, { { section = "llm", key = "enabled", value = true } },
		"no tap-hold key reaches config.toml")
end





-- ===============================================
-- ===============================================
-- ======= 1/ The Checked Keys Reach Remap =======
-- ===============================================
-- ===============================================

helpers.describe("the wizard's Tap-Holds answer imports the checked keys", function()
	helpers.it("saves them to the folder's remap file before the bridge starts (first run)", function()
		with_finish({ answers = answers({ caps_lock = true, tab = false, left_command = true }) }, function(state)
			assert_only_config_rows(state)
			helpers.assert_eq(#state.imports, 0, "no running bridge to take them")
			helpers.assert_eq(state.saves, { { keys = { "caps_lock", "left_command" },
				path = Fixture.KARABINER_CONFIG_PATH } }, "only the checked keys, in the folder's own file")
			assert_one_backup(state)
			helpers.assert_eq(state.notifications, 1)
			helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1, "then the reload starts the bridge on them")
			helpers.assert_eq(#state.alerts, 0)
		end)
	end)

	helpers.it("hands them to the running bridge and reloads only once it answered", function()
		with_finish({ answers = answers({ caps_lock = true }), remap = { running = true, hold_import = true } },
			function(state)
				assert_only_config_rows(state)
				helpers.assert_eq(state.imports, { { "caps_lock" } })
				assert_one_backup(state)
				helpers.assert_eq(#state.saves, 0, "a running bridge's file is never written behind it")
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 0, "no reload while the Karabiner transaction runs")
				state.import_callbacks[1](true, "ready", 1)
				helpers.assert_eq(state.notifications, 1)
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1)
				helpers.assert_eq(#state.alerts, 0)
			end)
	end)

	-- An initialized bridge that stopped refuses every transaction: routed to
	-- it, the keys were refused as "lifecycle-inactive" and never saved.
	helpers.it("saves them to the file of a bridge that stopped", function()
		with_finish({ answers = answers({ caps_lock = true }), remap = { initialized = true, running = false } },
			function(state)
				helpers.assert_eq(#state.imports, 0, "a stopped bridge takes no transaction")
				helpers.assert_eq(state.saves, { { keys = { "caps_lock" }, path = Fixture.KARABINER_CONFIG_PATH } })
				helpers.assert_eq(#state.alerts, 0)
			end)
	end)

	helpers.it("saves them to the new folder's file when the wizard moves the configuration", function()
		local menu_paths = {
			persist_config_dir_for_wizard = function() return true end,
			get = function() return "/virtual/moved/hammerspoon/config.toml" end,
		}
		with_finish({ answers = answers({ tab = true }, "/virtual/moved"), remap = { running = true },
			menu_paths = menu_paths }, function(state)
			helpers.assert_eq(state.writes[1].path, "/virtual/moved/hammerspoon/config.toml")
			helpers.assert_eq(#state.imports, 0,
				"the running bridge holds the previous folder's settings and would copy them over")
			helpers.assert_eq(state.saves, { { keys = { "tab" }, path = Fixture.KARABINER_CONFIG_PATH } })
		end)
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ A Re-Run Shows What Is In Force ====
-- ===============================================
-- ===============================================

-- A re-run started the page from nothing: every key pre-checked and imported
-- over the user's own settings, and the question at No with Tap-Holds on.
helpers.describe("a re-run shows the tap-hold keys in force", function()
	helpers.it("reads each key and the switch from the remap settings beside config.toml", function()
		local report = { enabled = true, keys = { caps_lock = "recommended", tab = "customised" } }
		with_finish({ remap = { report = report } }, function(state, onboarding)
			local values = onboarding._current_values("/virtual/hammerspoon/config.toml")
			helpers.assert_eq(state.reports, { Fixture.KARABINER_CONFIG_PATH }, "the folder's own remap settings")
			helpers.assert_eq(values["tap_holds.keys.caps_lock"], true, "an imported key reads as on")
			helpers.assert_eq(values["tap_holds.keys.tab"], "customised", "a customised key reads as kept")
			helpers.assert_nil(values["tap_holds.keys.left_command"], "a free key stays choosable")
			helpers.assert_eq(values["tap_holds.enabled"], true, "the question starts from the switch in force")
		end)
	end)

	helpers.it("fails the read rather than show a customised folder as neutral", function()
		with_finish({}, function(_, onboarding)
			helpers.assert_nil(onboarding._current_values("/virtual/hammerspoon/config.toml"))
		end)
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 3/ Nothing Else Is Written ============
-- ===============================================
-- ===============================================

helpers.describe("the wizard imports nothing it was not asked to", function()
	helpers.it("writes nothing for a No or an unchecked list", function()
		for _, remap in ipairs({ { running = false }, { running = true } }) do
			with_finish({ answers = answers({ caps_lock = false, tab = false }), remap = remap }, function(state)
				assert_only_config_rows(state)
				helpers.assert_eq(#state.imports, 0)
				helpers.assert_eq(#state.saves, 0)
				helpers.assert_eq(state.deferred, 1, "the reload does not wait for an import that never started")
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1)
			end)
		end
	end)

	-- The alert blocked inside the owner's terminal callback, while the remap
	-- transaction was still dispatching it.
	helpers.it("says so once deferred work runs, then still applies the saved answers", function()
		for _, remap in ipairs({ { running = true, import_ok = false }, { running = false, save_ok = false } }) do
			with_finish({ answers = answers({ caps_lock = true }), remap = remap }, function(state)
				assert_only_config_rows(state)
				helpers.assert_eq(#state.alerts, 0, "no modal inside the owner's callback")
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 0, "the reload follows the notice")
				helpers.assert_true(Fixture.run_deferred(state, NOTICE))
				helpers.assert_eq(#state.alerts, 1)
				helpers.assert_eq(state.alerts[1].body, "onboarding.error.tap_holds_import")
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1,
					"the other answers are saved and apply at the reload")
			end)
		end
	end)
end)





-- ====================================================
-- ====================================================
-- ======= 3b/ The Navigation Layer Comes Along =======
-- ====================================================
-- ====================================================

-- A fresh install has no layers.toml, which binds no key: the imported
-- left_command held an empty navigation layer. The key that enters the layer
-- now brings Ergopti's recommended layer into the configuration folder (the
-- owner never replaces a layers.toml the user has).
helpers.describe("the key holding the navigation layer brings the recommended layer", function()
	helpers.it("(nav-layer-fresh-install-default) imports the layer into the configuration folder", function()
		for _, remap in ipairs({ { running = false }, { running = true } }) do
			with_finish({ answers = answers({ caps_lock = true, left_command = true }), remap = remap }, function(state)
				helpers.assert_eq(state.layer_imports, { Fixture.CONFIG_DIR },
					"one import, into the folder layers.toml is read from")
				helpers.assert_eq(state.layer_undos, {})
				helpers.assert_eq(#state.alerts, 0)
				helpers.assert_eq(Fixture.count_deferred(state, NOTICE), 0)
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1)
			end)
		end
	end)

	helpers.it("(nav-layer-fresh-install-default) imports no layer for keys that do not hold it", function()
		with_finish({ answers = answers({ caps_lock = true, tab = true, left_command = false }) }, function(state)
			helpers.assert_eq(state.layer_imports, {})
			helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1)
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) a layer that cannot be written is said, the keys stay", function()
		with_finish({ answers = answers({ left_command = true }), layer = "fail" }, function(state)
			helpers.assert_eq(state.saves, { { keys = { "left_command" }, path = Fixture.KARABINER_CONFIG_PATH } })
			helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 0, "the reload follows the notice")
			helpers.assert_true(Fixture.run_deferred(state, NOTICE))
			helpers.assert_eq(state.alerts[1].body, "onboarding.error.nav_layer_import")
			helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1)
		end)
	end)

	helpers.it("(nav-layer-fresh-install-default) a refused key import takes the layer back", function()
		with_finish({ answers = answers({ left_command = true }), remap = { running = true, import_ok = false } },
			function(state)
				helpers.assert_eq(#state.layer_undos, 1, "the layer never outlives the key that enters it")
				helpers.assert_eq(state.layer_undos[1].status, "imported")
				helpers.assert_true(Fixture.run_deferred(state, NOTICE))
				helpers.assert_eq(state.alerts[1].body, "onboarding.error.tap_holds_import")
			end)
	end)
end)





-- =================================================
-- =================================================
-- ======= 4/ The Reload Happens Or Says Why =======
-- =================================================
-- =================================================

helpers.describe("the wizard's reload always happens or says why", function()
	-- A bridge that never answered kept the wizard closed and unreloaded.
	helpers.it("reloads without an import that never answers, with a notice", function()
		with_finish({ answers = answers({ caps_lock = true }), remap = { running = true, hold_import = true } },
			function(state)
				helpers.assert_eq(Fixture.count_deferred(state, TIMEOUT), 1, "the wait is bounded")
				helpers.assert_true(Fixture.run_deferred(state, TIMEOUT))
				helpers.assert_true(Fixture.run_deferred(state, NOTICE))
				helpers.assert_eq(state.alerts[1].body, "onboarding.error.tap_holds_import_timeout")
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1)
				state.import_callbacks[1](true, "ready", 1)
				helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1, "a late answer reloads nothing more")
				helpers.assert_eq(#state.alerts, 1)
			end)
	end)

	helpers.it("lets the timeout pass once the import answered", function()
		with_finish({ answers = answers({ caps_lock = true }), remap = { running = true } }, function(state)
			helpers.assert_true(Fixture.run_deferred(state, TIMEOUT))
			helpers.assert_eq(#state.alerts, 0)
			helpers.assert_eq(Fixture.count_deferred(state, NOTICE), 0)
			helpers.assert_eq(Fixture.count_deferred(state, RELOAD), 1)
		end)
	end)

	-- hs.reload() went to the coordinator unowned: a refused or aborted reload
	-- left the answers saved but unapplied, with the wizard already closed.
	helpers.it("asks the coordinator for an owned reload, and says when it is still needed", function()
		with_finish({ answers = answers({}) }, function(state)
			helpers.assert_true(Fixture.run_deferred(state, RELOAD))
			helpers.assert_eq(#state.reloads, 1)
			helpers.assert_eq(state.reloads[1].reason, "onboarding")
			helpers.assert_eq(#state.alerts, 0, "an accepted reload says nothing")
			state.reloads[1].on_aborted("the lease fence failed")
			helpers.assert_true(Fixture.run_deferred(state, NOTICE))
			helpers.assert_eq(state.alerts[1].body, "onboarding.error.reload_pending")
		end)
		with_finish({ answers = answers({}), reload = "refused" }, function(state)
			helpers.assert_true(Fixture.run_deferred(state, RELOAD))
			helpers.assert_true(Fixture.run_deferred(state, NOTICE))
			helpers.assert_eq(state.alerts[1].body, "onboarding.error.reload_pending")
			helpers.assert_eq(#state.alerts, 1)
		end)
	end)
end)

-- The real DeferredWork and TimerScheduler turn a refused native start into
-- false; only hs.timer candidates are controlled. No successful scheduler or
-- reload receipt is invented by the fixture.
--- @param exercise function Actual Finish and native callback observations.
local function with_wizard_timeout_native_refusal(exercise)
	with_finish({}, function(state)
		local previous_hs = rawget(_G, "hs")
		local previous_scheduler = package.loaded["adapters.timer_scheduler"]
		local previous_deferred = package.loaded["infra.deferred_work"]
		local previous_after = previous_deferred.after
		local scheduler, deferred, original_after
		local handles, nodes, cleanup_errors = {}, {}, {}
		local native_hs = { timer = {} }
		local control = { refuse_timeout = true }
		function native_hs.timer.new(delay, callback)
			local node = { delay = delay, callback = callback, active = false, starts = 0, stops = 0 }
			function node:start()
				self.starts = self.starts + 1
				if delay == 30 and control.refuse_timeout then return false end
				self.active = true
				return self
			end
			function node:stop() self.stops = self.stops + 1; self.active = false; return self end
			function node:running() return self.active end
			nodes[#nodes + 1] = node
			return node
		end
		function control.active(delay)
			local count = 0
			for _, node in ipairs(nodes) do if node.delay == delay and node.active then count = count + 1 end end
			return count
		end
		function control.deliver(delay)
			for _, node in ipairs(nodes) do
				if node.delay == delay and node.active then node.callback(); return true end
			end
			return false
		end
		control.nodes = nodes
		local function attempt(label, callback)
			local okay, detail = pcall(callback)
			if not okay then cleanup_errors[#cleanup_errors + 1] = label .. ": " .. tostring(detail) end
		end
		local outcome = table.pack(pcall(function()
			_G.hs = native_hs
			package.loaded["adapters.timer_scheduler"] = nil
			package.loaded["infra.deferred_work"] = nil
			scheduler = require("adapters.timer_scheduler")
			original_after = scheduler.after
			-- Forward every call to the actual producer, retaining only its exact
			-- returned handles for this fresh fixture's finally cleanup.
			scheduler.after = function(...)
				local result = table.pack(original_after(...))
				handles[#handles + 1] = result[1]
				return table.unpack(result, 1, result.n)
			end
			deferred = require("infra.deferred_work")
			previous_deferred.after = deferred.after
			return exercise(state, control)
		end))
		-- Drain every exact returned handle while its native port is still held;
		-- assertion failure cannot skip cancellation or module/facade restoration.
		if scheduler then
			for _, handle in ipairs(handles) do
				attempt("exact timer cancellation", function() assert(scheduler.cancel(handle) == true) end)
			end
			attempt("owned scheduler drain", function() assert(scheduler.activeCount() == 0) end)
			attempt("scheduler method restoration", function() scheduler.after = original_after end)
		end
		attempt("held DeferredWork facade restoration", function() previous_deferred.after = previous_after end)
		attempt("DeferredWork module restoration", function() package.loaded["infra.deferred_work"] = previous_deferred end)
		attempt("scheduler module restoration", function() package.loaded["adapters.timer_scheduler"] = previous_scheduler end)
		attempt("native namespace restoration", function() assert(rawget(_G, "hs") == native_hs); _G.hs = previous_hs end)
		if #cleanup_errors > 0 then
			if not outcome[1] then
				pcall(function() io.stderr:write("wizard timeout fixture cleanup: " .. table.concat(cleanup_errors, "; ") .. "\n") end)
			else
				error(table.concat(cleanup_errors, "; "), 0)
			end
		end
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("the wizard requires its native import timeout before remap effects", function()
	helpers.it("refuses a retained live import when native timer start fails and still applies other answers (wizard-timeout-admission)", function()
		with_wizard_timeout_native_refusal(function(state, control)
			local remap = package.loaded["platform.remap"]
			local held = 0
			remap.is_running = function() return true end
			remap.import_recommended_keys = function() held = held + 1; return true end
			state.finish(answers({ caps_lock = true }))
			assert_only_config_rows(state)
			helpers.assert_eq(held, 0, "an import with no bounded completion owner never starts")
			helpers.assert_eq(#state.imports, 0)
			helpers.assert_eq(#state.saves, 0)
			helpers.assert_eq(#state.backups, 0)
			helpers.assert_eq(control.nodes[1].delay, 30)
			helpers.assert_eq(control.nodes[1].starts, 1)
			helpers.assert_eq(control.nodes[1].stops, 1, "the actual adapter retires its refused native candidate")
			helpers.assert_eq(control.active(30), 0)
			helpers.assert_eq(#state.alerts, 0, "the existing notice remains deferred")
			helpers.assert_true(control.deliver(0))
			helpers.assert_eq(state.alerts[1].body, "onboarding.error.tap_holds_import")
			helpers.assert_eq(control.active(1.5), 1)
			helpers.assert_true(control.deliver(1.5))
			helpers.assert_eq(#state.reloads, 1, "the saved non-remap answers still reach the real reload continuation")
			helpers.assert_eq(state.notifications, 1)
		end)
	end)

	helpers.it("does not create a navigation layer or save remap keys without the timeout owner (wizard-timeout-admission)", function()
		with_wizard_timeout_native_refusal(function(state, control)
			state.finish(answers({ left_command = true }))
			assert_only_config_rows(state)
			helpers.assert_eq(state.layer_imports, {}, "no layer cleanup debt is acquired for a refused import")
			helpers.assert_eq(state.layer_undos, {})
			helpers.assert_eq(state.saves, {})
			helpers.assert_eq(state.backups, {})
			helpers.assert_true(control.deliver(0))
			helpers.assert_eq(state.alerts[1].body, "onboarding.error.tap_holds_import")
			helpers.assert_true(control.deliver(1.5))
			helpers.assert_eq(#state.reloads, 1)
		end)
	end)

	helpers.it("the same actual Finish retries after native timer repair with the original live import and single reload (wizard-timeout-admission)", function()
		with_wizard_timeout_native_refusal(function(state, control)
			local remap = package.loaded["platform.remap"]
			local imports, completion = 0, nil
			remap.is_running = function() return true end
			remap.import_recommended_keys = function(request, callback)
				imports = imports + 1
				state.backups[#state.backups + 1] = request.backup_path
				completion = callback
				return true
			end
			state.finish(answers({ left_command = true }))
			helpers.assert_eq(imports, 0)
			helpers.assert_true(control.deliver(0))
			helpers.assert_true(control.deliver(1.5))
			helpers.assert_eq(#state.reloads, 1)
			local retired = control.nodes[1]
			control.refuse_timeout = false
			state.finish(answers({ left_command = true }))
			helpers.assert_eq(#state.writes, 2, "the original claimed Finish remains retryable")
			helpers.assert_eq(imports, 1)
			assert_one_backup(state)
			helpers.assert_eq(state.layer_imports, { Fixture.CONFIG_DIR })
			helpers.assert_eq(state.layer_undos, {})
			helpers.assert_eq(control.active(30), 1)
			retired.callback()
			helpers.assert_eq(#state.alerts, 1, "a refused native candidate cannot dispatch stale user work")
			helpers.assert_type(completion, "function")
			completion(true, "ready", 1)
			helpers.assert_eq(control.active(1.5), 1)
			helpers.assert_true(control.deliver(30), "the acknowledged import's timer retires without another notice")
			helpers.assert_eq(#state.alerts, 1)
			helpers.assert_true(control.deliver(1.5))
			helpers.assert_eq(#state.reloads, 2)
			helpers.assert_eq(state.notifications, 2)
			helpers.assert_eq(state.layer_undos, {})
		end)
	end)
end)
