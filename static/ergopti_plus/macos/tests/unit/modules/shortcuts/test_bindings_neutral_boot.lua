--- tests/unit/modules/shortcuts/test_bindings_neutral_boot.lua

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

helpers.describe("neutral shortcut registration", function()
	helpers.it("enabling an empty master does not import fixed child preferences or native registrations", function()
		Fixture.with_bindings(function(bindings, ctx)
			local count = 0
			for id, entry in pairs(Fixture.index(bindings)) do
				count = count + 1
				helpers.assert_eq(entry.enabled, false, id .. " must require explicit desired intent")
			end
			helpers.assert_true(count > 10, "exercise the real registry")
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(ctx.created, 0, "no implicit child may acquire a native owner")
			helpers.assert_eq(Fixture.live_count(ctx), 0)
			helpers.assert_eq(bindings.enable("ctrl_a"), true)
			helpers.assert_eq(ctx.created, 1, "an explicit child still acquires its real native port")
			helpers.assert_eq(Fixture.live_count(ctx), 1)
			helpers.assert_eq(bindings.pause(), true)
			helpers.assert_eq(bindings.is_enabled("ctrl_a"), true, "pause must preserve desired intent")
			helpers.assert_eq(Fixture.live_count(ctx), 0)
		end)
	end)
end)
