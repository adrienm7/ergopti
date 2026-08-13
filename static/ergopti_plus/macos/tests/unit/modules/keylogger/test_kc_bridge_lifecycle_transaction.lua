--- tests/unit/modules/keylogger/test_kc_bridge_lifecycle_transaction.lua

--- ==============================================================================
--- MODULE: KC Bridge Lifecycle Transaction Tests
--- DESCRIPTION:
--- Drives the always-on physical-key ledger owners through native refusal and
--- teardown debt, and proves the parent keylogger cannot load after the bridge
--- refuses its required watcher transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh KC bridge with controlled native owners.
--- @param scheduler table TimerScheduler test double.
--- @param pathwatcher table Native pathwatcher test double.
--- @return table module Fresh bridge module.
local function load_bridge(scheduler, pathwatcher)
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.config_paths"] = { get_config_dir = function() return "." end }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("modules.keylogger.kc_bridge", {
		pathwatcher = pathwatcher,
		keycodes = { map = {} },
		timer = { absoluteTime = function() return 0 end },
	})
end

helpers.describe("KC bridge dual-producer transaction", function()
	helpers.it("does not acquire the poll sibling when pathwatcher construction throws or returns nil", function()
		for _, case in ipairs({
			{ label = "throw", new = function() error("watcher constructor exploded") end },
			{ label = "nil", new = function() return nil end },
		}) do
			local poll_calls = 0
			local bridge = load_bridge({
				every = function() poll_calls = poll_calls + 1; return { timer = {} }, true end,
				cancel = function() return true end,
			}, { new = case.new })
			local ok, committed = pcall(bridge.init, {}, nil, {}, {}, function() return false end)
			helpers.assert_true(ok, case.label .. " watcher construction failure must be contained")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(poll_calls, 0,
				case.label .. " watcher failure must not acquire the conflicting sibling poller")
		end
	end)

	helpers.it("rolls back the void-stop pathwatcher when poll activation refuses", function()
		local watcher_stops = 0
		local watcher = {}
		watcher.start = function() return watcher end
		watcher.stop = function() watcher_stops = watcher_stops + 1 end
		local poll = { timer = {} }
		local scheduler = {
			every = function() return poll, false end,
			cancel = function(handle) handle.timer = nil; return true end,
		}
		local bridge = load_bridge(scheduler, {
			new = function() return watcher end,
		})

		helpers.assert_eq(bridge.init({}, nil, {}, {}, function() return false end), false)
		helpers.assert_eq(watcher_stops, 1,
			"pathwatcher:stop() returns nil by contract; non-throw must commit rollback")
	end)

	helpers.it("fences a partially started watcher whose rollback throws", function()
		local callback = nil
		local watcher = {}
		watcher.start = function() error("start exploded after registration") end
		watcher.stop = function() error("stop refused") end
		local scheduler = {
			every = function() error("poller must not start after watcher refusal") end,
			cancel = function() return true end,
		}
		local bridge = load_bridge(scheduler, {
			new = function(_path, fn) callback = fn; return watcher end,
		})

		helpers.assert_eq(bridge.init({}, nil, {}, {}, function() return false end), false)
		local saved_open = io.open
		local open_calls = 0
		io.open = function() open_calls = open_calls + 1; return nil end
		callback()
		io.open = saved_open
		helpers.assert_eq(open_calls, 0,
			"a callback from an uncommitted retained watcher must be inert")
		helpers.assert_eq(bridge.start(), false,
			"unsettled watcher debt must block a replacement transaction")
	end)

	helpers.it("attempts both exact cleanups and blocks restart on either refusal", function()
		local watcher_stops = 0
		local poll_cancels = 0
		local watcher = {}
		watcher.start = function() return watcher end
		watcher.stop = function() watcher_stops = watcher_stops + 1; error("busy") end
		local poll = { timer = {} }
		local scheduler = {
			every = function() return poll, true end,
			cancel = function()
				poll_cancels = poll_cancels + 1
				return false
			end,
		}
		local bridge = load_bridge(scheduler, { new = function() return watcher end })

		helpers.assert_eq(bridge.init({}, nil, {}, {}, function() return false end), true)
		helpers.assert_eq(bridge.stop(), false)
		helpers.assert_eq(watcher_stops, 1)
		helpers.assert_eq(poll_cancels, 1,
			"one cleanup throw must not hide the sibling timer cleanup attempt")
		helpers.assert_eq(bridge.start(), false)
	end)

	helpers.it("returns true only for an active exact-dependency duplicate", function()
		local watcher = {}
		watcher.start = function() return watcher end
		watcher.stop = function() end
		local scheduler = {
			every = function() return { timer = {} }, true end,
			cancel = function(handle) handle.timer = nil; return true end,
		}
		local bridge = load_bridge(scheduler, { new = function() return watcher end })
		local state = {}
		local may_persist = function() return false end

		helpers.assert_eq(bridge.init(state, nil, nil, nil, may_persist), true)
		helpers.assert_eq(bridge.init(state, nil, nil, nil, may_persist), true)
		helpers.assert_eq(bridge.init({}, nil, nil, nil, may_persist), false,
			"a different state must not be accepted as an idempotent duplicate")
	end)

	helpers.it("fails closed when restart cannot prove the disabled-period EOF", function()
		local watcher = {}
		watcher.start = function() return watcher end
		watcher.stop = function() end
		local poll_callbacks = {}
		local scheduler = {
			every = function(_delay, callback)
				poll_callbacks[#poll_callbacks + 1] = callback
				return { timer = {} }, true
			end,
			cancel = function(handle) handle.timer = nil; return true end,
		}
		local bridge = load_bridge(scheduler, { new = function() return watcher end })
		local saved_open = io.open
		local phase = "init"
		local eof = 10
		io.open = function(path, mode)
			if mode == "a" then return { close = function() return true end } end
			if phase == "restart-failure" then return nil, "permission denied" end
			return {
				seek = function(_self, whence)
					if whence == "end" then return eof end
					return eof
				end,
				close = function() return true end,
				lines = function() return function() return nil end end,
			}
		end

		local ok, err = pcall(function()
			helpers.assert_eq(bridge.init({}, nil, nil, nil, function() return false end), true)
			helpers.assert_eq(bridge.stop(), true)
			eof = 25 -- Karabiner appended bytes while the bridge was terminally stopped.
			phase = "restart-failure"
			helpers.assert_eq(bridge.start(), false,
				"restart must not arm producers when it cannot discard the off-window backlog")
			helpers.assert_eq(#poll_callbacks, 1,
				"failed resync must leave the old fenced producer as the only historical callback")

			phase = "recovery"
			helpers.assert_eq(bridge.start(), true)
			helpers.assert_eq(#poll_callbacks, 2,
				"a later retry may arm producers only after EOF resync succeeds")
			helpers.assert_eq(bridge.get_stats().offset, 25,
				"the recovery must discard every byte appended while disabled")
		end)
		io.open = saved_open
		helpers.assert_true(ok, "EOF resync failure scenario must complete: " .. tostring(err))
	end)
end)

helpers.describe("keylogger parent requires KC bridge commitment", function()
	helpers.it("fails module load when the always-on bridge refuses init", function()
		package.loaded["modules.keylogger.init"] = nil
		package.loaded["modules.keylogger.kc_bridge"] = {
			init = function() return false end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = {
			ms = function() return 1 end,
			sec = function() return 1 end,
		}
		package.loaded["infra.manifest_reader"] = { default_for = function() return false end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = {}
		package.loaded["infra.teardown_transaction"] = {}
		package.loaded["infra.config_paths"] = { get_config_dir = function() return "." end }
		for _, name in ipairs({
			"adapters.input_source_broker", "modules.keylogger.log_manager",
			"modules.keylogger.context_tracker", "keylogger.metrics",
			"modules.keylogger.watchers", "adapters.process_lifecycle",
			"adapters.keyboard_hook", "adapters.event_provenance",
			"adapters.synthetic_input",
		}) do package.loaded[name] = {} end

		local loaded, err = pcall(require, "modules.keylogger.init")
		helpers.assert_eq(loaded, false,
			"the parent must not expose a keylogger whose required ledger drain is absent")
		helpers.assert_true(tostring(err):find("KC bridge failed to acquire", 1, true) ~= nil,
			"the load failure must identify the exact refused dependency")
	end)
end)
