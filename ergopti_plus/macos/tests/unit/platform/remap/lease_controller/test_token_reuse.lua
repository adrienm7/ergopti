--- tests/unit/platform/remap/lease_controller/test_token_reuse.lua

--- ==============================================================================
--- MODULE: Lease Token Reuse Decision Regression
--- DESCRIPTION:
--- Pins why a recovery generation never keeps its predecessor's token (the
--- token-scoped variable names, and with them the 743 KB karabiner.json, change
--- every recovery) and that each allocation records the decision through
--- Logger.evidence. See docs/adr/012-karabiner-lease-token-reuse.md: reuse needs a native
--- acknowledged rearm of the monotone tombstone, which only a Mac can verify.
--- ==============================================================================

local helpers = require("tests.helpers")
local TokenReuse = require("platform.remap.token_reuse")
local support = require("tests.support.lease_controller_fixture")
local with_fixture = support.with_fixture

--- Renders every evidence record the controller emitted so far.
--- @param ctx table Fixture context.
--- @return string[] lines Formatted evidence lines.
local function evidence_lines(ctx)
	local lines = {}
	for _, event in ipairs(ctx.logs.evidence) do
		lines[#lines + 1] = string.format(event[2], table.unpack(event, 3))
	end
	return lines
end

helpers.describe("karabiner lease token reuse: decision", function()
	helpers.it("(token-reuse-decision) refuses with the first applicable reason, never reuses", function()
		local verdict, reason = TokenReuse.decide({ previous_token = nil, unaccounted_writers = 0 })
		helpers.assert_eq(verdict, "fresh")
		helpers.assert_eq(reason, TokenReuse.FRESH_FIRST)

		verdict, reason = TokenReuse.decide({ previous_token = "a", unaccounted_writers = 2 })
		helpers.assert_eq(verdict, "fresh")
		helpers.assert_eq(reason, TokenReuse.REFUSED_WRITERS,
			"an unaccounted writer is named before the tombstone")

		verdict, reason = TokenReuse.decide({ previous_token = "a", unaccounted_writers = 0 })
		helpers.assert_eq(verdict, "fresh")
		helpers.assert_eq(reason, TokenReuse.REFUSED_TOMBSTONE,
			"even with every writer retired the monotone tombstone forbids reuse")
	end)

	helpers.it("(token-reuse-facts) rejects a decision made without the writer count", function()
		helpers.assert_true(not pcall(TokenReuse.decide, {}))
		helpers.assert_true(not pcall(TokenReuse.decide, nil))
	end)
end)

helpers.describe("karabiner lease token reuse: controller", function()
	helpers.it("(token-reuse-recovery) a recovery allocates a fresh token only after the exact fence and says why", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local old_token = controller.token()
			controller.start(function() end)
			helpers.assert_eq(#evidence_lines(ctx), 1)
			helpers.assert_true(evidence_lines(ctx)[1]:find("reason=first-generation", 1, true) ~= nil)

			-- The worker dies: its writer is unaccounted until the fence completes.
			ctx.complete(1, 9, "")
			helpers.assert_nil(controller.variables(),
				"no replacement (and no token decision) while a failed writer is unaccounted")
			helpers.assert_eq(#evidence_lines(ctx), 1)

			ctx.complete(2, 0, "")
			local replacement = controller.variables()
			helpers.assert_not_nil(replacement)
			helpers.assert_true(replacement.token ~= old_token, "a recovery never reuses the token")

			local lines = evidence_lines(ctx)
			helpers.assert_eq(#lines, 2)
			helpers.assert_true(lines[2]:find("decision=fresh reason=tombstone-monotone", 1, true) ~= nil,
				lines[2])
			helpers.assert_true(lines[2]:find("unaccounted_writers=0", 1, true) ~= nil, lines[2])
			helpers.assert_true(lines[2]:find("ledger_size=2", 1, true) ~= nil, lines[2])
			for _, line in ipairs(lines) do
				helpers.assert_true(line:find(old_token, 1, true) == nil
					and line:find(replacement.token, 1, true) == nil,
					"evidence names the decision, never a capability")
			end
		end)
	end)

	helpers.it("(token-reuse-late-writer) a retired generation's worker cannot act on its replacement", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.start(function() end)
			ctx.complete(1, 9, "")
			ctx.complete(2, 0, "")
			local replacement = controller.variables()
			controller.start(function() end)
			local spawn_count = #ctx.spawns
			local phase_before = controller.status()

			-- A late READY from the retired worker (spawn 1) must change nothing.
			pcall(ctx.chunk, 1, "READY\n")
			helpers.assert_eq(controller.status(), phase_before)
			helpers.assert_eq(#ctx.spawns, spawn_count)
			helpers.assert_eq(controller.variables().token, replacement.token)
		end)
	end)
end)
