--- _shared/lua/test/hotstring_cascade_net_edit_contract.lua

--- ==============================================================================
--- MODULE: Hotstring Cascade Net Edit Contract
--- DESCRIPTION:
--- Pins the shared chain loop (`hotstring_engine.cascade`) with a scripted
--- `pick` port, so each rule is proven apart from any registry: the net edit
--- keeps the untouched prefix, the arrow bound and the same-spec guard end the
--- chain, a refused `admit` ends it without marking the spec, a final_result link
--- ends it, and the carried end character survives every step. Both drivers
--- replay it; their registry questions are covered by cascade_vectors.json.
--- ==============================================================================

local M = {}

--- Builds a pick port that serves the scripted steps in order.
local function scripted(steps, seen_args)
	local index = 0
	return function(vcps, _, carried, stable)
		index = index + 1
		if seen_args then seen_args[#seen_args + 1] = { text = table.concat(vcps), carried = carried, stable = stable } end
		return steps[index]
	end
end

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
function M.register(helpers)
	local Cascade = require("hotstring_engine.cascade")

	local function resolve(buffer, first, steps, max_arrows, seen_args)
		return Cascade.resolve({
			buffer = Cascade.codepoints(buffer),
			first = first,
			max_arrows = max_arrows or 10,
			pick = scripted(steps, seen_args),
		})
	end

	helpers.describe("hotstring cascade net edit (shared contract)", function()
		helpers.it("returns nil when the first step has no successor", function()
			local net = resolve("xab", { key = "ab", backspace_count = 2, replacement = "cab" }, {})
			helpers.assert_eq(net, nil, "no chain")
		end)

		helpers.it("keeps the untouched prefix and reports one net edit", function()
			local net = resolve("xab", { key = "ab", backspace_count = 2, replacement = "cab" }, {
				{ key = "ab2", backspace_count = 2, replacement = "Z" },
			})
			helpers.assert_eq(net.stable, 1, "x untouched")
			helpers.assert_eq(net.backspace_count, 2, "erases the two typed letters")
			helpers.assert_eq(net.replacement, "cZ", "net text")
			helpers.assert_eq(net.steps, 2, "two arrows")
		end)

		helpers.it("reaches left of the first trigger when a step does", function()
			local net = resolve("xab", { key = "ab", backspace_count = 2, replacement = "cab" }, {
				{ key = "xcab", backspace_count = 4, replacement = "Q" },
			})
			helpers.assert_eq(net.stable, 0, "nothing untouched")
			helpers.assert_eq(net.backspace_count, 3, "erases the whole typed text")
		end)

		helpers.it("carries the end character through every step and returns it", function()
			local seen = {}
			local net = resolve("ab ", { key = "ab", backspace_count = 3, replacement = "cd", terminator = " " }, {
				{ key = "cd", backspace_count = 3, replacement = "ef" },
			}, 10, seen)
			helpers.assert_eq(seen[1].text, "cd ", "the port sees the end character")
			helpers.assert_eq(seen[1].carried, " ", "and is told it is carried")
			helpers.assert_eq(net.replacement, "ef", "text excludes the end character")
			helpers.assert_eq(net.terminator, " ", "end character left to replay")
		end)

		helpers.it("stops at the arrow bound", function()
			local net = resolve("a", { key = "a", backspace_count = 1, replacement = "b" }, {
				{ key = "b", backspace_count = 1, replacement = "c" },
				{ key = "c", backspace_count = 1, replacement = "d" },
			}, 2)
			helpers.assert_eq(net.steps, 2, "bounded")
			helpers.assert_eq(net.replacement, "c", "third step never applied")
		end)

		helpers.it("stops when the same spec would fire again", function()
			local net = resolve("a", { key = "a", backspace_count = 1, replacement = "ba" }, {
				{ key = "b", backspace_count = 1, replacement = "c" },
				{ key = "a", backspace_count = 1, replacement = "loop" },
			})
			helpers.assert_eq(net.steps, 2, "the repeat is refused")
			helpers.assert_eq(net.replacement, "bc", "text before the repeat")
		end)

		helpers.it("consults admit after the same-spec guard and honours its refusal", function()
			local asked = 0
			local net = resolve("a", { key = "a", backspace_count = 1, replacement = "b" }, {
				{ key = "a", backspace_count = 1, replacement = "x", admit = function() asked = asked + 1 return true end },
			})
			helpers.assert_eq(asked, 0, "a repeated spec never reaches the gate")
			helpers.assert_eq(net, nil, "nothing chained")
			net = resolve("a", { key = "a", backspace_count = 1, replacement = "b" }, {
				{ key = "b", backspace_count = 1, replacement = "c", admit = function() return false end },
			})
			helpers.assert_eq(net, nil, "a refused step ends the chain")
		end)

		helpers.it("ends the chain after a final_result link", function()
			local net = resolve("a", { key = "a", backspace_count = 1, replacement = "b" }, {
				{ key = "b", backspace_count = 1, replacement = "c", final_result = true },
				{ key = "c", backspace_count = 1, replacement = "d" },
			})
			helpers.assert_eq(net.steps, 2, "nothing chains off a final link")
			helpers.assert_eq(net.final_result, true, "reported")
		end)
	end)
end

return M
