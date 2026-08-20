--- static/ergopti_plus/linux/tests/unit/meta/test_linux_loader_delegates_toml_codec.lua

--- ==============================================================================
--- MODULE: Linux TOML Loader Delegation Guard
--- DESCRIPTION:
--- Regression guard ensuring that modules/hotstrings/loader.lua delegates
--- TOML parsing to the shared toml_codec.reader module rather than
--- reimplementing its own parser. The impurity that previously prevented
--- delegation (a hard require("infra.logger") in the shared reader) is now
--- fixed; this test locks in the delegation so the fork cannot silently return.
---
--- WHAT WE CHECK:
--- 1. loader.lua contains `require("toml_codec.reader")` (delegates to codec).
--- 2. loader.lua does NOT define its own parse_toml_file (no parallel parser).
--- 3. toml_codec.reader soft-resolves Logger so it loads on the Linux runtime.
--- 4. Every per-entry flag in the shared schema survives the whole TOML → reader
---    → loader → mapping chain. Delegation alone is not enough: the reader
---    returns a FIXED field set rather than passing the parsed table through, so
---    a schema flag it forgets to list is dropped in silence. That is exactly
---    what happened to `is_case_sensitive_strict` — the engine read it, the
---    loader forwarded it, and the value forwarded was always false for all
---    1 302 shared entries that declare it. The check is written over the flag
---    LIST so the next optional flag added to the schema cannot repeat it.
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





-- =======================================
-- =======================================
-- ======= 3/ Schema Flag Survival =======
-- =======================================
-- =======================================

--- Every boolean flag the shared hotstring schema defines per entry. The test is
--- written over this list rather than over one flag so that adding a flag to the
--- schema and forgetting it in the reader's return table fails here, instead of
--- reaching users as an entry that silently behaves like its default.
local SCHEMA_FLAGS = {
	"is_word",
	"auto_expand",
	"is_case_sensitive",
	"final_result",
	"is_case_sensitive_strict",
}

--- Writes `body` to a temp .toml under a directory named after the group the
--- loader is expected to infer, and returns the file path.
--- @param body string TOML source.
--- @return string|nil path Absolute path, or nil when the temp dir is unwritable.
local function write_temp_toml(body)
	local tmp = (os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"):gsub("\\", "/")
	local dir = tmp .. "/ergopti_flag_survival"
	-- The group name is derived from the PARENT directory, so the file has to sit
	-- one level down; a bare temp file would make the loader report "unknown".
	os.execute(string.format("mkdir -p '%s' 2>/dev/null || mkdir \"%s\" 2>nul",
		dir, dir:gsub("/", "\\")))
	local path = dir .. "/flags.toml"
	local fh = io.open(path, "wb")
	if not fh then return nil end
	fh:write(body)
	fh:close()
	return path
end

--- Builds a one-entry TOML file whose every schema flag is set to `value`.
--- @param value boolean The value written for all flags.
--- @return string TOML source.
local function toml_with_all_flags(value)
	local parts = {}
	for _, flag in ipairs(SCHEMA_FLAGS) do
		parts[#parts + 1] = string.format("%s = %s", flag, tostring(value))
	end
	return "[[probe]]\n\"zqx\" = { output = \"expanded\", "
		.. table.concat(parts, ", ") .. " }\n"
end

describe("Linux loader: every schema flag survives TOML → mapping", function()

	for _, flag_value in ipairs({ true, false }) do
		it(string.format("carries every schema flag through when all are %s", tostring(flag_value)), function()
			local path = write_temp_toml(toml_with_all_flags(flag_value))
			assert_true(path ~= nil, "could not write the fixture — the temp dir is unwritable.")

			local loader   = require("modules.hotstrings.loader")
			local mappings = loader.load({ path })
			os.remove(path)

			assert_true(#mappings == 1,
				string.format("expected exactly 1 mapping, got %d — the fixture did not parse.", #mappings))
			local m = mappings[1]
			assert_true(m.trigger == "zqx" and m.replacement == "expanded",
				"trigger/replacement did not survive the chain.")

			for _, flag in ipairs(SCHEMA_FLAGS) do
				assert_true(m[flag] == flag_value, string.format(
					"'%s' arrived as %s but the TOML says %s. Some link in TOML → " ..
					"toml_codec.reader → loader → mapping drops it, and a dropped flag " ..
					"reads as its default rather than as an error.",
					flag, tostring(m[flag]), tostring(flag_value)))
			end
		end)
	end

end)
