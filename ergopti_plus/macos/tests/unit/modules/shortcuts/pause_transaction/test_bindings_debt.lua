--- tests/unit/modules/shortcuts/pause_transaction/test_bindings_debt.lua

--- ==============================================================================
--- MODULE: Script-Control Bindings Debt Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context

helpers.describe("script-control: bindings child cleanup debt", function()
	helpers.it("settles pixel debt while preserving an originally OFF bindings layer", function()
		local calls = { pause = 0, resume = 0 }
		local debt = true
		with_context({
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return false end,
					has_bindings_pause_debt = function() return debt end,
					pause_bindings = function()
						calls.pause = calls.pause + 1
						debt = false
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						return true
					end,
					release_bindings_pause_claim = function() return true end,
				}
			end,
		}, function(script_control, ctx)

			helpers.assert_eq(script_control.pause_all(), true)
			ctx.fire_deferred()
			ctx.pause_callback(true, "paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(calls.pause, 1)
			helpers.assert_eq(debt, false)

			helpers.assert_eq(script_control.resume_all(), true)
			ctx.fire_deferred()
			ctx.resume_callback(true, "resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(calls.resume, 0,
				"cleanup-only debt must not resurrect bindings that were OFF before pause")
			script_control.stop()
		end)
	end)

	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("rejects an ambiguous bindings-debt snapshot after " .. mode, function()
			local pause_calls = 0
			with_context({
				shortcuts_factory = function()
					return {
						is_bindings_started = function() return false end,
						has_bindings_pause_debt = function()
							if mode == "throw" then error("synthetic debt query failure") end
							return nil
						end,
						pause_bindings = function()
							pause_calls = pause_calls + 1
							return true
						end,
						resume_bindings = function() return true end,
						release_bindings_pause_claim = function() return true end,
					}
				end,
			}, function(script_control, ctx)

				helpers.assert_eq(script_control.pause_all(), true,
					"the public request reports controller admission, not local settlement")
				ctx.fire_deferred()
				ctx.pause_callback(true, "native-paused")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(pause_calls, 0,
					"an ambiguous ownership query must fail before cleanup mutation")
				helpers.assert_eq(ctx.calls.karabiner_resume, 1,
					"the already-paused native layer must be rolled back")
				ctx.resume_callback(true, "native-running")
				script_control.stop()
			end)
		end)
	end

	helpers.it("does not duplicate a reversible shortcut debt with cleanup-only work", function()
		local calls = { pause = 0, resume = 0 }
		local started = true
		local debt = false
		local rollback_refusals = 1
		with_context({
			pause_failure = { step = "mlx_stop", mode = "false" },
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return started end,
					has_bindings_pause_debt = function() return debt end,
					pause_bindings = function()
						calls.pause = calls.pause + 1
						started = false
						debt = false
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						if rollback_refusals > 0 then
							rollback_refusals = rollback_refusals - 1
							debt = true
							return false
						end
						started = true
						debt = false
						return true
					end,
				}
			end,
		}, function(script_control, ctx)

			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callback(true, "first-native-paused")
			helpers.assert_eq(calls.pause, 1)
			helpers.assert_eq(calls.resume, 1)
			helpers.assert_eq(debt, true)
			helpers.assert_eq(ctx.calls.karabiner_resume, 1)
			ctx.resume_callback(true, "first-native-rollback")

			ctx.pause_failure = nil
			helpers.assert_eq(script_control.pause_all(), true)
			ctx.fire_deferred()
			ctx.pause_callback(true, "retry-native-paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(calls.pause, 2,
				"the retained reversible owner must be quiesced once, not once per debt label")

			script_control.resume_all()
			ctx.fire_deferred()
			ctx.resume_callback(true, "final-native-resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(calls.resume, 2)
			helpers.assert_eq(started, true,
				"the original ON intent must survive the retained reversible debt")
			script_control.stop()
		end)
	end)
end)
