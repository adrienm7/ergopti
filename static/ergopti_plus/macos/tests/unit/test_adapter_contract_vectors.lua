--- tests/unit/test_adapter_contract_vectors.lua

--- ==============================================================================
--- MODULE: Adapter Contract Behaviour Tests
--- DESCRIPTION:
--- Executes the contractTestVectors() scenarios defined in each
--- shared/ports/*.spec.js — translated into Lua so they run under the
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
--- expected outputs, mirroring the JS source exactly. When the JS vectors are
--- updated the Lua mirrors must be updated to match — the tests will fail until
--- they are synchronised, making drift immediately visible.
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

	helpers.it("send_info does not throw", function()
		notify_calls = {}
		local ok = pcall(function() adapter.send("Configuration loaded.", { level = "info" }) end)
		helpers.assert_true(ok, "send() must not throw")
		helpers.assert_true(#notify_calls > 0, "hs.notify.new must have been called")
	end)

	helpers.it("send_success does not throw", function()
		notify_calls = {}
		local ok = pcall(function() adapter.send("LLM bridge initialized.", { level = "success" }) end)
		helpers.assert_true(ok, "send() must not throw")
	end)

	helpers.it("send_warning does not throw", function()
		notify_calls = {}
		local ok = pcall(function() adapter.send("API key not set.", { level = "warning" }) end)
		helpers.assert_true(ok, "send() must not throw")
	end)

	helpers.it("send_error does not throw", function()
		notify_calls = {}
		local ok = pcall(function() adapter.send("Configuration file missing.", { level = "error" }) end)
		helpers.assert_true(ok, "send() must not throw")
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

	helpers.it("os_failure_does_not_propagate — adapter catches OS throws", function()
		notify_throws = true
		local ok = pcall(function() adapter.send("Test.", { level = "info" }) end)
		notify_throws = false
		helpers.assert_true(ok, "send() must catch and absorb OS exceptions")
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

	helpers.it("cancel is safe when no request is in flight", function()
		local fresh = helpers.load_with_stubs("adapters.http_client")
		local ok = pcall(function() fresh.cancel() end)
		helpers.assert_true(ok, "cancel() on idle adapter must not throw")
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

	helpers.it("send does not throw for short text", function()
		local ok = pcall(function() adapter.send("hello", {}, function() end) end)
		helpers.assert_true(ok, "send() must not throw for short text")
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

	helpers.it("cancel on already-fired handle is safe", function()
		hs.timer.__timers[1] = nil
		local handle = adapter.after(0.1, function() end)
		hs.timer.__fire_all()
		local ok = pcall(function() adapter.cancel(handle) end)
		helpers.assert_true(ok, "cancel() on a fired handle must not throw")
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

	helpers.it("delete on missing file is a no-op (does not throw)", function()
		os.remove(TMP)
		local ok = pcall(function() adapter.delete(TMP) end)
		helpers.assert_true(ok, "delete() on missing file must not throw")
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

	helpers.it("getFocused_no_exception — does not throw even when no window is focused", function()
		local ok = pcall(function() adapter.getFocused() end)
		helpers.assert_true(ok, "getFocused() must not throw")
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

	helpers.it("getAll_no_exception — does not throw even in restricted env", function()
		local ok = pcall(function() adapter.getAll() end)
		helpers.assert_true(ok, "getAll() must not throw")
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

	helpers.it("stop_when_not_running_is_safe — stop() is idempotent", function()
		adapter.stop()
		local ok = pcall(function() adapter.stop() end)
		helpers.assert_true(ok, "stop() when not running must not throw")
	end)

	helpers.it("getContext_returns_table — getContext() returns a table", function()
		local ctx = adapter.getContext()
		helpers.assert_true(
			ctx == nil or type(ctx) == "table",
			"getContext() must return nil or a table"
		)
	end)

	helpers.it("refreshContext does not throw", function()
		local ok = pcall(function() adapter.refreshContext() end)
		helpers.assert_true(ok, "refreshContext() must not throw")
	end)
end)




-- ==============================================
--- ==============================================
-- ======= 8/ TooltipRenderer Vectors ============
--- ==============================================
-- ==============================================

helpers.describe("Adapter contract vectors: TooltipRenderer", function()
	local adapter = helpers.load_with_stubs("adapters.tooltip_renderer")

	helpers.it("hide is safe when not showing", function()
		local ok = pcall(function() adapter.hide() end)
		helpers.assert_true(ok, "hide() when not visible must not throw")
	end)

	helpers.it("isVisible returns false after hide()", function()
		adapter.hide()
		local visible = adapter.isVisible()
		helpers.assert_true(visible == false or visible == nil,
			"isVisible() must return false/nil after hide()")
	end)

	helpers.it("show does not throw for a minimal payload", function()
		local payload = { lines = { { text = "Test", size = 14 } } }
		local ok = pcall(function() adapter.show(payload) end)
		helpers.assert_true(ok, "show() with minimal payload must not throw")
	end)

	helpers.it("updateElement does not throw for a draw_call payload", function()
		local draw_call = { type = "text", text = "Updated", size = 12 }
		local ok = pcall(function() adapter.updateElement(draw_call) end)
		helpers.assert_true(ok, "updateElement() must not throw")
	end)
end)




-- =========================================
--- =========================================
-- ======= 9/ TrayMenu Vectors ==============
--- =========================================
-- =========================================

helpers.describe("Adapter contract vectors: TrayMenu", function()
	local adapter = helpers.load_with_stubs("adapters.tray_menu")

	helpers.it("setTooltip does not throw", function()
		local ok = pcall(function() adapter.setTooltip("Test tooltip") end)
		helpers.assert_true(ok, "setTooltip() must not throw")
	end)

	helpers.it("setMenu does not throw for an empty items list", function()
		local ok = pcall(function() adapter.setMenu({}) end)
		helpers.assert_true(ok, "setMenu([]) must not throw")
	end)

	helpers.it("setIcon does not throw for a valid icon opts table", function()
		local ok = pcall(function() adapter.setIcon({ state = "active" }) end)
		helpers.assert_true(ok, "setIcon() must not throw")
	end)

	helpers.it("destroy does not throw", function()
		local ok = pcall(function() adapter.destroy() end)
		helpers.assert_true(ok, "destroy() must not throw")
	end)

	helpers.it("destroy is idempotent — safe to call twice", function()
		adapter.destroy()
		local ok = pcall(function() adapter.destroy() end)
		helpers.assert_true(ok, "destroy() called twice must not throw")
	end)
end)
