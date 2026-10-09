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
local fixture = require("tests.support.kc_bridge_fixture")
helpers.describe("kc_bridge — _file_offset advances while the keylogger is disabled (F-MED-26)", function()

	helpers.it("drain_log (via the watcher callback) advances the offset with LogManager nil", function()
		fixture.with_context(function(ctx)
			local kc = ctx.load()

			-- Feature disabled: init() is always called with log_manager=nil at
			-- keylogger module load, mirroring modules/keylogger/init.lua line 287.
			kc.init({ ok = true }, nil, {}, {}, function() return true end)
			local offset_before = kc.get_stats().offset

			ctx.append("a")
			ctx.append("b")
			ctx.append("U:a")

			helpers.assert_true(type(ctx.watcher_callback) == "function",
				"hs.pathwatcher.new must have captured a callback")
			ctx.watcher_callback()

			local offset_after = kc.get_stats().offset
			helpers.assert_true(offset_after > offset_before,
				"_file_offset must advance past newly-written lines even while "
				.. "_log_manager is nil (feature disabled) — got before=" .. tostring(offset_before)
				.. " after=" .. tostring(offset_after))
		end)
	end)

	helpers.it("no backlog burst-replay: enabling later logs only lines written AFTER enable", function()
		fixture.with_context(function(ctx)
			local kc = ctx.load()
			kc.init({ ok = true }, nil, {}, {}, function() return true end)

			-- Backlog accumulates while the feature is off.
			ctx.append("a")
			ctx.append("b")
			ctx.append("c")
			ctx.watcher_callback() -- drains (and discards) the backlog — offset advances

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
			ctx.append("c")

			ctx.watcher_callback()

			helpers.assert_eq(#logged, 1,
				"only the single line written after enabling must be logged — "
				.. "the pre-existing 'a'/'b'/'c' backlog must NOT be replayed, got "
				.. tostring(#logged) .. " logged event(s)")
		end)
	end)

	helpers.it("pending_down hold-duration tracking stays consistent across the disabled→enabled transition", function()
		fixture.with_context(function(ctx)
			local kc = ctx.load()
			kc.init({ ok = true }, nil, {}, {}, function() return true end)

			-- Press while disabled, release while disabled too — both consumed
			-- without a log call, and the pending_down bookkeeping must not leak
			-- a stale entry into the enabled period.
			ctx.append("a")
			ctx.append("U:a")
			ctx.watcher_callback()

			local logged = {}
			kc.set_log_manager({
				log_karabiner_press   = function(kc_num) table.insert(logged, { kc = kc_num, type = "press" }) end,
				log_karabiner_release = function(kc_num) table.insert(logged, { kc = kc_num, type = "release" }) end,
			})

			-- A fresh press/release pair after enabling must produce exactly one
			-- press + one release — no leftover state from the disabled period.
			ctx.append("b")
			ctx.append("U:b")
			ctx.watcher_callback()

			helpers.assert_eq(#logged, 2,
				"exactly the post-enable press+release pair must be logged")
			helpers.assert_eq(logged[1].type, "press")
			helpers.assert_eq(logged[2].type, "release")
		end)
	end)

	helpers.it("keeps draining without persisting after feature OFF when secure filtering is disabled", function()
		fixture.with_context(function(ctx)
			local feature_enabled = true
			local kc = ctx.load()
			package.loaded["modules.keylogger"] = {
				context_allows_logging = function() return true end,
			}
			helpers.assert_eq(kc.init({ ok = true }, nil, {}, {},
				function() return feature_enabled end), true)

			local logged = {}
			kc.set_log_manager({
				log_karabiner_press = function(kc_num)
					logged[#logged + 1] = kc_num
				end,
			})
			ctx.append("a")
			ctx.watcher_callback()
			helpers.assert_eq(#logged, 1,
				"the positive control must persist while the complete gate allows it")

			feature_enabled = false
			ctx.append("b")
			local before = kc.get_stats().offset
			ctx.watcher_callback()
			helpers.assert_eq(#logged, 1,
				"the retained always-on drain must not bypass feature OFF")
			helpers.assert_true(kc.get_stats().offset > before,
				"denied rows must still advance the ledger cursor instead of replaying later")
		end)
	end)

	helpers.it("resynchronises a cold-start cursor before an already-active bridge can persist", function()
		fixture.with_context(function(ctx)
			ctx.append("a")

			local saved_open = io.open
			local fail_initial_read = true
			local ledger_path = ctx.root .. "/metrics/karabiner_kc.log"
			io.open = function(path, mode)
				if fail_initial_read and path == ledger_path and mode == "r" then
					fail_initial_read = false
					return nil, "transient read refusal"
				end
				return saved_open(path, mode)
			end

			local ok, err = pcall(function()
				local kc = ctx.load()
				helpers.assert_eq(kc.init({ active_app_name = "TextEdit" }, nil, {}, {},
					function() return true end), true)

				local logged = {}
				kc.set_log_manager({
					log_karabiner_press = function(kc_num)
						logged[#logged + 1] = kc_num
					end,
				})
				helpers.assert_eq(kc.start(), true,
					"activation must retry the untrusted cold-start EOF even while watchers are active")
				ctx.append("b")
				ctx.watcher_callback()
				helpers.assert_eq(#logged, 1,
					"only the post-activation row may persist; the pre-session row must be discarded")
				helpers.assert_eq(logged[1], 1,
					"the one persisted row must be the post-activation physical key")
			end)
			io.open = saved_open
			helpers.assert_true(ok, "cold-start EOF refusal scenario must complete: " .. tostring(err))
		end)
	end)

	helpers.it("HS-054 preserves the cursor when the drain EOF probe fails", function()
		fixture.with_context(function(ctx)
			local kc = ctx.load()
			helpers.assert_eq(kc.init({ active_app_name = "TextEdit" }, nil, {}, {},
				function() return true end), true)

			local logged = {}
			kc.set_log_manager({
				log_karabiner_press = function(kc_num)
					logged[#logged + 1] = kc_num
				end,
			})
			ctx.append("a")
			ctx.watcher_callback()
			helpers.assert_eq(#logged, 1, "the positive control must drain the first row")
			local offset_before = kc.get_stats().offset
			helpers.assert_true(offset_before > 0, "the EOF failure must occur after cursor progress")

			ctx.append("b")
			local saved_open = io.open
			local ledger_path = ctx.root .. "/metrics/karabiner_kc.log"
			local injected = false
			io.open = function(path, mode)
				local handle, open_error = saved_open(path, mode)
				if path ~= ledger_path or mode ~= "r" or injected or not handle then
					return handle, open_error
				end
				injected = true
				return {
					seek = function(_, whence, offset)
						if whence == "end" then return nil, "injected EOF seek failure" end
						return handle:seek(whence, offset)
					end,
					lines = function() return handle:lines() end,
					close = function() return handle:close() end,
				}
			end

			local call_ok, call_error = xpcall(ctx.watcher_callback, debug.traceback)
			io.open = saved_open
			helpers.assert_true(call_ok,
				"the EOF error path must not escape the watcher: " .. tostring(call_error))
			helpers.assert_true(injected, "the test must inject the EOF seek refusal")
			helpers.assert_eq(#logged, 1,
				"a failed EOF probe must process neither the old row nor the new row")
			helpers.assert_eq(kc.get_stats().offset, offset_before,
				"a failed EOF probe must preserve the last trusted byte offset")
		end)
	end)

end)
