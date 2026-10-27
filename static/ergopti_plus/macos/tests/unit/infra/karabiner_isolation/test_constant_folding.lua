--- tests/unit/infra/karabiner_isolation/test_constant_folding.lua

--- ==============================================================================
--- MODULE: Karabiner Isolation folding cases
--- DESCRIPTION:
--- Behavioral scenarios for the shared Karabiner source detector.
--- ==============================================================================

local helpers = require("tests.helpers")
local syntax = require("tests.support.karabiner_isolation.syntax")
local has_folded_stock_target = syntax.has_folded_stock_target
local detector = require("tests.support.karabiner_isolation.detector")

helpers.describe("Karabiner isolation: folding cases", function()
	helpers.it("(fold-operator-prefilter) avoids constant lookups without concatenation", function()
		local lookups = 0
		local constants = setmetatable({}, {
			__index = function()
				lookups = lookups + 1
				return "karabiner_grabber"
			end,
		})
		for _, source in ipairs({ "", "local target = family", "family", "'karabiner_grabber'" }) do
			helpers.assert_eq(has_folded_stock_target(source, constants), false,
				"standalone values are not concatenations")
		end
		helpers.assert_eq(lookups, 0, "operator-free statements must not resolve constants")
		for _, operator in ipairs({ "..", "+" }) do
			helpers.assert_eq(has_folded_stock_target("prefix " .. operator .. " 'grabber'",
				{ prefix = "karabiner_" }), true, "both supported concatenation operators remain covered")
			helpers.assert_eq(has_folded_stock_target("'safe " .. operator .. " literal'", {}), false,
				"an operator inside a literal must not manufacture a concatenation")
		end
	end)
	-- The uninstall worker once spelled its owned vhid label as a literal. Read
	-- from the generated enum, the member name `macosVirtualHid` looked like the
	-- stock VirtualHID to a lexical scan, and its owned bootout was refused.
	helpers.it("(generated-identifier-fold) judges an enum reference by its value", function()
		local values = syntax.generated_swift_identifiers([[
enum Identifiers {
	enum ServiceLabels {
		static let macosVirtualHid = "com.ergoptiplus.runtime.vhid"
		static let stockServer = "org.pqrs.karabiner.karabiner_console_user_server"
	}
}
]])
		local owned = [[
enum OwnedRuntimeUninstall {
	static let jobs: [(label: String, plist: String)] = [
		(Identifiers.ServiceLabels.macosVirtualHid, "/Library/LaunchDaemons/\(Identifiers.ServiceLabels.macosVirtualHid).plist"),
	]
	static func script() -> String {
		var steps = ["set -e"]
		for job in jobs {
			steps.append("if /bin/launchctl print system/\(job.label) >/dev/null 2>&1; then /bin/launchctl bootout system/\(job.label); fi")
		}
		return steps.joined(separator: "; ")
	}
}
]]
		helpers.assert_true(#detector.find_offenders(owned) > 0,
			"unfolded, the member name alone reads as a stock target")
		local folded = syntax.fold_generated_identifiers(owned, values)
		helpers.assert_true(folded:find('("com.ergoptiplus.runtime.vhid", "/Library/LaunchDaemons/com.ergoptiplus.runtime.vhid.plist")',
			1, true) ~= nil, "a bare reference becomes a literal and an interpolated one its bare value")
		helpers.assert_eq(#detector.find_offenders(folded), 0,
			"the owned label's value is not a stock Karabiner target")
		local stock = owned:gsub("macosVirtualHid", "stockServer")
		helpers.assert_true(#detector.find_offenders(syntax.fold_generated_identifiers(stock, values)) > 0,
			"a stock label behind the enum is still refused")
		helpers.assert_true(not pcall(syntax.fold_generated_identifiers, "Identifiers.ServiceLabels.missing", values),
			"an unknown reference fails instead of passing unread")
	end)
end)
