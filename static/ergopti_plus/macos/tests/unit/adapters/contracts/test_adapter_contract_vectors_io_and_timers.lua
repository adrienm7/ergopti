--- tests/unit/adapters/contracts/test_adapter_contract_vectors_io_and_timers.lua

--- ==============================================================================
--- MODULE: Adapter Contract Behaviour Tests
--- DESCRIPTION:
--- Executes the contractTestVectors() scenarios defined in each
--- _shared/core/ports/*.spec.js — translated into Lua so they run under the
--- standard hs-stub test runner without a Node.js dependency.
---
--- RATIONALE:
--- test_adapter_compliance.lua already verifies *structural* compliance
--- (method names + arities). This file verifies *behavioural* compliance:
--- that each adapter actually does what its port contract promises — correct
--- return values, error-safe paths, side-effects captured by the hs stub.
---
--- APPROACH:
--- Each port section hard-codes the relevant contractTestVectors() inputs and
--- expected outputs, mirroring the JS source. The adapters themselves are REAL —
--- loaded through load_with_stubs and called directly — so these are behavioural
--- tests, not a reimplementation.
---
--- DRIFT, HONESTLY:
--- This file reads no .spec.js, so a vector changed on the JS side leaves the
--- Lua mirror passing against the old expectation. An earlier version of this
--- docstring claimed the opposite — "the tests will fail until they are
--- synchronised, making drift immediately visible" — and nothing made that true.
--- Measured: 138 vectors across 20 ports, 61 of them referenced here by id.
---
--- tools/test/test-port-vector-traceability.cjs ratchets that number, so the
--- link can only get better. Naming a vector id in a test is what makes that
--- test traceable — prefer including the id in the assertion message when adding
--- one.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.contracts.adapter_contract_vectors_fixture"] = nil
local Fixture = require("tests.support.adapters.contracts.adapter_contract_vectors_fixture")





-- ====================================
--- ====================================
-- ======= 1/ Notifier Vectors ========
--- ====================================
-- ====================================

helpers.describe("Adapter contract vectors: Notifier", function()
	local adapter

	-- Load with a notify stub that records what was sent.
	-- hs.notify.new() takes an options TABLE: { title=, informativeText=, subTitle= }
	local notify_calls = {}
	local notify_releases = 0
	local notify_throws = false
	local notify_refuses = false
	local hs_overrides = {
		notify = {
			new = function(opts_tbl)
				if notify_throws then error("OS notify error") end
				local t = type(opts_tbl) == "table" and opts_tbl or {}
				table.insert(notify_calls, {
					title = t.title,
					informative_text = t.informativeText,
					subtitle = t.subTitle,
				})
				local notification = {
					release = function() notify_releases = notify_releases + 1 end,
				}
				notification.send = function()
					if notify_refuses then return false end
					return notification
				end
				return notification
			end,
			show = function(_n) end,
		},
	}

	adapter = helpers.load_with_stubs("adapters.notifier", hs_overrides)

	helpers.it("localizes warning and error subtitles through infra.i18n", function()
		local I18n = require("infra.i18n")
		local original_get = I18n.get
		local requested_keys = {}
		I18n.get = function(key)
			requested_keys[#requested_keys + 1] = key
			if key == "common.warning" then return "Localized warning" end
			if key == "common.error_title" then return "Localized error" end
			return key
		end

		local ok, err = xpcall(function()
			notify_calls = {}
			helpers.assert_eq(adapter.send("Warning.", { kind = "warn" }), true,
				"the localized warning must still be delivered")
			helpers.assert_eq(adapter.send("Error.", { kind = "error" }), true,
				"the localized error must still be delivered")
			helpers.assert_eq(#notify_calls, 2,
				"both urgency kinds must reach the native notifier")
			helpers.assert_eq(notify_calls[1].subtitle, "⚠️ Localized warning",
				"warning subtitle must combine its icon with the active locale")
			helpers.assert_eq(notify_calls[2].subtitle, "🔴 Localized error",
				"error subtitle must combine its icon with the active locale")
			helpers.assert_eq(table.concat(requested_keys, ","),
				"common.warning,common.error_title",
				"the adapter must resolve the canonical locale keys")
		end, debug.traceback)
		I18n.get = original_get
		if not ok then error(err, 0) end
	end)

	-- Called DIRECTLY. "does not throw" was the assertion, and a throw fails the
	-- test anyway — with its real stack, which the pcall was converting into a
	-- boolean. What the pcall could NOT see is whether a notification was actually
	-- created: an adapter that swallowed every level silently would have passed
	-- all four of these.
	helpers.it("an info notification reaches hs.notify", function()
		notify_calls = {}
		local accepted = adapter.send("Configuration loaded.", { level = "info" })
		helpers.assert_eq(#notify_calls, 1,
			"exactly one notification must be created — none means the user is told nothing")
		helpers.assert_eq(accepted, true,
			"a native send capability returned by hs.notify is an accepted dispatch")
	end)

	helpers.it("a success notification reaches hs.notify", function()
		notify_calls = {}
		adapter.send("LLM bridge initialized.", { level = "success" })
		helpers.assert_eq(#notify_calls, 1, "success must not be silently dropped")
	end)

	helpers.it("a warning notification reaches hs.notify", function()
		notify_calls = {}
		adapter.send("API key not set.", { level = "warning" })
		helpers.assert_eq(#notify_calls, 1,
			"a warning the user never sees is the same as no warning at all")
	end)

	helpers.it("an error notification reaches hs.notify", function()
		notify_calls = {}
		adapter.send("Configuration file missing.", { level = "error" })
		helpers.assert_eq(#notify_calls, 1, "errors above all must be shown")
	end)

	helpers.it("title_forwarded — first arg becomes hs.notify title", function()
		notify_calls = {}
		-- HS adapter: M.send(title, opts) — the first arg IS the notification title.
		-- The port spec names it 'message' but the HS adapter uses it directly as
		-- the macOS notification title, which matches macOS UX conventions.
		adapter.send("Ergopti+", {})
		helpers.assert_true(#notify_calls > 0, "notification must be sent")
		helpers.assert_eq(notify_calls[1].title, "Ergopti+",
			"first arg must be forwarded as the hs.notify title")
	end)

	helpers.it("custom_title_forwarded — any string first arg is used as title", function()
		notify_calls = {}
		adapter.send("Mon Titre", { body = "Ready." })
		helpers.assert_true(#notify_calls > 0, "notification must be sent")
		helpers.assert_eq(notify_calls[1].title, "Mon Titre",
			"first arg must be forwarded as the hs.notify title")
	end)

	-- Absorption IS the contract here, so the call is still made directly: if it
	-- propagated, this test fails with the OS error itself rather than with a
	-- bare `false`. The half a pcall could not check is the one that matters —
	-- that the adapter is still usable afterwards. A notifier that absorbed the
	-- throw but left itself wedged would report every later message to nobody.
	helpers.it("an OS failure is absorbed and does not wedge the adapter", function()
		notify_calls = {}
		notify_throws = true
		adapter.send("Test.", { level = "info" })
		notify_throws = false
		helpers.assert_eq(#notify_calls, 0, "the failing attempt creates no notification")

		adapter.send("After the failure.", { level = "info" })
		helpers.assert_eq(#notify_calls, 1,
			"the next send must succeed — an absorbed OS error must not disable "
				.. "notifications for the rest of the session")
	end)

	helpers.it("an explicit native refusal is returned and logged", function()
		local lines = {}
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)
		notify_calls = {}
		notify_releases = 0
		notify_refuses = true
		local accepted = adapter.send("Permission denied.", { level = "error" })
		notify_refuses = false
		Logger.set_sink(nil)

		helpers.assert_eq(accepted, false,
			"send() must expose the native refusal to callers")
		helpers.assert_eq(#notify_calls, 1,
			"the refusal must come from a real native dispatch attempt")
		helpers.assert_eq(notify_releases, 1,
			"a refused notification must still release its native object")
		helpers.assert_contains(table.concat(lines, "\n"),
			"hs.notify refused delivery",
			"revoked notification permission must produce an actionable ERROR log")
	end)
end)




-- =====================================
--- =====================================
-- ======= 2/ HttpClient Vectors ========
--- =====================================
-- =====================================

--- Loads HttpClient with the TimerScheduler bound to the same fresh hs stub.
--- @return table HttpClient adapter.
local function load_http_client()
	package.loaded["adapters.timer_scheduler"] = nil
	return helpers.load_with_stubs("adapters.http_client")
end

helpers.describe("Adapter contract vectors: HttpClient", function()
	local adapter = load_http_client()

	helpers.it("post_success_200 — callback receives ok=true, status=200", function()
		hs.http.__set_response(
			"https://api.example.com/v1/chat/completions",
			200,
			'{"choices":[{"message":{"content":"hello"}}]}'
		)
		local result = nil
		adapter.post(
			"https://api.example.com/v1/chat/completions",
			{ ["Content-Type"] = "application/json" },
			'{"model":"gpt-4o","messages":[]}',
			function(r) result = r end
		)
		helpers.assert_true(result ~= nil, "callback must be called")
		helpers.assert_true(result.ok == true, "ok must be true for 200")
		helpers.assert_eq(result.status, 200, "status must be 200")
		helpers.assert_nil(result.error,
			"a successful HTTP envelope must not also report an error")
	end)

	helpers.it("post_auth_error_401 — callback receives ok=false, status=401", function()
		hs.http.__set_response(
			"https://api.example.com/v1/chat/completions",
			401,
			'{"error":"invalid api key"}'
		)
		local result = nil
		adapter.post(
			"https://api.example.com/v1/chat/completions",
			{ ["Authorization"] = "Bearer bad-key" },
			"{}",
			function(r) result = r end
		)
		helpers.assert_true(result ~= nil, "callback must be called")
		helpers.assert_true(result.ok == false, "ok must be false for 401")
		helpers.assert_eq(result.status, 401, "status must be 401")
		helpers.assert_eq(result.error, "HTTP 401",
			"a failed HTTP envelope must preserve its diagnostic")
	end)

	helpers.it("isActive returns false when no request is in flight", function()
		-- Load a fresh adapter with no pending request
		local fresh = load_http_client()
		helpers.assert_eq(fresh.isActive(), false, "isActive() must be false when idle")
	end)

	helpers.it("cancel on an idle adapter leaves it idle and usable", function()
		local fresh = load_http_client()
		fresh.cancel()
		helpers.assert_eq(fresh.isActive(), false,
			"cancelling nothing must not flip the in-flight flag — a stuck true makes "
				.. "every later request think one is already running and drop itself")
		-- And a second cancel must be just as harmless: the LLM bridge cancels on
		-- every keystroke, whether or not a request is live.
		fresh.cancel()
		helpers.assert_eq(fresh.isActive(), false, "a second cancel is still a no-op")
	end)
end)




-- ======================================
--- ======================================
-- ======= 3/ TextSender Vectors =========
--- ======================================
-- ======================================

helpers.describe("Adapter contract vectors: TextSender", function()
	local MAX_BROKER_STEPS = 100

	local function load_tagged_sender()
		package.loaded["tests.stubs.hs"] = nil
		local eventtap = require("tests.stubs.hs").eventtap
		local new_mouse_event = eventtap.event.newMouseEvent
		local posted_triggers = {}
		eventtap.event.newMouseEvent = function(...)
			local event = new_mouse_event(...)
			event.post = function(self)
				posted_triggers[#posted_triggers + 1] = self
				return self
			end
			return event
		end

		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.event_provenance"] = nil
		local adapter = helpers.load_with_stubs("adapters.text_sender", { eventtap = eventtap })
		local hs_table = _G.hs

		local function drain()
			local emitted = {}
			for _ = 1, MAX_BROKER_STEPS do
				if #posted_triggers > 0 then
					local trigger = table.remove(posted_triggers, 1)
					local pump = nil
					for _, tap in ipairs(hs_table.eventtap.__taps) do
						if tap.types and tap.types[1] == hs_table.eventtap.event.types.otherMouseUp then
							pump = tap
							break
						end
					end
					helpers.assert_not_nil(pump, "tagged text dispatch must create its broker tap")
					local consume, events = pump.fn(trigger)
					helpers.assert_eq(consume, true, "the private broker trigger must be consumed")
					for _, event in ipairs(events or {}) do emitted[#emitted + 1] = event end
				else
					local pending = nil
					for _, timer in ipairs(hs_table.timer.__timers) do
						if timer.running and timer.delay == 0 and not timer.recurring then
							pending = timer
							break
						end
					end
					if not pending then return emitted end
					pending:fire()
				end
			end
			error(string.format(
				"tagged text fixture did not become idle after %d broker steps",
				MAX_BROKER_STEPS))
		end

		return adapter, drain
	end

	helpers.it("erase_chars — eraseChars(3) emits exactly 3 Backspace events", function()
		local adapter, drain = load_tagged_sender()
		adapter.eraseChars(3)
		local ks = drain()
		local bs = 0
		for _, k in ipairs(ks) do
			if k.isDown and (k.key == "delete" or k.key == "forwarddelete" or
			   (type(k.key) == "string" and k.key:lower():find("delete"))) then
				bs = bs + 1
			end
		end
		helpers.assert_eq(bs, 3, "eraseChars(3) must emit exactly 3 delete events")
	end)

	helpers.it("erase_chars_zero — eraseChars(0) is a no-op", function()
		local adapter, drain = load_tagged_sender()
		adapter.eraseChars(0)
		helpers.assert_eq(#drain(), 0,
			"eraseChars(0) must not emit any keystroke")
	end)

	helpers.it("press_key_no_modifiers — pressKey emits the key", function()
		local adapter, drain = load_tagged_sender()
		adapter.pressKey("return", {})
		local events = drain()
		helpers.assert_eq(#events, 2,
			"pressKey must emit at least one keystroke")
		helpers.assert_eq(events[1].key, "return")
		helpers.assert_eq(events[2].key, "return")
	end)

	-- "does not throw" said nothing about whether the text was TYPED. A send that
	-- returned early — the exact shape of the nil-payload guard two files over —
	-- would have passed it while inserting nothing.
	helpers.it("send types short text directly and reports completion", function()
		local adapter, drain = load_tagged_sender()
		local done = false
		adapter.send("hello", {}, function() done = true end)
		local events = drain()
		helpers.assert_eq(#events, 10,
			"a short payload must be typed through the direct path, not silently dropped")
		local text = {}
		for _, event in ipairs(events) do
			if event.isDown then text[#text + 1] = event.unicode end
		end
		helpers.assert_eq(table.concat(text), "hello",
			"the tagged direct events must reproduce the requested text exactly")
		helpers.assert_true(done,
			"the completion callback must fire — the LLM bridge chains its cleanup on it, "
				.. "so a callback that never runs leaves the tooltip up forever")
	end)
end)




-- ==========================================
--- ==========================================
-- ======= 4/ TimerScheduler Vectors =========
--- ==========================================
-- ==========================================

helpers.describe("Adapter contract vectors: TimerScheduler", function()
	local adapter = helpers.load_with_stubs("adapters.timer_scheduler")

	helpers.it("after schedules a timer (fires when stub fires it)", function()
		hs.timer.__timers[1] = nil  -- start from clean state
		local fire_count = 0
		adapter.after(0.5, function() fire_count = fire_count + 1 end)
		-- The hs stub timer does not auto-advance — manually fire all pending timers
		hs.timer.__fire_all()
		helpers.assert_eq(fire_count, 1, "after() callback must fire exactly once")
	end)

	helpers.it("cancel prevents the callback from firing", function()
		hs.timer.__timers[1] = nil
		local fire_count = 0
		local handle = adapter.after(1.0, function() fire_count = fire_count + 1 end)
		adapter.cancel(handle)
		hs.timer.__fire_all()
		helpers.assert_eq(fire_count, 0, "cancel() must prevent the callback from firing")
	end)

	helpers.it("every schedules a recurring timer", function()
		hs.timer.__timers[1] = nil
		local fire_count = 0
		local handle = adapter.every(0.1, function() fire_count = fire_count + 1 end)
		hs.timer.__fire_all()
		hs.timer.__fire_all()
		adapter.cancel(handle)
		helpers.assert_true(fire_count >= 1, "every() callback must have fired at least once")
	end)

	helpers.it("cancelAll stops all scheduled timers", function()
		hs.timer.__timers[1] = nil
		local count = 0
		adapter.after(1.0, function() count = count + 1 end)
		adapter.every(0.5, function() count = count + 1 end)
		adapter.cancelAll()
		hs.timer.__fire_all()
		helpers.assert_eq(count, 0, "cancelAll() must stop all pending timers")
	end)

	-- Cancelling an already-fired handle must not RE-FIRE it. That is the failure
	-- a "does not throw" check cannot see, and it is the one that happens: the
	-- LLM bridge cancels its debounce on every keystroke, long after the timer it
	-- is holding has already run.
	helpers.it("cancel on an already-fired handle does not re-run the callback", function()
		-- Clear the whole registry, not just slot 1: __fire_all walks every timer
		-- any earlier case left behind, so a single-slot reset leaves this one
		-- counting somebody else's callbacks.
		for i = #hs.timer.__timers, 1, -1 do hs.timer.__timers[i] = nil end
		local runs = 0
		local handle = adapter.after(0.1, function() runs = runs + 1 end)
		hs.timer.__fire_all()
		helpers.assert_eq(runs, 1, "the timer must have fired exactly once")
		adapter.cancel(handle)
		hs.timer.__fire_all()
		helpers.assert_eq(runs, 1,
			"cancelling a spent handle must not resurrect it — a second run would "
				.. "type a stale prediction into the user's document")
	end)
end)




-- ======================================
--- ======================================
-- ======= 5/ FileSystem Vectors =========
--- ======================================
-- ======================================

helpers.describe("Adapter contract vectors: FileSystem", function()
	local host_fs = hs.fs
	-- Reuse the faithful host-stub primitives so the private staging directory
	-- exists on disk and cleanup exercises the same return contracts as production
	package.loaded["infra.fs_dir"] = nil
	local adapter = helpers.load_with_stubs("adapters.file_system", {
		fs = {
			dir = host_fs.dir,
			attributes = host_fs.attributes,
			symlinkAttributes = function(path)
				local attributes, attributes_err = host_fs.symlinkAttributes(path)
				if attributes then return attributes end
				local fallback = host_fs.attributes(path)
				if fallback then return fallback end
				return nil, attributes_err
			end,
			mkdir = host_fs.mkdir,
			rmdir = host_fs.rmdir,
			link = host_fs.link,
			lock = host_fs.lock,
			unlock = host_fs.unlock,
			xattr = host_fs.xattr,
			pathToAbsolute = function(p) return p end,
		},
	})
	local TMP     = os.tmpname()

	helpers.it("read_missing returns nil for absent file", function()
		local result = adapter.read(TMP .. "_does_not_exist_xyz")
		helpers.assert_nil(result, "read() on missing file must return nil")
	end)

	helpers.it("write returns true and creates the file", function()
		os.remove(TMP)
		local ok = adapter.write(TMP, "hello world")
		helpers.assert_true(ok == true, "write() must return true on success")
		helpers.assert_true(adapter.exists(TMP), "file must exist after write()")
		os.remove(TMP)
	end)

	helpers.it("read_after_write returns the written content", function()
		adapter.write(TMP, "test content")
		local content = adapter.read(TMP)
		helpers.assert_eq(content, "test content", "read() must return what was written")
		os.remove(TMP)
	end)

	helpers.it("append adds content after existing data", function()
		adapter.write(TMP, "line1")
		adapter.append(TMP, "line2")
		local content = adapter.read(TMP)
		helpers.assert_true(content ~= nil, "content must be readable after append")
		helpers.assert_true(content:find("line1") ~= nil, "original content must be preserved")
		helpers.assert_true(content:find("line2") ~= nil, "appended content must be present")
		os.remove(TMP)
	end)

	helpers.it("exists returns true for an existing file", function()
		adapter.write(TMP, "x")
		helpers.assert_true(adapter.exists(TMP) == true, "exists() must return true for existing file")
		os.remove(TMP)
	end)

	helpers.it("exists returns false for a missing file", function()
		os.remove(TMP)
		local result = adapter.exists(TMP)
		helpers.assert_true(result == false or result == nil,
			"exists() must return false/nil for missing file")
	end)

	helpers.it("delete removes the file", function()
		adapter.write(TMP, "to delete")
		adapter.delete(TMP)
		local result = adapter.exists(TMP)
		helpers.assert_true(result == false or result == nil,
			"file must not exist after delete()")
	end)

	helpers.it("delete on a missing file leaves it missing and the adapter usable", function()
		os.remove(TMP)
		adapter.delete(TMP)
		helpers.assert_true(adapter.exists(TMP) ~= true,
			"the file must still be absent — a delete that recreated or half-created "
				.. "it would be worse than one that failed")
		-- And the adapter must still work: cleanup paths call delete on files that
		-- may or may not exist, then immediately write.
		adapter.write(TMP, "after")
		helpers.assert_eq(adapter.read(TMP), "after",
			"a no-op delete must not disturb the next write")
		os.remove(TMP)
	end)
end)




-- =====================================
--- =====================================
-- ======= 6/ WindowInfo Vectors ========
--- =====================================
-- =====================================

helpers.describe("Adapter contract vectors: WindowInfo", function()
	local adapter = helpers.load_with_stubs("adapters.window_info")

	helpers.it("getFocused_returns_object — always returns a table, never nil", function()
		local result = adapter.getFocused()
		helpers.assert_true(type(result) == "table",
			"getFocused() must always return a table")
	end)

	helpers.it("getFocused with no focused window still returns the full shape", function()
		local info = adapter.getFocused()
		helpers.assert_eq(type(info), "table",
			"there is always an answer — the keystats writes this into every row")
		helpers.assert_eq(type(info.appId), "string",
			"appId must be a string even with nothing focused: it keys the privacy "
				.. "filters, and a nil there would compare unequal to every rule")
	end)

	helpers.it("getFocused_fields_are_strings — all four WindowInfo fields are strings", function()
		local info = adapter.getFocused()
		local SHAPE = { "appId", "windowTitle", "bundleId", "executablePath" }
		for _, field in ipairs(SHAPE) do
			helpers.assert_true(
				type(info[field]) == "string",
				string.format("getFocused().%s must be a string, got %s",
					field, type(info[field]))
			)
		end
	end)

	helpers.it("getAll_returns_array — returns a table (possibly empty)", function()
		local result = adapter.getAll()
		helpers.assert_true(type(result) == "table",
			"getAll() must return a table")
	end)

	helpers.it("getAll in a restricted environment returns an empty list, not nil", function()
		local all = adapter.getAll()
		helpers.assert_eq(type(all), "table",
			"callers ipairs() this — a nil would throw at the call site instead of "
				.. "here, where the cause is visible")
		for i, w in ipairs(all) do
			helpers.assert_eq(type(w), "table", "entry " .. i .. " must be a WindowInfo table")
		end
	end)
end)
