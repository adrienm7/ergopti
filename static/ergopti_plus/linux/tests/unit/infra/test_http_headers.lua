--- tests/unit/infra/test_http_headers.lua

--- ==============================================================================
--- MODULE: Immutable HTTP Header Preparation Controls
--- DESCRIPTION:
--- Fixed literal metadata and wire-order controls for shared header snapshots.
--- No expectations are generated from the implementation under test.
--- ==============================================================================

local helpers = require("tests.helpers")
local Headers = require("network.http_headers")
local Policy = require("infra.http_header_policy")

helpers.describe("immutable HTTP header snapshots", function()
	helpers.it("captures values exactly once in original sorted field order", function()
		local seen = {}
		local function value(name, bytes)
			return setmetatable({}, { __tostring = function() seen[#seen + 1] = name; return bytes end })
		end
		local rows, view = Headers.capture({ ["X-Z"] = value("Z", "last"), ["X-A"] = value("A", "first") }, Policy.validate)
		helpers.assert_eq(table.concat(seen, ","), "A,Z")
		helpers.assert_eq(rows[1].name, "X-A")
		helpers.assert_eq(rows[1].value, "first")
		helpers.assert_eq(rows[2].name, "X-Z")
		helpers.assert_eq(rows[2].value, "last")
		helpers.assert_eq(view["X-A"], "first")
	end)
	helpers.it("does not convert values when original mixed-name sorting refuses", function()
		local conversions = 0
		local value = setmetatable({}, { __tostring = function() conversions = conversions + 1; return "fixed" end })
		local ok = pcall(Headers.capture, { [1] = value, ["X-A"] = value }, Policy.validate)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(conversions, 0)
	end)
	helpers.it("preserves numeric names and their original ordered wire rows", function()
		local rows, view = Headers.capture({ [2] = "two", [1] = "one" }, Policy.validate)
		helpers.assert_eq(rows[1].name, "1")
		helpers.assert_eq(rows[2].name, "2")
		helpers.assert_eq(view["1"], "one")
	end)
	helpers.it("keeps whitespace-only bytes for the native semicolon law", function()
		local rows, view = Headers.capture({ ["X-Empty"] = " \t" }, Policy.validate)
		helpers.assert_eq(rows[1].value, " \t")
		helpers.assert_eq(view["X-Empty"], " \t")
	end)
	for _, bytes in ipairs({ "forbidden\0tail", "forbidden\r\ntail" }) do
		local literal = bytes
		helpers.it("refuses canonical forbidden value bytes", function()
			local accepted, refusal = pcall(Headers.capture, { ["X-A"] = literal }, Policy.validate)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(type(refusal), "string")
			helpers.assert_eq(refusal:match("HTTP header contains a forbidden byte$"), "HTTP header contains a forbidden byte")
		end)
	end
	helpers.it("detaches the published view from retained header rows", function()
		local rows, private = Headers.capture({ ["X-A"] = "first" }, Policy.validate)
		local public = Headers.copy(private)
		public["X-A"] = "changed"
		helpers.assert_eq(private["X-A"], "first")
		helpers.assert_eq(rows[1].value, "first")
	end)
	helpers.it("only accepts a plain byte-identical complete map", function()
		local _, private = Headers.capture({ ["X-A"] = "first" }, Policy.validate)
		helpers.assert_true(Headers.matches({ ["X-A"] = "first" }, private))
		helpers.assert_eq(Headers.matches({ ["X-A"] = "changed" }, private), false)
		helpers.assert_eq(Headers.matches({}, private), false)
		helpers.assert_eq(Headers.matches({ ["X-A"] = "first", ["X-B"] = "added" }, private), false)
		helpers.assert_eq(Headers.matches(setmetatable({ ["X-A"] = "first" }, {}), private), false)
	end)
	helpers.it("removes sensitive fields without re-evaluating any metadata", function()
		local rows, view = Headers.capture({ Authorization = "dummy", ["X-A"] = "first", ["X-Z"] = "last" }, Policy.validate)
		local retained, next_view = Headers.subset(rows, view, { ["X-A"] = "first", ["X-Z"] = "last" })
		helpers.assert_eq(#retained, 2)
		helpers.assert_eq(retained[1].name, "X-A")
		helpers.assert_eq(retained[2].name, "X-Z")
		helpers.assert_eq(next_view.Authorization, nil)
	end)
	helpers.it("refuses rewriting or introducing fields in a redirected snapshot", function()
		local rows, view = Headers.capture({ ["X-A"] = "first" }, Policy.validate)
		helpers.assert_eq(Headers.subset(rows, view, { ["X-A"] = "changed" }), nil)
		helpers.assert_eq(Headers.subset(rows, view, { ["X-B"] = "added" }), nil)
		helpers.assert_eq(Headers.subset(rows, view, setmetatable({}, {})), nil)
	end)
	helpers.it("retains duplicate normalized wire fields when filtering", function()
		local rows = { { name = "X-A", value = "first" }, { name = "X-A", value = "last" }, { name = "X-Z", value = "other" } }
		local retained = assert(Headers.subset(rows, { ["X-A"] = "last", ["X-Z"] = "other" }, { ["X-A"] = "last" }))
		helpers.assert_eq(#retained, 2)
		helpers.assert_eq(retained[1].value, "first")
		helpers.assert_eq(retained[2].value, "last")
	end)
end)
