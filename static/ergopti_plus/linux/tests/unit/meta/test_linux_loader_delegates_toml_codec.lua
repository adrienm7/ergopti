--- static/ergopti_plus/linux/tests/unit/meta/test_linux_loader_delegates_toml_codec.lua

--- ==============================================================================
--- MODULE: Linux TOML Loader Delegation Guard
--- DESCRIPTION:
--- Regression guard ensuring that modules/hotstrings/loader.lua delegates
--- TOML parsing to the shared toml_codec.reader module rather than
--- reimplementing its own parser. The impurity that previously prevented
--- delegation (a hard require("lib.logger") in the shared reader) is now
--- fixed; this test locks in the delegation so the fork cannot silently return.
---
--- WHAT WE CHECK:
--- 1. loader.lua contains `require("toml_codec.reader")` (delegates to codec).
--- 2. loader.lua does NOT define its own parse_toml_file (no parallel parser).
--- 3. toml_codec.reader soft-resolves Logger so it loads on the Linux runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_true = helpers.assert_true

local DRIVER_ROOT = helpers.driver_root()
local LOADER_PATH = DRIVER_ROOT .. "/modules/hotstrings/loader.lua"





-- =========================================
-- =========================================
-- ======= 1/ Static Source Analysis =======
-- =========================================
-- =========================================

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return "" end
	local s = fh:read("*a")
	fh:close()
	return s
end

local loader_src = read_file(LOADER_PATH)

describe("Linux TOML loader delegation to toml_codec.reader", function()

	it("loader.lua requires toml_codec.reader (delegates to shared codec)", function()
		assert_true(
			loader_src:find('require%("toml_codec%.reader"%)', 1, false) ~= nil
				or loader_src:find("require%('toml_codec%.reader'%)", 1, false) ~= nil,
			"loader.lua must delegate to toml_codec.reader — no local parser fork allowed."
		)
	end)

	it("loader.lua does not define parse_toml_file (no parallel parser)", function()
		assert_true(
			loader_src:find("parse_toml_file", 1, true) == nil,
			"parse_toml_file found in loader.lua — the parallel parser was not removed."
		)
	end)

	it("loader.lua does not redefine unquote helper (inline parser removed)", function()
		assert_true(
			loader_src:find("local function unquote", 1, true) == nil,
			"'unquote' helper found — the inline TOML parser is still present."
		)
	end)





-- =====================================
-- =====================================
-- ======= 2/ Runtime Load Guard =======
-- =====================================
-- =====================================

	it("toml_codec.reader loads without error on Linux runtime", function()
		local ok, result = pcall(require, "toml_codec.reader")
		assert_true(ok, "toml_codec.reader failed to load: " .. tostring(result))
	end)

	it("modules.hotstrings.loader loads without error on Linux runtime", function()
		local ok, result = pcall(require, "modules.hotstrings.loader")
		assert_true(ok, "modules.hotstrings.loader failed to load: " .. tostring(result))
	end)

	it("loader exposes M.load and M.find_toml_files", function()
		local ok, loader = pcall(require, "modules.hotstrings.loader")
		assert_true(ok and type(loader) == "table", "loader must return a table.")
		assert_true(type(loader.load) == "function", "loader.load must be a function.")
		assert_true(type(loader.find_toml_files) == "function", "loader.find_toml_files must be a function.")
	end)

end)
