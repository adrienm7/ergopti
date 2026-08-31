--- tests/unit/adapters/test_atspi_focus.lua

--- ==============================================================================
--- MODULE: AT-SPI Focus Query Tests (Linux)
--- DESCRIPTION:
--- Exercises the real tree-walk decision through an ownership-compatible fake:
--- focused descendant discovery, ambiguity, backend failure, and release pairing.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Focused Role Traversal =======
-- =========================================
-- =========================================

helpers.describe("AT-SPI focus query", function()
	local previous_logger = package.loaded["logger.shim"]
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	local AtspiFocus = helpers.load_module("adapters.atspi_focus")
	local ShellRunner = helpers.load_module("adapters.shell_runner")

	local function backend(root)
		local released = {}
		return {
			root = function() return root end,
			focused = function(node) return node.focused == true end,
			role = function(node) return node.role end,
			identity = function(node)
				return { name = node.name or "", attributes = node.attributes or {} }
			end,
			children = function(node) return node.children or {} end,
			release = function(node) released[#released + 1] = node.id end,
			released = released,
		}
	end

	helpers.it("returns the role of the focused nested accessible", function()
		local tree = {
			id = "desktop",
			children = {
				{ id = "app-a", children = { { id = "ordinary", role = 57 } } },
				{ id = "app-b", children = {
					{ id = "window", children = {
						{ id = "password", focused = true, role = 40 },
					} },
				} },
			},
		}
		local fake = backend(tree)
		AtspiFocus._set_backend_for_test(fake)
		local role, conclusive = AtspiFocus.get_role()
		helpers.assert_eq(conclusive, true, "one focused object is conclusive")
		helpers.assert_eq(role, 40, "the focused descendant's role must be returned")
		helpers.assert_eq(#fake.released, 6, "every owned node, including the root, must release")
	end)

	helpers.it("rejects no focus, duplicate focus, and traversal failure", function()
		local cases = {
			{ id = "none", children = { { id = "plain", role = 57 } } },
			{ id = "duplicate", children = {
				{ id = "a", focused = true, role = 40 },
				{ id = "b", focused = true, role = 57 },
			} },
		}
		for _, tree in ipairs(cases) do
			AtspiFocus._set_backend_for_test(backend(tree))
			local role, conclusive = AtspiFocus.get_role()
			helpers.assert_eq(role, nil, tree.id .. " must not invent a role")
			helpers.assert_eq(conclusive, false, tree.id .. " must remain inconclusive")
		end

		local broken = backend({ id = "root" })
		broken.children = function() return nil end
		AtspiFocus._set_backend_for_test(broken)
		local role, conclusive = AtspiFocus.get_role()
		helpers.assert_eq(role, nil, "a failed child query must not invent a role")
		helpers.assert_eq(conclusive, false, "partial traversal must remain inconclusive")
	end)

	helpers.it("bounds the native query and accepts only an explicit role record", function()
		AtspiFocus._set_backend_for_test(nil)
		local original_package_path = package.path
		package.path = package.path .. ";$(touch /tmp/ergopti-atspi-injection)'`id`"
		local quoted_package_path = ShellRunner.quote(package.path)
		local captured = nil
		AtspiFocus._set_command_runner_for_test(function(command)
			captured = command
			return false, "ROLE:40", "124"
		end)
		local role, conclusive = AtspiFocus.get_role()
		package.path = original_package_path
		helpers.assert_eq(role, nil, "timed-out output must never publish")
		helpers.assert_eq(conclusive, false, "timeout remains inconclusive")
		helpers.assert_true(captured:find("timeout -s KILL 1s", 1, true) ~= nil,
			"the native accessibility query must have a hard deadline")
		helpers.assert_contains(captured, "LUA_PATH=" .. quoted_package_path,
			"the inherited Lua search path must remain one inert shell word")

		AtspiFocus._set_command_runner_for_test(function()
			return true, 'diagnostic\nFOCUS:{"attributes":{},"name":"Password","role":40}', nil
		end)
		role, conclusive = AtspiFocus.get_role()
		helpers.assert_eq(conclusive, true, "a successful explicit role record is conclusive")
		helpers.assert_eq(role, 40, "the helper's exact numeric role must survive")
	end)

	helpers.it("returns focused identity fields without confusing another node", function()
		local tree = {
			id = "desktop",
			children = {
				{ id = "other", name = "Address and search bar", role = 79 },
				{
					id = "focused",
					focused = true,
					role = 79,
					name = "Search or enter address",
					attributes = { id = "urlbar-input" },
				},
			},
		}
		AtspiFocus._set_backend_for_test(backend(tree))
		local snapshot, conclusive = AtspiFocus.get_snapshot()
		helpers.assert_eq(conclusive, true)
		helpers.assert_eq(snapshot.role, 79)
		helpers.assert_eq(snapshot.name, "Search or enter address")
		helpers.assert_eq(snapshot.attributes.id, "urlbar-input")
	end)

	AtspiFocus._set_backend_for_test(nil)
	AtspiFocus._set_command_runner_for_test(nil)
	package.loaded["logger.shim"] = previous_logger
end)
