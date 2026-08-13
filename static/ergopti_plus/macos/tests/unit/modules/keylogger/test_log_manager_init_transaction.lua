--- tests/unit/modules/keylogger/test_log_manager_init_transaction.lua

--- ==============================================================================
--- MODULE: Log-manager initialization transaction
--- DESCRIPTION:
--- Proves that a native dependency which raises after acquiring a resource cannot
--- leave `M.init()` published as complete. The failed attempt must release its
--- timer and database, make pre-init lifecycle helpers inert, and allow a full
--- retry which owns exactly one live timer. Runtime stop has the same exact-owner
--- contract: an explicit native refusal remains retained for a later retry, but
--- its callback is fenced before the database can be closed.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===============================================
-- ===============================================
-- ======= 1/ Transactional Initialization =======
-- ===============================================
-- ===============================================

helpers.describe("log_manager — initialization transaction", function()
	helpers.it("rolls back a post-publication throw and retries the full init (keylogger-log-init-transaction)", function()
		local slots = {
			"infra.logger",
			"adapters.file_system",
			"modules.keylogger.sqlite_writer",
			"modules.keylogger.aggregator",
			"modules.keylogger.rotation",
			"modules.keylogger.export",
			"keylogger.metrics",
			"modules.keylogger.log_manager",
		}
		local saved = {}
		for _, slot in ipairs(slots) do saved[slot] = package.loaded[slot] end

		local timer_created = 0
		local timer_active = 0
		local timer_stop_calls = 0
		local timer_stop_refusals = 1
		local timer_truthy_stop_refusals = 0
		local fail_start_creation = 1
		local start_without_activation_creation = nil
		local timer_handles = {}
		local sqlite_init_calls = 0
		local db_open_calls = 0
		local db_close_calls = 0
		local db_open = false
		local lm = nil

		local ok, err = xpcall(function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"] = logger
			package.loaded["adapters.file_system"] = {
				read_with_status = function()
					return [[{"device_id":"device-stable","name":"Test Mac","os":"darwin","host_signature":"fallback:unknown","created_at":"2026-08-13 00:00:00.000"}]], "ok"
				end,
				write = function() return true end,
			}

			local db = {}
			function db:nrows(query)
				local yielded = false
				return function()
					if not yielded and query:find("aggregate_cache_revision", 1, true) then
						yielded = true
						return { value = "1" }
					end
					return nil
				end
			end

			package.loaded["modules.keylogger.sqlite_writer"] = {
				init = function() sqlite_init_calls = sqlite_init_calls + 1 end,
				open_db = function()
					db_open_calls = db_open_calls + 1
					db_open = true
					return true
				end,
				get_db = function() return db_open and db or nil end,
				close_db = function()
					db_close_calls = db_close_calls + 1
					db_open = false
				end,
			}
			package.loaded["modules.keylogger.aggregator"] = {
				init = function() end,
				set_ngram_ctx = function() end,
			}
			local rotation_initialized = false
			package.loaded["modules.keylogger.rotation"] = {
				is_initialized = function() return rotation_initialized end,
				init = function() rotation_initialized = true end,
				read_new_entries = function() return {}, 0, "eof" end,
			}
			package.loaded["modules.keylogger.export"] = {
				init = function() end,
				sync_foreign_data_sql = function() return {} end,
			}
			package.loaded["keylogger.metrics"] = {
				compute_wpm_from_events = function() return 0 end,
			}

			local entries = { "device-stable" }
			local hs_overrides = {
				fs = {
					attributes = function() return { mode = "file" } end,
					dir = function()
						local state = { index = 0 }
						return function(iter_state)
							iter_state.index = iter_state.index + 1
							return entries[iter_state.index]
						end, state
					end,
				},
				execute = function() return "" end,
				timer = {
					absoluteTime = function() return 0 end,
					secondsSinceEpoch = function() return 0 end,
					doAfter = function() error("unexpected deferred timer") end,
					new = function(_, callback)
						timer_created = timer_created + 1
						local creation = timer_created
						local handle = { running = false, callback = callback }
						function handle:start()
							if creation == start_without_activation_creation then return self end
							if not self.running then
								self.running = true
								timer_active = timer_active + 1
							end
							if creation == fail_start_creation then
								error("timer start exploded after acquisition")
							end
							return self
						end
						function handle:stop()
							timer_stop_calls = timer_stop_calls + 1
							if timer_stop_refusals > 0 then
								timer_stop_refusals = timer_stop_refusals - 1
								return false
							end
							if timer_truthy_stop_refusals > 0 then
								timer_truthy_stop_refusals = timer_truthy_stop_refusals - 1
								return self
							end
							if self.running then
								self.running = false
								timer_active = timer_active - 1
							end
							return self
						end
						function handle:fire()
							return self.callback()
						end
						timer_handles[#timer_handles + 1] = handle
						return handle
					end,
				},
			}

			lm = helpers.load_with_stubs("modules.keylogger.log_manager", hs_overrides)
			local state = { LOG_DIR = "/tmp/ergopti-log-manager-transaction" }
			local first_call_ok, first_result = pcall(lm.init, state)
			helpers.assert_true(first_call_ok,
				"a post-publication dependency throw must be contained by M.init()")
			helpers.assert_eq(false, first_result,
				"a rolled-back initialization must report failure")
			helpers.assert_eq(1, timer_active,
				"a refused stop must retain an inert cleanup obligation")
			helpers.assert_eq(1, timer_stop_calls,
				"rollback must attempt the exact partially acquired timer")
			helpers.assert_eq(false, db_open,
				"rollback must close the partially acquired database")
			helpers.assert_eq(1, db_close_calls,
				"the failed attempt must close its database exactly once")

			local ingest_calls = 0
			local real_ingest_once = lm.ingest_once
			lm.ingest_once = function(...)
				ingest_calls = ingest_calls + 1
				return real_ingest_once(...)
			end
			timer_handles[1]:fire()
			helpers.assert_eq(ingest_calls, 0,
				"a retained callback from failed initialization must be publication-inert")

			helpers.assert_eq(false, lm.ensure_ingest_running(),
				"failed initialization must make the re-arm contract fail closed")
			helpers.assert_eq(1, timer_created,
				"failed initialization must clear published state so re-arm stays inert")

			helpers.assert_eq(true, lm.init(state),
				"a later call must retry and commit the complete initialization")
			helpers.assert_eq(2, timer_stop_calls,
				"retry must settle the exact timer whose first stop was refused")
			helpers.assert_eq(2, sqlite_init_calls,
				"retry must execute the full dependency initialization, not the idempotent path")
			helpers.assert_eq(2, db_open_calls,
				"retry must reacquire the database")
			helpers.assert_eq(2, timer_created,
				"retry must create one replacement timer")
			helpers.assert_eq(1, timer_active,
				"only the successfully committed timer may remain active")

			helpers.assert_eq(true, lm.ensure_ingest_running(),
				"a committed timer must satisfy the exact re-arm contract")
			helpers.assert_eq(2, timer_created,
				"normal ensure_ingest_running() must remain idempotent after commit")
			helpers.assert_eq(1, timer_active,
				"normal committed state must retain exactly one timer")
			local committed_ingest_calls = ingest_calls
			timer_handles[2]:fire()
			helpers.assert_eq(ingest_calls, committed_ingest_calls + 1,
				"the callback of the committed timer must remain live")

			timer_stop_refusals = 1
			helpers.assert_eq(false, lm.stop(),
				"runtime stop must report an explicit native timer refusal")
			helpers.assert_eq(1, timer_active,
				"a refused runtime stop must retain the exact live timer")
			helpers.assert_eq(3, timer_stop_calls,
				"runtime stop must attempt the committed timer exactly once")
			helpers.assert_eq(2, timer_created,
				"a refused stop must not publish or allocate a replacement timer")
			helpers.assert_eq(false, db_open,
				"runtime stop may close the database only after fencing the retained callback")
			local stopped_ingest_calls = ingest_calls
			timer_handles[2]:fire()
			helpers.assert_eq(ingest_calls, stopped_ingest_calls,
				"a retained callback must be inert after runtime stop fences its owner")

			helpers.assert_eq(true, lm.stop(),
				"a later runtime stop must retry and settle the retained timer")
			helpers.assert_eq(0, timer_active,
				"the successful retry must leave no live ingest timer")
			helpers.assert_eq(4, timer_stop_calls,
				"runtime cleanup retry must target the same timer handle")

			fail_start_creation = 3
			timer_stop_refusals = 1
			helpers.assert_eq(false, lm.ensure_ingest_running(),
				"a re-arm whose start raises after activation must not commit")
			helpers.assert_eq(1, timer_active,
				"the partially activated timer remains an exact cleanup obligation")
			helpers.assert_eq(false, lm.ensure_ingest_running(),
				"a retained uncommitted handle must never masquerade as running")
			helpers.assert_eq(3, timer_created,
				"cleanup debt must block construction of a successor timer")
			local uncommitted_ingest_calls = ingest_calls
			timer_handles[3]:fire()
			helpers.assert_eq(ingest_calls, uncommitted_ingest_calls,
				"an activate-then-throw candidate must never invoke ingest")
			helpers.assert_eq(false, lm.stop(),
				"the first exact cleanup refusal must remain visible")
			helpers.assert_eq(true, lm.stop(),
				"the later cleanup retry must settle the same partial timer")
			helpers.assert_eq(0, timer_active)

			fail_start_creation = -1
			start_without_activation_creation = 4
			helpers.assert_eq(false, lm.ensure_ingest_running(),
				"a chainable start result is not a commit while native state stays stopped")
			helpers.assert_eq(4, timer_created)
			helpers.assert_eq(0, timer_active,
				"the false commit fixture must remain observably inactive")
			helpers.assert_eq(false, lm.ensure_ingest_running(),
				"the exact rejected candidate must block a sibling until cleanup")
			helpers.assert_eq(4, timer_created)
			helpers.assert_eq(true, lm.stop(),
				"an observably stopped rejected candidate must settle on exact teardown")

			start_without_activation_creation = nil
			helpers.assert_eq(true, lm.ensure_ingest_running())
			helpers.assert_eq(5, timer_created)
			timer_truthy_stop_refusals = 1
			helpers.assert_eq(false, lm.stop(),
				"a chainable stop result must not hide a still-running native timer")
			helpers.assert_eq(1, timer_active,
				"the exact still-running timer must remain retained for retry")
			local truthy_stop_ingest_calls = ingest_calls
			timer_handles[5]:fire()
			helpers.assert_eq(ingest_calls, truthy_stop_ingest_calls,
				"logical fencing must precede a truthy-but-ineffective native stop")
			helpers.assert_eq(false, lm.ensure_ingest_running(),
				"cleanup debt must not publish a sibling recurring timer")
			helpers.assert_eq(5, timer_created)
			helpers.assert_eq(true, lm.stop(),
				"the next stop must retry and settle the exact native timer")
			helpers.assert_eq(0, timer_active)
		end, debug.traceback)

		if lm then pcall(lm.stop) end
		for _, slot in ipairs(slots) do package.loaded[slot] = saved[slot] end
		if not ok then error(err, 0) end
	end)
end)
