--- tests/unit/modules/shortcuts/test_wrap_selection_atomic_transaction.lua

--- ==============================================================================
--- MODULE: Wrap-selection atomic clipboard transaction regression tests
--- DESCRIPTION:
--- Drives the real text action through every native failure boundary. A physical
--- wrap symbol may be consumed only after the paste and exact all-type clipboard
--- restore are both armed; every earlier failure must roll back, retaining the
--- latch until the exact clipboard snapshot is restored. Restore callbacks are
--- generation-gated so an obsolete timer cannot release a newer transaction.
--- ==============================================================================

local helpers = require("tests.helpers")


local function clone(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local copy = {}
	seen[value] = copy
	for key, item in pairs(value) do copy[clone(key, seen)] = clone(item, seen) end
	return copy
end


local function assert_deep_eq(actual, expected, message)
	helpers.assert_true(helpers.deep_equal(actual, expected), message)
end


local function load_fixture(options)
	options = options or {}
	local saved = {
		hs_global = _G.hs,
		hs_module = package.loaded["hs"],
		logger = package.loaded["infra.logger"],
		synthetic = package.loaded["adapters.synthetic_input"],
		text = package.loaded["modules.shortcuts.actions.text"],
	}

	local initial = clone(options.initial or {
		["public.utf8-plain-text"] = "ORIGINAL",
		["public.html"] = "<b>ORIGINAL</b>",
		["public.png"] = "\137PNG\r\n",
	})
	local clipboard_data = clone(initial)
	local timers = {}
	local deferred = {}
	local logs = {}
	local calls = {
		read = 0,
		write_text = 0,
		restore = 0,
		clear = 0,
		timer = 0,
		emit_attempts = 0,
		emit_successes = 0,
	}

	local read_outcomes = clone(options.read_outcomes or {})
	local write_outcomes = clone(options.write_outcomes or {})
	local restore_outcomes = clone(options.restore_outcomes or {})
	local timer_outcomes = clone(options.timer_outcomes or {})
	local emit_outcomes = clone(options.emit_outcomes or {})

	local function next_outcome(outcomes, index)
		return outcomes[index] or "success"
	end

	local logger = {}
	for _, level in ipairs({ "debug", "info", "warn", "error", "done", "trace" }) do
		logger[level] = function(_log, message, ...)
			logs[#logs + 1] = {
				level = level,
				message = tostring(message),
				args = table.pack(...),
			}
		end
	end
	package.loaded["infra.logger"] = logger

	local synthetic = {
		emit_key_stroke = function(_mods, key, _delay)
			helpers.assert_eq(key, "v", "wrap_selection may emit only Cmd+V")
			calls.emit_attempts = calls.emit_attempts + 1
			local outcome = next_outcome(emit_outcomes, calls.emit_attempts)
			if outcome == "throw" then error("injected synthetic emit failure") end
			if outcome == "false" then return false end
			calls.emit_successes = calls.emit_successes + 1
			return true
		end,
		emit_key_strokes = function() return true end,
		defer_after_callback = function(label, callback, ...)
			deferred[#deferred + 1] = {
				label = label,
				callback = callback,
				args = table.pack(...),
			}
			return true
		end,
	}
	package.loaded["adapters.synthetic_input"] = synthetic

	local pasteboard = {
		readAllData = function()
			calls.read = calls.read + 1
			local outcome = next_outcome(read_outcomes, calls.read)
			if outcome == "throw" then error("injected clipboard snapshot failure") end
			if outcome == "invalid" then return "not-a-pasteboard-snapshot" end
			return clone(clipboard_data)
		end,
		setContents = function(text)
			calls.write_text = calls.write_text + 1
			local outcome = next_outcome(write_outcomes, calls.write_text)
			-- Model a native call that changed the pasteboard before it reported
			-- failure. Rollback must therefore run for both false and throw.
			clipboard_data = { ["public.utf8-plain-text"] = text }
			if outcome == "throw" then error("injected clipboard write failure") end
			if outcome == "false" then return false end
			return true
		end,
		writeAllData = function(snapshot)
			calls.restore = calls.restore + 1
			local outcome = next_outcome(restore_outcomes, calls.restore)
			if outcome == "throw" then error("injected clipboard restore failure") end
			if outcome == "false" then return false end
			clipboard_data = clone(snapshot)
			return true
		end,
		clearContents = function()
			calls.clear = calls.clear + 1
			clipboard_data = {}
			return true
		end,
		getContents = function()
			return clipboard_data["public.utf8-plain-text"]
		end,
	}

	local timer = {
		doAfter = function(delay, callback)
			calls.timer = calls.timer + 1
			local outcome = next_outcome(timer_outcomes, calls.timer)
			if outcome == "throw" then error("injected timer allocation failure") end
			if outcome == "nil" then return nil end
			local handle = {
				delay = delay,
				callback = callback,
				stopped = false,
			}
			function handle:stop() self.stopped = true end
			timers[#timers + 1] = handle
			if outcome == "sync" then callback() end
			return handle
		end,
	}

	local Text = helpers.load_with_stubs("modules.shortcuts.actions.text", {
		pasteboard = pasteboard,
		timer = timer,
	})
	local log_baseline = #logs

	local fixture = {
		text = Text,
		initial = initial,
		timers = timers,
		deferred = deferred,
		logs = logs,
		log_baseline = log_baseline,
		calls = calls,
		clipboard = function() return clone(clipboard_data) end,
		wrap = function() return Text.wrap_selection("selected", "(", ")") end,
		fire = function(handle)
			return handle.callback()
		end,
		drain_deferred = function()
			local index = 1
			while index <= #deferred do
				local item = deferred[index]
				item.callback(table.unpack(item.args, 1, item.args.n))
				index = index + 1
			end
		end,
		restore = function()
			package.loaded["modules.shortcuts.actions.text"] = saved.text
			package.loaded["infra.logger"] = saved.logger
			package.loaded["adapters.synthetic_input"] = saved.synthetic
			package.loaded["hs"] = saved.hs_module
			_G.hs = saved.hs_global
		end,
	}
	return fixture
end


local function with_fixture(options, callback)
	local fixture = load_fixture(options)
	local ok, err = xpcall(function() callback(fixture) end, debug.traceback)
	fixture.restore()
	if not ok then error(err, 0) end
end


helpers.describe("wrap_selection: atomic pre-commit contract", function()
	helpers.it("returns true only after paste and restore are armed, and rejects re-entry", function()
		with_fixture({}, function(f)
			helpers.assert_eq(f.wrap(), true)
			helpers.assert_eq(f.calls.emit_successes, 1)
			helpers.assert_eq(#f.timers, 1, "restore timer must be strongly retained")
			helpers.assert_eq(f.wrap(), false, "an in-flight wrap must fail open")
			helpers.assert_eq(f.calls.read, 1, "re-entry must not snapshot the owned clipboard")
			f.fire(f.timers[1])
			assert_deep_eq(f.clipboard(), f.initial,
				"successful completion must restore every original pasteboard type")
		end)
	end)

	helpers.it("snapshot throw returns false, emits nothing, logs only after deferral, and reopens", function()
		with_fixture({ read_outcomes = { "throw", "success" } }, function(f)
			helpers.assert_eq(f.wrap(), false)
			helpers.assert_eq(f.calls.emit_attempts, 0)
			helpers.assert_eq(#f.timers, 0)
			assert_deep_eq(f.clipboard(), f.initial)
			helpers.assert_eq(#f.logs, f.log_baseline,
				"an eventtap failure must not synchronously enter the file logger")
			helpers.assert_true(#f.deferred > 0, "failure diagnostics must be deferred")
			f.drain_deferred()
			helpers.assert_true(#f.logs > f.log_baseline)
			helpers.assert_eq(f.wrap(), true, "snapshot failure must release the latch")
			f.fire(f.timers[#f.timers])
		end)
	end)

	for _, outcome in ipairs({ "false", "throw" }) do
		helpers.it("clipboard write " .. outcome .. " rolls back exact data and emits no paste", function()
			with_fixture({ write_outcomes = { outcome, "success" } }, function(f)
				helpers.assert_eq(f.wrap(), false)
				helpers.assert_eq(f.calls.emit_attempts, 0)
				assert_deep_eq(f.clipboard(), f.initial,
					"a partially-mutating clipboard failure must restore the full snapshot")
				helpers.assert_eq(f.wrap(), true, "clipboard write failure must release the latch")
				f.fire(f.timers[#f.timers])
			end)
		end)
	end

	helpers.it("keeps ownership and retries when pre-paste rollback cannot restore", function()
		with_fixture({
			write_outcomes = { "false" },
			restore_outcomes = { "false", "false", "success" },
		}, function(f)
			helpers.assert_eq(f.wrap(), false)
			helpers.assert_eq(f.calls.emit_attempts, 0)
			helpers.assert_eq(f.wrap(), false,
				"a corrupted clipboard must remain owned until exact recovery")
			helpers.assert_eq(#f.timers, 1,
				"failed synchronous rollback must retain one autonomous retry")
			f.fire(f.timers[1])
			assert_deep_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.wrap(), true,
				"successful exact recovery must release the transaction latch")
		end)
	end)

	for _, outcome in ipairs({ "nil", "throw" }) do
		helpers.it("restore timer allocation " .. outcome .. " rolls back before paste", function()
			with_fixture({ timer_outcomes = { outcome, "success" } }, function(f)
				helpers.assert_eq(f.wrap(), false)
				helpers.assert_eq(f.calls.emit_attempts, 0)
				assert_deep_eq(f.clipboard(), f.initial)
				helpers.assert_eq(f.wrap(), true, "timer allocation failure must release the latch")
				f.fire(f.timers[#f.timers])
			end)
		end)
	end

	for _, outcome in ipairs({ "false", "throw" }) do
		helpers.it("synthetic paste " .. outcome .. " stops its timer, rolls back, and reopens", function()
			with_fixture({ emit_outcomes = { outcome, "success" } }, function(f)
				helpers.assert_eq(f.wrap(), false)
				helpers.assert_eq(f.calls.emit_successes, 0,
					"a refused/throwing synthetic dispatch must commit no paste")
				helpers.assert_eq(#f.timers, 1)
				helpers.assert_true(f.timers[1].stopped,
					"rollback must stop the already-armed restore timer")
				assert_deep_eq(f.clipboard(), f.initial)
				-- Even a hostile native late-fire after stop must be inert.
				f.fire(f.timers[1])
				assert_deep_eq(f.clipboard(), f.initial)
				helpers.assert_eq(f.wrap(), true, "synthetic failure must release the latch")
				f.fire(f.timers[#f.timers])
			end)
		end)
	end
end)

helpers.describe("wrap_selection: restore recovery and generation ownership", function()
	for _, outcome in ipairs({ "false", "throw" }) do
		helpers.it("restore callback " .. outcome .. " stays owned and retries to exact data", function()
			with_fixture({ restore_outcomes = { outcome, "success" } }, function(f)
				helpers.assert_eq(f.wrap(), true)
				local first = f.timers[1]
				local ok, err = pcall(f.fire, first)
				helpers.assert_true(ok, "restore failure must not escape its timer: " .. tostring(err))
				helpers.assert_eq(#f.timers, 2, "restore failure must arm an autonomous retry")
				helpers.assert_eq(f.wrap(), false,
					"clipboard ownership must stay closed until restoration succeeds")
				f.fire(f.timers[2])
				assert_deep_eq(f.clipboard(), f.initial)
				helpers.assert_eq(f.wrap(), true, "successful retry must release ownership")
				f.fire(f.timers[#f.timers])
			end)
		end)
	end

	helpers.it("uses lifecycle fallback when restore fails and retry timer allocation fails", function()
		with_fixture({
			restore_outcomes = { "throw", "success" },
			timer_outcomes = { "success", "nil" },
		}, function(f)
			helpers.assert_eq(f.wrap(), true)
			f.fire(f.timers[1])
			helpers.assert_eq(f.wrap(), false,
				"the transaction remains owned while lifecycle restore is queued")
			local found_retry = false
			for _, item in ipairs(f.deferred) do
				if item.label == "wrap clipboard restore retry" then found_retry = true end
			end
			helpers.assert_true(found_retry, "timer failure must queue the independent lifecycle retry")
			f.drain_deferred()
			assert_deep_eq(f.clipboard(), f.initial)
			helpers.assert_eq(f.wrap(), true)
			f.fire(f.timers[#f.timers])
		end)
	end)

	helpers.it("a stale retained callback cannot clear a newer generation", function()
		with_fixture({}, function(f)
			helpers.assert_eq(f.wrap(), true)
			local stale = f.timers[1]
			f.fire(stale)
			helpers.assert_eq(f.wrap(), true)
			local current = f.timers[2]
			f.fire(stale)
			helpers.assert_eq(f.wrap(), false,
				"late generation-1 callback must not release generation-2 ownership")
			f.fire(current)
			assert_deep_eq(f.clipboard(), f.initial)
		end)
	end)
end)
