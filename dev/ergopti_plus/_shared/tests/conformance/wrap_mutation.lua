--- _shared/tests/conformance/wrap_mutation.lua

--- ==============================================================================
--- MODULE: Wrap Mutation Ownership Conformance
--- DESCRIPTION:
--- Exercises exact receipts, acknowledged read views and field-owned inverses.
--- ==============================================================================

return function(helpers)
	local Mutation = require("menu.wrap_mutation")
	local function fresh()
		return { wrap_symbol_states = { ["("] = false, future = true },
			custom_wrap_symbols = { { left = "a", right = "b", future = { note = "retain" } },
				{ left = "c", right = "d" } }, private = { note = "retain" } }
	end
	local function remove_first(candidate)
		table.remove(candidate.custom_wrap_symbols, 1)
		return true
	end
	helpers.describe("shared Wrap field publication ownership", function()
		for _, receipt in ipairs({ "false", "nil", "truthy", "throw" }) do
			helpers.it("restores owned fields after " .. receipt .. " while retaining live input", function()
				local state = fresh()
				local symbols, custom, private = state.wrap_symbol_states, state.custom_wrap_symbols, state.private
				local saves, observed = 0, {}
				local function save()
					saves = saves + 1
					observed.pending = Mutation.pending(state)
					observed.candidate = state.custom_wrap_symbols
					observed.input = Mutation.view(state).custom_wrap_symbols
					state.private.note = "foreign successor"
					if receipt == "throw" then error("controlled save failure", 0) end
					if receipt == "false" then return false end
					if receipt == "truthy" then return "accepted" end
				end
				helpers.assert_eq(Mutation.commit(state, remove_first, save), false)
				helpers.assert_eq(saves, 1)
				helpers.assert_true(observed.pending)
				helpers.assert_eq(observed.candidate, { { left = "c", right = "d" } }, "writer sees detached candidate")
				helpers.assert_eq(observed.input,
					{ { left = "a", right = "b", future = { note = "retain" } }, { left = "c", right = "d" } },
					"input still sees the independently specified original pair set")
				helpers.assert_true(rawequal(state.wrap_symbol_states, symbols))
				helpers.assert_true(rawequal(state.custom_wrap_symbols, custom))
				helpers.assert_true(rawequal(state.private, private))
				helpers.assert_eq(state.private.note, "foreign successor", "no complete state rollback")
				helpers.assert_eq(state.custom_wrap_symbols[1].future.note, "retain")
				helpers.assert_eq(Mutation.pending(state), false)
				helpers.assert_eq(Mutation.commit(state, remove_first, function() return true end), true, "same owner retries after refusal")
				helpers.assert_eq(state.custom_wrap_symbols, { { left = "c", right = "d" } })
				helpers.assert_eq(Mutation.view(state).custom_wrap_symbols, { { left = "c", right = "d" } })
			end)
		end
		helpers.it("publishes only after literal writer acknowledgement without changing prior tables", function()
			local state, saves = fresh(), 0
			local custom = state.custom_wrap_symbols
			helpers.assert_eq(Mutation.commit(state, remove_first, function() saves = saves + 1; return true end), true)
			helpers.assert_eq(saves, 1)
			helpers.assert_eq(#custom, 2)
			helpers.assert_eq(custom[1].future.note, "retain")
			helpers.assert_eq(state.custom_wrap_symbols, { { left = "c", right = "d" } })
		end)
		for _, phase in ipairs({ "construction", "save" }) do
			helpers.it("refuses a reentrant mutation during " .. phase, function()
				local state, nested_mutations, nested_saves = fresh(), 0, 0
				local nested_receipt
				local function reenter()
					nested_receipt = Mutation.commit(state, function()
						nested_mutations = nested_mutations + 1; return true
					end, function() nested_saves = nested_saves + 1; return true end)
				end
				helpers.assert_eq(Mutation.commit(state, function(candidate)
					if phase == "construction" then reenter() end
					return remove_first(candidate)
				end, function() if phase == "save" then reenter() end; return false end), false)
				helpers.assert_eq(nested_receipt, false, "observe exact reentrant receipt outside protected ports")
				helpers.assert_eq(nested_mutations + nested_saves, 0)
				helpers.assert_eq(state, fresh())
			end)
		end
		for _, phase in ipairs({ "construction", "save" }) do
			helpers.it("preserves a replacement successor during " .. phase, function()
				local state, saves = fresh(), 0
				local successor = { { left = "x", right = "y", private = "successor" } }
				helpers.assert_eq(Mutation.commit(state, function(candidate)
					if phase == "construction" then state.custom_wrap_symbols = successor end
					return remove_first(candidate)
				end, function()
					saves = saves + 1; state.custom_wrap_symbols = successor; return false
				end), false)
				helpers.assert_eq(saves, phase == "save" and 1 or 0)
				helpers.assert_true(rawequal(state.custom_wrap_symbols, successor), "old inverse cannot erase successor array")
				helpers.assert_eq(state.wrap_symbol_states, { ["("] = false, future = true })
				helpers.assert_eq(Mutation.pending(state), false)
			end)
		end
		for _, invalid in ipairs({ "cancelled", "truthy", "throw", "candidate" }) do
			helpers.it("releases the field claim after " .. invalid .. " construction", function()
				local state, saves = fresh(), 0
				helpers.assert_eq(Mutation.commit(state, function(candidate)
					candidate.custom_wrap_symbols[1].future.note = "candidate only"
					if invalid == "throw" then error("controlled construction failure", 0) end
					if invalid == "candidate" then candidate.custom_wrap_symbols = false; return true end
					if invalid == "truthy" then return "accepted" end
					return false
				end, function() saves = saves + 1; return true end), false)
				helpers.assert_eq(saves, 0)
				helpers.assert_eq(state, fresh())
				helpers.assert_eq(Mutation.pending(state), false)
			end)
		end
		helpers.it("retains absent field predecessors after refusal", function()
			local state = { private = "retain" }
			local saves = 0
			helpers.assert_eq(Mutation.commit(state, function(candidate)
				candidate.custom_wrap_symbols[1] = { left = "a", right = "b" }
				return true
			end, function() saves = saves + 1; return false end), false)
			helpers.assert_eq(saves, 1)
			helpers.assert_nil(rawget(state, "wrap_symbol_states"))
			helpers.assert_nil(rawget(state, "custom_wrap_symbols"))
			helpers.assert_eq(state.private, "retain")
		end)
		helpers.it("refuses malformed prior fields without reaching the writer", function()
			local state, calls = { custom_wrap_symbols = "not an array" }, 0
			helpers.assert_eq(Mutation.commit(state, remove_first, function() calls = calls + 1; return true end), false)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(state.custom_wrap_symbols, "not an array")
		end)
	end)
end
