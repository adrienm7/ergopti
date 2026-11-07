--- tests/unit/ui/menu/hotstrings/test_section_order_persistence.lua

--- ==============================================================================
--- MODULE: Hotstring Section Order Persistence Tests
--- DESCRIPTION:
--- Exercises the real conditional TOML writer for reorder, reset, malformed
--- preferences, concurrent edits and exclusive scope ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

helpers.describe("hotstring-section-order persistence", function()
	local function with_file(source, test)
		local path = os.tmpname()
		local function write(content)
			local file = assert(io.open(path, "wb")); assert(file:write(content)); file:close()
		end
		local function read()
			local file = assert(io.open(path, "rb")); local text = file:read("*a"); file:close(); return text
		end
		local before = package.loaded["infra.hotstring_preferences"]
		local ok, detail = xpcall(function()
			write(source)
			local preferences = helpers.load_module("infra.hotstring_preferences")
			preferences._set_file_for_test(path)
			test(preferences, read, write)
		end, debug.traceback)
		package.loaded["infra.hotstring_preferences"] = before
		os.remove(path)
		assert(ok, detail)
	end
	helpers.it("hotstring-section-order: reorders and resets one category while preserving unrelated bytes", function()
		with_file('[hotstrings.order_overrides]\nrolls = ["a", "b"]\nother = ["kept"]\n[future]\nvalue = "untouched" # user comment\n', function(owner, read)
			local snapshot = assert(owner.section_order_snapshot("rolls"))
			local committed, reason = owner.set_section_order(snapshot, { "b", "a" })
			helpers.assert_eq(committed, true, tostring(reason))
			helpers.assert_eq(Codec.decode(read()).hotstrings.order_overrides.rolls, { "b", "a" })
			helpers.assert_contains(read(), 'value = "untouched" # user comment')
			local next_snapshot = assert(owner.section_order_snapshot("rolls"))
			helpers.assert_eq(owner.set_section_order(next_snapshot, nil), true)
			helpers.assert_nil(Codec.decode(read()).hotstrings.order_overrides.rolls)
			helpers.assert_eq(Codec.decode(read()).hotstrings.order_overrides.other, { "kept" })
		end)
	end)
	helpers.it("hotstring-section-order: a stale menu cannot overwrite a concurrent source edit", function()
		with_file('[hotstrings.order_overrides]\nrolls = ["a", "b"]\n', function(owner, read, write)
			local snapshot = assert(owner.section_order_snapshot("rolls"))
			local external = '[hotstrings.order_overrides]\nrolls = ["c"]\n'
			write(external)
			helpers.assert_eq(owner.set_section_order(snapshot, { "b", "a" }), false)
			helpers.assert_eq(read(), external)
		end)
	end)
	helpers.it("hotstring-section-order: a pending scope refuses an ordinary order mutation", function()
		with_file('', function(owner, read)
			local snapshot = assert(owner.section_order_snapshot("rolls"))
			local token = {}
			helpers.assert_eq(owner.acquire(token), true)
			helpers.assert_eq(owner.set_section_order(snapshot, { "b", "a" }), false)
			helpers.assert_eq(read(), '')
			helpers.assert_eq(owner.release(token), true)
		end)
	end)
	for _, source in ipairs({ '[hotstrings]\norder_overrides = false\n', '[hotstrings.order_overrides]\nrolls = false\n', '[hotstrings.order_overrides]\nrolls = {}\n' }) do
		helpers.it("hotstring-section-order: malformed saved order is refused: " .. source:gsub("\n", " "), function()
			with_file(source, function(owner, read)
				helpers.assert_nil(owner.section_order_snapshot("rolls"))
				helpers.assert_eq(read(), source)
			end)
		end)
	end
end)
