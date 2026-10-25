--- _shared/lua/test/dynamic_hotstrings_user_scope_contract.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Configuration Inverse Contract
--- DESCRIPTION:
--- Pins dynamic_hotstrings/user_scope directly: a snapshot is captured only
--- while the native identity, the policy and the source file agree, a
--- transaction adopts new controls only while it still owns the revision, and
--- a nested foreign mutation can never become the accepted inverse. Both Lua
--- drivers build their user-code facade on it, so the cases run in both suites.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local UserScope = require("dynamic_hotstrings.user_scope")

	--- Builds a scope over a controllable world.
	--- @return table scope
	--- @return table world The mutable state behind the ports, and a call log.
	local function build()
		local world = {
			identity = {}, native = {},
			source = { present = true, path = "/c/user.lua", content = "return {}" },
			seconds = 3, enabled = true, desired = true, quiescent = true,
			calls = {},
		}
		world.policy = { ready = true, enabled = true, source = world.source }
		local scope
		local ports = {
			identity = function() return world.identity, world.native end,
			policy = function() return world.policy end,
			read_source = function()
				if world.on_read then world.on_read(scope) end
				return world.source
			end,
			source_current = function(source) return source.content == world.source.content end,
			seconds = function() return world.seconds end,
			enabled = function() return world.enabled end,
			desired = function() return world.desired end,
			quiescent = function() return world.quiescent end,
			set_seconds = function(value)
				world.calls[#world.calls + 1] = "seconds=" .. tostring(value)
				world.seconds = value
				local token = scope.begin()
				if world.on_set then world.on_set(scope) end
				return world.acknowledge ~= false, world.token_override or token
			end,
			set_enabled = function(value)
				world.calls[#world.calls + 1] = "enabled=" .. tostring(value)
				world.enabled = value
				local token = scope.begin()
				if world.on_enable then world.on_enable(scope) end
				return world.acknowledge ~= false, token
			end,
			restore = function(snapshot, token)
				world.calls[#world.calls + 1] = "restore"
				world.restored = { snapshot = snapshot, token = token }
				return world.restore_result ~= false
			end,
		}
		scope = UserScope.new(ports)
		return scope, world
	end

	helpers.describe("programmable hotstring configuration inverse (user-scope-contract)", function()
		helpers.it("(user-scope-contract) hands out a fresh revision token and recognises only the latest", function()
			local scope = build()
			local first = scope.begin()
			helpers.assert_true(scope.current(first))
			helpers.assert_eq(scope.revision(), first)
			local second = scope.begin()
			helpers.assert_eq(scope.current(first), false, "a superseded token is stale")
			helpers.assert_true(scope.current(second))
		end)

		helpers.it("(user-scope-contract) captures the live controls while identity, policy and source agree", function()
			local scope, world = build()
			local snapshot = scope.capture()
			helpers.assert_not_nil(snapshot)
			helpers.assert_eq(snapshot.identity, world.identity)
			helpers.assert_eq(snapshot.native, world.native)
			helpers.assert_eq(snapshot.seconds, 3)
			helpers.assert_eq(snapshot.enabled, true)
			helpers.assert_eq(snapshot.expected, scope.revision())
			helpers.assert_eq(snapshot.closed_only, nil)
			helpers.assert_true(scope.current_snapshot(snapshot))
		end)

		helpers.it("(user-scope-contract) refuses to capture without a native identity or with a drifted source", function()
			local scope, world = build()
			world.identity = nil
			helpers.assert_nil(scope.capture())
			scope, world = build()
			world.policy.source = { present = true, path = "/c/user.lua", content = "return { old = true }" }
			helpers.assert_nil(scope.capture(), "the policy was admitted from other source text")
			scope, world = build()
			world.policy.source = nil
			helpers.assert_nil(scope.capture(), "a ready policy must name its source")
		end)

		helpers.it("(user-scope-contract) refuses a capture that a nested mutation overtakes", function()
			local scope, world = build()
			world.on_read = function(owner) owner.begin() end
			helpers.assert_nil(scope.capture())
			scope, world = build()
			world.on_read = function() world.native = {} end
			helpers.assert_nil(scope.capture(), "the native object was replaced while reading")
		end)

		helpers.it("(user-scope-contract) captures an absent source only from a closed, quiescent facade", function()
			local scope, world = build()
			world.source = { present = false }
			world.policy = { ready = false, enabled = false }
			world.enabled = false
			local snapshot = scope.capture()
			helpers.assert_not_nil(snapshot)
			helpers.assert_eq(snapshot.closed_only, true)
			scope, world = build()
			world.source = { present = false }
			world.policy = { ready = false, enabled = false }
			world.enabled = true
			helpers.assert_nil(scope.capture(), "an enabled facade without a source is not closed")
			scope, world = build()
			world.source = { present = false }
			world.policy = { ready = false, enabled = false }
			world.enabled = false
			world.quiescent = false
			helpers.assert_nil(scope.capture(), "a facade with work in flight is not closed")
		end)

		helpers.it("(user-scope-contract) adopts the seconds, then the switch, and keeps ownership through both", function()
			local scope, world = build()
			local snapshot = scope.capture()
			helpers.assert_true(scope.adopt(snapshot, 5, false))
			helpers.assert_eq(world.calls, { "seconds=5", "enabled=false" })
			helpers.assert_true(scope.current_snapshot(snapshot), "the snapshot follows its own mutations")
		end)

		helpers.it("(user-scope-contract) refuses to adopt a stale snapshot without touching the facade", function()
			local scope, world = build()
			local snapshot = scope.capture()
			scope.begin()
			helpers.assert_eq(scope.adopt(snapshot, 5, false), false)
			helpers.assert_eq(world.calls, {})
			helpers.assert_eq(scope.current_snapshot(snapshot), false)
			scope, world = build()
			snapshot = scope.capture()
			world.source = { present = true, path = "/c/user.lua", content = "return { edited = true }" }
			helpers.assert_eq(scope.adopt(snapshot, 5, false), false, "the file changed after the capture")
			helpers.assert_eq(world.calls, {})
		end)

		helpers.it("(user-scope-contract) does not accept a foreign revision as the inverse of its own mutation", function()
			local scope, world = build()
			local snapshot = scope.capture()
			local own_token
			world.on_set = function(owner) own_token = owner.revision(); owner.begin() end
			helpers.assert_eq(scope.adopt(snapshot, 5, false), false, "a nested begin overtook the mutation")
			helpers.assert_eq(world.calls, { "seconds=5" }, "the switch is never written after a lost revision")
			helpers.assert_not_nil(own_token)
			scope, world = build()
			snapshot = scope.capture()
			world.on_enable = function(owner) owner.begin() end
			helpers.assert_eq(scope.adopt(snapshot, 5, false), false, "the last write is held to the same rule")
			scope, world = build()
			snapshot = scope.capture()
			world.acknowledge = false
			helpers.assert_eq(scope.adopt(snapshot, 5, false), false, "an unacknowledged write is not adopted")
			scope, world = build()
			snapshot = scope.capture()
			world.token_override = "not a token"
			helpers.assert_eq(scope.adopt(snapshot, 5, false), false, "a write that returns no token is refused")
		end)

		helpers.it("(user-scope-contract) never opens a closed-only snapshot", function()
			local scope, world = build()
			world.source = { present = false }
			world.policy = { ready = false, enabled = false }
			world.enabled = false
			local snapshot = scope.capture()
			helpers.assert_eq(scope.adopt(snapshot, 5, true), false)
			helpers.assert_eq(world.calls, {})
			helpers.assert_true(scope.adopt(snapshot, 5, false))
		end)

		helpers.it("(user-scope-contract) restores through the port only for a snapshot it still owns", function()
			local scope, world = build()
			local snapshot = scope.capture()
			helpers.assert_true(scope.restore(snapshot))
			helpers.assert_eq(world.restored.snapshot, snapshot)
			helpers.assert_true(scope.current(world.restored.token), "the restore runs under a fresh revision")
			scope, world = build()
			snapshot = scope.capture()
			world.restore_result = false
			helpers.assert_eq(scope.restore(snapshot), false, "a failed restore is reported")
			scope, world = build()
			snapshot = scope.capture()
			scope.begin()
			helpers.assert_eq(scope.restore(snapshot), false)
			helpers.assert_eq(world.calls, {}, "a stale snapshot never reaches the restore port")
			helpers.assert_eq(scope.restore("not a snapshot"), false)
		end)
	end)
end

return M
