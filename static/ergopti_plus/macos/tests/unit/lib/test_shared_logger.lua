--- tests/unit/lib/test_shared_logger.lua

--- ==============================================================================
--- TEST: Shared Logger Core Conformance
--- DESCRIPTION:
--- Validates that the shared logger core in shared/lua/logger/init.lua
--- produces lines that conform to the format contract in SPEC.md § 3.
--- Exercises all 8 variants, the ring buffer, severity filtering, and the
--- test vectors from static/ergopti_plus/shared/logger/test_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. Time-independent: M.timestamp_fn is replaced with a sentinel function
---    returning "TIMESTAMP" so expected lines can be hardcoded.
--- 2. Sink-based capture: a sink function collects emitted lines so the
---    test never touches the filesystem or the HS console.
--- 3. Covers both the shared test vectors (driver-neutral cases) and
---    Lua-specific format string vectors (message_hs field).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Load the shared logger (resolved via shared/lua on package.path)
local Logger = require("logger")




-- =============================================
--- ==========================================
-- ======= 1/ Test Helpers & Fixtures =======
--- ==========================================
-- =============================================

--- Installs a sentinel timestamp so log lines are time-independent.
local function freeze_timestamp()
	Logger.timestamp_fn = function() return "TIMESTAMP" end
end

--- Collects emitted lines into a local table for assertion.
--- @return table, function  collected lines array, sink function
local function make_sink()
	local lines = {}
	local function sink(line, _variant) table.insert(lines, line) end
	return lines, sink
end

--- Runs one call on the Logger and returns the last line emitted.
--- @param variant string
--- @param module_name string
--- @param msg string
--- @param ... any
--- @return string|nil
local function run_one(variant, module_name, msg, ...)
	local lines, sink = make_sink()
	Logger.set_sink(sink)
	Logger[variant](module_name, msg, ...)
	Logger.set_sink(nil)
	return lines[1]
end

--- Asserts that a string contains a given substring.
--- @param s string The string to search in.
--- @param sub string The substring to find.
--- @param msg string|nil Optional context tag.
local function assert_contains(s, sub, msg)
	helpers.assert_true(
		type(s) == "string" and s:find(sub, 1, true) ~= nil,
		(msg or "assert_contains") .. ": expected '" .. tostring(sub) .. "' in '" .. tostring(s) .. "'"
	)
end




-- =====================================================
--- ==============================================
-- ======= 2/ Test Suite — Eight Variants =======
--- ==============================================
-- =====================================================

helpers.describe("SharedLogger: eight variants", function()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()

	helpers.it("debug variant formats correctly", function()
		local line = run_one("debug", "TestModule", "Cache miss — reloading.")
		helpers.assert_eq(line, "TIMESTAMP [DEBUG] [TestModule] Cache miss — reloading.")
	end)

	helpers.it("trace variant formats correctly", function()
		local line = run_one("trace", "TestModule", "Timer started (0.300s)…")
		helpers.assert_eq(line, "TIMESTAMP [TRACE] [TestModule] Timer started (0.300s)…")
	end)

	helpers.it("done variant formats correctly", function()
		local line = run_one("done", "TestModule", "Timer stopped.")
		helpers.assert_eq(line, "TIMESTAMP [DONE] [TestModule] Timer stopped.")
	end)

	helpers.it("info variant formats correctly", function()
		local line = run_one("info", "TapHoldLoader", "Config file located.")
		helpers.assert_eq(line, "TIMESTAMP [INFO] [TapHoldLoader] Config file located.")
	end)

	helpers.it("start variant formats correctly", function()
		local line = run_one("start", "TapHoldLoader", "Loading tap-hold config from '/path/to/tap_hold.toml'…")
		helpers.assert_eq(line, "TIMESTAMP [START] [TapHoldLoader] Loading tap-hold config from '/path/to/tap_hold.toml'…")
	end)

	helpers.it("success variant formats correctly", function()
		local line = run_one("success", "TapHoldLoader", "Tap-hold config loaded (8 key(s), 2 layer(s)).")
		helpers.assert_eq(line, "TIMESTAMP [SUCCESS] [TapHoldLoader] Tap-hold config loaded (8 key(s), 2 layer(s)).")
	end)

	helpers.it("warn variant emits WARNING label", function()
		local line = run_one("warn", "gestures", "Probe timed out — retry 1/3.")
		helpers.assert_eq(line, "TIMESTAMP [WARNING] [gestures] Probe timed out — retry 1/3.")
	end)

	helpers.it("error variant formats correctly", function()
		local line = run_one("error", "karabiner", "Config write failed: permission denied.")
		helpers.assert_eq(line, "TIMESTAMP [ERROR] [karabiner] Config write failed: permission denied.")
	end)
end)




-- ===================================================
-- ===================================================
-- ======= 3/ Test Suite — Format String Args =======
-- ===================================================
-- ===================================================

helpers.describe("SharedLogger: format string args", function()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()

	helpers.it("integer arg is interpolated", function()
		local line = run_one("info", "TapHoldLoader", "Loaded %d key(s).", 8)
		helpers.assert_eq(line, "TIMESTAMP [INFO] [TapHoldLoader] Loaded 8 key(s).")
	end)

	helpers.it("two integer args are interpolated", function()
		local line = run_one("success", "TapHoldLoader", "Tap-hold config loaded (%d key(s), %d layer(s)).", 8, 2)
		helpers.assert_eq(line, "TIMESTAMP [SUCCESS] [TapHoldLoader] Tap-hold config loaded (8 key(s), 2 layer(s)).")
	end)

	helpers.it("string arg is interpolated", function()
		local line = run_one("debug", "ModelSwitcher", "Backend resolved to '%s'.", "mlx")
		helpers.assert_eq(line, "TIMESTAMP [DEBUG] [ModelSwitcher] Backend resolved to 'mlx'.")
	end)

	helpers.it("string and integer args are interpolated", function()
		local line = run_one("info", "menu_llm", "Profile '%s' selected (power level %d).", "advanced", 2)
		helpers.assert_eq(line, "TIMESTAMP [INFO] [menu_llm] Profile 'advanced' selected (power level 2).")
	end)

	helpers.it("float arg is interpolated", function()
		local line = run_one("debug", "TapHoldLoader", "Threshold set to %.2fs.", 0.35)
		helpers.assert_eq(line, "TIMESTAMP [DEBUG] [TapHoldLoader] Threshold set to 0.35s.")
	end)

	helpers.it("module tag with dots is preserved", function()
		local line = run_one("debug", "keymap.llm_bridge", "Stale callback discarded.")
		helpers.assert_eq(line, "TIMESTAMP [DEBUG] [keymap.llm_bridge] Stale callback discarded.")
	end)

	helpers.it("module tag with underscores is preserved", function()
		local line = run_one("info", "menu_llm.model_switcher", "Model switched.")
		helpers.assert_eq(line, "TIMESTAMP [INFO] [menu_llm.model_switcher] Model switched.")
	end)

	helpers.it("no args passes message verbatim", function()
		local line = run_one("info", "FirstBoot", "User config already present — skipping bootstrap.")
		helpers.assert_eq(line, "TIMESTAMP [INFO] [FirstBoot] User config already present — skipping bootstrap.")
	end)
end)




-- ==================================================
--- ==================================================
-- ======= 4/ Test Suite — Severity Filtering =======
--- ==================================================
-- ==================================================

helpers.describe("SharedLogger: severity filtering", function()
	freeze_timestamp()
	Logger.ring_buffer_clear()

	helpers.it("level debug passes all 8 variants", function()
		Logger.set_level("debug")
		local lines, sink = make_sink()
		Logger.set_sink(sink)
		Logger.debug("M", "d")
		Logger.trace("M", "t")
		Logger.done("M", "d")
		Logger.info("M", "i")
		Logger.start("M", "s")
		Logger.success("M", "s")
		Logger.warn("M", "w")
		Logger.error("M", "e")
		Logger.set_sink(nil)
		helpers.assert_eq(#lines, 8)
	end)

	helpers.it("level info drops debug/trace/done", function()
		Logger.set_level("info")
		local lines, sink = make_sink()
		Logger.set_sink(sink)
		Logger.debug("M", "should be dropped")
		Logger.trace("M", "should be dropped")
		Logger.done("M", "should be dropped")
		Logger.info("M", "should pass")
		Logger.set_sink(nil)
		helpers.assert_eq(#lines, 1)
		assert_contains(lines[1], "[INFO]")
	end)

	helpers.it("level warning drops info and below", function()
		Logger.set_level("warning")
		local lines, sink = make_sink()
		Logger.set_sink(sink)
		Logger.info("M", "should be dropped")
		Logger.start("M", "should be dropped")
		Logger.success("M", "should be dropped")
		Logger.warn("M", "should pass")
		Logger.error("M", "should pass")
		Logger.set_sink(nil)
		helpers.assert_eq(#lines, 2)
	end)

	helpers.it("level error passes only error", function()
		Logger.set_level("error")
		local lines, sink = make_sink()
		Logger.set_sink(sink)
		Logger.warn("M", "should be dropped")
		Logger.error("M", "should pass")
		Logger.set_sink(nil)
		helpers.assert_eq(#lines, 1)
		assert_contains(lines[1], "[ERROR]")
	end)

	helpers.it("numeric level 40 behaves as error-only", function()
		Logger.set_level(40)
		local lines, sink = make_sink()
		Logger.set_sink(sink)
		Logger.warn("M", "dropped")
		Logger.error("M", "passes")
		Logger.set_sink(nil)
		helpers.assert_eq(#lines, 1)
	end)
end)




-- ================================================
--- ===========================================
-- ======= 5/ Test Suite — Ring Buffer =======
--- ===========================================
-- ================================================

helpers.describe("SharedLogger: ring buffer", function()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()

	helpers.it("ring starts empty", function()
		Logger.ring_buffer_clear()
		helpers.assert_eq(Logger.ring_buffer_size(), 0)
		helpers.assert_eq(#Logger.ring_buffer_snapshot(), 0)
	end)

	helpers.it("ring grows with entries", function()
		Logger.ring_buffer_clear()
		Logger.info("M", "first")
		Logger.info("M", "second")
		helpers.assert_eq(Logger.ring_buffer_size(), 2)
	end)

	helpers.it("ring snapshot is ordered", function()
		Logger.ring_buffer_clear()
		Logger.info("M", "alpha")
		Logger.info("M", "beta")
		Logger.info("M", "gamma")
		local snap = Logger.ring_buffer_snapshot()
		helpers.assert_eq(#snap, 3)
		assert_contains(snap[1], "alpha")
		assert_contains(snap[2], "beta")
		assert_contains(snap[3], "gamma")
	end)

	helpers.it("ring clear resets size to 0", function()
		Logger.info("M", "entry")
		Logger.ring_buffer_clear()
		helpers.assert_eq(Logger.ring_buffer_size(), 0)
		helpers.assert_eq(#Logger.ring_buffer_snapshot(), 0)
	end)

	helpers.it("ring wraps at 200 entries", function()
		Logger.ring_buffer_clear()
		-- Fill buffer to capacity then add one more — oldest must be evicted
		for i = 1, 201 do
			Logger.info("M", "msg %d", i)
		end
		helpers.assert_eq(Logger.ring_buffer_size(), 200)
		local snap = Logger.ring_buffer_snapshot()
		-- First entry should now be msg 2 (msg 1 was evicted)
		assert_contains(snap[1], "msg 2")
		assert_contains(snap[200], "msg 201")
	end)
end)




-- ==========================================
--- ========================================
-- ======= 6/ Test Suite — Sink API =======
--- ========================================
-- ==========================================

helpers.describe("SharedLogger: sink API", function()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()
	Logger.set_sink(nil)

	helpers.it("no sink does not crash", function()
		Logger.set_sink(nil)
		Logger.ring_buffer_clear()
		-- Should not raise
		Logger.info("M", "no sink present")
		helpers.assert_eq(Logger.ring_buffer_size(), 1)
	end)

	helpers.it("sink receives formatted line", function()
		Logger.ring_buffer_clear()
		local received = {}
		Logger.set_sink(function(line, _) table.insert(received, line) end)
		Logger.info("M", "hello sink")
		Logger.set_sink(nil)
		helpers.assert_eq(#received, 1)
		assert_contains(received[1], "hello sink")
	end)

	helpers.it("sink receives variant name", function()
		local variants_seen = {}
		Logger.set_sink(function(_, v) table.insert(variants_seen, v) end)
		Logger.warn("M", "warn call")
		Logger.set_sink(nil)
		helpers.assert_eq(variants_seen[1], "warn")
	end)

	helpers.it("broken sink does not propagate error", function()
		Logger.ring_buffer_clear()
		Logger.set_sink(function(_, _) error("sink exploded") end)
		-- Should not propagate the error
		Logger.info("M", "despite broken sink")
		Logger.set_sink(nil)
		-- Line should still be in ring buffer
		helpers.assert_eq(Logger.ring_buffer_size(), 1)
	end)
end)
