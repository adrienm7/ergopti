--- static/ergopti_plus/linux/tests/unit/meta/test_shared_hotstring_engine.lua

--- ==============================================================================
--- MODULE: Shared Hotstring Engine — Unit Tests (Linux)
--- DESCRIPTION:
--- Validates that the shared hotstring engine at shared/lua/hotstring_engine/
--- is accessible from the Linux driver and that its core matching algorithm
--- behaves correctly — providing a smoke test that the path resolution in the
--- engine.lua thin re-export works end-to-end.
---
--- The full cross-driver corpus tests live in:
---   tests/unit/meta/test_port_adapter_presence.lua
--- This file focuses on functional correctness of the shared engine.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================
-- =========================================
-- ======= 1/ Engine Bootstrap =============
-- =========================================
-- =========================================

--- Resolves the path to shared/lua/ from this test file's location.
--- @return string|nil Absolute or relative path to shared/lua/, or nil on failure.
local function shared_lua_path()
	local this = debug.getinfo(1, "S").source:gsub("^@", "")
	-- Navigate: tests/unit/meta/ → tests/ → linux/ → shared/lua/
	local linux_root = this:match("^(.*[/\\])tests[/\\]")
	if not linux_root then return nil end
	return linux_root .. "../../shared/lua"
end

-- Bootstrap: inject shared/lua/ into package.path before requiring the engine.
local _shared = shared_lua_path()
if _shared then
	local entry = _shared .. "/?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end

local engine_mod = require("hotstring_engine")




-- =========================================
-- =========================================
-- ======= 2/ Suffix Matching ==============
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — suffix matching", function()
	helpers.it("basic trigger is matched at end of buffer", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"b", "t", "w"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "should match 'btw'")
		helpers.assert_eq("btw",        result.trigger,     "trigger")
		helpers.assert_eq("by the way", result.replacement, "replacement")
	end)

	helpers.it("no match when trigger is not at buffer tail", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"b", "t", "w", "x"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result == nil, "should not match after extra char")
	end)

	helpers.it("longer trigger wins over shorter (longest-match-first)", function()
		local e = engine_mod.new()
		e:load_mappings({
			{ trigger = "btw",  replacement = "short" },
			{ trigger = "btww", replacement = "long"  },
		})
		local result
		for _, ch in ipairs({"b", "t", "w", "w"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "should match")
		helpers.assert_eq("btww", result.trigger, "longer trigger must win")
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ Word Boundary ================
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — word boundary", function()
	helpers.it("is_word trigger blocked mid-word", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "the", replacement = "X", is_word = true } })
		local result
		for _, ch in ipairs({"o", "t", "h", "e"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result == nil, "should not match mid-word")
	end)

	helpers.it("is_word trigger matches after space", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "the", replacement = "X", is_word = true } })
		local result
		for _, ch in ipairs({" ", "t", "h", "e"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "should match after space")
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ Backspace Count ==============
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — backspace count", function()
	helpers.it("backspace_count = tlen without terminator", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"b", "t", "w"}) do
			result = e:on_char(ch, { terminator_consumed = false })
		end
		helpers.assert_true(result ~= nil, "match required")
		helpers.assert_eq(3, result.backspace_count, "tlen = 3")
	end)

	helpers.it("backspace_count = tlen + 1 with terminator consumed", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "btw", replacement = "by the way" } })
		-- Simulate trigger typed, then terminator typed but consumed.
		e:on_char("b")
		e:on_char("t")
		local result = e:on_char("w", { terminator_consumed = true })
		helpers.assert_true(result ~= nil, "match required")
		helpers.assert_eq(4, result.backspace_count, "tlen + 1 = 4")
	end)
end)




-- =========================================
-- =========================================
-- ======= 5/ Case Sensitivity =============
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — case sensitivity", function()
	helpers.it("default is case-insensitive", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "btw", replacement = "by the way" } })
		local result
		for _, ch in ipairs({"B", "T", "W"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "uppercase input should match lowercase trigger")
	end)

	helpers.it("is_case_sensitive rejects wrong case", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "BTW", replacement = "by the way", is_case_sensitive = true } })
		local result
		for _, ch in ipairs({"b", "t", "w"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result == nil, "lowercase should not match case-sensitive uppercase trigger")
	end)

	helpers.it("is_case_sensitive accepts correct case", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "BTW", replacement = "by the way", is_case_sensitive = true } })
		local result
		for _, ch in ipairs({"B", "T", "W"}) do
			result = e:on_char(ch)
		end
		helpers.assert_true(result ~= nil, "exact case should match")
	end)
end)




-- =========================================
-- =========================================
-- ======= 6/ Reset ========================
-- =========================================
-- =========================================

helpers.describe("shared hotstring engine — buffer reset", function()
	helpers.it("reset clears buffer so trigger no longer matches", function()
		local e = engine_mod.new()
		e:load_mappings({ { trigger = "btw", replacement = "by the way" } })
		e:on_char("b")
		e:on_char("t")
		e:reset()
		local result = e:on_char("w")
		helpers.assert_true(result == nil, "after reset, partial buffer is cleared — no match")
	end)
end)
