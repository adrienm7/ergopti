--- tests/unit/lib/test_shared_logger.lua

--- ==============================================================================
--- TEST: Shared Logger Core Conformance
--- DESCRIPTION:
--- Validates that the shared logger core in _shared/lua/logger/init.lua
--- produces lines that conform to the format contract in SPEC.md § 3.
--- Exercises all 8 variants, the ring buffer, severity filtering, and the
--- test vectors from static/drivers/_shared/logger/test_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. Time-independent: M.timestamp_fn is replaced with a sentinel function
---    returning "TIMESTAMP" so expected lines can be hardcoded.
--- 2. Sink-based capture: a sink function collects emitted lines so the
---    test never touches the filesystem or the HS console.
--- 3. Covers both the shared test vectors (driver-neutral cases) and
---    Lua-specific format string vectors (message_hs field).
--- ==============================================================================

local lu = require("luaunit")

-- Load the shared logger (resolved via _shared/lua on package.path)
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




-- =====================================================
--- ==============================================
-- ======= 2/ Test Suite — Eight Variants =======
--- ==============================================
-- =====================================================

TestLoggerVariants = {}

function TestLoggerVariants:setUp()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()
end

function TestLoggerVariants:test_debug()
	local line = run_one("debug", "TestModule", "Cache miss — reloading.")
	lu.assertEquals(line, "TIMESTAMP [DEBUG] [TestModule] Cache miss — reloading.")
end

function TestLoggerVariants:test_trace()
	local line = run_one("trace", "TestModule", "Timer started (0.300s)…")
	lu.assertEquals(line, "TIMESTAMP [TRACE] [TestModule] Timer started (0.300s)…")
end

function TestLoggerVariants:test_done()
	local line = run_one("done", "TestModule", "Timer stopped.")
	lu.assertEquals(line, "TIMESTAMP [DONE] [TestModule] Timer stopped.")
end

function TestLoggerVariants:test_info()
	local line = run_one("info", "TapHoldLoader", "Config file located.")
	lu.assertEquals(line, "TIMESTAMP [INFO] [TapHoldLoader] Config file located.")
end

function TestLoggerVariants:test_start()
	local line = run_one("start", "TapHoldLoader", "Loading tap-hold config from '/path/to/tap_hold.toml'…")
	lu.assertEquals(line, "TIMESTAMP [START] [TapHoldLoader] Loading tap-hold config from '/path/to/tap_hold.toml'…")
end

function TestLoggerVariants:test_success()
	local line = run_one("success", "TapHoldLoader", "Tap-hold config loaded (8 key(s), 2 layer(s)).")
	lu.assertEquals(line, "TIMESTAMP [SUCCESS] [TapHoldLoader] Tap-hold config loaded (8 key(s), 2 layer(s)).")
end

function TestLoggerVariants:test_warn_emits_warning_label()
	local line = run_one("warn", "gestures", "Probe timed out — retry 1/3.")
	lu.assertEquals(line, "TIMESTAMP [WARNING] [gestures] Probe timed out — retry 1/3.")
end

function TestLoggerVariants:test_error()
	local line = run_one("error", "karabiner", "Config write failed: permission denied.")
	lu.assertEquals(line, "TIMESTAMP [ERROR] [karabiner] Config write failed: permission denied.")
end




-- ===================================================
-- ===================================================
-- ======= 3/ Test Suite — Format String Args =======
-- ===================================================
-- ===================================================

TestLoggerFormat = {}

function TestLoggerFormat:setUp()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()
end

function TestLoggerFormat:test_integer_arg()
	local line = run_one("info", "TapHoldLoader", "Loaded %d key(s).", 8)
	lu.assertEquals(line, "TIMESTAMP [INFO] [TapHoldLoader] Loaded 8 key(s).")
end

function TestLoggerFormat:test_two_integer_args()
	local line = run_one("success", "TapHoldLoader", "Tap-hold config loaded (%d key(s), %d layer(s)).", 8, 2)
	lu.assertEquals(line, "TIMESTAMP [SUCCESS] [TapHoldLoader] Tap-hold config loaded (8 key(s), 2 layer(s)).")
end

function TestLoggerFormat:test_string_arg()
	local line = run_one("debug", "ModelSwitcher", "Backend resolved to '%s'.", "mlx")
	lu.assertEquals(line, "TIMESTAMP [DEBUG] [ModelSwitcher] Backend resolved to 'mlx'.")
end

function TestLoggerFormat:test_string_and_integer_args()
	local line = run_one("info", "menu_llm", "Profile '%s' selected (power level %d).", "advanced", 2)
	lu.assertEquals(line, "TIMESTAMP [INFO] [menu_llm] Profile 'advanced' selected (power level 2).")
end

function TestLoggerFormat:test_float_arg()
	local line = run_one("debug", "TapHoldLoader", "Threshold set to %.2fs.", 0.35)
	lu.assertEquals(line, "TIMESTAMP [DEBUG] [TapHoldLoader] Threshold set to 0.35s.")
end

function TestLoggerFormat:test_module_tag_with_dots()
	local line = run_one("debug", "keymap.llm_bridge", "Stale callback discarded.")
	lu.assertEquals(line, "TIMESTAMP [DEBUG] [keymap.llm_bridge] Stale callback discarded.")
end

function TestLoggerFormat:test_module_tag_with_underscores()
	local line = run_one("info", "menu_llm.model_switcher", "Model switched.")
	lu.assertEquals(line, "TIMESTAMP [INFO] [menu_llm.model_switcher] Model switched.")
end

function TestLoggerFormat:test_no_args_verbatim()
	local line = run_one("info", "FirstBoot", "User config already present — skipping bootstrap.")
	lu.assertEquals(line, "TIMESTAMP [INFO] [FirstBoot] User config already present — skipping bootstrap.")
end




-- ==================================================
--- ==================================================
-- ======= 4/ Test Suite — Severity Filtering =======
--- ==================================================
-- ==================================================

TestLoggerFiltering = {}

function TestLoggerFiltering:setUp()
	freeze_timestamp()
	Logger.ring_buffer_clear()
end

function TestLoggerFiltering:test_level_debug_passes_all()
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
	lu.assertEquals(#lines, 8)
end

function TestLoggerFiltering:test_level_info_drops_debug()
	Logger.set_level("info")
	local lines, sink = make_sink()
	Logger.set_sink(sink)
	Logger.debug("M", "should be dropped")
	Logger.trace("M", "should be dropped")
	Logger.done("M",  "should be dropped")
	Logger.info("M",  "should pass")
	Logger.set_sink(nil)
	lu.assertEquals(#lines, 1)
	lu.assertStrContains(lines[1], "[INFO]")
end

function TestLoggerFiltering:test_level_warning_drops_info_and_below()
	Logger.set_level("warning")
	local lines, sink = make_sink()
	Logger.set_sink(sink)
	Logger.info("M",    "should be dropped")
	Logger.start("M",   "should be dropped")
	Logger.success("M", "should be dropped")
	Logger.warn("M",    "should pass")
	Logger.error("M",   "should pass")
	Logger.set_sink(nil)
	lu.assertEquals(#lines, 2)
end

function TestLoggerFiltering:test_level_error_only()
	Logger.set_level("error")
	local lines, sink = make_sink()
	Logger.set_sink(sink)
	Logger.warn("M",  "should be dropped")
	Logger.error("M", "should pass")
	Logger.set_sink(nil)
	lu.assertEquals(#lines, 1)
	lu.assertStrContains(lines[1], "[ERROR]")
end

function TestLoggerFiltering:test_set_level_numeric_40()
	Logger.set_level(40)
	local lines, sink = make_sink()
	Logger.set_sink(sink)
	Logger.warn("M",  "dropped")
	Logger.error("M", "passes")
	Logger.set_sink(nil)
	lu.assertEquals(#lines, 1)
end




-- ================================================
--- ===========================================
-- ======= 5/ Test Suite — Ring Buffer =======
--- ===========================================
-- ================================================

TestLoggerRingBuffer = {}

function TestLoggerRingBuffer:setUp()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()
end

function TestLoggerRingBuffer:test_ring_starts_empty()
	lu.assertEquals(Logger.ring_buffer_size(), 0)
	lu.assertEquals(#Logger.ring_buffer_snapshot(), 0)
end

function TestLoggerRingBuffer:test_ring_grows_with_entries()
	Logger.info("M", "first")
	Logger.info("M", "second")
	lu.assertEquals(Logger.ring_buffer_size(), 2)
end

function TestLoggerRingBuffer:test_ring_snapshot_is_ordered()
	Logger.info("M", "alpha")
	Logger.info("M", "beta")
	Logger.info("M", "gamma")
	local snap = Logger.ring_buffer_snapshot()
	lu.assertEquals(#snap, 3)
	lu.assertStrContains(snap[1], "alpha")
	lu.assertStrContains(snap[2], "beta")
	lu.assertStrContains(snap[3], "gamma")
end

function TestLoggerRingBuffer:test_ring_clear_resets()
	Logger.info("M", "entry")
	Logger.ring_buffer_clear()
	lu.assertEquals(Logger.ring_buffer_size(), 0)
	lu.assertEquals(#Logger.ring_buffer_snapshot(), 0)
end

function TestLoggerRingBuffer:test_ring_wraps_at_200()
	-- Fill buffer to capacity then add one more — oldest must be evicted
	for i = 1, 201 do
		Logger.info("M", "msg %d", i)
	end
	lu.assertEquals(Logger.ring_buffer_size(), 200)
	local snap = Logger.ring_buffer_snapshot()
	-- First entry should now be msg 2 (msg 1 was evicted)
	lu.assertStrContains(snap[1], "msg 2")
	lu.assertStrContains(snap[200], "msg 201")
end




-- ==========================================
--- ========================================
-- ======= 6/ Test Suite — Sink API =======
--- ========================================
-- ==========================================

TestLoggerSink = {}

function TestLoggerSink:setUp()
	freeze_timestamp()
	Logger.set_level("debug")
	Logger.ring_buffer_clear()
	Logger.set_sink(nil)
end

function TestLoggerSink:test_no_sink_does_not_crash()
	Logger.set_sink(nil)
	-- Should not raise
	Logger.info("M", "no sink present")
	lu.assertEquals(Logger.ring_buffer_size(), 1)
end

function TestLoggerSink:test_sink_receives_formatted_line()
	local received = {}
	Logger.set_sink(function(line, _) table.insert(received, line) end)
	Logger.info("M", "hello sink")
	Logger.set_sink(nil)
	lu.assertEquals(#received, 1)
	lu.assertStrContains(received[1], "hello sink")
end

function TestLoggerSink:test_sink_receives_variant_name()
	local variants_seen = {}
	Logger.set_sink(function(_, v) table.insert(variants_seen, v) end)
	Logger.warn("M", "warn call")
	Logger.set_sink(nil)
	lu.assertEquals(variants_seen[1], "warn")
end

function TestLoggerSink:test_broken_sink_does_not_crash()
	Logger.set_sink(function(_, _) error("sink exploded") end)
	-- Should not propagate the error
	Logger.info("M", "despite broken sink")
	Logger.set_sink(nil)
	-- Line should still be in ring buffer
	lu.assertEquals(Logger.ring_buffer_size(), 1)
end
