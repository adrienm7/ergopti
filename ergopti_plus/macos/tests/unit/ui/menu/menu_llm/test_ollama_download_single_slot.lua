--- tests/unit/ui/menu/menu_llm/test_ollama_download_single_slot.lua

--- =============================================================================
--- MODULE: Ollama Download Exact-Owner Regression
--- DESCRIPTION:
--- Proves that the single pull slot retains its exact native task until the
--- completion callback settles cancellation, and that every rejected or failed
--- request receives one terminal callback without publishing stale model state.
--- =============================================================================

local helpers = require("tests.helpers")

local with_fixture = require("tests.support.ollama_pull_fixture").with_fixture

local function start_pull(fixture, target)
	local terminal = { success = 0, cancel = 0, reasons = {} }
	local accepted = fixture.manager.pull_model(target or "model-A", target or "model-A",
		function() terminal.success = terminal.success + 1; return true end,
		function(reason)
			terminal.cancel = terminal.cancel + 1
			terminal.reasons[#terminal.reasons + 1] = reason
			return true
		end,
		{ is_current = function() return true end })
	return accepted, terminal
end

local function assert_cancel_refusal(mode)
	with_fixture({ terminate_mode = mode }, function(f)
		local accepted, terminal = start_pull(f)
		helpers.assert_eq(accepted, true)
		local owner = f.active_tasks.ollama_pull
		helpers.assert_eq(f.progress.on_cancel(), false)
		helpers.assert_true(f.active_tasks.ollama_pull == owner)
		helpers.assert_eq(terminal.cancel, 1)
		helpers.assert_eq(terminal.success, 0)

		f.set_terminate_mode("self")
		helpers.assert_eq(f.progress.on_cancel(), true)
		helpers.assert_true(f.active_tasks.ollama_pull == owner)
		owner.on_done(0)
		helpers.assert_nil(f.active_tasks.ollama_pull)
		helpers.assert_eq(terminal.cancel, 1)
		helpers.assert_eq(f.effects.runtime, 0)
		helpers.assert_eq(f.effects.saves, 0)
	end)
end

helpers.describe("HS-010 Ollama download shared slot", function()
	for _, options in ipairs({ { show_result = false }, { show_replaced = true } }) do
		helpers.it("(ollama-ui-session-owner) does not adopt a "
			.. (options.show_replaced and "superseded" or "refused") .. " show", function()
			with_fixture(options, function(f)
				helpers.assert_true(start_pull(f, "model-A"))
				helpers.assert_nil(f.progress.updates)
				f.pulls[1].on_done(2)
				helpers.assert_eq(f.progress.completes, 0)
				helpers.assert_nil(f.active_tasks.ollama_pull)
			end)
		end)
	end

	helpers.it("(ollama-ui-session-owner) fences cancelled completion through the real shared window", function()
		with_fixture({ real_window = true }, function(f)
			local accepted, terminal = start_pull(f, "model-A")
			helpers.assert_true(accepted)
			local native = f.native_window()
			native.opts.on_navigation("didFinishNavigation")
			local owner = f.pulls[1]
			-- The native-close callback cancels A but does not destroy its task owner.
			native.opts.on_close()
			helpers.assert_eq(owner.terminate_calls, 1,
				"native close must cancel A even after the window becomes inactive")
			helpers.assert_eq(f.progress.aborts, 1)
			local successor_cancels = 0
			helpers.assert_true(f.window.show({ kind = "mlx_model", model = "model-B",
				on_cancel = function() successor_cancels = successor_cancels + 1 end,
			}))
			local successor = f.native_window()
			successor.opts.on_navigation("didFinishNavigation")
			native.opts.on_close()
			helpers.assert_eq(successor_cancels, 0, "a retired native close must not cancel B")
			helpers.assert_eq(owner.terminate_calls, 1)
			helpers.assert_eq(f.progress.aborts, 1)
			local before = #successor.codes
			owner.on_done(15)
			helpers.assert_eq(#successor.codes, before, "A must not emit done() into B")
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_nil(f.active_tasks.ollama_pull)
		end)
	end)

	helpers.it("(ollama-ui-session-owner) refuses an old retry without reclaiming the shared window", function()
		with_fixture({}, function(f)
			helpers.assert_true(start_pull(f, "model-A"))
			local retry = f.progress.on_retry
			f.pulls[1].on_done(2)
			package.loaded["ui.download_window"].show({ kind = "mlx_model", model = "model-B" })
			helpers.assert_eq(retry(), false)
			helpers.assert_eq(f.progress.shows, 2)
			helpers.assert_eq(#f.pulls, 1)
		end)
	end)

	for _, outcome in ipairs({ "cancel", "stream", "success", "failure" }) do
		helpers.it("(ollama-ui-session-owner) ignores old " .. outcome .. " after shared-window replacement", function()
			with_fixture({}, function(f)
				local accepted, terminal = start_pull(f, "model-A")
				helpers.assert_true(accepted)
				if outcome == "cancel" then helpers.assert_true(f.progress.on_cancel()) end
				package.loaded["ui.download_window"].show({ kind = "mlx_model", model = "model-B" })
				local completes, updates = f.progress.completes, f.progress.updates
				if outcome == "stream" then f.pulls[1].on_stream(nil, "old progress\n", "")
				else f.pulls[1].on_done(outcome == "success" and 0 or 15) end
				helpers.assert_eq(f.progress.completes, completes, "old completion must not mutate the successor")
				helpers.assert_eq(f.progress.updates, updates, "old progress must not mutate the successor")
				if outcome == "cancel" then helpers.assert_eq(terminal.cancel, 1) end
			end)
		end)
	end

	helpers.it("(ollama-terminal-model-argument) quotes custom repositories in the manual command", function()
		with_fixture({}, function(f)
			local repo = [[owner's/model; $(printf EXPANDED) `printf EXPANDED`]]
			helpers.assert_eq(start_pull(f, repo), true)
			helpers.assert_eq(f.progress.terminal_cmd,
				[[ollama pull 'owner'\''s/model; $(printf EXPANDED) `printf EXPANDED`']],
				"a repository must remain one literal shell argument")
		end)
	end)

	helpers.it("(HS-010-busy-terminal) rejects a successor with one terminal and preserves the first owner", function()
		with_fixture({}, function(f)
			local accepted_a = start_pull(f, "model-A")
			helpers.assert_eq(accepted_a, true)
			local owner = f.active_tasks.ollama_pull
			local accepted_b, terminal_b = start_pull(f, "model-B")
			helpers.assert_eq(accepted_b, false)
			helpers.assert_eq(terminal_b.cancel, 1)
			helpers.assert_eq(terminal_b.reasons[1], "busy")
			helpers.assert_true(f.active_tasks.ollama_pull == owner)
			helpers.assert_eq(#f.pulls, 1)
			helpers.assert_eq(f.progress.shows, 1)
			helpers.assert_type(f.progress.on_abort, "function")
			helpers.assert_type(f.progress.on_retry_start, "function")
			helpers.assert_eq(f.progress.on_abort(), true)
			helpers.assert_eq(f.progress.on_retry_start(), true)
			helpers.assert_eq(f.progress.aborts, 1)
			helpers.assert_eq(f.progress.retry_starts, 1)
		end)
	end)

	helpers.it("(HS-010-native-self) retains an accepted cancellation until exact completion", function()
		with_fixture({ terminate_mode = "self" }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			helpers.assert_eq(f.progress.on_cancel(), true)
			helpers.assert_true(f.active_tasks.ollama_pull == owner)
			helpers.assert_eq(owner.terminate_calls, 1)
			helpers.assert_eq(terminal.cancel, 0)

			owner.on_done(0)
			owner.on_done(0)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.display, 0)
			helpers.assert_eq(f.effects.saves, 0)
		end)
	end)

	helpers.it("(HS-010-cancel-refusal-false) retains cleanup ownership after false", function()
		assert_cancel_refusal("false")
	end)

	helpers.it("(HS-010-cancel-refusal-nil) retains cleanup ownership after nil", function()
		assert_cancel_refusal("nil")
	end)

	helpers.it("(HS-010-cancel-refusal-throw) retains cleanup ownership after throw", function()
		assert_cancel_refusal("throw")
	end)

	helpers.it("(HS-010-sync-cancel-completion) latches cancellation before native completion", function()
		with_fixture({
			terminate_mode = function(task)
				task.on_done(0)
				return "self"
			end,
		}, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			helpers.assert_eq(f.progress.on_cancel(), true)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(owner.terminate_calls, 1)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "user_cancelled")
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.saves, 0)
		end)
	end)

	helpers.it("(HS-010-construction-refusal) reports task construction refusal exactly once", function()
		with_fixture({ construct_result = false }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(#f.pulls, 0)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "task_construction_failed")
		end)
	end)

	helpers.it("(HS-010-start-refusal) reports task start refusal exactly once", function()
		with_fixture({ start_result = false }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "task_start_refused")
		end)
	end)

	helpers.it("(HS-010-sync-completion-refused-start) never publishes a callback delivered before start refusal", function()
		with_fixture({ start_result = false, complete_during_start = 0 }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "task_start_refused")
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.display, 0)
			helpers.assert_eq(f.effects.saves, 0)
			helpers.assert_nil(f.http_callback())
		end)
	end)

	helpers.it("(HS-010-sync-completion-accepted-start) settles a buffered failure exactly once", function()
		with_fixture({ complete_during_start = 2 }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "process_failed")
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.saves, 0)
		end)
	end)

	helpers.it("(HS-010-process-failure) reports a native pull failure exactly once", function()
		with_fixture({}, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			owner.on_done(2)
			owner.on_done(2)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "process_failed")
		end)
	end)

	helpers.it("(HS-010-success-control) commits one model only after loadability succeeds", function()
		with_fixture({}, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			owner.on_done(0)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_type(f.http_callback(), "function")
			f.http_callback()(200, "{}", {})
			helpers.assert_eq(terminal.success, 1)
			helpers.assert_eq(terminal.cancel, 0)
		end)
	end)
	helpers.it("wraps the original pull slot with admission before the exact CLI exec", function()
		local admissions = 0
		with_fixture({ network_env = {
			opaque_prelude = function(tag)
				helpers.assert_eq(tag, "OLLAMA-PULL")
				admissions = admissions + 1
				return "fixture_admission; "
			end,
		} }, function(f)
			helpers.assert_true(start_pull(f))
			helpers.assert_eq(admissions, 1)
			helpers.assert_eq(#f.pulls, 1)
			helpers.assert_eq(f.pulls[1].executable, "/bin/bash")
			helpers.assert_eq(f.pulls[1].args[1], "-c")
			helpers.assert_eq(f.pulls[1].args[2], "fixture_admission; exec '/fixture/ollama' pull 'model-A'")
			helpers.assert_eq(f.active_tasks.ollama_pull, f.pulls[1])
		end)
	end)

end)

return true
