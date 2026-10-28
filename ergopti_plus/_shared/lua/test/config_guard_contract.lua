--- _shared/lua/test/config_guard_contract.lua

--- ==============================================================================
--- MODULE: AI Menu Configuration Guard Contract
--- DESCRIPTION:
--- Pins llm/config_guard directly: the one cause named for each write refusal
--- and the retained-click fence. macOS and Linux both wrap their AI submenus
--- with it, so the cases run in both suites against the shared module itself,
--- not through one driver's menu builder.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Guard = require("llm.config_guard")

	--- A migration owner answering a fixed reason and status.
	local function migrate(reason, status)
		return {
			read_only_reason = function() return reason end,
			read_only_status = function() return status end,
		}
	end

	--- The dialect of a driver, recording each refusal.
	local function dialect(refusals)
		return {
			action = "action",
			children = "items",
			refused = function(reason) refusals[#refusals + 1] = reason end,
		}
	end

	helpers.describe("AI menu configuration guard (config-guard-contract)", function()
		helpers.it("(config-guard-contract) names one cause per refusal and nothing when the file is writable", function()
			helpers.assert_eq(Guard.reason_key("/c/config.toml", migrate(nil, nil)), nil)
			helpers.assert_eq(Guard.reason_key("/c/config.toml", migrate("x", "newer")), Guard.NEWER_REASON_KEY)
			helpers.assert_eq(Guard.reason_key("/c/config.toml", migrate("x", "unreadable")), Guard.GENERIC_REASON_KEY)
			helpers.assert_eq(Guard.NEWER_REASON_KEY, "menu.read_only.newer_schema")
			helpers.assert_eq(Guard.GENERIC_REASON_KEY, "menu.llm.save_unavailable")
		end)

		helpers.it("(config-guard-contract) treats a missing config path as unwritable without asking the owner", function()
			local asked = 0
			local owner = { read_only_reason = function() asked = asked + 1 end, read_only_status = function() end }
			helpers.assert_eq(Guard.reason_key(nil, owner), Guard.GENERIC_REASON_KEY)
			helpers.assert_eq(Guard.reason_key("", owner), Guard.GENERIC_REASON_KEY)
			helpers.assert_eq(asked, 0, "no path means no question to the migration owner")
		end)

		helpers.it("(config-guard-contract) asks again at every click and refuses without running the action", function()
			local refusals, ran, reason = {}, 0, nil
			local items = { { action = function(...) ran = ran + 1; return "done", ... end } }
			Guard.protect(items, function() return reason end, dialect(refusals))
			local first, argument = items[1].action("arg")
			helpers.assert_eq(first, "done")
			helpers.assert_eq(argument, "arg", "arguments reach the wrapped action")
			helpers.assert_eq(ran, 1)
			reason = Guard.NEWER_REASON_KEY
			helpers.assert_eq(items[1].action(), false)
			helpers.assert_eq(ran, 1, "a refused click must not run the action")
			helpers.assert_eq(#refusals, 1)
			helpers.assert_eq(refusals[1], Guard.NEWER_REASON_KEY)
			reason = nil
			helpers.assert_eq(items[1].action(), "done")
			helpers.assert_eq(ran, 2, "the fence lifts as soon as the file is writable again")
		end)

		helpers.it("(config-guard-contract) wraps in place, through children, and leaves rows without an action alone", function()
			local refusals, reason = {}, "r"
			local leaf = { action = function() return true end }
			local child_list = { leaf }
			local parent = { items = child_list }
			local inert = { title = "no action" }
			local items = { parent, inert, "text row" }
			Guard.protect(items, function() return reason end, dialect(refusals))
			helpers.assert_eq(items[1], parent, "the table keeps its identity")
			helpers.assert_eq(parent.items, child_list)
			helpers.assert_eq(leaf.action(), false)
			helpers.assert_eq(refusals[1], "r")
			helpers.assert_eq(inert.action, nil)
			helpers.assert_eq(items[3], "text row")
			Guard.protect(nil, function() end, dialect(refusals))
			Guard.protect("not a table", function() end, dialect(refusals))
		end)

		helpers.it("(config-guard-contract) stops at the depth bound and survives a cyclic tree", function()
			local refusals = {}
			local root = { items = {} }
			local node = root
			local nodes = {}
			for depth = 1, 10 do
				node.action = function() return true end
				nodes[depth] = node
				local nxt = { items = {} }
				node.items[1] = nxt
				node = nxt
			end
			Guard.protect({ root }, function() return "r" end, dialect(refusals))
			helpers.assert_eq(nodes[1].action(), false, "the top of the tree is fenced")
			local unfenced = false
			for _, candidate in ipairs(nodes) do
				if candidate.action() == true then unfenced = true end
			end
			helpers.assert_true(unfenced, "a tree deeper than the bound is not walked without end")
			local cyclic = { action = function() return true end }
			cyclic.items = { cyclic }
			Guard.protect({ cyclic }, function() return "r" end, dialect(refusals))
			helpers.assert_eq(cyclic.action(), false)
		end)
	end)
end

return M
