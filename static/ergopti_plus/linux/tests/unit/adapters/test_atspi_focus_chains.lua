--- tests/unit/adapters/test_atspi_focus_chains.lua

--- ==============================================================================
--- MODULE: Native Accessible Focus Ancestor Chain Tests
--- DESCRIPTION:
--- WebKit reports FOCUSED on its root pane, document and actual textarea. Their
--- unique leaf is one destination; unrelated focused branches remain ambiguous.
--- A focused password ancestor can never authorize an ordinary descendant.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the real traversal with native ownership-compatible tree observations.
--- @param nodes table Active frame descendants.
--- @param body function Assertions for the returned snapshot and verdict.
local function with_tree(nodes, body)
	local Focus = require("adapters.atspi_focus")
	local frame = { role = 23, active = true, bus = ":1.10", path = "/owned/frame", children = nodes }
	local root = { children = { { children = { frame } } } }
	local owned = {}
	local backend = {
		root = function() return root end,
		children = function(node) return node.children or {} end,
		focused = function(node) return node.focused == true end,
		active = function(node) return node.active == true end,
		role = function(node) return node.role end,
		identity = function(node)
			return { name = "", attributes = {}, native_bus_name = node.bus, native_object_path = node.path }
		end,
		release = function(node) owned[node] = (owned[node] or 0) + 1 end,
	}
	Focus._set_backend_for_test(backend)
	local ok, detail = pcall(function()
		local snapshot, conclusive = Focus.get_snapshot()
		body(snapshot, conclusive)
		for _, count in pairs(owned) do helpers.assert_eq(count, 1, "each visited borrowed tree reference releases once") end
	end)
	Focus._set_backend_for_test(nil)
	if not ok then error(detail, 0) end
end

helpers.describe("AT-SPI focused ancestor chains", function()
	helpers.it("(atspi-focus-chain) real WebKit root-pane document textarea observations select exact leaf", function()
		-- Measured against real WebKitGTK 2.52.6 with its sandbox enabled:
		-- frame23 bus1.0 -> root-pane49 bus1.2 -> document95 -> textarea79.
		-- All three descendants carry FOCUSED, despite one actual HTML control.
		with_tree({ { role = 49, focused = true, children = {
			{ role = 95, focused = true, children = { { children = {
				{ role = 79, focused = true, bus = ":1.20", path = "/embedded/textarea" },
			} } } },
		} } }, function(snapshot, conclusive)
			helpers.assert_true(conclusive)
			helpers.assert_eq(snapshot.role, 79)
			helpers.assert_eq(snapshot.native_bus_name, ":1.20")
			helpers.assert_eq(snapshot.native_object_path, "/embedded/textarea")
			helpers.assert_true(snapshot.active_scope)
		end)
	end)

	for _, shared_ancestor in ipairs({ false, true }) do
		helpers.it("(atspi-focus-chain) focused siblings remain ambiguous with focused ancestor " .. tostring(shared_ancestor), function()
			with_tree({ { role = 95, focused = shared_ancestor, children = {
				{ role = 79, focused = true, path = "/first" },
				{ role = 79, focused = true, path = "/second" },
			} } }, function(snapshot, conclusive)
				helpers.assert_eq(conclusive, false)
				helpers.assert_eq(snapshot, nil)
			end)
		end)
	end

	helpers.it("(atspi-focus-chain) focused branches separated by ordinary containers remain ambiguous", function()
		with_tree({ { children = { { role = 79, focused = true, path = "/first" } } },
			{ children = { { role = 79, focused = true, path = "/second" } } } }, function(snapshot, conclusive)
			helpers.assert_eq(conclusive, false)
			helpers.assert_eq(snapshot, nil)
		end)
	end)

	helpers.it("(atspi-focus-chain) focused password ancestor cannot admit an ordinary descendant", function()
		with_tree({ { role = 40, focused = true, children = {
			{ children = { { role = 79, focused = true, path = "/password/internal-text" } } },
		} } }, function(snapshot, conclusive)
			helpers.assert_eq(conclusive, false)
			helpers.assert_eq(snapshot, nil)
		end)
	end)

	helpers.it("(atspi-focus-chain) password leaf retains its secure role under focused ancestors", function()
		with_tree({ { role = 49, focused = true, children = { { role = 95, focused = true, children = {
			{ role = 40, focused = true, bus = ":1.20", path = "/embedded/password" },
		} } } } }, function(snapshot, conclusive)
			helpers.assert_true(conclusive)
			helpers.assert_eq(snapshot.role, 40)
			helpers.assert_eq(snapshot.native_object_path, "/embedded/password")
		end)
	end)
end)
