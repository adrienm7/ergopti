--- tests/unit/ui/menu/menu_llm/test_llm_activation_save_gate.lua

--- ==============================================================================
--- MODULE: LLM Activation Preference Gate
--- DESCRIPTION:
--- Exercises the real menu transaction with scoped dependencies and exact receipts.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

local function assert_rejected_activation(backend)
	with_activation(backend, { false }, nil, function(action, state, calls)
		action()
		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(calls.saves, 1)
		helpers.assert_eq(calls.keymap_states, { true, false },
			"a rejected persistence write must reapply the previous prediction lock")
		helpers.assert_eq(calls.get_runtime_enabled(), false,
			"runtime predictions must match the last durable preference")
		helpers.assert_eq(calls.bootstrap, 0,
			"a rejected " .. backend .. " activation must not start dependency setup")
		helpers.assert_eq(calls.requirements, 0,
			"a rejected " .. backend .. " activation must not start model requirements")
		helpers.assert_eq(calls.notifications, 0,
			"a rejected " .. backend .. " activation must not announce success")
		helpers.assert_eq(calls.updates, 1,
			"a rejected " .. backend .. " activation must repaint the restored preference")
	end)
end

helpers.describe("LLM Activation Preference Gate", function()
	helpers.it("keeps Ollama inert when the writer returns false", function()
		assert_rejected_activation("ollama")
	end)

	helpers.it("keeps MLX inert when the writer returns false", function()
		assert_rejected_activation("mlx")
	end)

	helpers.it("compensates a committed MLX enable when bootstrap fails", function()
		with_activation("mlx", { true, true }, nil, function(action, state, calls)
			action()
			helpers.assert_eq(state.llm_enabled, true)
			helpers.assert_eq(calls.saves, 1,
				"the enabled candidate must be durable before MLX setup starts")
			helpers.assert_eq(calls.bootstrap, 1)
			helpers.assert_type(calls.bootstrap_callback, "function")
			helpers.assert_eq(calls.notifications, 0,
				"activation success must wait for the asynchronous prerequisite")

			calls.bootstrap_callback(false)

			helpers.assert_eq(state.llm_enabled, false,
				"failed MLX setup must restore the disabled preference")
			helpers.assert_eq(calls.saves, 2,
				"failed MLX setup must durably compensate the earlier enable")
			helpers.assert_eq(calls.keymap_states, { true, false })
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end)

	helpers.it("fails closed when the compensating MLX disable cannot commit", function()
		with_activation("mlx", { true, false }, nil, function(action, state, calls)
			action()
			calls.bootstrap_callback(false)

			helpers.assert_eq(state.llm_enabled, true,
				"rollback of a rejected compensation must restore the last durable enabled state")
			helpers.assert_eq(calls.last_attempted_enabled(), false,
				"the callback must still attempt the compensating disable")
			helpers.assert_eq(calls.saves, 2)
			helpers.assert_eq(calls.notifications, 0,
				"a backend that failed bootstrap must never announce activation success")
			helpers.assert_eq(calls.requirements, 0)
		end)
	end)

	helpers.it("discards an MLX completion after a sibling backend switch", function()
		with_activation("mlx", { true }, nil, function(action, state, calls)
			action()
			helpers.assert_eq(calls.bootstrap, 1)

			state.llm_backend = "api"
			calls.bootstrap_callback(true)

			helpers.assert_eq(calls.requirements, 0,
				"an MLX callback must not start requirements under the replacement backend")
			helpers.assert_eq(calls.notifications, 0,
				"an MLX callback must not announce success after its backend was replaced")
			helpers.assert_eq(calls.updates, 0,
				"the stale callback must not publish its obsolete activation result")
		end)
	end)

	helpers.it("contains a directly raised MLX bootstrap and compensates the enable", function()
		with_activation("mlx", { true, true }, {
			bootstrap_throw = true,
		}, function(action, state, calls)
			action()
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(calls.saves, 2)
			helpers.assert_eq(calls.keymap_states, { true, false })
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end)

	helpers.it("contains a directly raised requirements dispatch and compensates Ollama", function()
		with_activation("ollama", { true, true }, {
			requirements_throw = true,
		}, function(action, state, calls)
			action()
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(calls.saves, 2)
			helpers.assert_eq(calls.keymap_states, { true, false })
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end)

	helpers.it("fails closed before persistence when the keymap enable setter raises", function()
		with_activation("ollama", { true }, {
			keymap_throw_on = true,
		}, function(action, state, calls)
			action()
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(calls.saves, 0,
				"a candidate whose runtime could not apply must never be persisted")
			helpers.assert_eq(calls.bootstrap, 0)
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end)

	helpers.it("settles an MLX activation exactly once when the checker callbacks twice", function()
		with_activation("mlx", { true }, {
			bootstrap_double_success = true,
		}, function(action, state, calls)
			action()
			helpers.assert_eq(state.llm_enabled, true)
			helpers.assert_eq(calls.saves, 1)
			helpers.assert_eq(calls.requirements, 1,
				"a duplicate success callback must not start requirements twice")
			helpers.assert_eq(calls.notifications, 1,
				"a duplicate success callback must not announce activation twice")
			helpers.assert_eq(calls.updates, 1,
				"a duplicate success callback must not repaint twice")
		end)
	end)

	helpers.it("does not compensate twice when the checker callbacks then raises", function()
		with_activation("mlx", { true, true }, {
			bootstrap_fail_then_throw = true,
		}, function(action, state, calls)
			action()
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(calls.saves, 2,
				"callback(false) followed by throw must perform one compensating save")
			helpers.assert_eq(calls.keymap_states, { true, false })
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("buffers synchronous requirements success until dispatch " .. mode
			.. " settles", function()
			local options = { requirements_sync_success = true }
			if mode == "throw" then
				options.requirements_throw = true
			else
				options.requirements_mode = mode
			end
			with_activation("ollama", { true, true }, options, function(action, state, calls)

				helpers.assert_eq(action(), false)
				helpers.assert_eq(state.llm_enabled, false)
				helpers.assert_eq(calls.saves, 2)
				helpers.assert_eq(calls.keymap_states, { true, false })
				helpers.assert_eq(calls.requirements, 1)
				helpers.assert_eq(calls.notifications, 0,
					"a synchronous terminal cannot publish before literal dispatch acceptance")
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("requires exact Ollama dependency settlement after " .. mode, function()
			local options = {}
			if mode == "throw" then
				options.ollama_bootstrap_throw = true
			elseif mode == "false" then
				options.ollama_bootstrap_return = false
			else
				options.ollama_bootstrap_return = "nil"
			end
			with_activation("ollama", { true, true }, options, function(action, state, calls)

				helpers.assert_eq(action(), false)
				helpers.assert_eq(calls.bootstrap, 1)
				if mode == "false" then
					helpers.assert_eq(calls.ollama_bootstrap_outcome, "boolean")
					helpers.assert_eq(calls.ollama_bootstrap_receipt, false)
				else
					helpers.assert_eq(calls.ollama_bootstrap_outcome, mode)
				end
				helpers.assert_eq(state.llm_enabled, false)
				helpers.assert_eq(calls.saves, 2)
				helpers.assert_eq(calls.requirements, 0)
				helpers.assert_eq(calls.notifications, 0)
			end)
		end)
	end
end)

return true
