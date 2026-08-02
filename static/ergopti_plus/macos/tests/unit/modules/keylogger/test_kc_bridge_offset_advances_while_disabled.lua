--- tests/unit/modules/keylogger/test_kc_bridge_offset_advances_while_disabled.lua

--- ==============================================================================
--- MODULE: KcBridge Offset Bookkeeping While Keylogger Disabled (F-MED-26)
--- DESCRIPTION:
--- KcBridge.init() arms the path watcher and poll timer at module load time
--- regardless of whether the keylogger feature is enabled, because Karabiner
--- writes physical-keycode lines to KC_LOG_PATH unconditionally. Before this
--- fix, drain_log()'s very first line was `if not _log_manager then return end`
--- — so while the feature was off (no LogManager injected yet), EVERY
--- drain_log() call (from the watcher callback or the poll timer) returned
--- immediately without ever advancing _file_offset. Karabiner kept appending
--- lines the whole time the feature was off; the next drain after the feature
--- was finally enabled replayed the entire backlog in one burst, crediting
--- every one of those physical keystrokes with the CURRENT timestamp instead
--- of the time they were actually pressed.
---
--- FEATURES & RATIONALE:
--- 1. Offset bookkeeping survives the disabled feature: drain_log() must
---    consume (and advance past) lines written while _log_manager is nil.
--- 2. No backlog replay on enable: once LogManager is injected, drain_log()
---    must not re-process lines that were already consumed while disabled.
--- 3. Enabling the feature later logs only genuinely NEW lines, not the
---    pre-existing backlog.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Stub Setup ==============
-- =====================================
-- =====================================

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

--- Builds a fresh temp directory path for this test run's KC_LOG_PATH so
--- concurrent test runs (or repeated `--only` reruns) never collide on the
--- same file. tests/stubs writes real files here — this test needs genuine
--- file I/O (not a no-op stub) to prove the offset actually advances on disk.
--- @return string Absolute path to a fresh scratch directory (no trailing slash).
local function fresh_tmp_dir()
	local base = os.tmpname()
	os.remove(base) -- os.tmpname() creates the file; we want a directory name only
	os.execute('mkdir "' .. base .. '_kcdir" 2>nul')
	return base .. "_kcdir"
end

local tmp_dir = fresh_tmp_dir()

--- Captures the callback passed to hs.pathwatcher.new so the test can invoke
--- drain_log() directly (it is a private local, unreachable any other way)
--- exactly the way a real filesystem event would.
local captured_watcher_cb = nil

local hs_overrides = {
	keycodes = {
		map = {
			cmd = 55, rightcmd = 54, shift = 56, rightshift = 60,
			alt = 58, rightalt = 61, ctrl = 59, rightctrl = 62,
			a = 0, b = 1, c = 8,
		},
	},
	pathwatcher = {
		new = function(_path, cb)
			captured_watcher_cb = cb
			return { start = function() end, stop = function() end }
		end,
	},
	timer = {
		new = function(_interval, _cb) return { start = function() end, stop = function() end } end,
		absoluteTime = function() return 0 end,
	},
}

--- Loads a fresh modules.keylogger.kc_bridge with KC_LOG_PATH resolved into
--- tmp_dir. tests.helpers.load_with_stubs() wipes every cached "ui.menu.*"
--- module (including ui.menu.menu_paths) as part of its own reset, so a
--- ui.menu.menu_paths stub installed BEFORE calling it is destroyed before
--- kc_bridge.lua's module-level `require("ui.menu.menu_paths")` ever runs.
--- Re-install the stub AFTER load_with_stubs's hs/package reset but BEFORE
--- the kc_bridge require that reads KC_LOG_PATH.
--- @return table The freshly loaded kc_bridge module.
local function load_kc_bridge_with_tmp_path()
	-- Piggyback on load_with_stubs for the hs stub reset, targeting a throwaway
	-- module so its "ui.menu.*" wipe runs, then reinstall our stub and require
	-- the real target ourselves.
	helpers.load_with_stubs("infra.logger", hs_overrides)
	package.loaded["infra.config_paths"] = {
		get_config_dir = function() return tmp_dir end,
	}
	package.loaded["modules.keylogger.kc_bridge"] = nil
	return require("modules.keylogger.kc_bridge")
end

--- Appends a raw line to the KC log file that KcBridge is watching, exactly
--- as the Karabiner shell_command action would.
--- @param line string The key_code (or "U:key_code" release) line to append.
local function append_ke_line(line)
	local path = tmp_dir .. "/metrics/karabiner_kc.log"
	local fh = io.open(path, "a")
	helpers.assert_true(fh ~= nil, "test setup: cannot open KC log at " .. path)
	fh:write(line .. "\n")
	fh:close()
end

--- Ensures the metrics directory exists before KcBridge.init() touches the log.
local function ensure_metrics_dir()
	os.execute('mkdir "' .. tmp_dir .. '/metrics" 2>nul')
end




-- ======================================================================
-- ======================================================================
-- ======= 2/ Offset Advances While Disabled (F-MED-26) ================
-- ======================================================================
-- ======================================================================

helpers.describe("kc_bridge — _file_offset advances while the keylogger is disabled (F-MED-26)", function()

	helpers.it("drain_log (via the watcher callback) advances the offset with LogManager nil", function()
		ensure_metrics_dir()
		local kc = load_kc_bridge_with_tmp_path()

		-- Feature disabled: init() is always called with log_manager=nil at
		-- keylogger module load, mirroring modules/keylogger/init.lua line 287.
		kc.init({ ok = true }, nil, {}, {})
		local offset_before = kc.get_stats().offset

		append_ke_line("a")
		append_ke_line("b")
		append_ke_line("U:a")

		helpers.assert_true(type(captured_watcher_cb) == "function",
			"hs.pathwatcher.new must have captured a callback")
		captured_watcher_cb()

		local offset_after = kc.get_stats().offset
		helpers.assert_true(offset_after > offset_before,
			"_file_offset must advance past newly-written lines even while "
			.. "_log_manager is nil (feature disabled) — got before=" .. tostring(offset_before)
			.. " after=" .. tostring(offset_after))
	end)

	helpers.it("no backlog burst-replay: enabling later logs only lines written AFTER enable", function()
		ensure_metrics_dir()
		local kc = load_kc_bridge_with_tmp_path()
		kc.init({ ok = true }, nil, {}, {})

		-- Backlog accumulates while the feature is off.
		append_ke_line("a")
		append_ke_line("b")
		append_ke_line("c")
		captured_watcher_cb() -- drains (and discards) the backlog — offset advances

		-- Now the feature is enabled: LogManager is injected.
		local logged = {}
		local fake_log_manager = {
			log_karabiner_press = function(kc_num, app_name)
				table.insert(logged, { kc = kc_num, app = app_name })
			end,
			log_karabiner_release = function(kc_num, app_name, hold_ms)
				table.insert(logged, { kc = kc_num, app = app_name, hold_ms = hold_ms })
			end,
		}
		kc.set_log_manager(fake_log_manager)

		-- Only NEW lines written after enable must be forwarded.
		append_ke_line("c")

		captured_watcher_cb()

		helpers.assert_eq(#logged, 1,
			"only the single line written after enabling must be logged — "
			.. "the pre-existing 'a'/'b'/'c' backlog must NOT be replayed, got "
			.. tostring(#logged) .. " logged event(s)")
	end)

	helpers.it("pending_down hold-duration tracking stays consistent across the disabled→enabled transition", function()
		ensure_metrics_dir()
		local kc = load_kc_bridge_with_tmp_path()
		kc.init({ ok = true }, nil, {}, {})

		-- Press while disabled, release while disabled too — both consumed
		-- without a log call, and the pending_down bookkeeping must not leak
		-- a stale entry into the enabled period.
		append_ke_line("a")
		append_ke_line("U:a")
		captured_watcher_cb()

		local logged = {}
		kc.set_log_manager({
			log_karabiner_press   = function(kc_num) table.insert(logged, { kc = kc_num, type = "press" }) end,
			log_karabiner_release = function(kc_num) table.insert(logged, { kc = kc_num, type = "release" }) end,
		})

		-- A fresh press/release pair after enabling must produce exactly one
		-- press + one release — no leftover state from the disabled period.
		append_ke_line("b")
		append_ke_line("U:b")
		captured_watcher_cb()

		helpers.assert_eq(#logged, 2,
			"exactly the post-enable press+release pair must be logged")
		helpers.assert_eq(logged[1].type, "press")
		helpers.assert_eq(logged[2].type, "release")
	end)

end)
