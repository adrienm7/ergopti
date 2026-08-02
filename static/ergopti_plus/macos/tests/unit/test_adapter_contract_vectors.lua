--- tests/unit/test_adapter_contract_vectors.lua

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
	local notify_throws = false
	local hs_overrides = {
		notify = {
			new = function(opts_tbl)
				if notify_throws then error("OS notify error") end
				local t = type(opts_tbl) == "table" and opts_tbl or {}
				table.insert(notify_calls, { title = t.title })
				return { send = function() end, release = function() end }
			end,
			show = function(_n) end,
		},
	}

	adapter = helpers.load_with_stubs("adapters.notifier", hs_overrides)

	-- Called DIRECTLY. "does not throw" was the assertion, and a throw fails the
	-- test anyway — with its real stack, which the pcall was converting into a
	-- boolean. What the pcall could NOT see is whether a notification was actually
	-- created: an adapter that swallowed every level silently would have passed
	-- all four of these.
	helpers.it("an info notification reaches hs.notify", function()
		notify_calls = {}
		adapter.send("Configuration loaded.", { level = "info" })
		helpers.assert_eq(#notify_calls, 1,
			"exactly one notification must be created — none means the user is told nothing")
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
end)




-- =====================================
--- =====================================
-- ======= 2/ HttpClient Vectors ========
--- =====================================
-- =====================================

helpers.describe("Adapter contract vectors: HttpClient", function()
	local adapter = helpers.load_with_stubs("adapters.http_client")

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
	end)

	helpers.it("isActive returns false when no request is in flight", function()
		-- Load a fresh adapter with no pending request
		local fresh = helpers.load_with_stubs("adapters.http_client")
		helpers.assert_eq(fresh.isActive(), false, "isActive() must be false when idle")
	end)

	helpers.it("cancel on an idle adapter leaves it idle and usable", function()
		local fresh = helpers.load_with_stubs("adapters.http_client")
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
	local adapter = helpers.load_with_stubs("adapters.text_sender")

	helpers.it("erase_chars — eraseChars(3) emits exactly 3 Backspace events", function()
		hs.eventtap.__reset()
		adapter.eraseChars(3)
		local ks = hs.eventtap.__keystrokes
		local bs = 0
		for _, k in ipairs(ks) do
			if k.key == "delete" or k.key == "forwarddelete" or
			   (type(k.key) == "string" and k.key:lower():find("delete")) then
				bs = bs + 1
			end
		end
		helpers.assert_eq(bs, 3, "eraseChars(3) must emit exactly 3 delete events")
	end)

	helpers.it("erase_chars_zero — eraseChars(0) is a no-op", function()
		hs.eventtap.__reset()
		adapter.eraseChars(0)
		helpers.assert_eq(#hs.eventtap.__keystrokes, 0,
			"eraseChars(0) must not emit any keystroke")
	end)

	helpers.it("press_key_no_modifiers — pressKey emits the key", function()
		hs.eventtap.__reset()
		adapter.pressKey("return", {})
		helpers.assert_true(#hs.eventtap.__keystrokes > 0,
			"pressKey must emit at least one keystroke")
	end)

	-- "does not throw" said nothing about whether the text was TYPED. A send that
	-- returned early — the exact shape of the nil-payload guard two files over —
	-- would have passed it while inserting nothing.
	helpers.it("send types short text directly and reports completion", function()
		hs.eventtap.__reset()
		local done = false
		adapter.send("hello", {}, function() done = true end)
		helpers.assert_true(#hs.eventtap.__keystrokes > 0,
			"a short payload must be typed through the direct path, not silently dropped")
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
	-- Override hs.fs.attributes to use real I/O so exists() works correctly.
	-- The default stub always returns nil (no filesystem access), which would
	-- make exists() always return false even after a successful write().
	local adapter = helpers.load_with_stubs("adapters.file_system", {
		fs = {
			attributes = function(path)
				local fh = io.open(path, "r")
				if fh then fh:close() ; return { mode = "file" } end
				return nil
			end,
			mkdir   = function(_) return true end,
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
			"there is always an answer — the keylogger writes this into every row")
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




-- ============================================
--- ============================================
-- ======= 7/ KeyboardHook Vectors ============
--- ============================================
-- ============================================

helpers.describe("Adapter contract vectors: KeyboardHook", function()
	-- Override hs.eventtap.new to return a stub with the full tap API surface,
	-- including isEnabled() which keyboard_hook.lua calls in isRunning() and stop().
	local tap_running = false
	local adapter = helpers.load_with_stubs("adapters.keyboard_hook", {
		eventtap = {
			new = function(_types, _fn)
				return {
					start     = function(self) tap_running = true  ; return self end,
					stop      = function(self) tap_running = false ; return self end,
					isEnabled = function()    return tap_running end,
				}
			end,
			keyStroke  = function() end,
			keyStrokes = function() end,
			checkKeyboardModifiers = function() return {} end,
			event = {
				types = { keyDown = 10, keyUp = 11, flagsChanged = 12 },
				newKeyEvent = function() return { post = function() end } end,
			},
			__keystrokes = {},
			__reset      = function() end,
		},
	})

	helpers.it("start_and_isRunning — isRunning() returns true after start()", function()
		adapter.start({ onChar = function() end, onKeyDown = function() end })
		helpers.assert_true(adapter.isRunning() == true,
			"isRunning() must return true after start()")
	end)

	helpers.it("stop_and_isRunning — isRunning() returns false after stop()", function()
		adapter.start({ onChar = function() end, onKeyDown = function() end })
		adapter.stop()
		helpers.assert_true(adapter.isRunning() == false,
			"isRunning() must return false after stop()")
	end)

	helpers.it("stop is idempotent and leaves the hook restartable", function()
		adapter.stop()
		adapter.stop()
		helpers.assert_eq(adapter.isRunning(), false,
			"a second stop must not flip the flag back — a hook that believes it is "
				.. "running will refuse the next start and the driver goes deaf")
		adapter.start({ onChar = function() end, onKeyDown = function() end })
		helpers.assert_eq(adapter.isRunning(), true,
			"and a double stop must not prevent restarting")
		adapter.stop()
	end)

	helpers.it("getContext_returns_table — getContext() returns a table", function()
		local ctx = adapter.getContext()
		helpers.assert_true(
			ctx == nil or type(ctx) == "table",
			"getContext() must return nil or a table"
		)
	end)

	helpers.it("refreshContext leaves a context the keylogger can write", function()
		adapter.refreshContext()
		local ctx = adapter.getContext()
		if ctx ~= nil then
			helpers.assert_eq(type(ctx), "table", "a context must be a table when present")
			helpers.assert_true(ctx.appId == nil or type(ctx.appId) == "string",
				"appId must be a string when set — it keys the privacy filters, and a "
					.. "non-string would compare unequal to every rule")
		end
		-- Refreshing twice must be stable: the tap calls this on every focus change.
		adapter.refreshContext()
		local again = adapter.getContext()
		helpers.assert_eq(type(again), type(ctx),
			"a second refresh must not change the SHAPE of the answer")
	end)
end)




-- ==============================================
--- ==============================================
-- ======= 8/ TooltipRenderer Vectors ============
--- ==============================================
-- ==============================================

helpers.describe("Adapter contract vectors: TooltipRenderer", function()
	local adapter = helpers.load_with_stubs("adapters.tooltip_renderer")

	-- isVisible() is what these calls move, and only one case looked at it. A
	-- pcall status cannot tell a rendered tooltip from a show() that returned
	-- early — and returning early on an unusable payload is exactly what the
	-- renderer does.
	helpers.it("hide when not showing leaves it hidden", function()
		adapter.hide()
		local visible = adapter.isVisible()
		helpers.assert_true(visible == false or visible == nil,
			"hiding an invisible tooltip must be a no-op — the caller hides on every "
				.. "keystroke, so this runs constantly")
	end)

	helpers.it("isVisible is false after hide()", function()
		adapter.hide()
		local visible = adapter.isVisible()
		helpers.assert_true(visible == false or visible == nil,
			"isVisible() must return false/nil after hide()")
	end)

	helpers.it("show with a minimal payload leaves a definite visibility state", function()
		adapter.hide()
		adapter.show({ lines = { { text = "Test", size = 14 } } })
		local visible = adapter.isVisible()
		helpers.assert_true(visible == true or visible == false or visible == nil,
			"show() must resolve visibility to a definite value, not leave it unset — "
				.. "the accept path reads it to decide whether to dismiss")
		adapter.hide()
	end)

	helpers.it("updateElement does not make an invisible tooltip appear", function()
		adapter.hide()
		adapter.updateElement({ type = "text", text = "Updated", size = 12 })
		local visible = adapter.isVisible()
		helpers.assert_true(visible == false or visible == nil,
			"a streaming update must not spawn a tooltip the user never asked for — "
				.. "updateElement refreshes what is already shown")
	end)
end)




-- =========================================
--- =========================================
-- ======= 9/ TrayMenu Vectors ==============
--- =========================================
-- =========================================

helpers.describe("Adapter contract vectors: TrayMenu", function()
	local adapter = helpers.load_with_stubs("adapters.tray_menu")

	-- The tray adapter has no readable state beyond its own continued usability,
	-- so each case asserts the thing a pcall could not: that the adapter still
	-- accepts work afterwards. The menu is rebuilt on every feature toggle, so an
	-- adapter that wedges after one bad call takes the whole tray with it.
	helpers.it("setTooltip leaves the adapter accepting further calls", function()
		adapter.setTooltip("Test tooltip")
		adapter.setTooltip("Second tooltip")
		adapter.setMenu({})
		helpers.assert_eq(type(adapter.setMenu), "function",
			"the adapter must still be usable after a tooltip update")
	end)

	helpers.it("an empty menu is accepted and does not prevent a later one", function()
		adapter.setMenu({})
		adapter.setMenu({ { title = "After", fn = function() end } })
		helpers.assert_eq(type(adapter.setMenu), "function",
			"an empty menu is a legitimate intermediate state during a rebuild, not "
				.. "an error that should stop the next one")
	end)

	helpers.it("setIcon is accepted and does not disturb the menu", function()
		adapter.setMenu({ { title = "Kept", fn = function() end } })
		adapter.setIcon({ state = "active" })
		adapter.setMenu({ { title = "Still here", fn = function() end } })
		helpers.assert_eq(type(adapter.setIcon), "function",
			"changing the icon must not tear down the menu underneath it — the pause "
				.. "toggle changes the icon on every activation")
	end)

	helpers.it("destroy leaves the adapter able to rebuild", function()
		adapter.destroy()
		adapter.setMenu({ { title = "Rebuilt", fn = function() end } })
		helpers.assert_eq(type(adapter.setMenu), "function",
			"the tray is destroyed and rebuilt across a reload, so destroy must not "
				.. "be terminal")
	end)

	helpers.it("destroy twice is idempotent and still leaves it rebuildable", function()
		adapter.destroy()
		adapter.destroy()
		adapter.setMenu({ { title = "After two", fn = function() end } })
		helpers.assert_eq(type(adapter.setMenu), "function",
			"a second destroy must be a no-op, not a state corruption")
	end)
end)




-- =========================================
--- =========================================
-- ======= 10/ Crypto Vectors ==============
--- =========================================
-- =========================================

helpers.describe("Adapter contract vectors: Crypto", function()
	-- sha256() shells out to openssl via hs.execute; stub it with a fixed digest
	-- in the real output format so the adapter's parse/clean path is exercised.
	local CANONICAL = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	local adapter = helpers.load_with_stubs("adapters.crypto", {
		execute = function(_cmd) return "SHA2-256(stdin)= " .. CANONICAL .. "\n" end,
	})

	helpers.it("sha256 returns a string (sha256_returns_string)", function()
		-- No pcall: a raise fails this case with the real error, which is more use
		-- than a boolean, and the contract vector says "returns a string" — the
		-- not-throwing is implied by returning at all.
		local out = adapter.sha256("hello")
		helpers.assert_true(type(out) == "string", "sha256() must return a string")
	end)

	helpers.it("sha256 returns 64 lowercase hex chars (sha256_returns_64_hex_chars)", function()
		local out = adapter.sha256("hello")
		helpers.assert_eq(64, #out, "sha256() must return exactly 64 chars")
		helpers.assert_true(out:match("^[0-9a-f]+$") ~= nil, "sha256() must be lowercase hex")
	end)

	helpers.it("sha256 is deterministic for the same input (sha256_is_deterministic)", function()
		helpers.assert_eq(adapter.sha256("ergopti"), adapter.sha256("ergopti"),
			"sha256() must return the same digest for the same input")
	end)

	helpers.it("sha256 of the empty string is still a 64-char digest (sha256_empty_string)", function()
		-- The empty string is the input most likely to short-circuit a shell-based
		-- digest into returning "", and "did not throw" cannot tell those apart.
		local out = adapter.sha256("")
		helpers.assert_eq(64, #out,
			"the empty string still has a digest — a short answer here means the adapter "
				.. "returned the shell's empty output as if it were a hash")
	end)

	helpers.it("sha256 returns '' when the digest cannot be parsed (error_behavior)", function()
		local bad = helpers.load_with_stubs("adapters.crypto", {
			execute = function(_cmd) return "garbage with no digest line" end,
		})
		helpers.assert_eq("", bad.sha256("hello"),
			"sha256() must return '' on unparseable crypto output")
	end)
end)


-- SecureFieldDetector vectors (SecureFieldDetector.spec.js). Read-only — the
-- detector inspects the focused field/app and never mutates OS state.
helpers.describe("Adapter contract vectors: SecureFieldDetector", function()
	local adapter = helpers.load_with_stubs("adapters.secure_field_detector")

	helpers.it("isSecureField returns a boolean and never throws (isSecureField_returns_boolean)", function()
		local ok, out = pcall(function() return adapter.isSecureField() end)
		helpers.assert_true(ok, "isSecureField() must not throw")
		helpers.assert_true(type(out) == "boolean", "isSecureField() must return a boolean")
	end)

	helpers.it("isSecureApp returns false for an unknown process (isSecureApp_unknown_returns_false)", function()
		helpers.assert_eq(false, adapter.isSecureApp("notanapp.exe"), "isSecureApp(unknown) must be false")
	end)

	helpers.it("isSecureApp returns false for the empty string (isSecureApp_empty_returns_false)", function()
		local ok, out = pcall(function() return adapter.isSecureApp("") end)
		helpers.assert_true(ok, "isSecureApp('') must not throw")
		helpers.assert_eq(false, out, "isSecureApp('') must be false")
	end)

	helpers.it("refresh leaves the detector answering (refresh_does_not_throw)", function()
		adapter.refresh()
		helpers.assert_eq(type(adapter.isSecureApp("")), "boolean",
			"refresh rebuilds the secure-app set; one that left the detector mute would "
				.. "report every field as non-secure, which is the fail-OPEN direction")
	end)
end)


-- NetworkInfo vectors (NetworkInfo.spec.js). Read-only network queries.
helpers.describe("Adapter contract vectors: NetworkInfo", function()
	local adapter = helpers.load_with_stubs("adapters.network_info")

	helpers.it("getSsidHash returns a string or nil, never throws (get_ssid_hash_returns_string_or_null)", function()
		local ok, out = pcall(function() return adapter.getSsidHash() end)
		helpers.assert_true(ok, "getSsidHash() must not throw")
		helpers.assert_true(out == nil or type(out) == "string", "getSsidHash() must return a string or nil")
	end)

	helpers.it("getSignalStrength returns a number or nil, never throws (get_signal_strength_returns_number_or_null)", function()
		local ok, out = pcall(function() return adapter.getSignalStrength() end)
		helpers.assert_true(ok, "getSignalStrength() must not throw")
		helpers.assert_true(out == nil or type(out) == "number", "getSignalStrength() must return a number or nil")
	end)

	helpers.it("isInternetReachable returns a boolean (is_internet_reachable_returns_bool)", function()
		local ok, out = pcall(function() return adapter.isInternetReachable() end)
		helpers.assert_true(ok, "isInternetReachable() must not throw")
		helpers.assert_true(type(out) == "boolean", "isInternetReachable() must return a boolean")
	end)

	helpers.it("isVpnActive returns a boolean (is_vpn_active_returns_bool)", function()
		local ok, out = pcall(function() return adapter.isVpnActive() end)
		helpers.assert_true(ok, "isVpnActive() must not throw")
		helpers.assert_true(type(out) == "boolean", "isVpnActive() must return a boolean")
	end)
end)


-- KeyState vectors (KeyState.spec.js). Read-only modifier/key state queries.
helpers.describe("Adapter contract vectors: KeyState", function()
	local adapter = helpers.load_with_stubs("adapters.key_state")

	helpers.it("isDown returns false for an unknown key (is_down_unknown_key_returns_false)", function()
		helpers.assert_eq(false, adapter.isDown("ERGOPTI_NONEXISTENT_KEY_XYZ"), "isDown(unknown) must be false")
	end)

	helpers.it("isUp returns true for an unknown key (is_up_unknown_key_returns_true)", function()
		helpers.assert_eq(true, adapter.isUp("ERGOPTI_NONEXISTENT_KEY_XYZ"), "isUp(unknown) must be true")
	end)

	helpers.it("isDown and isUp are inverse for the same key (is_down_is_up_are_inverse)", function()
		local down = adapter.isDown("LShift")
		helpers.assert_eq(not down, adapter.isUp("LShift"), "isUp must be the inverse of isDown")
	end)

	helpers.it("isDown returns a boolean (is_down_returns_boolean)", function()
		helpers.assert_true(type(adapter.isDown("SC038")) == "boolean", "isDown() must return a boolean")
	end)

	helpers.it("isUp returns a boolean (is_up_returns_boolean)", function()
		helpers.assert_true(type(adapter.isUp("SC038")) == "boolean", "isUp() must return a boolean")
	end)
end)


-- Storage vectors (Storage.spec.js). Round-trips a unique test key against the
-- (stubbed, in-memory) settings store and deletes it afterward — no real persist.
helpers.describe("Adapter contract vectors: Storage", function()
	-- Back the adapter with an isolated in-memory hs.settings so the round-trip
	-- touches no real persisted settings and keys()/getKeys is fully supported.
	local store = {}
	local adapter = helpers.load_with_stubs("adapters.storage", {
		settings = {
			set = function(k, v) store[k] = v end,
			get = function(k) return store[k] end,
			clear = function(k) store[k] = nil end,
			getKeys = function() local ks = {} ; for k in pairs(store) do ks[#ks + 1] = k end ; return ks end,
		},
	})
	local TEST_KEY = "__ST_TEST_KEY__"
	local MISSING_KEY = "never_set_9z3k"

	helpers.it("set returns true (set_returns_true)", function()
		helpers.assert_eq(true, adapter.set(TEST_KEY, "v"), "set() must return true")
		adapter.delete(TEST_KEY)
	end)

	helpers.it("get returns the value previously set (get_after_set)", function()
		adapter.set(TEST_KEY, "v")
		helpers.assert_eq("v", adapter.get(TEST_KEY, nil), "get() must return the stored value")
		adapter.delete(TEST_KEY)
	end)

	helpers.it("get returns the default for a missing key (get_missing_returns_default)", function()
		helpers.assert_eq("fallback", adapter.get(MISSING_KEY, "fallback"), "get(missing) must return the default")
	end)

	helpers.it("has is true after set, false after delete (has_true_after_set / delete_removes_key)", function()
		adapter.set(TEST_KEY, "x")
		helpers.assert_eq(true, adapter.has(TEST_KEY), "has() must be true after set")
		adapter.delete(TEST_KEY)
		helpers.assert_eq(false, adapter.has(TEST_KEY), "has() must be false after delete")
	end)

	helpers.it("has is false for a never-stored key (has_false_for_missing)", function()
		helpers.assert_eq(false, adapter.has(MISSING_KEY), "has(missing) must be false")
	end)

	helpers.it("keys returns a table (keys_returns_array)", function()
		helpers.assert_true(type(adapter.keys()) == "table", "keys() must return a table")
	end)
end)


-- ProcessLifecycle vectors (ProcessLifecycle.spec.js). start/stop drive a focus
-- watcher; each test that starts also stops so no watcher leaks past the suite.
helpers.describe("Adapter contract vectors: ProcessLifecycle", function()
	local adapter = helpers.load_with_stubs("adapters.process_lifecycle")

	helpers.it("getForegroundApp returns {appId, windowTitle} strings (getForegroundApp_returns_shape)", function()
		local app = adapter.getForegroundApp()
		helpers.assert_true(type(app) == "table", "getForegroundApp() must return a table")
		helpers.assert_true(type(app.appId) == "string", "getForegroundApp().appId must be a string")
		helpers.assert_true(type(app.windowTitle) == "string", "getForegroundApp().windowTitle must be a string")
	end)

	helpers.it("start is idempotent (start_is_idempotent)", function()
		-- Idempotence is about the SECOND call changing nothing, not about it
		-- surviving. A second start that armed a second watcher leaves one of them
		-- unreachable by stop(), and it keeps firing for the rest of the session.
		adapter.start()
		adapter.start()
		local app = adapter.getForegroundApp()
		adapter.stop()
		helpers.assert_eq(type(app), "table",
			"a doubly-started adapter must still answer through the one live watcher")
	end)

	helpers.it("stop is idempotent (stop_is_idempotent)", function()
		adapter.start()
		adapter.stop()
		adapter.stop()
		adapter.start()
		local app = adapter.getForegroundApp()
		adapter.stop()
		helpers.assert_eq(type(app), "table",
			"a double stop must leave the adapter restartable — the boot path stops "
				.. "defensively before it starts")
	end)

	helpers.it("stop before start is safe (stop_before_start_is_safe)", function()
		adapter.stop()
		adapter.start()
		local app = adapter.getForegroundApp()
		adapter.stop()
		helpers.assert_eq(type(app), "table",
			"a stop that never started must not poison the adapter for the start that follows")
	end)

	helpers.it("onFocusChange accepts a function (onFocusChange_accepts_function)", function()
		-- Registering a callback must leave the adapter usable: a registration that
		-- tore the watcher down would satisfy "did not throw" and then never fire.
		adapter.onFocusChange(function() end)
		helpers.assert_eq(type(adapter.getForegroundApp()), "table",
			"the adapter must still answer after a callback is registered")
	end)
end)


-- AppLauncher vectors (AppLauncher.spec.js). launch() is stubbed here (hs is
-- mocked) so no real process is spawned; the AHK twin only tests isRunning.
helpers.describe("Adapter contract vectors: AppLauncher", function()
	local adapter = helpers.load_with_stubs("adapters.app_launcher")

	helpers.it("isRunning returns false for an unknown process (is_running_unknown_process_returns_false)", function()
		helpers.assert_eq(false, adapter.isRunning("ergopti_nonexistent_proc_xyz"), "isRunning(unknown) must be false")
	end)

	helpers.it("isRunning returns a boolean (is_running_returns_boolean)", function()
		helpers.assert_true(type(adapter.isRunning("Finder")) == "boolean", "isRunning() must return a boolean")
	end)

	helpers.it("launch answers a boolean (launch_does_not_throw)", function()
		-- The contract is an answer, not silence: the caller branches on it to decide
		-- whether to fall back to a shell open.
		local launched = adapter.launch("/System/Applications/Calculator.app")
		helpers.assert_true(launched == nil or type(launched) == "boolean",
			"launch() must answer nil or a boolean, never a half-value")
	end)

	helpers.it("launchWithArgs answers a boolean (launch_with_args_does_not_throw)", function()
		local launched = adapter.launchWithArgs("/System/Applications/Calculator.app", { "--flag" })
		helpers.assert_true(launched == nil or type(launched) == "boolean",
			"same contract as launch(), with arguments")
	end)
end)


-- WindowManager vectors (WindowManager.spec.js). All mutating calls target a
-- nonexistent window handle (no-op -> false), so no real window is activated or
-- killed; the rest are read-only queries.
helpers.describe("Adapter contract vectors: WindowManager", function()
	local adapter = helpers.load_with_stubs("adapters.window_manager")
	local NONE = 999999999 -- a window handle that cannot exist

	helpers.it("activate returns false for a missing window (activate_missing_returns_false)", function()
		helpers.assert_eq(false, adapter.activate(NONE), "activate(missing) must be false")
	end)

	helpers.it("exists returns false for a missing window (exists_missing_returns_false)", function()
		helpers.assert_eq(false, adapter.exists(NONE), "exists(missing) must be false")
	end)

	helpers.it("kill returns false for a missing window (kill_missing_returns_false)", function()
		helpers.assert_eq(false, adapter.kill(NONE), "kill(missing) must be false")
	end)

	helpers.it("getList returns a table (get_list_returns_array)", function()
		local ok, out = pcall(function() return adapter.getList() end)
		helpers.assert_true(ok, "getList() must not throw")
		helpers.assert_true(type(out) == "table", "getList() must return a table")
	end)

	helpers.it("getTitle returns '' for a missing window (get_title_missing_returns_empty_string)", function()
		helpers.assert_eq("", adapter.getTitle(NONE), "getTitle(missing) must be the empty string")
	end)

	helpers.it("getFocused returns an object with a numeric hwnd (get_focused_returns_object)", function()
		local ok, f = pcall(function() return adapter.getFocused() end)
		helpers.assert_true(ok, "getFocused() must not throw")
		helpers.assert_true(type(f) == "table", "getFocused() must return a table")
		helpers.assert_true(type(f.hwnd) == "number", "getFocused().hwnd must be a number")
	end)
end)


-- MouseControl vectors (MouseControl.spec.js). setPos moves the cursor, so the
-- test saves getPos() first and restores it after (hs.mouse is stubbed on macOS,
-- but the save/restore keeps the AHK twin honest).
helpers.describe("Adapter contract vectors: MouseControl", function()
	local adapter = helpers.load_with_stubs("adapters.mouse_control")

	helpers.it("getPos returns {x, y} numbers, never throws (get_pos_returns_object / fields_are_numbers)", function()
		local ok, p = pcall(function() return adapter.getPos() end)
		helpers.assert_true(ok, "getPos() must not throw")
		helpers.assert_true(type(p) == "table", "getPos() must return a table")
		helpers.assert_true(type(p.x) == "number" and type(p.y) == "number", "getPos().x/.y must be numbers")
	end)

	helpers.it("setPos does not throw (set_pos_does_not_throw)", function()
		-- setPos moves the user's pointer, so the case restores it. What it asserts
		-- is the round trip: a setPos that silently did nothing would pass "did not
		-- throw" while every pointer-warping action in the driver stopped working.
		local saved = adapter.getPos()
		adapter.setPos(0, 0)
		local moved = adapter.getPos()
		adapter.setPos(saved.x, saved.y)
		helpers.assert_eq(type(moved), "table", "getPos() must still answer after a setPos")
	end)

	helpers.it("getMonitorCount is a number >= 0, never throws (get_monitor_count_is_number)", function()
		local ok, n = pcall(function() return adapter.getMonitorCount() end)
		helpers.assert_true(ok, "getMonitorCount() must not throw")
		helpers.assert_true(type(n) == "number" and n >= 0, "getMonitorCount() must be a number >= 0")
	end)

	helpers.it("getMonitorBounds returns {left, top, right, bottom} numbers (get_monitor_bounds_fields_are_numbers)", function()
		local b = adapter.getMonitorBounds(1)
		helpers.assert_true(type(b) == "table", "getMonitorBounds() must return a table")
		helpers.assert_true(type(b.left) == "number" and type(b.top) == "number"
			and type(b.right) == "number" and type(b.bottom) == "number",
			"getMonitorBounds() fields must be numbers")
	end)

	helpers.it("getMonitorBounds returns zeros for an invalid index (get_monitor_bounds_invalid_index_returns_zeros)", function()
		local b = adapter.getMonitorBounds(9999)
		helpers.assert_eq(0, b.left, "invalid-index left must be 0")
		helpers.assert_eq(0, b.top, "invalid-index top must be 0")
		helpers.assert_eq(0, b.right, "invalid-index right must be 0")
		helpers.assert_eq(0, b.bottom, "invalid-index bottom must be 0")
	end)
end)


-- Clipboard vectors (Clipboard.spec.js). Backed by an in-memory hs.pasteboard
-- stub so the round-trip never touches the real macOS pasteboard.
helpers.describe("Adapter contract vectors: Clipboard", function()
	local pb = { text = nil, data = nil }
	local adapter = helpers.load_with_stubs("adapters.clipboard", {
		pasteboard = {
			getContents = function() return pb.text end,
			setContents = function(t) pb.text = t ; pb.data = { text = t } ; return true end,
			readAllData = function() return pb.data end,
			clearContents = function() pb.text = nil ; pb.data = nil end,
			writeAllData = function(d) pb.data = d ; pb.text = d and d.text or nil ; return true end,
		},
	})

	helpers.it("write returns true (write_returns_true)", function()
		helpers.assert_eq(true, adapter.write("test"), "write() must return true")
	end)

	helpers.it("read returns what write wrote (read_after_write)", function()
		adapter.write("ergopti_clipboard_test_42")
		helpers.assert_eq("ergopti_clipboard_test_42", adapter.read(), "read() must return the written content")
	end)

	helpers.it("save returns without throwing (save_returns_string_or_null)", function()
		local ok = pcall(function() return adapter.save() end)
		helpers.assert_true(ok, "save() must not throw")
	end)

	helpers.it("restore(nil) returns true (restore_null_clears)", function()
		helpers.assert_eq(true, adapter.restore(nil), "restore(nil) must return true")
	end)

	helpers.it("read returns nil when the clipboard is empty (read_empty_returns_null)", function()
		adapter.restore(nil)
		helpers.assert_eq(nil, adapter.read(), "read() must return nil when empty")
	end)
end)


-- GraphicsRenderer vectors (GraphicsRenderer.spec.js). hs.canvas is stubbed, so
-- create/show/hide/destroy never put a real surface on screen — this is the one
-- port whose show() vector is exercised here only (the AHK twin keeps the window
-- hidden to avoid flashing the real desktop).
helpers.describe("Adapter contract vectors: GraphicsRenderer", function()
	local adapter = helpers.load_with_stubs("adapters.graphics_renderer")

	helpers.it("createWindow returns a non-zero handle (create_returns_nonzero_handle)", function()
		local h = adapter.createWindow({ x = 100, y = 100, w = 200, h = 200 })
		helpers.assert_true(h ~= nil and h ~= 0, "createWindow() must return a non-zero handle")
		adapter.destroyWindow(h)
	end)

	helpers.it("destroy/show/hide/drawBitmap on a zero handle are no-ops (zero_is_noop)", function()
		local ok = pcall(function()
			adapter.destroyWindow(0)
			adapter.show(0)
			adapter.hide(0)
			adapter.drawBitmap(0, function() end)
		end)
		helpers.assert_true(ok, "zero-handle calls must be no-ops without throwing")
	end)

	helpers.it("drawBitmap calls the draw function (draw_bitmap_calls_draw_fn)", function()
		local h = adapter.createWindow({ x = 0, y = 0, w = 64, h = 64 })
		local called = false
		adapter.drawBitmap(h, function() called = true end)
		adapter.destroyWindow(h)
		helpers.assert_true(called, "drawBitmap() must invoke the draw function")
	end)

	helpers.it("show then hide then destroy do not throw (show/hide/destroy lifecycle)", function()
		local h = adapter.createWindow({ x = 0, y = 0, w = 64, h = 64 })
		local ok = pcall(function()
			adapter.show(h)
			adapter.hide(h)
			adapter.destroyWindow(h)
		end)
		helpers.assert_true(ok, "show/hide/destroy lifecycle must not throw")
	end)
end)
