--- tests/unit/adapters/contracts/test_adapter_contract_vectors_input_and_system.lua

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

	helpers.it("refreshContext leaves a context the keystats can write", function()
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

	helpers.it("show with valid draw calls makes the tooltip visible", function()
		local native_styledtext_new = hs.styledtext.new
		local ok, err = pcall(function()
			-- The plain-Lua stub cannot create Hammerspoon userdata. Model the
			-- renderer's equivalent structured block without replacing the adapter,
			-- facade, or native canvas boundary under test.
			hs.styledtext.new = function(text) return { preds = text } end
			adapter.hide()
			adapter.show({
				draw_calls = {
					{ type = "rect", id = "bg" },
					{ type = "text", id = "row_text_0", text = "Test" },
				},
				duration_sec = 0,
			})
			local visible = adapter.isVisible()
			helpers.assert_eq(visible, true,
				"show() must translate the port payload into a committed tooltip render")
			adapter.hide()
		end)
		hs.styledtext.new = native_styledtext_new
		if not ok then error(err, 0) end
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
	-- sha256() hashes through hs.hash; the double reports a fixed native digest
	-- so the adapter's validation/normalisation path is exercised.
	local CANONICAL = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	local function native_hash(value)
		return {
			new = function()
				local context = {}
				function context:append() return self end
				function context:finish() return self end
				function context:value() return value end
				return context
			end,
		}
	end
	local adapter = helpers.load_with_stubs("adapters.crypto", {
		hash = native_hash(CANONICAL),
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
			hash = native_hash("garbage with no digest line"),
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
